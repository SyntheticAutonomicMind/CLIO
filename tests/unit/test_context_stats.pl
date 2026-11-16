#!/usr/bin/perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Tests for the context budget record.
#
# The record exists so that a question about context behavior ("why did
# this request shrink?", "how much budget was left?") is answerable from
# the session file. These tests pin the invariants that make it
# trustworthy:
#
# 1. estimate_messages_breakdown totals agree with estimate_messages_tokens
#    for every message shape CLIO sends.
# 2. validate_and_truncate fills context_plan with the budget it enforced.
# 3. A triggered trim records what it dropped, and lands under the target.
# 4. build_projection reports what it kept and what it archived.
# 5. Session::State bounds the ring and preserves order.

use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/../../lib";

use Test::More;
use JSON::PP;

use CLIO::Memory::TokenEstimator;
use CLIO::Core::API::MessageValidator;
use CLIO::Core::ContextBuilder;
use CLIO::Core::Defaults ();

# ---------------------------------------------------------------------------
# 1. Breakdown agrees with the total for every message shape
# ---------------------------------------------------------------------------

subtest 'breakdown total equals estimate_messages_tokens' => sub {
    my @shapes = (
        'plain text message',
        { role => 'assistant', content => 'text', tool_calls => [
            { id => 'a', type => 'function',
              function => { name => 'read_file', arguments => '{"path":"x"}' } },
        ] },
        { role => 'assistant', content => '', reasoning_content => 'thinking ' x 100 },
        { role => 'assistant', content => '', reasoning_details => [
            { type => 'reasoning.text', text => 'detail ' x 50 },
        ] },
        { role => 'tool', content => 'result', tool_call_id => 'a' },
        { role => 'user', content => [
            { type => 'text', text => 'look at this' },
            { type => 'image_url', image_url => { url => 'data:image/png;base64,AAAA' } },
        ] },
        { role => 'user', parts => [
            { text => 'gemini style part' },
            { inlineData => { mimeType => 'image/png', data => 'AAAA' } },
        ] },
    );

    for my $shape (@shapes) {
        my $msgs = ref($shape) eq 'HASH' ? [ $shape ] : [ { role => 'user', content => $shape } ];
        my $total = CLIO::Memory::TokenEstimator::estimate_messages_tokens($msgs);
        my $bd = CLIO::Memory::TokenEstimator::estimate_messages_breakdown($msgs);
        is($bd->{total}, $total, 'total matches for ' . (ref($shape) eq 'HASH' ? $shape->{role} : 'user'));
    }

    # Mixed array, the shape a real request has.
    my @mixed = (
        { role => 'system', content => 'system prompt' },
        map({ ({ role => 'user', content => "turn $_" },
                { role => 'assistant', content => 'ok',
                  tool_calls => [ { id => "c$_", type => 'function',
                                    function => { name => 'grep_search', arguments => '{"query":"x"}' } } ] },
                { role => 'tool', content => "result $_", tool_call_id => "c$_" }) } 1 .. 5),
    );
    my $total = CLIO::Memory::TokenEstimator::estimate_messages_tokens(\@mixed);
    my $bd = CLIO::Memory::TokenEstimator::estimate_messages_breakdown(\@mixed);
    is($bd->{total}, $total, 'mixed array total matches');
    is($bd->{messages}, scalar(@mixed), 'message count matches');
    cmp_ok($bd->{content_tokens}, '>', 0, 'content attributed');
    cmp_ok($bd->{tool_call_tokens}, '>', 0, 'tool_calls attributed');
    is($bd->{roles}{system}{messages}, 1, 'per-role count');
};

# ---------------------------------------------------------------------------
# 2. The plan records the budget that was enforced
# ---------------------------------------------------------------------------

subtest 'validate_and_truncate records the budget' => sub {
    my $msgs = [
        { role => 'system', content => 'system prompt' },
        { role => 'user', content => 'do the thing' },
        { role => 'assistant', content => 'working' },
    ];

    my $plan = {};
    my $out = CLIO::Core::API::MessageValidator::validate_and_truncate(
        messages           => $msgs,
        model_capabilities => {
            max_context_window_tokens => 1048576,
            max_prompt_tokens         => 1048576,
            max_output_tokens         => 131072,
        },
        tools       => [],
        token_ratio => 4,
        context_plan => $plan,
    );

    my $expected_budget = CLIO::Memory::TokenEstimator::compute_prompt_budget({
        max_context_window_tokens => 1048576,
        max_output_tokens         => 131072,
    });
    is($plan->{context_window}, 1048576, 'context window recorded');
    is($plan->{prompt_budget}, $expected_budget, 'prompt budget matches compute_prompt_budget');
    is($plan->{effective_limit}, $expected_budget, 'effective limit = budget with no tools');
    is($plan->{trim_target},
        int($expected_budget * CLIO::Core::Defaults::CONTEXT_TRIM_TARGET()),
        'trim target recorded');
    is($plan->{trimmed}, 0, 'small array is not trimmed');
    is($plan->{messages_before}, scalar(@$msgs), 'message count before recorded');
    is($plan->{messages_after}, scalar(@$out), 'message count after recorded');
    is($plan->{estimated_before}, $plan->{estimated_after}, 'estimate unchanged when not trimmed');
};

subtest 'tool tokens reduce the effective limit' => sub {
    my $msgs = [
        { role => 'user', content => 'hi' },
    ];
    my $tool = {
        type => 'function',
        function => {
            name => 'x',
            description => 'y' x 400,
            parameters => { type => 'object', properties => {} },
        },
    };

    my $plan = {};
    CLIO::Core::API::MessageValidator::validate_and_truncate(
        messages           => $msgs,
        model_capabilities => { max_context_window_tokens => 200000, max_output_tokens => 16000 },
        tools              => [ $tool ],
        token_ratio        => 4,
        context_plan       => $plan,
    );

    cmp_ok($plan->{tool_tokens}, '>', 0, 'tool tokens counted');
    is($plan->{effective_limit}, $plan->{prompt_budget} - $plan->{tool_tokens},
        'effective limit excludes the tool schema');
};

# ---------------------------------------------------------------------------
# 3. A triggered trim records what it dropped
# ---------------------------------------------------------------------------

subtest 'a triggered trim records the dropped set' => sub {
    my @msgs = ({ role => 'system', content => 'system prompt' });
    push @msgs, { role => 'user', content => 'original task ' . ('x' x 200) };
    for my $i (1 .. 40) {
        push @msgs,
            { role => 'assistant', content => "step $i",
              tool_calls => [ { id => "c$i", type => 'function',
                                function => { name => 'read_file',
                                              arguments => '{"path":"f"}' } } ] },
            { role => 'tool', content => ('result data ' x 200), tool_call_id => "c$i" };
        push @msgs, { role => 'user', content => "next $i" } if $i % 10 == 0;
    }
    push @msgs, { role => 'user', content => 'current request' };

    my $plan = {};
    my $out = CLIO::Core::API::MessageValidator::validate_and_truncate(
        messages           => \@msgs,
        # Small window forces the proactive trim.
        model_capabilities => { max_context_window_tokens => 32000, max_output_tokens => 8000 },
        tools       => [],
        token_ratio => 4,
        context_plan => $plan,
    );

    is($plan->{trimmed}, 1, 'trim flagged');
    cmp_ok($plan->{dropped_messages}, '>', 0, 'dropped message count recorded');
    cmp_ok($plan->{dropped_estimated_tokens}, '>', 0, 'dropped token estimate recorded');
    cmp_ok($plan->{estimated_after}, '<', $plan->{estimated_before}, 'estimate went down');
    cmp_ok(scalar(@$out), '<', scalar(@msgs), 'array got smaller');
    cmp_ok($plan->{thread_summary_chars}, '>', 0, 'compressed summary size recorded');

    # The current request must survive. The proactive trim folds its
    # compressed summary into the last user message, so assert the request
    # is still there rather than that it is untouched.
    my @users = grep { ($_->{role} // '') eq 'user' } @$out;
    like($users[-1]{content}, qr/\bcurrent request\s*\z/,
        'current user input preserved');
};

# ---------------------------------------------------------------------------
# 4. The projection records what it kept and archived
# ---------------------------------------------------------------------------

subtest 'projection stats record kept and archived messages' => sub {
    my @history;
    for my $turn (1 .. 20) {
        push @history, { role => 'user', content => "task $turn " . ('word ' x 40) };
        for my $i (1 .. 3) {
            push @history,
                { role => 'assistant', content => "step $turn.$i" },
                { role => 'tool', content => "result $turn.$i", tool_call_id => "t$turn-$i" };
        }
    }

    my $proj = CLIO::Core::ContextBuilder::build_projection(
        history       => \@history,
        user_input    => 'next',
        active_task   => 'task 1',
        context_window => 1048576,
        # Selection is budget-driven: a budget that cannot hold every turn
        # is what makes the projection archive the older ones.
        prompt_budget => 1500,
    );

    my $stats = $proj->{stats};
    ok(ref($stats) eq 'HASH', 'stats returned');
    is($stats->{turns_total}, 20, 'turn count recorded');
    cmp_ok($stats->{recent_turns}, '>', 0, 'recent turns recorded');
    cmp_ok($stats->{dropped_turns}, '>', 0, 'dropped turns recorded');
    is($stats->{dropped_turns} + $stats->{recent_turns}, $stats->{turns_total},
        'kept + dropped accounts for every turn');
    cmp_ok($stats->{dropped_messages}, '>', 0, 'dropped message count recorded');
    cmp_ok($stats->{dropped_chars}, '>', 0, 'dropped characters recorded');
    cmp_ok($stats->{compressed_tail_chars}, '>', 0, 'compressed tail size recorded');
    cmp_ok($stats->{kept_estimate}, '>', 0, 'kept estimate recorded');

    # The whole point of the record: the archive is a fraction of what it
    # replaced. Assert the ratio is reported honestly, not that it is good.
    cmp_ok($stats->{dropped_estimate}, '>', $stats->{kept_estimate},
        'archived content is larger than the kept window in this fixture');
};

# ---------------------------------------------------------------------------
# 5. Session::State bounds the ring
# ---------------------------------------------------------------------------

subtest 'context stats ring is bounded and ordered' => sub {
    require CLIO::Session::State;
    my $state = CLIO::Session::State->new(session_id => 'test-context-stats');

    for my $i (1 .. 60) {
        $state->record_context_stats({ timestamp => $i, index => $i });
    }

    my $entries = $state->context_stats();
    is(scalar(@$entries), CLIO::Session::State->CONTEXT_STATS_MAX, 'ring bounded');
    is($entries->[0]{index}, 60 - CLIO::Session::State->CONTEXT_STATS_MAX + 1,
        'oldest retained entry is the right one');
    is($entries->[-1]{index}, 60, 'newest entry is last');

    $state->cleanup();
};

done_testing();
