#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test for the task-transition bug.
#
# Failure mode reproduced:
# - User starts task A (e.g. "/init templating"), agent records an active
#   session goal for it.
# - User then starts task B (e.g. "auto-skill creation") in the same session,
#   agent records another active session goal.
# - WorkflowOrchestrator::_active_task_text() previously returned the FIRST
#   active goal, not the most recent. The "# Active task" string in the
#   dynamic userContext therefore pinned the session to task A.
# - The YaRN-compressed history (the "Earlier work" prose) and the anchor
#   turn were both frozen to task A. The model saw "# Active task: task A"
#   plus an anchor turn that was task A, and concluded that any work it
#   was doing on task B was "scope creep" - reverting its own uncommitted
#   changes in the bad session.
#
# This test pins three properties:
# 1. _active_task_text() returns the MOST RECENT active goal, not the first.
# 2. _active_task_text() still returns the original task when only one
#    active goal is set (regression guard for the simple case).
# 3. Short acknowledgements ("proceed", "yes", "ship it", "looks good")
#    do NOT trigger a new active task. This is the length guard.
#
# Future tests will pin the projection rendering ("NEW TASK: ..." hint)
# and the "current focus" precedence rules; this file covers the core
# _active_task_text fix because that is the smallest unit that broke.

use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/../../lib";

use Test::More;
use CLIO::Session::State;
require CLIO::Core::WorkflowOrchestrator;

# Access the private method through the package symbol table. This is the
# only way to test it without standing up a full WorkflowOrchestrator (which
# would require APIManager, session state, tool registry, etc.).
*_active_task_text = \&CLIO::Core::WorkflowOrchestrator::_active_task_text;

# ---------------------------------------------------------------------------
# Mock session: minimal object that satisfies _active_task_text's interface
# (state() -> ref with session_goals() method, get_conversation_history()).
# ---------------------------------------------------------------------------

package MockSession {
    sub new {
        my ($class, %args) = @_;
        bless {
            state => $args{state},
            history => $args{history} || [],
        }, $class;
    }
    sub state { return $_[0]->{state}; }
    sub get_conversation_history { return $_[0]->{history}; }
    sub can { return 1; }  # all methods exist
}

package main;

sub make_session_with_goals {
    my (@goals) = @_;
    my $state = CLIO::Session::State->new(
        session_id => 'test-' . int(rand(100000)),
        state_dir  => "/tmp/clio-task-transition-test-$$",
    );
    $state->set_session_goals(\@goals);
    return MockSession->new(state => $state);
}

# ---------------------------------------------------------------------------
# Test 1 (regression guard): single active goal returns its title.
# ---------------------------------------------------------------------------

{
    my $session = make_session_with_goals(
        {
            id          => 1,
            title       => 'Init templates',
            description => 'Set up /init templating with generic templates',
            status      => 'active',
            created_at  => '2026-09-01T00:00:00Z',
        },
    );
    my $task = _active_task_text(undef, $session);
    like($task, qr/Init templates/, 'Single active goal: title returned');
    like($task, qr/Set up \/init templating/, 'Single active goal: description appended');
}

# ---------------------------------------------------------------------------
# Test 2 (bug reproduction): two active goals - was returning FIRST, must
# return MOST RECENT. This is the exact scenario from the bad session.
# ---------------------------------------------------------------------------

{
    my $session = make_session_with_goals(
        {
            id          => 1,
            title       => 'Init templates',
            description => 'Set up /init templating with generic templates',
            status      => 'active',
            created_at  => '2026-09-01T00:00:00Z',
        },
        {
            id          => 2,
            title       => 'Auto-skill creation',
            description => 'Add a feature to auto-create skills at session end',
            status      => 'active',
            created_at  => '2026-09-05T00:00:00Z',
        },
    );
    my $task = _active_task_text(undef, $session);
    like($task, qr/Auto-skill creation/, 'Two active goals: MOST RECENT title returned (not the first)');
    unlike($task, qr/Init templates/, 'Two active goals: first goal is NOT the active task');
    like($task, qr/Add a feature to auto-create skills/, 'Two active goals: most recent description appended');
}

# ---------------------------------------------------------------------------
# Test 3 (regression guard): completed goals are not eligible.
# Most recent ACTIVE goal is returned, not most recent of any status.
# ---------------------------------------------------------------------------

{
    my $session = make_session_with_goals(
        {
            id          => 1,
            title       => 'Init templates',
            description => 'Set up /init templating',
            status      => 'completed',
            created_at  => '2026-09-01T00:00:00Z',
        },
        {
            id          => 2,
            title       => 'Auto-skill creation',
            description => 'Add a feature to auto-create skills at session end',
            status      => 'active',
            created_at  => '2026-09-05T00:00:00Z',
        },
        {
            id          => 3,
            title       => 'Refactor caching',
            description => 'Refactor the request cache',
            status      => 'pending',
            created_at  => '2026-09-06T00:00:00Z',
        },
    );
    my $task = _active_task_text(undef, $session);
    like($task, qr/Auto-skill creation/, 'Mixed statuses: most recent ACTIVE goal returned');
    unlike($task, qr/Init templates/, 'Mixed statuses: completed goal is NOT returned');
    unlike($task, qr/Refactor caching/, 'Mixed statuses: pending goal is NOT returned');
}

# ---------------------------------------------------------------------------
# Test 4 (length guard verification): short acknowledgements do not create
# new active goals. The fix relies on the agent/system to record a new
# active goal when the user starts a new task. The length guard lives in
# the system that records goals (todo_operations or session_goals update),
# not in _active_task_text. We verify the assumption here by checking
# that _active_task_text does NOT misfire on history alone - if all the
# recent user messages are short acknowledgements, the function should
# still return the active goal title, not a short message.
# ---------------------------------------------------------------------------

{
    my $state = CLIO::Session::State->new(
        session_id => 'test-ack-' . int(rand(100000)),
        state_dir  => "/tmp/clio-task-transition-test-ack-$$",
    );
    $state->set_session_goals([
        {
            id          => 1,
            title       => 'Original task',
            description => 'The user is working on this.',
            status      => 'active',
            created_at  => '2026-09-01T00:00:00Z',
        },
    ]);
    my $history = [
        { role => 'user',      content => 'Original substantive task description that the user asked about.' },
        { role => 'assistant', content => 'Working on it.' },
        { role => 'user',      content => 'proceed' },
        { role => 'assistant', content => 'Done.' },
        { role => 'user',      content => 'yes' },
        { role => 'assistant', content => 'Continuing.' },
        { role => 'user',      content => 'ship it' },
    ];
    my $session = MockSession->new(state => $state, history => $history);
    my $task = _active_task_text(undef, $session);
    like($task, qr/Original task/, 'Short acknowledgements: active goal title still returned');
    unlike($task, qr/^proceed$/, 'Short acknowledgements: "proceed" not promoted to active task');
    unlike($task, qr/^yes$/, 'Short acknowledgements: "yes" not promoted to active task');
    unlike($task, qr/^ship it$/, 'Short acknowledgements: "ship it" not promoted to active task');
}

# ---------------------------------------------------------------------------
# Test 5: empty session returns empty string.
# ---------------------------------------------------------------------------

{
    my $session = MockSession->new(
        state   => undef,
        history => [],
    );
    my $task = _active_task_text(undef, $session);
    is($task, '', 'Empty session: returns empty string');
}

# ---------------------------------------------------------------------------
# Test 6 (regression guard): no active goals falls back to YaRN's
# newest-first scan. The first user message is the original substantive
# task. If the most recent user message is also substantive, YaRN
# returns that (it scans newest-first).
# ---------------------------------------------------------------------------

{
    my $state = CLIO::Session::State->new(
        session_id => 'test-fallback-' . int(rand(100000)),
        state_dir  => "/tmp/clio-task-transition-test-fb-$$",
    );
    $state->set_session_goals([]);
    my $history = [
        { role => 'user', content => 'Original task: implement the /init templating feature.' },
        { role => 'assistant', content => 'Working on it.' },
        { role => 'user', content => 'Now I want to think through designing an auto skill feature that works like our LTM feature.' },
        { role => 'assistant', content => 'Designing it now.' },
    ];
    my $session = MockSession->new(state => $state, history => $history);
    my $task = _active_task_text(undef, $session);
    like($task, qr/auto skill feature/, 'No goals: YaRN fallback returns most recent substantive message');
    unlike($task, qr/Original task: implement the \/init/, 'No goals: original message NOT returned when more recent exists');
}

done_testing();
