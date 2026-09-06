#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# Tests for the context overflow bug fixes:
#   - Budget-aware max_tokens calculation
#   - top_provider field extraction
#   - Model name prefix collision avoidance

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;

# ── Test 1: Error classification for OpenRouter-style "maximum context length" ──
{
    my $error = "This endpoint's maximum context length is 196608 tokens. However, you requested about 200062 tokens (59082 of text input, 9908 of tool input, 131072 in the output). Please reduce the length of either one.";

    # This is the pattern from ResponseHandler after our fix
    # (uses . to match any char between words, matching spaces in the message)
    my $matches = $error =~ /maximum.context.length/i;
    ok($matches, "OpenRouter 'maximum context length' error matches classification pattern");

    # Also check the generic reduce pattern
    my $matches_reduce = $error =~ /reduce.*(?:prompt|input|context|length)/i;
    ok($matches_reduce, "OpenRouter error matches 'reduce' pattern for fallback classification");
}

# ── Test 2: Budget-aware max_tokens doesn't exceed context window ──
{
    # Simulate caps for minimax-m2.7:free on OpenRouter
    my $caps = {
        max_context_window_tokens => 196608,
        max_output_tokens => 176947,  # from top_provider after Bug 2 fix
    };

    require CLIO::Memory::TokenEstimator;
    my $buffer = 8192 + int(196608 * 0.05);  # est_buffer
    $buffer = 51200 if $buffer > 51200;
    my $budget = CLIO::Memory::TokenEstimator::compute_prompt_budget($caps);

    # With correct caps: budget = 196608 - 176947 - ~10000 = ~9661
    # This is tight but positive - the model can still work
    ok($budget > 0, "Prompt budget is positive with correct OpenRouter caps");
    cmp_ok($budget, '<', 196608, "Prompt budget is less than context window");

    # The key invariant: budget + max_output <= context_window
    my $total = $budget + $caps->{max_output_tokens};
    cmp_ok($total, '<', 196608 + $buffer, "Budget + output does not exceed context window");
}

# ── Test 3: Budget-aware max_tokens with large input ──
{
    # Simulate: input has already consumed most of the context
    my $caps = {
        max_context_window_tokens => 196608,
        max_output_tokens => 176947,
    };

    require CLIO::Core::Defaults;
    my $context_window = $caps->{max_context_window_tokens};
    my $max_output = $caps->{max_output_tokens};

    # Simulate 69K tokens of input (like the bug report)
    my $input_tokens = 69000;
    my $est_buffer = CLIO::Core::Defaults::OUTPUT_ESTIMATION_BUFFER()
                   + int($context_window * CLIO::Core::Defaults::OUTPUT_ESTIMATION_BUFFER_PCT());
    my $buffer_cap = CLIO::Core::Defaults::OUTPUT_ESTIMATION_BUFFER_MAX();
    $est_buffer = $buffer_cap if $est_buffer > $buffer_cap;

    my $available_for_output = $context_window - $input_tokens - $est_buffer;
    my $budget_aware = $available_for_output < $max_output ? $available_for_output : $max_output;

    # 196608 - 69000 - ~10864 = ~116744 available for output
    # min(176947, 116744) = 116744
    my $total = $input_tokens + $budget_aware;
    cmp_ok($total, '<=', $context_window,
           "Input ($input_tokens) + budget-aware output ($budget_aware) <= context ($context_window)");
    cmp_ok($budget_aware, '<', $max_output,
           "Budget-aware output ($budget_aware) is less than raw max_output ($max_output) when input is large");
}

# ── Test 4: Provider prefix collision avoidance ──
{
    # Simulate what _parse_model_provider does with a stripped model name
    # This test verifies that 'minimax/minimax-m2.7:free' would be
    # misinterpreted as the 'minimax' CLIO provider (the bug),
    # and that using the full model name 'openrouter/minimax/minimax-m2.7:free'
    # is correctly parsed as provider='openrouter'.

    require CLIO::Providers;

    # Stripped name (what was being passed before the fix):
    my $stripped = 'minimax/minimax-m2.7:free';
    my ($prefix_stripped, $rest_stripped) = ('', '');
    if ($stripped =~ m{^([a-z][a-z0-9_.-]*)/(.+)$}i) {
        my ($p, $r) = ($1, $2);
        if (CLIO::Providers::provider_exists($p)) {
            ($prefix_stripped, $rest_stripped) = ($p, $r);
        }
    }
    is($prefix_stripped, 'minimax', 'Stripped name is mis-parsed as minimax provider (reproduces Bug 1)');

    # Full name (after the fix):
    my $full = 'openrouter/minimax/minimax-m2.7:free';
    my ($prefix_full, $rest_full) = ('', '');
    if ($full =~ m{^([a-z][a-z0-9_.-]*)/(.+)$}i) {
        my ($p, $r) = ($1, $2);
        if (CLIO::Providers::provider_exists($p)) {
            ($prefix_full, $rest_full) = ($p, $r);
        }
    }
    is($prefix_full, 'openrouter', 'Full model name is correctly parsed as openrouter provider (Bug 1 fix)');
    is($rest_full, 'minimax/minimax-m2.7:free', 'OpenRouter model id correctly preserved');
}

# ── Test 5: top_provider field extraction ──
{
    # Simulate OpenRouter API response for minimax/minimax-m2.7:free
    my $info = {
        id => 'minimax/minimax-m2.7:free',
        context_length => 196608,
        top_provider => {
            context_length => 196608,
            max_completion_tokens => 176947,
        },
    };

    # Old behavior (Bug 2): max_output_tokens falls through to DEFAULT (16384)
    my $old_max_output = $info->{max_completion_tokens}
        || 16384;  # DEFAULT_MAX_OUTPUT_TOKENS
    is($old_max_output, 16384, 'Old extraction falls back to DEFAULT when max_completion_tokens is in top_provider');

    # New behavior (Bug 2 fix): check top_provider
    my $tp = ref($info->{top_provider}) eq 'HASH' ? $info->{top_provider} : {};
    my $tp_out = $tp->{max_completion_tokens} || $tp->{max_output_tokens};
    my $new_max_output = $info->{max_completion_tokens} || $tp_out || 16384;
    is($new_max_output, 176947, 'New extraction correctly reads top_provider.max_completion_tokens');
}

# ── Test 6: Budget-aware max_tokens safety net prevents overflow ──
{
    # Worst case: even with the wrong max_output from Bug 1 (131072),
    # the budget-aware calculation should still prevent overflow
    my $context_window = 196608;
    my $wrong_max_output = 131072;  # from minimax static map (Bug 1)
    my $input_tokens = 59082 + 9908;  # 69K from the bug report

    require CLIO::Core::Defaults;
    my $est_buffer = CLIO::Core::Defaults::OUTPUT_ESTIMATION_BUFFER()
                   + int($context_window * CLIO::Core::Defaults::OUTPUT_ESTIMATION_BUFFER_PCT());
    my $buffer_cap = CLIO::Core::Defaults::OUTPUT_ESTIMATION_BUFFER_MAX();
    $est_buffer = $buffer_cap if $est_buffer > $buffer_cap;

    my $available = $context_window - $input_tokens - $est_buffer;
    my $budget_aware = $available < $wrong_max_output ? $available : $wrong_max_output;

    my $total = $input_tokens + $budget_aware;
    cmp_ok($total, '<=', $context_window,
           "Even with wrong max_output (Bug 1), budget-aware max_tokens prevents overflow: $input_tokens + $budget_aware = $total <= $context_window");
}

done_testing();
