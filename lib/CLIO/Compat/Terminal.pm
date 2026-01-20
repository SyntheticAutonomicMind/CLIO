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

sub ReadKey {
    my ($timeout) = @_;
    $timeout = 0 unless defined $timeout;
    
    # Remove utf8 layer for sysread compatibility
    binmode(STDIN, ':bytes');
    
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
        
        sysread(STDIN, $char, 1);
        
        fcntl(STDIN, F_SETFL, $flags);
    } elsif ($timeout == 0) {
        # Blocking read
        sysread(STDIN, $char, 1);
    } else {
        # Timed read using select
        use IO::Select;
        my $sel = IO::Select->new();
        $sel->add(\*STDIN);
        
        if ($sel->can_read($timeout)) {
            sysread(STDIN, $char, 1);
        }
    }
    
    # Only restore mode if we set it
    ReadMode(0) if $mode_was_set == 0;
    
    return $char;
}

# Ensure terminal is restored on exit
END {
    ReadMode(0);
}

1;
