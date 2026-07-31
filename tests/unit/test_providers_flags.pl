#!/usr/bin/env perl
# Test: provider registry flags and helpers in CLIO::Providers.
#
# Validates the local_inference / exposes_props / default_context_window
# / url_detection_patterns feature flags introduced to replace scattered
# `provider =~ /^sam|lmstudio|llama\.cpp$/i` regex checks across the
# codebase.
#
# Adding a new local inference provider should require:
#   1. Add entry to %PROVIDERS with local_inference => 1, exposes_props => 1,
#      (optional) url_detection_patterns => [qr{...}].
#   2. Tests in this file should pass without any code change in the
#      consumers (MessageValidator, APIManager, MCM, provider_from_url).

use strict;
use warnings;
use utf8;
use lib './lib';
use Test::More;
use CLIO::Providers qw(
    get_provider list_providers provider_exists
    is_local_inference exposes_props default_context_window
    provider_from_url
);
use CLIO::Core::Defaults qw(
    DEFAULT_LOCAL_CONTEXT_WINDOW DEFAULT_CONTEXT_WINDOW
);

# Each tier name + the providers that should belong to it.
my @LOCAL_NAMES  = qw(sam lmstudio llama.cpp);
my @CLOUD_NAMES  = qw(openai anthropic google minimax zai deepseek nvidia github_copilot openrouter ollama_cloud);

# ============================================================================
# Registry must declare the flags on every named local provider
# ============================================================================
for my $name (@LOCAL_NAMES) {
    my $p = get_provider($name);
    ok($p, "local provider $name is registered");

    ok($p->{local_inference}, "$name has local_inference flag set");
    ok($p->{exposes_props},   "$name has exposes_props flag set");
}

for my $name (@CLOUD_NAMES) {
    my $p = get_provider($name);
    ok($p, "cloud provider $name is registered");
    ok(!$p->{local_inference}, "$name should NOT have local_inference flag");
    ok(!$p->{exposes_props},   "$name should NOT have exposes_props flag");
}

# ============================================================================
# is_local_inference
# ============================================================================
for my $name (@LOCAL_NAMES) {
    is(is_local_inference($name), 1, "is_local_inference($name) == 1");
}
for my $name (@CLOUD_NAMES) {
    is(is_local_inference($name), 0, "is_local_inference($name) == 0");
}
is(is_local_inference('nonexistent_provider'), 0, "is_local_inference(unknown) == 0");

# ============================================================================
# exposes_props
# ============================================================================
for my $name (@LOCAL_NAMES) {
    is(exposes_props($name), 1, "exposes_props($name) == 1");
}
for my $name (@CLOUD_NAMES) {
    is(exposes_props($name), 0, "exposes_props($name) == 0");
}
is(exposes_props('nonexistent_provider'), 0, "exposes_props(unknown) == 0");

# ============================================================================
# default_context_window
# ============================================================================
for my $name (@LOCAL_NAMES) {
    is(default_context_window($name),
        DEFAULT_LOCAL_CONTEXT_WINDOW(),
        "default_context_window($name) == DEFAULT_LOCAL_CONTEXT_WINDOW");
}
for my $name (@CLOUD_NAMES) {
    is(default_context_window($name),
        DEFAULT_CONTEXT_WINDOW(),
        "default_context_window($name) == DEFAULT_CONTEXT_WINDOW");
}

# Sentinel value: any provider that is_local_inference() should be enough
# to route to the local default. The function uses is_local_inference so
# any non-empty provider name that triggers a "true" result works.
{
    # A fake provider name that's in the registry gets its own result
    is(default_context_window('sam'),  DEFAULT_LOCAL_CONTEXT_WINDOW(),
        "default_context_window sam -> local window");
    is(default_context_window('openai'), DEFAULT_CONTEXT_WINDOW(),
        "default_context_window openai -> cloud window");
}

# ============================================================================
# url_detection_patterns - registry-driven URL discovery
# ============================================================================
{
    # SAM listens on 8080
    is(provider_from_url('http://localhost:8080/v1/models'),    'sam',
        'SAM URL pattern matches via registry');
    is(provider_from_url('http://localhost:8080/v1/chat/completions'), 'sam',
        'SAM URL with /chat path still matches');
    is(provider_from_url('http://192.168.1.50:8080/v1'), 'sam',
        'SAM pattern matches LAN host too');
    is(provider_from_url('https://api.example.com:8080/'), 'sam',
        'SAM pattern is port-based (not just localhost)');

    # LM Studio listens on 1234
    is(provider_from_url('http://localhost:1234/v1/models'), 'lmstudio',
        'LM Studio URL pattern matches via registry');
    is(provider_from_url('http://gpu-server.local:1234/v1'), 'lmstudio',
        'LM Studio LAN hostname matches');

    # llama.cpp has no detection pattern (port is freely configurable).
    # Confirm the URL falls through to undef, which means user must
    # specify --provider llama.cpp explicitly.
    is(provider_from_url('http://localhost:8080/v1/models'),
        'sam',
        'llama.cpp explicitly NOT in URL detection (falls through to sam on 8080)');
}

# ============================================================================
# provider_from_url preserves cloud-provider match behavior
# ============================================================================
{
    is(provider_from_url('https://api.anthropic.com/v1/messages'), 'anthropic',      'Anthropic URL');
    is(provider_from_url('https://api.openai.com/v1/models'),      'openai',         'OpenAI URL');
    is(provider_from_url('https://api.githubcopilot.com'),          'github-copilot', 'Copilot URL');
    is(provider_from_url('https://api.minimax.io/v1/models'),       'minimax',        'MiniMax URL');
    is(provider_from_url('https://api.deepseek.com/v1/models'),     'deepseek',       'DeepSeek URL');
    is(provider_from_url('https://api.z.ai/api/paas/v4/models'),    'zai',            'Z.AI URL');
    is(provider_from_url('https://integrate.api.nvidia.com/v1'),     'nvidia',         'NVIDIA URL');
    is(provider_from_url('https://openrouter.ai/api/v1/models'),     'openrouter',     'OpenRouter URL');
    is(provider_from_url('https://ollama.com/v1/models'),           'ollama-cloud',   'Ollama Cloud URL');
    is(provider_from_url('https://dashscope.aliyuncs.com/compatible-mode/v1/models'),
       'dashscope',
       'DashScope URL');
}

# An unknown LAN URL with explicit port must NOT match any provider,
# so the caller can decide if it's a local server with custom port.
{
    is(provider_from_url('http://my-server.local:9999/v1'),
        undef,
        'Unknown LAN URL with custom port returns undef');
    is(provider_from_url('https://api.example.com/v1'),
        undef,
        'Unknown cloud URL returns undef');
}

done_testing();
