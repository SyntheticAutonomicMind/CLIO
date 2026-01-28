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

    # Standalone spinner (prints on its own line)
    my $spinner = CLIO::UI::ProgressSpinner->new(
        frames => ['.', 'o', 'O', 'o'],
        delay => 100000,  # microseconds (100ms)
    );
    $spinner->start();
    # ... do work ...
    $spinner->stop();

    # Inline spinner (animates on same line as existing text)
    # Usage: Print "CLIO: " then start inline spinner
    print "CLIO: ";
    my $spinner = CLIO::UI::ProgressSpinner->new(
        frames => ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'],
        delay => 100000,
        inline => 1,  # Don't clear entire line on stop, just remove spinner
    );
    $spinner->start();
    # Terminal shows: "CLIO: ⠋" animating
    # ... do work ...
    $spinner->stop();
    # Terminal shows: "CLIO: " with cursor after it for content to follow

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        # Default to braille pattern spinner (smooth, compatible animation)
        frames => $args{frames} || ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'],
        delay => $args{delay} || 100000,  # 100ms default
        inline => $args{inline} // 0,     # Inline mode: don't clear entire line
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
        # Child process - Clear inherited signal handlers
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
        # Inline mode: just backspace to remove the spinner character
        # The maximum frame width is 1 character (Unicode braille/emoji), so one backspace is enough
        print "\b ";  # Backspace then space to clear the character
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
    
    while (1) {
        my $frame = $frames->[$frame_index];
        
        if ($inline) {
            # Inline mode: backspace to remove previous frame, print new one
            # Each frame is expected to be 1 character (Unicode char counts as 1)
            print "\b$frame";
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
