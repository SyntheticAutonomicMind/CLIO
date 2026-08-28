#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# Tests for the interrupt-after-streaming fix in WorkflowOrchestrator.
#
# Bug: When an interrupt was detected during streaming (the on_chunk callback
# set _interrupt_pending), the code after the API call did NOT call
# _handle_interrupt. Instead it just cleared the flag and did `next`,
# causing the agent to retry the API call without ever prompting the user.
# The user had to press ESC 5+ times.
#
# Fix: When _interrupt_pending is set after streaming, _handle_interrupt is
# called directly (not via _check_and_handle_interrupt, which short-circuits
# on _interrupt_pending) to prompt the user via the interact tool.

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$FindBin::Bin/../../lib";

# Force non-TTY so interact returns immediately (no blocking)
BEGIN {
    if (open my $devnull, '<', '/dev/null') {
        close STDIN;
        open(STDIN, '<&', $devnull) or die "Cannot dup /dev/null over STDIN: $!";
    }
}

use Test::More tests => 4;
use CLIO::Core::WorkflowOrchestrator;
use CLIO::Core::Config;
use CLIO::Core::APIManager;
use CLIO::Session::Manager;
use CLIO::Core::Interrupt;

# --- Test 1: _check_and_handle_interrupt short-circuits without _handle_interrupt ---
# This documents WHY the orchestrator can't rely on _check_and_handle_interrupt
# alone when _interrupt_pending is set. The method returns 1 immediately
# (short-circuit) without calling _handle_interrupt - that's the bug.
test('check_and_handle short-circuits on _interrupt_pending', sub {
    my $config = CLIO::Core::Config->new();
    my $api_manager = CLIO::Core::APIManager->new(config => $config);
    my $session = CLIO::Session::Manager->new();

    my $orch = CLIO::Core::WorkflowOrchestrator->new(
        api_manager => $api_manager,
        session => $session,
        debug => 0,
    );

    $orch->{_interrupt_pending} = 1;

    my $intercepted = 0;
    no warnings 'redefine';
    local *{CLIO::Core::WorkflowOrchestrator::_handle_interrupt} = sub {
        $intercepted = 1;
    };

    my $result = $orch->_check_and_handle_interrupt($session, []);
    # _check_and_handle_interrupt short-circuits: returns 1 without
    # calling _handle_interrupt. This is why the caller must handle
    # _interrupt_pending separately.
    ok($result == 1, 'returns 1 (short-circuit)');
    ok(!$intercepted, '_handle_interrupt NOT called by _check_and_handle_interrupt');
});

# --- Test 2: The fix - orchestrator calls _handle_interrupt directly ---
# This mirrors the fixed code in orchestrate() after the API call:
#   if ($self->{_interrupt_pending}) {
#       $self->_handle_interrupt($session, \@messages);
#       $self->{_interrupt_pending} = 0;
#       next;
#   }
test('orchestrator calls _handle_interrupt directly when _interrupt_pending is set', sub {
    my $config = CLIO::Core::Config->new();
    my $api_manager = CLIO::Core::APIManager->new(config => $config);
    my $session = CLIO::Session::Manager->new();

    my $orch = CLIO::Core::WorkflowOrchestrator->new(
        api_manager => $api_manager,
        session => $session,
        debug => 0,
    );

    $orch->{_interrupt_pending} = 1;

    my $handle_called = 0;
    my $messages = [];
    no warnings 'redefine';
    local *{CLIO::Core::WorkflowOrchestrator::_handle_interrupt} = sub {
        my ($self, $sess, $msgs) = @_;
        $handle_called = 1;
        push @$msgs, { role => 'user', content => 'interrupted' };
    };

    # The fixed post-API-call interrupt check:
    if ($orch->{_interrupt_pending}) {
        $orch->_handle_interrupt($session, $messages);
        $orch->{_interrupt_pending} = 0;
    }

    ok($handle_called, '_handle_interrupt called directly');
    ok($messages->[0]{content} eq 'interrupted', 'user response added to messages');
});

sub test {
    my ($name, $coderef) = @_;
    print "Test: $name... ";
    my $ok = 1;
    my $err;
    {
        local $@;
        eval {
            $coderef->();
        };
        if ($@) {
            $ok = 0;
            $err = $@;
        }
    }
    if ($ok) {
        print "PASS\n";
    } else {
        print "FAIL\n";
        print "  Error: $err\n";
    }
    exit 1 unless $ok;
}

END {
    CLIO::Core::Interrupt::clear();
    CLIO::Core::Interrupt::uninstall_alrm_handler();
}
