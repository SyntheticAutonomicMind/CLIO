# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Core::ReadLine;

use strict;
use warnings;
use utf8;
use CLIO::Core::Logger qw(should_log log_debug log_warning);

# Ensure STDOUT is autoflushed for immediate terminal response
$| = 1;
use CLIO::Compat::Terminal qw(ReadMode ReadKey GetTerminalSize);
use Encode ();

=head1 NAME

CLIO::Core::ReadLine - Custom readline implementation with tab completion

=head1 DESCRIPTION

A self-contained readline implementation that doesn't depend on external
CPAN modules. Provides:
- Tab completion
- Command history
- Line editing (backspace, delete, arrow keys)
- Portable terminal control using stty

=head2 DESIGN: Compute-from-state cursor tracking

Cursor positions are NEVER tracked incrementally via shadow state that
can desync from the terminal. Instead, B<_cursor_at_codepoint> is the
single source of truth: it walks the input string character-by-character
and computes the physical (row, col) for any codepoint offset. Every
cursor movement, redraw, and reposition uses this pure function.

The only incremental state retained is C<last_cursor_row>, used solely
by C<redraw_line> to know how many rows to move up before clearing —
and that value is always set by C<_cursor_at_codepoint> (via
C<reposition_cursor>, C<_redraw_from_cursor>, or C<redraw_line> itself).

=cut

=head2 _display_width

Compute the number of terminal columns a string occupies.

ASCII characters are 1 column wide. CJK (Chinese/Japanese/Korean) and other
fullwidth Unicode characters are 2 columns wide. This is needed for correct
cursor positioning when wide characters are present in the input.

Uses Unicode::GCString if available (most accurate), otherwise falls back
to a regex-based range check covering the common East Asian wide blocks.

=cut

# Probe for Unicode::GCString at startup so we don't repeat the eval
# on every _display_width call. The result is captured in a closure.
my $HAS_UNICODE_GCSTRING = eval { require Unicode::GCString; 1 } ? 1 : 0;

sub _check_gcstring { $HAS_UNICODE_GCSTRING }

sub _display_width {
    my ($str) = @_;
    return 0 unless defined $str && length($str);

    # Use Unicode::GCString for accurate width if available
    if ($HAS_UNICODE_GCSTRING) {
        return Unicode::GCString->new($str)->columns();
    }

    # Fallback: count codepoints, adding 1 extra column for each wide character.
    # Wide characters are those in the East Asian Wide (W) and Fullwidth (F) categories.
    # This covers CJK Unified Ideographs, Hiragana, Katakana, Hangul, and common
    # fullwidth forms used in Chinese/Japanese/Korean text.
    my $width = 0;
    for my $ch (split //, $str) {
        my $cp = ord($ch);
        if (
            # CJK Unified Ideographs and extensions
            ($cp >= 0x4E00  && $cp <= 0x9FFF)   ||
            ($cp >= 0x3400  && $cp <= 0x4DBF)   ||
            ($cp >= 0x20000 && $cp <= 0x2A6DF)  ||
            ($cp >= 0x2A700 && $cp <= 0x2CEAF)  ||
            ($cp >= 0xF900  && $cp <= 0xFAFF)   ||
            ($cp >= 0x2F800 && $cp <= 0x2FA1F)  ||
            # CJK Compatibility and Radicals
            ($cp >= 0x2E80  && $cp <= 0x2EFF)   ||
            ($cp >= 0x2F00  && $cp <= 0x2FDF)   ||
            ($cp >= 0x31C0  && $cp <= 0x31EF)   ||
            # Hiragana, Katakana, Bopomofo
            ($cp >= 0x3040  && $cp <= 0x30FF)   ||
            ($cp >= 0x3100  && $cp <= 0x312F)   ||
            ($cp >= 0x31A0  && $cp <= 0x31BF)   ||
            # Enclosed CJK, CJK Compatibility
            ($cp >= 0x3200  && $cp <= 0x32FF)   ||
            ($cp >= 0x3300  && $cp <= 0x33FF)   ||
            # Hangul Syllables
            ($cp >= 0xAC00  && $cp <= 0xD7AF)   ||
            # Halfwidth and Fullwidth Forms
            ($cp >= 0xFF01  && $cp <= 0xFF60)   ||
            ($cp >= 0xFFE0  && $cp <= 0xFFE6)   ||
            # Wide miscellaneous symbols
            ($cp >= 0x1F300 && $cp <= 0x1F9FF)
        ) {
            $width += 2;
        } else {
            $width += 1;
        }
    }
    return $width;
}

sub new {
    my ($class, %args) = @_;

    my $self = {
        prompt => $args{prompt} || '> ',
        history => $args{history} || [],
        history_pos => -1,
        completer => $args{completer},  # CLIO::Core::TabCompletion instance
        debug => $args{debug} || 0,
        max_history => $args{max_history} || 1000,
        # How many terminal lines the current input occupies.
        # Computed from input state; used by redraw_line for vertical
        # movement.
        display_lines => 1,
        # Cursor position tracking. Updated by _cursor_at_codepoint-based
        # operations. Used by redraw_line to know how many rows to move up
        # before clearing. Always set to the value computed by
        # _cursor_at_codepoint — never by ad-hoc arithmetic.
        last_cursor_row => 0,
        last_cursor_col => 1,
        last_cursor_disp => 0,
        pending_wrap => 0,
        # Performance caches (invalidated per-readline call)
        _prompt_disp_cache => undef,   # cached prompt display width
        _term_width_cache => undef,    # cached terminal width
        _term_width_time => 0,         # when we last checked terminal width
    };

    return bless $self, $class;
}

=head2 readline

Read a line of input with tab completion and line editing support.

Arguments:
- $prompt: Optional prompt to display (overrides default)

Returns: Line of input (chomped), or undef on EOF

Signal Handling:
- Ctrl-C (SIGINT): Raises actual SIGINT signal to allow session cleanup
  handlers to run. This ensures session state is saved before exit.
- Ctrl-D (EOF): Returns undef when pressed on empty line
- EINTR: Automatically retries on signal interruption without busy-wait

=cut

=head2 _get_term_width

Return cached terminal width. Refreshes from the terminal at most once
per second to avoid expensive ioctl calls on every keystroke.

=cut

sub _get_term_width {
    my ($self) = @_;
    my $now = time();
    if (!$self->{_term_width_cache} || $now > $self->{_term_width_time}) {
        my ($w, $h) = GetTerminalSize();
        $self->{_term_width_cache} = ($w && $w >= 10) ? $w : 80;
        $self->{_term_width_time} = $now;
    }
    return $self->{_term_width_cache};
}

=head2 _get_prompt_disp

Return cached display width of the visible prompt (ANSI codes stripped).
Set once per readline() call since the prompt doesn't change mid-input.

=cut

sub _get_prompt_disp {
    my ($self, $prompt) = @_;
    unless (defined $self->{_prompt_disp_cache}) {
        my $visible = $prompt // '';
        $visible =~ s/\e\[[0-9;]*m//g;
        $self->{_prompt_disp_cache} = _display_width($visible);
    }
    return $self->{_prompt_disp_cache};
}

=head2 _cursor_at_codepoint

Compute the physical (row, col) that the cursor would be at if it sat
at codepoint $cp in $input. Starts at (0, 1+prompt_disp) and walks through
each codepoint, tracking wraps.

This is the single source of truth for cursor position. Every cursor
movement, redraw, and reposition is computed from this function — never
from incrementally-tracked shadow state that can desync.

Returns: ($row, $col) where $row is 0-indexed and $col is 1-indexed.

=cut

sub _cursor_at_codepoint {
    my ($self, $input, $cp, $prompt) = @_;
    $prompt //= $self->{prompt} // '';

    my $term_width = $self->_get_term_width();
    my $prompt_disp = $self->_get_prompt_disp($prompt);

    # Start at (0, prompt_disp+1) - the position right after the prompt.
    my $row = 0;
    my $col = $prompt_disp + 1;

    # Walk through codepoints 0..cp-1, advancing col and wrapping on
    # boundary. We track pending state internally so we know whether the
    # cursor is at col 1 of a new row (after a wrap) or col term_width
    # (pending wrap on the previous row).
    my $pending = 0;
    for my $i (0 .. $cp - 1) {
        my $ch = substr($input, $i, 1);
        my $w = _display_width($ch);

        if ($pending) {
            $row += 1;
            $col = 1;
            $pending = 0;
        }
        # If this char doesn't fit in remaining space, wrap first.
        if ($col + $w - 1 > $term_width) {
            $row += 1;
            $col = 1;
        }
        $col += $w;
        if ($col == $term_width) {
            $pending = 1;
        }
    }

    # Note: the cursor at codepoint $cp is "before" char $cp. If pending
    # is set here, the cursor sits at last col of current row (the
    # wrap will resolve when char $cp is printed). Convert to a
    # 1-indexed col for the caller.
    if ($pending) {
        # Cursor is at last col of current row.
        return ($row, $term_width);
    }
    return ($row, $col);
}

=head2 _emit_text

Print $text and update last_cursor_* / pending_wrap tracking to reflect
the cursor's actual position after the text is rendered.

Wide-character widths are honored via _display_width.

ANSI escape sequences (SGR color codes from colorize()) are printed to
the terminal but STRIPPED from cursor tracking. They are invisible
control codes that do not move the cursor. Without stripping, the
prompt's ANSI bytes inflate last_cursor_col, corrupting every
downstream cursor computation (paste positioning, backspace tracking,
redraw_line/reposition_cursor). This matches _get_prompt_disp() and
_cursor_at_codepoint(), which already strip ANSI codes when computing
display width.

=cut

sub _emit_text {
    my ($self, $text) = @_;
    return unless defined $text && length $text;

    # Print the raw text (including ANSI escape sequences for color) to
    # the terminal. These bytes are invisible control codes; the
    # terminal renders them for color but does not move the cursor.
    print $text;

    # For cursor tracking, strip ANSI escape sequences. They must NOT
    # advance the cursor position.
    my $visible = $text;
    $visible =~ s/\e\[[0-9;?]*[A-Za-z]//g;

    return unless length $visible;

    my $term_width = $self->_get_term_width();
    my $row = $self->{last_cursor_row};
    my $col = $self->{last_cursor_col};
    my $pending = $self->{pending_wrap};

    for my $i (0 .. length($visible) - 1) {
        my $ch = substr($visible, $i, 1);
        my $w = _display_width($ch);

        # Step 1: Resolve pending-wrap if set. The wrap happens BEFORE
        # the char is placed.
        if ($pending) {
            $row += 1;
            $col = 1;
            $pending = 0;
        }

        # Step 2: Place the char. If it doesn't fit in the remaining
        # space (col + w > term_width + 1), it wraps to next row.
        if ($col + $w - 1 > $term_width) {
            # Wrap before placing.
            $row += 1;
            $col = 1;
        }
        $col += $w;

        # Step 3: If we landed exactly at col=term_width, set pending
        # for the NEXT char (which will wrap). Note: if this is the
        # LAST char of $text, pending is set but never used (caller
        # will likely clear it before the next operation).
        if ($col == $term_width + 1) {
            # Shouldn't happen since we wrap when col + w > term_width;
            # defensive.
            $col = 1;
            $row += 1;
        } elsif ($col == $term_width) {
            $pending = 1;
        }
    }

    $self->{last_cursor_row} = $row;
    $self->{last_cursor_col} = $col;
    $self->{last_cursor_disp} = $row * $term_width + ($col - 1);
    $self->{pending_wrap} = $pending;
}

=head2 _emit_newline

Emit a newline: move to column 1 of the next row. Updates tracking.

Pending wrap is resolved (a newline always wraps to col 1 of next row).

=cut

sub _emit_newline {
    my ($self) = @_;
    print "\r\n";
    # Newline: move to (row+1, col 1).
    my $row = $self->{last_cursor_row};
    if ($self->{pending_wrap}) {
        # Wrap resolves: row stays (we're at last col of current row),
        # newline moves to (row+1, 1).
        $row += 1;
    } else {
        $row += 1;
    }
    $self->{last_cursor_row} = $row;
    $self->{last_cursor_col} = 1;
    $self->{last_cursor_disp} = $row * $self->_get_term_width();
    $self->{pending_wrap} = 0;
}

=head2 _emit_ctrl_c

Emit the "^C\n" sequence shown when the user hits Ctrl+C. Updates
tracking to leave the cursor at col 1 of the next row.

=cut

sub _emit_ctrl_c {
    my ($self) = @_;
    print "^C";
    # "^" is 1 col, "C" is 1 col = 2 cols of text.
    my $row = $self->{last_cursor_row};
    my $col = $self->{last_cursor_col} + 2;
    my $term_width = $self->_get_term_width();
    if ($col > $term_width) {
        $row += 1;
        $col = 1;
    }
    $self->{last_cursor_row} = $row;
    $self->{last_cursor_col} = $col;
    $self->{last_cursor_disp} = $row * $term_width + ($col - 1);
    $self->{pending_wrap} = ($col == $term_width);
    $self->_emit_newline();  # The trailing \n
}

=head2 redraw_line

Redraw the input line with cursor at correct position.

This method performs a FULL clear-and-redraw of the input line. It should ONLY
be called when the input CONTENT has changed (character added/deleted, text replaced).

For cursor-only movements (arrows, home/end), use reposition_cursor() instead.

All positions are computed from input state via _cursor_at_codepoint — never
from incrementally-tracked shadow state.

=cut

sub redraw_line {
    my ($self, $input_ref, $cursor_pos_ref, $prompt) = @_;

    # Defensive: ensure prompt is defined
    $prompt //= '';

    # Safety: clamp cursor position to valid range
    my $input_len = length($$input_ref);
    if ($$cursor_pos_ref < 0) {
        log_debug('ReadLine', "Cursor position was negative ($$cursor_pos_ref), clamping to 0");
        $$cursor_pos_ref = 0;
    } elsif ($$cursor_pos_ref > $input_len) {
        log_debug('ReadLine', "Cursor position exceeded input length ($$cursor_pos_ref > $input_len), clamping to $input_len");
        $$cursor_pos_ref = $input_len;
    }

    my $term_width = $self->_get_term_width();
    my $prompt_disp = $self->_get_prompt_disp($prompt);

    # Total display columns for the new content
    my $input_disp  = _display_width($$input_ref);
    my $total_disp  = $prompt_disp + $input_disp;

    # How many terminal lines the new content occupies
    my $new_lines_needed = $total_disp > 0 ? int(($total_disp - 1) / $term_width) + 1 : 1;

    my $old_display_lines = $self->{display_lines} || 1;
    my $max_lines = $old_display_lines > $new_lines_needed ? $old_display_lines : $new_lines_needed;

    if (should_log('DEBUG')) {
        log_debug('ReadLine', "redraw_line: input_len=$input_len, prompt_disp=$prompt_disp, input_disp=$input_disp, total_disp=$total_disp");
        log_debug('ReadLine', "redraw_line: term_width=$term_width, new_lines_needed=$new_lines_needed");
        log_debug('ReadLine', "redraw_line: old_display_lines=$old_display_lines, max_lines=$max_lines");
        log_debug('ReadLine', "redraw_line: last cursor was at row=$self->{last_cursor_row}, col=$self->{last_cursor_col} pending=$self->{pending_wrap}");
    }

    # Move to (row 0, col 1) of the input area.
    # last_cursor_row is always correct (set by _cursor_at_codepoint
    # in every operation that changes the cursor).
    print "\r";
    if ($self->{pending_wrap}) {
        $self->{last_cursor_col} = 1;
        $self->{pending_wrap} = 0;
    } else {
        $self->{last_cursor_col} = 1;
    }
    my $current_row = $self->{last_cursor_row};
    if ($current_row > 0) {
        print "\e[${current_row}A";
        $self->{last_cursor_row} = 0;
    }

    # Clear from here to end of screen, then redraw prompt + input
    print "\e[J";
    $self->_emit_text($prompt);
    $self->_emit_text($$input_ref);

    # Update display_lines for next redraw.
    $self->{display_lines} = $new_lines_needed;

    # After printing, the terminal cursor is at the end of the output.
    # Compute the desired cursor position from input state (NOT from
    # last_cursor_* or arithmetic division -- both can be wrong,
    # especially with wide characters).
    my ($desired_row, $desired_col) = $self->_cursor_at_codepoint($$input_ref, $$cursor_pos_ref, $prompt);

    # Compute end position from input state too.
    my ($end_row, $end_col) = $self->_cursor_at_codepoint($$input_ref, length($$input_ref), $prompt);

    if (should_log('DEBUG')) {
        log_debug('ReadLine', "redraw_line: end position: ($end_row,$end_col)");
        log_debug('ReadLine', "redraw_line: desired cursor: ($desired_row,$desired_col)");
    }

    # Reposition cursor to desired location.
    if ($desired_row != $end_row || $desired_col != $end_col) {
        # Use CR + vertical + horizontal to avoid pending-wrap issues.
        print "\r";
        if ($desired_row < $end_row) {
            print "\e[" . ($end_row - $desired_row) . "A";
        } elsif ($desired_row > $end_row) {
            print "\e[" . ($desired_row - $end_row) . "B";
        }
        print "\e[" . ($desired_col - 1) . "C" if $desired_col > 1;
    }

    # Update tracking to reflect the final cursor position.
    $self->{last_cursor_row} = $desired_row;
    $self->{last_cursor_col} = $desired_col;
    $self->{last_cursor_disp} = $prompt_disp + _display_width(substr($$input_ref, 0, $$cursor_pos_ref));
    $self->{pending_wrap} = 0;
}

=head2 _redraw_from_cursor

Partial redraw: reprint from cursor position to end of input, then
clear any leftover characters and reposition the cursor.

All positions are computed from input state via _cursor_at_codepoint.

=cut

sub _redraw_from_cursor {
    my ($self, $input_ref, $cursor_pos_ref, $prompt) = @_;

    my $term_width = $self->_get_term_width();
    my $prompt_disp = $self->_get_prompt_disp($prompt);

    # Print everything after cursor, then clear leftover chars.
    my $tail = substr($$input_ref, $$cursor_pos_ref);
    $self->_emit_text($tail);
    print "\e[J";

    # Compute end-of-input position from input state.
    my ($end_row, $end_col) = $self->_cursor_at_codepoint($$input_ref, length($$input_ref), $prompt);

    # Compute target cursor position from input state.
    my ($target_row, $target_col) = $self->_cursor_at_codepoint($$input_ref, $$cursor_pos_ref, $prompt);

    if (should_log('DEBUG')) {
        log_debug('ReadLine', "_redraw_from_cursor: end=($end_row,$end_col), target=($target_row,$target_col)");
    }

    # Move from end to target. Use CR + vertical + horizontal for safety
    # (avoid pending-wrap ambiguity with relative horizontal movement).
    if ($target_row != $end_row || $target_col != $end_col) {
        print "\r";
        if ($target_row < $end_row) {
            print "\e[" . ($end_row - $target_row) . "A";
        } elsif ($target_row > $end_row) {
            print "\e[" . ($target_row - $end_row) . "B";
        }
        print "\e[" . ($target_col - 1) . "C" if $target_col > 1;
    }

    # Update tracking.
    $self->{last_cursor_row} = $target_row;
    $self->{last_cursor_col} = $target_col;
    my $cursor_disp = $prompt_disp + _display_width(substr($$input_ref, 0, $$cursor_pos_ref));
    $self->{last_cursor_disp} = $cursor_disp;
    $self->{pending_wrap} = 0;

    # Update display_lines.
    my $total_disp = $prompt_disp + _display_width($$input_ref);
    $self->{display_lines} = $total_disp > 0 ? int(($total_disp - 1) / $term_width) + 1 : 1;
}

=head2 _redraw_line_external

Redraw the current prompt and input line after external output (e.g., broker
events) has been printed above the input line. Moves cursor to column 0,
reprints the prompt and input buffer, and repositions the cursor.

All positions are computed from input state via _cursor_at_codepoint.

=cut

sub _redraw_line_external {
    my ($self, $prompt, $input_ref, $cursor_pos_ref) = @_;

    $prompt //= '';

    # Clamp cursor position.
    my $input_len = length($$input_ref);
    if ($$cursor_pos_ref < 0) {
        $$cursor_pos_ref = 0;
    } elsif ($$cursor_pos_ref > $input_len) {
        $$cursor_pos_ref = $input_len;
    }

    # Move to column 0 of current row, clear to end of screen,
    # then redraw prompt + input.
    print "\r";
    print "\e[J";
    $self->_emit_text($prompt);
    $self->_emit_text($$input_ref);

    # Compute cursor position from input state.
    my ($cursor_row, $cursor_col) = $self->_cursor_at_codepoint($$input_ref, $$cursor_pos_ref, $prompt);

    # Compute end-of-input position from input state.
    my ($end_row, $end_col) = $self->_cursor_at_codepoint($$input_ref, length($$input_ref), $prompt);

    # Move from end to cursor position.
    if ($cursor_row != $end_row || $cursor_col != $end_col) {
        print "\r";
        if ($cursor_row < $end_row) {
            print "\e[" . ($end_row - $cursor_row) . "A";
        } elsif ($cursor_row > $end_row) {
            print "\e[" . ($cursor_row - $end_row) . "B";
        }
        print "\e[" . ($cursor_col - 1) . "C" if $cursor_col > 1;
    }

    # Update tracking.
    my $term_width = $self->_get_term_width();
    my $prompt_disp = $self->_get_prompt_disp($prompt);
    my $total_disp = $prompt_disp + _display_width($$input_ref);
    my $new_display_lines = $total_disp > 0 ? int(($total_disp - 1) / $term_width) + 1 : 1;
    my $cursor_disp = $prompt_disp + _display_width(substr($$input_ref, 0, $$cursor_pos_ref));

    $self->{display_lines} = $new_display_lines;
    $self->{last_cursor_row} = $cursor_row;
    $self->{last_cursor_col} = $cursor_col;
    $self->{last_cursor_disp} = $cursor_disp;
    $self->{pending_wrap} = 0;
}

sub readline {
    my ($self, $prompt, %opts) = @_;

    $prompt //= $self->{prompt};

    # Optional event multiplexing
    my $event_callback = $opts{event_callback};
    my $prefill = $opts{prefill} || '';

    # Reset display lines tracking for new input
    $self->{display_lines} = 1;
    $self->{last_cursor_row} = 0;
    $self->{last_cursor_col} = 1;
    $self->{last_cursor_disp} = 0;
    $self->{pending_wrap} = 0;

    # Reset performance caches for this readline session
    $self->{_prompt_disp_cache} = undef;
    $self->{_term_width_cache} = undef;
    $self->{_term_width_time} = 0;

    # Install SIGWINCH handler
    my $resize_flag = 0;
    local $SIG{WINCH} = sub { $resize_flag = 1; };

    # Print prompt
    $self->_emit_text($prompt);

    # Set terminal to raw mode
    ReadMode('raw');

    my $input = $prefill;
    my $cursor_pos = length($prefill);
    my $completion_state = {
        active => 0,
        candidates => [],
        index => 0,
        original_input => '',
    };

    # If pre-filled, display the restored text
    if (length $prefill) {
        $self->_emit_text($prefill);
    }

    while (1) {
        my $char;

        # Handle SIGWINCH before reading
        if ($resize_flag) {
            $resize_flag = 0;
            $self->{_term_width_cache} = undef;
            $self->{_term_width_time} = 0;
            $self->redraw_line(\$input, \$cursor_pos, $prompt);
        }

        if ($event_callback) {
            # Multiplexed mode: poll STDIN + event callback
            while (!defined $char) {
                my $rin = '';
                vec($rin, fileno(STDIN), 1) = 1;

                my $nfound = select(my $rout = $rin, undef, undef, 1.0);

                if ($nfound > 0 && vec($rout, fileno(STDIN), 1)) {
                    $char = ReadKey(-1);
                }

                my $cb_result = $event_callback->();
                if ($cb_result && $cb_result eq 'BREAK') {
                    if (length $input) {
                        $self->_redraw_line_external($prompt, \$input, \$cursor_pos);
                    } else {
                        $self->_emit_newline();
                        ReadMode('restore');
                        return { type => '__AGENT_EVENT__', partial_input => '' };
                    }
                }
                if ($cb_result) {
                    $self->_redraw_line_external($prompt, \$input, \$cursor_pos);
                }
            }
        } else {
            $char = ReadKey(0);

            unless (defined $char) {
                next;
            }
        }

        my $ord = ord($char);

        log_debug('ReadLine', "char='$char' ord=$ord pos=$cursor_pos input='$input'");

        # Tab key (completion)
        if ($ord == 9) {
            $self->handle_tab(\$input, \$cursor_pos, $completion_state, $prompt);
            next;
        }

        # Reset completion state on any non-tab key
        if ($completion_state->{active}) {
            $completion_state->{active} = 0;
            $completion_state->{candidates} = [];
            $completion_state->{index} = 0;
        }

        # Enter key
        if ($ord == 10 || $ord == 13) {
            $self->_emit_newline();
            ReadMode('restore');

            if (length($input) > 0) {
                $self->add_to_history($input);
            }

            return $input;
        }

        # Ctrl-D (EOF)
        if ($ord == 4) {
            if (length($input) == 0) {
                $self->_emit_newline();
                ReadMode('restore');
                return undef;
            }
            if ($cursor_pos < length($input)) {
                substr($input, $cursor_pos, 1, '');
                $self->redraw_line(\$input, \$cursor_pos, $prompt);
            }
            next;
        }

        # Ctrl-C
        if ($ord == 3) {
            $self->_emit_ctrl_c();
            ReadMode('restore');
            kill 'INT', $$;
            return undef;
        }

        # Backspace or Delete (127 = DEL, 8 = BS)
        if ($ord == 127 || $ord == 8) {
            if ($cursor_pos > 0) {
                my $input_len = length($input);
                my $deleting_at_end = ($cursor_pos == $input_len);

                my $deleted_char = substr($input, $cursor_pos - 1, 1);
                my $deleted_width = _display_width($deleted_char);

                substr($input, $cursor_pos - 1, 1, '');
                $cursor_pos--;

                if ($deleting_at_end) {
                    # Optimization: if deleting from end, try the fast-path
                    # (\b \b). Fall back to full redraw when the deletion
                    # crosses a row boundary or involves non-ASCII content.

                    my $term_width = $self->_get_term_width();
                    my $prompt_disp = $self->_get_prompt_disp($prompt);

                    # Compute old and new cursor positions from input state.
                    # We reconstruct the old input by re-inserting the deleted
                    # char at cursor_pos (pre-increment).
                    my $old_input = substr($input, 0, $cursor_pos) . $deleted_char . substr($input, $cursor_pos);
                    my $old_cp = $cursor_pos + 1;
                    my ($old_row, $old_col) = $self->_cursor_at_codepoint($old_input, $old_cp, $prompt);
                    my ($new_row, $new_col) = $self->_cursor_at_codepoint($input, $cursor_pos, $prompt);

                    my $input_disp = _display_width($input);

                    # Fast path is safe when:
                    # - cursor stays on the same row (no wrap boundary crossing)
                    # - deleted char is exactly 1 column (no wide chars)
                    # - remaining input has no wide chars (ASCII-only so
                    #   arithmetic == character-by-character width)
                    if ($old_row == $new_row && $old_col > 1 && $deleted_width == 1 && $input_disp == length($input)) {
                        # Fast path: single-column ASCII at end of line.
                        print "\b \b";

                        # Update tracking.
                        $self->{last_cursor_col} -= 1;
                        if ($self->{pending_wrap}) {
                            $self->{pending_wrap} = 0;
                            # If we were at pending wrap, col is still term_width.
                            # Moving left 1 puts us at term_width - 1.
                        }
                        $self->{last_cursor_col} = 1 if $self->{last_cursor_col} < 1;
                        $self->{last_cursor_disp} = $self->{last_cursor_row} * $term_width + ($self->{last_cursor_col} - 1);

                        # Update display_lines.
                        my $total_disp = $prompt_disp + $input_disp;
                        $self->{display_lines} = $total_disp > 0 ? int(($total_disp - 1) / $term_width) + 1 : 1;
                    } else {
                        $self->redraw_line(\$input, \$cursor_pos, $prompt);
                    }
                } else {
                    # Deleting from middle - full redraw
                    $self->redraw_line(\$input, \$cursor_pos, $prompt);
                }
            }
            next;
        }

        # Escape sequence (arrow keys, function keys, etc.)
        if ($ord == 27) {
            my $seq = $char;

            for my $i (1..5) {
                my $next = ReadKey(0.1);
                last unless defined $next;
                $seq .= $next;

                if ($next =~ /[A-Za-z~]/ || ord($next) == 0x7F) {
                    last;
                }
            }

            log_debug('ReadLine', "Raw escape sequence bytes: " . join(' ', map { sprintf('0x%02X', ord($_)) } split //, $seq));

            $self->handle_escape_sequence($seq, \$input, \$cursor_pos, $prompt);
            next;
        }

        # Ctrl-A (beginning of line)
        if ($ord == 1) {
            my $old_pos = $cursor_pos;
            $cursor_pos = 0;
            $self->reposition_cursor(\$old_pos, \$cursor_pos, \$input, $prompt);
            next;
        }

        # Ctrl-E (end of line)
        if ($ord == 5) {
            my $old_pos = $cursor_pos;
            $cursor_pos = length($input);
            $self->reposition_cursor(\$old_pos, \$cursor_pos, \$input, $prompt);
            next;
        }

        # Ctrl-K (kill to end of line)
        if ($ord == 11) {
            substr($input, $cursor_pos) = '';
            $self->redraw_line(\$input, \$cursor_pos, $prompt);
            next;
        }

        # Ctrl-U (kill to beginning of line)
        if ($ord == 21) {
            substr($input, 0, $cursor_pos) = '';
            $cursor_pos = 0;
            $self->redraw_line(\$input, \$cursor_pos, $prompt);
            next;
        }

        # Ctrl-W (kill word backward)
        if ($ord == 23) {
            $self->_kill_word_backward(\$input, \$cursor_pos, $prompt);
            next;
        }

        # Regular printable character
        if ($ord >= 32 || ($ord >= 128)) {
            if (should_log('DEBUG')) {
                log_debug('ReadLine', "Inserting '$char' at cursor_pos=$cursor_pos, input_len=" . length($input));
                log_debug('ReadLine', "Input before: '$input'");
            }

            my $input_len = length($input);
            my $inserting_at_end = ($cursor_pos == $input_len);

            substr($input, $cursor_pos, 0, $char);
            $cursor_pos++;

            if (should_log('DEBUG')) {
                log_debug('ReadLine', "Input after: '$input', new cursor_pos=$cursor_pos");
            }

            if ($inserting_at_end) {
                $self->_emit_text($char);

                # Update display lines.
                my $term_width = $self->_get_term_width();
                if ($self->{last_cursor_row} >= $self->{display_lines}) {
                    $self->{display_lines} = $self->{last_cursor_row} + 1;
                }
            } else {
                $self->_emit_text($char);
                $self->_redraw_from_cursor(\$input, \$cursor_pos, $prompt);
            }
        }
    }
}

=head2 handle_tab

Handle tab completion

=cut

sub handle_tab {
    my ($self, $input_ref, $cursor_pos_ref, $state, $prompt) = @_;

    return unless $self->{completer};

    my $current_input = $$input_ref;

    log_debug('ReadLine', "Tab pressed, input='$current_input'");

    unless ($state->{active}) {
        $state->{original_input} = $$input_ref;
        $state->{active} = 1;
        $state->{index} = 0;

        my @candidates = $self->{completer}->complete(
            $current_input, $current_input, 0
        );

        $state->{candidates} = \@candidates;

        log_debug('ReadLine', "Found " . scalar(@candidates) . " candidates: @candidates");

        return unless @candidates;

        if (@candidates == 1) {
            $$input_ref = $candidates[0];
            $$cursor_pos_ref = length($$input_ref);
            $self->redraw_line($input_ref, $cursor_pos_ref, $prompt);
            $state->{active} = 0;
            log_debug('ReadLine', "Single match, completed to: '$$input_ref'");
            return;
        }

        $$input_ref = $candidates[0];
        $$cursor_pos_ref = length($$input_ref);
        $self->redraw_line($input_ref, $cursor_pos_ref, $prompt);
        log_debug('ReadLine', "Multiple matches, showing first: '$$input_ref'");

    } else {
        $state->{index}++;

        if ($state->{index} >= scalar(@{$state->{candidates}})) {
            $state->{index} = -1;
            $$input_ref = $state->{original_input};
            log_debug('ReadLine', "Wrapped to original");
        } else {
            $$input_ref = $state->{candidates}->[$state->{index}];
            log_debug('ReadLine', "Cycling to: '$$input_ref'");
        }

        $$cursor_pos_ref = length($$input_ref);
        $self->redraw_line($input_ref, $cursor_pos_ref, $prompt);
    }
}

=head2 handle_escape_sequence

Handle escape sequences (arrow keys, function keys, etc.)

Supported sequences:
- ESC [ A/B/C/D - Arrow keys (up/down/right/left)
- ESC [ 1;5C/D - Ctrl+Right/Left (word forward/backward, standard xterm)
- ESC [ 1;3C/D - Ctrl+Right/Left (Terminal.app sends modifier 3)
- ESC [ 1;2C/D - Shift+Right/Left (word forward/backward)
- ESC [ 1;5A/B - Ctrl+Up/Down (home/end of line)
- ESC [ 5C/D - Ctrl+Right/Left (alternative format)
- ESC b/f - Option+Left/Right (macOS, word movement)
- ESC d - Alt+D (kill word forward)
- ESC DEL - Alt+Backspace (kill word backward)
- ESC [ H / ESC [ 1~ / ESC O H - Home key (beginning of line)
- ESC [ F / ESC [ 4~ / ESC O F - End key (end of line)
- ESC [ 3~ - Delete key (forward delete)

=cut

sub handle_escape_sequence {
    my ($self, $seq, $input_ref, $cursor_pos_ref, $prompt) = @_;

    log_debug('ReadLine', "Escape sequence: " . join(' ', map { sprintf('%02X', ord($_)) } split //, $seq) . " = '$seq'");

    # Arrow keys: ESC [ A/B/C/D
    if ($seq =~ /^\e\[([ABCD])$/) {
        my $dir = $1;

        if ($dir eq 'A') {
            $self->history_prev($input_ref, $cursor_pos_ref, $prompt);
        } elsif ($dir eq 'B') {
            $self->history_next($input_ref, $cursor_pos_ref, $prompt);
        } elsif ($dir eq 'C') {
            if ($$cursor_pos_ref < length($$input_ref)) {
                my $old_pos = $$cursor_pos_ref;
                $$cursor_pos_ref++;
                $self->reposition_cursor(\$old_pos, $cursor_pos_ref, $input_ref, $prompt);
            }
        } elsif ($dir eq 'D') {
            if ($$cursor_pos_ref > 0) {
                my $old_pos = $$cursor_pos_ref;
                $$cursor_pos_ref--;
                $self->reposition_cursor(\$old_pos, $cursor_pos_ref, $input_ref, $prompt);
            }
        }
        return;
    }

    # Modified arrow keys: ESC [ 1 ; MOD C/D
    if ($seq =~ /^\e\[1;([2-8])([ABCD])/) {
        my ($modifier, $dir) = ($1, $2);

        if ($modifier == 5 || $modifier == 3) {
            if ($dir eq 'C') {
                $self->move_word_forward($input_ref, $cursor_pos_ref, $prompt);
            } elsif ($dir eq 'D') {
                $self->move_word_backward($input_ref, $cursor_pos_ref, $prompt);
            } elsif ($dir eq 'A') {
                my $old_pos = $$cursor_pos_ref;
                $$cursor_pos_ref = 0;
                $self->reposition_cursor(\$old_pos, $cursor_pos_ref, $input_ref, $prompt);
            } elsif ($dir eq 'B') {
                my $old_pos = $$cursor_pos_ref;
                $$cursor_pos_ref = length($$input_ref);
                $self->reposition_cursor(\$old_pos, $cursor_pos_ref, $input_ref, $prompt);
            }
        } elsif ($modifier == 2) {
            if ($dir eq 'C') {
                $self->move_word_forward($input_ref, $cursor_pos_ref, $prompt);
            } elsif ($dir eq 'D') {
                $self->move_word_backward($input_ref, $cursor_pos_ref, $prompt);
            }
        }
        return;
    }

    # Alternative format: ESC [ MOD C/D (without "1;")
    if ($seq =~ /^\e\[([5-6])([CD])/) {
        my ($modifier, $dir) = ($1, $2);

        if ($modifier == 5) {
            if ($dir eq 'C') {
                $self->move_word_forward($input_ref, $cursor_pos_ref, $prompt);
            } elsif ($dir eq 'D') {
                $self->move_word_backward($input_ref, $cursor_pos_ref, $prompt);
            }
        } elsif ($modifier == 6) {
            if ($dir eq 'C') {
                my $old_pos = $$cursor_pos_ref;
                $$cursor_pos_ref = length($$input_ref);
                $self->reposition_cursor(\$old_pos, $cursor_pos_ref, $input_ref, $prompt);
            } elsif ($dir eq 'D') {
                my $old_pos = $$cursor_pos_ref;
                $$cursor_pos_ref = 0;
                $self->reposition_cursor(\$old_pos, $cursor_pos_ref, $input_ref, $prompt);
            }
        }
        return;
    }

    # Home key: ESC[H, ESC[1~, ESCOH
    if ($seq =~ /^\e\[H$/ || $seq =~ /^\e\[1~$/ || $seq =~ /^\eOH$/) {
        my $old_pos = $$cursor_pos_ref;
        $$cursor_pos_ref = 0;
        $self->reposition_cursor(\$old_pos, $cursor_pos_ref, $input_ref, $prompt);
        return;
    }

    # End key: ESC[F, ESC[4~, ESCOF
    if ($seq =~ /^\e\[F$/ || $seq =~ /^\e\[4~$/ || $seq =~ /^\eOF$/) {
        my $old_pos = $$cursor_pos_ref;
        $$cursor_pos_ref = length($$input_ref);
        $self->reposition_cursor(\$old_pos, $cursor_pos_ref, $input_ref, $prompt);
        return;
    }

    # Delete key: ESC[3~
    if ($seq =~ /^\e\[3~$/) {
        if ($$cursor_pos_ref < length($$input_ref)) {
            substr($$input_ref, $$cursor_pos_ref, 1, '');
            $self->redraw_line($input_ref, $cursor_pos_ref, $prompt);
        }
        return;
    }

    # Modified Delete key: ESC[3;MOD~
    if ($seq =~ /^\e\[3;([2-8])~$/) {
        my ($modifier) = ($1);

        if ($modifier == 2) {
            $self->_kill_word_backward($input_ref, $cursor_pos_ref, $prompt);
        } elsif ($modifier == 5 || $modifier == 3) {
            $self->_kill_word_forward($input_ref, $cursor_pos_ref, $prompt);
        }
        return;
    }

    # macOS Terminal.app / iTerm2: Option+Left = ESC b, Option+Right = ESC f
    if ($seq =~ /^\eb/) {
        $self->move_word_backward($input_ref, $cursor_pos_ref, $prompt);
        return;
    }
    if ($seq =~ /^\ef/) {
        $self->move_word_forward($input_ref, $cursor_pos_ref, $prompt);
        return;
    }

    # Alt+D / ESC d - kill word forward
    if ($seq =~ /^\ed/) {
        $self->_kill_word_forward($input_ref, $cursor_pos_ref, $prompt);
        return;
    }

    # Alt+Backspace / ESC + DEL (0x7F) - kill word backward
    if ($seq eq "\e\x7f") {
        $self->_kill_word_backward($input_ref, $cursor_pos_ref, $prompt);
        return;
    }
}

=head2 reposition_cursor

Reposition the cursor without redrawing the entire line.

This is used for cursor-only movements (arrows, home/end) where the input
content hasn't changed. Both the source and target positions are computed
from input state via _cursor_at_codepoint — a pure function that walks the
input string to determine the physical (row, col) for any codepoint offset.

Arguments:
- $old_pos_ref: Reference to previous cursor position (BEFORE movement)
- $new_pos_ref: Reference to new cursor position (AFTER movement)
- $input_ref:  Reference to the input string
- $prompt:     Prompt string (for calculating display positions)

=cut

sub reposition_cursor {
    my ($self, $old_pos_ref, $new_pos_ref, $input_ref, $prompt) = @_;

    $prompt //= '';
    my $term_width = $self->_get_term_width();

    # Compute BOTH source and target from input state.
    # This is the key redesign: we never rely on incrementally-tracked
    # last_cursor_* as the source. _cursor_at_codepoint is a pure
    # function — given the same (input, cp, prompt), it always
    # returns the same (row, col).
    my ($old_row, $old_col) = $self->_cursor_at_codepoint($$input_ref, $$old_pos_ref, $prompt);
    my ($new_row, $new_col) = $self->_cursor_at_codepoint($$input_ref, $$new_pos_ref, $prompt);

    if (should_log('DEBUG')) {
        log_debug('ReadLine', "reposition_cursor: old_pos=$$old_pos_ref, new_pos=$$new_pos_ref");
        log_debug('ReadLine', "reposition_cursor: from ($old_row,$old_col) to ($new_row,$new_col)");
        log_debug('ReadLine', "reposition_cursor: both computed via _cursor_at_codepoint from input state");
    }

    # Move from source to target. Use CR + vertical + horizontal for
    # all cross-row movements to avoid pending-wrap ambiguity.
    # For same-row movements, use relative horizontal movement for
    # speed (no visible cursor jump) — safe unless at last column.
    if ($new_row == $old_row && $old_col < $term_width) {
        # Same row, not at last column: relative movement.
        my $delta = $new_col - $old_col;
        if ($delta > 0) {
            print "\e[${delta}C";
        } elsif ($delta < 0) {
            print "\e[" . (-$delta) . "D";
        }
        # delta == 0: already there.
    } else {
        # Cross-row or at last column: CR + vertical + horizontal.
        print "\r";
        if ($new_row != $old_row) {
            if ($new_row > $old_row) {
                print "\e[" . ($new_row - $old_row) . "B";
            } else {
                print "\e[" . ($old_row - $new_row) . "A";
            }
        }
        print "\e[" . ($new_col - 1) . "C" if $new_col > 1;
    }

    # Update tracking for redraw_line's vertical movement.
    $self->{last_cursor_row} = $new_row;
    $self->{last_cursor_col} = $new_col;
    $self->{last_cursor_disp} = $new_row * $term_width + ($new_col - 1);
    $self->{pending_wrap} = 0;

    if (should_log('DEBUG')) {
        log_debug('ReadLine', "reposition_cursor: tracking set to ($new_row,$new_col)");
    }
}

=head2 move_word_forward

Move cursor forward by one word (Shift+Right arrow)

A word is defined as a sequence of non-whitespace characters or whitespace.

=cut

sub move_word_forward {
    my ($self, $input_ref, $cursor_pos_ref, $prompt) = @_;

    my $len = length($$input_ref);
    my $old_pos = $$cursor_pos_ref;
    my $pos = $$cursor_pos_ref;

    return if $pos >= $len;

    my $text = $$input_ref;

    if (substr($text, $pos, 1) =~ /\s/) {
        while ($pos < $len && substr($text, $pos, 1) =~ /\s/) {
            $pos++;
        }
    }

    while ($pos < $len && substr($text, $pos, 1) !~ /\s/) {
        $pos++;
    }

    $$cursor_pos_ref = $pos;
    $self->reposition_cursor(\$old_pos, $cursor_pos_ref, $input_ref, $prompt);
}

=head2 move_word_backward

Move cursor backward by one word (Shift+Left arrow)

A word is defined as a sequence of non-whitespace characters or whitespace.

=cut

sub move_word_backward {
    my ($self, $input_ref, $cursor_pos_ref, $prompt) = @_;

    my $old_pos = $$cursor_pos_ref;
    my $pos = $$cursor_pos_ref;

    return if $pos <= 0;

    my $text = $$input_ref;
    $pos--;

    if (substr($text, $pos, 1) =~ /\s/) {
        while ($pos > 0 && substr($text, $pos, 1) =~ /\s/) {
            $pos--;
        }
    }

    while ($pos > 0 && substr($text, $pos - 1, 1) !~ /\s/) {
        $pos--;
    }

    $$cursor_pos_ref = $pos;
    $self->reposition_cursor(\$old_pos, $cursor_pos_ref, $input_ref, $prompt);
}

=head2 _kill_word_forward

Delete from the cursor to the start of the next word boundary.
Used by Ctrl+Delete, Alt+D, and ESC d.

=cut

sub _kill_word_forward {
    my ($self, $input_ref, $cursor_pos_ref, $prompt) = @_;

    my $len = length($$input_ref);
    return if $$cursor_pos_ref >= $len;

    my $pos = $$cursor_pos_ref;
    while ($pos < $len && substr($$input_ref, $pos, 1) =~ /\s/) {
        $pos++;
    }
    while ($pos < $len && substr($$input_ref, $pos, 1) !~ /\s/) {
        $pos++;
    }
    substr($$input_ref, $$cursor_pos_ref, $pos - $$cursor_pos_ref, '');
    $self->redraw_line($input_ref, $cursor_pos_ref, $prompt);
}

=head2 _kill_word_backward

Delete from the cursor back to the start of the previous word boundary.
Used by Ctrl+W, Alt+Backspace, and Shift+Delete.

=cut

sub _kill_word_backward {
    my ($self, $input_ref, $cursor_pos_ref, $prompt) = @_;

    return if $$cursor_pos_ref <= 0;

    my $old_pos = $$cursor_pos_ref;
    my $pos = $$cursor_pos_ref - 1;
    my $text = $$input_ref;

    # Same word-boundary logic as move_word_backward: only skip whitespace
    # if the character at the starting position is whitespace. The original
    # code checked substr(pos-1) in the first loop, which unconditionally
    # skipped backward whitespace even when the cursor was mid-word (e.g.
    # just after the first character of a word).  That caused Ctrl-W to
    # delete the entire previous word instead of stopping at the current
    # word boundary.
    if (substr($text, $pos, 1) =~ /\s/) {
        while ($pos > 0 && substr($text, $pos, 1) =~ /\s/) {
            $pos--;
        }
    }

    while ($pos > 0 && substr($text, $pos - 1, 1) !~ /\s/) {
        $pos--;
    }

    substr($$input_ref, $pos, $old_pos - $pos, '');
    $$cursor_pos_ref = $pos;
    $self->redraw_line($input_ref, $cursor_pos_ref, $prompt);
}

=head2 history_prev

Go to previous history entry

=cut

sub history_prev {
    my ($self, $input_ref, $cursor_pos_ref, $prompt) = @_;

    return unless defined $self->{history} && ref($self->{history}) eq 'ARRAY';
    return unless @{$self->{history}};

    if ($self->{history_pos} == -1) {
        $self->{current_input} = $$input_ref;
        $self->{history_pos} = scalar(@{$self->{history}}) - 1;
    } elsif ($self->{history_pos} > 0) {
        $self->{history_pos}--;
    } else {
        return;
    }

    if ($self->{history_pos} < 0 || $self->{history_pos} >= scalar(@{$self->{history}})) {
        log_debug('ReadLine', "History position out of bounds: $self->{history_pos}");
        $self->{history_pos} = -1;
        return;
    }

    $$input_ref = $self->{history}->[$self->{history_pos}] // '';
    $$cursor_pos_ref = length($$input_ref);
    $self->redraw_line($input_ref, $cursor_pos_ref, $prompt);
}

=head2 history_next

Go to next history entry

=cut

sub history_next {
    my ($self, $input_ref, $cursor_pos_ref, $prompt) = @_;

    return if $self->{history_pos} == -1;

    return unless defined $self->{history} && ref($self->{history}) eq 'ARRAY';

    $self->{history_pos}++;

    if ($self->{history_pos} >= scalar(@{$self->{history}})) {
        $$input_ref = $self->{current_input} // '';
        $self->{history_pos} = -1;
    } else {
        if ($self->{history_pos} < 0 || $self->{history_pos} >= scalar(@{$self->{history}})) {
            log_debug('ReadLine', "History position out of bounds: $self->{history_pos}");
            $$input_ref = $self->{current_input} // '';
            $self->{history_pos} = -1;
        } else {
            $$input_ref = $self->{history}->[$self->{history_pos}] // '';
        }
    }

    $$cursor_pos_ref = length($$input_ref);
    $self->redraw_line($input_ref, $cursor_pos_ref, $prompt);
}

=head2 add_to_history

Add a line to command history

=cut

sub add_to_history {
    my ($self, $line) = @_;

    $self->{history_pos} = -1;

    if (@{$self->{history}} && $self->{history}->[-1] eq $line) {
        return;
    }

    push @{$self->{history}}, $line;

    if (@{$self->{history}} > $self->{max_history}) {
        shift @{$self->{history}};
    }
}

1;

__END__

=head1 USAGE

    use CLIO::Core::ReadLine;
    use CLIO::Core::TabCompletion;

    my $completer = CLIO::Core::TabCompletion->new();
    my $rl = CLIO::Core::ReadLine->new(
        prompt => 'YOU: ',
        completer => $completer,
        debug => 0
    );

    while (defined(my $input = $rl->readline())) {
        print "You said: $input\n";
    }

=head1 AUTHOR

Fewtarius

=head1 LICENSE

See main CLIO LICENSE file.
1;
