# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::UI::HostProtocol;

use strict;
use warnings;
use utf8;
use CLIO::Util::JSON qw(encode_json);
use CLIO::Core::Logger qw(log_debug);

=head1 NAME

CLIO::UI::HostProtocol - Structured communication with host applications

=head1 DESCRIPTION

When CLIO runs inside a host application such as MIRA (detected via
CLIO_HOST_PROTOCOL=1 environment variable), this module emits OSC
escape sequences carrying structured metadata. The host intercepts
these to drive native UI elements like spinners, status bars, todo
overlays, and token counters.

Protocol uses OSC code 0 (set window title) with a "clio:" prefix so
that the host's VTE title callback can distinguish protocol messages
from regular title changes. The payload is type:json format.

Any application that spawns CLIO over a PTY can consume these events
by watching for title changes starting with "clio:".

=head1 SYNOPSIS

    use CLIO::UI::HostProtocol;

    my $proto = CLIO::UI::HostProtocol->new();

    if ($proto->active()) {
        $proto->emit_status('thinking', model => 'gpt-4.1');
        $proto->emit_tool_start('file_operations', 'read_file');
        $proto->emit_tool_end('file_operations');
        $proto->emit_tokens(prompt => 45000, completion => 1200, total => 46200, model => 'gpt-4.1');
    }

=cut

sub new {
    my ($class, %args) = @_;
    my $self = {
        active       => ($ENV{CLIO_HOST_PROTOCOL} ? 1 : 0),
        debug        => $args{debug} || 0,
        broker_relay => undef,  # Set via set_broker_relay() for puppeteer forwarding
    };
    bless $self, $class;

    if ($self->{active}) {
        log_debug('HostProtocol', 'Host protocol active');
    }

    return $self;
}

# Check if protocol is active (OSC output or broker relay)
sub active { return $_[0]->{active} || $_[0]->{broker_relay} ? 1 : 0; }

# Set a broker client for relay mode (puppeteer child agents)
# When set, state changes are forwarded to the broker as status_update messages
sub set_broker_relay {
    my ($self, $client) = @_;
    $self->{broker_relay} = $client;
    log_debug('HostProtocol', 'Broker relay mode enabled');
}

# Low-level: emit an OSC title message with clio: prefix
# Format: ESC ] 0 ; clio:<type>:<json> BEL
# Also forwards to broker if relay is set (puppeteer mode)
sub _emit {
    my ($self, $type, $data) = @_;
    
    # OSC output (host app mode)
    if ($self->{active}) {
        my $payload = encode_json($data);
        print "\x1b]0;clio:${type}:${payload}\x07";
        STDOUT->flush() if STDOUT->can('flush');
        log_debug('HostProtocol', "emit $type: $payload");
    }
    
    # Broker relay (puppeteer child mode) - forward status-relevant events
    if ($self->{broker_relay} && ($type eq 'status' || $type eq 'tool')) {
        eval {
            my $state = $type eq 'status' ? ($data->{state} || 'unknown') : 'tools';
            my %update = (state => $state);
            $update{tool} = $data->{name} if $data->{name};
            $update{message} = $data->{label} if $data->{label};
            $self->{broker_relay}->send_status_update(%update);

            # Also forward tool events as activity stream entries
            if ($type eq 'tool') {
                my $action = $data->{action} || 'unknown';
                my $tool_name = $data->{name};
                my $detail = $data->{op};
                $self->{broker_relay}->send_activity($action, $tool_name, $detail);
            }
        };
        log_debug('HostProtocol', "Broker relay error: $@") if $@;
    }
}

# Status change: thinking, streaming, tools, idle
sub emit_status {
    my ($self, $state, %extra) = @_;
    my $data = { state => $state, %extra };
    $self->_emit('status', $data);
}

# Tool execution start
sub emit_tool_start {
    my ($self, $name, $op) = @_;
    $self->_emit('tool', {
        action => 'start',
        name   => $name,
        ($op ? (op => $op) : ()),
    });
}

# Tool execution end
sub emit_tool_end {
    my ($self, $name) = @_;
    $self->_emit('tool', { action => 'end', name => $name });
}

# Spinner control (suppresses ASCII spinner in host mode)
sub emit_spinner_start {
    my ($self, $label) = @_;
    $self->_emit('spinner', {
        action => 'start',
        ($label ? (label => $label) : ()),
    });
}

sub emit_spinner_stop {
    my ($self) = @_;
    $self->_emit('spinner', { action => 'stop' });
}

# Session metadata
sub emit_session {
    my ($self, %info) = @_;
    $self->_emit('session', \%info);
}

# Token usage
sub emit_tokens {
    my ($self, %usage) = @_;
    $self->_emit('tokens', \%usage);
}

# Todo list state
sub emit_todo {
    my ($self, @items) = @_;
    $self->_emit('todo', { items => \@items });
}

# Plain title (non-protocol, regular OSC 0)
sub emit_title {
    my ($self, $text) = @_;
    return unless $self->{active};
    print "\x1b]0;${text}\x07";
    STDOUT->flush() if STDOUT->can('flush');
}

# Sub-agent lifecycle events
# Actions: spawn, status, message, exit
sub emit_agent_event {
    my ($self, $action, %data) = @_;
    $self->_emit('agent', { action => $action, %data });
}

# Remote execution lifecycle events
# Actions: start, progress, complete, error
sub emit_remote_event {
    my ($self, $action, %data) = @_;
    $self->_emit('remote', { action => $action, %data });
}

# Agent tree topology snapshot
# Emitted on any topology change (spawn, exit) so host can render hierarchy
sub emit_agent_tree {
    my ($self, $tree) = @_;
    $self->_emit('tree', $tree);
}

1;
