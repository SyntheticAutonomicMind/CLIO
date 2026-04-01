# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::UI::Multiplexer;

use strict;
use warnings;
use utf8;
use Carp qw(croak);
use CLIO::Core::Logger qw(log_debug log_info log_warning);


=head1 NAME

CLIO::UI::Multiplexer - Terminal multiplexer integration layer

=head1 DESCRIPTION

Detects and integrates with terminal multiplexers (tmux, GNU Screen, Zellij)
to provide multi-pane visibility for sub-agent output and event streams.

This module is the main entry point. It detects which multiplexer (if any) is
running and delegates pane management to the appropriate driver.

=head1 SYNOPSIS

    use CLIO::UI::Multiplexer;

    my $mux = CLIO::UI::Multiplexer->new();

    if ($mux->available()) {
        my $pane_id = $mux->create_pane(
            name    => 'agent-1',
            command => 'tail -f /tmp/clio-agent-agent-1.log',
        );
        # ...
        $mux->kill_pane($pane_id);
    }

=cut

# Detection priority order
my @DETECTION_ORDER = ('tmux', 'screen', 'zellij');

# Environment variables for detection
my %ENV_VARS = (
    tmux   => 'TMUX',
    screen => 'STY',
    zellij => 'ZELLIJ',
);

# Driver modules
my %DRIVER_MODULES = (
    tmux   => 'CLIO::UI::Multiplexer::Tmux',
    screen => 'CLIO::UI::Multiplexer::Screen',
    zellij => 'CLIO::UI::Multiplexer::Zellij',
);

sub new {
    my ($class, %args) = @_;

    my $self = {
        driver       => undef,    # Active driver instance
        type         => undef,    # 'tmux', 'screen', 'zellij', or undef
        managed_panes => {},      # pane_id => { name, command, created_at }
        debug        => $args{debug} // 0,
        auto_pane    => $args{auto_pane} // 1,  # Auto-create panes on agent spawn
    };

    bless $self, $class;

    # Auto-detect multiplexer
    $self->_detect();

    return $self;
}

=head2 detect()

Detect which terminal multiplexer is running, if any.
Returns the type string ('tmux', 'screen', 'zellij') or undef.

=cut

sub detect {
    my ($self_or_class) = @_;

    for my $type (@DETECTION_ORDER) {
        my $env_var = $ENV_VARS{$type};
        if (defined $ENV{$env_var} && $ENV{$env_var} ne '') {
            return $type;
        }
    }
    return undef;
}

=head2 available()

Returns true if a terminal multiplexer is detected and a driver is loaded.

=cut

sub available {
    my ($self) = @_;
    return defined $self->{driver};
}

=head2 type()

Returns the multiplexer type ('tmux', 'screen', 'zellij') or undef.

=cut

sub type {
    my ($self) = @_;
    return $self->{type};
}

=head2 auto_pane()

Get or set whether panes are automatically created on agent spawn.

=cut

sub auto_pane {
    my ($self, $value) = @_;
    if (defined $value) {
        $self->{auto_pane} = $value;
    }
    return $self->{auto_pane};
}

=head2 create_pane(%args)

Create a new pane in the multiplexer.

Arguments:
    name    - Human-readable pane name (e.g., 'agent-1')
    command - Command to run in the pane (e.g., 'tail -f /tmp/log')
    vertical - Split vertically if true (default: horizontal)
    size    - Pane size as percentage (default: driver-specific)

Returns a pane ID string on success, undef on failure.

=cut

sub create_pane {
    my ($self, %args) = @_;

    unless ($self->{driver}) {
        log_warning('Multiplexer', 'No multiplexer detected, cannot create pane');
        return undef;
    }

    my $name = $args{name} or croak "name required for create_pane";
    my $command = $args{command} or croak "command required for create_pane";

    log_debug('Multiplexer', "Creating pane '$name': $command");

    my $pane_id = eval {
        $self->{driver}->create_pane(%args);
    };
    if ($@) {
        log_warning('Multiplexer', "Failed to create pane '$name': $@");
        return undef;
    }

    if ($pane_id) {
        $self->{managed_panes}{$pane_id} = {
            name       => $name,
            command    => $command,
            created_at => time(),
        };
        log_info('Multiplexer', "Created pane '$name' ($pane_id)");
    }

    return $pane_id;
}

=head2 kill_pane($pane_id)

Close a managed pane.

=cut

sub kill_pane {
    my ($self, $pane_id) = @_;

    unless ($self->{driver}) {
        return 0;
    }

    log_debug('Multiplexer', "Killing pane: $pane_id");

    my $result = eval {
        $self->{driver}->kill_pane($pane_id);
    };
    if ($@) {
        log_warning('Multiplexer', "Failed to kill pane $pane_id: $@");
        return 0;
    }

    delete $self->{managed_panes}{$pane_id};
    return $result;
}

=head2 kill_all_panes()

Close all CLIO-managed panes.

=cut

sub kill_all_panes {
    my ($self) = @_;

    my $count = 0;
    for my $pane_id (keys %{$self->{managed_panes}}) {
        $count++ if $self->kill_pane($pane_id);
    }
    return $count;
}

=head2 list_panes()

Returns a hashref of managed panes: { pane_id => { name, command, created_at } }

=cut

sub list_panes {
    my ($self) = @_;

    # Prune dead panes
    if ($self->{driver}) {
        my @dead;
        for my $pane_id (keys %{$self->{managed_panes}}) {
            unless ($self->{driver}->pane_exists($pane_id)) {
                push @dead, $pane_id;
            }
        }
        delete $self->{managed_panes}{$_} for @dead;
    }

    return { %{$self->{managed_panes}} };
}

=head2 create_agent_pane($agent_id, $log_path)

Convenience method: create a pane tailing a sub-agent's log file.

=cut

sub create_agent_pane {
    my ($self, $agent_id, $log_path) = @_;

    $log_path //= "/tmp/clio-agent-$agent_id.log";

    # Touch the log file first so tail -f doesn't fail
    if (!-f $log_path) {
        open(my $fh, '>>', $log_path);
        close($fh) if $fh;
    }

    return $self->create_pane(
        name    => $agent_id,
        command => "tail -f $log_path",
        size    => 30,
    );
}

=head2 status_info()

Returns a hashref with multiplexer status information for display.

=cut

sub status_info {
    my ($self) = @_;

    return {
        detected   => $self->{type} // 'none',
        available  => $self->available() ? 1 : 0,
        auto_pane  => $self->{auto_pane} ? 1 : 0,
        pane_count => scalar keys %{$self->{managed_panes}},
        panes      => $self->list_panes(),
    };
}

# === Private Methods ===

sub _detect {
    my ($self) = @_;

    my $type = $self->detect();
    return unless $type;

    my $module = $DRIVER_MODULES{$type};
    eval "require $module";
    if ($@) {
        log_warning('Multiplexer', "Detected $type but failed to load driver: $@");
        return;
    }

    $self->{driver} = $module->new(debug => $self->{debug});
    $self->{type} = $type;

    log_info('Multiplexer', "Detected multiplexer: $type");
}

1;

__END__

=head1 AUTHOR

Fewtarius

=head1 LICENSE

See main CLIO LICENSE file.
