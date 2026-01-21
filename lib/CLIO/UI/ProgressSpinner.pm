package CLIO::UI::ProgressSpinner;

use strict;
use warnings;
use utf8;
use Time::HiRes qw(usleep);

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

=head1 NAME

CLIO::UI::ProgressSpinner - Simple terminal progress animation

=head1 DESCRIPTION

Provides a simple rotating animation to indicate system is busy processing.
Animation clears itself when stopped.

=head1 SYNOPSIS

    my $spinner = CLIO::UI::ProgressSpinner->new(
        frames => ['.', 'o', 'O', 'o'],
        delay => 100000,  # microseconds (100ms)
    );
    
    $spinner->start();
    # ... do work ...
    $spinner->stop();

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        # Default to braille pattern spinner (smooth, compatible animation)
        frames => $args{frames} || ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'],
        delay => $args{delay} || 100000,  # 100ms default
        pid => undef,
        running => 0,
    };
    
    bless $self, $class;
    return $self;
}

=head2 start

Start the progress animation in background.
Non-blocking - returns immediately while animation continues.

=cut

sub start {
    my ($self) = @_;
    
    return if $self->{running};
    
    # Fork a child process to handle animation
    my $pid = fork();
    
    if (!defined $pid) {
        warn "Failed to fork progress spinner: $!";
        return;
    }
    
    if ($pid == 0) {
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
    
    # Clear the spinner line
    print "\r\e[K";  # Move to start of line and clear it
    $| = 1;
    
    $self->{running} = 0;
}

=head2 _run_animation (internal)

Animation loop running in child process.

=cut

sub _run_animation {
    my ($self) = @_;
    
    # CRITICAL: Child process must set UTF-8 binmode for Unicode characters
    binmode(STDOUT, ':encoding(UTF-8)');
    
    my $frame_index = 0;
    my $frames = $self->{frames};
    my $delay = $self->{delay};
    
    while (1) {
        my $frame = $frames->[$frame_index];
        print "\r$frame";
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

=cut
