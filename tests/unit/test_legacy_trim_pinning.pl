#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test: legacy trim_conversation_for_api must pin
# first user message (original task anchor) and last user message
# (current turn's user_input) under aggressive trim.
#
# Without pinning, the legacy trim was the silent context-loss
# vector that dropped the original task from session history
# before _role_based_tail_walk ever saw it.

use strict;
use warnings;
use utf8;
use lib './lib';

use Test::More;
use CLIO::Core::ConversationManager qw(trim_conversation_for_api);

# Build a large history that will force aggressive trim
my @history;
push @history, { role => 'user', content => 'ORIGINAL_TASK ' x 30 };  # ~150 tokens
push @history, { role => 'assistant', content => 'Got it.' };
for my $i (1..30) {
    push @history, { role => 'user', content => "task $i" . 'x' x 50 };
    push @history, { role => 'assistant', content => "Work $i", tool_calls => [{id=>"t$i",function=>{name=>'e',arguments=>'{}'}}] };
    push @history, { role => 'tool', tool_call_id => "t$i", content => "R$i " x 50 };  # ~50 tokens each
}
push @history, { role => 'user', content => 'FINAL_QUESTION_HERE' };

# Tiny budget forces aggressive trim
my $result = trim_conversation_for_api(
    \@history,
    'sys',  # system_prompt
    model_context_window => 5000,
    max_response_tokens => 1000,
);

my @contents = map { $_->{content} // '' } @$result;
my @roles = map { $_->{role} } @$result;

ok(grep { /ORIGINAL_TASK/ } @contents,
    'Legacy trim: first user (original task anchor) survived aggressive trim')
    or diag("Roles: @roles");

ok(grep { /FINAL_QUESTION_HERE/ } @contents,
    'Legacy trim: last user (current input) survived aggressive trim')
    or diag("Roles: @roles");

# Sanity: tool pair invariant still holds
my %call_ids;
my %result_ids;
for my $m (@$result) {
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
    ok($call_ids{$rid}, "Legacy trim: tool_result $rid has matching tool_call")
        or diag("orphan: $rid");
}

done_testing();