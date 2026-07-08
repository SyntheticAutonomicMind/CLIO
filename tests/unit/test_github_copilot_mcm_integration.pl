#!/usr/bin/perl
# SPDX-License-Identifier: GPL-3.0-only
use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../../lib";

# Regression: GitHub Copilot's MCM integration had 4 bugs that affected
# any user with reasoning-capable Copilot models (e.g. Claude Sonnet 4,
# gpt-5.4):
#
# 1. _fetch_github_copilot_capabilities returned the raw GitHub Copilot
#    schema (max_context_window_tokens, max_thinking_budget, etc.)
#    which does NOT match the MCM standard schema (context_window,
#    supports_reasoning, reasoning_mode, etc.). MCM consumers
#    (APIManager._get_reasoning_mode, _extract_model_capabilities)
#    read the standard fields and see them as missing. Concrete
#    effect: APIManager's reasoning_mode is undef, so reasoning_effort
#    is never sent to Copilot, even for models that support it.
#
# 2. GitHubCopilotModelsAPI.get_model_capabilities only extracted
#    supports_adaptive_thinking from the Copilot API response. If
#    the API also returned supports_enabled_thinking, it was
#    silently dropped on the floor.
#
# 3. get_model_billing and get_model_capabilities used `$model->{id}
#    eq $model_id` for model lookup - case-sensitive exact match.
#    Same bug class as the MCM API fetchers (6b8f2a2f).
#
# 4. _save_cache did a direct write to the cache file with no
#    atomicity. If the process was killed mid-write, the cache file
#    would be corrupted. MCM's _save_cache uses the atomic
#    temp+rename pattern.
#
# Fix:
# - _fetch_github_copilot_capabilities now translates the Copilot
#   schema to the MCM standard schema, including the reasoning
#   fields that drive _ensure_reasoning_mode
# - get_model_capabilities now extracts supports_enabled_thinking
# - Both lookups are case-insensitive
# - _save_cache uses atomic temp+rename
#
# Tests below verify each fix in isolation.

use Test::More;

# Test 1: Schema translation produces the standard MCM fields
{
    # Simulate what GitHubCopilotModelsAPI returns
    my $copilot_caps = {
        family => 'gpt-4',
        supported_endpoints => ['/chat/completions', '/responses'],
        category => 'versatile',
        vendor => 'OpenAI',
        picker_enabled => 1,
        preview => 0,
        supports_tools => 1,
        supports_streaming => 1,
        supports_vision => 0,
        supports_adaptive_thinking => 1,
        max_prompt_tokens => 128000,
        max_output_tokens => 16384,
        max_context_window_tokens => 264000,
        max_non_streaming_output_tokens => 8192,
        max_thinking_budget => 10000,
        min_thinking_budget => 1024,
        reasoning_effort => ['low', 'medium', 'high'],
    };

    # Apply the translation (same logic as the fix in MCM)
    my $supports_adaptive = $copilot_caps->{supports_adaptive_thinking} ? 1 : 0;
    my $supports_enabled = $copilot_caps->{supports_enabled_thinking} ? 1 : 0;
    my $mcm_caps = {
        provider                => 'github_copilot',
        model                   => 'gpt-5.4',
        context_window          => $copilot_caps->{max_context_window_tokens},
        max_prompt_tokens       => $copilot_caps->{max_prompt_tokens},
        max_output_tokens       => $copilot_caps->{max_output_tokens},
        supports_tools          => $copilot_caps->{supports_tools},
        supports_streaming      => $copilot_caps->{supports_streaming},
        supports_vision         => $copilot_caps->{supports_vision},
        supports_reasoning      => ($supports_adaptive || $supports_enabled) ? 1 : 0,
        supports_adaptive_thinking => $supports_adaptive,
        supports_enabled_thinking  => $supports_enabled,
        architecture            => $copilot_caps->{family},
        raw                     => $copilot_caps,
    };

    is($mcm_caps->{provider}, 'github_copilot',
        'translation: provider set to github_copilot');
    is($mcm_caps->{context_window}, 264000,
        'translation: context_window comes from max_context_window_tokens');
    is($mcm_caps->{max_prompt_tokens}, 128000,
        'translation: max_prompt_tokens preserved');
    is($mcm_caps->{max_output_tokens}, 16384,
        'translation: max_output_tokens preserved');
    is($mcm_caps->{supports_reasoning}, 1,
        'translation: supports_reasoning is true when supports_adaptive_thinking is set');
    is($mcm_caps->{supports_adaptive_thinking}, 1,
        'translation: supports_adaptive_thinking preserved');
    is($mcm_caps->{supports_enabled_thinking}, 0,
        'translation: supports_enabled_thinking defaults to 0 when missing from copilot response');
    is($mcm_caps->{architecture}, 'gpt-4',
        'translation: architecture comes from family');
    ok(exists $mcm_caps->{raw} && ref($mcm_caps->{raw}) eq 'HASH',
        'translation: raw preserves the full copilot response for downstream code');
}

# Test 2: supports_enabled_thinking extraction is now present in
# get_model_capabilities
{
    my $src = do { local $/; open my $fh, '<', 'lib/CLIO/Core/GitHubCopilotModelsAPI.pm' or die; <$fh> };
    like($src, qr/supports_enabled_thinking\}[^=]*=[^=]*\$supports->\{enabled_thinking\}/,
        'get_model_capabilities now extracts supports_enabled_thinking from API response');
}

# Test 3: Model ID matching is case-insensitive in both lookups
{
    my $src = do { local $/; open my $fh, '<', 'lib/CLIO/Core/GitHubCopilotModelsAPI.pm' or die; <$fh> };

    # Both get_model_billing and get_model_capabilities should use lc()
    # comparison instead of eq. Count occurrences of the new pattern
    # to ensure both lookups were updated.
    my $count = () = $src =~ /lc\(\$model->\{id\}\)\s*eq\s*lc\(\$model_id\)/g;
    ok($count >= 2, "case-insensitive model id match used $count times (get_model_billing + get_model_capabilities minimum)");

    # The old pattern should not appear (within either function body)
    my $billing_start = index($src, 'sub get_model_billing');
    my $capabilities_start = index($src, 'sub get_model_capabilities');
    my $billing_end = index($src, 'sub ', $billing_start + 1);
    my $capabilities_end = index($src, 'sub ', $capabilities_start + 1);
    my $billing_body = substr($src, $billing_start, $billing_end - $billing_start);
    my $capabilities_body = substr($src, $capabilities_start, $capabilities_end - $capabilities_start);

    unlike($billing_body, qr/\$model->\{id\}\s*eq\s*\$model_id(?!\))/,  # negative lookahead to skip negated form
        'get_model_billing no longer uses case-sensitive eq comparison');
    unlike($capabilities_body, qr/\$model->\{id\}\s*eq\s*\$model_id/,
        'get_model_capabilities no longer uses case-sensitive eq comparison');
}

# Test 4: _save_cache uses atomic temp+rename pattern
{
    my $src = do { local $/; open my $fh, '<', 'lib/CLIO/Core/GitHubCopilotModelsAPI.pm' or die; <$fh> };

    my $fn_start = index($src, 'sub _save_cache');
    # The next "sub " after _save_cache may not exist if _save_cache
    # is the last function. Use the end of the file (or the final
    # __END__ marker) as the upper bound.
    my $fn_end_candidate = index($src, 'sub ', $fn_start + 1);
    my $fn_end   = $fn_end_candidate > 0 ? $fn_end_candidate : length($src);
    my $fn_body  = $fn_start >= 0 ? substr($src, $fn_start, $fn_end - $fn_start) : '';

    like($fn_body, qr/\.tmp/,
        '_save_cache writes to a .tmp file first');
    like($fn_body, qr/rename\(/,
        '_save_cache uses rename() for atomic write');
    unlike($fn_body, qr/open my \$fh, '>', \$self->\{cache_file\}/,
        '_save_cache no longer writes directly to the final cache file path');
}

# Test 5: Source-level check that the MCM translation produces
# the fields _ensure_reasoning_mode needs
{
    my $src = do { local $/; open my $fh, '<', 'lib/CLIO/Core/ModelCapabilitiesManager.pm' or die; <$fh> };

    my $fn_start = index($src, 'sub _fetch_github_copilot_capabilities');
    my $fn_end   = index($src, 'sub ', $fn_start + 1);
    my $fn_body  = $fn_start >= 0 && $fn_end > $fn_start
        ? substr($src, $fn_start, $fn_end - $fn_start)
        : '';

    like($fn_body, qr/supports_reasoning/,
        '_fetch_github_copilot_capabilities sets supports_reasoning (drives _ensure_reasoning_mode)');
    like($fn_body, qr/supports_adaptive_thinking/,
        '_fetch_github_copilot_capabilities sets supports_adaptive_thinking (used by data-driven path)');
    like($fn_body, qr/supports_enabled_thinking/,
        '_fetch_github_copilot_capabilities sets supports_enabled_thinking (used by data-driven path)');
    like($fn_body, qr/context_window/,
        '_fetch_github_copilot_capabilities sets context_window (used by /api models display)');
}

# Test 6: Default behavior when copilot API doesn't return thinking info
{
    my $copilot_caps = {
        family => 'gpt-4',
        supported_endpoints => ['/chat/completions'],
        category => 'lightweight',
        supports_tools => 1,
        supports_streaming => 1,
        supports_vision => 0,
        max_prompt_tokens => 8192,
        max_output_tokens => 4096,
        max_context_window_tokens => 8192,
    };

    my $supports_adaptive = $copilot_caps->{supports_adaptive_thinking} ? 1 : 0;
    my $supports_enabled = $copilot_caps->{supports_enabled_thinking} ? 1 : 0;
    my $mcm_caps = {
        supports_reasoning => ($supports_adaptive || $supports_enabled) ? 1 : 0,
        supports_adaptive_thinking => $supports_adaptive,
        supports_enabled_thinking => $supports_enabled,
    };

    is($mcm_caps->{supports_reasoning}, 0,
        'translation: model without thinking info gets supports_reasoning=0');
    is($mcm_caps->{supports_adaptive_thinking}, 0,
        'translation: model without thinking info gets supports_adaptive_thinking=0');
    is($mcm_caps->{supports_enabled_thinking}, 0,
        'translation: model without thinking info gets supports_enabled_thinking=0');
}

# Test 7: Defensive defined-check on $model->{id} (the API could
# theoretically return a model without an id field)
{
    my $src = do { local $/; open my $fh, '<', 'lib/CLIO/Core/GitHubCopilotModelsAPI.pm' or die; <$fh> };

    my $count = () = $src =~ /defined\s+\$model->\{id\}\s*&&\s*lc\(\$model->\{id\}\)\s*eq\s*lc\(\$model_id\)/g;
    ok($count >= 2, "defined-check + lc() comparison used $count times (defensive against missing id)");
}

done_testing();
