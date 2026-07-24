#!/usr/bin/env perl

# Tests for reasoning_effort propagation to OpenAI and GitHub Copilot
# /chat/completions endpoints. The /responses path is already covered by
# test_reasoning_round_trip.pl, so this focuses on the OpenAI-compatible
# path in adapt_request_for_endpoint.
#
# Covers:
#   - OpenAI o-series gets reasoning_effort when show_thinking is on
#   - OpenAI gpt-5+ gets reasoning_effort when show_thinking is on
#   - OpenAI non-reasoning models (gpt-4.1, gpt-4o) do NOT get reasoning_effort
#   - GitHub Copilot Claude 4 family gets reasoning_effort when show_thinking is on
#   - GitHub Copilot o-series and gpt-5+ get reasoning_effort
#   - GitHub Copilot non-reasoning models do NOT get reasoning_effort
#   - When show_thinking is off, no reasoning_effort is added
#   - thinking_effort config (low/medium/high) flows through to the param
#   - OpenRouter path is unaffected (no reasoning_effort key sent)
#   - ollama_cloud no longer has supports_reasoning in endpoint config
#   - openai + github_copilot providers report supports_reasoning=1

use strict;
use warnings;
use lib './lib';
use Test::More;
use JSON::PP qw(encode_json decode_json);

use_ok('CLIO::Providers');
use_ok('CLIO::Core::APIManager');
use_ok('CLIO::Core::Config');

# Build a fake APIManager with controllable config. We only need
# adapt_request_for_endpoint so we don't initialize the heavy machinery.
sub _make_mgr {
    my (%args) = @_;
    my $config = $args{config} || CLIO::Core::Config->new();
    $config->set('show_thinking', $args{show_thinking} // 0);
    $config->set('thinking_effort', $args{thinking_effort} // 'medium');
    my $mgr = CLIO::Core::APIManager->new(
        provider => 'openai',
        model    => 'gpt-4.1',
        config   => $config,
    );
    # Pre-populate model capabilities cache. _get_reasoning_mode calls
    # get_model_capabilities(), which without an internet-reachable api_base
    # for the test provider falls through to a 30s HTTP fetch that times out
    # and returns undef. Tests inject the caps they need instead of waiting
    # for the network probe.
    if ($args{cached_caps}) {
        $mgr->{_model_capabilities_cache} = { %{$args{cached_caps}} };
    }
    return $mgr;
}

# 1. OpenAI: o-series gets reasoning_effort when thinking is on
{
    my $mgr = _make_mgr(show_thinking => 1, thinking_effort => 'high');
    $mgr->{_model_capabilities_cache} ||= {};
    $mgr->{_model_capabilities_cache}{'o3-mini'} = { supports_reasoning => 1, reasoning_mode => 'effort' };
    my $payload = { model => 'o3-mini', messages => [] };
    my $ec = CLIO::Providers::build_endpoint_config('openai', 'sk-test');
    my $result = $mgr->adapt_request_for_endpoint($payload, $ec);

    is($result->{reasoning_effort}, 'high', 'OpenAI o3-mini gets reasoning_effort=high');
    ok(!exists $result->{reasoning}, 'OpenAI o3-mini does NOT get OpenRouter-style reasoning key');
}

# 2. OpenAI: gpt-5+ gets reasoning_effort
{
    my $mgr = _make_mgr(show_thinking => 1, thinking_effort => 'low');
    $mgr->{_model_capabilities_cache} ||= {};
    $mgr->{_model_capabilities_cache}{'gpt-5'} = { supports_reasoning => 1, reasoning_mode => 'effort' };
    my $payload = { model => 'gpt-5', messages => [] };
    my $ec = CLIO::Providers::build_endpoint_config('openai', 'sk-test');
    my $result = $mgr->adapt_request_for_endpoint($payload, $ec);

    is($result->{reasoning_effort}, 'low', 'OpenAI gpt-5 gets reasoning_effort=low');
}

# 3. OpenAI: non-reasoning models do NOT get reasoning_effort
{
    for my $model (qw(gpt-4.1 gpt-4o gpt-4-turbo gpt-3.5-turbo)) {
        my $mgr = _make_mgr(show_thinking => 1, thinking_effort => 'high');
        # Preload supports_reasoning=0 so the caps lookup short-circuits
        # without falling through to a slow HTTP fetch of an unreachable
        # api_base. _get_reasoning_mode() returns undef for these models.
        $mgr->{_model_capabilities_cache} ||= {};
        $mgr->{_model_capabilities_cache}{$model} = { supports_reasoning => 0 };
        my $payload = { model => $model, messages => [] };
        my $ec = CLIO::Providers::build_endpoint_config('openai', 'sk-test');
        my $result = $mgr->adapt_request_for_endpoint($payload, $ec);

        ok(!exists $result->{reasoning_effort}, "OpenAI $model does NOT get reasoning_effort");
    }
}

# 4. OpenAI: show_thinking off - no reasoning_effort even on o-series
{
    my $mgr = _make_mgr(show_thinking => 0, thinking_effort => 'high');
    # Caps preloaded so reasoning_mode resolves. show_thinking=0 should
    # still keep reasoning_effort off; this confirms the gate works.
    $mgr->{_model_capabilities_cache} ||= {};
    $mgr->{_model_capabilities_cache}{'o1-preview'} = { supports_reasoning => 1, reasoning_mode => 'effort' };
    my $payload = { model => 'o1-preview', messages => [] };
    my $ec = CLIO::Providers::build_endpoint_config('openai', 'sk-test');
    my $result = $mgr->adapt_request_for_endpoint($payload, $ec);

    ok(!exists $result->{reasoning_effort}, 'OpenAI o1-preview: no reasoning_effort when show_thinking=0');
}

# 5. GitHub Copilot: Claude 4 family gets reasoning_effort
{
    for my $model (qw(
        claude-sonnet-4
        claude-sonnet-4.5
        claude-opus-4
        claude-opus-4.5
        claude-haiku-4.5
        claude-sonnet-4-20250514
    )) {
        my $mgr = _make_mgr(show_thinking => 1, thinking_effort => 'medium');
        $mgr->{_model_capabilities_cache} ||= {};
        $mgr->{_model_capabilities_cache}{$model} = { supports_reasoning => 1, reasoning_mode => 'effort' };
        my $payload = { model => $model, messages => [] };
        my $ec = CLIO::Providers::build_endpoint_config('github_copilot', 'gho-test');
        my $result = $mgr->adapt_request_for_endpoint($payload, $ec);

        is($result->{reasoning_effort}, 'medium', "GitHub Copilot $model gets reasoning_effort=medium");
    }
}

# 6. GitHub Copilot: o-series and gpt-5+ get reasoning_effort
{
    for my $model (qw(o1-preview o3-mini o4-mini gpt-5 gpt-5-mini gpt-5-codex)) {
        my $mgr = _make_mgr(show_thinking => 1, thinking_effort => 'low');
        $mgr->{_model_capabilities_cache} ||= {};
        $mgr->{_model_capabilities_cache}{$model} = { supports_reasoning => 1, reasoning_mode => 'effort' };
        my $payload = { model => $model, messages => [] };
        my $ec = CLIO::Providers::build_endpoint_config('github_copilot', 'gho-test');
        my $result = $mgr->adapt_request_for_endpoint($payload, $ec);

        is($result->{reasoning_effort}, 'low', "GitHub Copilot $model gets reasoning_effort=low");
    }
}

# 7. GitHub Copilot: non-reasoning models do NOT get reasoning_effort
{
    for my $model (qw(
        gpt-4o
        gpt-4.1
        gpt-3.5-turbo
        claude-3-5-sonnet
        claude-3-haiku
    )) {
        my $mgr = _make_mgr(show_thinking => 1, thinking_effort => 'high');
        # Preload supports_reasoning=0 to skip the slow lookup path.
        # _get_reasoning_mode() returns undef for these models.
        $mgr->{_model_capabilities_cache} ||= {};
        $mgr->{_model_capabilities_cache}{$model} = { supports_reasoning => 0 };
        my $payload = { model => $model, messages => [] };
        my $ec = CLIO::Providers::build_endpoint_config('github_copilot', 'gho-test');
        my $result = $mgr->adapt_request_for_endpoint($payload, $ec);

        ok(!exists $result->{reasoning_effort}, "GitHub Copilot $model does NOT get reasoning_effort");
    }
}

# 8. GitHub Copilot: show_thinking off - no reasoning_effort
{
    my $mgr = _make_mgr(show_thinking => 0, thinking_effort => 'high');
    $mgr->{_model_capabilities_cache} ||= {};
    $mgr->{_model_capabilities_cache}{'gpt-5'} = { supports_reasoning => 1, reasoning_mode => 'effort' };
    my $payload = { model => 'gpt-5', messages => [] };
    my $ec = CLIO::Providers::build_endpoint_config('github_copilot', 'gho-test');
    my $result = $mgr->adapt_request_for_endpoint($payload, $ec);

    ok(!exists $result->{reasoning_effort}, 'GitHub Copilot gpt-5: no reasoning_effort when show_thinking=0');
}

# 9. OpenRouter: unchanged behavior (uses reasoning: {enabled,effort})
{
    my $mgr = _make_mgr(show_thinking => 1, thinking_effort => 'high');
    $mgr->{_model_capabilities_cache} = { 'deepseek/deepseek-r1' => { supports_reasoning => 1 } };

    my $payload = { model => 'deepseek/deepseek-r1', messages => [] };
    my $ec = CLIO::Providers::build_endpoint_config('openrouter', 'sk-test');
    my $result = $mgr->adapt_request_for_endpoint($payload, $ec);

    ok(!exists $result->{reasoning_effort}, 'OpenRouter path does NOT use reasoning_effort key');
    ok(exists $result->{reasoning}, 'OpenRouter path uses reasoning key');
    is($result->{reasoning}{effort}, 'high', 'OpenRouter reasoning.effort = high');
    ok($result->{reasoning}{enabled}, 'OpenRouter reasoning.enabled = true');
}

# 10. Provider registry: openai + github_copilot have supports_reasoning
{
    my $openai = CLIO::Providers::get_provider('openai');
    ok($openai->{supports_reasoning}, 'openai provider has supports_reasoning=1');

    my $copilot = CLIO::Providers::get_provider('github_copilot');
    ok($copilot->{supports_reasoning}, 'github_copilot provider has supports_reasoning=1');
}

# 11. Provider registry: ollama_cloud no longer claims reasoning support
{
    my $ollama = CLIO::Providers::get_provider('ollama_cloud');
    ok(!$ollama->{supports_reasoning}, 'ollama_cloud provider does NOT have supports_reasoning');

    # Endpoint config also no longer propagates the flag
    my $ec = CLIO::Providers::build_endpoint_config('ollama_cloud', 'test-key');
    ok(!$ec->{supports_reasoning}, 'ollama_cloud endpoint config does NOT have supports_reasoning');
}

# 12. Endpoint config propagates supports_reasoning from provider
{
    my $ec_openai = CLIO::Providers::build_endpoint_config('openai', 'sk-test');
    ok($ec_openai->{supports_reasoning}, 'openai endpoint config inherits supports_reasoning');

    my $ec_copilot = CLIO::Providers::build_endpoint_config('github_copilot', 'gho-test');
    ok($ec_copilot->{supports_reasoning}, 'github_copilot endpoint config inherits supports_reasoning');
}

# 13. thinking_effort values propagate verbatim
{
    for my $effort (qw(low medium high)) {
        my $mgr = _make_mgr(show_thinking => 1, thinking_effort => $effort);
        $mgr->{_model_capabilities_cache} ||= {};
        $mgr->{_model_capabilities_cache}{'o3-mini'} = { supports_reasoning => 1, reasoning_mode => 'effort' };
        my $payload = { model => 'o3-mini', messages => [] };
        my $ec = CLIO::Providers::build_endpoint_config('openai', 'sk-test');
        my $result = $mgr->adapt_request_for_endpoint($payload, $ec);
        is($result->{reasoning_effort}, $effort, "thinking_effort=$effort propagates to OpenAI o3-mini");
    }
}

# 14. Payload with already-set reasoning_effort is overwritten
{
    my $mgr = _make_mgr(show_thinking => 1, thinking_effort => 'low');
    $mgr->{_model_capabilities_cache} ||= {};
    $mgr->{_model_capabilities_cache}{'o3-mini'} = { supports_reasoning => 1, reasoning_mode => 'effort' };
    my $payload = { model => 'o3-mini', messages => [], reasoning_effort => 'stale-value' };
    my $ec = CLIO::Providers::build_endpoint_config('openai', 'sk-test');
    my $result = $mgr->adapt_request_for_endpoint($payload, $ec);

    is($result->{reasoning_effort}, 'low', 'reasoning_effort overwritten by config value');
}

# 15. Copilot + openai combo: if a user routes openai through Copilot, the openai branch wins
{
    my $mgr = _make_mgr(show_thinking => 1, thinking_effort => 'medium');
    $mgr->{_model_capabilities_cache} ||= {};
    $mgr->{_model_capabilities_cache}{'gpt-5'} = { supports_reasoning => 1, reasoning_mode => 'effort' };
    my $payload = { model => 'gpt-5', messages => [] };
    my $ec = CLIO::Providers::build_endpoint_config('openai', 'sk-test');
    ok(!$ec->{requires_copilot_headers}, 'openai endpoint does not have requires_copilot_headers');
    my $result = $mgr->adapt_request_for_endpoint($payload, $ec);
    is($result->{reasoning_effort}, 'medium', 'pure openai path: gpt-5 gets reasoning_effort');
}

done_testing();
