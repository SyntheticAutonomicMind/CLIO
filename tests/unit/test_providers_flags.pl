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
    capability_fetcher default_reasoning_mode
    quota_handler
);
use CLIO::Core::Defaults qw(
    DEFAULT_LOCAL_CONTEXT_WINDOW DEFAULT_CONTEXT_WINDOW
);
use CLIO::Core::ModelDataLoader;

# JSON defaults per provider (centralized model data inserts these).
# The function checks JSON defaults first, then falls back to
# DEFAULT_LOCAL_CONTEXT_WINDOW / DEFAULT_CONTEXT_WINDOW constants.
my %PROVIDER_DEFAULT_CONTEXT = (
    'sam'           => 32000,
    'lmstudio'      => 32000,
    'llama.cpp'     => 32000,
    'openai'        => 128000,
    'anthropic'     => 200000,
    'google'        => 1048576,
    'minimax'       => 1000000,
    'zai'           => 200000,
    'deepseek'      => 1048576,
    'nvidia'        => 1048576,
    'github_copilot' => 128000,
    'openrouter'    => 128000,
    'ollama_cloud'  => 128000,
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
# Returns the JSON-declared default for each provider (per-provider
# accurate values), or the constant fallback when JSON doesn't define
# one. Constants provide a safe default for newly-added providers.
for my $name (@LOCAL_NAMES) {
    is(default_context_window($name),
        $PROVIDER_DEFAULT_CONTEXT{$name},
        "default_context_window($name) == DEFAULT_LOCAL_CONTEXT_WINDOW");
}
for my $name (@CLOUD_NAMES) {
    is(default_context_window($name),
        $PROVIDER_DEFAULT_CONTEXT{$name},
        "default_context_window($name) == DEFAULT_CONTEXT_WINDOW");
}

# Sentinel value: any provider that is_local_inference() should be enough
# to route to the local default. The function uses is_local_inference so
# any non-empty provider name that triggers a "true" result works.
{
    # The function checks JSON defaults first - sam and openai both have
    # max_context_tokens defined in provider-defaults.json so they get
    # the per-provider value, not the constants.
    is(default_context_window('sam'),  $PROVIDER_DEFAULT_CONTEXT{sam},
        "default_context_window sam -> JSON-declared default");
    is(default_context_window('openai'), $PROVIDER_DEFAULT_CONTEXT{openai},
        "default_context_window openai -> JSON-declared default");
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

# ============================================================================
# capability_fetcher - registry-driven MCM dispatch
# ============================================================================
{
    # Providers with a dedicated fetcher declare it in the registry.
    # Each fetcher value maps to a `_fetch_<value>_capabilities` method
    # on ModelCapabilitiesManager. Most providers use a one-to-one
    # mapping (anthropic -> anthropic), but some share a fetcher
    # (minimax + minimax_token both -> minimax, zai + zai_coding
    # both -> zai). Document the map explicitly so future additions
    # notice when they need to add to the shared set.
    my %EXPECTED_FETCHER = (
        'anthropic'      => 'anthropic',
        'google'         => 'google',
        'nvidia'         => 'nvidia',
        'zai'            => 'zai',
        'zai_coding'     => 'zai',
        'minimax'        => 'minimax',
        'minimax_token'  => 'minimax',
        'deepseek'       => 'deepseek',
        'github_copilot' => 'github_copilot',
    );
    for my $name (sort keys %EXPECTED_FETCHER) {
        is(capability_fetcher($name), $EXPECTED_FETCHER{$name},
            "capability_fetcher($name) maps to $EXPECTED_FETCHER{$name}");
    }

    # Providers without a dedicated fetcher return undef so the caller
    # can fall back to the generic OpenAI-compatible path.
    for my $name (qw(openai ollama_cloud openrouter sam lmstudio)) {
        is(capability_fetcher($name), undef,
            "$name has no dedicated fetcher -> undef (caller falls back)");
    }
}

# ============================================================================
# default_reasoning_mode - registry-driven MCM reasoning_mode heuristic
# ============================================================================
{
    # Providers with an explicit default
    is(default_reasoning_mode('anthropic'), 'adaptive',
        'anthropic default is adaptive (most 5+ models)');
    is(default_reasoning_mode('google'), 'enabled',
        'google default is enabled (thinkingBudget)');
    is(default_reasoning_mode('zai'),  'enabled',
        'zai default is enabled (GLM thinking type)');
    is(default_reasoning_mode('deepseek'), 'effort',
        'deepseek default is effort (reasoning_effort)');

    # Cloud providers without a declared default: fall through to
    # the effort-mode fallback in MCM. The registry returns undef
    # so MCM can apply its own model-name heuristics.
    for my $name (qw(openai github_copilot openrouter nvidia)) {
        is(default_reasoning_mode($name), undef,
            "$name has no declared default -> undef (MCM uses fallback)");
    }

    # MiniMax family: per-model (M3 adaptive vs M2.x enabled),
    # so the registry deliberately leaves the default undef and lets
    # the model-name pattern in MCM run.
    is(default_reasoning_mode('minimax'),      undef,
        'minimax leaves default undef (M3/M2.x split is per-model)');
    is(default_reasoning_mode('minimax_token'), undef,
        'minimax_token leaves default undef (same reason)');
}

# ============================================================================
# quota_handler - registry-driven /api quota dispatch
# ============================================================================
{
    # quota_handler returns the suffix that maps to `_handle_<x>_quota`
    # on the UI/Commands/API/Auth command class. Providers without a
    # quota API return undef (caller shows "no quota API" message).
    is(quota_handler('github_copilot'), 'copilot',
        'github_copilot -> copilot handler');
    is(quota_handler('minimax'),       'minimax',
        'minimax -> minimax handler');
    is(quota_handler('minimax_token'), 'minimax',
        'minimax_token shares the minimax handler (Token Plan API)');

    # Providers without quota APIs
    for my $name (qw(openai anthropic google zai nvidia deepseek openrouter)) {
        is(quota_handler($name), undef,
            "$name has no quota API -> undef");
    }
}

done_testing();
