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
- Standard readline/emac-mode key bindings: Ctrl-A/E (beginning/end of
  line), Ctrl-B/F (backward/forward char), Ctrl-K (kill to end),
  Ctrl-U (kill to beginning), Ctrl-W (kill word), Ctrl-T (transpose),
  Ctrl-L (clear screen), Ctrl-Y (yank from kill ring), Alt+Y (yank-pop)

=head2 DESIGN: Compute-from-state cursor tracking

Cursor positions are NEVER tracked incrementally via shadow state that
can desync from the terminal. Instead, B<_cursor_at_codepoint> is the
single source of truth: it walks the input string character-by-character
and computes the physical (row, col) for any codepoint offset. Every
cursor movement, redraw, and reposition uses this pure function.

Incremental state retained for fast-path operations and viewport math
(see C<new()> for the full list):
- C<last_cursor_row>: cursor screen row after the last C<_emit_text>
  call (clamped to max_row). Read by C<_emit_text> as the starting row
  for the next emit. Written by C<_emit_text>, C<_emit_newline>,
  C<reposition_cursor>, C<redraw_line>, C<_redraw_line_external>.
- C<last_cursor_col>: cursor screen column after the last C<_emit_text>
  call. Read by C<_emit_text> as the starting column for the next emit.
  Written back by every cursor-moving operation.
- C<scroll_offset>: DERIVED state — C<max(0, display_lines - term_height)>.
  Recomputed by C<_refresh_geometry> whenever content or geometry changes.
  Used by C<_input_row_to_screen_row> to convert input rows to screen rows.
- C<last_cursor_input_row>: the cursor's row within the input buffer
  (0-indexed, NOT a screen row). Written by C<redraw_line>,
  C<reposition_cursor>, C<_redraw_line_external>, and the fast-path
  insert/backspace. Read by C<redraw_line> and C<_redraw_line_external>
  to compute C<rows_to_top> (how many rows to move up before clearing).

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
        # Cursor position tracking. Updated by _emit_text (clamped to
        # max_row), reposition_cursor, redraw_line. Read only by _emit_text
        # as the starting point for the next emit.
        last_cursor_row => 0,
        last_cursor_col => 1,
        # How many input rows are scrolled off the top of the screen.
        # DERIVED state (max(0, display_lines - term_height)), recomputed
        # by _refresh_geometry whenever content or geometry changes.
        # Used by _input_row_to_screen_row to convert input rows to screen rows.
        scroll_offset => 0,
        # How many rows the cursor is from the top of the input area
        # (0 = first row). Written by redraw_line, reposition_cursor,
        # _redraw_line_external, and the fast-path insert/backspace.
        last_cursor_input_row => 0,
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

=head2 _refresh_geometry

Recompute all derived geometry state from the current input and prompt:
display_lines, scroll_offset, last_cursor_input_row. This is the
single place where derived geometry is updated, ensuring consistency.

scroll_offset = max(0, display_lines - term_height)
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
    $self->{scroll_offset} = _max(0, $display_lines - $term_height);
    my ($cursor_input_row, $cursor_col) = $self->_cursor_at_codepoint($input, $cursor_pos, $prompt);
    $self->{last_cursor_input_row} = $cursor_input_row;
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

Position semantics match the terminal's autowrap behavior: a char placed
at the last column (col=term_width) occupies that column, and the cursor
advances to (row+1, col=1). The cursor is never reported at col > term_width.

This is the single source of truth for cursor position. Every cursor
movement, redraw, and reposition computes from this pure function.

B<Note:> This function is pure — it does NOT modify any object state.
Callers pass its return values through C<_input_row_to_screen_row>
(which reads the derived C<scroll_offset>) to get screen coordinates.

Returns: ($row, $col) where $row is 0-indexed (input row, NOT screen row)
and $col is 1-indexed.

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
    # boundary. Two wrap checks per char:
    #   1. Pre-place: if the char doesn't fit at the current col, wrap first.
    #   2. Post-place: if the cursor advanced past the last col, the terminal
    #      autowrapped (char at col=term_width -> cursor at row+1, col=1).
    # The previous implementation tracked pending=1 when col reached
    # term_width and modeled the wrap as "wrap first, then place". That
    # mis-modeled autowrap: the terminal places the char at col=term_width
    # THEN wraps the cursor. The pending version returned col=2 after the
    # wrap when the actual position was col=1, causing every cursor position
    # past the first wrap to be off by one column.
    for my $i (0 .. $cp - 1) {
        my $ch = substr($input, $i, 1);
        my $w = _display_width($ch);

        # Pre-place wrap: char doesn't fit at the current col.
        if ($col + $w - 1 > $term_width) {
            $row += 1;
            $col = 1;
        }
        $col += $w;
        # Post-place wrap: cursor advanced past last col (autowrap).
        if ($col > $term_width) {
            $row += 1;
            $col = 1;
        }
    }

    return ($row, $col);
}

=head2 _input_row_to_screen_row

Convert an input row (as returned by _cursor_at_codepoint) to a
screen row, accounting for terminal scrolling.

When the input is taller than the terminal, the terminal scrolls the
content up. The visible portion is the last term_height rows of the
input. scroll_offset (derived by _refresh_geometry) tracks how many
input rows are above the visible window.

Returns: screen row (0-indexed, clamped to 0..max_row).

=cut

sub _input_row_to_screen_row {
    my ($self, $input_row) = @_;
    my $term_height = $self->_get_term_height();
    my $max_row = $term_height - 1;
    my $scroll_offset = $self->{scroll_offset} || 0;
    my $screen_row = $input_row - $scroll_offset;
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

Print $text and update last_cursor_* tracking to reflect the cursor's
actual position after the text is rendered.

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
    my $visible = _strip_ansi($text);

    return unless length $visible;

    my $term_width = $self->_get_term_width();
    my $row = $self->{last_cursor_row};
    my $col = $self->{last_cursor_col};

    # Track last_cursor_* with the terminal's autowrap semantics: a char
    # placed at col=term_width wraps the cursor to (row+1, col=1) AFTER
    # the char is placed. The previous "pending wrap first, then place"
    # model mis-modeled autowrap and left the cursor one column past the
    # terminal's actual position whenever a wrap occurred (col=2 instead
    # of col=1 on the new row, and similarly for every subsequent row).
    for my $i (0 .. length($visible) - 1) {
        my $ch = substr($visible, $i, 1);
        my $w = _display_width($ch);

        # Pre-place wrap: char doesn't fit at the current col.
        if ($col + $w - 1 > $term_width) {
            $row += 1;
            $col = 1;
        }
        $col += $w;
        # Post-place wrap: cursor advanced past last col (autowrap).
        if ($col > $term_width) {
            $row += 1;
            $col = 1;
        }
    }

    # If the row went past the bottom of the screen, the terminal
    # scrolled. Clamp last_cursor_row to the visible area so the next
    # _emit_text call continues from the correct screen position.
    # scroll_offset is NOT accumulated here — it is derived by
    # _refresh_geometry from the total content height.
    my $term_height = $self->_get_term_height();
    my $max_row = $term_height - 1;
    if ($row > $max_row) {
        $row = $max_row;
        $col = 1;
    }

    $self->{last_cursor_row} = $row;
    $self->{last_cursor_col} = $col;
}

=head2 _emit_newline

Emit a newline: move to column 1 of the next row. Updates tracking.

=cut

sub _emit_newline {
    my ($self) = @_;
    print "\r\n";
    # Newline: move to (row+1, col 1).
    my $term_height = $self->_get_term_height();
    my $max_row = $term_height - 1;
    my $row = $self->{last_cursor_row} + 1;
    if ($row > $max_row) {
        $row = $max_row;
    }
    $self->{last_cursor_row} = $row;
    $self->{last_cursor_col} = 1;
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
        # "^C" would land at col=term_width, then col=term_width+1 after
        # the second char — terminal autowraps to next row, col=1.
        $row += 1;
        $col = 1;
    }
    $self->{last_cursor_row} = $row;
    $self->{last_cursor_col} = $col;
    $self->_emit_newline();  # The trailing \n
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
    my $new_lines_needed = $self->_compute_display_lines($total_disp);

    # Save old cursor_input_row before _refresh_geometry overwrites it.
    # redraw_line needs to know where the cursor WAS (to move up the
    # right number of rows), not where it is now.
    my $old_cursor_input_row = $self->{last_cursor_input_row} || 0;
    my $old_display_lines = $self->{display_lines} || 1;

    # Derive scroll_offset and last_cursor_input_row from total content.
    $self->_refresh_geometry($$input_ref, $$cursor_pos_ref, $prompt);

    if (should_log('DEBUG')) {
        log_debug('ReadLine', "redraw_line: input_len=$input_len, prompt_disp=$prompt_disp, input_disp=$input_disp, total_disp=$total_disp");
        log_debug('ReadLine', "redraw_line: term_width=$term_width, new_lines_needed=$new_lines_needed");
        log_debug('ReadLine', "redraw_line: old_display_lines=$old_display_lines, old_cursor_input_row=$old_cursor_input_row");
        log_debug('ReadLine', "redraw_line: last cursor was at row=$self->{last_cursor_row}, col=$self->{last_cursor_col}");
    }

    # Move to (row 0, col 1) of the input area.
    # Move up by the cursor's actual distance from the top of the input
    # (last_cursor_input_row), NOT by display_lines - 1 which assumes
    # the cursor is at the bottom. When the user navigates back to a
    # previous line with arrow keys, the cursor is on a middle row;
    # using display_lines - 1 would overshoot past the top of the
    # input, scrolling terminal content above the input upward by one
    # row per keystroke.
    print "\r";
    $self->{last_cursor_col} = 1;
    my $rows_to_top = $old_cursor_input_row;
    # Clamp to old_display_lines - 1 as a safety net for stale state.
    if ($rows_to_top > $old_display_lines - 1) {
        $rows_to_top = $old_display_lines - 1;
    }
    if ($rows_to_top < 0) { $rows_to_top = 0; }
    if ($rows_to_top > 0) {
        print "\e[${rows_to_top}A";
    }
    $self->{last_cursor_row} = 0;

    # Clear from here to end of screen, then redraw prompt + input
    print "\e[J";
    $self->_emit_text($prompt);
    $self->_emit_text($$input_ref);

    # After printing, the terminal cursor is at the end of the output.
    # Compute the desired cursor position from input state (NOT from
    # last_cursor_* or arithmetic division -- both can be wrong,
    # especially with wide characters).
    my ($desired_input_row, $desired_col) = $self->_cursor_at_codepoint($$input_ref, $$cursor_pos_ref, $prompt);

    # Compute end position from input state too.
    my ($end_input_row, $end_col) = $self->_cursor_at_codepoint($$input_ref, length($$input_ref), $prompt);

    # Convert input rows to screen rows (account for terminal scrolling
    # when the input is taller than the screen).
    my $desired_row = $self->_input_row_to_screen_row($desired_input_row);
    my $end_row = $self->_input_row_to_screen_row($end_input_row);

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
    $self->{last_cursor_input_row} = $desired_input_row;
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

    # Save old cursor_input_row before _refresh_geometry overwrites it.
    my $old_cursor_input_row = $self->{last_cursor_input_row} || 0;

    # Move to column 0 of current row, clear to end of screen,
    # then redraw prompt + input.
    print "\r";
    # Move up to the top of the input area (same logic as redraw_line).
    my $old_display_lines = $self->{display_lines} || 1;
    my $rows_to_top = $old_cursor_input_row;
    if ($rows_to_top > $old_display_lines - 1) {
        $rows_to_top = $old_display_lines - 1;
    }
    if ($rows_to_top > 0) {
        print "\e[${rows_to_top}A";
    }
    $self->{last_cursor_col} = 1;
    $self->{last_cursor_row} = 0;
    print "\e[J";
    $self->_emit_text($prompt);
    $self->_emit_text($$input_ref);

    # Derive scroll_offset from total content.
    $self->_refresh_geometry($$input_ref, $$cursor_pos_ref, $prompt);

    # Compute cursor position from input state.
    my ($cursor_input_row, $cursor_col) = $self->_cursor_at_codepoint($$input_ref, $$cursor_pos_ref, $prompt);

    # Compute end-of-input position from input state.
    my ($end_input_row, $end_col) = $self->_cursor_at_codepoint($$input_ref, length($$input_ref), $prompt);

    # Convert input rows to screen rows (account for terminal scrolling).
    my $cursor_row = $self->_input_row_to_screen_row($cursor_input_row);
    my $end_row = $self->_input_row_to_screen_row($end_input_row);

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

    $self->{last_cursor_row} = $cursor_row;
    $self->{last_cursor_col} = $cursor_col;
    $self->{last_cursor_input_row} = $cursor_input_row;
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
    $self->{scroll_offset} = 0;
    $self->{last_cursor_input_row} = 0;

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
        # Derive geometry from the prefilled content.
        $self->_refresh_geometry($input, $cursor_pos, $prompt);
    }

    while (1) {
        my $char;

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
            $char = ReadKey(0);

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
                    # Optimization: if deleting from end, try the fast-path
                    # (move back, overwrite with space, move back). Fall back
                    # to full redraw when the deletion crosses a row boundary
                    # or involves non-ASCII content.

                    my $term_width = $self->_get_term_width();
                    my $prompt_disp = $self->_get_prompt_disp($prompt);

                    # Compute old and new cursor positions from input state.
                    # We reconstruct the old input by re-inserting the deleted
                    # text at the deletion point.
                    my $old_input = substr($input, 0, $cursor_pos) . $deleted . substr($input, $cursor_pos);
                    my $old_cp = $cursor_pos + length($deleted);
                    my ($old_row, $old_col) = $self->_cursor_at_codepoint($old_input, $old_cp, $prompt);
                    my ($new_row, $new_col) = $self->_cursor_at_codepoint($input, $cursor_pos, $prompt);

                    my $input_disp = _display_width($input);

                    # Fast path is safe when:
                    # - cursor stays on the same row (no wrap boundary crossing)
                    # - deleted cluster is exactly 1 column (no wide chars)
                    # - remaining input is ASCII-only ($display_width == length)
                    if ($old_row == $new_row && $old_col > 1 && $deleted_width == 1 && $input_disp == length($input)) {
                        # Fast path: single-column ASCII at end of line.
                        print "\b \b";

                        # Update tracking. Recompute scroll_offset from
                        # total content (NOT accumulated from _emit_text).
                        $self->{last_cursor_col} -= 1;
                        $self->{last_cursor_col} = 1 if $self->{last_cursor_col} < 1;

                        my $total_disp = $prompt_disp + $input_disp;
                        $self->{display_lines} = $self->_compute_display_lines($total_disp);
                        $self->{scroll_offset} = _max(0, $self->{display_lines} - $self->_get_term_height());
                        $self->{last_cursor_input_row} = $self->{display_lines} - 1;
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
        # Clears the terminal and redraws the prompt + input at the top.
        if ($ord == 12) {
            print "\e[2J\e[H";
            # After clearing, the cursor is at (0,0) and the screen is blank.
            # Reset scroll and display tracking so redraw_line starts fresh.
            $self->{scroll_offset} = 0;
            $self->{last_cursor_row} = 0;
            $self->{last_cursor_col} = 1;
            $self->{display_lines} = 1;
            $self->{last_cursor_input_row} = 0;
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

                # Compute display_lines from actual content width, NOT from
                # last_cursor_row (a screen row). When the terminal scrolls
                # because the input overflowed the bottom of the screen,
                # _emit_text clamps last_cursor_row to max_row, so deriving
                # display_lines from it produces term_height instead of the
                # real content height. A later redraw_line would then move up
                # by (term_height - 1) rows, overshooting past the input into
                # content already on screen and wiping it with \e[J.
                #
                # The backspace fast-path already uses _compute_display_lines;
                # the insert path must too. This is O(1) for ASCII (the common
                # case) since _display_width falls back to length().
                my $total_disp = $self->_get_prompt_disp($prompt) + _display_width($input);
                $self->{display_lines} = $self->_compute_display_lines($total_disp);
                $self->{scroll_offset} = _max(0, $self->{display_lines} - $self->_get_term_height());
                # Cursor is at the end of the input, so it's on the last row.
                $self->{last_cursor_input_row} = $self->{display_lines} - 1;
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

        return 0 unless @candidates;

        if (@candidates == 1) {
            $$input_ref = $candidates[0];
            $$cursor_pos_ref = length($$input_ref);
            $self->redraw_line($input_ref, $cursor_pos_ref, $prompt);
            $state->{active} = 0;
            log_debug('ReadLine', "Single match, completed to: '$$input_ref'");
            return 1;
        }

        $$input_ref = $candidates[0];
        $$cursor_pos_ref = length($$input_ref);
        $self->redraw_line($input_ref, $cursor_pos_ref, $prompt);
        log_debug('ReadLine', "Multiple matches, showing first: '$$input_ref'");
        return 1;

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
        return 1;
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
- ESC y - Alt+Y (yank-pop: cycle through kill ring)
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

    $prompt //= '';

    # Ensure scroll_offset is derived from current content so
    # _input_row_to_screen_row gives correct screen rows.
    $self->_refresh_geometry($$input_ref, $$new_pos_ref, $prompt);

    my $term_width = $self->_get_term_width();

    # Compute BOTH source and target from input state. _cursor_at_codepoint
    # is a pure function: given the same (input, cp, prompt), it always
    # returns the same (row, col). No incrementally-tracked state.
    my ($old_input_row, $old_col) = $self->_cursor_at_codepoint($$input_ref, $$old_pos_ref, $prompt);
    my ($new_input_row, $new_col) = $self->_cursor_at_codepoint($$input_ref, $$new_pos_ref, $prompt);

    # Convert input rows to screen rows (account for terminal scrolling
    # when the input is taller than the screen).
    my $old_row = $self->_input_row_to_screen_row($old_input_row);
    my $new_row = $self->_input_row_to_screen_row($new_input_row);

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

    # Update tracking.
    $self->{last_cursor_row} = $new_row;
    $self->{last_cursor_col} = $new_col;
    $self->{last_cursor_input_row} = $new_input_row;

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
