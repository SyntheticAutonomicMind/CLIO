package CLIO::Compat::Terminal;

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(GetTerminalSize ReadMode ReadKey ReadLine);

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
    # Check if we have a TTY first
    unless (-t STDOUT) {
        # Not a terminal, return defaults
        return (80, 24);
    }
    
    # Try stty first (works on Linux and macOS)
    if (open(my $stty, '-|', 'stty size 2>/dev/null')) {
        my $size = <$stty>;
        close($stty);
        if ($size && $size =~ /^(\d+)\s+(\d+)/) {
            return ($2, $1);  # stty returns rows cols, we want cols rows
        }
    }
    
    # Try tput as fallback
    my $cols = `tput cols 2>/dev/null`;
    my $rows = `tput lines 2>/dev/null`;
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

=head2 _read_utf8_char

Internal helper to read a complete UTF-8 character from STDIN.

Reads the initial byte, detects if it's part of a multi-byte UTF-8 sequence,
and reads additional bytes as needed. This allows pasting Unicode characters
like Greek letters (α = 2 bytes), CJK characters (中 = 3 bytes), and emoji (= 4 bytes).

UTF-8 encoding:
  - 1-byte: 0x00-0x7F (ASCII)
  - 2-byte: 0xC0-0xDF (e.g., α)
  - 3-byte: 0xE0-0xEF (e.g., 中)
  - 4-byte: 0xF0-0xF7 (e.g., emoji)

Returns: Complete UTF-8 character(s), or undef on EOF

=cut

sub _read_utf8_char {
    # Internal helper to read a complete UTF-8 character from STDIN
    # Reads initial byte, then determines if multi-byte sequence and reads remaining bytes
    
    my $bytes = '';
    my $read_char = read(STDIN, $bytes, 1);
    
    return undef unless $read_char;
    
    # Check if this is a multi-byte UTF-8 sequence
    my $first_ord = ord($bytes);
    my $num_bytes = 1;
    
    if ($first_ord >= 0xC0 && $first_ord < 0xE0) {
        $num_bytes = 2;  # 2-byte sequence (e.g., α is 0xCE 0xB1)
    } elsif ($first_ord >= 0xE0 && $first_ord < 0xF0) {
        $num_bytes = 3;  # 3-byte sequence (e.g., 中 is 0xE4 0xB8 0xAD)
    } elsif ($first_ord >= 0xF0 && $first_ord < 0xF8) {
        $num_bytes = 4;  # 4-byte sequence (e.g., emoji)
    }
    
    # Read remaining bytes for multi-byte sequences
    for (2 .. $num_bytes) {
        my $next_byte;
        if (read(STDIN, $next_byte, 1)) {
            $bytes .= $next_byte;
        } else {
            last;  # End of sequence if we can't read more
        }
    }
    
    # Decode the UTF-8 bytes to a proper character
    # This is important: we read raw bytes but return a decoded character
    if ($num_bytes > 1) {
        # For multi-byte sequences, decode from UTF-8 bytes
        eval {
            require Encode;
            Encode->import('FB_QUIET');
            $bytes = Encode::decode('UTF-8', $bytes, Encode::FB_QUIET());
        };
        # If Encode fails, return the bytes as-is (shouldn't happen for valid UTF-8)
    }
    
    return $bytes;
}

sub ReadKey {
    my ($timeout) = @_;
    $timeout = 0 unless defined $timeout;
    
    # CRITICAL: Use :bytes mode for reading to handle both:
    # 1. ANSI escape sequences (arrow keys: ESC [ A/B/C/D)
    # 2. UTF-8 multi-byte characters (emoji, Greek, CJK)
    # We'll manually decode UTF-8 when needed using _read_utf8_char
    binmode(STDIN, ':raw');
    
    # Check if terminal mode is already set (by ReadLine or other code)
    my $mode_was_set = _get_current_mode();
    
    # Only set cbreak mode if we're currently in normal mode
    ReadMode(1) if $mode_was_set == 0;
    
    my $char;
    if ($timeout == -1) {
        # Non-blocking read
        use POSIX qw(:errno_h);
        use Fcntl;
        
        my $flags = fcntl(STDIN, F_GETFL, 0);
        fcntl(STDIN, F_SETFL, $flags | O_NONBLOCK);
        
        # For control characters and escape sequences, read raw bytes
        my $read_byte = read(STDIN, $char, 1);
        if ($read_byte && ord($char) >= 128) {
            # High bit set - might be UTF-8 multi-byte sequence
            # Put the byte back into the buffer concept (we'll re-read it)
            # Actually, we can't put it back easily, so read the rest of the sequence
            my $first_ord = ord($char);
            my $num_bytes = 1;
            
            if ($first_ord >= 0xC0 && $first_ord < 0xE0) {
                $num_bytes = 2;
            } elsif ($first_ord >= 0xE0 && $first_ord < 0xF0) {
                $num_bytes = 3;
            } elsif ($first_ord >= 0xF0 && $first_ord < 0xF8) {
                $num_bytes = 4;
            }
            
            # Read remaining bytes
            for (2 .. $num_bytes) {
                my $next_byte;
                read(STDIN, $next_byte, 1);
                $char .= $next_byte if defined $next_byte;
            }
            
            # Decode UTF-8
            eval {
                require Encode;
                Encode->import('FB_QUIET');
                $char = Encode::decode('UTF-8', $char, Encode::FB_QUIET());
            };
        }
        
        fcntl(STDIN, F_SETFL, $flags);
    } elsif ($timeout == 0) {
        # Blocking read - use helper for UTF-8
        $char = _read_utf8_char();
    } else {
        # Timed read using select
        use IO::Select;
        my $sel = IO::Select->new();
        $sel->add(\*STDIN);
        
        if ($sel->can_read($timeout)) {
            $char = _read_utf8_char();
        }
    }
    
    # Only restore mode if we set it
    ReadMode(0) if $mode_was_set == 0;
    
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

1;
