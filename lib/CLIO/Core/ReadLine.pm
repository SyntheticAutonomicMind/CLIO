package CLIO::Core::ReadLine;

use strict;
use warnings;
use CLIO::Core::Logger qw(should_log);

# Ensure STDOUT is autoflushed for immediate terminal response
$| = 1;
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
        # Track where the cursor was positioned in the last redraw
        # This allows us to know exactly where to start the next redraw from
        last_cursor_row => 0,
        last_cursor_col => 0,
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
    $self->{last_cursor_row} = 0;
    $self->{last_cursor_col} = 0;
    
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
                # Check if we're deleting from the end
                my $input_len = length($input);
                my $deleting_at_end = ($cursor_pos == $input_len);
                
                # Remove character before cursor
                substr($input, $cursor_pos - 1, 1, '');
                $cursor_pos--;
                
                if ($deleting_at_end) {
                    # Optimization: if deleting from end, we can handle it locally
                    # This avoids full redraw and prevents scroll issues when unwrapping
                    
                    my ($term_width, $term_height) = GetTerminalSize();
                    $term_width ||= 80;
                    
                    # Calculate visible prompt length
                    my $visible_prompt = $prompt;
                    $visible_prompt =~ s/\e\[[0-9;]*m//g;
                    my $prompt_len = length($visible_prompt);
                    
                    # Calculate old and new cursor positions
                    my $old_total_pos = $prompt_len + $cursor_pos + 1;  # +1 because we already decremented cursor_pos
                    my $new_total_pos = $prompt_len + $cursor_pos;
                    
                    my $old_row = int($old_total_pos / $term_width);
                    my $new_row = int($new_total_pos / $term_width);
                    
                    # Check if we're unwrapping (going from row 1 to row 0)
                    # Also use full redraw when landing on exact terminal width boundary
                    # to avoid cursor ambiguity with pending wrap state
                    if ($old_row > $new_row || ($new_total_pos > 0 && $new_total_pos % $term_width == 0)) {
                        # Unwrapped or at exact boundary - need full redraw
                        $self->redraw_line(\$input, \$cursor_pos, $prompt);
                    } else {
                        # Same row, not at boundary - just backspace locally
                        print "\b \b";  # Move back, print space, move back again
                        
                        # Update cursor tracking
                        my $new_col = ($new_total_pos % $term_width) + 1;
                        $self->{last_cursor_row} = $new_row;
                        $self->{last_cursor_col} = $new_col;
                        
                        # Update display_lines to match actual content
                        my $total_chars = $prompt_len + length($input);
                        my $new_display_lines = $total_chars > 0 ? int(($total_chars - 1) / $term_width) + 1 : 1;
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
        
        # Regular printable character (including multi-byte UTF-8)
        # Allow any character not caught by special handlers above
        # For multi-byte UTF-8 chars, $ord will be >= 128 (first byte of sequence)
        # For single-byte ASCII, $ord will be >= 32
        if ($ord >= 32 || ($ord >= 128)) {
            # This is either ASCII printable or the start of a UTF-8 multi-byte sequence
            if (should_log('DEBUG')) {
                print STDERR "[DEBUG][ReadLine] Inserting '$char' at cursor_pos=$cursor_pos, input_len=" . length($input) . "\n";
                print STDERR "[DEBUG][ReadLine] Input before: '$input'\n";
            }
            
            my $input_len = length($input);
            my $inserting_at_end = ($cursor_pos == $input_len);
            
            substr($input, $cursor_pos, 0, $char);
            $cursor_pos += length($char);  # Increment by actual character length
            
            if (should_log('DEBUG')) {
                print STDERR "[DEBUG][ReadLine] Input after: '$input', new cursor_pos=$cursor_pos\n";
            }
            
            if ($inserting_at_end) {
                # Optimization: if inserting at end, just print the character
                # This avoids full redraw and prevents scroll issues when wrapping
                print $char;
                
                # Update cursor tracking
                my ($term_width, $term_height) = GetTerminalSize();
                $term_width ||= 80;
                
                # Calculate visible prompt length
                my $visible_prompt = $prompt;
                $visible_prompt =~ s/\e\[[0-9;]*m//g;
                my $prompt_len = length($visible_prompt);
                
                # Calculate new cursor position
                my $total_pos = $prompt_len + $cursor_pos;
                my $new_row = int($total_pos / $term_width);
                my $new_col = ($total_pos % $term_width) + 1;
                
                # Update display lines if we wrapped to a new line
                if ($new_row >= $self->{display_lines}) {
                    $self->{display_lines} = $new_row + 1;
                }
                
                $self->{last_cursor_row} = $new_row;
                $self->{last_cursor_col} = $new_col;
            } else {
                # Inserting in middle - need full redraw
                $self->redraw_line(\$input, \$cursor_pos, $prompt);
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
    if ($seq =~ /^\e\[1;([2-8])([CD])/) {
        my ($modifier, $dir) = ($1, $2);
        
        if ($modifier == 5 || $modifier == 3) {
            # Ctrl modifier (5=standard xterm, 3=Terminal.app)
            if ($dir eq 'C') {
                # Ctrl+Right - move to end of line
                my $old_pos = $$cursor_pos_ref;
                $$cursor_pos_ref = length($$input_ref);
                $self->reposition_cursor(\$old_pos, $cursor_pos_ref, $input_ref, $prompt);
            } elsif ($dir eq 'D') {
                # Ctrl+Left - move to beginning of line
                my $old_pos = $$cursor_pos_ref;
                $$cursor_pos_ref = 0;
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
                # Ctrl+Right - move to end of line
                my $old_pos = $$cursor_pos_ref;
                $$cursor_pos_ref = length($$input_ref);
                $self->reposition_cursor(\$old_pos, $cursor_pos_ref, $input_ref, $prompt);
            } elsif ($dir eq 'D') {
                # Ctrl+Left - move to beginning of line
                my $old_pos = $$cursor_pos_ref;
                $$cursor_pos_ref = 0;
                $self->reposition_cursor(\$old_pos, $cursor_pos_ref, $input_ref, $prompt);
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
    
    # Get terminal width
    my ($term_width, $term_height) = GetTerminalSize();
    $term_width ||= 80;
    $term_width = 80 if $term_width < 10;
    
    # Calculate visible prompt length (strip ANSI codes)
    my $visible_prompt = $prompt;
    $visible_prompt =~ s/\e\[[0-9;]*m//g;
    my $prompt_len = length($visible_prompt);
    
    # Calculate old and new positions (including prompt)
    my $old_total_pos = $prompt_len + $$old_pos_ref;
    my $new_total_pos = $prompt_len + $$new_pos_ref;
    
    # Calculate row and column for both positions
    # Position represents "cursor is after this many characters have been printed"
    # So pos=0 means cursor at column 1 (before first char)
    # pos=1 means cursor at column 2 (after first char)
    # pos=80 means cursor at column 81 -> but terminal wraps, so row 1, column 1
    # Formula: row = pos / width, col = (pos % width) + 1
    my $old_row = int($old_total_pos / $term_width);
    my $old_col = ($old_total_pos % $term_width) + 1;
    
    my $new_row = int($new_total_pos / $term_width);
    my $new_col = ($new_total_pos % $term_width) + 1;
    
    if (should_log('DEBUG')) {
        print STDERR "[DEBUG][ReadLine] reposition_cursor: old_pos=$$old_pos_ref, new_pos=$$new_pos_ref\n";
        print STDERR "[DEBUG][ReadLine] reposition_cursor: old_total=$old_total_pos, new_total=$new_total_pos\n";
        print STDERR "[DEBUG][ReadLine] reposition_cursor: from ($old_row,$old_col) to ($new_row,$new_col)\n";
    }
    
    # Currently at old position (old_row, old_col)
    # Need to move to new position (new_row, new_col)
    
    if ($new_row < $old_row) {
        # Moving UP to an earlier line (e.g., scrolling left past line boundary)
        my $rows_up = $old_row - $new_row;
        print "\e[${rows_up}A";
        # After moving up, we're at column old_col on the target row
        # After moving up, use absolute column positioning to avoid
        # issues with VT100 pending wrap state
        print "\r";  # Go to column 1
        if ($new_col > 1) {
            my $cols_right = $new_col - 1;
            print "\e[${cols_right}C";
        }
    } elsif ($new_row > $old_row) {
        # Moving DOWN to a later line (e.g., scrolling right past line boundary)
        my $rows_down = $new_row - $old_row;
        print "\e[${rows_down}B";
        # After moving down, use absolute column positioning
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
        print STDERR "[DEBUG][ReadLine] reposition_cursor: saved last_cursor=($new_row,$new_col)\n";
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
    
    # Helper function to convert character position to (row, col)
    # Position means "cursor is before the character at this index"
    # Position 0 = cursor before first char = column prompt_len+1
    # Position 1 = cursor after first char = column prompt_len+2
    # ...but we're computing position INCLUDING prompt, so:
    # pos=1 means "after first character printed" = column 2
    # pos=N means "after Nth character printed" = column N+1
    #
    # WAIT: Actually terminals are 1-indexed. If we print "abc":
    # 'a' goes to column 1, 'b' to column 2, 'c' to column 3
    # Cursor ends up at column 4 (after 'c')
    # So: after printing N characters, cursor is at column N+1
    # 
    # For row calculation: if width=80, after printing 80 chars,
    # cursor is at column 81 which wraps to column 1 of next row.
    # Actually in VT100, it's "pending wrap" at column 80, then wraps when next char comes.
    # But for our purposes, let's say: after printing 80 chars, cursor is at col 80 (or pending wrap).
    # After printing 81 chars, cursor is at col 1 of row 1.
    #
    # Position N (0-indexed chars printed) -> cursor is after Nth char
    # So pos=0 means nothing printed, cursor at col 1 of row 0
    # pos=1 means 1 char printed, cursor at col 2 of row 0
    # pos=80 means 80 chars printed, cursor at col 81 -> but that wraps to col 1 of row 1?
    # 
    # Let's think differently:
    # pos=0: cursor at column 1, row 0
    # pos=N: cursor at column ((N-1) % width) + 2, row = (N-1) / width (if N > 0)
    #        OR: column (N % width) + 1 if N % width != 0, else column = width and might wrap
    #
    # Simpler: 
    # pos 0 -> col 1, row 0
    # pos 1 -> col 2, row 0
    # ...
    # pos 79 -> col 80, row 0 (but this is the "pending wrap" position!)
    # pos 80 -> col 1, row 1 (first char of second line)
    # pos 81 -> col 2, row 1
    # ...
    #
    # So: row = pos / width, col = (pos % width) + 1
    my $pos_to_rowcol = sub {
        my ($pos) = @_;
        
        my $row = int($pos / $term_width);
        my $col = ($pos % $term_width) + 1;
        
        return ($row, $col);
    };
    
    # Calculate how many lines the NEW input will use
    my $total_chars = $prompt_len + $input_len;
    my $new_lines_needed = $total_chars > 0 ? int(($total_chars - 1) / $term_width) + 1 : 1;
    
    # We need to move to the start of our input area to clear and redraw.
    # We don't know exactly where the cursor is right now, but we know:
    #  - The previous redraw used $self->{display_lines} lines
    #  - The cursor is somewhere within that area (probably)
    # 
    # Strategy: Move to column 0, then move up by enough lines to reach the start.
    # We'll use the maximum of old_display_lines and new_lines_needed to be safe.
    
    my $old_display_lines = $self->{display_lines} || 1;
    my $max_lines = $old_display_lines > $new_lines_needed ? $old_display_lines : $new_lines_needed;
    
    if (should_log('DEBUG')) {
        print STDERR "[DEBUG][ReadLine] redraw_line: input_len=$input_len, prompt_len=$prompt_len, total_chars=$total_chars\n";
        print STDERR "[DEBUG][ReadLine] redraw_line: term_width=$term_width, new_lines_needed=$new_lines_needed\n";
        print STDERR "[DEBUG][ReadLine] redraw_line: old_display_lines=$old_display_lines, max_lines=$max_lines\n";
        print STDERR "[DEBUG][ReadLine] redraw_line: last cursor was at row=$self->{last_cursor_row}, col=$self->{last_cursor_col}\n";
    }
    
    # Move to column 1 of current line
    print "\r";
    
    # Move up from the last cursor position to row 0
    # We know exactly where the cursor was from the previous redraw
    my $lines_to_move_up = $self->{last_cursor_row};
    if ($lines_to_move_up > 0) {
        print "\e[${lines_to_move_up}A";
    }
    
    # Now we're at column 1 of row 0 (first line of our input)
    # Clear from here to end of screen
    print "\e[J";
    
    # Print prompt and input (terminal wraps naturally)
    print $prompt, $$input_ref;
    
    # Update display_lines for next redraw
    $self->{display_lines} = $new_lines_needed;
    
    # After printing, calculate where cursor is now (at end of what we printed)
    # When we print exactly N*term_width characters, the terminal enters "pending wrap"
    # state: cursor is at column term_width of the last row, NOT column 1 of the next row.
    # The wrap only happens when the next character is printed.
    my $end_pos = $total_chars;
    my ($end_row, $end_col);
    if ($end_pos > 0 && $end_pos % $term_width == 0) {
        # Pending wrap: cursor is at last column of current row
        $end_row = int($end_pos / $term_width) - 1;
        $end_col = $term_width;
    } else {
        ($end_row, $end_col) = $pos_to_rowcol->($end_pos);
    }
    
    # Calculate where we WANT the cursor to be
    my $desired_pos = $prompt_len + $$cursor_pos_ref;
    my ($desired_row, $desired_col);
    if ($desired_pos > 0 && $desired_pos % $term_width == 0) {
        # At boundary: place cursor at last column of current row
        $desired_row = int($desired_pos / $term_width) - 1;
        $desired_col = $term_width;
    } else {
        ($desired_row, $desired_col) = $pos_to_rowcol->($desired_pos);
    }
    
    if (should_log('DEBUG')) {
        print STDERR "[DEBUG][ReadLine] redraw_line: end position: row=$end_row, col=$end_col\n";
        print STDERR "[DEBUG][ReadLine] redraw_line: desired cursor: row=$desired_row, col=$desired_col\n";
    }
    
    # Only reposition if we're not already at the correct position
    if ($desired_row != $end_row || $desired_col != $end_col) {
        # Move from end position to desired cursor position
        if ($desired_row < $end_row) {
            # Need to move up
            my $rows_up = $end_row - $desired_row;
            print "\e[${rows_up}A";
        } elsif ($desired_row > $end_row) {
            # Need to move down (shouldn't normally happen)
            my $rows_down = $desired_row - $end_row;
            print "\e[${rows_down}B";
        }
        
        # Now position to correct column using absolute positioning
        # This avoids any issues with pending wrap state at column term_width
        print "\r";  # Go to column 1
        if ($desired_col > 1) {
            my $cols_right = $desired_col - 1;
            print "\e[${cols_right}C";
        }
    }
    
    # Save the final cursor position for the next redraw
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
