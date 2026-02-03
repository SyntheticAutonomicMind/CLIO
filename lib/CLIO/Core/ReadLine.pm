package CLIO::Core::ReadLine;

use strict;
use warnings;
use CLIO::Core::Logger qw(should_log);
use feature 'say';
use CLIO::Compat::Terminal qw(ReadMode ReadKey GetTerminalSize);

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

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        prompt => $args{prompt} || '> ',
        history => [],
        history_pos => -1,
        completer => $args{completer},  # CLIO::Core::TabCompletion instance
        debug => $args{debug} || 0,
        max_history => $args{max_history} || 1000,
        # Track how many terminal lines the current input occupies
        # This is MEASURED (from last redraw), not calculated
        display_lines => 1,
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

sub readline {
    my ($self, $prompt) = @_;
    
    $prompt //= $self->{prompt};
    
    # Reset display lines tracking for new input
    $self->{display_lines} = 1;
    
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
        
        print STDERR "[DEBUG][ReadLine] char='$char' ord=$ord pos=$cursor_pos input='$input'\n" if should_log('DEBUG');
        
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
            # If there's input, Ctrl-D deletes forward
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
                # Remove character before cursor
                substr($input, $cursor_pos - 1, 1, '');
                $cursor_pos--;
                $self->redraw_line(\$input, \$cursor_pos, $prompt);
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
                
                # Stop if we've completed the sequence (ends with letter or ~)
                if ($next =~ /[A-Za-z~]/) {
                    last;
                }
            }
            
            print STDERR "[DEBUG][ReadLine] Raw escape sequence bytes: " . join(' ', map { sprintf('0x%02X', ord($_)) } split //, $seq) . "\n" if should_log('DEBUG');
            
            $self->handle_escape_sequence($seq, \$input, \$cursor_pos, $prompt);
            next;
        }
        
        # Ctrl-A (beginning of line)
        if ($ord == 1) {
            $cursor_pos = 0;
            $self->redraw_line(\$input, \$cursor_pos, $prompt);
            next;
        }
        
        # Ctrl-E (end of line)
        if ($ord == 5) {
            $cursor_pos = length($input);
            $self->redraw_line(\$input, \$cursor_pos, $prompt);
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
        
        # Regular printable character (including multi-byte UTF-8)
        # Allow any character not caught by special handlers above
        # For multi-byte UTF-8 chars, $ord will be >= 128 (first byte of sequence)
        # For single-byte ASCII, $ord will be >= 32
        if ($ord >= 32 || ($ord >= 128)) {
            # This is either ASCII printable or the start of a UTF-8 multi-byte sequence
            substr($input, $cursor_pos, 0, $char);
            $cursor_pos += length($char);  # Increment by actual character length
            $self->redraw_line(\$input, \$cursor_pos, $prompt);
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
    
    print STDERR "[DEBUG][ReadLine] Tab pressed, input='$current_input'\n" if should_log('DEBUG');
    
    # First tab - initialize completion
    unless ($state->{active}) {
        $state->{original_input} = $$input_ref;
        $state->{active} = 1;
        $state->{index} = 0;
        
        # For /edit commands, extract just the filename part for completion
        my $completion_text = $current_input;
        my $prefix = '';
        
        if ($current_input =~ m{^(/edit\s+)(.*)$}) {
            $prefix = $1;
            $completion_text = $2;
            print STDERR "[DEBUG][ReadLine] /edit detected, completing: '$completion_text'\n" if should_log('DEBUG');
        }
        
        # Get completion candidates
        my @candidates = $self->{completer}->complete(
            $completion_text,   # text being completed
            $current_input,     # full line
            length($prefix)     # start position of text
        );
        
        # Add prefix back to candidates
        if ($prefix) {
            @candidates = map { $prefix . $_ } @candidates;
        }
        
        $state->{candidates} = \@candidates;
        
        print STDERR "[DEBUG][ReadLine] Found " . scalar(@candidates) . " candidates: @candidates\n" if $self->{debug};
        
        # No candidates - beep or do nothing
        return unless @candidates;
        
        # Single candidate - complete it
        if (@candidates == 1) {
            $$input_ref = $candidates[0];
            $$cursor_pos_ref = length($$input_ref);
            $self->redraw_line($input_ref, $cursor_pos_ref, $self->{prompt});
            $state->{active} = 0;  # Done
            print STDERR "[DEBUG][ReadLine] Single match, completed to: '$$input_ref'\n" if should_log('DEBUG');
            return;
        }
        
        # Multiple candidates - show first one
        $$input_ref = $candidates[0];
        $$cursor_pos_ref = length($$input_ref);
        $self->redraw_line($input_ref, $cursor_pos_ref, $self->{prompt});
        print STDERR "[DEBUG][ReadLine] Multiple matches, showing first: '$$input_ref'\n" if should_log('DEBUG');
        
    } else {
        # Subsequent tabs - cycle through candidates
        $state->{index}++;
        
        # Wrap around
        if ($state->{index} >= scalar(@{$state->{candidates}})) {
            # Back to original
            $state->{index} = -1;
            $$input_ref = $state->{original_input};
            print STDERR "[DEBUG][ReadLine] Wrapped to original\n" if should_log('DEBUG');
        } else {
            $$input_ref = $state->{candidates}->[$state->{index}];
            print STDERR "[DEBUG][ReadLine] Cycling to: '$$input_ref'\n" if should_log('DEBUG');
        }
        
        $$cursor_pos_ref = length($$input_ref);
        $self->redraw_line($input_ref, $cursor_pos_ref, $self->{prompt});
    }
}

=head2 handle_escape_sequence

Handle escape sequences (arrow keys, function keys, etc.)

Supported sequences:
- ESC [ A/B/C/D - Arrow keys (up/down/right/left)  
- ESC [ 1;5C/D - Ctrl+Right/Left (standard xterm)
- ESC [ 1;2C/D - Shift+Right/Left (standard xterm)
- ESC [ 1;6C/D - Ctrl+Shift+Right/Left
- ESC [ 5C/D - Ctrl+Right/Left (alternative)
- ESC [ 6C/D - Shift+Right/Left (alternative)
- ESC b/f - Option+Left/Right (macOS Terminal.app)

Terminal.app can send different sequences depending on settings, so we handle multiple formats.

=cut

sub handle_escape_sequence {
    my ($self, $seq, $input_ref, $cursor_pos_ref, $prompt) = @_;
    
    print STDERR "[DEBUG][ReadLine] Escape sequence: " . join(' ', map { sprintf('%02X', ord($_)) } split //, $seq) . " = '$seq'\n" if should_log('DEBUG');
    
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
                $$cursor_pos_ref++;
                $self->redraw_line($input_ref, $cursor_pos_ref, $prompt);
            }
        } elsif ($dir eq 'D') {
            # Left arrow - move one character left
            if ($$cursor_pos_ref > 0) {
                $$cursor_pos_ref--;
                $self->redraw_line($input_ref, $cursor_pos_ref, $prompt);
            }
        }
        return;
    }
    
    # Modified arrow keys - standard xterm format: ESC [ 1 ; MOD C/D
    # Modifiers: 2=Shift, 3=Alt, 4=Shift+Alt, 5=Ctrl, 6=Ctrl+Shift, 7=Ctrl+Alt, 8=Ctrl+Shift+Alt
    # NOTE: Terminal.app sends modifier 3 for Ctrl, not the standard modifier 5
    if ($seq =~ /^\e\[1;([2-8])([CD])/) {
        my ($modifier, $dir) = ($1, $2);
        
        if ($modifier == 5 || $modifier == 3) {
            # Ctrl modifier (5=standard xterm, 3=Terminal.app)
            if ($dir eq 'C') {
                # Ctrl+Right - move to end of line
                $$cursor_pos_ref = length($$input_ref);
                $self->redraw_line($input_ref, $cursor_pos_ref, $prompt);
            } elsif ($dir eq 'D') {
                # Ctrl+Left - move to beginning of line
                $$cursor_pos_ref = 0;
                $self->redraw_line($input_ref, $cursor_pos_ref, $prompt);
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
                # Ctrl+Right - move to end of line
                $$cursor_pos_ref = length($$input_ref);
                $self->redraw_line($input_ref, $cursor_pos_ref, $prompt);
            } elsif ($dir eq 'D') {
                # Ctrl+Left - move to beginning of line
                $$cursor_pos_ref = 0;
                $self->redraw_line($input_ref, $cursor_pos_ref, $prompt);
            }
        } elsif ($modifier == 6) {
            # Shift modifier (alternative format)
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
    
    # macOS Terminal.app specific: Option+Left = ESC b, Option+Right = ESC f
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
}

=head2 move_word_forward

Move cursor forward by one word (Shift+Right arrow)

A word is defined as a sequence of non-whitespace characters or whitespace.

=cut

sub move_word_forward {
    my ($self, $input_ref, $cursor_pos_ref, $prompt) = @_;
    
    my $len = length($$input_ref);
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
    $self->redraw_line($input_ref, $cursor_pos_ref, $prompt);
}

=head2 move_word_backward

Move cursor backward by one word (Shift+Left arrow)

A word is defined as a sequence of non-whitespace characters or whitespace.

=cut

sub move_word_backward {
    my ($self, $input_ref, $cursor_pos_ref, $prompt) = @_;
    
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
        print STDERR "[WARN][ReadLine] History position out of bounds: $self->{history_pos}\n";
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
            print STDERR "[WARN][ReadLine] History position out of bounds: $self->{history_pos}\n";
            $$input_ref = $self->{current_input} // '';
            $self->{history_pos} = -1;
        } else {
            $$input_ref = $self->{history}->[$self->{history_pos}] // '';
        }
    }
    
    $$cursor_pos_ref = length($$input_ref);
    $self->redraw_line($input_ref, $cursor_pos_ref, $prompt);
}

=head2 redraw_line

Redraw the input line with cursor at correct position.

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
        print STDERR "[WARN][ReadLine] Cursor position was negative ($$cursor_pos_ref), clamping to 0\n";
        $$cursor_pos_ref = 0;
    } elsif ($$cursor_pos_ref > $input_len) {
        print STDERR "[WARN][ReadLine] Cursor position exceeded input length ($$cursor_pos_ref > $input_len), clamping to $input_len\n";
        $$cursor_pos_ref = $input_len;
    }
    
    # Get terminal width for proper wrapping
    my ($term_width, $term_height) = GetTerminalSize();
    $term_width ||= 80;
    $term_height ||= 24;
    $term_width = 80 if $term_width < 10;
    
    # Calculate visible prompt length (strip ANSI codes)
    my $visible_prompt = $prompt;
    $visible_prompt =~ s/\e\[[0-9;]*m//g;
    my $prompt_len = length($visible_prompt);
    
    # Clear the current input display
    # We track how many lines we used last time in $self->{display_lines}
    my $lines_to_clear = $self->{display_lines} || 1;
    
    if ($lines_to_clear > 1) {
        my $up_count = $lines_to_clear - 1;
        print "\e[${up_count}A";
    }
    
    # Now at first line - move to beginning and clear everything below
    print "\r\e[J";
    
    # Print prompt and input (terminal wraps naturally)
    print $prompt, $$input_ref;
    
    # Calculate how many lines we just used
    my $total_chars = $prompt_len + $input_len;
    my $lines_used = $total_chars > 0 ? int(($total_chars - 1) / $term_width) + 1 : 1;
    $self->{display_lines} = $lines_used;
    
    # After printing, cursor is at end of input
    # We need to position cursor at the correct location
    
    # Calculate where cursor should be
    my $cursor_total_pos = $prompt_len + $$cursor_pos_ref;
    my $end_total_pos = $prompt_len + $input_len;
    
    # Calculate row and column for both positions
    # Row 0 is first line, counting from 0
    my $cursor_row = $cursor_total_pos > 0 ? int(($cursor_total_pos - 1) / $term_width) : 0;
    my $cursor_col = $cursor_total_pos > 0 ? (($cursor_total_pos - 1) % $term_width) + 1 : 1;
    
    my $end_row = $end_total_pos > 0 ? int(($end_total_pos - 1) / $term_width) : 0;
    my $end_col = $end_total_pos > 0 ? (($end_total_pos - 1) % $term_width) + 1 : 1;
    
    # Currently at end position (end_row, end_col)
    # Need to move to cursor position (cursor_row, cursor_col)
    
    if ($cursor_row < $end_row) {
        # Cursor is on an earlier line - move up
        my $rows_up = $end_row - $cursor_row;
        print "\e[${rows_up}A";
        # After moving up, we're at column end_col on the target row
        # Move to beginning of line, then forward to cursor_col
        print "\r";
        if ($cursor_col > 1) {
            my $cols_right = $cursor_col - 1;
            print "\e[${cols_right}C";
        }
    } elsif ($cursor_row == $end_row) {
        # Same row - just move horizontally
        if ($cursor_col < $end_col) {
            my $cols_left = $end_col - $cursor_col;
            print "\e[${cols_left}D";
        }
    }
    # If cursor_row > end_row, something is wrong (shouldn't happen)
}

=head2 add_to_history

Add a line to command history

=cut

sub add_to_history {
    my ($self, $line) = @_;
    
    # Don't add if same as last entry
    if (@{$self->{history}} && $self->{history}->[-1] eq $line) {
        return;
    }
    
    push @{$self->{history}}, $line;
    
    # Trim history if too long
    if (@{$self->{history}} > $self->{max_history}) {
        shift @{$self->{history}};
    }
    
    # Reset history position
    $self->{history_pos} = -1;
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
