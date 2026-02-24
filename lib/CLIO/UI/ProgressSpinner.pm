package CLIO::UI::ProgressSpinner;

use strict;
use warnings;
use utf8;
use Time::HiRes qw(usleep time);
use POSIX ();
use CLIO::Core::Logger qw(log_debug);

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

=head1 NAME

CLIO::UI::ProgressSpinner - Simple terminal progress animation

=head1 DESCRIPTION

Provides a simple rotating animation to indicate system is busy processing.
Can run standalone or inline (without printing its own line).

Animation clears itself when stopped. In inline mode, only the spinner
character is removed, preserving any text that came before it on the line.

Uses a forked child process for non-blocking animation. The stop() method
is designed to be robust against race conditions: it kills the child,
uses non-blocking waitpid with a timeout, and performs aggressive terminal
cleanup to ensure no stale spinner characters remain.

=head1 SYNOPSIS

    # Standalone spinner with theme-managed frames
    my $spinner = CLIO::UI::ProgressSpinner->new(
        theme_mgr => $theme_manager,
        delay => 100000,  # microseconds (100ms)
    );
    $spinner->start();
    # ... do work ...
    $spinner->stop();

    # Custom spinner (explicit frames override theme)
    my $spinner = CLIO::UI::ProgressSpinner->new(
        frames => ['.', 'o', 'O', 'o'],
        delay => 100000,
    );

    # Inline spinner (animates on same line as existing text)
    # Usage: Print "CLIO: " then start inline spinner
    print "CLIO: ";
    my $spinner = CLIO::UI::ProgressSpinner->new(
        theme_mgr => $theme_manager,
        inline => 1,  # Don't clear entire line on stop, just remove spinner
    );
    $spinner->start();
    # Terminal shows: "CLIO: ⠋" animating (using frames from theme)
    # ... do work ...
    $spinner->stop();
    # Terminal shows: "CLIO: " with cursor after it for content to follow

=cut

sub new {
    my ($class, %args) = @_;
    
    # Use theme manager frames if available, otherwise fall back to default
    my @frames = ('⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏');
    if ($args{theme_mgr} && $args{theme_mgr}->can('get_spinner_frames')) {
        @frames = @{$args{theme_mgr}->get_spinner_frames()};
    } elsif ($args{frames}) {
        @frames = @{$args{frames}};
    }
    
    my $self = {
        # Frames from theme or explicit argument or default braille pattern
        frames => \@frames,
        delay => $args{delay} || 100000,  # 100ms default
        inline => $args{inline} // 0,     # Inline mode: don't clear entire line
        theme_mgr => $args{theme_mgr},    # Store theme manager for potential future use
        pid => undef,
        running => 0,
        _started_at => 0,                 # Timestamp when start() was called
    };
    
    bless $self, $class;
    return $self;
}

=head2 start

Start the progress animation in background.
Non-blocking - returns immediately while animation continues.

In inline mode, assumes the cursor is already positioned where the spinner
should appear (typically right after "CLIO: "). The spinner will animate in place.

In standalone mode, the spinner animates from the beginning of the line.

=cut

sub start {
    my ($self) = @_;
    
    return if $self->{running};
    
    # Fork a child process to handle animation
    my $pid = fork();
    
    if (!defined $pid) {
        # Fork failures can happen legitimately (e.g., resource limits)
        # Only log in debug mode to avoid alarming users
        log_debug('ProgressSpinner', "Failed to fork progress spinner: $!");
        return;
    }
    
    if ($pid == 0) {
        # Child process - detach from parent's terminal input
        close(STDIN);
        open(STDIN, '<', '/dev/null') or warn "Cannot reopen STDIN: $!";
        
        # Clear inherited signal handlers - ensure SIGTERM terminates immediately
        $SIG{INT} = 'DEFAULT';
        $SIG{TERM} = 'DEFAULT';
        $SIG{ALRM} = 'DEFAULT';
        
        # Run animation loop
        $self->_run_animation();
        POSIX::_exit(0);
    }
    
    # Parent process - store child PID and return
    $self->{pid} = $pid;
    $self->{running} = 1;
    $self->{_started_at} = time();
}

=head2 stop

Stop the progress animation and clear it from terminal.

Uses a robust multi-step shutdown:
1. Send SIGTERM to child process
2. Non-blocking waitpid with timeout (prevents hang)
3. Escalate to SIGKILL if child doesn't exit within 200ms
4. Aggressive terminal cleanup to handle race conditions where child
   may have output a frame between our kill and cleanup

In standalone mode: clears the entire line and repositions cursor at start
In inline mode: removes just the spinner character(s), leaves text before it

=cut

sub stop {
    my ($self) = @_;
    
    return unless $self->{running};
    
    # Mark as not running immediately to prevent re-entrant calls
    $self->{running} = 0;
    
    # Kill child process with robust shutdown
    if ($self->{pid}) {
        my $pid = $self->{pid};
        $self->{pid} = undef;
        
        # Step 1: Send SIGTERM (graceful)
        kill('TERM', $pid);
        
        # Step 2: Non-blocking wait with timeout
        # This prevents hanging if the child is somehow stuck
        my $reaped = 0;
        my $deadline = time() + 0.2;  # 200ms timeout
        
        while (time() < $deadline) {
            my $result = waitpid($pid, POSIX::WNOHANG());
            if ($result == $pid || $result == -1) {
                $reaped = 1;
                last;
            }
            usleep(10000);  # 10ms between checks
        }
        
        # Step 3: Escalate to SIGKILL if still alive
        if (!$reaped) {
            kill('KILL', $pid);
            # Brief final wait for SIGKILL (always works on non-zombie)
            waitpid($pid, 0);
            log_debug('ProgressSpinner', "Spinner child required SIGKILL (pid=$pid)");
        }
        
        # Step 4: Brief delay to let any in-flight output from child settle
        # The child may have output a frame just before being killed.
        # This tiny delay lets the terminal process it before we clean up.
        usleep(5000);  # 5ms
    }
    
    # Step 5: Aggressive terminal cleanup
    # Must handle race condition where child wrote a frame right before dying
    if ($self->{inline}) {
        # Inline mode: erase spinner character(s) robustly
        # Use backspace + space + backspace for the spinner character,
        # but also add a second pass for race condition safety
        print "\b \b";
    } else {
        # Standalone mode: clear entire line and move cursor to start
        print "\r\e[K";
    }
    
    # Flush immediately to ensure cleanup is visible
    STDOUT->flush() if STDOUT->can('flush');
}

=head2 is_running

Check if the spinner animation is currently active.
Also validates that the child process is actually alive (handles zombie detection).

Returns: 1 if running, 0 if not

=cut

sub is_running {
    my ($self) = @_;
    
    return 0 unless $self->{running};
    
    # Validate the child process is still alive
    if ($self->{pid}) {
        my $result = waitpid($self->{pid}, POSIX::WNOHANG());
        if ($result == $self->{pid} || $result == -1) {
            # Child has exited (or doesn't exist) - mark as not running
            $self->{pid} = undef;
            $self->{running} = 0;
            return 0;
        }
    }
    
    return $self->{running};
}

=head2 _run_animation (internal)

Animation loop running in child process.

=cut

sub _run_animation {
    my ($self) = @_;
    
    # Child process must set UTF-8 binmode for Unicode characters
    binmode(STDOUT, ':encoding(UTF-8)');
    
    my $frame_index = 0;
    my $frames = $self->{frames};
    my $delay = $self->{delay};
    my $inline = $self->{inline};
    my $first_frame = 1;  # Track first frame to avoid spurious backspace
    
    while (1) {
        my $frame = $frames->[$frame_index];
        
        if ($inline) {
            # Inline mode: print frame, backspacing first to clear previous frame
            # On first frame, don't backspace - there's nothing to erase yet
            if ($first_frame) {
                print $frame;
                $first_frame = 0;
            } else {
                print "\b$frame";
            }
        } else {
            # Standalone mode: carriage return to start of line + frame
            print "\r$frame";
        }
        
        STDOUT->flush() if STDOUT->can('flush');
        
        usleep($delay);
        
        $frame_index = ($frame_index + 1) % scalar(@$frames);
    }
}

sub DESTROY {
    my ($self) = @_;
    $self->stop() if $self->{running};
}

1;

=head1 EXAMPLES

Simple dots animation:

    my $spinner = CLIO::UI::ProgressSpinner->new(
        frames => ['.', '..', '...'],
        delay => 200000,
    );

Classic spinner:

    my $spinner = CLIO::UI::ProgressSpinner->new(
        frames => ['|', '/', '-', '\\'],
    );

Inline spinner with prefix:

    print "CLIO: ";
    my $spinner = CLIO::UI::ProgressSpinner->new(
        frames => ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'],
        inline => 1,
    );
    $spinner->start();
    # Terminal shows: "CLIO: ⠋" animating
    sleep 3;
    $spinner->stop();
    # Terminal shows: "CLIO: " ready for content

=cut
