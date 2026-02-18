package CLIO::UI::ProgressSpinner;

use strict;
use warnings;
use utf8;
use Time::HiRes qw(usleep);
use CLIO::Core::Logger qw(should_log);

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

=head1 NAME

CLIO::UI::ProgressSpinner - Simple terminal progress animation

=head1 DESCRIPTION

Provides a simple rotating animation to indicate system is busy processing.
Can run standalone or inline (without printing its own line).

Animation clears itself when stopped. In inline mode, only the spinner
character is removed, preserving any text that came before it on the line.

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
    my @frames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
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
        print STDERR "[DEBUG][ProgressSpinner] Failed to fork progress spinner: $!\n" 
            if should_log('DEBUG');
        return;
    }
    
    if ($pid == 0) {
        # Child process - CRITICAL: Reset terminal state while connected to parent TTY
        # This must happen BEFORE any I/O operations in child
        eval {
            require CLIO::Compat::Terminal;
            CLIO::Compat::Terminal::reset_terminal();
        };
        
        # Clear inherited signal handlers
        # Parent may have INT/TERM handlers that shouldn't run in child
        # When parent kills child with TERM, we want clean exit, not parent's cleanup
        $SIG{INT} = 'DEFAULT';
        $SIG{TERM} = 'DEFAULT';
        $SIG{ALRM} = 'DEFAULT';
        
        # Child process - run animation loop
        $self->_run_animation();
        exit 0;
    }
    
    # Parent process - store child PID and return
    $self->{pid} = $pid;
    $self->{running} = 1;
}

=head2 stop

Stop the progress animation and clear it from terminal.

In standalone mode: clears the entire line and repositions cursor at start
In inline mode: removes just the spinner character(s), leaves text before it

=cut

sub stop {
    my ($self) = @_;
    
    return unless $self->{running};
    
    # Kill child process
    if ($self->{pid}) {
        kill 'TERM', $self->{pid};
        waitpid($self->{pid}, 0);
        $self->{pid} = undef;
    }
    
    # Clear based on mode
    if ($self->{inline}) {
        # Inline mode: fully erase the spinner character and reposition cursor
        # Use \b \b sequence: backspace over spinner, overwrite with space, backspace to position
        # This ensures the spinner is completely removed regardless of race conditions
        print "\b \b";
    } else {
        # Standalone mode: clear entire line and move cursor to start
        print "\r\e[K";
    }
    
    $| = 1;
    
    $self->{running} = 0;
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
        
        $| = 1;
        
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

1;
