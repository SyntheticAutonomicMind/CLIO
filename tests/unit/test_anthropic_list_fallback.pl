#!/usr/bin/perl
# SPDX-License-Identifier: GPL-3.0-only
use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../../lib";

# Regression: Anthropic MCM only called /v1/models/{model_id} (per-model
# endpoint). Azure AI Foundry and similar proxies alias models under
# deployment names, so:
#
# - User configures "claude-sonnet-4.6" (the underlying Anthropic model
#   name); Foundry accepts it on /v1/messages via canonical-name routing
# - MCM calls /v1/models/claude-sonnet-4.6 -> HTTP 404 (Foundry only
#   exposes deployment names on this endpoint)
# - MCM returns undef, APIManager caches undef, reasoning_mode is undef,
#   thinking params never reach the model, context_window collapses to
#   whatever fallback wins downstream (forcing 64k instead of 200k)
#
# /api models looked correct because Models.pm hardcodes 200k for every
# Anthropic row regardless of MCM's actual success, masking the bug.
#
# Fix:
# _fetch_anthropic_capabilities now:
# 1. Tries per-model endpoint first (/v1/models/{model_id}) - rich data
#    including supports_adaptive_thinking / supports_enabled_thinking
# 2. Falls back to LIST endpoint (/v1/models) when per-model 404s or
#    returns malformed data, using _find_model_in_list for case-
#    insensitive and prefix-stripped matches (handles deployment-name
#    aliases and "anthropic/..." prefix differences)
# 3. Translates the LIST entry to MCM standard schema, accepting the
#    various field-name conventions proxies use (max_input_tokens,
#    context_window, context_length for input; max_tokens,
#    max_output_tokens, max_completion_tokens for output)
# 4. Falls back to Providers.pm Anthropic defaults for any field the
#    proxy omits
#
# Two helpers were extracted:
# - _parse_anthropic_per_model_response (rich data path)
# - _build_anthropic_caps_from_list_entry (sparse / proxy data path)
#
# Tests below cover the helper translations in isolation, the LIST
# fallback control flow via source-level checks, and end-to-end
# reasoning_mode resolution for proxied models.

use Test::More;

use CLIO::Core::ModelCapabilitiesManager;

my $mcm = CLIO::Core::ModelCapabilitiesManager->new();

# ========================================================================
# Helper: _parse_anthropic_per_model_response (rich data path)
# ========================================================================

# Test 1: Anthropic native /v1/models/{id} response with full capabilities
{
    my $response = {
        id => 'claude-sonnet-4-20250514',
        display_name => 'Claude Sonnet 4',
        type => 'model',
        created_at => '2025-05-14',
        max_input_tokens => 200000,
        max_tokens => 16384,
        capabilities => {
            thinking => {
                supported => 1,
                types => {
                    adaptive => { supported => 1 },
                    enabled  => { supported => 1 },
                },
            },
            image_input => { supported => 1 },
        },
    };

    my $caps = $mcm->_parse_anthropic_per_model_response($response, 'claude-sonnet-4-20250514');
    ok($caps, 'per-model: returns hashref for full Anthropic response');
    is($caps->{provider}, 'anthropic', 'per-model: provider=anthropic');
    is($caps->{model}, 'claude-sonnet-4-20250514', 'per-model: model from response id');
    is($caps->{context_window}, 200000, 'per-model: context_window=200000');
    is($caps->{max_prompt_tokens}, 200000, 'per-model: max_prompt_tokens=200000');
    is($caps->{max_output_tokens}, 16384, 'per-model: max_output_tokens=16384');
    ok($caps->{supports_tools}, 'per-model: supports_tools=1');
    ok($caps->{supports_streaming}, 'per-model: supports_streaming=1');
    ok($caps->{supports_vision}, 'per-model: supports_vision=1');
    ok($caps->{supports_reasoning}, 'per-model: supports_reasoning=1');
    ok($caps->{supports_adaptive_thinking}, 'per-model: supports_adaptive_thinking=1');
    ok($caps->{supports_enabled_thinking}, 'per-model: supports_enabled_thinking=1');
    is($caps->{architecture}, 'claude', 'per-model: architecture=claude');
    is_deeply($caps->{raw}, $response, 'per-model: raw preserves full response');
}

# Test 2: Per-model response missing max_tokens falls back to provider default
{
    my $response = {
        id => 'claude-sonnet-4-20250514',
        max_input_tokens => 200000,
        capabilities => {
            thinking => { supported => 1, types => { enabled => { supported => 1 } } },
        },
    };

    my $caps = $mcm->_parse_anthropic_per_model_response($response, 'claude-sonnet-4-20250514');
    is($caps->{context_window}, 200000, 'per-model fallback: context_window from response');
    # max_tokens missing -> falls back to Anthropic provider default (64000)
    is($caps->{max_output_tokens}, 64000, 'per-model fallback: max_output_tokens from Providers.pm default');
}

# Test 3: Per-model response missing max_input_tokens falls back to provider default
{
    my $response = {
        id => 'claude-sonnet-4-20250514',
        max_tokens => 16384,
    };

    my $caps = $mcm->_parse_anthropic_per_model_response($response, 'claude-sonnet-4-20250514');
    # max_input_tokens missing -> falls back to Anthropic provider default (200000)
    is($caps->{context_window}, 200000, 'per-model fallback: context_window from Providers.pm default');
    is($caps->{max_output_tokens}, 16384, 'per-model fallback: max_output_tokens from response');
}

# Test 4: Requested model used as fallback when response has no id
{
    my $response = {
        max_input_tokens => 200000,
    };

    my $caps = $mcm->_parse_anthropic_per_model_response($response, 'my-requested-model');
    is($caps->{model}, 'my-requested-model', 'per-model: requested_model used when response id missing');
}

# ========================================================================
# Helper: _build_anthropic_caps_from_list_entry (LIST response path)
# ========================================================================

# Test 5: LIST entry with Anthropic-native field names (max_input_tokens, max_tokens)
{
    my $entry = {
        id => 'claude-sonnet-4-20250514',
        display_name => 'Claude Sonnet 4',
        type => 'model',
        created_at => '2025-05-14',
        max_input_tokens => 200000,
        max_tokens => 16384,
        capabilities => {
            thinking => {
                supported => 1,
                types => {
                    adaptive => { supported => 1 },
                    enabled  => { supported => 1 },
                },
            },
            image_input => { supported => 1 },
        },
    };

    my $caps = $mcm->_build_anthropic_caps_from_list_entry($entry, 'claude-sonnet-4-20250514');
    ok($caps, 'LIST entry: returns hashref for rich Anthropic entry');
    is($caps->{context_window}, 200000, 'LIST entry: context_window from max_input_tokens');
    is($caps->{max_output_tokens}, 16384, 'LIST entry: max_output_tokens from max_tokens');
    ok($caps->{supports_adaptive_thinking}, 'LIST entry: supports_adaptive_thinking set when in capabilities');
    ok($caps->{supports_enabled_thinking}, 'LIST entry: supports_enabled_thinking set when in capabilities');
    is($caps->{supports_reasoning}, 1, 'LIST entry: supports_reasoning=1 when capabilities.thinking.supported');
}

# Test 6: LIST entry with OpenAI-style field names (context_window, max_completion_tokens)
# Some proxies (Azure Foundry, OpenRouter-style proxies) add these to
# the list response. MCM must accept them.
{
    my $entry = {
        id => 'claude-sonnet-4-20250514',
        context_window => 200000,
        max_completion_tokens => 16384,
    };

    my $caps = $mcm->_build_anthropic_caps_from_list_entry($entry, 'claude-sonnet-4-20250514');
    is($caps->{context_window}, 200000, 'LIST OpenAI-style: context_window accepted');
    is($caps->{max_output_tokens}, 16384, 'LIST OpenAI-style: max_completion_tokens accepted');
}

# Test 7: Sparse LIST entry with no token metadata - uses provider defaults
{
    my $entry = {
        id => 'claude-sonnet-4-20250514',
        display_name => 'Claude Sonnet 4',
        type => 'model',
    };

    my $caps = $mcm->_build_anthropic_caps_from_list_entry($entry, 'claude-sonnet-4-20250514');
    is($caps->{context_window}, 200000, 'LIST sparse: context_window from Providers.pm default');
    is($caps->{max_output_tokens}, 64000, 'LIST sparse: max_output_tokens from Providers.pm default');
    # When capabilities block is absent from a sparse LIST response, we
    # still set supports_reasoning=1 (all Claude models support thinking)
    # so the request path actually sends reasoning_effort. adaptive/enabled
    # flags stay undef so _ensure_reasoning_mode's name heuristic picks
    # the right mode (adaptive for 4.6+, enabled for older).
    is($caps->{supports_reasoning}, 1, 'LIST sparse: supports_reasoning=1 (all Claude models support thinking)');
    is($caps->{supports_adaptive_thinking}, undef, 'LIST sparse: supports_adaptive_thinking=undef');
    is($caps->{supports_enabled_thinking}, undef, 'LIST sparse: supports_enabled_thinking=undef');
}

# Test 8: LIST entry with deployment alias (Azure Foundry scenario)
# The proxy returns the deployment name as id but with full metadata.
# The user-configured model might be the canonical name or the
# deployment name - either way, _find_model_in_list handles the match,
# and once matched, the entry data is used.
{
    my $entry = {
        id => 'my-alias-4-6',  # Azure Foundry deployment name
        context_window => 200000,
        max_output_tokens => 16384,
        capabilities => {
            thinking => { supported => 1, types => { adaptive => { supported => 1 } } },
            image_input => { supported => 1 },
        },
    };

    my $caps = $mcm->_build_anthropic_caps_from_list_entry($entry, 'my-alias-4-6');
    is($caps->{model}, 'my-alias-4-6', 'LIST alias: model uses entry id');
    is($caps->{context_window}, 200000, 'LIST alias: context_window from entry');
    is($caps->{max_output_tokens}, 16384, 'LIST alias: max_output_tokens from entry');
    ok($caps->{supports_adaptive_thinking}, 'LIST alias: adaptive thinking surfaced from capabilities');
}

# Test 9: LIST entry with thinking but types block absent
{
    my $entry = {
        id => 'claude-sonnet-4-20250514',
        max_input_tokens => 200000,
        capabilities => {
            thinking => { supported => 1 },
        },
    };

    my $caps = $mcm->_build_anthropic_caps_from_list_entry($entry, 'claude-sonnet-4-20250514');
    is($caps->{supports_reasoning}, 1, 'LIST thinking-only: supports_reasoning=1');
    is($caps->{supports_adaptive_thinking}, undef, 'LIST thinking-only: supports_adaptive_thinking undef (no types block)');
    is($caps->{supports_enabled_thinking}, undef, 'LIST thinking-only: supports_enabled_thinking undef (no types block)');
}

# Test 10: LIST entry with thinking but supported=0
{
    my $entry = {
        id => 'claude-sonnet-4-20250514',
        max_input_tokens => 200000,
        capabilities => {
            thinking => { supported => 0 },
        },
    };

    my $caps = $mcm->_build_anthropic_caps_from_list_entry($entry, 'claude-sonnet-4-20250514');
    is($caps->{supports_reasoning}, 0, 'LIST thinking-off: supports_reasoning=0');
}

# Test 11: Field-name priority (max_input_tokens beats context_window)
{
    my $entry = {
        id => 'claude-sonnet-4-20250514',
        max_input_tokens => 200000,  # Preferred (Anthropic-native)
        context_window => 999999,    # Lower priority
    };

    my $caps = $mcm->_build_anthropic_caps_from_list_entry($entry, 'claude-sonnet-4-20250514');
    is($caps->{context_window}, 200000, 'LIST field priority: max_input_tokens beats context_window');
}

# ========================================================================
# _find_model_in_list integration with Anthropic LIST response shapes
# ========================================================================

# Test 12: Case-insensitive lookup against Azure Foundry list
{
    my $entries = [
        { id => 'my-alias-sonnet-4-6', context_window => 200000 },
        { id => 'claude-haiku-4-5',    context_window => 200000 },
    ];
    my $matched = $mcm->_find_model_in_list($entries, 'MY-ALIAS-SONNET-4-6', 'id');
    ok($matched && $matched->{id} eq 'my-alias-sonnet-4-6',
        'LIST lookup: case-insensitive match for deployment alias');
}

# Test 13: Prefix-stripped match (response has 'anthropic/' prefix)
{
    my $entries = [
        { id => 'anthropic/claude-sonnet-4-20250514', context_window => 200000 },
        { id => 'anthropic/claude-haiku-4-5',        context_window => 200000 },
    ];
    my $matched = $mcm->_find_model_in_list($entries, 'claude-sonnet-4-20250514', 'id');
    ok($matched && $matched->{id} eq 'anthropic/claude-sonnet-4-20250514',
        'LIST lookup: prefix-stripped match (response has anthropic/, caller does not)');
}

# Test 14: Reverse prefix-stripped match (caller has 'anthropic/' prefix)
{
    my $entries = [
        { id => 'claude-sonnet-4-20250514', context_window => 200000 },
    ];
    my $matched = $mcm->_find_model_in_list($entries, 'anthropic/claude-sonnet-4-20250514', 'id');
    ok($matched && $matched->{id} eq 'claude-sonnet-4-20250514',
        'LIST lookup: prefix-stripped match (caller has anthropic/, response does not)');
}

# ========================================================================
# _ensure_reasoning_mode resolution after LIST fallback
# ========================================================================

# Test 15: After LIST fallback for an Anthropic 4.6 model with no
# capabilities.thinking.types in the response, _ensure_reasoning_mode
# should set reasoning_mode='adaptive' via the name heuristic.
{
    my $caps = $mcm->_build_anthropic_caps_from_list_entry(
        { id => 'claude-sonnet-4-6', context_window => 200000 },  # sparse entry
        'claude-sonnet-4-6'
    );
    is($caps->{supports_reasoning}, 1, 'LIST sparse: supports_reasoning=1 (reasoning is supported, mode unresolved)');

    $mcm->_ensure_reasoning_mode($caps, 'anthropic', 'claude-sonnet-4-6');
    is($caps->{reasoning_mode}, 'adaptive',
        'after LIST fallback for 4.6: reasoning_mode=adaptive via heuristic');
}

# Test 16: After LIST fallback for an older Anthropic model, heuristic
# picks 'enabled' (the legacy thinking mode).
{
    my $caps = $mcm->_build_anthropic_caps_from_list_entry(
        { id => 'claude-3-5-sonnet-20241022', context_window => 200000 },
        'claude-3-5-sonnet-20241022'
    );
    $mcm->_ensure_reasoning_mode($caps, 'anthropic', 'claude-3-5-sonnet-20241022');
    is($caps->{reasoning_mode}, 'enabled',
        'after LIST fallback for 3.x model: reasoning_mode=enabled via heuristic');
}

# Test 17: LIST entry that DOES include capabilities.thinking.types.adaptive
# should produce reasoning_mode=adaptive without consulting the heuristic.
{
    my $caps = $mcm->_build_anthropic_caps_from_list_entry(
        {
            id => 'my-aliased-claude-4-5',  # alias name that heuristic would mis-classify
            context_window => 200000,
            capabilities => {
                thinking => { supported => 1, types => { adaptive => { supported => 1 } } },
            },
        },
        'my-aliased-claude-4-5'
    );
    $mcm->_ensure_reasoning_mode($caps, 'anthropic', 'my-aliased-claude-4-5');
    is($caps->{reasoning_mode}, 'adaptive',
        'LIST entry with explicit adaptive caps: reasoning_mode=adaptive (data wins over heuristic)');
}

# ========================================================================
# Source-level checks (regression guards)
# ========================================================================

# Test 18: _fetch_anthropic_capabilities tries per-model first, then falls back to LIST
{
    my $src = do { local $/; open my $fh, '<', 'lib/CLIO/Core/ModelCapabilitiesManager.pm' or die; <$fh> };

    # Locate the function block
    my $start = index($src, 'sub _fetch_anthropic_capabilities');
    my $end   = index($src, 'sub _parse_anthropic_per_model_response');
    my $block = substr($src, $start, $end - $start);

    like($block, qr/my \$per_model_url\s*=\s*"\$\{?api_base\}?\/\$model"/,
        'per-model URL is constructed as $api_base/$model');
    like($block, qr/\$list_resp\s*=\s*\$http->get\(\s*\$api_base\b/,
        'LIST fallback calls $http->get($api_base) (the /v1/models list)');
    like($block, qr/_find_model_in_list\(\s*\$entries\s*,\s*\$model\s*,\s*['\']id['\"]/,
        'LIST fallback uses _find_model_in_list with id_field=id');
    like($block, qr/_build_anthropic_caps_from_list_entry/,
        'LIST fallback calls _build_anthropic_caps_from_list_entry to translate');
    unlike($block, qr/return undef\s*unless\s*\$resp->\{success\}/,
        'per-model failure no longer hard-returns undef (falls through to LIST)');
}

# Test 19: Both helpers exist as separate subs
{
    my $src = do { local $/; open my $fh, '<', 'lib/CLIO/Core/ModelCapabilitiesManager.pm' or die; <$fh> };
    like($src, qr/^sub _parse_anthropic_per_model_response\s*\{/m,
        '_parse_anthropic_per_model_response is defined');
    like($src, qr/^sub _build_anthropic_caps_from_list_entry\s*\{/m,
        '_build_anthropic_caps_from_list_entry is defined');
    like($src, qr/=head2 _parse_anthropic_per_model_response \(Internal\)/,
        '_parse_anthropic_per_model_response has POD');
    like($src, qr/=head2 _build_anthropic_caps_from_list_entry \(Internal\)/,
        '_build_anthropic_caps_from_list_entry has POD');
}

# Test 20: Anthropic provider default max_context_tokens is 200000
# (verifies the fallback to provider defaults yields the right value
# for proxy-list responses with no metadata)
{
    require CLIO::Providers;
    my $pdef = CLIO::Providers::get_provider('anthropic');
    is($pdef->{max_context_tokens}, 200000, 'Anthropic provider default max_context_tokens=200000');
    # Updated 2026-07-31: Claude 4.5+ default output is 64K. The Anthropic
    # native API exposes the actual per-model max via /v1/models, but the
    # Providers.pm default is used when the API is unreachable or the
    # model is new and not yet in the response.
    is($pdef->{max_output_tokens}, 64000, 'Anthropic provider default max_output_tokens=64000');
}

# ========================================================================
# xhigh thinking effort support (Anthropic 4.6+ adaptive)
# ========================================================================

# Test 21: Anthropic _default_thinking_config accepts xhigh effort
{
    require CLIO::Providers::Anthropic;
    my $provider = CLIO::Providers::Anthropic->new(
        api_key => 'test-key',
        model   => 'claude-sonnet-4-6',
    );

    # xhigh passed through as-is (not coerced to medium)
    my $cfg = $provider->_default_thinking_config('claude-sonnet-4-6', {
        enabled => 1,
        mode    => 'adaptive',
        effort  => 'xhigh',
    });
    is($cfg->{effort}, 'xhigh',
        'Anthropic adaptive: xhigh effort is preserved (not coerced to medium)');
    is($cfg->{mode}, 'adaptive',
        'Anthropic adaptive: mode=adaptive preserved');
}

# Test 22: Anthropic xhigh in enabled mode maps to a larger budget
{
    require CLIO::Providers::Anthropic;
    my $provider = CLIO::Providers::Anthropic->new(
        api_key => 'test-key',
        model   => 'claude-3-5-sonnet-20241022',
    );

    # For older models that don't support adaptive, xhigh maps to 32k budget
    my $cfg = $provider->_default_thinking_config('claude-3-5-sonnet-20241022', {
        enabled => 1,
        mode    => 'enabled',
        effort  => 'xhigh',
    });
    is($cfg->{mode}, 'enabled', 'Anthropic enabled: mode=enabled for 3.5 model');
    is($cfg->{effort}, 'xhigh', 'Anthropic enabled: effort=xhigh preserved');
    ok($cfg->{budget_tokens} && $cfg->{budget_tokens} > 20000,
        'Anthropic enabled: xhigh maps to budget > 20k (deeper than high)');
    cmp_ok($cfg->{budget_tokens}, '<=', 65536,
        'Anthropic enabled: xhigh budget <= 64k safety ceiling');
}

# Test 23: Anthropic validates unknown effort levels and falls back to medium
{
    require CLIO::Providers::Anthropic;
    my $provider = CLIO::Providers::Anthropic->new(
        api_key => 'test-key',
        model   => 'claude-sonnet-4-6',
    );

    # Garbage effort value -> falls back to medium
    my $cfg = $provider->_default_thinking_config('claude-sonnet-4-6', {
        enabled => 1,
        mode    => 'adaptive',
        effort  => 'gibberish',
    });
    is($cfg->{effort}, 'medium',
        'Anthropic adaptive: unknown effort falls back to medium (safety)');
}

# Test 24: Google _build_thinking_config accepts xhigh and maps to high budget
{
    require CLIO::Providers::Google;
    my $provider = CLIO::Providers::Google->new(
        api_key => 'test-key',
        model   => 'gemini-2.5-pro',
    );

    my $cfg = $provider->_build_thinking_config('gemini-2.5-pro', {
        enabled => 1,
        effort  => 'xhigh',
    });
    ok($cfg, 'Google: _build_thinking_config returns hash for xhigh');
    is($cfg->{thinkingBudget}, 24576,
        'Google: xhigh effort maps to high budget (24576) since Google has no distinct xhigh tier');
}

# Test 25: Google unknown effort falls back to medium budget
{
    require CLIO::Providers::Google;
    my $provider = CLIO::Providers::Google->new(
        api_key => 'test-key',
        model   => 'gemini-2.5-pro',
    );

    my $cfg = $provider->_build_thinking_config('gemini-2.5-pro', {
        enabled => 1,
        effort  => 'gibberish',
    });
    is($cfg->{thinkingBudget}, 8192,
        'Google: unknown effort falls back to medium budget (8192)');
}

done_testing();
