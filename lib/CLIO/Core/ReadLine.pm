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
use Time::HiRes ();

=head1 NAME

CLIO::Core::ReadLine - Custom readline implementation with tab completion

=head1 DESCRIPTION

A self-contained readline implementation that doesn't depend on external
CPAN modules. Provides:
- Tab completion
- Command history
- Line editing (backspace, delete, arrow keys)
- Portable terminal control using stty
- Standard readline/emac-mode key bindings: Ctrl-A/E (beginning/end of
  line), Ctrl-B/F (backward/forward char), Ctrl-K (kill to end),
  Ctrl-U (kill to beginning), Ctrl-W (kill word), Ctrl-T (transpose),
  Ctrl-L (clear screen), Ctrl-Y (yank from kill ring), Alt+Y (yank-pop)

=head2 DESIGN: Compute-from-state cursor tracking

The terminal manages its own cursor position. ReadLine does NOT track
the VT cursor incrementally — it computes all screen positions from
input state via the pure function C<_cursor_at_codepoint>, then moves
the cursor there using C<\r> (CR to column 0) + absolute cursor movement.

State retained (see C<new()> for the full list):
- C<display_lines>: number of terminal rows occupied by prompt + input.
  Updated by C<_refresh_geometry>.
- C<base_cursor_row>: the physical terminal row (0-indexed) where the
  input area starts. Queried via DSR at readline() start. This is
  needed because the prompt is not always at the top of the terminal
  (previous chat output fills most of the screen). Used by
  C<_refresh_geometry> and C<_input_row_to_screen_row>.
- C<scroll_offset>: DERIVED state — C<max(0, display_lines - (term_height - base_cursor_row))>.
  Recomputed by C<_refresh_geometry>.  Used by
  C<_input_row_to_screen_row>.
- C<last_cursor_input_row>: the cursor's row within the input buffer
  (0-indexed, NOT a screen row).  Written by C<_refresh_geometry> and
  C<redraw_line>.  Read by C<redraw_line> to compute C<rows_to_top>
  (how many rows to move up before clearing).
- C<last_cursor_input_col>: the cursor's column within the input buffer
  (1-indexed). Written by C<_refresh_geometry>, C<redraw_line>,
  C<_redraw_line_external>, and C<reposition_cursor>. Read by
  C<reposition_cursor> for the same-row vs cross-row decision.
- C<last_cursor_input_pending>: whether the cursor is in a pending-wrap
  state (deferred autowrap — the last character filled the last column).
  Written by C<_refresh_geometry>, C<redraw_line>,
  C<_redraw_line_external>, and C<reposition_cursor>. Read by
  C<redraw_line> and C<_redraw_line_external> to decide whether to emit
  a space to resolve pending-wrap before CR (Step 1).
  THIS IS NOT THE SAME AS C<last_cursor_input_col >= term_width> —
  col=term_width can occur without pending (cursor at the last column
  but the previous character did not fill it).

The fields C<last_cursor_row> and C<last_cursor_col> (incremental VT
cursor tracking) have been REMOVED.  They were the source of drift
between a shadow cursor model and the terminal's actual cursor
position.  All screen positions are computed from input state.

=cut

=head2 _display_width

Compute the number of terminal columns a string occupies.

ASCII characters are 1 column wide. CJK (Chinese/Japanese/Korean) and other
fullwidth Unicode characters are 2 columns wide. Combining marks, ZWJ,
ZWNJ, variation selectors, and other zero-width characters contribute
0 columns. Tab characters are normalized to a single space by the
editor (see readline() insert path) before they reach width computation.

Uses Unicode::GCString if available (most accurate), otherwise falls back
to Perl Unicode properties (C<\p{Wide}>, C<\p{Mn}>, C<\p{Me}>) and an
explicit zero-width codepoint table.

=cut

# Probe for Unicode::GCString at startup so we don't repeat the eval
# on every _display_width call. The result is captured in a closure.
my $HAS_UNICODE_GCSTRING = eval { require Unicode::GCString; 1 } ? 1 : 0;

# Codepoints that are zero-width in terminal rendering: combining marks,
# ZWJ, ZWNJ, variation selectors, zero-width spaces, and tags.
sub _is_zero_width {
    my ($cp) = @_;
    # \p{Mn} = nonspacing marks (combining diacritics)
    # \p{Me} = enclosing marks
    return 1 if chr($cp) =~ /\p{Mn}/;
    return 1 if chr($cp) =~ /\p{Me}/;
    # Explicit zero-width format characters
    return 1 if $cp == 0x200B;  # Zero Width Space
    return 1 if $cp == 0x200C;  # Zero Width Non-Joiner
    return 1 if $cp == 0x200D;  # Zero Width Joiner
    return 1 if $cp == 0x2060;  # Word Joiner
    return 1 if $cp == 0xFEFF;  # Zero Width No-Break Space / BOM
    # Variation Selectors (VS1-VS16)
    return 1 if $cp >= 0xFE00 && $cp <= 0xFE0F;
    # Tags (language tags, U+E0001..U+E007F)
    return 1 if $cp >= 0xE0001 && $cp <= 0xE007F;
    return 0;
}

# Regional Indicator symbols (A-Z, U+1F1E6..U+1F1FF) used in flag emoji.
sub _is_regional_indicator {
    my ($cp) = @_;
    return $cp >= 0x1F1E6 && $cp <= 0x1F1FF;
}

# Check if a codepoint should be rendered as 2 columns wide.
sub _is_wide_cp {
    my ($cp) = @_;
    my $ch = chr($cp);
    # East Asian Wide and Fullwidth characters (CJK, Hiragana, Katakana,
    # Hangul, fullwidth forms, most emoji in the SMP)
    return 1 if $ch =~ /\p{EA=Wide}/;
    return 1 if $ch =~ /\p{EA=Fullwidth}/;
    # Regional indicators (flags) — EA=Neutral per Unicode, but terminals
    # render them as 2-column wide.
    return 1 if $cp >= 0x1F1E6 && $cp <= 0x1F1FF;
    return 0;
}

sub _display_width {
    my ($str) = @_;
    return 0 unless defined $str && length($str);

    # Use Unicode::GCString for accurate width if available
    if ($HAS_UNICODE_GCSTRING) {
        return Unicode::GCString->new($str)->columns();
    }

    # Fallback: process grapheme clusters via \X. The width of each
    # cluster is the width of its first non-zero-width character
    # (the "base"). This correctly handles:
    #   - Combining marks (e + U+0301): width = 1 (from the base 'e')
    #   - ZWJ sequences (man + ZWJ + woman): width = 2 (from the first emoji)
    #   - Regional indicator pairs (flag): width = 2 (from the first RI)
    #   - Zero-width chars (ZWJ, VS, ZWSP): contribute 0 to their cluster
    my $width = 0;
    while ($str =~ /(\X)/g) {
        my $cluster = $1;
        # Find the first non-zero-width character in the cluster.
        for my $i (0 .. length($cluster) - 1) {
            my $ch = substr($cluster, $i, 1);
            my $cp = ord($ch);
            if (_is_zero_width($cp)) {
                next;
            }
            if (_is_wide_cp($cp)) {
                $width += 2;
            } else {
                $width += 1;
            }
            last;  # Only count the first non-zero-width char of the cluster
        }
    }
    return $width;
}

# Find the codepoint offset of the start of the grapheme cluster that
# ends at or before position $cp (i.e., the previous grapheme boundary
# before $cp). Returns 0 if $cp <= 0.
#
# Walks backwards past zero-width characters (combining marks, ZWJ, VS,
# etc.) that extend the preceding base character. Also handles flag emoji
# (two consecutive regional indicators as a single cluster).
sub _grapheme_boundary_before {
    my ($input, $cp) = @_;
    return 0 if $cp <= 0;
    # Start at the character just before $cp — this is the base
    # character of the grapheme we want to back up to.
    my $pos = $cp - 1;
    # Walk backwards past zero-width characters that extend the
    # character at $pos (e.g., base + combining mark).
    while ($pos > 0) {
        my $ch = substr($input, $pos, 1);
        last unless _is_zero_width(ord($ch));
        $pos--;
    }
    # Handle flag emoji: if the char at $pos is a regional indicator
    # and the char before it is also a regional indicator, they form
    # a single grapheme. Move back to the start of the pair.
    if ($pos > 0) {
        my $this_cp = ord(substr($input, $pos, 1));
        my $prev_cp = ord(substr($input, $pos - 1, 1));
        if (_is_regional_indicator($this_cp) && _is_regional_indicator($prev_cp)) {
            $pos--;
        }
    }
    return $pos;
}

# Find the codepoint offset of the end of the grapheme cluster that
# starts at or after position $cp. Returns length($input) if $cp >=
# length($input).
sub _grapheme_boundary_after {
    my ($input, $cp) = @_;
    my $len = length($input);
    return $len if $cp >= $len;
    # Start just after the base character at $cp.
    my $pos = $cp + 1;
    # Walk forward past zero-width characters (combining marks, ZWJ, VS).
    while ($pos < $len) {
        my $ch = substr($input, $pos, 1);
        last unless _is_zero_width(ord($ch));
        $pos++;
    }
    # Handle flag emoji: if the base char is a regional indicator and
    # the next char is also a regional indicator, consume both.
    if ($pos < $len && $pos == $cp + 1) {
        my $base_cp = ord(substr($input, $cp, 1));
        my $next_cp = ord(substr($input, $pos, 1));
        if (_is_regional_indicator($base_cp) && _is_regional_indicator($next_cp)) {
            $pos++;
            # Also consume any trailing zero-width chars after the second RI
            while ($pos < $len) {
                my $ch = substr($input, $pos, 1);
                last unless _is_zero_width(ord($ch));
                $pos++;
            }
        }
    }
    return $pos;
}

=head2 _strip_ansi

Strip terminal control sequences from $text and return the visible substring.
The result contains no control bytes - only printable characters and
whitespace. Used by cursor-tracking code (C<_get_prompt_disp>,
C<_emit_text>) to compute display width without inflating the count
with invisible escape bytes.

Handles:
- OSC sequences: ESC ] ... BEL / ESC ] ... ST
- DCS sequences:  ESC P ... ST
- CSI sequences:  ESC [ params final
- Other 2-byte/3-byte ESC sequences (ESC + non-[ non-])

Arguments:
- $text: String that may contain terminal control sequences.

Returns:
- String with all control sequences removed.

=cut

sub _strip_ansi {
    my ($text) = @_;
    return '' unless defined $text && length $text;
    my $copy = $text;
    # OSC: ESC ] ... terminated by BEL (0x07) or ST (ESC \)
    $copy =~ s/\e\].*?(\x07|\e\\)//g;
    # DCS: ESC P ... ST (ESC \)
    $copy =~ s/\eP.*?(\e\\)//g;
    # CSI: ESC [ params final-byte
    $copy =~ s/\e\[[0-9;?]*[A-Za-z]//g;
    # Other 2-byte ESC sequences: ESC + (anything except [ or ]) + char
    $copy =~ s/\e[^][A-Za-z0-9]*[A-Za-z0-9]//g;
    return $copy;
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
        # Computed from input state via _compute_display_lines; used by
        # redraw_line for vertical movement.
        display_lines => 1,
        # How many input rows are scrolled off the top of the screen.
        # DERIVED state: max(0, display_lines - (term_height - base_cursor_row)),
        # recomputed by _refresh_geometry whenever content or geometry changes.
        # Used by _input_row_to_screen_row to convert input rows to screen rows.
        scroll_offset => 0,
        # The physical terminal row (0-indexed) where the input area starts.
        # Queried via DSR at readline() start. Needed because the prompt
        # is not always at the top of the terminal — previous chat output
        # fills most of the screen.
        base_cursor_row => 0,
        # Key queue: characters intercepted during DSR cursor-position query
        # that are not part of the DSR response. They are re-injected into the
        # readline loop on the next iteration. See _query_cursor_pos.
        _key_queue => [],
        # How many rows the cursor is from the top of the input area
        # (0 = first row). Written by redraw_line, reposition_cursor,
        # _redraw_line_external, and the fast-path insert/backspace.
        last_cursor_input_row => 0,
        # The cursor's col within the input buffer (1-indexed).
        # Written by _refresh_geometry, redraw_line, _redraw_line_external,
        # and reposition_cursor. Read by reposition_cursor for the same-row
        # vs cross-row decision.
        last_cursor_input_col => 1,
        # Kill ring for line-editing commands (Ctrl-K, Ctrl-U, Ctrl-W, etc.)
        # Mirrors GNU readline: text killed by these commands is saved so
        # the user can yank it back with Ctrl-Y. Consecutive kills (without
        # any other command in between) accumulate into a single entry.
        kill_ring => [],
        kill_ring_active => 0,
        # Internal: was the immediately preceding command a kill?
        # Stored at the top of each input loop iteration so kill_ring_save
        # can decide append-vs-new before the flag is reset.
        _prev_was_kill => 0,
        # Kill-ring yank state for Alt-Y cycling. These are INVALIDATED
        # by any command other than yank/yank-pop, and reset at the start
        # of each readline() call. Alt-Y is only meaningful immediately
        # after Ctrl-Y (GNU readline semantics).
        yank_start_pos => undef,
        yank_text => undef,
        yank_index => 0,
        # Was the immediately preceding command a yank or yank-pop?
        # Set by yank()/yank_pop() so the input loop knows not to
        # invalidate yank state at the start of the next iteration.
        _yank_op => 0,
        # Performance caches (invalidated per-readline call)
        _prompt_disp_cache => undef,   # cached prompt display width
        _term_size_cache => undef,     # cached (cols, rows) from GetTerminalSize
        _term_size_time => 0,          # when we last checked terminal size
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

=head2 _refresh_term_size

Refresh the cached terminal dimensions atomically. Both width and height
are fetched from a single GetTerminalSize() call so they are never
inconsistent. Cached for at most 1 second to avoid ioctl overhead.

=cut

sub _refresh_term_size {
    my ($self) = @_;
    my $now = time();
    if (!$self->{_term_size_cache} || $now > $self->{_term_size_time}) {
        my ($w, $h) = GetTerminalSize();
        $self->{_term_size_cache} = [
            ($w && $w >= 10) ? $w : 80,
            ($h && $h >= 5)  ? $h : 24,
        ];
        $self->{_term_size_time} = $now;
    }
    return @{$self->{_term_size_cache}};
}

=head2 _invalidate_term_size

Force a terminal size refresh on the next _refresh_term_size call.
Called by the SIGWINCH handler and at readline() start.

=cut

sub _invalidate_term_size {
    my ($self) = @_;
    $self->{_term_size_cache} = undef;
    $self->{_term_size_time} = 0;
}

=head2 _get_term_width

Return cached terminal width (via _refresh_term_size).

=cut

sub _get_term_width {
    my ($self) = @_;
    my ($w, $h) = $self->_refresh_term_size();
    return $w;
}

=head2 _get_term_height

Return cached terminal height (via _refresh_term_size).
Defaults to 24.

=cut

sub _get_term_height {
    my ($self) = @_;
    my ($w, $h) = $self->_refresh_term_size();
    return $h;
}

=head2 _invalidate_yank

Invalidate yank state (yank_start_pos/yank_text/yank_index). Called by
readline() at start and after any command that is not yank or yank-pop.

GNU readline rule: yank-pop (Alt-Y) is only meaningful immediately after
yank (Ctrl-Y), before any other editing command. This method enforces
that rule by clearing the yank anchor.

=cut

sub _invalidate_yank {
    my ($self) = @_;
    $self->{yank_start_pos} = undef;
    $self->{yank_text} = undef;
    $self->{yank_index} = 0;
}

=head2 _is_dsr_prefix

Test whether a partial byte sequence could still be the prefix of a DSR
(Device Status Report) response.

A DSR response is C<ESC[row;colR>. The response arrives one byte at a
time, so the probe passes through intermediate states such as C<ESC[24;>
before the column digits arrive. The digit run after the ';' must
therefore be allowed to be empty — otherwise the probe is rejected
mid-response and the remaining bytes (including the terminating 'R') are
pushed into the input queue and appear as literal text in the user's
input.

Arguments: $probe (string) - the bytes accumulated so far
Returns: 1 if the sequence could still become a DSR response, 0 otherwise

=cut

sub _is_dsr_prefix {
    my ($self, $probe) = @_;
    return 0 unless defined $probe;
    return $probe =~ /^\e(?:\[\d*(;\d*)?)?$/ ? 1 : 0;
}

=head2 _query_cursor_pos

Query the terminal for the current cursor position using the DSR
(Device Status Report) sequence C<ESC[6n>. The terminal responds
with C<ESC[row;colR> on stdin.

This is used at readline() start to record C<base_cursor_row> — the
physical terminal row where the input area begins. Without this, the
cursor-tracking code assumes the input starts at row 0, which is only
true when the prompt is at the top of a blank terminal.

Any non-DSR characters that arrive during the query (e.g. user typed a
key, or an SSH echo) are saved to C<_key_queue> and re-injected into
the readline loop on the next iteration.

Returns: C<(row, col)> where row is 0-indexed, or C<(0, 1)> if the
query fails (not a TTY, timeout).

=cut

sub _query_cursor_pos {
    my ($self, %opts) = @_;

    # Only meaningful on a real TTY
    return (0, 1) unless -t STDIN;

    my $timeout = $opts{timeout} // 0.25;

    # Use cbreak mode (echo off) to prevent the DSR response from being
    # echoed back to stdout.
    ReadMode(1);

    # Send DSR request.
    #
    # The query has to reach the terminal that will answer it, and the
    # answer arrives back on stdin. When stdout is redirected (e.g.
    # `clio | tee log`), printing ESC[6n to stdout would put the escape
    # sequence into the captured output and the response would arrive
    # late — if at all. Write the query to /dev/tty instead so the
    # terminal still answers while stdout stays clean.
    if (-t STDOUT) {
        print "\e[6n";
        STDOUT->flush() if STDOUT->can('flush');
    } elsif (open(my $tty, '>', '/dev/tty')) {
        print $tty "\e[6n";
        $tty->flush() if $tty->can('flush');
        close($tty);
    } else {
        # No way to ask the terminal — restore the terminal mode and
        # report the default position rather than waiting out the
        # timeout for a response that can never come.
        ReadMode(0);
        return (0, 1);
    }

    # Use a monotonic clock with sub-second resolution. Perl's time() has
    # one-second granularity, so a deadline built from it would extend the
    # query window to a full second (or zero) instead of $timeout.
    my $deadline = Time::HiRes::time() + $timeout;
    my $probe = '';
    my $saw_escape = 0;
    my $parsed;

    while (Time::HiRes::time() < $deadline) {
        my $remaining = $deadline - Time::HiRes::time();
        # Clamp to a positive window. ReadKey(0) is a *blocking* read in
        # this compat layer, so a remainder of exactly 0 would hang until
        # the user pressed a key.
        $remaining = 0.04 if $remaining > 0.04;
        $remaining = 0.001 if $remaining < 0.001;
        my $ch = ReadKey($remaining);
        next unless defined $ch;

        if (!$saw_escape) {
            if ($ch eq "\e") {
                $saw_escape = 1;
                $probe = $ch;
            } else {
                # Not a DSR response — save for readline loop.
                push @{$self->{_key_queue}}, $ch;
            }
            next;
        }

        $probe .= $ch;

        # DSR response: ESC [ rows ; cols R
        if ($probe =~ /^\e\[(\d+);(\d+)R$/) {
            $parsed = [ _max(0, $1 - 1), _max(1, $2) ];
            last;
        }

        # Check if the probe is still a valid DSR prefix.
        #
        # The column digits follow the ';', so the prefix "ESC[24;" is a
        # legitimate intermediate state. The digit run after ';' must
        # therefore be allowed to be empty, otherwise the probe is
        # rejected mid-response and the remaining bytes (including the
        # terminating 'R') are pushed into the input queue as literal
        # text.
        if (!$self->_is_dsr_prefix($probe)) {
            # Not a DSR-shaped prefix — save for readline loop.
            push @{$self->{_key_queue}}, split //, $probe;
            $probe = '';
            $saw_escape = 0;
            next;
        }
    }

    # Any remaining probe bytes that didn't form a complete DSR response.
    if (!$parsed && length($probe)) {
        push @{$self->{_key_queue}}, split //, $probe;
    }

    # DSR late-drain: if the query timed out, the terminal may still send its
    # DSR response. On slow Linux terminals, the response can arrive a few
    # milliseconds after the deadline. Without draining, these bytes sit in
    # the stdin buffer and leak into readline: the ESC is read by the escape
    # sequence reader (which only captures 5 bytes after ESC), and the
    # remaining bytes (e.g. "0R" or just "R") are inserted as literal text
    # into the user's input.
    #
    # We do a short blocking drain (safe here — not in signal context) to
    # give the terminal a grace period to finish sending the DSR response.
    # Any bytes we read that form a DSR pattern are discarded; anything
    # else is pushed to _key_queue for readline to handle.
    if (!$parsed) {
        my $drain_deadline = Time::HiRes::time() + 0.05;
        my $drain_probe = '';
        my $drain_saw_esc = 0;
        while (Time::HiRes::time() < $drain_deadline) {
            my $remaining = $drain_deadline - Time::HiRes::time();
            # Clamp to a positive window. ReadKey(0) is a *blocking* read
            # in this compat layer.
            $remaining = 0.04 if $remaining > 0.04;
            $remaining = 0.001 if $remaining < 0.001;
            my $ch = ReadKey($remaining);
            next unless defined $ch;

            if (!$drain_saw_esc) {
                if ($ch eq "\e") {
                    $drain_saw_esc = 1;
                    $drain_probe = $ch;
                } else {
                    push @{$self->{_key_queue}}, $ch;
                }
                next;
            }

            $drain_probe .= $ch;

            if ($drain_probe =~ /^\e\[(\d+);(\d+)R$/) {
                log_debug('ReadLine', "DSR late-drain: consumed '$drain_probe'");
                $drain_probe = '';
                $drain_saw_esc = 0;
                next;
            }

            # Same prefix rule as the primary probe: "ESC[24;" is a valid
            # intermediate state of a DSR response.
            if (!$self->_is_dsr_prefix($drain_probe)) {
                push @{$self->{_key_queue}}, split //, $drain_probe;
                $drain_probe = '';
                $drain_saw_esc = 0;
                next;
            }
        }

        # Final non-blocking sweep for any remaining DSR bytes.
        if ($drain_saw_esc && length($drain_probe)) {
            my $drained = $drain_probe;
            while (defined(my $byte = ReadKey(-1))) {
                $drained .= $byte;
                if ($drained =~ /^\e\[(\d+);(\d+)R$/) {
                    log_debug('ReadLine', "DSR late-drain: consumed '$drained'");
                    $drained = '';
                    last;
                }
                if (!$self->_is_dsr_prefix($drained)) {
                    push @{$self->{_key_queue}}, split //, $drained;
                    $drained = '';
                    last;
                }
            }
            if (length($drained)) {
                push @{$self->{_key_queue}}, split //, $drained;
            }
        }

        # Final non-blocking sweep for any non-escape bytes.
        while (defined(my $byte = ReadKey(-1))) {
            push @{$self->{_key_queue}}, $byte;
        }
    }

    # Restore terminal mode (readline will set raw mode afterwards).
    ReadMode(0);

    if ($parsed) {
        log_debug('ReadLine', "DSR cursor pos: row=$parsed->[0] col=$parsed->[1]");
        return @$parsed;
    }

    log_debug('ReadLine', 'DSR cursor query timed out, using default (0, 1)');
    return (0, 1);
}

=head2 _refresh_geometry

Recompute all derived geometry state from the current input and prompt:
display_lines, scroll_offset, last_cursor_input_row. This is the
single place where derived geometry is updated, ensuring consistency.

scroll_offset = max(0, display_lines - (term_height - base_cursor_row))
The cursor's input row is derived from the cursor position via
_cursor_at_codepoint (called by the caller as needed).

=cut

sub _refresh_geometry {
    my ($self, $input, $cursor_pos, $prompt) = @_;
    my $prompt_disp = $self->_get_prompt_disp($prompt);
    my $total_disp = $prompt_disp + _display_width($input);
    my $term_height = $self->_get_term_height();
    my $display_lines = $self->_compute_display_lines($total_disp);
    $self->{display_lines} = $display_lines;
    my $base_row = $self->{base_cursor_row} || 0;
    my $available_height = $term_height - $base_row;
    $self->{scroll_offset} = _max(0, $display_lines - $available_height);
    my ($cursor_input_row, $cursor_col, $cursor_input_pending) = $self->_cursor_at_codepoint($input, $cursor_pos, $prompt);
    $self->{last_cursor_input_row} = $cursor_input_row;
    $self->{last_cursor_input_col} = $cursor_col;
    $self->{last_cursor_input_pending} = $cursor_input_pending;
    return;
}

sub _max {
    my ($a, $b) = @_;
    return $a > $b ? $a : $b;
}

=head2 _get_prompt_disp

Return cached display width of the visible prompt (ANSI codes stripped).
Set once per readline() call since the prompt doesn't change mid-input.

=cut

sub _get_prompt_disp {
    my ($self, $prompt) = @_;
    unless (defined $self->{_prompt_disp_cache}) {
        $self->{_prompt_disp_cache} = _display_width(_strip_ansi($prompt // ''));
    }
    return $self->{_prompt_disp_cache};
}

=head2 _cursor_at_codepoint

Compute the physical (row, col) that the cursor would be at if it sat
at codepoint $cp in $input. Starts at (0, 1+prompt_disp) and walks through
each codepoint, tracking wraps.

Position semantics match the terminal's deferred-autowrap (a.k.a.
pending-wrap) behavior: a char placed at the last column
(col=term_width) occupies that column, and the cursor STAYS at the
last column (pending state) until the next character is output, at
which point the terminal wraps to (row+1, col=1). The cursor is never
reported at col > term_width.

This model is consistent with the line-start precomputation in
redraw_line() and _redraw_line_external(), which also use lpending.

This is the single source of truth for cursor position. Every cursor
movement, redraw, and reposition computes from this pure function.

B<Note:> This function is pure — it does NOT modify any object state.
Callers pass its return values through C<_input_row_to_screen_row>
(which reads the derived C<scroll_offset>) to get screen coordinates.

Returns: ($row, $col, $pending) where $row is 0-indexed (input row, NOT
screen row), $col is 1-indexed, and $pending is a boolean indicating
whether the cursor is in a deferred-autowrap (pending-wrap) state — i.e.
the cursor is at col=term_width because the last character placed filled
the last column. Callers MUST check $pending (not just $col ==
$term_width) to distinguish this state from a non-pending cursor that
happens to be at the last column.

=cut

sub _cursor_at_codepoint {
    my ($self, $input, $cp, $prompt) = @_;
    $prompt //= $self->{prompt} // '';

    my $term_width = $self->_get_term_width();
    my $prompt_disp = $self->_get_prompt_disp($prompt);

    # Start at (0, prompt_disp+1) - the position right after the prompt.
    my $row = 0;
    my $col = $prompt_disp + 1;
    my $pending = 0;

    # Clamp cp to input length to avoid substr-out-of-bounds warnings
    # when callers pass cursor positions past the end of input.
    $cp = length($input) if $cp > length($input);

    # Walk through codepoints 0..cp-1, advancing col and wrapping on
    # boundary using the terminal's deferred-autowrap (pending-wrap) model.
    # Each iteration:
    #   1. If pending wrap from the previous char, resolve it: move to
    #      (row+1, col=1).
    #   2. Pre-place wrap: if the char doesn't fit at the current col,
    #      wrap immediately (col=1, row+1).
    #   3. Place the char (advance col), and if col exceeded term_width,
    #      enter pending-wrap state (col=term_width, pending=1). The
    #      cursor stays at the last column until the next char is output.
    for my $i (0 .. $cp - 1) {
        my $ch = substr($input, $i, 1);
        my $w = _display_width($ch);
        next unless $w;

        # Resolve pending wrap from the previous char: the terminal wraps
        # to the next row when the next character is output.
        if ($pending) {
            $row += 1;
            $col = 1;
            $pending = 0;
        }

        # Pre-place wrap: char doesn't fit at the current col.
        if ($col + $w - 1 > $term_width) {
            $row += 1;
            $col = 1;
        }
        $col += $w;
        # Post-place: cursor advanced past last col -> enter pending state.
        # The terminal keeps the cursor at the last column; it wraps on
        # the NEXT character output.
        if ($col > $term_width) {
            $col = $term_width;
            $pending = 1;
        }
    }

    return ($row, $col, $pending);
}

=head2 _input_row_to_screen_row

Convert an input row (as returned by _cursor_at_codepoint) to a
screen row, accounting for terminal scrolling.

When the input is taller than the available terminal space (term_height
minus base_cursor_row), the terminal scrolls the content up.
scroll_offset (derived by _refresh_geometry) tracks how many input rows
are above the visible window. The screen row is:
input_row - scroll_offset + base_cursor_row.

Returns: screen row (0-indexed, clamped to 0..max_row).

=cut

sub _input_row_to_screen_row {
    my ($self, $input_row) = @_;
    my $term_height = $self->_get_term_height();
    my $max_row = $term_height - 1;
    my $scroll_offset = $self->{scroll_offset} || 0;
    my $base_row = $self->{base_cursor_row} || 0;
    my $screen_row = $input_row - $scroll_offset + $base_row;
    return $screen_row > $max_row ? $max_row : ($screen_row < 0 ? 0 : $screen_row);
}

=head2 _compute_display_lines

Compute the number of terminal rows that prompt + input text occupies,
accounting for terminal autowrap when the content ends exactly at the
last column: a character placed in the final column wraps the cursor
to the next row, so the content occupies one extra row.

Arguments:
- $total_disp: Total display columns of prompt + input (ANSI-stripped).

Returns: Number of terminal rows (at least 1).

=cut

sub _compute_display_lines {
    my ($self, $total_disp) = @_;
    return 1 unless $total_disp > 0;
    my $term_width = $self->_get_term_width();
    return int(($total_disp - 1) / $term_width) + 1
         + (($total_disp % $term_width == 0) ? 1 : 0);
}

=head2 _emit_text

Print $text directly to the terminal.  The terminal manages its own
cursor position; ReadLine does NOT track it incrementally.

ANSI escape sequences (SGR color codes from colorize()) are printed to
the terminal as-is.

=cut

sub _emit_text {
    my ($self, $text) = @_;
    return unless defined $text && length $text;
    print $text;
}

=head2 _emit_newline

Emit a newline: move to column 1 of the next row.

=cut

sub _emit_newline {
    my ($self) = @_;
    print "\r\n";
}

=head2 _emit_ctrl_c

Emit the "^C\n" sequence shown when the user hits Ctrl+C.

=cut

sub _emit_ctrl_c {
    my ($self) = @_;
    print "^C\n";
}

=head2 kill_ring_save

Save $text to the kill ring, mirroring GNU readline semantics. If the
immediately preceding command was also a kill (tracked via
C<_prev_was_kill>), the text is appended to the most recent entry;
otherwise a new entry is pushed. This makes consecutive Ctrl-K / Ctrl-U
/ Ctrl-W calls accumulate into a single yank, matching bash.

Arguments:
- $text: The killed text to store.

=cut

sub kill_ring_save {
    my ($self, $text) = @_;
    return unless defined $text && length $text;
    if ($self->{_prev_was_kill} && scalar(@{$self->{kill_ring}})) {
        $self->{kill_ring}->[-1] .= $text;
    } else {
        push @{$self->{kill_ring}}, $text;
    }
    $self->{kill_ring_active} = 1;
    log_debug('ReadLine', "kill_ring_save: saved '" . length($text) . " chars, ring size=" . scalar(@{$self->{kill_ring}}));
}

=head2 yank

Insert the most recent kill-ring entry at the cursor position, mirroring
Ctrl-Y in GNU readline. Records yank state so that repeated Alt-Y can
cycle through older entries.

Arguments:
- $input_ref:      Reference to the input string.
- $cursor_pos_ref: Reference to the cursor position (codepoint offset).
- $prompt:         Prompt string.

=cut

sub yank {
    my ($self, $input_ref, $cursor_pos_ref, $prompt) = @_;

    return unless scalar(@{$self->{kill_ring}});

    my $yanked = $self->{kill_ring}->[-1];
    return unless length $yanked;

    substr($$input_ref, $$cursor_pos_ref, 0, $yanked);
    $$cursor_pos_ref = $$cursor_pos_ref + length($yanked);

    # Record yank state for Alt-Y cycling.
    $self->{yank_start_pos} = $$cursor_pos_ref - length($yanked);
    $self->{yank_text} = $yanked;
    $self->{yank_index} = $#{$self->{kill_ring}};  # index into kill_ring

    # Mark this as a yank operation so the input loop does not
    # invalidate yank state before the next iteration (allowing
    # repeated Alt-Y to cycle).
    $self->{_yank_op} = 1;

    $self->redraw_line($input_ref, $cursor_pos_ref, $prompt);
}

=head2 yank_pop

Cycle the currently-yanked text to the next (older) kill-ring entry.
Replaces the previously yanked text with the next older entry. Only
meaningful immediately after a yank.

Arguments:
- $input_ref:      Reference to the input string.
- $cursor_pos_ref: Reference to the cursor position (codepoint offset).
- $prompt:         Prompt string.

=cut

sub yank_pop {
    my ($self, $input_ref, $cursor_pos_ref, $prompt) = @_;

    return unless defined $self->{yank_start_pos};
    return unless defined $self->{yank_text};
    return unless scalar(@{$self->{kill_ring}});

    # Remove the previously yanked text.
    my $yank_len = length($self->{yank_text});
    my $start = $self->{yank_start_pos};
    substr($$input_ref, $start, $yank_len, '');

    # Cycle to the next older entry (decrement, wrap to newest).
    my $ring = $self->{kill_ring};
    $self->{yank_index} = ($self->{yank_index} > 0) ? $self->{yank_index} - 1 : $#{$ring};
    my $yanked = $ring->[$self->{yank_index}];

    # Insert at the yank start position.
    substr($$input_ref, $start, 0, $yanked);
    $$cursor_pos_ref = $start + length($yanked);

    $self->{yank_text} = $yanked;
    log_debug('ReadLine', "yank_pop: cycled to entry $self->{yank_index}, len=" . length($yanked));

    # Mark this as a yank operation (same as yank()).
    $self->{_yank_op} = 1;

    $self->redraw_line($input_ref, $cursor_pos_ref, $prompt);
}

=head2 redraw_line

Redraw the input line with cursor at correct position.

This method performs a FULL clear-and-redraw of the input line. It should ONLY
be called when the input CONTENT has changed (character added/deleted, text
replaced).  For cursor-only movements (arrows, home/end), use
reposition_cursor() instead.

Uses per-line C<\e[K> (erase to end of line) instead of C<\e[J> (erase to
end of screen), which would wipe terminal content above the input area.
All positions are computed from input state via _cursor_at_codepoint.

=cut

sub redraw_line {
    my ($self, $input_ref, $cursor_pos_ref, $prompt) = @_;

    $prompt //= '';

    my $input_len = length($$input_ref);
    if ($$cursor_pos_ref < 0) {
        $$cursor_pos_ref = 0;
    } elsif ($$cursor_pos_ref > $input_len) {
        $$cursor_pos_ref = $input_len;
    }

    my $term_width  = $self->_get_term_width();
    my $prompt_disp = $self->_get_prompt_disp($prompt);
    my $input_disp  = _display_width($$input_ref);
    my $total_disp  = $prompt_disp + $input_disp;

    # Save old state before _refresh_geometry overwrites it.
    my $old_cursor_input_row = $self->{last_cursor_input_row} || 0;
    my $old_display_lines    = $self->{display_lines} || 1;
    my $old_cursor_input_col = $self->{last_cursor_input_col} || 1;
    my $old_cursor_input_pending = $self->{last_cursor_input_pending} || 0;

    $self->_refresh_geometry($$input_ref, $$cursor_pos_ref, $prompt);

    my $new_display_lines = $self->_compute_display_lines($total_disp);
    my $lines_to_handle   = _max($old_display_lines, $new_display_lines);

    # --- Step 1: Move to top of input area ---
    # CR to col 0, then cursor-up by old_cursor_input_row.
    #
    # Pending-wrap handling: if the VT cursor was in a pending-wrap state
    # (old_cursor_input_pending is true), CR does NOT resolve pending on
    # most terminals (xterm, Terminal.app, Linux console), and ESC[nA may
    # resolve it on some terminals (Terminal.app, Linux console), causing
    # the cursor to wrap to the wrong row. We resolve pending by emitting
    # a space character — the only universal method — before CR + ESC[nA.
    # The space wraps to the next row, so we go up one extra row, and
    # increase lines_to_handle by 1 so Step 2 clears the extra line
    # (erasing the space).
    #
    # IMPORTANT: We check old_cursor_input_pending (the actual VT pending
    # state), NOT (old_cursor_input_col >= term_width). The col can be
    # term_width without pending — in that case the VT cursor is simply
    # at the last column with no wrap pending, and emitting a space would
    # cause an unintended row shift.
    my $pending = $old_cursor_input_pending;
    if ($pending) {
        print ' ';
    }
    print "\r";
    my $rows_to_top = $old_cursor_input_row + ($pending ? 1 : 0);
    if ($rows_to_top > $old_display_lines - 1 + ($pending ? 1 : 0)) {
        $rows_to_top = $old_display_lines - 1 + ($pending ? 1 : 0);
    }
    if ($rows_to_top < 0) { $rows_to_top = 0; }
    if ($rows_to_top > 0) {
        print "\e[${rows_to_top}A";
    }
    $lines_to_handle += $pending ? 1 : 0;

    # --- Step 2: Clear + reprint all lines (walk down) ---
    # Per-line \e[K clears the current line only — never wipes content
    # above the input area.
    my @line_starts = (0);
    my $col = $prompt_disp + 1;
    my $lpending = 0;
    for my $i (0 .. $input_len - 1) {
        my $w = _display_width(substr($$input_ref, $i, 1));
        next unless $w;
        if ($lpending) {
            push @line_starts, $i;
            $col = 1;
            $lpending = 0;
        }
        if ($col + $w - 1 > $term_width) {
            push @line_starts, $i;
            $col = 1;
        }
        $col += $w;
        if ($col > $term_width) {
            $col = $term_width;
            $lpending = 1;
        }
    }

    for my $i (0 .. $lines_to_handle - 1) {
        print "\e[K";
        if ($i < $new_display_lines && exists $line_starts[$i]) {
            $self->_emit_text($prompt) if $i == 0;
            my $line_end = $line_starts[$i + 1];
            $line_end = $input_len unless defined $line_end;
            $line_end = $input_len if $line_end > $input_len;
            $line_end = $line_starts[$i] unless $line_end > $line_starts[$i];
            $self->_emit_text(substr($$input_ref, $line_starts[$i], $line_end - $line_starts[$i]));
        }
        if ($i < $lines_to_handle - 1) {
            print "\r\n";
        }
    }
    # After the loop, CR to col 0 (resolves any pending autowrap from
    # the last line, avoiding the off-by-one-row issue when the cursor
    # was at the last column).
    print "\r";

    # --- Step 3: Position cursor at desired location ---
    # After the loop the cursor is at the end of the last line walked
    # down to (lines_to_handle - 1).  Move back to the top of the input
    # area using CR + cursor-up, then move to the desired position.
    # This avoids pending-wrap ambiguity and works regardless of whether
    # the loop walked extra blank lines (when input shrank).
    my ($desired_input_row, $desired_col, $desired_pending) =
        $self->_cursor_at_codepoint($$input_ref, $$cursor_pos_ref, $prompt);
    my $desired_row = $self->_input_row_to_screen_row($desired_input_row);

    # Move to the top of the input area first.
    my $top_screen_row = $self->_input_row_to_screen_row(0);
    if ($lines_to_handle > 1) {
        print "\e[" . ($lines_to_handle - 1) . "A";
    }

    # Now move from top-of-input to the desired cursor position.
    if ($desired_row > $top_screen_row) {
        print "\e[" . ($desired_row - $top_screen_row) . "B";
    } elsif ($desired_row < $top_screen_row) {
        print "\e[" . ($top_screen_row - $desired_row) . "A";
    }
    if ($desired_pending) {
        # Target is in pending-wrap state (the last char filled the last
        # column). ESC[nC cannot set pending on xterm/Terminal.app.
        # Position at the last column (term_width - 1, 0-indexed), then
        # emit the input character at cursor_pos-1 to set the VT's
        # pending state (character output is the only universal
        # pending-resolution method). This character is at the last column,
        # so overwriting it with itself is harmless.
        print "\e[" . ($term_width - 1) . "C";
        $self->_emit_text(substr($$input_ref, $$cursor_pos_ref - 1, 1))
            if $$cursor_pos_ref > 0;
    } elsif ($desired_col == $term_width) {
        # Cursor is at the last column WITHOUT pending — the last char
        # before the cursor was placed at col term_width-1, not the last
        # column. The VT cursor is at col term_width-1 (0-indexed) with no
        # pending state. Move directly there with ESC[nC; no character
        # emission needed (doing so would overwrite existing VT content).
        print "\e[" . ($term_width - 1) . "C" if $term_width > 1;
    } elsif ($desired_col > 1) {
        print "\e[" . ($desired_col - 1) . "C";
    }

    $self->{last_cursor_input_row} = $desired_input_row;
    $self->{last_cursor_input_col} = $desired_col;
    $self->{last_cursor_input_pending} = $desired_pending;
}

=head2 _redraw_line_external

Redraw the current prompt and input line after external output (e.g., broker
events) has been printed above the input line.  Moves cursor back to the
top of the input area, clears and reprints with per-line C<\e[K>, then
repositions the cursor.  All positions are computed from input state via
_cursor_at_codepoint.

=cut

sub _redraw_line_external {
    my ($self, $prompt, $input_ref, $cursor_pos_ref) = @_;

    $prompt //= '';

    my $input_len = length($$input_ref);
    if ($$cursor_pos_ref < 0) {
        $$cursor_pos_ref = 0;
    } elsif ($$cursor_pos_ref > $input_len) {
        $$cursor_pos_ref = $input_len;
    }

    my $old_cursor_input_row = $self->{last_cursor_input_row} || 0;
    my $old_cursor_input_col = $self->{last_cursor_input_col} || 1;

    $self->_refresh_geometry($$input_ref, $$cursor_pos_ref, $prompt);

    my $term_width = $self->_get_term_width();

    # External output has shifted the cursor down by an unknown number
    # of rows. Move back to the top of the input area using CR +
    # ESC[NA (up by old_cursor_input_row).
    #
    # Pending-wrap handling: if the VT cursor was in a pending-wrap state
    # (old_cursor_input_pending) before external output, we cannot know
    # what the external output did to the VT's pending state. Resolve it
    # with a space — the only universal method — before CR + ESC[nA.
    my $old_cursor_input_pending = $self->{last_cursor_input_pending} || 0;
    my $pending = $old_cursor_input_pending;
    if ($pending) {
        print ' ';
    }
    print "\r";
    my $old_display_lines = $self->{display_lines} || 1;
    my $rows_to_top = $old_cursor_input_row + ($pending ? 1 : 0);
    if ($rows_to_top > $old_display_lines - 1 + ($pending ? 1 : 0)) {
        $rows_to_top = $old_display_lines - 1 + ($pending ? 1 : 0);
    }
    if ($rows_to_top > 0) {
        print "\e[${rows_to_top}A";
    }

    # Clear + reprint with per-line \e[K.
    my $prompt_disp = $self->_get_prompt_disp($prompt);
    my $total_disp  = $prompt_disp + _display_width($$input_ref);
    my $lines_to_clear = $self->_compute_display_lines($total_disp);
    $lines_to_clear += $pending ? 1 : 0;
    my $input = $$input_ref;

    # Precompute line starts (same autowrap model as redraw_line).
    my @line_starts = (0);
    my $col = $prompt_disp + 1;
    my $lpending = 0;
    for my $i (0 .. length($input) - 1) {
        my $w = _display_width(substr($input, $i, 1));
        next unless $w;
        if ($lpending) {
            push @line_starts, $i;
            $col = 1;
            $lpending = 0;
        }
        if ($col + $w - 1 > $term_width) {
            push @line_starts, $i;
            $col = 1;
        }
        $col += $w;
        if ($col > $term_width) {
            $col = $term_width;
            $lpending = 1;
        }
    }

    for my $i (0 .. $lines_to_clear - 1) {
        print "\e[K";
        if ($i == 0) {
            $self->_emit_text($prompt);
        }
        if (exists $line_starts[$i]) {
            my $line_start = $line_starts[$i];
            my $line_end = $line_starts[$i + 1];
            $line_end = length($input) unless defined $line_end;
            $line_end = $line_start unless $line_end > $line_start;
            $self->_emit_text(substr($input, $line_start, $line_end - $line_start));
        }
        print "\r\n" if $i < $lines_to_clear - 1;
    }
    # After the loop, CR to col 0 (resolves any pending autowrap from
    # the last line, avoiding off-by-one-row issues).
    print "\r";

    # Reposition cursor from input state.
    my ($cursor_input_row, $cursor_col, $cursor_pending) =
        $self->_cursor_at_codepoint($$input_ref, $$cursor_pos_ref, $prompt);
    my $cursor_row = $self->_input_row_to_screen_row($cursor_input_row);

    # Move to the top of the input area, then to the desired position.
    my $top_screen_row = $self->_input_row_to_screen_row(0);
    if ($lines_to_clear > 1) {
        print "\e[" . ($lines_to_clear - 1) . "A";
    }
    if ($cursor_row > $top_screen_row) {
        print "\e[" . ($cursor_row - $top_screen_row) . "B";
    } elsif ($cursor_row < $top_screen_row) {
        print "\e[" . ($top_screen_row - $cursor_row) . "A";
    }
    if ($cursor_pending) {
        # Target is in pending-wrap state (the last char filled the last
        # column). Emit the char at cursor_pos-1 to set VT pending.
        print "\e[" . ($term_width - 1) . "C";
        $self->_emit_text(substr($$input_ref, $$cursor_pos_ref - 1, 1))
            if $$cursor_pos_ref > 0;
    } elsif ($cursor_col == $term_width) {
        # Cursor at the last column WITHOUT pending — move directly.
        print "\e[" . ($term_width - 1) . "C" if $term_width > 1;
    } elsif ($cursor_col > 1) {
        print "\e[" . ($cursor_col - 1) . "C";
    }
    $self->{last_cursor_input_row} = $cursor_input_row;
    $self->{last_cursor_input_col} = $cursor_col;
    $self->{last_cursor_input_pending} = $cursor_pending;
}

sub readline {
    my ($self, $prompt, %opts) = @_;

    $prompt //= $self->{prompt};

    # Optional event multiplexing
    my $event_callback = $opts{event_callback};
    my $prefill = $opts{prefill} || '';

    # Reset display lines tracking for new input.
    $self->{display_lines} = 1;
    $self->{scroll_offset} = 0;
    $self->{last_cursor_input_row} = 0;
    $self->{last_cursor_input_col} = 1;
    # Clear any key queue from a previous DSR query.
    $self->{_key_queue} = [];

    # Reset kill-ring accumulation state. The kill_ring itself persists
    # across readline calls (so Ctrl-Y can yank text killed on a previous
    # line), but the "last command was a kill" flag must reset so kills
    # on this line don't accumulate with kills from the previous line.
    $self->{kill_ring_active} = 0;
    $self->{_prev_was_kill} = 0;

    # Reset yank state. Alt-Y is only valid immediately after Ctrl-Y;
    # yank state must not carry across readline boundaries.
    $self->_invalidate_yank();
    $self->{_yank_op} = 0;

    # Reset history position so Up/Down starts from the end.
    $self->{history_pos} = -1;
    delete $self->{current_input};

    # Force terminal size refresh on this readline call.
    $self->_invalidate_term_size();

    # Reset performance caches for this readline session
    $self->{_prompt_disp_cache} = undef;

    # Install SIGWINCH handler
    my $resize_flag = 0;
    local $SIG{WINCH} = sub { $resize_flag = 1; };

    # Query the terminal's current cursor position before printing the
    # prompt. This records base_cursor_row — the physical terminal row
    # where the input area begins. The prompt is typically NOT at row 0
    # (previous chat output fills most of the screen), so all subsequent
    # screen-row calculations must be offset by base_cursor_row.
    # Uses DSR (ESC[6n); any non-DSR characters arriving during the
    # query are saved to _key_queue and drained at the start of the
    # input loop.
    if (-t STDIN) {
        my ($br, $bc) = $self->_query_cursor_pos();
        $self->{base_cursor_row} = $br;
    }

    # Print prompt
    $self->_emit_text($prompt);

    # Set terminal to raw mode
    ReadMode('raw');

    # Enable bracketed paste mode so pasted text is inserted literally
    # without interpreting escape sequences.
    print "\e[?2004h";
    STDOUT->flush() if STDOUT->can('flush');

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
        # Derive geometry from the prefilled content.
        $self->_refresh_geometry($input, $cursor_pos, $prompt);
    }

    while (1) {
        my $char;

        # Drain any characters saved during DSR cursor query.
        if (@{$self->{_key_queue}}) {
            $char = shift @{$self->{_key_queue}};
        }

        # Handle SIGWINCH before reading
        if ($resize_flag) {
            $resize_flag = 0;
            $self->_invalidate_term_size();
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
            # Only block on a fresh read if no char was queued by the DSR
            # cursor query — a blocking ReadKey here would clobber the
            # queued value and silently drop type-ahead input.
            $char = ReadKey(0) unless defined $char;

            unless (defined $char) {
                next;
            }
        }

        my $ord = ord($char);

        log_debug('ReadLine', "char='$char' ord=$ord pos=$cursor_pos input='$input'");

        # Track whether the preceding command was a kill, for kill-ring
        # accumulation: consecutive kills (Ctrl-K, Ctrl-U, Ctrl-W, etc.)
        # append to the same ring entry, matching bash/readline.
        $self->{_prev_was_kill} = $self->{kill_ring_active};
        $self->{kill_ring_active} = 0;

        # Invalidate yank state: yank-pop is only valid immediately after
        # a yank or yank-pop (GNU readline semantics). Any other command
        # makes the recorded yank_start_pos/yank_text stale.
        unless ($self->{_yank_op}) {
            $self->_invalidate_yank();
        }
        $self->{_yank_op} = 0;

        # Tab key (completion) — or tab character in input.
        # If there is a completer and it handles the tab (finds candidates,
        # cycles, etc.), it returns 1 and we skip the rest. If it returns 0
        # (no completer or no candidates), fall through and treat Tab as
        # a tab character, which is normalized to a space by the insert path.
        if ($ord == 9) {
            my $handled = $self->handle_tab(\$input, \$cursor_pos, $completion_state, $prompt);
            next if $handled;
            $char = ' ';
            $ord = ord($char);
        }

        # Reset completion state on any non-tab key
        if ($completion_state->{active}) {
            $completion_state->{active} = 0;
            $completion_state->{candidates} = [];
            $completion_state->{index} = 0;
        }

        # Enter key
        if ($ord == 10 || $ord == 13) {
            print "\e[?2004l";
            # Move the cursor to the end of the input before emitting the
            # submit newline. The user may have scrolled back to an earlier
            # row to edit, leaving the cursor in the middle of a multi-row
            # input. Submitting from there would emit the newline inside
            # the input, so everything printed afterwards (the busy
            # indicator, the echoed user message) would start inside the
            # input line instead of after it.
            $self->_move_cursor_to_end(\$input, \$cursor_pos, $prompt);
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
                print "\e[?2004l";
                $self->_emit_newline();
                ReadMode('restore');
                return undef;
            }
            if ($cursor_pos < length($input)) {
                # Grapheme-aware: delete the entire grapheme at cursor.
                my $del_end = _grapheme_boundary_after($input, $cursor_pos);
                substr($input, $cursor_pos, $del_end - $cursor_pos, '');
                $self->_invalidate_yank();
                $self->redraw_line(\$input, \$cursor_pos, $prompt);
            }
            next;
        }

        # Ctrl-C
        if ($ord == 3) {
            print "\e[?2004l";
            # Move the cursor to the end of the input so the abort marker
            # lands after the whole input instead of splitting it.
            $self->_move_cursor_to_end(\$input, \$cursor_pos, $prompt);
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

                # Grapheme-aware: find the start of the grapheme cluster
                # containing the character before the cursor, so we delete
                # the entire cluster (e.g., 'e' + combining accent) not
                # just its last codepoint.
                my $del_start = _grapheme_boundary_before($input, $cursor_pos);
                my $deleted = substr($input, $del_start, $cursor_pos - $del_start);
                my $deleted_width = _display_width($deleted);

                substr($input, $del_start, $cursor_pos - $del_start, '');
                $cursor_pos = $del_start;

                # Invalidate yank state (input content changed).
                $self->_invalidate_yank();

                if ($deleting_at_end) {
                    # Fast-path: if cursor is on same input row before
                    # and after deletion, and deleted cluster is 1 column,
                    # use \b \b.  Otherwise redraw_line.
                    my $term_width = $self->_get_term_width();
                    my $old_input = substr($input, 0, $cursor_pos) . $deleted . substr($input, $cursor_pos);
                    my $old_cp = $cursor_pos + length($deleted);
                    my ($old_row, $old_col) = $self->_cursor_at_codepoint($old_input, $old_cp, $prompt);
                    my ($new_row, $new_col) = $self->_cursor_at_codepoint($input, $cursor_pos, $prompt);

                    if ($old_row == $new_row && $old_col > 1 && $old_col < $term_width && $deleted_width == 1) {
                        print "\b \b";
                        $self->_refresh_geometry($input, $cursor_pos, $prompt);
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

        # Escape sequence (arrow keys, function keys, DSR response, etc.)
        if ($ord == 27) {
            my $seq = $char;

            # Read up to 8 bytes after ESC — enough to capture a full DSR
            # response (ESC[row;colR, e.g. ESC[24;80R is 7 bytes after ESC).
            # The previous limit of 5 was too small: it captured ESC[24;8
            # from a DSR response and left "0R" in the buffer to leak as
            # literal text. 8 covers even 3-digit row/col values (e.g.
            # ESC[100;99R = 8 bytes after ESC); most DSR responses are
            # 4-6 bytes after ESC and will terminate early because the
            # trailing 'R' matches the letter-class check below.
            for my $i (1..8) {
                my $next = ReadKey(0.1);
                last unless defined $next;
                $seq .= $next;

                if ($next =~ /[A-Za-z~]/ || ord($next) == 0x7F) {
                    last;
                }
            }

            # Bracketed paste start: ESC [ 200 ~
            if ($seq eq "\e[200~") {
                my $pasted = $self->_read_bracketed_paste();
                if (length $pasted) {
                    substr($input, $cursor_pos, 0, $pasted);
                    $cursor_pos += length($pasted);
                    $self->_invalidate_yank();
                    $self->redraw_line(\$input, \$cursor_pos, $prompt);
                }
                next;
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

        # Ctrl-K (kill to end of line) — saves to kill ring for Ctrl-Y
        if ($ord == 11) {
            my $killed = substr($input, $cursor_pos);
            substr($input, $cursor_pos) = '';
            $self->kill_ring_save($killed);
            $self->_invalidate_yank();
            $self->redraw_line(\$input, \$cursor_pos, $prompt);
            next;
        }

        # Ctrl-U (kill to beginning of line) — saves to kill ring for Ctrl-Y
        # When cursor is at end, this clears the whole line. Standard
        # readline behavior: kills from cursor to beginning.
        if ($ord == 21) {
            my $killed = substr($input, 0, $cursor_pos);
            substr($input, 0, $cursor_pos) = '';
            $cursor_pos = 0;
            $self->kill_ring_save($killed);
            $self->_invalidate_yank();
            $self->redraw_line(\$input, \$cursor_pos, $prompt);
            next;
        }

        # Ctrl-W (kill word backward) — saves to kill ring for Ctrl-Y
        if ($ord == 23) {
            $self->_kill_word_backward(\$input, \$cursor_pos, $prompt);
            $self->_invalidate_yank();
            next;
        }

        # Ctrl-L (clear screen and redraw) — standard readline.
        if ($ord == 12) {
            print "\e[2J\e[H";
            $self->{scroll_offset} = 0;
            $self->{base_cursor_row} = 0;
            $self->{display_lines} = 1;
            $self->{last_cursor_input_row} = 0;
            $self->{last_cursor_input_col} = 1;
            $self->_invalidate_yank();
            $self->redraw_line(\$input, \$cursor_pos, $prompt);
            next;
        }

        # Ctrl-B (move backward one character) — standard readline,
        # equivalent to Left arrow. Grapheme-aware: skips past
        # combining marks, ZWJ, etc. that extend the preceding base.
        if ($ord == 2) {
            if ($cursor_pos > 0) {
                my $old_pos = $cursor_pos;
                $cursor_pos = _grapheme_boundary_before($input, $cursor_pos);
                if ($cursor_pos != $old_pos) {
                    $self->reposition_cursor(\$old_pos, \$cursor_pos, \$input, $prompt);
                }
            }
            next;
        }

        # Ctrl-F (move forward one character) — standard readline,
        # equivalent to Right arrow. Grapheme-aware.
        if ($ord == 6) {
            if ($cursor_pos < length($input)) {
                my $old_pos = $cursor_pos;
                $cursor_pos = _grapheme_boundary_after($input, $cursor_pos);
                if ($cursor_pos != $old_pos) {
                    $self->reposition_cursor(\$old_pos, \$cursor_pos, \$input, $prompt);
                }
            }
            next;
        }

        # Ctrl-T (transpose characters) — standard readline.
        # Swaps the character before and after the cursor. When the
        # cursor is at the end of the line, swaps the last two characters.
        # Grapheme-aware: transposes grapheme clusters, not individual
        # codepoints that would split combining marks.
        if ($ord == 20) {
            my $len = length($input);
            if ($cursor_pos >= $len && $len >= 2) {
                # At end: swap last two grapheme clusters.
                my $gb2 = length($input);
                my $gb1 = _grapheme_boundary_before($input, $gb2);
                my $gb0 = _grapheme_boundary_before($input, $gb1);
                if ($gb1 > $gb0) {
                    my $g2 = substr($input, $gb1, $gb2 - $gb1);
                    my $g1 = substr($input, $gb0, $gb1 - $gb0);
                    substr($input, $gb0, $gb2 - $gb0, $g2 . $g1);
                }
            } elsif ($cursor_pos > 0 && $cursor_pos < $len) {
                # Swap the grapheme before cursor with the one after.
                my $gb_after = _grapheme_boundary_after($input, $cursor_pos);
                my $gb_before = _grapheme_boundary_before($input, $cursor_pos);
                if ($gb_before < $cursor_pos && $gb_after > $cursor_pos) {
                    my $g_before = substr($input, $gb_before, $cursor_pos - $gb_before);
                    my $g_after = substr($input, $cursor_pos, $gb_after - $cursor_pos);
                    substr($input, $gb_before, $gb_after - $gb_before, $g_after . $g_before);
                    $cursor_pos = $gb_before + length($g_after);
                }
            }
            $self->_invalidate_yank();
            $self->redraw_line(\$input, \$cursor_pos, $prompt);
            next;
        }

        # Ctrl-Y (yank from kill ring) — standard readline.
        # Inserts the most recently killed text at the cursor.
        if ($ord == 25) {
            $self->yank(\$input, \$cursor_pos, $prompt);
            next;
        }

        # Regular printable character
        if ($ord >= 32 || ($ord >= 128)) {
            # Normalize tabs to spaces. Terminals use variable-width
            # tab stops (typically 8 columns), which makes cursor
            # tracking unreliable. We normalize to a single space so
            # display width is always 1, consistent with _display_width.
            if ($char eq "\t") {
                $char = ' ';
            }

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

            # Invalidate yank state (input content changed).
            $self->_invalidate_yank();

            if ($inserting_at_end) {
                $self->_emit_text($char);
                $self->_refresh_geometry($input, $cursor_pos, $prompt);
            } else {
                # Mid-input insert: full redraw. redraw_line recomputes
                # all positions from input state via _cursor_at_codepoint,
                # so it is correct regardless of where the cursor came
                # from. The rows_to_top fix ensures it moves up by the
                # cursor's actual distance from the top of the input,
                # not by display_lines - 1 (which assumes bottom).
                $self->redraw_line(\$input, \$cursor_pos, $prompt);
            }
        }
    }
}

=head2 handle_tab

Handle tab completion

=cut

sub handle_tab {
    my ($self, $input_ref, $cursor_pos_ref, $state, $prompt) = @_;

    return 0 unless $self->{completer};

    my $current_input = $$input_ref;
    my $cursor_pos = $$cursor_pos_ref;

    log_debug('ReadLine', "Tab pressed, input='$current_input', cursor=$cursor_pos");

    # The text to the left of the cursor is what we pass to the completer.
    # This ensures tab completion works correctly when the cursor is in
    # the middle of the line or at the very beginning (position 0).
    my $line_to_complete = substr($current_input, 0, $cursor_pos);
    my $text_after_cursor = substr($current_input, $cursor_pos);

    unless ($state->{active}) {
        $state->{original_input} = $current_input;
        $state->{active} = 1;
        $state->{index} = 0;
        $state->{cursor_pos} = $cursor_pos;

        my @candidates = $self->{completer}->complete(
            $line_to_complete, $line_to_complete, 0
        );

        $state->{candidates} = \@candidates;

        log_debug('ReadLine', "Found " . scalar(@candidates) . " candidates: @candidates");

        return 0 unless @candidates;

        # When applying a candidate, replace only the text to the left of
        # the cursor. This preserves any text that was to the right of
        # the cursor (important when the cursor is in the middle of the line).
        if (@candidates == 1) {
            $$input_ref = $candidates[0] . $text_after_cursor;
            $$cursor_pos_ref = length($candidates[0]);
            $self->redraw_line($input_ref, $cursor_pos_ref, $prompt);
            $state->{active} = 0;
            log_debug('ReadLine', "Single match, completed to: '$$input_ref'");
            return 1;
        }

        $$input_ref = $candidates[0] . $text_after_cursor;
        $$cursor_pos_ref = length($candidates[0]);
        $self->redraw_line($input_ref, $cursor_pos_ref, $prompt);
        log_debug('ReadLine', "Multiple matches, showing first: '$$input_ref'");
        return 1;

    } else {
        $state->{index}++;

        # The text to the right of the original cursor position is preserved
        # across all cycled candidates.
        my $text_after = substr($state->{original_input}, $state->{cursor_pos});

        if ($state->{index} >= scalar(@{$state->{candidates}})) {
            $state->{index} = -1;
            $$input_ref = $state->{original_input};
            $$cursor_pos_ref = $state->{cursor_pos};
            log_debug('ReadLine', "Wrapped to original");
        } else {
            $$input_ref = $state->{candidates}->[$state->{index}] . $text_after;
            $$cursor_pos_ref = length($state->{candidates}->[$state->{index}]);
            log_debug('ReadLine', "Cycling to: '$$input_ref'");
        }

        $self->redraw_line($input_ref, $cursor_pos_ref, $prompt);
        return 1;
    }
}

=head2 _read_bracketed_paste

Read a bracketed paste from stdin.  The terminal sends C<ESC[200~> to
mark the start of a paste and C<ESC[201~> to mark the end.  This method
reads bytes until the end marker is seen, then returns the pasted text.

Returns: the pasted text (without the start/end markers), or empty
string if no end marker was found within 5 seconds.

=cut

sub _read_bracketed_paste {
    my ($self) = @_;

    my $pasted = '';
    my $deadline = time() + 5;

    while (time() < $deadline) {
        my $rin = '';
        vec($rin, fileno(STDIN), 1) = 1;
        my $nfound = select(my $rout = $rin, undef, undef, 0.05);
        next unless $nfound && $nfound > 0;
        my $byte = ReadKey(-1);
        next unless defined $byte;

        $pasted .= $byte;

        # Check for end marker: ESC [ 2 0 1 ~
        if (length($pasted) >= 6 &&
            substr($pasted, -6) eq "\e[201~") {
            $pasted = substr($pasted, 0, -6);
            last;
        }
    }

    $pasted = _strip_ansi($pasted);
    return $pasted;
}

=head2 handle_escape_sequence

Handle escape sequences (arrow keys, function keys, etc.)

Supported sequences:
- ESC [ row ; col R - DSR (Device Status Report) response, silently consumed
- ESC [ A/B/C/D - Arrow keys (up/down/right/left)
- ESC [ 1;5C/D - Ctrl+Right/Left (word forward/backward, standard xterm)
- ESC [ 1;3C/D - Ctrl+Right/Left (Terminal.app sends modifier 3)
- ESC [ 1;2C/D - Shift+Right/Left (word forward/backward)
- ESC [ 1;5A/B - Ctrl+Up/Down (home/end of line)
- ESC [ 5C/D - Ctrl+Right/Left (alternative format)
- ESC b/f - Option+Left/Right (macOS, word movement)
- ESC d - Alt+D (kill word forward)
- ESC DEL - Alt+Backspace (kill word backward)
- ESC y - Alt+Y (yank-pop: cycle through kill ring)
- ESC [ H / ESC [ 1~ / ESC O H - Home key (beginning of line)
- ESC [ F / ESC [ 4~ / ESC O F - End key (end of line)
- ESC [ 3~ - Delete key (forward delete)

=cut

sub handle_escape_sequence {
    my ($self, $seq, $input_ref, $cursor_pos_ref, $prompt) = @_;

    log_debug('ReadLine', "Escape sequence: " . join(' ', map { sprintf('%02X', ord($_)) } split //, $seq) . " = '$seq'");

    # DSR (Device Status Report) response: ESC [ row ; col R
    # This can arrive late after _query_cursor_pos times out and leak into
    # the readline main loop. Silently consume it so it does not appear as
    # literal text in the user's input.
    if ($seq =~ /^\e\[\d+;\d+R$/) {
        log_debug('ReadLine', "DSR response consumed: '$seq'");
        return;
    }

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
                $$cursor_pos_ref = _grapheme_boundary_after($$input_ref, $$cursor_pos_ref);
                if ($$cursor_pos_ref != $old_pos) {
                    $self->reposition_cursor(\$old_pos, $cursor_pos_ref, $input_ref, $prompt);
                }
            }
        } elsif ($dir eq 'D') {
            if ($$cursor_pos_ref > 0) {
                my $old_pos = $$cursor_pos_ref;
                $$cursor_pos_ref = _grapheme_boundary_before($$input_ref, $$cursor_pos_ref);
                if ($$cursor_pos_ref != $old_pos) {
                    $self->reposition_cursor(\$old_pos, $cursor_pos_ref, $input_ref, $prompt);
                }
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
            # Grapheme-aware: delete the entire grapheme cluster at the
            # cursor, not just one codepoint.
            my $del_start = $$cursor_pos_ref;
            my $del_end = _grapheme_boundary_after($$input_ref, $$cursor_pos_ref);
            substr($$input_ref, $del_start, $del_end - $del_start, '');
            $self->_invalidate_yank();
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

    # Alt+Y - yank-pop: cycle through kill ring entries (replaces
    # current yank with next older entry). Only meaningful after Ctrl-Y.
    if ($seq eq "\ey") {
        $self->yank_pop($input_ref, $cursor_pos_ref, $prompt);
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

    return if $$old_pos_ref == $$new_pos_ref;

    $prompt //= '';

    my $term_width = $self->_get_term_width();

    # Compute SOURCE position from input state (pure function, no
    # _refresh_geometry needed for _cursor_at_codepoint).
    my ($old_input_row, $old_col, $old_pending) = $self->_cursor_at_codepoint($$input_ref, $$old_pos_ref, $prompt);
    my ($new_input_row, $new_col, $new_pending) = $self->_cursor_at_codepoint($$input_ref, $$new_pos_ref, $prompt);

    # Ensure scroll_offset is derived from current content so
    # _input_row_to_screen_row gives correct screen rows.
    $self->_refresh_geometry($$input_ref, $$new_pos_ref, $prompt);

    # Convert input rows to screen rows (account for terminal scrolling
    # when the input is taller than the screen).
    my $old_row = $self->_input_row_to_screen_row($old_input_row);
    my $new_row = $self->_input_row_to_screen_row($new_input_row);

    if (should_log('DEBUG')) {
        log_debug('ReadLine', "reposition_cursor: old_pos=$$old_pos_ref, new_pos=$$new_pos_ref");
        log_debug('ReadLine', "reposition_cursor: from ($old_row,$old_col,pending=$old_pending) to ($new_row,$new_col,pending=$new_pending)");
        log_debug('ReadLine', "reposition_cursor: both computed via _cursor_at_codepoint from input state");
    }

    # Resolve old pending-wrap state without a full redraw.
    #
    # When old_pending is true, the VT cursor sits at the last column of
    # old_input_row with a deferred autowrap pending. We MUST clear this
    # before any cursor movement to avoid the VT cursor wrapping to the
    # wrong row.
    #
    # CR (\r) alone does NOT clear pending on all terminals. On xterm and
    # VTE (GNOME Terminal, VS Code, Konsole) CR happens to work, but on
    # macOS Terminal.app and the Linux console, CR does NOT clear pending
    # — and worse, cursor-movement sequences (ESC[nA/B/C/D) DO resolve it
    # by wrapping, sending the cursor to (old_row+1, col 0) instead of
    # the intended location. This is the root cause of the "can't get to
    # row n column 0" bug.
    #
    # Character output is the ONLY universal pending-resolution method:
    # every terminal resolves pending when a character is printed.
    #
    # We emit the character that BELONGS at (old_row+1, col 0) — the
    # codepoint at old_pos (if it exists in the input) or a space (if
    # old_pos is past the end of input). This overwrites the terminal
    # cell with the correct content, so no restoration is needed.
    #
    # After char output + CR, the VT cursor is at (old_row+1, 0) with
    # pending cleared on ALL terminal types.
    if ($old_pending) {
        # Emit the char that belongs at (old_row+1, col 0) — or a space
        # if old_pos is past the end of input. Char output resolves
        # pending universally (wraps to the next row). Then CR moves to
        # col 0 of that row. After this, the cursor is on the wrapped
        # row at col 0 with pending cleared on ALL terminal types.
        my $pending_char = ' ';
        if ($$old_pos_ref < length($$input_ref)) {
            $pending_char = substr($$input_ref, $$old_pos_ref, 1);
        }
        $self->_emit_text($pending_char);
        print "\r";
        $old_row += 1;   # cursor wrapped to the next row
        $old_col = 1;    # cursor at col 0 (0-indexed) = col 1 (1-indexed)
    }

    if ($new_row == $old_row) {
        # Same row: relative movement (ESC[nC / ESC[nD).
        # After CR-for-pending, old_col is 1. After normal movement,
        # old_col is the 1-indexed col from _cursor_at_codepoint.
        my $delta = $new_col - $old_col;
        if ($delta > 0) {
            print "\e[${delta}C";
        } elsif ($delta < 0) {
            print "\e[" . (-$delta) . "D";
        }
        # delta == 0: already there.
    } else {
        # Cross-row: use absolute positioning (ESC[row;colH) to jump
        # directly to the target row and column. This avoids the CR +
        # relative movement sequence that briefly lands the cursor on
        # column 0 of the current row — a visible flicker at the wrap
        # boundary where the cursor appears to "skip" the first character
        # of a wrapped line. When old_pending=0 (no pending resolution
        # was needed), the cursor is NOT at column 0, so CR would
        # unnecessarily move it there first. Absolute positioning jumps
        # straight to the target.
        #
        # Pending-wrap is already resolved above (via char output + CR),
        # so the cursor is in a clean state. Absolute positioning
        # (ESC[row;colH) does not trigger deferred autowrap, so it is
        # safe on all terminal types.
        print "\e[" . ($new_row + 1) . ";" . $new_col . "H";
    }

    # Set new pending-wrap state: position the VT cursor at the last
    # column, then emit the character at (new_pos - 1) to trigger the
    # terminal's deferred autowrap. This character occupies the last
    # column, so overwriting it with itself is harmless.
    if ($new_pending) {
        my $col_0indexed = $new_col - 1;
        if ($col_0indexed < $term_width - 1) {
            print "\e[" . ($term_width - 1 - $col_0indexed) . "C";
        }
        $self->_emit_text(substr($$input_ref, $$new_pos_ref - 1, 1))
            if $$new_pos_ref > 0;
    }

    # Update tracking.
    $self->{last_cursor_input_row} = $new_input_row;
    $self->{last_cursor_input_col} = $new_col;
    $self->{last_cursor_input_pending} = $new_pending;

    if (should_log('DEBUG')) {
        log_debug('ReadLine', "reposition_cursor: tracking set to input_row=$new_input_row, col=$new_col, pending=$new_pending");
    }
}

=head2 _move_cursor_to_end

Move the cursor to the end of the input buffer without redrawing it.

Used when submitting the input. The cursor is often left on an earlier
row of a multi-row input after the user scrolls back to edit part of it.
Submitting from there emits the submit newline in the middle of the
input, which leaves the tail of the input on screen and starts the next
output (busy indicator, echoed user message) inside the input line
instead of after it.

The cursor is moved with reposition_cursor() so the pending-wrap and
scroll-offset edge cases are handled by the same code path used for
ordinary cursor movement. No-op when the cursor is already at the end
of the input.

Arguments:
- $input_ref:      Reference to the input string
- $cursor_pos_ref: Reference to the cursor position (updated in place)
- $prompt:         Prompt string (for calculating display positions)

=cut

sub _move_cursor_to_end {
    my ($self, $input_ref, $cursor_pos_ref, $prompt) = @_;

    my $end_pos = length($$input_ref);
    return if $$cursor_pos_ref == $end_pos;

    my $old_pos = $$cursor_pos_ref;
    $$cursor_pos_ref = $end_pos;
    $self->reposition_cursor(\$old_pos, $cursor_pos_ref, $input_ref, $prompt);
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
    my $killed = substr($$input_ref, $$cursor_pos_ref, $pos - $$cursor_pos_ref);
    substr($$input_ref, $$cursor_pos_ref, $pos - $$cursor_pos_ref, '');
    $self->kill_ring_save($killed);
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

    my $killed = substr($$input_ref, $pos, $old_pos - $pos);
    substr($$input_ref, $pos, $old_pos - $pos, '');
    $$cursor_pos_ref = $pos;
    $self->kill_ring_save($killed);
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
