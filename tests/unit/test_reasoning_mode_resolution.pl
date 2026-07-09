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


# ========================================================================
# Anthropic 5-series and proxy aliases
# ========================================================================
# Regression: an earlier commit introduced the LIST endpoint fallback, which
# routes models from Anthropic-compatible proxies (Azure Foundry, custom
# deployments) through the heuristic in _ensure_reasoning_mode for the
# first time. The previous regex only recognized 4.6+ generations
# (-sonnet-4-6, -opus-4-7) and a hardcoded mythos prefix. It did not
# recognize:
#
# 1. The new bare -5 generation (Sonnet 5, Opus 5, Haiku 5, Fable 5,
#    Mythos 5) - all of which are adaptive per Anthropic's API docs.
# 2. Proxy aliases that don't start with "claude-" (e.g.
#    "Proxy-Sonnet-5", "Proxy-Opus-4-8"). The heuristic was
#    hardcoded for "claude-" prefixed names; proxy deployment names
#    broke it.
#
# Result: Proxy-Sonnet-5 was being misclassified as 'enabled' mode
# and CLIO was sending {"thinking": {"type": "enabled", ...}} which
# Anthropic's API (and any modern proxy) rejects with HTTP 400
# "thinking.type.enabled is not supported for this model".
#
# The fix extends the regex to match the {family}-5 suffix (anywhere
# in the name) and adds "fable" to the family list.

# Test 20: Anthropic Sonnet 5 bare -> adaptive
{
    my $caps = _run(
        provider => 'anthropic',
        model    => 'claude-sonnet-5',
        caps     => { supports_reasoning => 1 },
    );
    is($caps->{reasoning_mode}, 'adaptive',
        'Anthropic Sonnet 5 -> adaptive (5-series is adaptive-only)');
}

# Test 21: Anthropic Opus 5 bare -> adaptive
{
    my $caps = _run(
        provider => 'anthropic',
        model    => 'claude-opus-5',
        caps     => { supports_reasoning => 1 },
    );
    is($caps->{reasoning_mode}, 'adaptive',
        'Anthropic Opus 5 -> adaptive');
}

# Test 22: Anthropic Haiku 5 bare -> adaptive
{
    my $caps = _run(
        provider => 'anthropic',
        model    => 'claude-haiku-5',
        caps     => { supports_reasoning => 1 },
    );
    is($caps->{reasoning_mode}, 'adaptive',
        'Anthropic Haiku 5 -> adaptive');
}

# Test 23: Anthropic Fable 5 bare -> adaptive (always-on adaptive per docs)
{
    my $caps = _run(
        provider => 'anthropic',
        model    => 'claude-fable-5',
        caps     => { supports_reasoning => 1 },
    );
    is($caps->{reasoning_mode}, 'adaptive',
        'Anthropic Fable 5 -> adaptive (always-on per Anthropic docs)');
}

# Test 24: Anthropic Mythos 5 bare -> adaptive
{
    my $caps = _run(
        provider => 'anthropic',
        model    => 'claude-mythos-5',
        caps     => { supports_reasoning => 1 },
    );
    is($caps->{reasoning_mode}, 'adaptive',
        'Anthropic Mythos 5 -> adaptive (always-on per Anthropic docs)');
}

# Test 25: Proxy alias for Sonnet 5 (no "claude-" prefix) -> adaptive
# This is the EXACT scenario from the live bug report: Proxy-Sonnet-5
# was being sent to the API with thinking.type=enabled and HTTP 400'd.
{
    my $caps = _run(
        provider => 'anthropic',
        model    => 'Proxy-Sonnet-5',
        caps     => { supports_reasoning => 1 },
    );
    is($caps->{reasoning_mode}, 'adaptive',
        'Proxy alias Proxy-Sonnet-5 -> adaptive (was misclassified as enabled, caused HTTP 400)');
}

# Test 26: Proxy alias for Opus 4.8 -> adaptive
{
    my $caps = _run(
        provider => 'anthropic',
        model    => 'Proxy-Opus-4-8',
        caps     => { supports_reasoning => 1 },
    );
    is($caps->{reasoning_mode}, 'adaptive',
        'Proxy alias Proxy-Opus-4-8 -> adaptive (works for proxy deployment names)');
}

# Test 27: Proxy alias for Sonnet 4.5 (older) -> enabled
# 4.5 is older than 4.6, so it stays in 'enabled' mode. The alias
# check must NOT over-match and accidentally adaptive-classify 4.5.
{
    my $caps = _run(
        provider => 'anthropic',
        model    => 'Proxy-Sonnet-4-5',
        caps     => { supports_reasoning => 1 },
    );
    is($caps->{reasoning_mode}, 'enabled',
        'Proxy alias Proxy-Sonnet-4-5 -> enabled (4.5 is pre-adaptive)');
}

# Test 28: Anthropic 3.5 still enabled (sanity check that we didn't break old models)
{
    my $caps = _run(
        provider => 'anthropic',
        model    => 'claude-3-5-sonnet-20241022',
        caps     => { supports_reasoning => 1 },
    );
    is($caps->{reasoning_mode}, 'enabled',
        'Anthropic 3.5 Sonnet -> enabled (no adaptive support)');
}

# ========================================================================
# Provider-agnostic Anthropic-family detection
# ========================================================================
# Regression: Anthropic-compatible proxies (Azure Foundry, custom
# deployments) often register under a non-"anthropic" provider name.
# The previous heuristic gated the Anthropic-family regex on
# $provider =~ /^anthropic$/i, so any custom-named provider with a
# Claude-family model name fell through to the default 'effort' mode
# and the request went out with the wrong thinking format.
#
# The fix: extract the Anthropic-family regex into
# _anthropic_model_reasoning_mode (a model-name-only helper) and call
# it first in _ensure_reasoning_mode, before any provider-name gating.
# The Anthropic-family tokens (sonnet/opus/haiku/fable/mythos) are
# unique enough to Anthropic that this is safe.

# Test 29: Custom provider name with Anthropic-family model -> adaptive
# (proxy registered under a custom name but pointing at Anthropic-compatible
# API). Same scenario the user hit with Proxy-Sonnet-5.
{
    my $caps = _run(
        provider => 'my-custom-anthropic-proxy',
        model    => 'claude-sonnet-5',
        caps     => { supports_reasoning => 1 },
    );
    is($caps->{reasoning_mode}, 'adaptive',
        'Custom provider name with claude-sonnet-5 -> adaptive (provider-agnostic detection)');
}

# Test 30: Custom provider with proxy alias for Sonnet 5 -> adaptive
{
    my $caps = _run(
        provider => 'corp-internal-proxy',
        model    => 'Proxy-Sonnet-5',
        caps     => { supports_reasoning => 1 },
    );
    is($caps->{reasoning_mode}, 'adaptive',
        'Custom provider with proxy alias Proxy-Sonnet-5 -> adaptive');
}

# Test 31: Custom provider with proxy alias for Opus 4.8 -> adaptive
{
    my $caps = _run(
        provider => 'azure-foundry',
        model    => 'internal-opus-4-8',
        caps     => { supports_reasoning => 1 },
    );
    is($caps->{reasoning_mode}, 'adaptive',
        'Custom provider azure-foundry with internal-opus-4-8 -> adaptive');
}

# Test 32: Custom provider with proxy alias for Sonnet 4.5 (pre-adaptive)
# must STILL classify as enabled, not over-match.
{
    my $caps = _run(
        provider => 'corp-internal-proxy',
        model    => 'Proxy-Sonnet-4-5',
        caps     => { supports_reasoning => 1 },
    );
    is($caps->{reasoning_mode}, 'enabled',
        'Custom provider with proxy alias Proxy-Sonnet-4-5 -> enabled (4.5 is pre-adaptive)');
}

# Test 33: Custom provider with Mythos 5 -> adaptive (always-on)
{
    my $caps = _run(
        provider => 'corp-internal-proxy',
        model    => 'my-mythos-5-deployment',
        caps     => { supports_reasoning => 1 },
    );
    is($caps->{reasoning_mode}, 'adaptive',
        'Custom provider with mythos-5 deployment -> adaptive');
}

# Test 34: Non-Anthropic-family model on custom provider -> falls through
# to provider-specific heuristic. "effort" is the default for unknown
# providers (OpenAI/DeepSeek/NVIDIA/OpenRouter).
{
    my $caps = _run(
        provider => 'some-random-provider',
        model    => 'gpt-4o-mini',
        caps     => { supports_reasoning => 1 },
    );
    is($caps->{reasoning_mode}, 'effort',
        'Non-Anthropic-family model on custom provider -> effort (provider-specific default)');
}

# Test 35: Provider=anthropic with non-family model still uses enabled
# (the previous provider=anthropic fallback was 'enabled'; this
# confirms it didn't accidentally become 'effort').
{
    my $caps = _run(
        provider => 'anthropic',
        model    => 'some-anthropic-model-without-sonnet-naming',
        caps     => { supports_reasoning => 1 },
    );
    is($caps->{reasoning_mode}, 'enabled',
        'anthropic provider with non-family model name -> enabled (legacy fallback)');
}

# Test 36: _anthropic_model_reasoning_mode direct call - the helper
# extracted from _ensure_reasoning_mode, provider-name independent.
# This is the source of truth used by both MCM and Anthropic.pm.
{
    is($mcm->_anthropic_model_reasoning_mode('claude-sonnet-5'), 'adaptive',
        'helper: claude-sonnet-5 -> adaptive');
    is($mcm->_anthropic_model_reasoning_mode('claude-sonnet-4-6'), 'adaptive',
        'helper: claude-sonnet-4-6 -> adaptive');
    is($mcm->_anthropic_model_reasoning_mode('claude-sonnet-4-20250514'), 'enabled',
        'helper: claude-sonnet-4-20250514 (4.0 dated) -> enabled');
    is($mcm->_anthropic_model_reasoning_mode('claude-sonnet-4-5-20250929'), 'enabled',
        'helper: claude-sonnet-4-5-20250929 (4.5 dated) -> enabled');
    is($mcm->_anthropic_model_reasoning_mode('Proxy-Sonnet-5'), 'adaptive',
        'helper: Proxy-Sonnet-5 -> adaptive');
    is($mcm->_anthropic_model_reasoning_mode('Proxy-Opus-4-8'), 'adaptive',
        'helper: Proxy-Opus-4-8 -> adaptive');
    is($mcm->_anthropic_model_reasoning_mode('claude-mythos'), 'adaptive',
        'helper: claude-mythos -> adaptive');
    is($mcm->_anthropic_model_reasoning_mode('claude-mythos-preview'), 'adaptive',
        'helper: claude-mythos-preview -> adaptive');
    is($mcm->_anthropic_model_reasoning_mode('claude-fable-5'), 'adaptive',
        'helper: claude-fable-5 -> adaptive');
    is($mcm->_anthropic_model_reasoning_mode('claude-haiku-5'), 'adaptive',
        'helper: claude-haiku-5 -> adaptive');
    is($mcm->_anthropic_model_reasoning_mode('claude-opus-4-1'), 'enabled',
        'helper: claude-opus-4-1 (4.1) -> enabled');
    is($mcm->_anthropic_model_reasoning_mode('claude-3-5-sonnet-20241022'), 'enabled',
        'helper: claude-3-5-sonnet-20241022 (3.5) -> enabled');
    is($mcm->_anthropic_model_reasoning_mode('gpt-4o'), undef,
        'helper: gpt-4o -> undef (not Anthropic family)');
    is($mcm->_anthropic_model_reasoning_mode('MiniMax-M3'), undef,
        'helper: MiniMax-M3 -> undef (not Anthropic family)');
    is($mcm->_anthropic_model_reasoning_mode(undef), undef,
        'helper: undef -> undef');
    is($mcm->_anthropic_model_reasoning_mode(''), undef,
        'helper: empty string -> undef');
}

done_testing();
