#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test: _find_substantive_user_task must recover the original
# task from the YaRN thread when state->{history} no longer contains it.
#
# Bug: Sessions whose original task message was trimmed from state->{history}
# in a prior session run (pre-fix reactive trim that kept only the last
# N non-user messages) lose their model anchor. _find_substantive_user_task
# only walked state->{history}; if no user message >= 50 chars was there,
# it returned ''. The model then had no <activeTask> block and hallucinated
# "no active task" (observed in session a6a0eb10, 2026-08-29 where the
# original 296-char "I would like you to do a full code review of
# PhotonTERM..." was trimmed from state->{history} but preserved in the
# YaRN thread).
#
# Fix: _find_substantive_user_task now takes an optional $session. When
# no substantive user task is found in state->{history}, it falls back
# to the YaRN thread (the durable, never-trimmed store) and returns the
# OLDEST substantive user message - the original task. This restores
# the model anchor for sessions that lost their original task to a
# pre-fix trim.

use strict;
use warnings;
use utf8;
use lib '/home/deck/repositories/CLIO/lib';
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Test::More;
use CLIO::Memory::YaRN;
use CLIO::Memory::ShortTerm;
use CLIO::Memory::LongTerm;

# Helper: build a minimal mock session that exposes can('yarn'),
# session_id(), and the data _find_substantive_user_task needs.
{
    package MockSession;
    sub new {
        my ($class, %opts) = @_;
        return bless {
            session_id => $opts{session_id} // 'mock-session',
            yarn       => $opts{yarn},
            id_value   => $opts{id_value},  # what ->id() returns
        }, $class;
    }
    sub session_id { $_[0]->{session_id} }
    sub id          { $_[0]->{id_value} }   # sessions use ->id() not ->session_id()
    sub yarn        { $_[0]->{yarn} }
    sub can         { 1 }  # claim we have any method
}

# ── Test 1: API signature now accepts a session ───────────────────────
{
    my $src = do { local $/; open my $fh, '<', 'lib/CLIO/Core/WorkflowOrchestrator.pm' or die "open: $!"; <$fh> };
    like($src, qr/_find_substantive_user_task\(\$messages, \$current_user_input, \$session\)/,
         '_find_substantive_user_task POD declares third arg $session');
    like($src, qr/\$session->can\('yarn'\)/,
         '_find_substantive_user_task checks $session->can("yarn")');
    like($src, qr/\$session->yarn->get_thread\(\$thread_id\)/,
         '_find_substantive_user_task uses $session->yarn->get_thread');
    like($src, qr/Substantive user task not found in state->\{history\}; recovering from YaRN thread/s,
         '_find_substantive_user_task logs the recovery at info level');
}

# ── Test 2: Both call sites pass $session ─────────────────────────────
{
    my $src = do { local $/; open my $fh, '<', 'lib/CLIO/Core/WorkflowOrchestrator.pm' or die "open: $!"; <$fh> };
    # Count occurrences of _find_substantive_user_task being called with
    # three args (including $session). At least 2 call sites should pass
    # $session: the resume fast path and the rebuild path.
    my $count = () = $src =~ /_find_substantive_user_task\(\$[^)]*\$session\)/g;
    cmp_ok($count, '>=', 2,
           'Both call sites pass $session to _find_substantive_user_task (found ' . $count . ')');
}

# ── Test 3: Functional - no session, no fallback ──────────────────────
{
    # Build the orchestrator-style object. Calling _find_substantive_user_task
    # without a session must behave as before - return '' when no
    # substantive task is in messages.
    require CLIO::Core::WorkflowOrchestrator;
    my $wo = CLIO::Core::WorkflowOrchestrator->new();
    my $messages = [
        { role => 'user', content => 'continue' },
        { role => 'assistant', content => 'ok' },
    ];
    my $result = $wo->_find_substantive_user_task($messages, 'continue', undef);
    is($result, '', 'No session, no substantive task in messages => returns ""');
}

# ── Test 4: Functional - state->{history} HAS the task, yarn untouched ─
{
    require CLIO::Core::WorkflowOrchestrator;
    my $wo = CLIO::Core::WorkflowOrchestrator->new();
    my $messages = [
        { role => 'user', content => 'I would like you to do a full code review of PhotonTERM - I want to start using it soon.' },
        { role => 'assistant', content => 'ok' },
        { role => 'user', content => 'continue' },
    ];
    my $result = $wo->_find_substantive_user_task($messages, 'continue', undef);
    is($result, 'I would like you to do a full code review of PhotonTERM - I want to start using it soon.',
       'Substantive task in state->{history} is returned (most recent)');
}

# ── Test 5: Functional - state->{history} LOST the task, YaRN has it ──
{
    # This is the bug scenario. state->{history} has only short directives.
    # YaRN thread has the original 296-char task message.
    my $yarn = CLIO::Memory::YaRN->new();
    $yarn->create_thread('test-yarn-fallback');

    my $original_task = 'I would like you to do a full code review of PhotonTERM - I want to start using it soon but we need to make sure that it follows correct UI/UX patterns, and it is free of smells and inconsistencies.';
    $yarn->add_to_thread('test-yarn-fallback', { role => 'user', content => $original_task });
    $yarn->add_to_thread('test-yarn-fallback', { role => 'assistant', content => 'Looking at the codebase...' });
    $yarn->add_to_thread('test-yarn-fallback', { role => 'tool', tool_call_id => 'tc1', content => 'lots of file content' });
    $yarn->add_to_thread('test-yarn-fallback', { role => 'assistant', content => 'continuing review...' });
    $yarn->add_to_thread('test-yarn-fallback', { role => 'user', content => 'continue' });
    $yarn->add_to_thread('test-yarn-fallback', { role => 'user', content => 'Yes, lets complete all of the remaining work.' });

    my $session = MockSession->new(
        session_id => 'test-yarn-fallback',
        yarn       => $yarn,
    );

    require CLIO::Core::WorkflowOrchestrator;
    my $wo = CLIO::Core::WorkflowOrchestrator->new();

    # state->{history} - only short directives (the bug scenario)
    my $history = [
        { role => 'user', content => 'continue' },
        { role => 'assistant', content => 'ok' },
        { role => 'user', content => 'Yes, lets complete all of the remaining work.' },
    ];

    my $result = $wo->_find_substantive_user_task($history, 'Yes, lets complete all of the remaining work.', $session);
    is($result, $original_task,
       'When state->{history} has no substantive task, YaRN thread is consulted and original task is returned');
}

# ── Test 6: Functional - current user input IS substantive, prefer it ─
{
    require CLIO::Core::WorkflowOrchestrator;
    my $wo = CLIO::Core::WorkflowOrchestrator->new();
    my $history = [
        { role => 'user', content => 'old task that is also substantive and 50+ chars long' },
    ];
    my $current = 'A new substantive task the user just typed, definitely longer than 50 chars';
    my $result = $wo->_find_substantive_user_task($history, $current, undef);
    is($result, $current,
       'Current substantive user input wins over older history task');
}

# ── Test 7: Functional - no session and no task => empty string ──────
{
    require CLIO::Core::WorkflowOrchestrator;
    my $wo = CLIO::Core::WorkflowOrchestrator->new();
    my $history = [
        { role => 'user', content => 'go' },
        { role => 'assistant', content => 'ok' },
    ];
    my $result = $wo->_find_substantive_user_task($history, 'go', undef);
    is($result, '', 'Short directives, no session => returns ""');
}

# ── Test 8: Functional - session has yarn but yarn thread is empty ──
{
    my $yarn = CLIO::Memory::YaRN->new();
    # Don't add anything to the yarn thread.
    my $session = MockSession->new(
        session_id => 'empty-thread',
        yarn       => $yarn,
    );
    require CLIO::Core::WorkflowOrchestrator;
    my $wo = CLIO::Core::WorkflowOrchestrator->new();
    my $history = [
        { role => 'user', content => 'continue' },
    ];
    my $result = $wo->_find_substantive_user_task($history, 'continue', $session);
    is($result, '', 'Empty yarn thread with no substantive task in history => ""');
}

done_testing();
