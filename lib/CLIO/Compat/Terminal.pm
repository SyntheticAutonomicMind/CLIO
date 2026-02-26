package CLIO::Compat::Terminal;

use strict;
use warnings;
use utf8;
use Exporter 'import';

our @EXPORT_OK = qw(GetTerminalSize ReadMode ReadKey ReadLine reset_terminal reset_terminal_light reset_terminal_full);

=head1 NAME

CLIO::Compat::Terminal - Portable terminal control using POSIX::Termios

=head1 DESCRIPTION

Provides terminal control functionality without Term::ReadKey or stty dependency.
Uses POSIX::Termios for terminal mode control (pure syscalls, no child processes)
and ioctl(TIOCGWINSZ) for terminal size queries.

Previous versions used system('stty', ...) which was fragile:
- Every ReadMode() call spawned 1-2 child processes
- Race conditions with signals during fork+exec
- Terminal commands could corrupt the saved stty state
- 'stty sane' fallback was unpredictable

The POSIX::Termios approach is:
- Zero child processes (direct tcsetattr/tcgetattr syscalls)
- Signal-safe (tcsetattr is async-signal-safe per POSIX)
- Reliable save/restore (struct snapshot at init time)
- Faster (no fork+exec overhead)

=head1 FUNCTIONS

=cut

# POSIX::Termios initialization
# We try to load POSIX::Termios at compile time. If unavailable (extremely
# unlikely for Perl 5.32+), we fall back to stty.
my $HAS_POSIX_TERMIOS = 0;
my $INITIAL_TERMIOS;  # Saved at first ReadMode call - pristine terminal state

eval {
    require POSIX;
    POSIX->import(qw(:termios_h));
    $HAS_POSIX_TERMIOS = 1;
};

# TIOCGWINSZ constant for ioctl-based terminal size
# macOS: 0x40087468, Linux: 0x5413
my $TIOCGWINSZ;
eval {
    # Try to determine the right constant for this platform
    require Config;
    if ($Config::Config{osname} && $Config::Config{osname} eq 'linux') {
        $TIOCGWINSZ = 0x5413;
    } else {
        # macOS, FreeBSD, and most other Unix
        $TIOCGWINSZ = 0x40087468;
    }
};

=head2 GetTerminalSize

Get terminal dimensions (columns and rows).

Uses ioctl(TIOCGWINSZ) for zero-overhead size queries, with stty fallback.

Returns: ($cols, $rows)

=cut

sub GetTerminalSize {
    # Check if we have a TTY on either STDOUT or STDIN
    unless (-t STDOUT || -t STDIN) {
        return (80, 24);
    }

    # Method 1: ioctl(TIOCGWINSZ) via /dev/tty - no child process needed
    if ($TIOCGWINSZ) {
        my ($cols, $rows);
        eval {
            if (open my $tty, '<', '/dev/tty') {
                my $winsize = "\0" x 8;
                if (ioctl($tty, $TIOCGWINSZ, $winsize)) {
                    ($rows, $cols) = unpack('SS', $winsize);
                }
                close $tty;
            }
        };
        if ($cols && $rows && $cols > 0 && $rows > 0) {
            return ($cols, $rows);
        }
    }

    # Method 2: stty fallback (spawns child process)
    my $size = `stty size < /dev/tty 2>/dev/null`;
    chomp($size) if $size;
    if ($size && $size =~ /^(\d+)\s+(\d+)/) {
        return ($2, $1);  # stty returns rows cols, we want cols rows
    }

    # Method 3: tput fallback
    my $cols = `tput cols < /dev/tty 2>/dev/null`;
    my $rows = `tput lines < /dev/tty 2>/dev/null`;
    chomp($cols, $rows);
    if ($cols && $rows && $cols =~ /^\d+$/ && $rows =~ /^\d+$/) {
        return ($cols, $rows);
    }

    # Method 4: environment variables as last resort
    my $env_cols = $ENV{COLUMNS} || $ENV{TERM_WIDTH} || 80;
    my $env_rows = $ENV{LINES} || $ENV{TERM_HEIGHT} || 24;

    return ($env_cols, $env_rows);
}

=head2 ReadMode

Set terminal read mode (compatible with Term::ReadKey).

Uses POSIX::Termios for direct tcsetattr/tcgetattr syscalls instead of
shelling out to stty. Saves pristine terminal state on first call and
restores it reliably on mode 0/restore.

Arguments:
- $mode: 0/'normal'/'restore' = normal, 1/'cbreak' = cbreak,
         2/'raw' = raw, 3/'ultra-raw' = ultra-raw, 4 = restore

Returns: 1 on success

=cut

{
    my $current_mode = 0;  # Track current mode state

    sub ReadMode {
        my ($mode) = @_;

        # Skip if not a TTY
        return 1 unless -t STDIN;

        # Normalize mode to number if it's a string
        my $mode_num = $mode;
        if (!looks_like_number($mode)) {
            $mode_num = 0 if $mode eq 'normal' || $mode eq 'restore';
            $mode_num = 1 if $mode eq 'cbreak';
            $mode_num = 2 if $mode eq 'raw';
            $mode_num = 3 if $mode eq 'ultra-raw';
        }

        if ($HAS_POSIX_TERMIOS) {
            return _readmode_termios($mode_num);
        } else {
            return _readmode_stty($mode_num);
        }
    }

    sub _readmode_termios {
        my ($mode_num) = @_;

        # Save pristine terminal state on first call
        if (!$INITIAL_TERMIOS) {
            $INITIAL_TERMIOS = POSIX::Termios->new();
            $INITIAL_TERMIOS->getattr(fileno(STDIN));
        }

        if ($mode_num == 0 || $mode_num == 4) {
            # Restore to pristine state
            $INITIAL_TERMIOS->setattr(fileno(STDIN), POSIX::TCSANOW());
            $current_mode = 0;
        }
        elsif ($mode_num == 1) {
            # Cbreak mode: no echo, character-at-a-time input, signals enabled
            my $t = POSIX::Termios->new();
            $t->getattr(fileno(STDIN));
            my $lflag = $t->getlflag();
            $lflag &= ~(POSIX::ECHO() | POSIX::ICANON());
            $t->setlflag($lflag);
            $t->setcc(POSIX::VMIN(), 1);
            $t->setcc(POSIX::VTIME(), 0);
            $t->setattr(fileno(STDIN), POSIX::TCSANOW());
            $current_mode = 1;
        }
        elsif ($mode_num == 2) {
            # Raw mode: no echo, no canonical, no signal processing,
            # no input processing (CR->NL, XON/XOFF)
            my $t = POSIX::Termios->new();
            $t->getattr(fileno(STDIN));
            my $lflag = $t->getlflag();
            $lflag &= ~(POSIX::ECHO() | POSIX::ICANON() | POSIX::ISIG());
            $t->setlflag($lflag);
            my $iflag = $t->getiflag();
            $iflag &= ~(POSIX::IXON() | POSIX::ICRNL());
            $t->setiflag($iflag);
            $t->setcc(POSIX::VMIN(), 1);
            $t->setcc(POSIX::VTIME(), 0);
            $t->setattr(fileno(STDIN), POSIX::TCSANOW());
            $current_mode = 2;
        }
        elsif ($mode_num == 3) {
            # Ultra-raw mode: everything off including ISIG, IXON, ICRNL, OPOST
            my $t = POSIX::Termios->new();
            $t->getattr(fileno(STDIN));
            my $lflag = $t->getlflag();
            $lflag &= ~(POSIX::ECHO() | POSIX::ICANON() | POSIX::ISIG() | POSIX::IEXTEN());
            $t->setlflag($lflag);
            my $iflag = $t->getiflag();
            $iflag &= ~(POSIX::IXON() | POSIX::ICRNL() | POSIX::INLCR() | POSIX::IGNCR());
            $t->setiflag($iflag);
            my $oflag = $t->getoflag();
            $oflag &= ~(POSIX::OPOST());
            $t->setoflag($oflag);
            $t->setcc(POSIX::VMIN(), 1);
            $t->setcc(POSIX::VTIME(), 0);
            $t->setattr(fileno(STDIN), POSIX::TCSANOW());
            $current_mode = 3;
        }

        return 1;
    }

    # Fallback stty implementation (used only if POSIX::Termios unavailable)
    sub _readmode_stty {
        my ($mode_num) = @_;
        my $saved_mode = $CLIO::Compat::Terminal::_stty_saved_mode;

        if ($mode_num == 0 || $mode_num == 4) {
            if ($saved_mode) {
                system('stty', $saved_mode);
                $CLIO::Compat::Terminal::_stty_saved_mode = undef;
            } else {
                system('stty', 'sane');
            }
            $current_mode = 0;
        } elsif ($mode_num == 1) {
            unless ($saved_mode) {
                $CLIO::Compat::Terminal::_stty_saved_mode = `stty -g 2>/dev/null`;
                chomp($CLIO::Compat::Terminal::_stty_saved_mode) if $CLIO::Compat::Terminal::_stty_saved_mode;
            }
            system('stty', '-echo', '-icanon', 'min', '1', 'time', '0');
            $current_mode = 1;
        } elsif ($mode_num == 2) {
            unless ($saved_mode) {
                $CLIO::Compat::Terminal::_stty_saved_mode = `stty -g 2>/dev/null`;
                chomp($CLIO::Compat::Terminal::_stty_saved_mode) if $CLIO::Compat::Terminal::_stty_saved_mode;
            }
            system('stty', 'raw', '-echo');
            $current_mode = 2;
        } elsif ($mode_num == 3) {
            unless ($saved_mode) {
                $CLIO::Compat::Terminal::_stty_saved_mode = `stty -g 2>/dev/null`;
                chomp($CLIO::Compat::Terminal::_stty_saved_mode) if $CLIO::Compat::Terminal::_stty_saved_mode;
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

# Simple numeric check (avoids Scalar::Util dependency)
sub looks_like_number {
    my ($val) = @_;
    return 0 unless defined $val;
    return $val =~ /^-?\d+\.?\d*$/;
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
        while (1) {
            $bytes_read = sysread(STDIN, $char, 1);
            last if defined $bytes_read;
            use POSIX qw(:errno_h);
            last if $! != EINTR;
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
END {
    # Skip restoration if:
    # 1. Not connected to a TTY (e.g., during syntax check or piped input)
    # 2. No changes were made to terminal mode
    return unless -t STDIN && _get_current_mode() != 0;

    # Restore terminal state - use Termios if available (no timeout needed,
    # it's a single syscall), otherwise fall back to stty with timeout
    if ($HAS_POSIX_TERMIOS && $INITIAL_TERMIOS) {
        eval { $INITIAL_TERMIOS->setattr(fileno(STDIN), POSIX::TCSANOW()); };
    } else {
        local $SIG{ALRM} = sub { die "stty timeout\n" };
        eval {
            alarm(1);
            ReadMode(0);
            alarm(0);
        };
        alarm(0);
    }
}

=head2 reset_terminal_light

Light terminal reset - restores terminal mode only.

Use this for:
- Child processes before detaching (no ANSI codes needed)
- After commands that might have changed terminal mode

This does NOT reset colors or cursor visibility - just terminal mode.

Returns: 1 on success

=cut

sub reset_terminal_light {
    # Skip if not a TTY
    return 1 unless -t STDIN;

    # Restore terminal mode - Termios is a single syscall, no timeout needed
    if ($HAS_POSIX_TERMIOS && $INITIAL_TERMIOS) {
        eval { $INITIAL_TERMIOS->setattr(fileno(STDIN), POSIX::TCSANOW()); };
    } else {
        eval {
            local $SIG{ALRM} = sub { die "ReadMode timeout\n" };
            alarm(1);
            ReadMode(0);
            alarm(0);
        };
        alarm(0);
    }

    return 1;
}

=head2 reset_terminal

Moderate terminal reset - restores terminal mode and safe ANSI attributes.

This function:
1. Restores terminal mode to normal (via Termios or ReadMode(0))
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

    # Step 1: Restore terminal mode
    if ($HAS_POSIX_TERMIOS && $INITIAL_TERMIOS) {
        eval { $INITIAL_TERMIOS->setattr(fileno(STDIN), POSIX::TCSANOW()); };
    } else {
        eval {
            local $SIG{ALRM} = sub { die "ReadMode timeout\n" };
            alarm(1);
            ReadMode(0);
            alarm(0);
        };
        alarm(0);
    }

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

This performs aggressive reset. With Termios, restores the pristine saved state.
With stty fallback, runs stty sane.

WARNING: May cause cursor position changes.

=cut

sub reset_terminal_full {
    # Skip if not a TTY
    return 1 unless -t STDIN && -t STDOUT;

    # Step 1: Restore terminal mode
    if ($HAS_POSIX_TERMIOS && $INITIAL_TERMIOS) {
        eval { $INITIAL_TERMIOS->setattr(fileno(STDIN), POSIX::TCSANOW()); };
    } else {
        # Fallback: ReadMode(0) then stty sane
        eval {
            local $SIG{ALRM} = sub { die "ReadMode timeout\n" };
            alarm(1);
            ReadMode(0);
            alarm(0);
        };
        alarm(0);

        eval {
            local $SIG{ALRM} = sub { die "stty timeout\n" };
            alarm(1);
            system('stty', 'sane');
            alarm(0);
        };
        alarm(0);
    }

    # Step 2: Print ANSI escape sequences
    # NOTE: Still avoiding \e[r as it moves cursor to home
    print STDOUT "\e[0m\e[?25h\e[?7h";

    # Flush output
    STDOUT->autoflush(1);
    STDOUT->flush() if STDOUT->can('flush');

    return 1;
}

1;
