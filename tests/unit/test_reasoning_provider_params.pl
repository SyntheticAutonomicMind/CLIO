#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# Regression test for reasoning parameter injection across all providers.
# Uses the data-driven reasoning_schema from provider-defaults.json
# (propagated via build_endpoint_config) to verify that each provider
# receives the correct param format and value mapping.

use strict;
use warnings;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use Test::More tests => 46;

use CLIO::Core::APIManager;
use CLIO::Providers qw(build_endpoint_config);

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
# adapt_request_for_endpoint / _inject_reasoning_params touch.
my $am = bless {
    debug => 0,
    config => undef,
    api_base => 'https://example.com/v1/chat/completions',
}, 'CLIO::Core::APIManager';

# Stub _get_reasoning_mode to return the correct mode per model family.
# This mirrors what ModelCapabilitiesManager would return from
# provider-defaults.json / models.json.
no warnings 'redefine';
*CLIO::Core::APIManager::_get_reasoning_mode = sub {
    my ($self, $model) = @_;
    return 'adaptive' if $model && $model =~ /M3/i;
    return 'enabled'  if $model && $model =~ /M2/i;
    # Z.AI and most others: 'effort' (OpenAI-style reasoning_effort)
    return 'effort';
};

# Stub _model_supports_reasoning to return 1 for OpenRouter nested mode.
*CLIO::Core::APIManager::_model_supports_reasoning = sub { 1 };

sub _run_adapt {
    my (%args) = @_;
    my $endpoint_config = build_endpoint_config($args{provider}, 'test-key');
    # Allow test overrides on top of the schema
    if ($args{overrides}) {
        for my $k (keys %{$args{overrides}}) {
            $endpoint_config->{$k} = $args{overrides}{$k};
        }
    }
    my $payload = $args{payload};
    $am->{config} = FakeConfig->new(
        thinking_effort => $args{effort},
        show_thinking   => $args{show_thinking} // 1,
        thinking_mode   => $args{thinking_mode},
    );
    $am->adapt_request_for_endpoint($payload, $endpoint_config);
    return ($payload, $endpoint_config);
}

# ============================================================
# OpenRouter: reasoning.{enabled, effort}
# ============================================================
#
# OpenRouter uses a nested reasoning object with enabled + effort.
# Both free and paid model variants support it, whereas max_tokens
# only works on some upstream providers.

# Case 1: OpenRouter + high effort -> enabled=true, effort=high
{
    my $payload = { model => 'openrouter/anthropic/claude-3.7-sonnet', messages => [] };
    my ($p) = _run_adapt(
        provider => 'openrouter',
        payload => $payload,
        thinking_mode => 'enabled',
        effort => 'high',
    );
    is($p->{reasoning}{effort}, 'high',
        'OpenRouter+high: reasoning.effort is high');
    ok(defined $p->{reasoning}{enabled} && ${$p->{reasoning}{enabled}} == 1,
        'OpenRouter+high: reasoning.enabled is true');
    ok(!exists $p->{reasoning}{max_tokens},
        'OpenRouter+high: NO max_tokens (portable effort only)');
}

# Case 2: OpenRouter + low -> effort=low
{
    my $payload = { model => 'openrouter/anthropic/claude-3.7-sonnet', messages => [] };
    my ($p) = _run_adapt(provider => 'openrouter', payload => $payload, thinking_mode => 'enabled', effort => 'low');
    is($p->{reasoning}{effort}, 'low', 'OpenRouter+low: reasoning.effort is low');
}

# Case 3: OpenRouter + medium -> effort=medium
{
    my $payload = { model => 'openrouter/anthropic/claude-3.7-sonnet', messages => [] };
    my ($p) = _run_adapt(provider => 'openrouter', payload => $payload, thinking_mode => 'enabled', effort => 'medium');
    is($p->{reasoning}{effort}, 'medium', 'OpenRouter+medium: reasoning.effort is medium');
}

# Case 4: OpenRouter + effort undef defaults to medium
{
    my $payload = { model => 'openrouter/anthropic/claude-3.7-sonnet', messages => [] };
    my ($p) = _run_adapt(provider => 'openrouter', payload => $payload, thinking_mode => 'enabled', effort => undef);
    is($p->{reasoning}{effort}, 'medium', 'OpenRouter+effort undef: defaults to medium');
}

# Case 5: OpenRouter + unknown effort falls back to high
{
    my $payload = { model => 'openrouter/anthropic/claude-3.7-sonnet', messages => [] };
    my ($p) = _run_adapt(provider => 'openrouter', payload => $payload, thinking_mode => 'enabled', effort => 'turbo');
    is($p->{reasoning}{effort}, 'high', 'OpenRouter+unknown effort: falls back to high');
}

# Case 6: OpenRouter + thinking_mode=disabled -> no reasoning param
{
    my $payload = { model => 'openrouter/anthropic/claude-3.7-sonnet', messages => [] };
    my ($p) = _run_adapt(provider => 'openrouter', payload => $payload, thinking_mode => 'disabled', effort => 'high');
    ok(!exists $p->{reasoning}, 'OpenRouter+disabled: no reasoning param sent');
}

# Case 7: OpenRouter + effort "max" (o-series parity) passes through
{
    my $payload = { model => 'openrouter/openai/o1', messages => [] };
    my ($p) = _run_adapt(provider => 'openrouter', payload => $payload, thinking_mode => 'enabled', effort => 'max');
    is($p->{reasoning}{effort}, 'max', 'OpenRouter+max: effort passes through verbatim');
    ok(!exists $p->{reasoning}{max_tokens}, 'OpenRouter+max: NO max_tokens');
}

# ============================================================
# Z.AI: thinking.type + reasoning_effort
# ============================================================

# Case 8: Z.AI + high effort -> thinking.type=enabled, reasoning_effort=high
{
    my $payload = { model => 'glm-5.2', messages => [] };
    my ($p) = _run_adapt(provider => 'zai', payload => $payload, thinking_mode => 'enabled', effort => 'high');
    is($p->{thinking}{type}, 'enabled', 'Z.AI+high: thinking.type is enabled');
    is($p->{reasoning_effort}, 'high', 'Z.AI+high: reasoning_effort is high');
}

# Case 9: Z.AI + xhigh -> mapped to Z.AI's max
{
    my $payload = { model => 'glm-5.2', messages => [] };
    my ($p) = _run_adapt(provider => 'zai', payload => $payload, thinking_mode => 'enabled', effort => 'xhigh');
    is($p->{reasoning_effort}, 'max', 'Z.AI+xhigh: reasoning_effort maps to Z.AI max');
}

# Case 10: Z.AI + low -> reasoning_effort=low
{
    my $payload = { model => 'glm-5.2', messages => [] };
    my ($p) = _run_adapt(provider => 'zai', payload => $payload, thinking_mode => 'enabled', effort => 'low');
    is($p->{reasoning_effort}, 'low', 'Z.AI+low: reasoning_effort is low');
}

# Case 11: Z.AI + medium -> reasoning_effort=medium
{
    my $payload = { model => 'glm-5.2', messages => [] };
    my ($p) = _run_adapt(provider => 'zai', payload => $payload, thinking_mode => 'enabled', effort => 'medium');
    is($p->{reasoning_effort}, 'medium', 'Z.AI+medium: reasoning_effort is medium');
}

# Case 12: Z.AI + effort undef defaults to high
{
    my $payload = { model => 'glm-5.2', messages => [] };
    my ($p) = _run_adapt(provider => 'zai', payload => $payload, thinking_mode => 'enabled', effort => undef);
    is($p->{reasoning_effort}, 'high', 'Z.AI+effort undef: defaults to high');
}

# Case 13: Z.AI + unknown effort falls back to high
{
    my $payload = { model => 'glm-5.2', messages => [] };
    my ($p) = _run_adapt(provider => 'zai', payload => $payload, thinking_mode => 'enabled', effort => 'turbo');
    is($p->{reasoning_effort}, 'high', 'Z.AI+unknown effort: falls back to high');
}

# Case 14: Z.AI + thinking_mode=disabled -> NO thinking param at all
{
    my $payload = { model => 'glm-5.2', messages => [] };
    my ($p) = _run_adapt(provider => 'zai', payload => $payload, thinking_mode => 'disabled', effort => 'high');
    ok(!exists $p->{thinking}, 'Z.AI+disabled: no thinking payload (param omitted)');
    ok(!exists $p->{reasoning_effort}, 'Z.AI+disabled: no reasoning_effort sent');
}

# ============================================================
# OpenAI-compat (effort mode): reasoning_effort only
# ============================================================

# Case 15: OpenAI + high -> reasoning_effort=high, no thinking
{
    my $payload = { model => 'gpt-5', messages => [], max_tokens => 4096 };
    my ($p) = _run_adapt(provider => 'openai', payload => $payload, thinking_mode => 'enabled', effort => 'high');
    is($p->{reasoning_effort}, 'high', 'OpenAI: reasoning_effort preserved');
    ok(!exists $p->{thinking}, 'OpenAI: no thinking payload');
    ok(!exists $p->{budget_tokens}, 'OpenAI: no budget_tokens leaked');
}

# Case 16: OpenAI + unknown effort -> defaults to medium (not in Z.AI enum)
{
    my $payload = { model => 'gpt-5', messages => [] };
    my ($p) = _run_adapt(provider => 'openai', payload => $payload, thinking_mode => 'enabled', effort => 'turbo');
    is($p->{reasoning_effort}, 'medium', 'OpenAI+unknown effort: defaults to medium');
}

# Case 17: DeepSeek + stream_options deleted
{
    my $payload = { model => 'deepseek-v4-pro', messages => [], stream_options => { include_usage => \1 } };
    my ($p, $cfg) = _run_adapt(provider => 'deepseek', payload => $payload, thinking_mode => 'enabled', effort => 'high');
    ok(!exists $p->{stream_options}, 'DeepSeek: stream_options deleted');
    is($p->{reasoning_effort}, 'high', 'DeepSeek: reasoning_effort sent');
}

# Case 18: NVIDIA + reasoning_effort
{
    my $payload = { model => 'nvidia/nemotron-3-ultra-550b-a55b', messages => [] };
    my ($p) = _run_adapt(provider => 'nvidia', payload => $payload, thinking_mode => 'enabled', effort => 'medium');
    is($p->{reasoning_effort}, 'medium', 'NVIDIA: reasoning_effort sent');
}

# ============================================================
# Local inference: must never receive reasoning params
# ============================================================

# Case 19: llama.cpp + max_tokens present -> must NOT get reasoning_effort
{
    my $payload = { model => 'deepseek-r1', messages => [], max_tokens => 4096 };
    my ($p, $cfg) = _run_adapt(provider => 'llama.cpp', payload => $payload, thinking_mode => 'enabled', effort => 'high');
    ok(!exists $p->{reasoning_effort}, 'llama.cpp: NO reasoning_effort (requires_no_reasoning)');
    ok(exists $p->{max_tokens}, 'llama.cpp: max_tokens preserved (not renamed)');
}

# Case 20: llama.cpp + MiniMax mode (adaptive model) -> NO thinking params
{
    my $payload = { model => 'MiniMax-M3', messages => [] };
    my ($p, $cfg) = _run_adapt(provider => 'llama.cpp', payload => $payload, thinking_mode => 'enabled', effort => 'high');
    ok(!exists $p->{reasoning_effort}, 'llama.cpp: NO reasoning_effort for MiniMax-style model');
    ok(!exists $p->{thinking}, 'llama.cpp: NO thinking params');
}

# Case 21: LM Studio -> NO reasoning params
{
    my $payload = { model => 'deepseek-r1', messages => [], max_tokens => 2048 };
    my ($p, $cfg) = _run_adapt(provider => 'lmstudio', payload => $payload, thinking_mode => 'enabled', effort => 'high');
    ok(!exists $p->{reasoning_effort}, 'LM Studio: NO reasoning params');
    ok(!exists $p->{thinking}, 'LM Studio: NO thinking params');
}

# Case 22: Ollama Cloud -> NO reasoning params
{
    my $payload = { model => 'gemma4:31b', messages => [], max_tokens => 2048 };
    my ($p, $cfg) = _run_adapt(provider => 'ollama_cloud', payload => $payload, thinking_mode => 'enabled', effort => 'high');
    ok(!exists $p->{reasoning_effort}, 'Ollama Cloud: NO reasoning params');
    ok(!exists $p->{thinking}, 'Ollama Cloud: NO thinking params');
}

# Case 23: SAM -> NO reasoning params
{
    my $payload = { model => 'local-model', messages => [], max_tokens => 2048 };
    my ($p, $cfg) = _run_adapt(provider => 'sam', payload => $payload, thinking_mode => 'enabled', effort => 'high');
    ok(!exists $p->{reasoning_effort}, 'SAM: NO reasoning params');
    ok(!exists $p->{thinking}, 'SAM: NO thinking params');
}

# Case 24: Z.AI + minimal/none pass through verbatim
{
    my $payload = { model => 'glm-5.2', messages => [] };
    my ($p) = _run_adapt(provider => 'zai', payload => $payload, thinking_mode => 'enabled', effort => 'minimal');
    is($p->{reasoning_effort}, 'minimal', 'Z.AI+minimal: reasoning_effort passes through verbatim');

    my $payload2 = { model => 'glm-5.2', messages => [] };
    my ($p2) = _run_adapt(provider => 'zai', payload => $payload2, thinking_mode => 'enabled', effort => 'none');
    is($p2->{reasoning_effort}, 'none', 'Z.AI+none: reasoning_effort passes through verbatim');
}

# Case 25: MiniMax M3 -> think_object with adaptive type + budget
{
    my $payload = { model => 'MiniMax-M3', messages => [], max_tokens => 8192 };
    my ($p, $cfg) = _run_adapt(provider => 'minimax', payload => $payload, thinking_mode => 'enabled', effort => 'high');
    is($p->{thinking}{type}, 'adaptive', 'MiniMax M3: thinking.type is adaptive');
    ok(!exists $p->{thinking}{budget_tokens},
        'MiniMax M3: no budget_tokens (model decides depth in adaptive mode)');
    is($p->{max_completion_tokens}, 8192, 'MiniMax M3: max_tokens renamed to max_completion_tokens');
    ok(exists $p->{reasoning_split}, 'MiniMax M3: reasoning_split sent');
}

# Case 26: MiniMax M2.x -> think_object with enabled type
{
    my $payload = { model => 'MiniMax-M2.7', messages => [] };
    my ($p) = _run_adapt(provider => 'minimax', payload => $payload, thinking_mode => 'enabled', effort => 'medium');
    is($p->{thinking}{type}, 'enabled', 'MiniMax M2.x: thinking.type is enabled');
    ok(!exists $p->{thinking}{budget_tokens},
        'MiniMax M2.x: no budget_tokens (model decides depth)');
}

# Case 27: MiniMax + thinking_mode=disabled -> type=disabled
{
    my $payload = { model => 'MiniMax-M3', messages => [] };
    my ($p) = _run_adapt(provider => 'minimax', payload => $payload, thinking_mode => 'disabled', effort => 'high');
    is($p->{thinking}{type}, 'disabled', 'MiniMax+disabled: thinking.type is disabled');
}

# Case 28: MiniMax + thinking_mode=auto + show_thinking=0 -> type=disabled
{
    my $payload = { model => 'MiniMax-M3', messages => [] };
    my ($p) = _run_adapt(provider => 'minimax', payload => $payload, thinking_mode => 'auto', effort => 'high', show_thinking => 0);
    is($p->{thinking}{type}, 'disabled', 'MiniMax+auto/off: thinking.type is disabled');
}