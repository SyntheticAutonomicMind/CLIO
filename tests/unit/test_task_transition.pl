#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Tests for _active_task_text() (CLIO::Core::WorkflowOrchestrator).
#
# active_task resolution (see the POD on _active_task_text):
# 1. The current user_input, when substantive (>= 50 chars). Short
#    acknowledgements ("yes", "proceed", "ship it") are NOT tasks.
# 2. The most recent substantive (>= 50 char) user message in history
#    (YaRN::find_substantive_task, newest-first).
# 3. The durable YaRN thread (recover_substantive_task), never trimmed.
# 4. '' when nothing substantive is available.
#
# Session goals are intentionally NOT consulted: they go stale when the
# user pivots mid-session, leaking an outdated "Current task:" into the
# compressed summary and making the model reset to old work (the bug
# d3ef9ee4 fixed by switching to the live conversation). This test pins
# that behaviour so it does not silently regress.

use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/../../lib";

use Test::More;
use CLIO::Session::State;
require CLIO::Core::WorkflowOrchestrator;

# Access the private method through the package symbol table. This is the
# only way to test it without standing up a full WorkflowOrchestrator
# (which would require APIManager, tool registry, etc.).
*_active_task_text = \&CLIO::Core::WorkflowOrchestrator::_active_task_text;

# ---------------------------------------------------------------------------
# Mock session: satisfies _active_task_text's interface
# (state(), get_conversation_history()). Deliberately does NOT provide id(),
# so the recover_substantive_task (durable thread) fallback is never
# reached -- keeps the assertions hermetic. History items are hashrefs of
# {role, content} matching CLIO::Session::State's real message shape.
# ---------------------------------------------------------------------------

package MockSession {
    sub new {
        my ($class, %args) = @_;
        my $state = CLIO::Session::State->new(
            session_id => $args{session_id} // ('test-' . $$. '-' . int(rand(100000))),
            state_dir  => $args{state_dir} // "/tmp/clio-task-transition-test-$$",
        );
        if (my $goals = $args{goals}) {
            $state->set_session_goals($goals);
        }
        return bless {
            state   => $state,
            history => $args{history} // [],
        }, $class;
    }
    sub state { return $_[0]->{state}; }
    sub get_conversation_history { return $_[0]->{history}; }
}

package main;

# Build a proper arrayref-of-hashref history from a flat list of messages.
sub hist { [ @_ ] }

# A stale session goal -- must never become the active task.
my $stale_goal = {
    id          => 1,
    title       => 'Init templates',
    description => 'Set up /init templating with generic templates',
    status      => 'active',
    created_at  => '2026-09-01T00:00:00Z',
};

my $substantive = "Fix the routing bug properly so recovery trims conversation " .
                  "history before retrying the request with a larger model.";

# ---------------------------------------------------------------------------
# Test 1: a substantive user_input (>= 50 chars) is returned verbatim and
# dominates over stale session goals. This is the primary path and the one
# actually hit in production (user_input is always the live request).
# ---------------------------------------------------------------------------

{
    my $session = MockSession->new(goals => [$stale_goal]);
    my $task = _active_task_text(undef, $session, $substantive);
    is($task, $substantive,
       'substantive user_input is the active task');
    unlike($task, qr/Init templates/,
           'stale session goal is NOT used as active task');
}

# ---------------------------------------------------------------------------
# Test 2: a short acknowledgement ("proceed") is NOT the active task;
# the most recent substantive user message from history is used instead.
# This is the regression guard for the task-transition bug: before the
# substantive floor, an ack could overwrite the real task in the
# compressed summary's "Current task:" line.
# ---------------------------------------------------------------------------

{
    my $session = MockSession->new(
        goals   => [$stale_goal],
        history => hist({ role => 'user', content => $substantive }),
    );
    my $task = _active_task_text(undef, $session, 'proceed');
    is($task, $substantive,
       'short ack defers to the most recent substantive history');
    unlike($task, qr/^proceed$/,
           'the ack itself is not the active task');
    unlike($task, qr/Init templates/,
           'stale goal is not used as the fallback');
}

# ---------------------------------------------------------------------------
# Test 3: when there is no live user_input, the most recent substantive
# user message in history is returned. This covers turns where the input
# has already been saved to history before the projection runs.
# ---------------------------------------------------------------------------

{
    my $session = MockSession->new(
        history => hist({ role => 'user', content => $substantive }),
    );
    my $task = _active_task_text(undef, $session, undef);
    is($task, $substantive,
       'empty user_input falls back to most recent substantive history');
}

# ---------------------------------------------------------------------------
# Test 4: nothing available -> ''. Short acks with empty history must not
# leak into the summary as a fake task. (In production this only happens
# for pathological sessions that never contain a substantive request;
# recover_substantive_task handles the durable-thread case for real
# sessions.)
# ---------------------------------------------------------------------------

{
    my $session = MockSession->new(history => []);
    my $task = _active_task_text(undef, $session, 'yes');
    is($task, '',
       'short ack with empty history returns empty, not the ack');
}

# ---------------------------------------------------------------------------
# Test 5: find_substantive_task scans newest-first and only returns
# >= 50 char USER messages; assistant messages and short (< 50) user
# messages are skipped, even when more recent.
# ---------------------------------------------------------------------------

{
    my $session = MockSession->new(history => hist(
        { role => 'user',      content => $substantive },   # oldest, substantive
        { role => 'user',      content => 'a' x 49 },        # recent, but < 50
        { role => 'assistant', content => 'a' x 200 },      # recent, wrong role
        { role => 'user',      content => 'proceed' },       # most recent ack
    ));
    my $task = _active_task_text(undef, $session, undef);
    is($task, $substantive,
       'most recent SUBSTANTIVE user message wins; acks and <50 msgs skipped');
}

done_testing();
