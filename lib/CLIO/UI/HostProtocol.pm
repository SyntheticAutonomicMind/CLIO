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
        $proto->emit_tokens(used => 45000, limit => 128000, turn => 1200);
    }

=cut

sub new {
    my ($class, %args) = @_;
    my $self = {
        active => ($ENV{CLIO_HOST_PROTOCOL} ? 1 : 0),
        debug  => $args{debug} || 0,
    };
    bless $self, $class;

    if ($self->{active}) {
        log_debug('HostProtocol', 'Host protocol active');
    }

    return $self;
}

# Check if protocol is active
sub active { return $_[0]->{active}; }

# Low-level: emit an OSC title message with clio: prefix
# Format: ESC ] 0 ; clio:<type>:<json> BEL
sub _emit {
    my ($self, $type, $data) = @_;
    return unless $self->{active};

    my $payload = encode_json($data);
    # OSC 0 = set icon name and window title
    print "\x1b]0;clio:${type}:${payload}\x07";
    STDOUT->flush() if STDOUT->can('flush');

    log_debug('HostProtocol', "emit $type: $payload");
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

1;
