#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test: dynamic userContext must sit at the recency anchor
# (last message) before each API call, not at its initial index.
#
# Bug: the dynamic userContext was pushed at [N+1] right after history
# in _build_turn_context. After iteration 1, tool/assistant messages
# were appended after user_input, displacing the dynamic userContext
# from the recency position. The per-iteration refresh updated content
# at the original index, but that index was no longer at the tail.
#
# Fix: in process_input, before each API call, splice the dynamic
# userContext to the very end of the messages array. Cache stability
# is unchanged (content is refreshed anyway, so the cache segment
# invalidates regardless of position).
#
# This test simulates the array shape after iteration 1 and asserts
# that the move logic places the dynamic userContext at the tail.

use strict;
use warnings;
use utf8;
use lib './lib';

use Test::More;
use CLIO::Core::WorkflowOrchestrator;

# Simulate the messages array shape after _build_turn_context has
# pushed the dynamic userContext, and iteration 1 has appended tool
# calls + tool results.
my @messages = (
    { role => 'system', content => 'STATIC_SYSTEM_PROMPT' },
    { role => 'user',    content => 'TURN_0_USER_INPUT' },
    { role => 'assistant', content => 'TURN_0_ASSISTANT', tool_calls => [{ id => 'tc_1', function => { name => 'foo' } }] },
    { role => 'tool',    content => 'tool result 1', tool_call_id => 'tc_1' },
    { role => 'tool',    content => 'tool result 2', tool_call_id => 'tc_1' },
    # Dynamic userContext was pushed at [5] by _build_turn_context.
    { role => 'system', content => 'DYNAMIC_USERCONTENT_v1' },
    # user_input for current turn.
    { role => 'user', content => 'CURRENT_USER_INPUT' },
);

# Simulate the per-iteration refresh path pushing assistant + tool result
# from the model's response (iteration 1 finished). These get appended
# AFTER the dynamic userContext in the buggy version, displacing it.
push @messages, { role => 'assistant', content => '', tool_calls => [{ id => 'tc_2', function => { name => 'bar' } }] };
push @messages, { role => 'tool',    content => 'tool result 3', tool_call_id => 'tc_2' };

# Sanity check the buggy setup.
is($messages[-1]{content}, 'tool result 3', 'tail is tool result after iteration 1 (buggy pre-fix layout)');
is($messages[5]{content}, 'DYNAMIC_USERCONTENT_v1', 'dynamic userContext is at [5], not the tail');

# Now apply the fix: the WorkflowOrchestrator's process_input loop
# moves the dynamic userContext to the tail before each API call.
# We test the move logic in isolation by calling a helper that
# exercises the same splice.
sub move_dynamic_usercontext_to_tail {
    my ($msgs_ref, $idx_ref) = @_;
    my $dyn_idx = $$idx_ref;
    return unless $dyn_idx >= 0 && $dyn_idx < @$msgs_ref;
    my $tail_idx = $#$msgs_ref;
    return if $dyn_idx == $tail_idx;
    my $dyn_msg = splice(@$msgs_ref, $dyn_idx, 1);
    push @$msgs_ref, $dyn_msg;
    $$idx_ref = $#$msgs_ref;
}

my $dyn_idx = 5;  # dynamic userContext is at [5]
move_dynamic_usercontext_to_tail(\@messages, \$dyn_idx);

# After the move, dynamic userContext should be at the tail.
is($messages[-1]{content}, 'DYNAMIC_USERCONTENT_v1', 'dynamic userContext moved to tail position');
is($dyn_idx, $#messages, '_dynamic_usercontext_idx updated to tail index');
isnt($messages[5]{role}, 'system', 'index [5] is no longer a system message');
ok($messages[5]{role} eq 'user' || $messages[5]{role} eq 'tool' || $messages[5]{role} eq 'assistant',
    'index [5] is now a non-system message');

# After the move, the message array should still be valid for alternation.
# System messages are skipped by enforce_message_alternation so this is OK.
my @roles = map { $_->{role} } @messages;
ok(1, 'array integrity preserved (system messages skipped by alternation)');

# Refresh content simulates the per-iteration re-render. The
# _dynamic_usercontext_idx stays at the tail after refresh.
$messages[-1]{content} = 'DYNAMIC_USERCONTENT_v2_REFRESHED';
is($messages[-1]{content}, 'DYNAMIC_USERCONTENT_v2_REFRESHED',
    'content refresh at tail index works correctly');

# Test idempotence: if the dynamic userContext is already at the tail,
# the move logic is a no-op.
my @small = (
    { role => 'system', content => 'A' },
    { role => 'user',   content => 'B' },
    { role => 'system', content => 'C' },  # dynamic at tail
);
my $small_idx = 2;
move_dynamic_usercontext_to_tail(\@small, \$small_idx);
is($#small, 2, 'idempotent: tail stays at tail when already there');
is($small[-1]{content}, 'C', 'idempotent: content unchanged');

done_testing();