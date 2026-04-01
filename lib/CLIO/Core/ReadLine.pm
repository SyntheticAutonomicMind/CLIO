# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Core::ReadLine;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
use CLIO::Core::Logger qw(should_log log_debug log_warning);

# Ensure STDOUT is autoflushed for immediate terminal response
$| = 1;
use feature 'say';
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

{
    # Cache Unicode::GCString availability check
    my $HAS_UNICODE_GCSTRING;
    sub _check_gcstring {
        unless (defined $HAS_UNICODE_GCSTRING) {
            $HAS_UNICODE_GCSTRING = eval { require Unicode::GCString; 1 } ? 1 : 0;
        }
        return $HAS_UNICODE_GCSTRING;
    }
}

sub _display_width {
    my ($str) = @_;
    return 0 unless defined $str && length($str);

    # Use Unicode::GCString for accurate width if available
    if (_check_gcstring()) {
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
        # Track where the cursor was positioned in the last redraw
        # This allows us to know exactly where to start the next redraw from
        last_cursor_row => 0,
        last_cursor_col => 0,
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
clear any leftover characters. Much faster than full redraw for mid-line
edits since it skips the prompt and text before the cursor.

=cut

sub _redraw_from_cursor {
    my ($self, $input_ref, $cursor_pos_ref, $prompt) = @_;

    my $term_width = $self->_get_term_width();
    my $prompt_disp = $self->_get_prompt_disp($prompt);
    my $input_len = length($$input_ref);

    # Text from cursor to end
    my $tail = substr($$input_ref, $$cursor_pos_ref);
    my $tail_disp = _display_width($tail);

    # Where cursor is right now (display columns from start of line)
    my $cursor_prefix_disp = _display_width(substr($$input_ref, 0, $$cursor_pos_ref));
    my $cursor_total = $prompt_disp + $cursor_prefix_disp;
    my $cursor_row = int($cursor_total / $term_width);
    my $cursor_col = ($cursor_total % $term_width) + 1;

    # Save cursor position, print tail, clear to end of screen, restore cursor
    print "\e7";        # save cursor
    print $tail;        # overwrite from cursor to end
    print "\e[J";       # clear any leftover chars beyond new end
    print "\e8";        # restore cursor

    # Update display_lines tracking
    my $total_disp = $prompt_disp + _display_width($$input_ref);
    my $new_display_lines = $total_disp > 0 ? int(($total_disp - 1) / $term_width) + 1 : 1;
    $self->{display_lines} = $new_display_lines;
    $self->{last_cursor_row} = $cursor_row;
    $self->{last_cursor_col} = $cursor_col;
}

sub readline {
    my ($self, $prompt) = @_;
    
    $prompt //= $self->{prompt};
    
    # Reset display lines tracking for new input
    $self->{display_lines} = 1;
    $self->{last_cursor_row} = 0;
    $self->{last_cursor_col} = 0;
    
    # Reset performance caches for this readline session
    $self->{_prompt_disp_cache} = undef;
    $self->{_term_width_cache} = undef;
    $self->{_term_width_time} = 0;
    
    # Print prompt
    print $prompt;
    
    # Set terminal to raw mode
    ReadMode('raw');
    
    my $input = '';
    my $cursor_pos = 0;  # Position in $input
    my $completion_state = {
        active => 0,
        candidates => [],
        index => 0,
        original_input => '',
    };
    
    while (1) {
        my $char = ReadKey(0);  # Blocking read
        
        # Handle undefined - can happen if sysread is interrupted by signal
        unless (defined $char) {
            # ReadKey can return undef when sysread() is interrupted
            # by a signal (EINTR). This is NORMAL and should just retry immediately.
            # DO NOT SLEEP - that creates a busy-wait loop burning 100% CPU!
            # The blocking sysread will properly wait when not interrupted.
            next;
        }
        
        my $ord = ord($char);
        
        log_debug('ReadLine', "char='$char' ord=$ord pos=$cursor_pos input='$input'");
        
        # Tab key (completion)
        if ($ord == 9) {
            $self->handle_tab(\$input, \$cursor_pos, $completion_state);
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
            print "\r\n";  # Return to column 0 and newline
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
                print "\r\n";  # Return to column 0 and newline
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
            print "^C\n";
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
                    # Optimization: if deleting from end, we can handle it locally
                    # This avoids full redraw and prevents scroll issues when unwrapping.

                    my $term_width = $self->_get_term_width();
                    my $prompt_disp = $self->_get_prompt_disp($prompt);
                    my $input_before = substr($input, 0, $cursor_pos);  # after decrement
                    my $cursor_disp  = _display_width($input_before);

                    # Display-column positions of old and new cursor
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
                    if ($old_row > $new_row ||
                        ($new_total_pos > 0 && $new_total_pos % $term_width == 0) ||
                        $deleted_width > 1 ||
                        _display_width($input) != length($input))
                    {
                        $self->redraw_line(\$input, \$cursor_pos, $prompt);
                    } else {
                        # Fast path: single-column ASCII character at end of line.
                        # Move back, overwrite with space, move back again.
                        print "\b \b";

                        # Update cursor tracking
                        my $new_col = ($new_total_pos % $term_width) + 1;
                        $self->{last_cursor_row} = $new_row;
                        $self->{last_cursor_col} = $new_col;

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
            # Use a timeout of 500ms to accommodate slow network connections (SSH)
            # while staying responsive if sequence ends early
            # Most modern terminals send complete sequences within 50ms
            for my $i (1..5) {
                my $next = ReadKey(0.5);  # 500ms timeout between bytes
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
            if ($cursor_pos > 0) {
                my $old_pos = $cursor_pos;
                my $pos = $cursor_pos;
                $pos--;
                # Skip whitespace backward
                while ($pos > 0 && substr($input, $pos - 1, 1) =~ /\s/) {
                    $pos--;
                }
                # Skip non-whitespace backward
                while ($pos > 0 && substr($input, $pos - 1, 1) !~ /\s/) {
                    $pos--;
                }
                substr($input, $pos, $old_pos - $pos, '');
                $cursor_pos = $pos;
                $self->redraw_line(\$input, \$cursor_pos, $prompt);
            }
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
                print $char;

                # Update cursor tracking using display-column widths, not codepoint counts.
                my $term_width = $self->_get_term_width();
                my $prompt_disp = $self->_get_prompt_disp($prompt);
                my $input_so_far  = substr($input, 0, $cursor_pos);
                my $total_pos     = $prompt_disp + _display_width($input_so_far);

                my $new_row = int($total_pos / $term_width);
                my $new_col = ($total_pos % $term_width) + 1;

                # Update display lines if we wrapped to a new line
                if ($new_row >= $self->{display_lines}) {
                    $self->{display_lines} = $new_row + 1;
                }

                $self->{last_cursor_row} = $new_row;
                $self->{last_cursor_col} = $new_col;
            } else {
                # Inserting in middle - partial redraw from cursor
                $self->_redraw_from_cursor(\$input, \$cursor_pos, $prompt);
            }
        }
    }
}

=head2 handle_tab

Handle tab completion

=cut

sub handle_tab {
    my ($self, $input_ref, $cursor_pos_ref, $state) = @_;
    
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
            $self->redraw_line($input_ref, $cursor_pos_ref, $self->{prompt});
            $state->{active} = 0;  # Done
            log_debug('ReadLine', "Single match, completed to: '$$input_ref'");
            return;
        }
        
        # Multiple candidates - show first one
        $$input_ref = $candidates[0];
        $$cursor_pos_ref = length($$input_ref);
        $self->redraw_line($input_ref, $cursor_pos_ref, $self->{prompt});
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
        $self->redraw_line($input_ref, $cursor_pos_ref, $self->{prompt});
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
        my $len = length($$input_ref);
        if ($$cursor_pos_ref < $len) {
            my $pos = $$cursor_pos_ref;
            # Skip whitespace forward
            while ($pos < $len && substr($$input_ref, $pos, 1) =~ /\s/) {
                $pos++;
            }
            # Skip non-whitespace forward
            while ($pos < $len && substr($$input_ref, $pos, 1) !~ /\s/) {
                $pos++;
            }
            substr($$input_ref, $$cursor_pos_ref, $pos - $$cursor_pos_ref, '');
            $self->redraw_line($input_ref, $cursor_pos_ref, $prompt);
        }
        return;
    }
    
    # Alt+Backspace / ESC + DEL (0x7F) - kill word backward
    if ($seq eq "\e\x7f") {
        if ($$cursor_pos_ref > 0) {
            my $old_pos = $$cursor_pos_ref;
            my $pos = $$cursor_pos_ref - 1;
            # Skip whitespace backward
            while ($pos > 0 && substr($$input_ref, $pos - 1, 1) =~ /\s/) {
                $pos--;
            }
            # Skip non-whitespace backward
            while ($pos > 0 && substr($$input_ref, $pos - 1, 1) !~ /\s/) {
                $pos--;
            }
            substr($$input_ref, $pos, $old_pos - $pos, '');
            $$cursor_pos_ref = $pos;
            $self->redraw_line($input_ref, $cursor_pos_ref, $prompt);
        }
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
        log_warning('ReadLine', "History position out of bounds: $self->{history_pos}");
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
            log_warning('ReadLine', "History position out of bounds: $self->{history_pos}");
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

    # Calculate display-column positions of old and new cursor.
    # $$old_pos_ref and $$new_pos_ref are codepoint offsets into $$input_ref.
    # We need to convert them to display columns by measuring the display width
    # of the prefix up to each offset.
    my $old_prefix_disp = _display_width(substr($$input_ref, 0, $$old_pos_ref));
    my $new_prefix_disp = _display_width(substr($$input_ref, 0, $$new_pos_ref));

    my $old_total_pos = $prompt_disp + $old_prefix_disp;
    my $new_total_pos = $prompt_disp + $new_prefix_disp;

    # Calculate row and column for both positions
    # Formula: row = pos / width, col = (pos % width) + 1
    my $old_row = int($old_total_pos / $term_width);
    my $old_col = ($old_total_pos % $term_width) + 1;

    my $new_row = int($new_total_pos / $term_width);
    my $new_col = ($new_total_pos % $term_width) + 1;

    if (should_log('DEBUG')) {
        log_debug('ReadLine', "reposition_cursor: old_pos=$$old_pos_ref, new_pos=$$new_pos_ref");
        log_debug('ReadLine', "reposition_cursor: old_total=$old_total_pos, new_total=$new_total_pos");
        log_debug('ReadLine', "reposition_cursor: from ($old_row,$old_col) to ($new_row,$new_col)");
    }

    # Currently at old position (old_row, old_col)
    # Need to move to new position (new_row, new_col)

    if ($new_row < $old_row) {
        # Moving UP to an earlier line (e.g., scrolling left past line boundary)
        my $rows_up = $old_row - $new_row;
        print "\e[${rows_up}A";
        # Use absolute column positioning to avoid VT100 pending wrap state issues
        print "\r";  # Go to column 1
        if ($new_col > 1) {
            my $cols_right = $new_col - 1;
            print "\e[${cols_right}C";
        }
    } elsif ($new_row > $old_row) {
        # Moving DOWN to a later line (e.g., scrolling right past line boundary)
        my $rows_down = $new_row - $old_row;
        print "\e[${rows_down}B";
        # Use absolute column positioning
        print "\r";  # Go to column 1
        if ($new_col > 1) {
            my $cols_right = $new_col - 1;
            print "\e[${cols_right}C";
        }
    } else {
        # Same row - use absolute column positioning to be safe
        # This handles the case where old_col was at term_width (pending wrap state)
        print "\r";  # Go to column 1
        if ($new_col > 1) {
            my $cols_right = $new_col - 1;
            print "\e[${cols_right}C";
        }
    }
    
    # Update tracked cursor position
    $self->{last_cursor_row} = $new_row;
    $self->{last_cursor_col} = $new_col;
    
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
        log_warning('ReadLine', "Cursor position was negative ($$cursor_pos_ref), clamping to 0");
        $$cursor_pos_ref = 0;
    } elsif ($$cursor_pos_ref > $input_len) {
        log_warning('ReadLine', "Cursor position exceeded input length ($$cursor_pos_ref > $input_len), clamping to $input_len");
        $$cursor_pos_ref = $input_len;
    }

    # Get terminal width for proper wrapping
    my $term_width = $self->_get_term_width();
    my $prompt_disp = $self->_get_prompt_disp($prompt);

    # Calculate total display columns occupied by prompt + full input
    my $input_disp  = _display_width($$input_ref);
    my $total_disp  = $prompt_disp + $input_disp;

    # Calculate how many terminal lines the new content occupies
    my $new_lines_needed = $total_disp > 0 ? int(($total_disp - 1) / $term_width) + 1 : 1;

    # Helper: convert a display-column position to (row, col)
    # row = pos / width, col = (pos % width) + 1
    my $pos_to_rowcol = sub {
        my ($pos) = @_;
        my $row = int($pos / $term_width);
        my $col = ($pos % $term_width) + 1;
        return ($row, $col);
    };

    my $old_display_lines = $self->{display_lines} || 1;
    my $max_lines = $old_display_lines > $new_lines_needed ? $old_display_lines : $new_lines_needed;

    if (should_log('DEBUG')) {
        log_debug('ReadLine', "redraw_line: input_len=$input_len, prompt_disp=$prompt_disp, input_disp=$input_disp, total_disp=$total_disp");
        log_debug('ReadLine', "redraw_line: term_width=$term_width, new_lines_needed=$new_lines_needed");
        log_debug('ReadLine', "redraw_line: old_display_lines=$old_display_lines, max_lines=$max_lines");
        log_debug('ReadLine', "redraw_line: last cursor was at row=$self->{last_cursor_row}, col=$self->{last_cursor_col}");
    }

    # Move to column 1 of current line, then back to row 0 of our input area
    print "\r";
    my $lines_to_move_up = $self->{last_cursor_row};
    if ($lines_to_move_up > 0) {
        print "\e[${lines_to_move_up}A";
    }

    # Clear from here to end of screen, then redraw prompt + input
    print "\e[J";
    print $prompt, $$input_ref;

    # Update display_lines for next redraw
    $self->{display_lines} = $new_lines_needed;

    # After printing, calculate the cursor's current position (end of output).
    # When we print exactly N*term_width display columns, the terminal enters
    # "pending wrap" state: cursor sits at column term_width of the last row.
    my $end_pos = $total_disp;
    my ($end_row, $end_col);
    if ($end_pos > 0 && $end_pos % $term_width == 0) {
        # Pending wrap: cursor is at last column of current row
        $end_row = int($end_pos / $term_width) - 1;
        $end_col = $term_width;
    } else {
        ($end_row, $end_col) = $pos_to_rowcol->($end_pos);
    }

    # Calculate where we WANT the cursor to be (at $$cursor_pos_ref codepoints into input)
    my $cursor_prefix_disp = _display_width(substr($$input_ref, 0, $$cursor_pos_ref));
    my $desired_pos = $prompt_disp + $cursor_prefix_disp;
    my ($desired_row, $desired_col);
    if ($desired_pos > 0 && $desired_pos % $term_width == 0) {
        # At boundary: cursor at last column of current row
        $desired_row = int($desired_pos / $term_width) - 1;
        $desired_col = $term_width;
    } else {
        ($desired_row, $desired_col) = $pos_to_rowcol->($desired_pos);
    }

    if (should_log('DEBUG')) {
        log_debug('ReadLine', "redraw_line: end position: row=$end_row, col=$end_col");
        log_debug('ReadLine', "redraw_line: desired cursor: row=$desired_row, col=$desired_col");
    }

    # Reposition cursor to desired location if necessary
    if ($desired_row != $end_row || $desired_col != $end_col) {
        if ($desired_row < $end_row) {
            my $rows_up = $end_row - $desired_row;
            print "\e[${rows_up}A";
        } elsif ($desired_row > $end_row) {
            my $rows_down = $desired_row - $end_row;
            print "\e[${rows_down}B";
        }

        # Absolute column positioning avoids pending-wrap ambiguity
        print "\r";  # Go to column 1
        if ($desired_col > 1) {
            my $cols_right = $desired_col - 1;
            print "\e[${cols_right}C";
        }
    }

    # Save final cursor position for next redraw
    $self->{last_cursor_row} = $desired_row;
    $self->{last_cursor_col} = $desired_col;
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
