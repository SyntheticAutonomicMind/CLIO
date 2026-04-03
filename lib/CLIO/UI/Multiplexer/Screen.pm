# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::UI::Multiplexer::Screen;

use strict;
use warnings;
use utf8;
use Carp qw(croak);
use CLIO::Core::Logger qw(log_debug log_info log_warning);


=head1 NAME

CLIO::UI::Multiplexer::Screen - GNU Screen driver for CLIO multiplexer integration

=head1 DESCRIPTION

Implements pane management via the GNU Screen CLI. Screen's window model
differs from tmux - it uses numbered windows rather than pane IDs. This
driver maps CLIO pane concepts to Screen windows.

Screen's split-pane support is limited compared to tmux, so we use
separate windows (tabs) rather than splits. Each agent gets its own
Screen window that the user can switch to with C-a <number>.

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        debug      => $args{debug} // 0,
        screen_bin => _find_screen(),
        pane_map   => {},  # name => window_number
        next_title => 0,
    };

    bless $self, $class;
    return $self;
}

=head2 create_pane(%args)

Create a new Screen window running the given command.

Arguments:
    name    - Window title (e.g., 'agent-1')
    command - Command to execute in the window
    vertical - Ignored (Screen split support is limited)
    size    - Ignored (Screen windows are full-size)

Returns: window identifier string (window title)

=cut

sub create_pane {
    my ($self, %args) = @_;

    my $name    = $args{name} or croak "name required";
    my $command = $args{command} or croak "command required";

    # Screen creates windows via the -X command interface
    # 'screen -t title command' creates a new window with a title
    # Screen's -X passes the remaining args as a single command to interpret
    my @cmd = (
        $self->{screen_bin}, '-X',
        'screen', '-t', $name,
        $command,
    );

    log_debug('Screen', "Running: " . join(' ', map { "'$_'" } @cmd));

    eval { $self->_run_cmd(@cmd) };
    if ($@) {
        log_warning('Screen', "Failed to create window '$name': $@");
        return undef;
    }

    # Use the name as our pane ID since Screen doesn't return window numbers
    # from -X commands
    my $pane_id = "screen:$name";
    $self->{pane_map}{$name} = $pane_id;

    log_info('Screen', "Created window '$name' ($pane_id)");

    # Switch focus back to the original window
    eval {
        $self->_run_cmd($self->{screen_bin}, '-X', 'other');
    };

    return $pane_id;
}

=head2 kill_pane($pane_id)

Kill a Screen window by its identifier.

=cut

sub kill_pane {
    my ($self, $pane_id) = @_;

    return 0 unless $pane_id;

    # Extract window name from our pane_id format
    my $name;
    if ($pane_id =~ /^screen:(.+)$/) {
        $name = $1;
    } else {
        $name = $pane_id;
    }

    # Check if window still exists before trying to kill it.
    # Screen auto-kills windows when their program terminates, so the
    # window is usually already gone by the time we get here. If we
    # blindly run 'kill', it targets the CURRENT window (CLIO's own
    # window), which kills the screen session.
    unless ($self->pane_exists($pane_id)) {
        log_debug('Screen', "Window '$name' already gone, skipping kill");
        # Clean up internal tracking
        my @to_remove = grep { ($self->{pane_map}{$_} // '') eq $pane_id } keys %{$self->{pane_map}};
        delete $self->{pane_map}{$_} for @to_remove;
        return 1;
    }

    # Use -p to target the specific window by name, avoiding the
    # two-step select+kill race that can hit the wrong window.
    eval {
        $self->_run_cmd($self->{screen_bin}, '-p', $name, '-X', 'kill');
    };
    if ($@) {
        log_debug('Screen', "kill window failed (may already be closed): $@");
    }

    # Clean up internal tracking
    my @to_remove = grep { ($self->{pane_map}{$_} // '') eq $pane_id } keys %{$self->{pane_map}};
    delete $self->{pane_map}{$_} for @to_remove;

    return 1;
}

=head2 pane_exists($pane_id)

Check if a Screen window still exists.

=cut

sub pane_exists {
    my ($self, $pane_id) = @_;

    return 0 unless $pane_id;

    my $name;
    if ($pane_id =~ /^screen:(.+)$/) {
        $name = $1;
    } else {
        $name = $pane_id;
    }

    # List windows and check for our title
    my $output = eval {
        $self->_run_cmd($self->{screen_bin}, '-Q', 'windows');
    };
    return 0 if $@;

    # Screen window list format: "0 clio  1 agent-1  2 agent-2"
    return ($output && $output =~ /\b\Q$name\E\b/) ? 1 : 0;
}

=head2 list_panes()

List all Screen windows.

Returns: arrayref of window info hashes

=cut

sub list_panes {
    my ($self) = @_;

    my $output = eval {
        $self->_run_cmd($self->{screen_bin}, '-Q', 'windows');
    };
    return [] if $@ || !$output;

    # Parse Screen's window list format
    my @result;
    while ($output =~ /(\d+)\s+(\S+)/g) {
        push @result, { id => "screen:$2", command => $2 };
    }

    return \@result;
}

# === Private Methods ===

sub _run_cmd {
    my ($self, @cmd) = @_;

    my $pid = open(my $pipe, '-|');
    if (!defined $pid) {
        croak "Cannot fork for screen command: $!";
    }

    if ($pid == 0) {
        open(STDERR, '>&STDOUT');
        exec(@cmd) or die "Cannot exec: $!";
    }

    my $output = do { local $/; <$pipe> };
    close($pipe);
    my $exit_code = $? >> 8;

    if ($exit_code != 0) {
        croak "screen command failed (exit $exit_code): " . join(' ', @cmd) . "\nOutput: " . ($output // '');
    }

    return $output;
}

sub _find_screen {
    my $nulldev = $^O eq 'MSWin32' ? 'nul' : '/dev/null';
    my $path = `which screen 2>$nulldev`;
    chomp $path if $path;
    return $path || 'screen';
}

1;

__END__

=head1 AUTHOR

Fewtarius

=head1 LICENSE

See main CLIO LICENSE file.
