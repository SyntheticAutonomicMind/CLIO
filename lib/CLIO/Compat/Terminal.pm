package CLIO::Compat::Terminal;

use strict;
use warnings;
use utf8;
use Exporter 'import';

our @EXPORT_OK = qw(GetTerminalSize ReadMode ReadKey ReadLine reset_terminal reset_terminal_light reset_terminal_full);

=head1 NAME

CLIO::Compat::Terminal - Portable terminal control using core modules

=head1 DESCRIPTION

Provides terminal control functionality without Term::ReadKey dependency.
Uses system stty and ANSI escape codes for portability.

=head1 FUNCTIONS

=cut

=head2 GetTerminalSize

Get terminal dimensions (columns and rows).

Returns: ($cols, $rows)

=cut

sub GetTerminalSize {
    # Check if we have a TTY on either STDOUT or STDIN
    # In some contexts (piped scripts), STDOUT might not be a TTY but STDIN is
    unless (-t STDOUT || -t STDIN) {
        # Not a terminal, return defaults
        return (80, 24);
    }
    
    # Try stty with explicit /dev/tty (works on Linux and macOS)
    # We can't use open(..., '-|') because that creates a pipe without a controlling TTY
    # Instead, use backticks with explicit redirection
    my $size = `stty size < /dev/tty 2>/dev/null`;
    chomp($size);
    if ($size && $size =~ /^(\d+)\s+(\d+)/) {
        return ($2, $1);  # stty returns rows cols, we want cols rows
    }
    
    # Try tput as fallback
    my $cols = `tput cols < /dev/tty 2>/dev/null`;
    my $rows = `tput lines < /dev/tty 2>/dev/null`;
    chomp($cols, $rows);
    
    if ($cols && $rows && $cols =~ /^\d+$/ && $rows =~ /^\d+$/) {
        return ($cols, $rows);
    }
    
    # Environment variables as last resort
    my $env_cols = $ENV{COLUMNS} || $ENV{TERM_WIDTH} || 80;
    my $env_rows = $ENV{LINES} || $ENV{TERM_HEIGHT} || 24;
    
    return ($env_cols, $env_rows);
}

=head2 ReadMode

Set terminal read mode (compatible with Term::ReadKey).

Arguments:
- $mode: 0 = normal, 1 = cbreak, 2 = raw, 3 = ultra-raw, 4 = restore

Returns: 1 on success

=cut

{
    my $saved_mode;
    my $current_mode = 0;  # Track current mode state
    
    sub ReadMode {
        my ($mode) = @_;
        
        # Skip if not a TTY
        return 1 unless -t STDIN;
        
        # Normalize mode to number if it's a string
        my $mode_num = $mode;
        $mode_num = 0 if $mode eq 'normal' || $mode eq 'restore';
        $mode_num = 1 if $mode eq 'cbreak';
        $mode_num = 2 if $mode eq 'raw';
        $mode_num = 3 if $mode eq 'ultra-raw';
        
        if ($mode_num == 0 || $mode_num == 4) {
            # Restore normal mode
            if ($saved_mode) {
                system('stty', $saved_mode);
                $saved_mode = undef;
            } else {
                system('stty', 'sane');
            }
            $current_mode = 0;
        } elsif ($mode_num == 1) {
            # Cbreak mode: no echo, immediate input
            unless ($saved_mode) {
                $saved_mode = `stty -g 2>/dev/null`;
                chomp($saved_mode) if $saved_mode;
            }
            system('stty', '-echo', '-icanon', 'min', '1', 'time', '0');
            $current_mode = 1;
        } elsif ($mode_num == 2) {
            # Raw mode: like cbreak but no signal processing
            unless ($saved_mode) {
                $saved_mode = `stty -g 2>/dev/null`;
                chomp($saved_mode) if $saved_mode;
            }
            system('stty', 'raw', '-echo');
            $current_mode = 2;
        } elsif ($mode_num == 3) {
            # Ultra-raw mode
            unless ($saved_mode) {
                $saved_mode = `stty -g 2>/dev/null`;
                chomp($saved_mode) if $saved_mode;
            }
            system('stty', 'raw', '-echo', '-isig');
            $current_mode = 3;
        }
        
        return 1;
    }
    
    # Getter for current mode (used by ReadKey)
    sub _get_current_mode {
        return $current_mode;
    }
}

=head2 ReadLine

Read a single line from STDIN (compatible with Term::ReadKey).

Arguments:
- $input_fd: File descriptor (optional, defaults to 0/STDIN)

Returns: Line read from input

=cut

sub ReadLine {
    my ($input_fd) = @_;
    $input_fd ||= 0;
    
    if ($input_fd == 0) {
        return scalar <STDIN>;
    }
    
    # For other file descriptors, read from the handle
    # This is a simplified version - Term::ReadKey is more sophisticated
    return undef;
}

=head2 ReadKey

Read a single key press (compatible with Term::ReadKey).

Arguments:
- $timeout: Timeout in seconds (optional, 0 = blocking, -1 = non-blocking)

Returns: Character read, or undef on timeout

=cut

sub ReadKey {
    my ($timeout) = @_;
    $timeout = 0 unless defined $timeout;
    
    # Use :bytes mode for raw byte reading (works with sysread)
    binmode(STDIN, ':bytes');
    
    # Check if terminal mode is already set (by ReadLine or other code)
    my $mode_was_set = _get_current_mode();
    
    # Only set cbreak mode if we're currently in normal mode
    ReadMode(1) if $mode_was_set == 0;
    
    my $char;
    my $bytes_read;
    
    if ($timeout == -1) {
        # Non-blocking read
        use POSIX qw(:errno_h);
        use Fcntl;
        
        my $flags = fcntl(STDIN, F_GETFL, 0);
        fcntl(STDIN, F_SETFL, $flags | O_NONBLOCK);
        
        # Retry on EINTR (interrupted by signal)
        while (1) {
            $bytes_read = sysread(STDIN, $char, 1);
            last if defined $bytes_read;  # Success or real error
            last if $! != EINTR;          # Real error (not EINTR)
            # EINTR: retry immediately
        }
        
        fcntl(STDIN, F_SETFL, $flags);
    } elsif ($timeout == 0) {
        # Blocking read with EINTR retry
        # sysread() returns undef when interrupted by signal (EINTR).
        # This is NORMAL - just retry the read. Do NOT sleep or bail out.
        while (1) {
            $bytes_read = sysread(STDIN, $char, 1);
            last if defined $bytes_read;  # Success or real error (bytes_read could be 0 for EOF)
            # If sysread returned undef, check if it was EINTR
            use POSIX qw(:errno_h);
            last if $! != EINTR;          # Real error (not EINTR)
            # EINTR: retry immediately without sleeping
        }
    } else {
        # Timed read using select
        use IO::Select;
        my $sel = IO::Select->new();
        $sel->add(\*STDIN);
        
        if ($sel->can_read($timeout)) {
            # Retry on EINTR
            while (1) {
                $bytes_read = sysread(STDIN, $char, 1);
                last if defined $bytes_read;
                use POSIX qw(:errno_h);
                last if $! != EINTR;
                # EINTR: retry
            }
        }
    }
    
    # Only restore mode if we set it
    ReadMode(0) if $mode_was_set == 0;
    
    return undef unless $bytes_read;
    
    # Check if this is the start of a UTF-8 multi-byte sequence
    my $ord = ord($char);
    
    # For UTF-8 sequences (high bit set, >= 0xC0), read additional bytes
    if ($ord >= 0xC0) {
        my $num_bytes = 1;
        
        if ($ord < 0xE0) {
            $num_bytes = 2;  # 2-byte sequence
        } elsif ($ord < 0xF0) {
            $num_bytes = 3;  # 3-byte sequence
        } elsif ($ord < 0xF8) {
            $num_bytes = 4;  # 4-byte sequence
        }
        
        # Read remaining bytes
        for (2 .. $num_bytes) {
            my $next_byte;
            if (sysread(STDIN, $next_byte, 1)) {
                $char .= $next_byte;
            }
        }
        
        # Decode UTF-8 bytes to character
        eval {
            require Encode;
            $char = Encode::decode('UTF-8', $char, Encode::FB_QUIET());
        };
    }
    
    return $char;
}

# Ensure terminal is restored on exit
# Only restore if we actually have a TTY and made changes
END {
    # Skip restoration if:
    # 1. Not connected to a TTY (e.g., during syntax check or piped input)
    # 2. No changes were made to terminal mode
    return unless -t STDIN && _get_current_mode() != 0;
    
    # Attempt restoration but don't hang if there's an issue
    # Use alarm to timeout stty command
    local $SIG{ALRM} = sub { die "stty timeout\n" };
    eval {
        alarm(1);  # 1 second timeout
        ReadMode(0);
        alarm(0);  # Cancel alarm
    };
    alarm(0);  # Ensure alarm is cancelled even if eval fails
}

=head2 reset_terminal_light

Light terminal reset - restores ReadMode only.

Use this for:
- Child processes before detaching (no ANSI codes needed)
- After commands that might have changed terminal mode

This does NOT reset colors or cursor visibility - just ReadMode.

Returns: 1 on success

=cut

sub reset_terminal_light {
    # Skip if not a TTY
    return 1 unless -t STDIN;
    
    # Restore ReadMode to normal with timeout
    eval {
        local $SIG{ALRM} = sub { die "ReadMode timeout\n" };
        alarm(1);
        ReadMode(0);
        alarm(0);
    };
    alarm(0);  # Ensure alarm is cancelled
    
    return 1;
}

=head2 reset_terminal

Moderate terminal reset - restores ReadMode and safe ANSI attributes.

This function:
1. Restores ReadMode to normal (0)
2. Resets ANSI colors/attributes
3. Shows cursor (in case it was hidden)
4. Enables line wrap (in case it was disabled)

IMPORTANT: Does NOT use stty sane or reset scroll region (\e[r) as these
are too aggressive and can cause cursor position issues.

Use this after:
- Commands that may have corrupted terminal state
- Returning from interactive shells

Returns: 1 on success

=cut

sub reset_terminal {
    # Skip if not a TTY
    return 1 unless -t STDIN && -t STDOUT;
    
    # Step 1: Restore ReadMode to normal with timeout
    eval {
        local $SIG{ALRM} = sub { die "ReadMode timeout\n" };
        alarm(1);
        ReadMode(0);
        alarm(0);
    };
    alarm(0);  # Ensure alarm is cancelled
    
    # Step 2: Print safe ANSI escape sequences
    # \e[0m    - Reset all attributes (colors, bold, etc.)
    # \e[?25h  - Show cursor (in case it was hidden)
    # \e[?7h   - Enable line wrap (in case it was disabled)
    # NOTE: Do NOT use \e[r (reset scroll region) - it moves cursor to home!
    print STDOUT "\e[0m\e[?25h\e[?7h";
    
    # Flush output
    STDOUT->autoflush(1);
    STDOUT->flush() if STDOUT->can('flush');
    
    return 1;
}

=head2 reset_terminal_full

Full terminal reset - use only when user explicitly requests it via /reset.

This performs aggressive reset including stty sane.
WARNING: May cause cursor position changes.

=cut

sub reset_terminal_full {
    # Skip if not a TTY
    return 1 unless -t STDIN && -t STDOUT;
    
    # Step 1: Restore ReadMode to normal
    eval {
        local $SIG{ALRM} = sub { die "ReadMode timeout\n" };
        alarm(1);
        ReadMode(0);
        alarm(0);
    };
    alarm(0);
    
    # Step 2: Run stty sane for full terminal settings reset
    eval {
        local $SIG{ALRM} = sub { die "stty timeout\n" };
        alarm(1);
        system('stty', 'sane');
        alarm(0);
    };
    alarm(0);
    
    # Step 3: Print ANSI escape sequences
    # NOTE: Still avoiding \e[r as it moves cursor to home
    print STDOUT "\e[0m\e[?25h\e[?7h";
    
    # Flush output
    STDOUT->autoflush(1);
    STDOUT->flush() if STDOUT->can('flush');
    
    return 1;
}

1;
