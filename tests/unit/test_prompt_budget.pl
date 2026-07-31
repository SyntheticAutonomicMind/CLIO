#!/usr/bin/env perl
# Test: compute_prompt_budget in TokenEstimator produces correct values
# across context/output tiers, and uses the model's actual output cap
# (no hard cap) for the reserve.

use strict;
use warnings;
use utf8;
use lib './lib';
use Test::More;
use CLIO::Memory::TokenEstimator qw(compute_prompt_budget);
use CLIO::Core::Defaults qw(
    DEFAULT_MAX_OUTPUT_TOKENS
    DEFAULT_CONTEXT_WINDOW
    OUTPUT_ESTIMATION_BUFFER
    OUTPUT_ESTIMATION_BUFFER_PCT
    OUTPUT_ESTIMATION_BUFFER_MAX
);

# Helper: compute the expected buffer for a context window using the
# same formula as compute_prompt_budget.
sub _expected_buffer {
    my ($ctx) = @_;
    my $b = OUTPUT_ESTIMATION_BUFFER() + int($ctx * OUTPUT_ESTIMATION_BUFFER_PCT());
    my $cap = OUTPUT_ESTIMATION_BUFFER_MAX();
    return $b > $cap ? $cap : $b;
}

# Sanity check the helper matches the actual function on a few cases
is(_expected_buffer(32768), 8192 + int(32768 * 0.05), "32K buffer = 8K + 1.6K");
is(_expected_buffer(200000), 8192 + int(200000 * 0.05), "200K buffer = 8K + 10K");
is(_expected_buffer(1048576), 51200, "1M buffer = 50K (cap kicks in)");

# ============================================================================
# Tier matrix: (context_window, max_output_tokens, expected_prompt_budget)
# ============================================================================
# Context/output values come from our actual model configurations:
#   32K ctx, 8K output (local llama.cpp small models)
#   128K ctx, 16K output (most cloud models, gpt-4.1, Claude default)
#   200K ctx, 64K output (Anthropic Claude 4.5+)
#   1M ctx, 128K output (MiniMax-M3, Z.AI GLM-5)
#   1M ctx, 16K output (NVIDIA Nemotron 3 Ultra/Super, Llama 4 Maverick)
#   1M ctx, 32K output (DeepSeek V4, Kimi K2)
# ============================================================================

my @tiers = (
    # (label, ctx, out, expected_budget)
    [ '32K/8K local',  32768,  8192  ],
    [ '128K/16K cloud', 131072, 16384 ],
    [ '200K/64K Claude', 200000, 64000 ],
    [ '1M/128K M3',     1048576, 131072],
    [ '1M/16K NIM',     1048576, 16384 ],
    [ '1M/32K DeepSeek', 1048576, 32768 ],
);

for my $tier (@tiers) {
    my ($label, $ctx, $out) = @$tier;
    my $caps = {
        max_context_window_tokens => $ctx,
        max_output_tokens         => $out,
    };
    my $budget = compute_prompt_budget($caps);
    my $expected = $ctx - $out - _expected_buffer($ctx);
    $expected = 1000 if $expected < 1000;

    is($budget, $expected, "$label: budget = ctx - output - buffer = $expected");
}

# ============================================================================
# No hard cap: reserve follows max_output_tokens exactly
# ============================================================================
# A model with 256K output (future hypothetical) should reserve 256K, not
# be clamped to 128K. The user explicitly said "the caps should be whatever
# the model supports".
{
    my $caps = {
        max_context_window_tokens => 1048576,
        max_output_tokens         => 262144,  # 256K output
    };
    my $budget = compute_prompt_budget($caps);
    my $expected = 1048576 - 262144 - _expected_buffer(1048576);
    is($budget, $expected, "1M/256K: no hard cap (256K reserve is honored)");
}

# ============================================================================
# Estimation buffer scales with context window
# ============================================================================
{
    # 32K context: buffer = 8K + 5% of 32K = 8K + 1638 = 9638
    my $b32 = compute_prompt_budget({
        max_context_window_tokens => 32768,
        max_output_tokens         => 4096,
    });
    is($b32, 32768 - 4096 - _expected_buffer(32768), "32K ctx output=4K: buffer = 8K + 1.6K");

    # 200K context: buffer = 8K + 5% of 200K = 8K + 10000 = 18000
    my $b200 = compute_prompt_budget({
        max_context_window_tokens => 200000,
        max_output_tokens         => 4096,
    });
    is($b200, 200000 - 4096 - _expected_buffer(200000), "200K ctx output=4K: buffer = 8K + 10K");

    # 1M context: buffer = 8K + 5% of 1M = 8K + 52428 = 60428, capped at 50K
    my $b1m = compute_prompt_budget({
        max_context_window_tokens => 1048576,
        max_output_tokens         => 4096,
    });
    is($b1m, 1048576 - 4096 - _expected_buffer(1048576), "1M ctx output=4K: buffer capped at 50K");
}

# ============================================================================
# Field-name flexibility: accept max_context_window_tokens, context_window,
# or max_prompt_tokens as the context window
# ============================================================================
{
    # Alias: context_window
    my $b1 = compute_prompt_budget({
        context_window => 131072,
        max_output_tokens => 16384,
    });
    is($b1, 131072 - 16384 - _expected_buffer(131072), "context_window alias works");

    # Alias: max_prompt_tokens (used by MCM-normalized caps)
    my $b2 = compute_prompt_budget({
        max_prompt_tokens => 131072,
        max_output_tokens => 16384,
    });
    is($b2, 131072 - 16384 - _expected_buffer(131072), "max_prompt_tokens alias works");

    # No max_output_tokens: falls back to DEFAULT_MAX_OUTPUT_TOKENS (16K)
    my $b3 = compute_prompt_budget({
        max_context_window_tokens => 131072,
    });
    is($b3, 131072 - 16384 - _expected_buffer(131072), "no max_output_tokens uses DEFAULT_MAX_OUTPUT_TOKENS");
}

# ============================================================================
# Floor at 1000 ensures even tiny-context local models are usable
# ============================================================================
{
    # 1K context with 64K output: budget would be negative, floor at 1000
    my $b = compute_prompt_budget({
        max_context_window_tokens => 1000,
        max_output_tokens         => 65536,  # way more than context
    });
    is($b, 1000, "negative budget floors at 1000 (1K ctx, 64K output)");

    # Empty caps hash: falls back to DEFAULT_CONTEXT_WINDOW (128K) and
    # DEFAULT_MAX_OUTPUT_TOKENS (16K). 128K - 16K - buffer = budget.
    my $b2 = compute_prompt_budget({});
    is($b2, 128000 - 16384 - _expected_buffer(128000), "empty caps hash uses DEFAULT_CONTEXT_WINDOW + DEFAULT_MAX_OUTPUT_TOKENS");
}

# ============================================================================
# Comparison: previous behavior (50% reserve) vs new (actual output reserve)
# ============================================================================
# Demonstrates the user's complaint: for 1M context with 16K actual output,
# the old 50% reserve (500K) was 31x what's actually needed.
{
    my $ctx = 1048576;
    my $out = 16384;
    my $old_reserve = int($ctx * 0.50);  # 524288
    my $new_budget = compute_prompt_budget({
        max_context_window_tokens => $ctx,
        max_output_tokens         => $out,
    });
    my $new_reserve = $ctx - $new_budget;

    ok($new_reserve < $old_reserve,
        "1M ctx with 16K output: new reserve ($new_reserve) < old 50% reserve ($old_reserve)");
    ok($new_reserve <= $out + 60000,
        "1M ctx with 16K output: new reserve fits output + buffer ($new_reserve <= " . ($out + 60000) . ")");
}

# ============================================================================
# Sanity: covers all provider/model combos in our static map
# ============================================================================
# Quick sanity check that every output tier we have configured falls within
# a reasonable prompt budget. This isn't a strict correctness test - just that
# the helper doesn't produce negative or absurd values.
{
    my @max_outputs = (8192, 16384, 32768, 64000, 128000, 131072);
    for my $out (@max_outputs) {
        for my $ctx (32768, 131072, 200000, 1048576) {
            my $budget = compute_prompt_budget({
                max_context_window_tokens => $ctx,
                max_output_tokens         => $out,
            });
            ok($budget >= 1000, "ctx=$ctx out=$out: budget >= floor ($budget)");
            ok($budget <= $ctx, "ctx=$ctx out=$out: budget <= context ($budget <= $ctx)");
        }
    }
}

done_testing();
