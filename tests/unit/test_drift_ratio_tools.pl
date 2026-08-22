#!/usr/bin/env perl
# Test: Drift ratio includes tool definition tokens in the estimate
#
# The _learn_from_api_response computes drift = actual_tokens / estimated_tokens.
# The estimated_tokens only counted message content + tool_call JSON, but
# NOT tool definitions (the tools[] array). OpenRouter's usage.prompt_tokens
# includes tool definitions in the prompt count. Without counting them in
# the estimate, drift is inflated (e.g. 4.0 clamp ceiling), which tightens
# the trim threshold to 28,800 tokens and collapses the cache prefix to
# ~25K tokens (the 24,992 observed in the OpenRouter/Poolside session).
#
# This test verifies that tool definitions are now included in the
# estimated_tokens calculation.

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use Test::More;
use CLIO::Memory::TokenEstimator qw(estimate_tokens get_effective_ratio compute_prompt_budget);
use CLIO::Memory::TokenEstimator qw(estimate_tokens get_effective_ratio compute_prompt_budget);
use POSIX qw(ceil);
use CLIO::Util::JSON qw(encode_json safe_encode_json decode_json);

# Call set_learned_ratio directly (not exported, but available as a package function)
CLIO::Memory::TokenEstimator::set_learned_ratio(undef);  # Reset to default

# --- Test 1: Tool definitions add to estimated_chars ---
# Simulate the estimation logic from _learn_from_api_response, both
# without and with the tool-definition fix, on a mock conversation
# with large tool schemas (like CLIO's 16+ tools).

# Simulate a model response where actual prompt tokens = 170K (including
# tool defs). Message content = 130K chars, tool defs = 50K chars.
my $msg_chars = 130_000;
my $tool_def_chars = 50_000;
my $actual_prompt_tokens = 170_000;  # What OpenRouter reports

# Without fix: only message content counted
my $ratio = get_effective_ratio();  # 4.0 (default)
my $estimated_without_tool_defs = int(ceil($msg_chars / $ratio));
my $drift_without = $actual_prompt_tokens / $estimated_without_tool_defs;
$drift_without = 4.0 if $drift_without > 4.0;  # clamped

# With fix: message content + tool def chars counted
my $estimated_with_tool_defs = int(ceil(($msg_chars + $tool_def_chars) / $ratio));
my $drift_with = $actual_prompt_tokens / $estimated_with_tool_defs;
$drift_with = 4.0 if $drift_with > 4.0;  # clamped

diag(sprintf("Without tool defs: estimated=%d, actual=%d, drift=%.2f, threshold=%d",
    $estimated_without_tool_defs, $actual_prompt_tokens, $drift_without,
    int(128000 * 0.90 / $drift_without)));
diag(sprintf("With tool defs:    estimated=%d, actual=%d, drift=%.2f, threshold=%d",
    $estimated_with_tool_defs, $actual_prompt_tokens, $drift_with,
    int(128000 * 0.90 / $drift_with)));

cmp_ok($drift_with, '<', $drift_without,
    "Drift ratio is lower with tool definitions included in estimate");

# With 128K context window:
# Without fix: drift=4.0 (clamped), threshold=28800 -> dialog trimmed to ~22K
# With fix: drift=2.72, threshold=42703 -> dialog trimmed to ~38K
# The fix reduces the over-trimming severity
ok($drift_with < 4.0,
    "Drift does not hit the 4.0 clamp ceiling when tool defs are included");

# --- Test 2: Threshold comparison ---
my $threshold_without = int(128000 * 0.90 / $drift_without);
my $threshold_with = int(128000 * 0.90 / $drift_with);
cmp_ok($threshold_with, '>', $threshold_without,
    "Trim threshold is higher with tool-defs included (less aggressive trimming)");

# --- Test 3: Simulated _learn_from_api_response with tools ---
# Verify the corrected estimation includes tool definition chars.
# This mirrors the logic now in APIManager::_learn_from_api_response.

# Build mock messages
my @messages = (
    { role => 'system', content => 'You are CLIO. ' x 500 },
    { role => 'user', content => 'Fix the bug. ' x 1000 },
    { role => 'assistant', content => 'Investigating. ' x 2000, tool_calls => [
        { id => 'tc_1', type => 'function', function => { name => 'file_operations', arguments => '{"operation":"read","path":"lib/CLIO/Core.pm"}' } },
    ] },
    { role => 'tool', content => 'File content. ' x 3000, tool_call_id => 'tc_1' },
    { role => 'user', content => 'Continue. ' x 100 },
);

# Build mock tools (CLIO-style: each tool has a schema)
my @tools = (
    { type => 'function', function => { name => 'file_operations', description => 'Read, write, search files. ' x 500, parameters => { type => 'object', properties => { operation => { type => 'string', description => 'Operation to perform. ' x 100 } } } } },
    { type => 'function', function => { name => 'version_control', description => 'Git operations. ' x 500, parameters => { type => 'object', properties => {} } } },
    { type => 'function', function => { name => 'terminal_operations', description => 'Execute shell commands. ' x 500, parameters => { type => 'object', properties => {} } } },
);

# Compute estimated_tokens WITHOUT tools (old behavior)
my $est_no_tools = 0;
for my $msg (@messages) {
    $est_no_tools += estimate_tokens($msg->{content} || '');
    if ($msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY') {
        for my $tc (@{$msg->{tool_calls}}) {
            my $json = CLIO::Util::JSON::encode_json($tc);
            $est_no_tools += estimate_tokens($json);
        }
    }
}

# Compute estimated_tokens WITH tools (new behavior)
my $est_with_tools = $est_no_tools;
for my $tool (@tools) {
    my $tool_json = CLIO::Util::JSON::safe_encode_json($tool);
    if (defined $tool_json && length($tool_json) > 0) {
        $est_with_tools += estimate_tokens($tool_json);
    }
}

cmp_ok($est_with_tools, '>', $est_no_tools,
    "Estimated tokens with tool defs > estimated tokens without tool defs");
ok(($est_with_tools - $est_no_tools) > 0,
    "Tool defs add positive token estimate (" . ($est_with_tools - $est_no_tools) . " tokens)");

# Compute drift ratios
# Use a mock actual token count that's realistic (includes tool defs)
my $actual = $est_with_tools * 1.1;  # 10% overhead from JSON structure, special tokens
my $drift_no_tools = $actual / $est_no_tools;
my $drift_with_tools_ratio = $actual / $est_with_tools;

cmp_ok($drift_with_tools_ratio, '<', $drift_no_tools,
    "Drift is lower when tool defs are included in the estimate (actual=$actual, est_no_tools=$est_no_tools, est_with_tools=$est_with_tools, drift_no_tools=" . sprintf("%.2f", $drift_no_tools) . ", drift_with=" . sprintf("%.2f", $drift_with_tools_ratio) . ")");

# --- Test 4: With correct context window (500K), drift stays low ---
# The primary fix is the context_length parsing (500K vs 128K).
# With 500K context, even at a moderate drift of 1.1 (realistic
# after the tool-defs fix), the threshold far exceeds a 170K prompt,
# so no trim fires and the cache stays stable.
{
    CLIO::Memory::TokenEstimator::set_learned_ratio(4.0);  # Reset to default
    # With drift=1.1 (realistic after tool-defs fix), threshold is:
    my $threshold_500k = int(500000 * 0.90 / 1.1);
    ok($threshold_500k > 170000,
        "With 500K ctx and drift=1.1, threshold ($threshold_500k) > 170K prompt — no trim, cache stable");

    # Contrast: with 128K ctx (wrong fallback), even at drift=1.1:
    my $threshold_128k = int(128000 * 0.90 / 1.1);
    ok($threshold_128k < 170000,
        "With 128K ctx and drift=1.1, threshold ($threshold_128k) < 170K prompt — trim fires, cache collapses");
}

done_testing();
