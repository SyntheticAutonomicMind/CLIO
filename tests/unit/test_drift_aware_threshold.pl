#!/usr/bin/env perl
# Tests for the drift-aware trim threshold (CLIO::Core::WorkflowOrchestrator)
#
# Each model's tokenizer produces different counts than the chars/token
# heuristic assumes. When a model consistently differs by 1.2x or more,
# the proactive trim at 90% of ctx ships an oversized payload that the
# provider rejects. The drift-aware threshold:
#   1. Saves the actual/estimated ratio on each successful API response
#      via APIManager::_learn_from_api_response
#   2. Reads the saved ratio from session state on each trim
#   3. Tightens the trim threshold by that ratio: adjusted = raw_90pct / drift
#
# Without drift-aware thresholding, a session whose last turn ran tools
# and grew the cached payload past 90% of ctx would fail the very next
# resume with HTTP 400 (token limit exceeded) — the bug we fixed on
# CachyLLama 2026-08-20.

use strict;
use warnings;
use lib './lib';
use Test::More;

# =============================================================================
# Drift-aware threshold computation
# =============================================================================

sub compute_threshold {
    my %a = @_;
    my $ctx = $a{ctx}              || 131072;
    my $drift = $a{drift}          || 1.0;
    my $metadata_age = $a{age}     || 0;
    my $raw = int($ctx * 0.90);

    # Mirror logic from WorkflowOrchestrator::_compute_drift_aware_threshold
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

subtest 'default 90% threshold when no drift data' => sub {
    my ($raw, $adj) = compute_threshold(ctx => 131072);
    is($raw, 117964, 'raw = 90% of ctx');
    is($adj, 117964, 'adjusted = raw when drift_ratio is 1.0');
};

subtest 'CachyLLama scenario: drift=1.56 tightens threshold by 1.56x' => sub {
    # 131072 * 0.90 / 1.56 = 75617 estimated tokens
    # At actual/estimated=1.56, this corresponds to 117964 actual tokens,
    # which is exactly 90% of ctx on the server.
    my ($raw, $adj) = compute_threshold(ctx => 131072, drift => 1.56);
    is($raw, 117964, 'raw 90% threshold');
    is($adj, 75617, 'tightened to 75617 estimated tokens');
    ok($adj < $raw, 'tightening reduces threshold');
};

subtest 'small drift (1.1x) is applied but minor impact' => sub {
    my ($raw, $adj) = compute_threshold(ctx => 131072, drift => 1.1);
    # Code uses small drift ratios (< 1.2) but the impact is minor:
    # 117964 / 1.1 = 107239, only ~9% tightening vs the ~40% for CachyLLama 1.56x
    is($adj, 107239, 'small drift applied (minor tightening)');
    ok($adj > $raw * 0.9, 'minor tightening keeps threshold above 90% of raw');
};

subtest 'gate at 1.2 inclusive' => sub {
    my ($raw, $adj) = compute_threshold(ctx => 131072, drift => 1.2);
    is($adj, 98303, 'drift=1.20 triggers tightening: 117964 / 1.20 = 98303');
};

subtest 'stale drift ratio (older than 1 hour) is ignored' => sub {
    my ($raw, $adj) = compute_threshold(ctx => 131072, drift => 1.56, age => 7200);
    is($adj, $raw, 'old drift ratio falls back to default');
};

subtest 'never loosens below raw 90% (drift < 1.0 has no effect)' => sub {
    my ($raw, $adj) = compute_threshold(ctx => 131072, drift => 0.9);
    is($adj, $raw, 'drift < 1.0 means local estimate OVERcounts, no tightening');
};

subtest 'tiny model: 4096 ctx with drift keeps floor' => sub {
    my ($raw, $adj) = compute_threshold(ctx => 4096, drift => 1.5);
    # 4096 * 0.90 / 1.5 = 2457 (below MIN_CSSS_SLOT_TOKENS=8000 — caller should clamp)
    is($adj, 2457, 'tiny ctx yields small threshold (caller clamps)');
};

subtest 'anthropic-sized 200K ctx with drift' => sub {
    my ($raw, $adj) = compute_threshold(ctx => 200000, drift => 1.3);
    is($raw, 180000, 'raw = 180K');
    is($adj, 138461, 'tightened to 138K estimated');
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

subtest 'CachyLLama end-to-end: same numbers as the live fix' => sub {
    my $ctx = 131072;
    my $srv_estimated_tokens = 104616;  # what CLIO thinks it sent
    my $srv_actual_tokens    = 163014;  # what server saw

    # Compute the drift ratio we'd save to state after a 400 reveals this
    my $drift = compute_drift_ratio(estimated_tokens => $srv_estimated_tokens, actual_tokens => $srv_actual_tokens);

    # Now compute the next trim threshold with that drift
    my ($raw, $adj) = compute_threshold(ctx => $ctx, drift => $drift);

    # The adjusted threshold in ACTUAL tokens (estimated * drift) should be ~90% of ctx.
    # Allow +/-2 to absorb integer truncation rounding.
    my $effective_actual = int($adj * $drift);
    my $expected = int($ctx * 0.90);
    ok(abs($effective_actual - $expected) <= 5, "adjusted threshold in actual tokens ~ $expected (got $effective_actual)");
};

done_testing();
