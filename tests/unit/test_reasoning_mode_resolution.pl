#!/usr/bin/perl
# SPDX-License-Identifier: GPL-3.0-only
use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../../lib";

# Regression: ModelCapabilitiesManager._ensure_reasoning_mode determines
# which thinking format to send to the API (adaptive/enabled/effort).
# Wrong mode = wrong payload format = thinking rejected or rendered
# as garbage.
#
# The old code was purely heuristic. It broke in two ways:
#
# 1. Anthropic regex `-(?:opus|sonnet|haiku)-4-(?:[6-9]|\d{2,})$` only
#    matched model names that END with the version number. It missed
#    date-suffixed Anthropic models (claude-sonnet-4-20250514,
#    claude-opus-4-5-20251101) and pre-4.6 mid-cycle releases
#    (claude-opus-4-1, claude-sonnet-4-5). All of these were
#    classified as 'enabled' even when the actual model wanted
#    'adaptive' (4.6+ only) or vice versa.
#
# 2. The Anthropic /v1/models response provides explicit
#    supports_adaptive_thinking and supports_enabled_thinking fields.
#    These were read by _fetch_anthropic_capabilities but never
#    consulted by _ensure_reasoning_mode. The heuristic ran even
#    when authoritative data was available.
#
# Fix:
# - _ensure_reasoning_mode now checks supports_adaptive_thinking /
#   supports_enabled_thinking FIRST. The Anthropic API's own data
#   wins.
# - The Anthropic regex was relaxed: no longer requires $ at the
#   end, so date-suffixed models (claude-sonnet-4-6-20251001) match
#   the "4-6+" rule.
# - MiniMax static maps now set supports_adaptive_thinking (M3) or
#   supports_enabled_thinking (M2.x) explicitly, so they don't
#   depend on the heuristic at all.

use Test::More;

use CLIO::Core::ModelCapabilitiesManager;

my $mcm = CLIO::Core::ModelCapabilitiesManager->new();

# Helper to drive _ensure_reasoning_mode in isolation. The internal
# method is the one that does all the work; get_capabilities calls
# _ensure_reasoning_mode and caches the result, so testing the helper
# directly is the cleanest way to verify the resolution rules.
sub _run {
    my (%args) = @_;
    my $caps = $args{caps} || {};
    $mcm->_ensure_reasoning_mode($caps, $args{provider}, $args{model});
    return $caps;
}

# Test 1: Already-set value is preserved
{
    my $caps = _run(
        provider => 'anthropic',
        model    => 'claude-sonnet-4-20250514',
        caps     => { supports_reasoning => 1, reasoning_mode => 'enabled' },
    );
    is($caps->{reasoning_mode}, 'enabled',
        'already-set reasoning_mode is preserved (caller knows best)');
}

# Test 2: Non-reasoning model gets no mode
{
    my $caps = _run(
        provider => 'anthropic',
        model    => 'claude-sonnet-4-20250514',
        caps     => { supports_reasoning => 0 },
    );
    ok(!exists $caps->{reasoning_mode},
        'supports_reasoning=0 leaves reasoning_mode unset');
}

# Test 3: Anthropic API data wins over heuristic (adaptive)
{
    my $caps = _run(
        provider => 'anthropic',
        model    => 'claude-sonnet-4-20250514',  # would be 'enabled' by heuristic
        caps     => {
            supports_reasoning => 1,
            supports_adaptive_thinking => 1,
        },
    );
    is($caps->{reasoning_mode}, 'adaptive',
        'Anthropic supports_adaptive_thinking wins over heuristic');
}

# Test 4: Anthropic API data wins over heuristic (enabled)
{
    my $caps = _run(
        provider => 'anthropic',
        model    => 'claude-sonnet-4-7',  # would be 'adaptive' by heuristic
        caps     => {
            supports_reasoning => 1,
            supports_enabled_thinking => 1,
        },
    );
    is($caps->{reasoning_mode}, 'enabled',
        'Anthropic supports_enabled_thinking wins over heuristic');
}

# Test 5: Anthropic adaptive preferred when both supported
{
    my $caps = _run(
        provider => 'anthropic',
        model    => 'claude-sonnet-4-7',
        caps     => {
            supports_reasoning => 1,
            supports_adaptive_thinking => 1,
            supports_enabled_thinking => 1,
        },
    );
    is($caps->{reasoning_mode}, 'adaptive',
        'adaptive preferred when both thinking types are supported');
}

# Test 6: Heuristic - Anthropic 4.6+ bare version
{
    my $caps = _run(
        provider => 'anthropic',
        model    => 'claude-sonnet-4-6',
        caps     => { supports_reasoning => 1 },
    );
    is($caps->{reasoning_mode}, 'adaptive',
        'Anthropic 4.6+ bare version -> adaptive');
}

# Test 7: Heuristic - Anthropic 4.6+ date-suffixed (was broken)
{
    my $caps = _run(
        provider => 'anthropic',
        model    => 'claude-sonnet-4-6-20251001',
        caps     => { supports_reasoning => 1 },
    );
    is($caps->{reasoning_mode}, 'adaptive',
        'Anthropic 4.6+ with date suffix -> adaptive (was broken)');
}

# Test 8: Heuristic - Anthropic 4.5 (older, not 4.6+)
{
    my $caps = _run(
        provider => 'anthropic',
        model    => 'claude-sonnet-4-5-20250929',
        caps     => { supports_reasoning => 1 },
    );
    is($caps->{reasoning_mode}, 'enabled',
        'Anthropic 4.5 -> enabled (older API)');
}

# Test 9: Heuristic - Anthropic date-only (Sonnet 4)
{
    my $caps = _run(
        provider => 'anthropic',
        model    => 'claude-sonnet-4-20250514',
        caps     => { supports_reasoning => 1 },
    );
    is($caps->{reasoning_mode}, 'enabled',
        'Anthropic 4.0 (date-only) -> enabled');
}

# Test 10: Heuristic - Anthropic Opus 4.1
{
    my $caps = _run(
        provider => 'anthropic',
        model    => 'claude-opus-4-1-20250805',
        caps     => { supports_reasoning => 1 },
    );
    is($caps->{reasoning_mode}, 'enabled',
        'Anthropic Opus 4.1 -> enabled (older than 4.6)');
}

# Test 11: Heuristic - Google always uses enabled
{
    my $caps = _run(
        provider => 'google',
        model    => 'gemini-2.5-flash',
        caps     => { supports_reasoning => 1 },
    );
    is($caps->{reasoning_mode}, 'enabled',
        'Google -> enabled (thinkingBudget)');
}

# Test 12: Heuristic - MiniMax M3 -> adaptive
{
    my $caps = _run(
        provider => 'minimax',
        model    => 'MiniMax-M3',
        caps     => { supports_reasoning => 1 },
    );
    is($caps->{reasoning_mode}, 'adaptive',
        'MiniMax M3 -> adaptive (matches real MiniMax API)');
}

# Test 13: Heuristic - MiniMax M2.x -> enabled
{
    my $caps = _run(
        provider => 'minimax',
        model    => 'MiniMax-M2.7',
        caps     => { supports_reasoning => 1 },
    );
    is($caps->{reasoning_mode}, 'enabled',
        'MiniMax M2.7 -> enabled (matches real MiniMax API)');
}

# Test 14: MiniMax M3 with data-driven field wins over heuristic
# (Even though heuristic would also produce 'adaptive', the data-
# driven path is exercised and we want to verify it gets used.)
{
    my $caps = _run(
        provider => 'minimax',
        model    => 'MiniMax-M3',
        caps     => {
            supports_reasoning => 1,
            supports_adaptive_thinking => 1,  # set by static map
        },
    );
    is($caps->{reasoning_mode}, 'adaptive',
        'MiniMax M3 with data-driven adaptive_thinking -> adaptive');
}

# Test 15: MiniMax M2.7 with data-driven field
{
    my $caps = _run(
        provider => 'minimax',
        model    => 'MiniMax-M2.7',
        caps     => {
            supports_reasoning => 1,
            supports_enabled_thinking => 1,  # set by static map
        },
    );
    is($caps->{reasoning_mode}, 'enabled',
        'MiniMax M2.7 with data-driven enabled_thinking -> enabled');
}

# Test 16: Heuristic - Z.AI always uses enabled
{
    my $caps = _run(
        provider => 'zai',
        model    => 'glm-5',
        caps     => { supports_reasoning => 1 },
    );
    is($caps->{reasoning_mode}, 'enabled',
        'Z.AI -> enabled (chain-of-thought)');
}

# Test 17: Heuristic - Default (OpenAI, DeepSeek, NVIDIA, etc.) -> effort
{
    for my $provider (qw(openai deepseek nvidia openrouter github_copilot)) {
        my $caps = _run(
            provider => $provider,
            model    => 'some-model',
            caps     => { supports_reasoning => 1 },
        );
        is($caps->{reasoning_mode}, 'effort',
            "$provider -> effort (reasoning_effort parameter)");
    }
}

# Test 18: End-to-end - get_capabilities for MiniMax M3 returns reasoning_mode
{
    # Use a fresh MCM to avoid cache
    my $mcm2 = CLIO::Core::ModelCapabilitiesManager->new();
    my $caps = $mcm2->get_capabilities('minimax', 'MiniMax-M3');
    ok($caps && $caps->{reasoning_mode}, 'get_capabilities(MiniMax M3) returns reasoning_mode');
    is($caps->{reasoning_mode}, 'adaptive',
        'MiniMax M3 end-to-end reasoning_mode is adaptive');
}

# Test 19: End-to-end - get_capabilities for MiniMax M2.7 returns enabled
{
    my $mcm2 = CLIO::Core::ModelCapabilitiesManager->new();
    my $caps = $mcm2->get_capabilities('minimax', 'MiniMax-M2.7');
    is($caps->{reasoning_mode}, 'enabled',
        'MiniMax M2.7 end-to-end reasoning_mode is enabled');
}

done_testing();
