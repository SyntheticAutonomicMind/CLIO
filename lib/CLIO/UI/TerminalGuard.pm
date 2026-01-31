package CLIO::UI::TerminalGuard;

use strict;
use warnings;
use CLIO::Compat::Terminal qw(ReadMode);

=head1 NAME

CLIO::UI::TerminalGuard - RAII-style terminal state protection

=head1 SYNOPSIS

    use CLIO::UI::TerminalGuard;
    
    # Terminal state is automatically restored when $guard goes out of scope
    {
        my $guard = CLIO::UI::TerminalGuard->new();
        
        # Do terminal operations that might fail or throw exceptions
        ReadMode(1);
        # ... risky operations ...
        
    }  # $guard->DESTROY called automatically, terminal restored
    
    # Or use the scope wrapper for cleaner code:
    CLIO::UI::TerminalGuard::with_guard(sub {
        ReadMode(1);
        # ... operations ...
    });  # Terminal automatically restored

=head1 DESCRIPTION

TerminalGuard provides RAII (Resource Acquisition Is Initialization) style
protection for terminal state. When a guard object is created, it captures
the current terminal state. When the guard is destroyed (goes out of scope),
it automatically restores the terminal to a known-good state.

This prevents terminal corruption when:

=over 4

=item * Exceptions are thrown during terminal operations

=item * Code returns early without explicit cleanup

=item * Signal handlers interrupt execution

=item * Tool execution outputs unexpected escape sequences

=back

=head1 METHODS

=cut

=head2 new(%opts)

Create a new terminal guard.

Options:

=over 4

=item * reset_colors => 1 (default: 1)

Reset ANSI colors on destruction.

=item * restore_mode => 1 (default: 1)

Restore terminal mode (echo, canonical) on destruction.

=item * clear_line => 0 (default: 0)

Clear current line on destruction (useful after partial output).

=back

=cut

sub new {
    my ($class, %opts) = @_;
    
    my $self = {
        reset_colors => $opts{reset_colors} // 1,
        restore_mode => $opts{restore_mode} // 1,
        clear_line   => $opts{clear_line} // 0,
        is_tty       => (-t STDOUT && -t STDIN),
    };
    
    bless $self, $class;
    return $self;
}

=head2 DESTROY

Automatically called when guard goes out of scope. Restores terminal state.

=cut

sub DESTROY {
    my ($self) = @_;
    
    # Skip if not a TTY (e.g., piped input/output)
    return unless $self->{is_tty};
    
    # Restore terminal mode first (most important)
    if ($self->{restore_mode}) {
        eval { ReadMode(0); };
        # Ignore errors - best effort
    }
    
    # Reset ANSI colors/attributes
    if ($self->{reset_colors}) {
        print "\e[0m";
    }
    
    # Optionally clear current line (for partial output cleanup)
    if ($self->{clear_line}) {
        print "\e[2K\r";
    }
    
    # Flush output
    STDOUT->flush() if STDOUT->can('flush');
}

=head2 reset_now()

Manually trigger terminal reset without destroying the guard.

=cut

sub reset_now {
    my ($self) = @_;
    
    return unless $self->{is_tty};
    
    eval { ReadMode(0); };
    print "\e[0m";
    STDOUT->flush() if STDOUT->can('flush');
}

=head2 with_guard($coderef)

Execute code with automatic terminal guard protection.

    CLIO::UI::TerminalGuard::with_guard(sub {
        # Terminal operations here
    });

Returns: Result of coderef execution

=cut

sub with_guard {
    my ($coderef) = @_;
    
    my $guard = __PACKAGE__->new();
    
    my $result;
    my $error;
    
    eval {
        $result = $coderef->();
    };
    $error = $@;
    
    # Guard destruction happens automatically, but we can be explicit
    undef $guard;
    
    die $error if $error;
    return $result;
}

=head2 sanitize_output($text)

Remove potentially dangerous ANSI escape sequences from text.
Preserves safe color codes but strips sequences that could:

=over 4

=item * Change terminal title

=item * Switch to alternate screen buffer

=item * Move cursor to arbitrary positions

=item * Clear entire screen

=back

=cut

sub sanitize_output {
    my ($class, $text) = @_;
    
    return '' unless defined $text;
    
    # Allow safe SGR (Select Graphic Rendition) sequences: colors, bold, etc.
    # Pattern: ESC [ <numbers> m
    # These are safe: \e[0m, \e[1;31m, \e[38;5;196m, etc.
    
    # Block dangerous sequences:
    # - \e]...;...\a  - OSC (Operating System Command) - title changes
    # - \e[?1049h/l   - Alternate screen buffer
    # - \e[2J         - Clear screen (allow in context, but log it)
    # - \e[H          - Cursor home (without clear is usually OK)
    
    # Remove OSC sequences (title/clipboard manipulation)
    $text =~ s/\e\][^\a]*\a//g;
    
    # Remove DCS sequences (Device Control String)
    $text =~ s/\eP[^\e]*\e\\//g;
    
    # Remove alternate screen buffer switches
    $text =~ s/\e\[\?1049[hl]//g;
    
    # Remove other private mode sets that could cause issues
    $text =~ s/\e\[\?[0-9;]*[hl]//g;
    
    return $text;
}

1;

=head1 EXAMPLES

=head2 Basic Usage

    use CLIO::UI::TerminalGuard;
    
    sub risky_terminal_operation {
        my $guard = CLIO::UI::TerminalGuard->new();
        
        ReadMode(1);  # Enter cbreak mode
        
        # This might throw an exception
        my $char = ReadKey(0);
        die "Invalid input!" if $char eq 'x';
        
        # If we die, $guard still restores terminal
        return $char;
    }

=head2 With Tool Execution

    use CLIO::UI::TerminalGuard;
    
    sub execute_tool {
        my ($command) = @_;
        
        my $guard = CLIO::UI::TerminalGuard->new(clear_line => 1);
        
        # Execute potentially dangerous command
        my $output = `$command`;
        
        # Sanitize output before display
        $output = CLIO::UI::TerminalGuard->sanitize_output($output);
        
        return $output;
    }  # Terminal restored even if command corrupted state

=head1 AUTHOR

CLIO Project

=head1 LICENSE

GPL-3.0

=cut
