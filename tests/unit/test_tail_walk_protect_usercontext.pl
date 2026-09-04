#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test: _role_based_tail_walk must protect the dynamic
# userContext system message and the current turn's user_input
# even under aggressive budget pressure.
#
# Without this guard (B1), the proactive trim drops the dynamic
# userContext and the current user_input when budget is tight, and
# the model loses its task/todos/relevant memory and the actual
# question it was asked. Long-session context-loss bug.

use strict;
use warnings;
use utf8;
use lib './lib';

use Test::More;
use CLIO::Core::API::MessageValidator qw(validate_and_truncate);

# Build the realistic message layout produced by WorkflowOrchestrator's
# role-based projection rebuild:
#   [0] system_prompt
#   [1] anchor turn (original user task)
#   [2] anchor turn (assistant)
#   [3] recent turn (user) ... this is part of recent turns
#   [4] recent turn (assistant)
#   [5] system_userContext (dynamic - has active task, todos, memory)
#   [6] user_input (current turn)
#   [7..] current turn exchanges (tool pairs)
my @messages;
push @messages, { role => 'system', content => 'SYSTEM_PROMPT_' . ('x' x 200) };
push @messages, { role => 'user', content => 'Original anchor task ' . ('x' x 200) };
push @messages, { role => 'assistant', content => 'Got it, will work on it.' };
push @messages, { role => 'user', content => 'Recent turn user ' . ('x' x 100) };
push @messages, { role => 'assistant', content => 'Recent turn assistant.' };
push @messages, { role => 'system', content => 'DYNAMIC_USERCONTEXT_TASK_TODOS_MEMORY' . ('x' x 100) };
push @messages, { role => 'user', content => 'CURRENT_QUESTION_HERE' };
# Many tool exchanges to blow budget
for my $i (1..50) {
    push @messages, {
        role => 'assistant',
        content => "iter $i",
        tool_calls => [{ id => "tc_$i", function => { name => 'fs', arguments => '{}' } }],
    };
    push @messages, { role => 'tool', tool_call_id => "tc_$i", content => 'result ' x 200 };
}

# Aggressive budget: ~1000 tokens forces trim to keep only newest turns
my $trimmed = validate_and_truncate(
    messages           => \@messages,
    model_capabilities => {
        max_context_window_tokens => 2000,
        max_output_tokens         => 200,
    },
);

# Critical assertions: pinned messages survived
my @roles;
my @contents;
for my $m (@$trimmed) {
    push @roles, $m->{role};
    push @contents, $m->{content};
}

ok(grep { /SYSTEM_PROMPT_/ } @contents,
    'system_prompt (index 0) survived aggressive trim') or diag("Roles: @roles");

ok(grep { /Original anchor task/ } @contents,
    'anchor user message survived aggressive trim') or diag("Roles: @roles");

ok(grep { /DYNAMIC_USERCONTEXT_TASK_TODOS_MEMORY/ } @contents,
    'dynamic userContext system message survived aggressive trim (B1 fix)')
    or diag("Roles: @roles");

ok(grep { /CURRENT_QUESTION_HERE/ } @contents,
    'current turn user_input survived aggressive trim (B1 fix)')
    or diag("Roles: @roles");

# Without B1 fix the proactive trim drops BOTH the dynamic userContext
# and current user_input. With the fix, both survive even under aggressive
# trim pressure - the walk evicts oldest tool exchanges first.

# Tool pairing invariant: every tool message has a matching tool_call.
my %call_ids;
my %result_ids;
for my $m (@$trimmed) {
    if ($m->{tool_calls} && ref($m->{tool_calls}) eq 'ARRAY') {
        for my $tc (@{$m->{tool_calls}}) {
            $call_ids{$tc->{id}} = 1 if $tc->{id};
        }
    }
    if ($m->{tool_call_id}) {
        $result_ids{$m->{tool_call_id}} = 1;
    }
}

for my $rid (keys %result_ids) {
    ok($call_ids{$rid}, "tool_result $rid has matching tool_call (pair intact)")
        or diag("orphan tool_result: $rid");
}

done_testing();