#!/usr/bin/env perl
# Regression test: enforce_message_alternation must strip orphan tool_calls
# (assistant tool_use blocks without matching tool_result messages).
#
# Bug (2026-08-24): Long sessions with many dozens of tool calls would
# trigger a trim that dropped tool_results while keeping the assistant's
# tool_calls. On iteration 1 of process_input, the proactive trim
# (validate_and_truncate) is skipped (only fires when iteration > 1),
# so the only validation before the API call was enforce_message_alternation.
# But enforce_message_alternation only called reinterleave_tool_results,
# which reorders existing pairs but does NOT strip orphans. The orphan
# tool_calls reached the Anthropic API as:
#   "tool_use ids were found without tool_result blocks immediately after"
#
# The previous fixes (commits 405be9c, 2a80a58) addressed the resume
# snapshot path (_capture_api_payload, _try_resume_from_payload) but
# NOT enforce_message_alternation itself — the last common chokepoint
# before every API call. This test closes that gap.

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";

use Test::More;
use CLIO::Core::ConversationManager qw(
    trim_conversation_for_api
    enforce_message_alternation
    reinterleave_tool_results
);
use CLIO::Core::API::MessageValidator qw(validate_tool_message_pairs);
use CLIO::Providers::Anthropic;

#---------------------------------------------------------------------------
# Helper: count orphan tool_calls (tool_call IDs with no matching tool_result)
#---------------------------------------------------------------------------
sub count_orphan_tool_calls {
    my ($msgs) = @_;
    my %tc_ids;
    my %tr_ids;
    for my $msg (@$msgs) {
        if (($msg->{role} // '') eq 'assistant' && $msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY') {
            for my $tc (@{$msg->{tool_calls}}) {
                $tc_ids{$tc->{id}} = 1 if $tc->{id};
            }
        }
        if ($msg->{tool_call_id}) {
            $tr_ids{$msg->{tool_call_id}} = 1;
        }
    }
    my $orphans = 0;
    for my $id (keys %tc_ids) {
        $orphans++ unless $tr_ids{$id};
    }
    return $orphans;
}

#---------------------------------------------------------------------------
# Helper: Anthropic convert_messages adjacency check
# Returns list of error strings (empty = OK)
#---------------------------------------------------------------------------
sub anthropic_adjacency_errors {
    my ($msgs) = @_;
    my $anthropic = CLIO::Providers::Anthropic->new(debug => 0);
    my $converted = $anthropic->convert_messages($msgs);
    my @errors;
    for my $i (0 .. $#{$converted} - 1) {
        my $m = $converted->[$i];
        next unless $m->{role} eq 'assistant' && $m->{content} && ref($m->{content}) eq 'ARRAY';
        my @tc_ids = map { $_->{id} } grep { $_->{type} eq 'tool_use' } @{$m->{content}};
        next unless @tc_ids;
        my $next = $converted->[$i + 1];
        my @tr_ids;
        if ($next->{content} && ref($next->{content}) eq 'ARRAY') {
            @tr_ids = map { $_->{tool_use_id} } grep { $_->{type} eq 'tool_result' } @{$next->{content}};
        }
        for my $tc_id (@tc_ids) {
            my $found = grep { $_ eq $tc_id } @tr_ids;
            push @errors, "tool_use[$tc_id] not adjacent to its tool_result" unless $found;
        }
    }
    return @errors;
}

#---------------------------------------------------------------------------
# Test 1: enforce_message_alternation strips orphan tool_calls on iteration 1
# (the regression scenario: proactive trim skipped, only alternation runs)
#---------------------------------------------------------------------------
subtest 'enforce_message_alternation: strips orphan tool_calls (iteration-1 path)' => sub {
    # Simulate messages that come from trim_conversation_for_api when
    # the budget walk drops tool_results but keeps assistant tool_calls.
    my $msgs = [
        { role => 'system', content => 'sys' },
        { role => 'user', content => 'q1' },
        { role => 'assistant', content => 'a1', tool_calls => [
            { id => 'orphan_tc', type => 'function', function => { name => 'x', arguments => '{}' } },
        ] },
        # NO tool_result for orphan_tc — this is the regression
        { role => 'user', content => 'q2' },
    ];

    my $result = enforce_message_alternation($msgs, 'anthropic', debug => 0);

    is(count_orphan_tool_calls($result), 0, 'zero orphan tool_calls after alternation');
    my @errors = anthropic_adjacency_errors($result);
    is(scalar(@errors), 0, 'zero Anthropic adjacency errors');

    # Assistant message should be preserved as plain text (content kept)
    my $asst = (grep { $_->{role} eq 'assistant' } @$result)[0];
    ok($asst, 'assistant message preserved');
    is($asst->{content}, 'a1', 'assistant content preserved');
    ok(!exists $asst->{tool_calls} || !@{$asst->{tool_calls}}, 'tool_calls stripped from orphan assistant');
};

#---------------------------------------------------------------------------
# Test 2: trim_conversation_for_api strips orphans on early return (no trim)
#---------------------------------------------------------------------------
subtest 'trim_conversation_for_api: strips orphan tool_calls on early return (no trim)' => sub {
    my $msgs = [
        { role => 'user', content => 'q1' },
        { role => 'assistant', content => 'a1', tool_calls => [
            { id => 'orphan_tc', type => 'function', function => { name => 'x', arguments => '{}' } },
        ] },
        { role => 'user', content => 'q2' },
    ];

    # Very large budget so no trim happens
    my $result = trim_conversation_for_api($msgs, 'sys', model_context_window => 999999, max_response_tokens => 1000, debug => 0);

    is(count_orphan_tool_calls($result), 0, 'orphan stripped on early return (no trim)');
};

#---------------------------------------------------------------------------
# Test 3: trim_conversation_for_api strips orphans after trimming
#---------------------------------------------------------------------------
subtest 'trim_conversation_for_api: strips orphan tool_calls after trim' => sub {
    # Build a large conversation where trim drops tool_results but keeps tool_calls
    my $large = 'x' x 100000;  # ~25K tokens
    my $msgs = [
        { role => 'system', content => 'sys' },
        { role => 'user', content => 'q1' },
        { role => 'assistant', content => 'a1', tool_calls => [
            { id => 'call_1', type => 'function', function => { name => 'x', arguments => '{}' } },
        ] },
        { role => 'tool', content => $large, tool_call_id => 'call_1' },
        { role => 'user', content => 'q2' },
        { role => 'assistant', content => 'a2', tool_calls => [
            { id => 'call_2', type => 'function', function => { name => 'x', arguments => '{}' } },
        ] },
        { role => 'tool', content => $large, tool_call_id => 'call_2' },
        { role => 'user', content => 'q3' },
    ];

    # 200K context but small prompt budget to force trimming
    my $result = trim_conversation_for_api($msgs, 'sys',
        model_context_window => 200000,
        max_response_tokens => 200000,  # Make prompt budget very small
        debug => 1,
    );

    is(count_orphan_tool_calls($result), 0, 'no orphan tool_calls after trim');
    if (count_orphan_tool_calls($result) == 0) {
        pass('trim result passes orphan check');
    }
};

#---------------------------------------------------------------------------
# Test 4: End-to-end: trim -> enforce_message_alternation pipeline
# (simulates what process_input does on iteration 1)
#---------------------------------------------------------------------------
subtest 'end-to-end: trim -> enforce_message_alternation removes orphans' => sub {
    # Orphan in loaded history, goes through rebuild path
    my $history = [
        { role => 'user', content => 'q1' },
        { role => 'assistant', content => 'a1', tool_calls => [
            { id => 'call_1', type => 'function', function => { name => 'x', arguments => '{}' } },
        ] },
        # NO tool_result — orphan from prior trim
        { role => 'user', content => 'q2' },
    ];

    # Step 1: trim_conversation_for_api (rebuild path in _build_turn_context)
    my $trimmed = trim_conversation_for_api($history, 'sys',
        model_context_window => 200000, max_response_tokens => 16000, debug => 0);

    # Step 2: enforce_message_alternation (iteration 1 in process_input, no proactive trim)
    my $result = enforce_message_alternation($trimmed, 'anthropic', debug => 0);

    is(count_orphan_tool_calls($result), 0, 'no orphan tool_calls after full pipeline');
    my @errors = anthropic_adjacency_errors($result);
    is(scalar(@errors), 0, 'zero Anthropic adjacency errors after full pipeline');
};

#---------------------------------------------------------------------------
# Test 5: Multiple orphan tool_calls in one assistant message
#---------------------------------------------------------------------------
subtest 'enforce_message_alternation: strips multiple orphan tool_calls' => sub {
    my $msgs = [
        { role => 'user', content => 'q' },
        { role => 'assistant', content => 'a', tool_calls => [
            { id => 'orphan_a', type => 'function', function => { name => 'x', arguments => '{}' } },
            { id => 'orphan_b', type => 'function', function => { name => 'y', arguments => '{}' } },
        ] },
        { role => 'user', content => 'q2' },
    ];

    my $result = enforce_message_alternation($msgs, 'anthropic', debug => 0);
    is(count_orphan_tool_calls($result), 0, 'all orphan tool_calls stripped');
    my @errors = anthropic_adjacency_errors($result);
    is(scalar(@errors), 0, 'zero Anthropic adjacency errors');
};

#---------------------------------------------------------------------------
# Test 6: Partial orphan — one matched, one orphan, both preserved correctly
#---------------------------------------------------------------------------
subtest 'enforce_message_alternation: partial orphan keeps matched pair, strips orphan' => sub {
    my $msgs = [
        { role => 'user', content => 'q' },
        { role => 'assistant', content => 'a', tool_calls => [
            { id => 'matched', type => 'function', function => { name => 'x', arguments => '{}' } },
            { id => 'orphan',  type => 'function', function => { name => 'y', arguments => '{}' } },
        ] },
        { role => 'tool', content => 'r', tool_call_id => 'matched' },
        { role => 'user', content => 'q2' },
    ];

    my $result = enforce_message_alternation($msgs, 'anthropic', debug => 0);
    is(count_orphan_tool_calls($result), 0, 'zero orphan tool_calls');
    my @errors = anthropic_adjacency_errors($result);
    is(scalar(@errors), 0, 'zero Anthropic adjacency errors');

    # Verify matched pair still present
    my $has_matched = grep {
        $_->{role} eq 'assistant' && $_->{tool_calls} &&
        scalar(@{$_->{tool_calls}}) == 1 &&
        $_->{tool_calls}[0]{id} eq 'matched'
    } @$result;
    ok($has_matched, 'matched tool_call preserved after orphan strip');
};

#---------------------------------------------------------------------------
# Test 7: Non-orphan pairs still work (no regression)
#---------------------------------------------------------------------------
subtest 'enforce_message_alternation: non-orphan pairs unaffected' => sub {
    my $msgs = [
        { role => 'system', content => 'sys' },
        { role => 'user', content => 'q1' },
        { role => 'assistant', content => 'a1', tool_calls => [
            { id => 'call_1', type => 'function', function => { name => 'x', arguments => '{}' } },
        ] },
        { role => 'tool', content => 'r1', tool_call_id => 'call_1' },
        { role => 'user', content => 'q2' },
        { role => 'assistant', content => 'a2', tool_calls => [
            { id => 'call_2', type => 'function', function => { name => 'x', arguments => '{}' } },
        ] },
        { role => 'tool', content => 'r2', tool_call_id => 'call_2' },
    ];

    my $result = enforce_message_alternation($msgs, 'anthropic', debug => 0);
    is(count_orphan_tool_calls($result), 0, 'no orphans');
    my @errors = anthropic_adjacency_errors($result);
    is(scalar(@errors), 0, 'zero Anthropic adjacency errors');
    is(scalar(@$result), 7, 'message count preserved (no orphans to strip)');
};

done_testing();
