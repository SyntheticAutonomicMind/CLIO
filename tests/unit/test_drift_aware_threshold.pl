#!/usr/bin/env perl
# Tests for the drift-aware trim threshold (CLIO::Core::WorkflowOrchestrator)
#
# Each model's tokenizer produces different counts than the chars/token
# heuristic assumes. When a model consistently differs by 1.2x or more,
# the proactive trim at compute_prompt_budget would ship an oversized payload
# that the provider rejects. The drift-aware threshold:
#   1. Saves the actual/estimated ratio on each successful API response
#      via APIManager::_learn_from_api_response
#   2. Reads the saved ratio from session state on each trim
#   3. Tightens the trim threshold by that ratio: adjusted = raw / drift
#
# The base threshold is now compute_prompt_budget($caps) =
#   ctx_window - output_reserve - est_buffer
# which properly accounts for the model's max_output_tokens. This replaces
# the old int(ctx * 0.90) formula that ignored the output reserve and could
# allow the total payload (prompt + output) to exceed the context window.

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use Test::More;

use CLIO::Memory::TokenEstimator qw(compute_prompt_budget);

# =============================================================================
# Drift-aware threshold computation
# =============================================================================

# Default caps used across most tests: 128K context, 16K output (local model
# default). Mirrors the CachyLLama scenario from 2026-08-20.
my $DEFAULT_CAPS = {
    max_context_window_tokens => 131072,
    max_output_tokens         => 16384,
};

sub compute_threshold {
    my %a = @_;
    my $caps = $a{caps} || $DEFAULT_CAPS;
    my $drift = $a{drift}          || 1.0;
    my $metadata_age = $a{age}     || 0;

    # Mirror logic from _compute_drift_aware_threshold:
    # raw = compute_prompt_budget($caps)
    my $raw = compute_prompt_budget($caps);

    # Read drift ratio from session state (mirrored here as a parameter).
    my $drift_ratio = 1.0;
    if ($a{drift} && $a{drift} >= 1.2 && $metadata_age < 3600) {
        $drift_ratio = $a{drift};
    } elsif ($a{drift} && $a{drift} > 0 && $a{drift} < 1.2) {
        $drift_ratio = $a{drift};
    }

    my $adjusted = $raw;
    if ($drift_ratio > 1.0) {
        $adjusted = int($raw / $drift_ratio);
    }
    return ($raw, $adjusted);
}

subtest 'default threshold when no drift data' => sub {
    my ($raw, $adj) = compute_threshold(caps => $DEFAULT_CAPS);
    # compute_prompt_budget(128K ctx, 16K output) = 128000 - 16384 - est_buffer
    # est_buffer = 8192 + int(131072 * 0.05) = 8192 + 6553 = 14745
    # raw = 131072 - 16384 - 14745 = 99943
    is($raw, 99943, 'raw = compute_prompt_budget(128K ctx, 16K output)');
    is($adj, 99943, 'adjusted = raw when drift_ratio is 1.0');
    cmp_ok($adj, '<', 131072 * 0.90, 'threshold is now below 90% of ctx (accounts for output reserve)');
    diag(sprintf("Old threshold was %d (90%% of ctx); new threshold is %d (ctx - output - buffer).",
        int(131072 * 0.90), $adj));
};

subtest 'CachyLLama scenario: drift=1.56 tightens threshold by 1.56x' => sub {
    # raw = 99943 (compute_prompt_budget)
    # adjusted = int(99943 / 1.56) = 64066
    my ($raw, $adj) = compute_threshold(caps => $DEFAULT_CAPS, drift => 1.56);
    is($raw, 99943, 'raw = compute_prompt_budget');
    is($adj, 64066, 'tightened to 64066 estimated tokens (was 75617 with old 90% formula)');
    ok($adj < $raw, 'tightening reduces threshold');
    # The adjusted threshold in ACTUAL tokens (estimated * drift) should be ~99943,
    # which fits within the 131072 context window with 16384+14745 = 31129 tokens
    # reserved for output + buffer. 99943 + 31129 = 131072 = exactly ctx.
    my $effective_actual = int($adj * 1.56);
    ok($effective_actual <= 131072, "adjusted threshold in actual tokens ($effective_actual) <= ctx (131072)");
};

subtest 'small drift (1.1x) is applied but minor impact' => sub {
    my ($raw, $adj) = compute_threshold(caps => $DEFAULT_CAPS, drift => 1.1);
    # 99943 / 1.1 = 90857
    is($adj, 90857, 'small drift applied (minor tightening)');
    ok($adj > $raw * 0.85, 'minor tightening keeps threshold above 85% of raw');
};

subtest 'gate at 1.2 inclusive' => sub {
    my ($raw, $adj) = compute_threshold(caps => $DEFAULT_CAPS, drift => 1.2);
    # 99943 / 1.2 = 83285
    is($adj, 83285, 'drift=1.20 triggers tightening: 99943 / 1.20 = 83285');
};

subtest 'stale drift ratio (older than 1 hour) is ignored' => sub {
    my ($raw, $adj) = compute_threshold(caps => $DEFAULT_CAPS, drift => 1.56, age => 7200);
    is($adj, $raw, 'old drift ratio falls back to default (no tightening)');
};

subtest 'never loosens below raw (drift < 1.0 has no effect)' => sub {
    my ($raw, $adj) = compute_threshold(caps => $DEFAULT_CAPS, drift => 0.9);
    is($adj, $raw, 'drift < 1.0 means local estimate OVERcounts, no tightening');
};

subtest 'tiny model: 4K ctx yields floor' => sub {
    # For a 4K context model with 4K output, compute_prompt_budget returns 1000
    # (the minimum floor). With drift 1.5: int(1000 / 1.5) = 666.
    my $tiny_caps = {
        max_context_window_tokens => 4096,
        max_output_tokens         => 4096,
    };
    my ($raw, $adj) = compute_threshold(caps => $tiny_caps, drift => 1.5);
    is($raw, 1000, 'tiny ctx hits the 1000-token floor in compute_prompt_budget');
    is($adj, 666, 'tiny ctx with drift yields 666 (caller clamps as needed)');
};

subtest 'anthropic-sized 200K ctx with drift' => sub {
    my $anthro_caps = {
        max_context_window_tokens => 200000,
        max_output_tokens         => 4096,
    };
    my ($raw, $adj) = compute_threshold(caps => $anthro_caps, drift => 1.3);
    # compute_prompt_budget = 200000 - 4096 - (8192 + 10000) = 177712
    # adjusted = int(177712 / 1.3) = 136701
    is($raw, 177712, 'raw = compute_prompt_budget(200K ctx, 4K output)');
    is($adj, 136701, 'tightened to 136K estimated');
};

subtest 'MiniMax 1M ctx with 128K output — old formula would overflow' => sub {
    # OLD formula: int(1000000 * 0.90) = 900000
    # NEW formula: compute_prompt_budget = 1000000 - 131072 - 51200 = 817728
    # The old threshold (900K) + 128K output = 1,028K > 1M ctx -> OVERFLOW!
    # The new threshold (817K) + 128K output + 51K buffer = ~997K < 1M -> SAFE
    my $minimax_caps = {
        max_context_window_tokens => 1000000,
        max_output_tokens         => 131072,
    };
    my ($raw, $adj) = compute_threshold(caps => $minimax_caps);
    is($raw, 817728, 'raw = compute_prompt_budget(1M ctx, 128K output)');
    cmp_ok($raw, '<', int(1000000 * 0.90), 'new threshold is below old 90% formula (817K < 900K)');
    my $projected_total = $raw + 131072 + 51200;  # threshold + output + buffer
    cmp_ok($projected_total, '<=', 1000000, "new threshold + output + buffer ($projected_total) <= 1M ctx");
    my $old_projected = int(1000000 * 0.90) + 131072;  # old threshold + output (no buffer)
    cmp_ok($old_projected, '>', 1000000, "old 90% threshold + output ($old_projected) > 1M ctx — overflow!");
};

subtest 'DeepSeek V4: 64K ctx, 8K output' => sub {
    # OLD: int(65536 * 0.90) = 58982; 58982 + 8192 = 67174 > 65536 -> OVERFLOW!
    # NEW: compute_prompt_budget = 65536 - 8192 - (8192 + 3276) = 45876
    #       45876 + 8192 + 11468 = 65536 = exactly ctx -> SAFE
    my $ds_caps = {
        max_context_window_tokens => 65536,
        max_output_tokens         => 8192,
    };
    my ($raw, $adj) = compute_threshold(caps => $ds_caps);
    is($raw, 45876, 'raw = compute_prompt_budget(64K ctx, 8K output)');
    cmp_ok($raw, '<', int(65536 * 0.90), 'new threshold below old 90% formula (45876 < 58982)');
    my $projected_total = $raw + 8192 + 11468;
    cmp_ok($projected_total, '<=', 65536, "new threshold + output + buffer ($projected_total) <= 64K ctx");
};

# =============================================================================
# Drift ratio computation (saved to state)
# =============================================================================

sub compute_drift_ratio {
    my %a = @_;
    return unless $a{estimated_tokens} > 0 && $a{actual_tokens} > 0;
    my $drift = $a{actual_tokens} / $a{estimated_tokens};
    $drift = 4.0 if $drift > 4.0;
    $drift = 1.0 if $drift < 1.0;
    return $drift;
}

subtest 'drift ratio: estimate matches actual = 1.0' => sub {
    is(compute_drift_ratio(estimated_tokens => 100, actual_tokens => 100), 1.0, 'ratio 1.0');
};

subtest 'drift ratio: 1.56x undercount (CachyLLama)' => sub {
    my $d = compute_drift_ratio(estimated_tokens => 104616, actual_tokens => 163014);
    ok(($d >= 1.55 && $d <= 1.56), "drift ~1.56 (got $d)");
};

subtest 'drift ratio: estimate overcounts (rare)' => sub {
    is(compute_drift_ratio(estimated_tokens => 1000, actual_tokens => 800), 1.0, 'clamped to 1.0 floor');
};

subtest 'drift ratio: extreme undercount clamped to 4.0' => sub {
    is(compute_drift_ratio(estimated_tokens => 100, actual_tokens => 100000), 4.0, 'clamped to 4.0 cap');
};

subtest 'drift ratio: zero estimate returns undef' => sub {
    is(compute_drift_ratio(estimated_tokens => 0, actual_tokens => 100), undef, 'returns undef');
};

# =============================================================================
# end-to-end: threshold + drift composition
# =============================================================================

subtest 'CachyLLama end-to-end: threshold accounts for output reserve' => sub {
    my $ctx = 131072;
    my $srv_estimated_tokens = 104616;  # what CLIO thinks it sent
    my $srv_actual_tokens    = 163014;  # what server saw

    # Compute the drift ratio we'd save to state after a 400 reveals this
    my $drift = compute_drift_ratio(estimated_tokens => $srv_estimated_tokens, actual_tokens => $srv_actual_tokens);

    # Now compute the next trim threshold with that drift
    my ($raw, $adj) = compute_threshold(caps => $DEFAULT_CAPS, drift => $drift);

    # The adjusted threshold in ACTUAL tokens (estimated * drift) should be
    # ~99943, which fits within ctx with output + buffer reserved.
    my $effective_actual = int($adj * $drift);
    my $output_reserve = 16384;
    my $est_buffer = 8192 + int($ctx * 0.05);
    my $budget = $ctx - $output_reserve - $est_buffer;
    ok(abs($effective_actual - $budget) <= 5, "adjusted threshold in actual tokens ~ $budget (got $effective_actual)");
    ok($effective_actual + $output_reserve + $est_buffer <= $ctx,
        "actual tokens + output + buffer ($effective_actual + $output_reserve + $est_buffer = " . ($effective_actual + $output_reserve + $est_buffer) . ") <= ctx ($ctx)");
};

done_testing();
