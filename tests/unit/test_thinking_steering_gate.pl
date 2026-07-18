#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
#
# Regression test for the M3 thinking-steering bug:
# The "Reasoning Visibility" steering paragraph was over-firing for every
# provider with show_thinking=1, producing low-quality planning-list thinking
# on MiniMax-M3 (`**Locating X****Reporting Y****Preparing Z**`). The fix
# gates needs_thinking_steering on:
#   1. reasoning_mode resolving to 'adaptive' (per MCM._get_reasoning_mode)
#   2. AND the model name matching the Anthropic family pattern (per
#      MCM._anthropic_model_reasoning_mode returning 'adaptive')
#
# Other providers have adaptive mode too (M3 supports_adaptive_thinking=1)
# but they don't have the summarizer-collapse problem, so they shouldn't
# fire the steering. This test exercises the gate logic directly without
# requiring a real Anthropic API key.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use Test::More;

use CLIO::Core::ModelCapabilitiesManager;

my $mcm = CLIO::Core::ModelCapabilitiesManager->new(debug => 0);

# The two halves of the gate. The full WorkflowOrchestrator logic ANDs
# these, but we test each independently so the test doesn't depend on a
# real Anthropic API key for capabilities lookup.

# Half 1: family heuristic alone (no API needed).
sub _family_mode {
    my ($model) = @_;
    return $mcm->_anthropic_model_reasoning_mode($model);
}

# Half 2: full gate logic. With M3 in the static map, reasoning_mode='adaptive'
# resolves locally. With other providers (DeepSeek, OpenAI, Z.AI) it resolves
# locally too. Anthropic models would need API access for caps, but we
# simulate by treating the family check as authoritative for the model
# names in our test cases.
sub _gate_for_test {
    my ($model, $simulated_reasoning_mode) = @_;
    return 0 unless defined $model && length $model;
    # Distinguish "explicit undef from caller" from "no argument at all"
    # so we can test the gate's undef-reasoning_mode branch correctly.
    return 0 unless @_ >= 2;
    return 0 unless defined $simulated_reasoning_mode && $simulated_reasoning_mode eq 'adaptive';
    my $family_mode = _family_mode($model);
    return (defined $family_mode && $family_mode eq 'adaptive') ? 1 : 0;
}

# ---------------------------------------------------------------------------
# Test 1: Family heuristic classifies correctly for Anthropic family.
# This is the discriminator - M3's family_mode is undef, Anthropic adaptive
# family returns 'adaptive', Anthropic legacy returns 'enabled'.
# ---------------------------------------------------------------------------
subtest 'family heuristic - Anthropic adaptive family returns adaptive' => sub {
    for my $model (qw(
        claude-sonnet-4-6
        claude-opus-4-7
        claude-opus-4-8
        claude-fable-5
        claude-mythos-5
        Proxy-Fable-5
        internal-mythos-5
        anthropic-claude-sonnet-4-6
    )) {
        is(_family_mode($model), 'adaptive',
            "$model: family_mode=adaptive (triggers steering when reasoning_mode=adaptive)");
    }
};

subtest 'family heuristic - Anthropic legacy returns enabled' => sub {
    for my $model (qw(
        claude-haiku-4-5-20251001
        claude-sonnet-4-20250514
        claude-opus-4-20250514
    )) {
        is(_family_mode($model), 'enabled',
            "$model: family_mode=enabled (legacy mode, summarizer-collapse N/A)");
    }
};

subtest 'family heuristic - non-Anthropic returns undef' => sub {
    for my $model (qw(
        minimax/MiniMax-M3
        deepseek/deepseek-v4-pro
        openai/o1
        zai/glm-5
        gpt-4o
        mistral-large
        gemini-2-5-pro
    )) {
        is(_family_mode($model), undef,
            "$model: family_mode=undef (not Anthropic family)");
    }
};

# ---------------------------------------------------------------------------
# Test 4: Full gate logic. With reasoning_mode=adaptive (simulated from API),
# the gate fires for Anthropic family adaptive models and stays off for
# everything else (including M3, which has adaptive reasoning_mode but is
# not Anthropic family).
# ---------------------------------------------------------------------------
subtest 'gate fires for Anthropic family adaptive' => sub {
    for my $model (qw(
        claude-sonnet-4-6
        claude-opus-4-7
        claude-mythos-5
        Proxy-Fable-5
        internal-mythos-5
    )) {
        is(_gate_for_test($model, 'adaptive'), 1,
            "$model: gate fires (reasoning_mode=adaptive AND family=adaptive)");
    }
};

# ---------------------------------------------------------------------------
# Test 5 (THE REGRESSION): M3 must NOT trigger steering even when its
# reasoning_mode resolves to 'adaptive' (which it does, via supports_adaptive_thinking
# in the M3 static map). M3's "adaptive" is the native reasoning format,
# not the Anthropic summarizer-collapse case.
# ---------------------------------------------------------------------------
subtest 'regression - M3 adaptive mode does NOT trigger steering' => sub {
    is(_gate_for_test('minimax/MiniMax-M3', 'adaptive'), 0,
        'M3: gate=0 even with reasoning_mode=adaptive (the original M3 regression)');
};

# ---------------------------------------------------------------------------
# Test 6: gate stays off for non-adaptive reasoning_modes.
# Even Anthropic family models in legacy/enabled mode don't trigger.
# ---------------------------------------------------------------------------
subtest 'gate stays off when reasoning_mode is not adaptive' => sub {
    for my $model (qw(
        claude-sonnet-4-6
        claude-opus-4-7
        minimax/MiniMax-M3
        deepseek/deepseek-v4-pro
    )) {
        is(_gate_for_test($model, 'enabled'), 0,
            "$model: gate=0 when reasoning_mode=enabled");
        is(_gate_for_test($model, 'effort'), 0,
            "$model: gate=0 when reasoning_mode=effort");
        is(_gate_for_test($model, undef), 0,
            "$model: gate=0 when reasoning_mode=undef");
    }
};

# ---------------------------------------------------------------------------
# Test 7: empty/undef model - safety.
# ---------------------------------------------------------------------------
subtest 'empty/undef model - gate=0' => sub {
    is(_gate_for_test(undef, 'adaptive'), 0, 'undef model: gate=0');
    is(_gate_for_test('', 'adaptive'),    0, 'empty model: gate=0');
};

done_testing();
