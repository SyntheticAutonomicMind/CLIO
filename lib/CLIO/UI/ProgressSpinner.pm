# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::UI::ProgressSpinner;

use strict;
use warnings;
use utf8;
use Time::HiRes qw(usleep time);
use POSIX ();
use CLIO::Core::Logger qw(log_debug);


=head1 NAME

CLIO::UI::ProgressSpinner - Terminal progress animation with cursor management

=head1 DESCRIPTION

Provides a progress animation to indicate the system is busy. Hides the
cursor during animation and restores it on stop. Default animation is a
dot pattern (. .. ... .. . [blank]) that works on all terminals including console
and serial.

Uses a forked child process for non-blocking animation.

=head1 SYNOPSIS

    my $spinner = CLIO::UI::ProgressSpinner->new(
        theme_mgr => $theme_manager,
    );
    $spinner->start();  # cursor hidden, animation starts
    # ... do work ...
    $spinner->stop();   # animation cleared, cursor restored

=cut

# Default dot frames - works everywhere (ASCII, console, serial)
my @DEFAULT_FRAMES = ('.', '..', '...', '..', '.', ' ');

sub new {
    my ($class, %args) = @_;
    
    # Use theme manager frames if available, otherwise default dots
    my @frames = @DEFAULT_FRAMES;
    if ($args{theme_mgr} && $args{theme_mgr}->can('get_spinner_frames')) {
        my $theme_frames = $args{theme_mgr}->get_spinner_frames();
        @frames = @$theme_frames if $theme_frames && @$theme_frames;
    } elsif ($args{frames}) {
        @frames = @{$args{frames}};
    }
    
    # If frames contain braille characters but locale doesn't support Unicode,
    # fall back to default dot pattern
    if (_has_braille_chars(\@frames) && !_locale_supports_utf8()) {
        @frames = @DEFAULT_FRAMES;
    }
    
    # Calculate max frame width for clean erasure
    my $max_width = 0;
    for my $f (@frames) {
        my $len = length($f);
        $max_width = $len if $len > $max_width;
    }
    
    my $self = {
        frames     => \@frames,
        max_width  => $max_width,
        delay      => $args{delay} || 200000,  # 200ms default (slower for dots)
        inline     => $args{inline} // 0,
        theme_mgr  => $args{theme_mgr},
        pid        => undef,
        running    => 0,
        _started_at => 0,
    };
    
    bless $self, $class;
    return $self;
}

=head2 start

Start the progress animation. Hides the cursor and forks a child process.

=cut

sub start {
    my ($self) = @_;
    
    return if $self->{running};
    
    # Hide cursor before animation begins
    print "\e[?25l";
    STDOUT->flush() if STDOUT->can('flush');
    
    # Windows: fork() is unreliable, skip animation subprocess
    if ($^O eq 'MSWin32') {
        $self->{running} = 1;
        $self->{_started_at} = time();
        return;
    }
    
    my $pid = fork();
    
    if (!defined $pid) {
        log_debug('ProgressSpinner', "Failed to fork progress spinner: $!");
        # Restore cursor on fork failure
        print "\e[?25h";
        STDOUT->flush() if STDOUT->can('flush');
        return;
    }
    
    if ($pid == 0) {
        # Child process
        close(STDIN);
        open(STDIN, '<', '/dev/null') or warn "Cannot reopen STDIN: $!";
        
        $SIG{INT} = 'DEFAULT';
        $SIG{TERM} = 'DEFAULT';
        $SIG{ALRM} = 'DEFAULT';
        
        $self->_run_animation();
        POSIX::_exit(0);
    }
    
    # Parent
    $self->{pid} = $pid;
    $self->{running} = 1;
    $self->{_started_at} = time();
}

=head2 stop

Stop the animation, clear spinner text, and show the cursor.

=cut

sub stop {
    my ($self) = @_;
    
    return unless $self->{running};
    
    $self->{running} = 0;
    
    if ($self->{pid}) {
        my $pid = $self->{pid};
        $self->{pid} = undef;
        
        # Graceful shutdown
        kill('TERM', $pid);
        
        my $reaped = 0;
        my $deadline = time() + 0.2;
        
        while (time() < $deadline) {
            my $result = waitpid($pid, POSIX::WNOHANG());
            if ($result == $pid || $result == -1) {
                $reaped = 1;
                last;
            }
            usleep(10000);
        }
        
        if (!$reaped) {
            kill('KILL', $pid);
            waitpid($pid, 0);
            log_debug('ProgressSpinner', "Spinner child required SIGKILL (pid=$pid)");
        }
        
        usleep(5000);  # Let in-flight output settle
    }
    
    # Clean up spinner text
    if ($self->{inline}) {
        # Erase up to max frame width
        my $w = $self->{max_width};
        print "\b" x $w . ' ' x $w . "\b" x $w;
    } else {
        print "\r\e[K";
    }
    
    # Show cursor
    print "\e[?25h";
    STDOUT->flush() if STDOUT->can('flush');
}

=head2 is_running

Check if the spinner is active (validates child process is alive).

=cut

sub is_running {
    my ($self) = @_;
    
    return 0 unless $self->{running};
    
    if ($self->{pid}) {
        my $result = waitpid($self->{pid}, POSIX::WNOHANG());
        if ($result == $self->{pid} || $result == -1) {
            $self->{pid} = undef;
            $self->{running} = 0;
            # Show cursor if child died unexpectedly
            print "\e[?25h";
            STDOUT->flush() if STDOUT->can('flush');
            return 0;
        }
    }
    
    return $self->{running};
}

=head2 _run_animation (internal)

Animation loop in child process.

=cut

sub _run_animation {
    my ($self) = @_;
    
    my $frame_index = 0;
    my $frames = $self->{frames};
    my $delay = $self->{delay};
    my $inline = $self->{inline};
    my $max_width = $self->{max_width};
    my $first_frame = 1;
    
    while (1) {
        my $frame = $frames->[$frame_index];
        
        if ($inline) {
            if ($first_frame) {
                # Pad to max width so all frames occupy the same space
                print $frame . (' ' x ($max_width - length($frame)));
                $first_frame = 0;
            } else {
                # Back up, write frame padded, back up trailing spaces
                print "\b" x $max_width;
                print $frame . (' ' x ($max_width - length($frame)));
            }
        } else {
            # Standalone: carriage return + frame padded to max width
            print "\r" . $frame . (' ' x ($max_width - length($frame)));
        }
        
        STDOUT->flush() if STDOUT->can('flush');
        usleep($delay);
        $frame_index = ($frame_index + 1) % scalar(@$frames);
    }
}

# ─────────────────────────────────────────────────────────────
# Internal helpers
# ─────────────────────────────────────────────────────────────

sub _has_braille_chars {
    my ($frames) = @_;
    for my $frame (@$frames) {
        return 1 if $frame =~ /[\x{2800}-\x{28FF}]/;
    }
    return 0;
}

sub _locale_supports_utf8 {
    for my $var ($ENV{LC_ALL}, $ENV{LC_CTYPE}, $ENV{LANG}) {
        next unless defined $var;
        return 1 if $var =~ /UTF-?8/i;
    }
    return 0;
}

sub DESTROY {
    my ($self) = @_;
    if ($self->{running}) {
        $self->stop();
    } elsif ($self->{pid}) {
        kill('KILL', $self->{pid});
        waitpid($self->{pid}, POSIX::WNOHANG());
        $self->{pid} = undef;
        # Show cursor as safety net
        print "\e[?25h";
        STDOUT->flush() if STDOUT->can('flush');
    }
}

1;

__END__

=head1 DEFAULT FRAMES

The default spinner is a dot pattern: .  ..  ...  ..  .  (blank)

This works on all terminals including Linux console, serial, and dumb.

Themes can override with spinner_frames in their .style file.

=cut
