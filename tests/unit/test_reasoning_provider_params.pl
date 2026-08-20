#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# Regression test for OpenRouter reasoning.max_tokens and Z.AI
# reasoning_effort payload shape.
#
# Without max_tokens, OpenRouter models emit brief planning one-liners
# ("Planning X", "Locating Y") instead of full reasoning. Z.AI's
# reasoning_effort controls the depth of thinking on GLM-5.2+ models;
# without it the model defaults to "max" but we want users to control
# effort from the same thinking_effort config as other providers.

use strict;
use warnings;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use Test::More tests => 28;

use CLIO::Core::APIManager;

# Fake Config object that exposes the keys adapt_request_for_endpoint reads.
package FakeConfig {
    sub new {
        my ($cls, %opts) = @_;
        return bless { %opts }, $cls;
    }
    sub get {
        my ($self, $key) = @_;
        return $self->{$key};
    }
}

package main;

# Bare-bones APIManager that bypasses new() and only seeds the fields
# adapt_request_for_endpoint touches.
my $am = bless {
    debug => 0,
    api_base => 'https://api.openrouter.ai/api/v1/chat/completions',
}, 'CLIO::Core::APIManager';

# Stub model-supports-reasoning to always return true so we exercise the
# send path (not the gate).
no warnings 'redefine';
*CLIO::Core::APIManager::_model_supports_reasoning = sub { 1 };

sub _run_adapt {
    my (%args) = @_;
    my $payload = $args{payload};
    my $endpoint_config = $args{endpoint_config};
    $am->{config} = FakeConfig->new(
        thinking_effort => $args{effort},
        show_thinking => $args{show_thinking} // 1,
        thinking_mode => $args{thinking_mode},
    );
    $am->adapt_request_for_endpoint($payload, $endpoint_config);
    return $payload;
}

# ============================================================
# OpenRouter: reasoning.{enabled, effort}
# ============================================================
#
# OpenRouter's reasoning.max_tokens only works on some upstream providers
# (e.g. Together) and fails on others (e.g. Nvidia free tier). The
# portable approach is to use reasoning.effort which works across all
# upstream providers. Both free and paid model variants support effort.

sub _openrouter_cfg {
    return {
        openrouter => 1,
        native_thinking_format => 1,
        supports_reasoning => 1,
        sampling_defaults => { temperature => 1.0 },
    };
}

# Case 1: OpenRouter + high effort -> enabled, effort=high
{
    my $payload = { model => 'openrouter/anthropic/claude-3.7-sonnet', messages => [] };
    _run_adapt(
        payload => $payload,
        endpoint_config => _openrouter_cfg(),
        thinking_mode => 'enabled',
        effort => 'high',
    );
    my $enabled_ref = $payload->{reasoning}{enabled};
    is($$enabled_ref, 1,
        'OpenRouter+high: reasoning.enabled is true');
    is($payload->{reasoning}{effort}, 'high',
        'OpenRouter+high: reasoning.effort is high');
    ok(!exists $payload->{reasoning}{max_tokens},
        'OpenRouter+high: NO max_tokens (portable effort only)');
}

# Case 2: OpenRouter + low -> effort=low
{
    my $payload = { model => 'openrouter/anthropic/claude-3.7-sonnet', messages => [] };
    _run_adapt(
        payload => $payload,
        endpoint_config => _openrouter_cfg(),
        thinking_mode => 'enabled',
        effort => 'low',
    );
    is($payload->{reasoning}{effort}, 'low',
        'OpenRouter+low: reasoning.effort is low');
    ok(!exists $payload->{reasoning}{max_tokens},
        'OpenRouter+low: NO max_tokens');
}

# Case 3: OpenRouter + medium -> effort=medium
{
    my $payload = { model => 'openrouter/anthropic/claude-3.7-sonnet', messages => [] };
    _run_adapt(
        payload => $payload,
        endpoint_config => _openrouter_cfg(),
        thinking_mode => 'enabled',
        effort => 'medium',
    );
    is($payload->{reasoning}{effort}, 'medium',
        'OpenRouter+medium: reasoning.effort is medium');
    ok(!exists $payload->{reasoning}{max_tokens},
        'OpenRouter+medium: NO max_tokens');
}

# Case 4: OpenRouter + effort undef defaults to medium
{
    my $payload = { model => 'openrouter/anthropic/claude-3.7-sonnet', messages => [] };
    _run_adapt(
        payload => $payload,
        endpoint_config => _openrouter_cfg(),
        thinking_mode => 'enabled',
        effort => undef,
    );
    is($payload->{reasoning}{effort}, 'medium',
        'OpenRouter+effort undef: defaults to medium effort');
    ok(!exists $payload->{reasoning}{max_tokens},
        'OpenRouter+effort undef: NO max_tokens');
}

# Case 5: OpenRouter + unknown effort falls back to high
{
    my $payload = { model => 'openrouter/anthropic/claude-3.7-sonnet', messages => [] };
    _run_adapt(
        payload => $payload,
        endpoint_config => _openrouter_cfg(),
        thinking_mode => 'enabled',
        effort => 'turbo',
    );
    is($payload->{reasoning}{effort}, 'high',
        'OpenRouter+unknown effort: falls back to high effort');
    ok(!exists $payload->{reasoning}{max_tokens},
        'OpenRouter+unknown effort: NO max_tokens');
}

# Case 6: OpenRouter + thinking_mode=disabled -> no reasoning param
{
    my $payload = { model => 'openrouter/anthropic/claude-3.7-sonnet', messages => [] };
    _run_adapt(
        payload => $payload,
        endpoint_config => _openrouter_cfg(),
        thinking_mode => 'disabled',
        effort => 'high',
    );
    ok(!exists $payload->{reasoning},
        'OpenRouter+disabled: no reasoning param sent');
}

# ============================================================
# Z.AI: thinking.type + reasoning_effort
# ============================================================

sub _zai_cfg {
    return {
        zai => 1,
        native_thinking_format => 1,
        supports_reasoning => 1,
        sampling_defaults => { temperature => 1.0 },
    };
}

# Stub _get_reasoning_mode to return 'enabled' (M2.x-style) so the
# send_thinking gate passes.
*CLIO::Core::APIManager::_get_reasoning_mode = sub { 'enabled' };

# Case 7: Z.AI + high effort -> thinking.type=enabled, reasoning_effort=high
{
    my $payload = { model => 'glm-5.2', messages => [] };
    _run_adapt(
        payload => $payload,
        endpoint_config => _zai_cfg(),
        thinking_mode => 'enabled',
        effort => 'high',
    );
    is_deeply($payload->{thinking}, { type => 'enabled' },
        'Z.AI+high: thinking.type is enabled');
    is($payload->{reasoning_effort}, 'high',
        'Z.AI+high: reasoning_effort is high');
}

# Case 8: Z.AI + xhigh -> mapped to Z.AI's max
{
    my $payload = { model => 'glm-5.2', messages => [] };
    _run_adapt(
        payload => $payload,
        endpoint_config => _zai_cfg(),
        thinking_mode => 'enabled',
        effort => 'xhigh',
    );
    is($payload->{reasoning_effort}, 'max',
        'Z.AI+xhigh: reasoning_effort maps to Z.AI max');
}

# Case 9: Z.AI + low -> reasoning_effort=low
{
    my $payload = { model => 'glm-5.2', messages => [] };
    _run_adapt(
        payload => $payload,
        endpoint_config => _zai_cfg(),
        thinking_mode => 'enabled',
        effort => 'low',
    );
    is($payload->{reasoning_effort}, 'low',
        'Z.AI+low: reasoning_effort is low');
}

# Case 10: Z.AI + medium -> reasoning_effort=medium
{
    my $payload = { model => 'glm-5.2', messages => [] };
    _run_adapt(
        payload => $payload,
        endpoint_config => _zai_cfg(),
        thinking_mode => 'enabled',
        effort => 'medium',
    );
    is($payload->{reasoning_effort}, 'medium',
        'Z.AI+medium: reasoning_effort is medium');
}

# Case 11: Z.AI + effort undef defaults to high
{
    my $payload = { model => 'glm-5.2', messages => [] };
    _run_adapt(
        payload => $payload,
        endpoint_config => _zai_cfg(),
        thinking_mode => 'enabled',
        effort => undef,
    );
    is($payload->{reasoning_effort}, 'high',
        'Z.AI+effort undef: defaults to high');
}

# Case 12: Z.AI + unknown effort falls back to high
{
    my $payload = { model => 'glm-5.2', messages => [] };
    _run_adapt(
        payload => $payload,
        endpoint_config => _zai_cfg(),
        thinking_mode => 'enabled',
        effort => 'turbo',
    );
    is($payload->{reasoning_effort}, 'high',
        'Z.AI+unknown effort: falls back to high');
}

# Case 13: Z.AI + thinking_mode=disabled -> NO thinking param at all
# (Z.AI has no {type:disabled} - the only way to opt out is to omit the
# param entirely; Z.AI then defaults to its own internal thinking mode).
{
    my $payload = { model => 'glm-5.2', messages => [] };
    _run_adapt(
        payload => $payload,
        endpoint_config => _zai_cfg(),
        thinking_mode => 'disabled',
        effort => 'high',
    );
    ok(!exists $payload->{thinking},
        'Z.AI+disabled: no thinking payload (param omitted to disable)');
    ok(!exists $payload->{reasoning_effort},
        'Z.AI+disabled: no reasoning_effort sent');
}

# ============================================================
# Sanity: existing providers' payload shape is unchanged
# ============================================================

# Case 14: OpenAI-compat (no native_thinking_format) still sends
# reasoning_effort, not budget_tokens. Verify budget_tokens is NOT
# introduced to OpenAI-compat paths (that would 400 the request).
{
    my $payload = { model => 'gpt-5', messages => [] };
    _run_adapt(
        payload => $payload,
        endpoint_config => {
            openai => 1,
            supports_reasoning => 1,
        },
        thinking_mode => 'enabled',
        effort => 'high',
    );
    is($payload->{reasoning_effort}, 'high',
        'OpenAI-compat: reasoning_effort preserved');
    ok(!exists $payload->{thinking},
        'OpenAI-compat: no thinking payload (correct - this provider uses reasoning_effort)');
    ok(!exists $payload->{budget_tokens},
        'OpenAI-compat: no budget_tokens leaked (that field is MiniMax/OpenRouter/Z.AI only)');
}

# Case 15: Z.AI thinking_mode=enabled also passes through thinking_effort
# values that ARE in Z.AI's enum (none, minimal) for completeness
{
    my $payload = { model => 'glm-5.2', messages => [] };
    _run_adapt(
        payload => $payload,
        endpoint_config => _zai_cfg(),
        thinking_mode => 'enabled',
        effort => 'minimal',
    );
    is($payload->{reasoning_effort}, 'minimal',
        'Z.AI+minimal: reasoning_effort passes through verbatim');
}

{
    my $payload = { model => 'glm-5.2', messages => [] };
    _run_adapt(
        payload => $payload,
        endpoint_config => _zai_cfg(),
        thinking_mode => 'enabled',
        effort => 'none',
    );
    is($payload->{reasoning_effort}, 'none',
        'Z.AI+none: reasoning_effort passes through verbatim');
}

# Case 16: OpenRouter effort "max" (OpenAI/o-series parity) passes through
{
    my $payload = { model => 'openrouter/openai/o1', messages => [] };
    _run_adapt(
        payload => $payload,
        endpoint_config => _openrouter_cfg(),
        thinking_mode => 'enabled',
        effort => 'max',
    );
    is($payload->{reasoning}{effort}, 'max',
        'OpenRouter+max: effort passes through verbatim');
    ok(!exists $payload->{reasoning}{max_tokens},
        'OpenRouter+max: NO max_tokens');
}
