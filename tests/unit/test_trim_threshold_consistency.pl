#!/usr/bin/env perl
# Test: Pre-flight trim threshold consistency with proactive trim
#
# After implementing the pipeline protocol, the pre-flight trim in
# trim_conversation_for_api used its own 90% of (prompt_budget - system)
# threshold, while the proactive trim in WorkflowOrchestrator used the
# drift-aware _compute_drift_aware_threshold (int(ctx * 0.90 / drift)).
# These mismatched thresholds caused double-trims: pre-flight trimmed to
# ~85K, then proactive trimmed again to ~77K (with drift=1.5),
# deinterleaving tool_results twice and breaking LCP cache stability.
#
# This test verifies that trim_conversation_for_api now accepts a
# trim_threshold parameter and uses it as the effective limit, making
# the pre-flight trim and proactive trim agree.

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use Test::More;

use CLIO::Core::ConversationManager qw(trim_conversation_for_api);
use CLIO::Memory::TokenEstimator qw(estimate_tokens compute_prompt_budget);
use CLIO::Core::Defaults;

# --- Test 1: trim_conversation_for_api accepts trim_threshold parameter ---
# Build a history that would exceed the default threshold but fit under
# a higher one (simulating drift-aware threshold being higher than
# prompt_budget).
my $system_prompt = 'You are CLIO, a terminal AI assistant.';
my $sys_tokens = 50;

# Build ~1500 messages, each ~100 tokens. Total ~150K tokens.
my @history;
for my $i (0..1499) {
    push @history, {
        role     => ($i % 2 == 0) ? 'user' : 'assistant',
        content  => "Message $i: " . ('x' x 400),  # ~100 tokens each at ratio 4.0
    };
}

# Without trim_threshold: uses prompt_budget (default 128K ctx -> ~105K budget)
my $prom_budget = CLIO::Memory::TokenEstimator::compute_prompt_budget({
    max_context_window_tokens => 128000,
    max_output_tokens         => 8192,
});
my $result_default = trim_conversation_for_api(\@history, $system_prompt,
    model_context_window => 128000,
    max_response_tokens  => 8192,
    debug                => 0,
);
ok(ref($result_default) eq 'ARRAY', "trim_conversation_for_api returns arrayref");
ok(scalar(@$result_default) < scalar(@history), "Default trim reduced message count");
ok(scalar(@$result_default) > 0, "Default trim kept at least 1 message");

# With trim_threshold: uses the provided threshold (higher than prompt_budget)
# A threshold of 140000 should keep more messages than the default ~105K budget.
my $result_with_threshold = trim_conversation_for_api(\@history, $system_prompt,
    model_context_window => 128000,
    max_response_tokens  => 8192,
    trim_threshold       => 140000,
    debug                => 0,
);
ok(ref($result_with_threshold) eq 'ARRAY', "trim_conversation_for_api returns arrayref with threshold");
ok(scalar(@$result_with_threshold) > scalar(@$result_default),
    "Higher trim_threshold keeps more messages than default threshold");
note(sprintf("Default trim: %d msgs, Threshold=140K: %d msgs", scalar(@$result_default), scalar(@$result_with_threshold)));

# --- Test 2: trim_threshold lower than prompt_budget trims more aggressively ---
# With a lower threshold (e.g. 80K due to drift), should keep fewer messages.
my $result_low_threshold = trim_conversation_for_api(\@history, $system_prompt,
    model_context_window => 128000,
    max_response_tokens  => 8192,
    trim_threshold       => 80000,
    debug                => 0,
);
ok(scalar(@$result_low_threshold) < scalar(@$result_default),
    "Lower trim_threshold (80K) keeps fewer messages than default (~105K)");
note(sprintf("Default trim: %d msgs, Threshold=80K: %d msgs", scalar(@$result_default), scalar(@$result_low_threshold)));

# --- Test 3: Consistency check — threshold parameter is respected ---
# The trim_threshold parameter bypasses the default 90% multiplier and uses
# the threshold directly. When trim_threshold equals safe_threshold, the
# target is (threshold - system_tokens) without the extra 0.9 headroom,
# so it keeps slightly more. This is correct: the drift-aware threshold
# already has the 90% safety margin baked in via _compute_drift_aware_threshold.
my $result_same = trim_conversation_for_api(\@history, $system_prompt,
    model_context_window => 128000,
    max_response_tokens  => 8192,
    trim_threshold       => int($prom_budget * 0.9),
    debug                => 0,
);
ok(scalar(@$result_same) > 0, "trim_threshold (at 90% of budget) keeps messages");
note(sprintf("Threshold=90%% of budget: %d msgs vs default: %d msgs", scalar(@$result_same), scalar(@$result_default)));

# --- Test 4: Preserves tool call/result pairs with trim_threshold ---
# Build history with interleaved tool calls and results
my @history_with_tools;
for my $i (0..99) {
    push @history_with_tools, { role => 'user',    content => "Query $i " . ('x' x 200) };
    push @history_with_tools, {
        role => 'assistant',
        content => "Response $i " . ('x' x 200),
        tool_calls => [{ id => "tc_$i", type => 'function',
            function => { name => 'test_tool', arguments => '{"key":"value"}' } }],
    };
    push @history_with_tools, {
        role => 'tool',
        tool_call_id => "tc_$i",
        content => "Result $i " . ('x' x 200),
    };
}

my $result_tools = trim_conversation_for_api(\@history_with_tools, $system_prompt,
    model_context_window => 128000,
    max_response_tokens  => 8192,
    trim_threshold       => 30000,
    debug                => 0,
);

# After trim, every retained assistant with tool_calls should have
# a corresponding tool_result, and vice versa.
my %tool_call_ids;
my %tool_result_ids;
for my $msg (@$result_tools) {
    if ($msg->{role} eq 'assistant' && $msg->{tool_calls}) {
        for my $tc (@{$msg->{tool_calls}}) {
            $tool_call_ids{$tc->{id}} = 1 if $tc->{id};
        }
    }
    if ($msg->{role} eq 'tool' && $msg->{tool_call_id}) {
        $tool_result_ids{$msg->{tool_call_id}} = 1;
    }
}

my $orphan_calls = 0;
for my $id (keys %tool_call_ids) {
    $orphan_calls++ unless exists $tool_result_ids{$id};
}
my $orphan_results = 0;
for my $id (keys %tool_result_ids) {
    $orphan_results++ unless exists $tool_call_ids{$id};
}

is($orphan_calls, 0, "No orphaned tool_calls after threshold-based trim");
is($orphan_results, 0, "No orphaned tool_results after threshold-based trim");

done_testing();
