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
        # Track how many terminal lines the current input occupies
        # This is MEASURED (from last redraw), not calculated
        display_lines => 1,
        # Actual terminal cursor position (0-indexed row, 1-indexed col).
        # This is what the terminal physically shows - NOT a logical guess
        # based on input length. Updated whenever we emit any cursor
        # movement or text.
        last_cursor_row => 0,
        last_cursor_col => 1,
        # Absolute (0-indexed) display column of the cursor in the last paint.
        # Used to compute incremental horizontal movement without flashing
        # to column 1. Updated whenever we emit any cursor positioning.
        last_cursor_disp => 0,
        # True when the terminal is in the VT100 "pending wrap" state: we
        # just emitted exactly N*term_width columns and the next printed
        # character will wrap to column 1 of the next row. Cursor
        # physically sits at (last row, term_width) until then.
        #
        # This flag is the single source of truth that fixes the
        # "text corrupts crossing wrap boundary" and "shift+arrow then
        # type appends to end" bugs - before this existed, the code
        # computed cursor position from _pos_to_rowcol(input_length)
        # which incorrectly assumed pending-wrap state even after the
        # terminal had already wrapped.
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

=head2 _redraw_from_cursor

Partial redraw: reprint from cursor position to end of input, then
clear any leftover characters and reposition the cursor. The caller
must have already printed any new content (e.g., an inserted character)
so the terminal cursor is at the correct starting point.

=cut

sub _redraw_from_cursor {
    my ($self, $input_ref, $cursor_pos_ref, $prompt) = @_;

    my $term_width = $self->_get_term_width();
    my $prompt_disp = $self->_get_prompt_disp($prompt);

    # Print everything after cursor, then clear leftover chars.
    # _emit_text handles wide-char widths and pending wrap correctly.
    my $tail = substr($$input_ref, $$cursor_pos_ref);
    $self->_emit_text($tail);
    print "\e[J";

    # Calculate where the cursor IS now (end of input) and where it
    # SHOULD be. _pos_to_rowcol needs to know whether pending_wrap is
    # set so the target reflects the post-emit physical position.
    my $total_disp = $prompt_disp + _display_width($$input_ref);
    my $cursor_disp = $prompt_disp + _display_width(substr($$input_ref, 0, $$cursor_pos_ref));

    # After emitting the tail, last_cursor_* reflects the end position
    # of the input. We need to move from there to where the cursor
    # should land (just after the inserted char).
    my $end_row = $self->{last_cursor_row};
    my $end_col = $self->{last_cursor_col};

    # Target: row/col for cursor_pos in the input. _pos_to_rowcol is
    # safe to call here because there's no pending_wrap at the cursor
    # position - cursor_pos always sits at an "ordinary" column.
    my ($target_row, $target_col) = $self->_pos_to_rowcol($cursor_disp, 0);

    # Move vertically (if needed) using absolute offsets. After vertical
    # movement the terminal cursor is at column 1 of the target row, so
    # the horizontal positioning below is correct.
    if ($target_row < $end_row) {
        my $up = $end_row - $target_row;
        print "\e[${up}A";
        $self->{last_cursor_row} = $target_row;
        $self->{pending_wrap} = 0;
    } elsif ($target_row > $end_row) {
        my $down = $target_row - $end_row;
        print "\e[${down}B";
        $self->{last_cursor_row} = $target_row;
        $self->{pending_wrap} = 0;
    }

    # Horizontal: carriage return + advance to $target_col (1-indexed).
    print "\r";
    if ($target_col > 1) {
        print "\e[" . ($target_col - 1) . "C";
    }
    $self->{last_cursor_col} = $target_col;
    $self->{last_cursor_disp} = $cursor_disp;
    $self->{pending_wrap} = 0;

    # Update display_lines.
    my $new_display_lines = $total_disp > 0
        ? int(($total_disp - 1) / $term_width) + 1
        : 1;
    $self->{display_lines} = $new_display_lines;
}

=head2 _pos_to_rowcol

Convert an absolute (0-indexed) display column to a (row, col) pair.

The conversion respects the VT100 "pending wrap" state. Pending wrap means
the terminal just emitted exactly N*term_width columns and the next
printed character will wrap to column 1 of the next row. Cursor
physically sits at (row N-1, col term_width) until then.

The caller passes the current pending_wrap flag as the third argument.
When pending_wrap is true, pos is forced to "row N-1, col term_width"
even when it falls on a wrap boundary.

Returns: ($row, $col) where $row is 0-indexed and $col is 1-indexed.

=cut

sub _pos_to_rowcol {
    my ($self, $pos, $pending) = @_;
    $pending //= 0;
    my $term_width = $self->_get_term_width();
    if ($pos == 0) {
        # Empty line: cursor at col 1 row 0.
        return (0, 1);
    }
    my ($row, $col);
    if ($pos > 0 && $pos % $term_width == 0) {
        # Wrap boundary. Position is either:
        #   pending-wrap: cursor at last col of previous row
        #   after-wrap:   cursor at col 1 of current row (just past the wrap,
        #                 no char placed at this position yet)
        if ($pending) {
            $row = int($pos / $term_width) - 1;
            $col = $term_width;
        } else {
            $row = int($pos / $term_width);
            $col = 1;
        }
    } else {
        $row = int($pos / $term_width);
        $col = ($pos % $term_width) + 1;
    }
    return ($row, $col);
}

=head2 _cursor_at_codepoint

Compute the physical (row, col) that the cursor would be at if it sat
at codepoint $cp in $input. Starts at (0, 1+prompt_disp) and walks through
each codepoint, tracking wraps.

This is the ground truth for "where the cursor sits at cp". Use this
in reposition_cursor instead of computing (prompt + cp) and translating
through _pos_to_rowcol - which gets the wrap accounting wrong by 1 col.

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

This is the single source of truth for cursor position. Every place
that prints text must route through here so that arrow-key navigation,
Ctrl+W, and redraw_line all see the *physical* terminal cursor position
rather than a logical guess derived from input length.

The terminal-emulator model:
  - Cursor has a (row, col) position (col is 1-indexed).
  - Print a char at (row, col); col advances by char width.
  - If col exceeds term_width after a print, wrap to (row+1, 1) and
    place remaining char(s) there.
  - If the cursor sits at exactly col=term_width, it's in pending-wrap
    state: the next print wraps first.

=cut

sub _emit_text {
    my ($self, $text) = @_;
    return unless defined $text && length $text;

    my $term_width = $self->_get_term_width();
    my $row = $self->{last_cursor_row};
    my $col = $self->{last_cursor_col};
    my $pending = $self->{pending_wrap};

    for my $i (0 .. length($text) - 1) {
        my $ch = substr($text, $i, 1);
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
        print $ch;
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

=head2 _emit_move

Emit a relative cursor movement (no text) and update tracking.

$rows and $cols are signed offsets. Negative rows move up, positive down.
Positive cols move right, negative left. Either may be 0.

Pending wrap is cleared on any movement (the terminal cursor is now at
a definite position).

=cut

sub _emit_move {
    my ($self, $drows, $dcols) = @_;
    my $term_width = $self->_get_term_width();
    my $row = $self->{last_cursor_row};
    my $col = $self->{last_cursor_col};

    # Pending wrap is implicitly resolved by any movement: the cursor
    # is now at an absolute position, not the "between rows" limbo.
    if ($self->{pending_wrap}) {
        $row += 1;
        $col = 1;
    }

    $row += $drows;
    $col += $dcols;

    # Clamp to non-negative.
    $row = 0 if $row < 0;
    $col = 1 if $col < 1;
    $col = $term_width if $col > $term_width;

    $self->{last_cursor_row} = $row;
    $self->{last_cursor_col} = $col;
    $self->{last_cursor_disp} = $row * $term_width + ($col - 1);
    $self->{pending_wrap} = 0;
}

=head2 _emit_cursor_to

Move the cursor to an absolute (row, col) and update tracking.
Row is 0-indexed; col is 1-indexed.

=cut

sub _emit_cursor_to {
    my ($self, $row, $col) = @_;
    $self->{last_cursor_row} = $row;
    $self->{last_cursor_col} = $col;
    $self->{last_cursor_disp} = $row * $self->_get_term_width() + ($col - 1);
    $self->{pending_wrap} = 0;
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

sub readline {
    my ($self, $prompt, %opts) = @_;
    
    $prompt //= $self->{prompt};
    
    # Optional event multiplexing: when event_callback is provided, use select()
    # on STDIN with a 1-second timeout, polling the callback each cycle.
    # This is the "doevents()" pattern from PhotonBBS - the broker uses
    # request-response protocol so we poll on a timer, not watch the socket fd.
    my $event_callback = $opts{event_callback};  # coderef, returns true if redraw needed
    my $prefill = $opts{prefill} || '';  # Pre-fill input buffer (restored after agent interrupt)

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

    # Install SIGWINCH handler: terminal width changes invalidate our
    # cached width and require a redraw of the current input line so the
    # cursor lands at the correct column on the new layout.
    my $resize_flag = 0;
    local $SIG{WINCH} = sub { $resize_flag = 1; };
    
    # Print prompt
    $self->_emit_text($prompt);

    # Set terminal to raw mode
    ReadMode('raw');

    my $input = $prefill;
    my $cursor_pos = length($prefill);  # Position in $input
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
        # Read next character - either blocking (normal) or multiplexed (with event_callback)
        my $char;

        # Handle SIGWINCH before reading: if the terminal resized while we
        # were idle, invalidate cached width and force a full redraw.
        if ($resize_flag) {
            $resize_flag = 0;
            $self->{_term_width_cache} = undef;
            $self->{_term_width_time} = 0;
            # Force redraw on next keystroke
            $self->redraw_line(\$input, \$cursor_pos, $prompt);
        }

        if ($event_callback) {
            # Multiplexed mode: use select() on STDIN with periodic callback
            # Inspired by PhotonBBS's alarm(1) + doevents() pattern.
            # The broker uses request-response protocol (not push), so we poll
            # the callback on a timer rather than watching the broker fd.
            while (!defined $char) {
                my $rin = '';
                vec($rin, fileno(STDIN), 1) = 1;
                
                # Wait up to 1 second for STDIN, then poll events
                my $nfound = select(my $rout = $rin, undef, undef, 1.0);
                
                # Check STDIN for user keypress
                if ($nfound > 0 && vec($rout, fileno(STDIN), 1)) {
                    $char = ReadKey(-1);  # Non-blocking read, data should be available
                }
                
                # Poll event callback (broker events, agent messages, etc.)
                # Returns: 0 = nothing, 1 = redraw needed, "BREAK" = abort readline
                my $cb_result = $event_callback->();
                if ($cb_result && $cb_result eq 'BREAK') {
                    # Agent event requires AI attention - abort readline
                    if (length $input) {
                        # User has typed something - don't interrupt them.
                        # Redraw the prompt and their input after the event display.
                        $self->_redraw_line_external($prompt, \$input, \$cursor_pos);
                    } else {
                        # No user input yet - safe to hand control to AI
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
            # Normal mode: blocking read (exact same behavior as before)
            $char = ReadKey(0);
            
            # Handle undefined - can happen if sysread is interrupted by signal
            unless (defined $char) {
                # ReadKey can return undef when sysread() is interrupted
                # by a signal (EINTR). This is NORMAL and should just retry.
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
            $self->_emit_newline();  # Return to column 0 and newline
            ReadMode('restore');

            # Add to history if non-empty
            if (length($input) > 0) {
                $self->add_to_history($input);
            }

            return $input;
        }

        # Ctrl-D (EOF)
        if ($ord == 4) {
            if (length($input) == 0) {
                $self->_emit_newline();  # Return to column 0 and newline
                ReadMode('restore');
                return undef;
            }
            # Ctrl-D with text: forward delete (standard terminal behavior)
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
            # Raise actual SIGINT so session cleanup handlers can run
            # This allows the main signal handler to save session state
            kill 'INT', $$;  # Send SIGINT to self
            # If handler returns (shouldn't), return undef as fallback
            return undef;
        }
        
        # Backspace or Delete (127 = DEL, 8 = BS)
        if ($ord == 127 || $ord == 8) {
            if ($cursor_pos > 0) {
                # Check if we're deleting from the end
                my $input_len = length($input);
                my $deleting_at_end = ($cursor_pos == $input_len);

                # Capture the character being deleted BEFORE removing it,
                # so we can calculate its display width for the fast-path erase.
                my $deleted_char = substr($input, $cursor_pos - 1, 1);
                my $deleted_width = _display_width($deleted_char);

                # Remove the character before cursor (one Perl codepoint = one character)
                substr($input, $cursor_pos - 1, 1, '');
                $cursor_pos--;

                if ($deleting_at_end) {
                    # Optimization: if deleting from end, we can handle it
                    # locally. Avoids full redraw for the common single-
                    # column-ASCII case.

                    my $term_width = $self->_get_term_width();
                    my $prompt_disp = $self->_get_prompt_disp($prompt);
                    my $input_before = substr($input, 0, $cursor_pos);  # after decrement
                    my $cursor_disp  = _display_width($input_before);

                    # Display-column positions of old and new cursor.
                    my $old_total_pos = $prompt_disp + $cursor_disp + $deleted_width;
                    my $new_total_pos = $prompt_disp + $cursor_disp;

                    my $old_row = int($old_total_pos / $term_width);
                    my $new_row = int($new_total_pos / $term_width);

                    # Use full redraw when:
                    # - row changes (unwrap across line boundary)
                    # - landing on an exact boundary (pending wrap ambiguity)
                    # - the deleted character was wide (>1 col)
                    # - the remaining input contains any wide chars (CJK, emoji, etc.)
                    #   The fast-path \b \b sequence moves the cursor exactly 1 column.
                    #   When wide characters are present, the cursor may land inside a
                    #   2-column cell, which terminals handle inconsistently and can
                    #   leave visual ghost characters on screen.
                    # - wrap tightens: old_row == new_row BUT total display
                    #   width drops by enough that the previous wrap boundary
                    #   disappears. Without redraw the orphan chars stay on
                    #   screen (this was bug #2).
                    my $wrap_tightened = ($old_row == $new_row)
                        && ($old_total_pos % $term_width == 0 || $old_total_pos > $term_width);
                    if ($old_row > $new_row ||
                        ($new_total_pos > 0 && $new_total_pos % $term_width == 0) ||
                        $deleted_width > 1 ||
                        _display_width($input) != length($input) ||
                        $wrap_tightened)
                    {
                        $self->redraw_line(\$input, \$cursor_pos, $prompt);
                    } else {
                        # Fast path: single-column ASCII character at end of line.
                        # Move back, overwrite with space, move back again.
                        print "\b \b";

                        # Update cursor tracking using actual physical
                        # position. The terminal cursor moved left by 1
                        # column from where it was.
                        if ($self->{pending_wrap}) {
                            # Cursor was at last col of previous row in
                            # pending-wrap. \b moves left within row.
                            $self->{last_cursor_col} -= 1;
                            $self->{pending_wrap} = 0;
                        } else {
                            $self->{last_cursor_col} -= 1;
                        }
                        $self->{last_cursor_col} = 1 if $self->{last_cursor_col} < 1;
                        $self->{last_cursor_disp} = $self->{last_cursor_row} * $term_width + ($self->{last_cursor_col} - 1);

                        # Update display_lines to match actual content
                        my $total_disp = $prompt_disp + _display_width($input);
                        my $new_display_lines = $total_disp > 0 ? int(($total_disp - 1) / $term_width) + 1 : 1;
                        $self->{display_lines} = $new_display_lines;
                    }
                } else {
                    # Deleting from middle - need full redraw
                    $self->redraw_line(\$input, \$cursor_pos, $prompt);
                }
            }
            next;
        }
        
        # Escape sequence (arrow keys, function keys, etc.)
        if ($ord == 27) {
            # Read escape sequence - can be variable length:
            # - Simple: ESC [ A (3 bytes total)
            # - Modified arrows: ESC [ 1 ; 5 C (6 bytes total) - Ctrl+Arrow
            # - Modified arrows: ESC [ 1 ; 2 C (6 bytes total) - Shift+Arrow
            # - Function keys and other: ESC [ ... ~ (variable)
            
            # Start building the sequence
            my $seq = $char;  # Start with ESC
            
            # Read additional bytes with a reasonable timeout
            # Different terminals send sequences at different speeds
            # 100ms per byte balances responsive single-keypress handling
            # against slow SSH sessions. Total worst case is 5 * 100ms =
            # 500ms, matching readline convention. Modern terminals send
            # complete sequences in well under 50ms.
            for my $i (1..5) {
                my $next = ReadKey(0.1);  # 100ms timeout between bytes
                last unless defined $next;
                $seq .= $next;
                
                # Stop if we've completed the sequence:
                # - letter or ~ (standard CSI/SS3 terminators)
                # - DEL (0x7F) for Alt+Backspace (ESC + DEL)
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
        
        # Ctrl-W (kill word backward - standard terminal binding)
        if ($ord == 23) {
            $self->_kill_word_backward(\$input, \$cursor_pos, $prompt);
            next;
        }
        
        # Regular printable character (including multi-byte UTF-8)
        # Allow any character not caught by special handlers above
        # For multi-byte UTF-8 chars, ReadKey already assembled the full codepoint.
        # For single-byte ASCII, $ord will be >= 32.
        if ($ord >= 32 || ($ord >= 128)) {
            if (should_log('DEBUG')) {
                log_debug('ReadLine', "Inserting '$char' at cursor_pos=$cursor_pos, input_len=" . length($input));
                log_debug('ReadLine', "Input before: '$input'");
            }

            my $input_len = length($input);
            my $inserting_at_end = ($cursor_pos == $input_len);

            substr($input, $cursor_pos, 0, $char);
            $cursor_pos++;  # Advance by 1 character (codepoint), not byte count

            if (should_log('DEBUG')) {
                log_debug('ReadLine', "Input after: '$input', new cursor_pos=$cursor_pos");
            }

            if ($inserting_at_end) {
                # Optimization: if inserting at end, just print the character.
                # This avoids full redraw and prevents scroll issues when wrapping.
                $self->_emit_text($char);

                # Update display lines if we wrapped to a new line.
                my $term_width = $self->_get_term_width();
                if ($self->{last_cursor_row} >= $self->{display_lines}) {
                    $self->{display_lines} = $self->{last_cursor_row} + 1;
                }
            } else {
                # Inserting in middle: print the new char (advances terminal
                # cursor past it), then redraw the remaining tail and
                # reposition the cursor back.
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
    
    # First tab - initialize completion
    unless ($state->{active}) {
        $state->{original_input} = $$input_ref;
        $state->{active} = 1;
        $state->{index} = 0;
        
        # Pass full line to completer - it handles all context parsing
        my @candidates = $self->{completer}->complete(
            $current_input,     # text being completed (full line)
            $current_input,     # full line
            0                   # start position
        );
        
        $state->{candidates} = \@candidates;
        
        log_debug('ReadLine', "Found " . scalar(@candidates) . " candidates: @candidates");
        
        # No candidates - beep or do nothing
        return unless @candidates;
        
        # Single candidate - complete it
        if (@candidates == 1) {
            $$input_ref = $candidates[0];
            $$cursor_pos_ref = length($$input_ref);
            $self->redraw_line($input_ref, $cursor_pos_ref, $prompt);
            $state->{active} = 0;  # Done
            log_debug('ReadLine', "Single match, completed to: '$$input_ref'");
            return;
        }
        
        # Multiple candidates - show first one
        $$input_ref = $candidates[0];
        $$cursor_pos_ref = length($$input_ref);
        $self->redraw_line($input_ref, $cursor_pos_ref, $prompt);
        log_debug('ReadLine', "Multiple matches, showing first: '$$input_ref'");
        
    } else {
        # Subsequent tabs - cycle through candidates
        $state->{index}++;
        
        # Wrap around
        if ($state->{index} >= scalar(@{$state->{candidates}})) {
            # Back to original
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
            # Up arrow - previous history
            $self->history_prev($input_ref, $cursor_pos_ref, $prompt);
        } elsif ($dir eq 'B') {
            # Down arrow - next history
            $self->history_next($input_ref, $cursor_pos_ref, $prompt);
        } elsif ($dir eq 'C') {
            # Right arrow - move one character right
            if ($$cursor_pos_ref < length($$input_ref)) {
                my $old_pos = $$cursor_pos_ref;
                $$cursor_pos_ref++;
                $self->reposition_cursor(\$old_pos, $cursor_pos_ref, $input_ref, $prompt);
            }
        } elsif ($dir eq 'D') {
            # Left arrow - move one character left
            if ($$cursor_pos_ref > 0) {
                my $old_pos = $$cursor_pos_ref;
                $$cursor_pos_ref--;
                $self->reposition_cursor(\$old_pos, $cursor_pos_ref, $input_ref, $prompt);
            }
        }
        return;
    }
    
    # Modified arrow keys - standard xterm format: ESC [ 1 ; MOD C/D
    # Modifiers: 2=Shift, 3=Alt, 4=Shift+Alt, 5=Ctrl, 6=Ctrl+Shift, 7=Ctrl+Alt, 8=Ctrl+Shift+Alt
    # NOTE: Terminal.app sends modifier 3 for Ctrl, not the standard modifier 5
    if ($seq =~ /^\e\[1;([2-8])([ABCD])/) {
        my ($modifier, $dir) = ($1, $2);
        
        if ($modifier == 5 || $modifier == 3) {
            # Ctrl modifier (5=standard xterm, 3=Terminal.app)
            if ($dir eq 'C') {
                # Ctrl+Right - move word forward (standard terminal behavior)
                $self->move_word_forward($input_ref, $cursor_pos_ref, $prompt);
            } elsif ($dir eq 'D') {
                # Ctrl+Left - move word backward (standard terminal behavior)
                $self->move_word_backward($input_ref, $cursor_pos_ref, $prompt);
            } elsif ($dir eq 'A') {
                # Ctrl+Up - move to beginning of line
                my $old_pos = $$cursor_pos_ref;
                $$cursor_pos_ref = 0;
                $self->reposition_cursor(\$old_pos, $cursor_pos_ref, $input_ref, $prompt);
            } elsif ($dir eq 'B') {
                # Ctrl+Down - move to end of line
                my $old_pos = $$cursor_pos_ref;
                $$cursor_pos_ref = length($$input_ref);
                $self->reposition_cursor(\$old_pos, $cursor_pos_ref, $input_ref, $prompt);
            }
        } elsif ($modifier == 2) {
            # Shift modifier
            if ($dir eq 'C') {
                # Shift+Right - move word forward
                $self->move_word_forward($input_ref, $cursor_pos_ref, $prompt);
            } elsif ($dir eq 'D') {
                # Shift+Left - move word backward
                $self->move_word_backward($input_ref, $cursor_pos_ref, $prompt);
            }
        }
        return;
    }
    
    # Alternative format (some terminals): ESC [ MOD C/D (without the "1;")
    if ($seq =~ /^\e\[([5-6])([CD])/) {
        my ($modifier, $dir) = ($1, $2);
        
        if ($modifier == 5) {
            # Ctrl modifier
            if ($dir eq 'C') {
                # Ctrl+Right - move word forward
                $self->move_word_forward($input_ref, $cursor_pos_ref, $prompt);
            } elsif ($dir eq 'D') {
                # Ctrl+Left - move word backward
                $self->move_word_backward($input_ref, $cursor_pos_ref, $prompt);
            }
        } elsif ($modifier == 6) {
            # Ctrl+Shift modifier
            if ($dir eq 'C') {
                # Ctrl+Shift+Right - move to end of line
                my $old_pos = $$cursor_pos_ref;
                $$cursor_pos_ref = length($$input_ref);
                $self->reposition_cursor(\$old_pos, $cursor_pos_ref, $input_ref, $prompt);
            } elsif ($dir eq 'D') {
                # Ctrl+Shift+Left - move to beginning of line
                my $old_pos = $$cursor_pos_ref;
                $$cursor_pos_ref = 0;
                $self->reposition_cursor(\$old_pos, $cursor_pos_ref, $input_ref, $prompt);
            }
        }
        return;
    }
    
    # Home key: ESC[H, ESC[1~, ESCOH (xterm application mode)
    if ($seq =~ /^\e\[H$/ || $seq =~ /^\e\[1~$/ || $seq =~ /^\eOH$/) {
        my $old_pos = $$cursor_pos_ref;
        $$cursor_pos_ref = 0;
        $self->reposition_cursor(\$old_pos, $cursor_pos_ref, $input_ref, $prompt);
        return;
    }
    
    # End key: ESC[F, ESC[4~, ESCOF (xterm application mode)
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
    # Modifier 2=Shift, 5=Ctrl (xterm), 3=Ctrl (Terminal.app).
    # Shift+Delete = delete word backward (mirrors Shift+Left which moves
    # word backward). Ctrl+Delete = delete word forward (mirrors
    # Ctrl+Right which moves word forward).
    if ($seq =~ /^\e\[3;([2-8])~$/) {
        my ($modifier) = ($1);

        if ($modifier == 2) {
            # Shift+Delete - delete word backward
            $self->_kill_word_backward($input_ref, $cursor_pos_ref, $prompt);
        } elsif ($modifier == 5 || $modifier == 3) {
            # Ctrl+Delete - delete word forward
            $self->_kill_word_forward($input_ref, $cursor_pos_ref, $prompt);
        }
        return;
    }
    
    # macOS Terminal.app / iTerm2: Option+Left = ESC b, Option+Right = ESC f
    if ($seq =~ /^\eb/) {
        # Option+Left - move word backward
        $self->move_word_backward($input_ref, $cursor_pos_ref, $prompt);
        return;
    }
    if ($seq =~ /^\ef/) {
        # Option+Right - move word forward
        $self->move_word_forward($input_ref, $cursor_pos_ref, $prompt);
        return;
    }
    
    # Alt+D / ESC d - kill word forward (standard readline binding)
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

=head2 move_word_forward

Move cursor forward by one word (Shift+Right arrow)

A word is defined as a sequence of non-whitespace characters or whitespace.

=cut

sub move_word_forward {
    my ($self, $input_ref, $cursor_pos_ref, $prompt) = @_;
    
    my $len = length($$input_ref);
    my $old_pos = $$cursor_pos_ref;
    my $pos = $$cursor_pos_ref;
    
    return if $pos >= $len;  # Already at end
    
    my $text = $$input_ref;
    
    # If we're on whitespace, skip all whitespace
    if (substr($text, $pos, 1) =~ /\s/) {
        while ($pos < $len && substr($text, $pos, 1) =~ /\s/) {
            $pos++;
        }
    }
    
    # Now skip non-whitespace characters
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
    
    return if $pos <= 0;  # Already at beginning
    
    my $text = $$input_ref;
    $pos--;  # Move back one position first
    
    # If we're on whitespace, skip all whitespace backward
    if (substr($text, $pos, 1) =~ /\s/) {
        while ($pos > 0 && substr($text, $pos, 1) =~ /\s/) {
            $pos--;
        }
    }
    
    # Now skip non-whitespace characters backward
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
    # Skip whitespace forward, then non-whitespace forward.
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
    # Skip whitespace backward, then non-whitespace backward.
    while ($pos > 0 && substr($$input_ref, $pos - 1, 1) =~ /\s/) {
        $pos--;
    }
    while ($pos > 0 && substr($$input_ref, $pos - 1, 1) !~ /\s/) {
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
    
    # Safety: validate history array is accessible
    return unless defined $self->{history} && ref($self->{history}) eq 'ARRAY';
    return unless @{$self->{history}};
    
    # First time - save current input
    if ($self->{history_pos} == -1) {
        $self->{current_input} = $$input_ref;
        $self->{history_pos} = scalar(@{$self->{history}}) - 1;
    } elsif ($self->{history_pos} > 0) {
        $self->{history_pos}--;
    } else {
        return;  # Already at oldest
    }
    
    # Safety: bounds check before array access
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
    
    return if $self->{history_pos} == -1;  # Not in history
    
    # Safety: validate history array is accessible
    return unless defined $self->{history} && ref($self->{history}) eq 'ARRAY';
    
    $self->{history_pos}++;
    
    if ($self->{history_pos} >= scalar(@{$self->{history}})) {
        # Back to current input
        $$input_ref = $self->{current_input} // '';
        $self->{history_pos} = -1;
    } else {
        # Safety: bounds check before array access
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

=head2 reposition_cursor

Reposition the cursor without redrawing the entire line.

This is used for cursor-only movements (arrows, home/end) where the input
content hasn't changed. We ONLY move the cursor up when we're moving from
a lower line to an upper line - NOT just because cursor is before end.

Arguments:
- $old_pos_ref: Reference to previous cursor position (BEFORE movement)
- $new_pos_ref: Reference to new cursor position (AFTER movement)
- $prompt: Prompt string (for calculating display positions)

=cut

sub reposition_cursor {
    my ($self, $old_pos_ref, $new_pos_ref, $input_ref, $prompt) = @_;

    $prompt //= '';

    my $term_width = $self->_get_term_width();
    my $prompt_disp = $self->_get_prompt_disp($prompt);

    # The terminal cursor is currently at the *physical* position stored
    # in last_cursor_row/col. Use the tracked position as the source of
    # truth for "where we are now".
    my $old_row = $self->{last_cursor_row};
    my $old_col = $self->{last_cursor_col};
    my $old_pending = $self->{pending_wrap};

    # Target row/col: walk from start of input to new_pos codepoints,
    # tracking row/col as we go. This gives the actual physical cursor
    # position for the new cursor_pos, accounting for all wraps.
    my ($new_row, $new_col) = $self->_cursor_at_codepoint($$input_ref, $$new_pos_ref);

    if (should_log('DEBUG')) {
        log_debug('ReadLine', "reposition_cursor: old_pos=$$old_pos_ref, new_pos=$$new_pos_ref");
        log_debug('ReadLine', "reposition_cursor: from ($old_row,$old_col,pending=$old_pending) to ($new_row,$new_col)");
    }

    # Emit cursor movement using the tracked physical position.
    if ($old_pending) {
        # We were in pending-wrap state. Any movement resolves it.
        # The pending wrap goes to (old_row+1, 1). Apply the row delta.
        my $effective_old_row = $old_row + 1;
        my $effective_old_col = 1;
        if ($new_row < $effective_old_row) {
            my $up = $effective_old_row - $new_row;
            print "\e[${up}A";
        } elsif ($new_row > $effective_old_row) {
            my $down = $new_row - $effective_old_row;
            print "\e[${down}B";
        }
        # Same effective row: print CR + advance.
        print "\r";
        print "\e[" . ($new_col - 1) . "C" if $new_col > 1;
    } else {
        # Standard case: move from (old_row, old_col) to (new_row, new_col).
        if ($new_row < $old_row) {
            my $up = $old_row - $new_row;
            print "\e[${up}A";
            print "\r";
            print "\e[" . ($new_col - 1) . "C" if $new_col > 1;
        } elsif ($new_row > $old_row) {
            my $down = $new_row - $old_row;
            print "\e[${down}B";
            print "\r";
            print "\e[" . ($new_col - 1) . "C" if $new_col > 1;
        } else {
            # Same row. Use incremental movement from tracked column.
            my $delta = $new_col - $old_col;
            if ($delta > 0) {
                print "\e[${delta}C";
            } elsif ($delta < 0) {
                my $abs = -$delta;
                print "\e[${abs}D";
            }
            # delta == 0: already there.
        }
    }

    # Update tracked cursor position to reflect the move.
    $self->{last_cursor_row}  = $new_row;
    $self->{last_cursor_col}  = $new_col;
    $self->{last_cursor_disp} = $new_row * $term_width + ($new_col - 1);
    $self->{pending_wrap} = 0;

    if (should_log('DEBUG')) {
        log_debug('ReadLine', "reposition_cursor: saved last_cursor=($new_row,$new_col)");
    }
}

=head2 redraw_line

Redraw the input line with cursor at correct position.

This method performs a FULL clear-and-redraw of the input line. It should ONLY
be called when the input CONTENT has changed (character added/deleted, text replaced).

For cursor-only movements (arrows, home/end), use reposition_cursor() instead.

Uses natural terminal wrapping instead of cursor positioning arithmetic.
Tracks the number of lines occupied by the input display and clears them
before redrawing, avoiding artifacts from cursor movement.

=cut

sub redraw_line {
    my ($self, $input_ref, $cursor_pos_ref, $prompt) = @_;

    # Defensive: ensure prompt is defined (should never happen, but prevents warnings)
    $prompt //= '';

    # Safety: clamp cursor position to valid range (0 to length of input)
    my $input_len = length($$input_ref);
    if ($$cursor_pos_ref < 0) {
        log_debug('ReadLine', "Cursor position was negative ($$cursor_pos_ref), clamping to 0");
        $$cursor_pos_ref = 0;
    } elsif ($$cursor_pos_ref > $input_len) {
        log_debug('ReadLine', "Cursor position exceeded input length ($$cursor_pos_ref > $input_len), clamping to $input_len");
        $$cursor_pos_ref = $input_len;
    }

    # Get terminal width for wrapping
    my $term_width = $self->_get_term_width();
    my $prompt_disp = $self->_get_prompt_disp($prompt);

    # Calculate total display columns occupied by prompt + full input
    my $input_disp  = _display_width($$input_ref);
    my $total_disp  = $prompt_disp + $input_disp;

    # Calculate how many terminal lines the new content occupies
    my $new_lines_needed = $total_disp > 0 ? int(($total_disp - 1) / $term_width) + 1 : 1;

    my $old_display_lines = $self->{display_lines} || 1;
    my $max_lines = $old_display_lines > $new_lines_needed ? $old_display_lines : $new_lines_needed;

    if (should_log('DEBUG')) {
        log_debug('ReadLine', "redraw_line: input_len=$input_len, prompt_disp=$prompt_disp, input_disp=$input_disp, total_disp=$total_disp");
        log_debug('ReadLine', "redraw_line: term_width=$term_width, new_lines_needed=$new_lines_needed");
        log_debug('ReadLine', "redraw_line: old_display_lines=$old_display_lines, max_lines=$max_lines");
        log_debug('ReadLine', "redraw_line: last cursor was at row=$self->{last_cursor_row}, col=$self->{last_cursor_col} pending=$self->{pending_wrap}");
    }

    # Move to (row 0, col 1). After \r the cursor is at col1 of current
    # row; if pending_wrap was set, we are at (last_cursor_row, 1)
    # after \r, then \e[N A moves us up to (0, 1).
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
    # Use _emit_text so cursor tracking stays in sync with what we actually
    # print, including pending_wrap state at the boundary.
    $self->_emit_text($prompt);
    $self->_emit_text($$input_ref);

    # Update display_lines for next redraw.
    $self->{display_lines} = $new_lines_needed;

    # After printing, the terminal cursor is at the end of the output.
    # last_cursor_row/col/disp reflect the physical position now.
    my $end_row = $self->{last_cursor_row};
    my $end_col = $self->{last_cursor_col};

    # Calculate where we WANT the cursor to be (at $$cursor_pos_ref
    # codepoints into input). The cursor position is always at an
    # "ordinary" column - no pending wrap at the cursor's location.
    my $cursor_prefix_disp = _display_width(substr($$input_ref, 0, $$cursor_pos_ref));
    my $desired_pos = $prompt_disp + $cursor_prefix_disp;
    my ($desired_row, $desired_col) = $self->_pos_to_rowcol($desired_pos, 0);

    if (should_log('DEBUG')) {
        log_debug('ReadLine', "redraw_line: end position: row=$end_row, col=$end_col");
        log_debug('ReadLine', "redraw_line: desired cursor: row=$desired_row, col=$desired_col");
    }

    # Reposition cursor to desired location if necessary. After \r and
    # moving up, our current row is 0. Reapply last_cursor tracking from
    # this point.
    if ($desired_row != $end_row || $desired_col != $end_col) {
        if ($desired_row < $end_row) {
            my $rows_up = $end_row - $desired_row;
            print "\e[${rows_up}A";
            $self->{last_cursor_row} -= $rows_up;
        } elsif ($desired_row > $end_row) {
            my $rows_down = $desired_row - $end_row;
            print "\e[${rows_down}B";
            $self->{last_cursor_row} += $rows_down;
        }

        # Absolute column positioning avoids pending-wrap ambiguity.
        print "\r";
        $self->{last_cursor_col} = 1;
        $self->{pending_wrap} = 0;
        if ($desired_col > 1) {
            print "\e[" . ($desired_col - 1) . "C";
            $self->{last_cursor_col} = $desired_col;
        }
    }

    # Save final cursor position for next redraw.
    $self->{last_cursor_row} = $desired_row;
    $self->{last_cursor_col} = $desired_col;
    $self->{last_cursor_disp} = $desired_pos;
    $self->{pending_wrap} = 0;
}

=head2 _redraw_line_external

Redraw the current prompt and input line after external output (e.g., broker
events) has been printed above the input line. Moves cursor to column 0,
reprints the prompt and input buffer, and repositions the cursor.

This is used by the multiplexed event loop to restore the input line after
displaying agent events inline.

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

    # Move to column 0 of current row, clear from there to end of screen,
    # then redraw prompt + input. Uses _emit_text so cursor tracking stays
    # in sync with what we actually print.
    print "\r";
    print "\e[J";
    $self->_emit_text($prompt);
    $self->_emit_text($$input_ref);

    # Reposition cursor to the correct location using tracked positions.
    my $term_width = $self->_get_term_width();
    my $prompt_disp = $self->_get_prompt_disp($prompt);
    my $cursor_disp = $prompt_disp + _display_width(substr($$input_ref, 0, $$cursor_pos_ref));

    my ($cursor_row, $cursor_col) = $self->_pos_to_rowcol($cursor_disp, 0);

    # last_cursor_row/col reflect end-of-input now. Move to desired.
    my $end_row = $self->{last_cursor_row};
    if ($cursor_row < $end_row) {
        my $rows_up = $end_row - $cursor_row;
        print "\e[${rows_up}A";
    } elsif ($cursor_row > $end_row) {
        my $rows_down = $cursor_row - $end_row;
        print "\e[${rows_down}B";
    }

    print "\r";
    print "\e[${cursor_col}C" if $cursor_col > 0;

    # Update tracking.
    my $total_disp = $prompt_disp + _display_width($$input_ref);
    my $new_display_lines = $total_disp > 0 ? int(($total_disp - 1) / $term_width) + 1 : 1;
    $self->{display_lines} = $new_display_lines;
    $self->{last_cursor_row} = $cursor_row;
    $self->{last_cursor_col} = $cursor_col > 0 ? $cursor_col : 1;
    $self->{last_cursor_disp} = $cursor_disp;
    $self->{pending_wrap} = 0;
}

=head2 add_to_history

Add a line to command history

=cut

sub add_to_history {
    my ($self, $line) = @_;
    
    # Always reset history position, even if duplicate
    # (prevents stale position after up-arrow -> Enter -> up-arrow)
    $self->{history_pos} = -1;
    
    # Don't add if same as last entry
    if (@{$self->{history}} && $self->{history}->[-1] eq $line) {
        return;
    }
    
    push @{$self->{history}}, $line;
    
    # Trim history if too long
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
