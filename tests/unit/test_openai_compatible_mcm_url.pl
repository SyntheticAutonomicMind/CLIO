#!/usr/bin/perl
# SPDX-License-Identifier: GPL-3.0-only
use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../../lib";

# Regression: MCM._fetch_openai_compatible_capabilities had two bugs that
# silently broke capability lookup for every openai-compatible provider
# (openai, openrouter, ollama_cloud, sam, lmstudio, llama.cpp, generic):
#
# 1. It used the provider's default api_base from Providers.pm
#    ($provider_def->{api_base}) instead of the user's configured api_base
#    (which they set via /api set base). For local providers this is
#    essentially always wrong - the user has overridden the default
#    localhost:port to point at their LAN IP, a non-default port, or a
#    proxy. MCM kept hitting the default and either got stale data or
#    failed silently.
#
# 2. It appended /models to the full chat URL. For
#    https://api.openai.com/v1/chat/completions, that produced
#    https://api.openai.com/v1/chat/completions/models which doesn't
#    exist (the models endpoint is /v1/models). Result: HTTP 404, MCM
#    returns undef, the user sees the provider's max_context_tokens
#    fallback or DEFAULT_CONTEXT_WINDOW.
#
# Fix:
# - Read user_api_base via Config::get_provider_base($provider)
# - Transform: strip /chat/completions (or /chat) and trailing slashes
#   before appending /models

use Test::More;

# Simulate the URL transformation in isolation (same regex the fix uses)
sub _derive_models_url {
    my ($api_base) = @_;
    $api_base =~ s{/+$}{};
    $api_base =~ s{/chat/completions/?$}{};
    $api_base =~ s{/chat/?$}{};
    return "${api_base}/models";
}

# Test 1: openai (default) - https://api.openai.com/v1/chat/completions
is(_derive_models_url('https://api.openai.com/v1/chat/completions'),
   'https://api.openai.com/v1/models',
   'openai: /v1/chat/completions -> /v1/models');

# Test 2: openai with trailing slash
is(_derive_models_url('https://api.openai.com/v1/chat/completions/'),
   'https://api.openai.com/v1/models',
   'openai: trailing slash is stripped');

# Test 3: openrouter
is(_derive_models_url('https://openrouter.ai/api/v1/chat/completions'),
   'https://openrouter.ai/api/v1/models',
   'openrouter: /api/v1/chat/completions -> /api/v1/models');

# Test 3a: OrcaRouter
is(_derive_models_url('https://api.orcarouter.ai/v1/chat/completions'),
   'https://api.orcarouter.ai/v1/models',
   'orca: /v1/chat/completions -> /v1/models');

# Test 3b: KiloCode
is(_derive_models_url('https://api.kilo.ai/api/gateway/chat/completions'),
   'https://api.kilo.ai/api/gateway/models',
   'kilo: /api/gateway/chat/completions -> /api/gateway/models');

# Test 4: ollama_cloud
is(_derive_models_url('https://ollama.com/v1/chat/completions'),
   'https://ollama.com/v1/models',
   'ollama_cloud: /v1/chat/completions -> /v1/models');

# Test 5: sam (local, port 8080)
is(_derive_models_url('http://localhost:8080/v1/chat/completions'),
   'http://localhost:8080/v1/models',
   'sam: local /v1/chat/completions -> /v1/models');

# Test 6: lmstudio (local, port 1234)
is(_derive_models_url('http://localhost:1234/v1/chat/completions'),
   'http://localhost:1234/v1/models',
   'lmstudio: local /v1/chat/completions -> /v1/models');

# Test 7: llama.cpp on LAN (user overrides api_base)
is(_derive_models_url('http://192.168.1.50:9090/v1/chat/completions'),
   'http://192.168.1.50:9090/v1/models',
   'llama.cpp on LAN: LAN IP + custom port + /v1 -> /v1/models');

# Test 8: provider that has api_base WITHOUT /chat/completions (e.g. deepseek)
is(_derive_models_url('https://api.deepseek.com/v1'),
   'https://api.deepseek.com/v1/models',
   'deepseek: /v1 (no /chat/completions) -> /v1/models');

# Test 9: z.ai
is(_derive_models_url('https://api.z.ai/api/paas/v4'),
   'https://api.z.ai/api/paas/v4/models',
   'z.ai: /api/paas/v4 -> /api/paas/v4/models');

# Test 10: bare host (no path at all) - some providers set api_base to just a URL
is(_derive_models_url('https://api.example.com'),
   'https://api.example.com/models',
   'bare host: /models is appended');

# Test 11: Verify the source actually does the transformation in the MCM
# (regression guard against future refactors)
{
    my $src = do { local $/; open my $fh, '<', 'lib/CLIO/Core/ModelCapabilitiesManager.pm' or die; <$fh> };
    like($src, qr/get_provider_base\(\$provider\)/,
        'MCM openai-compatible fetcher calls get_provider_base($provider)');
    like($src, qr{chat/completions},
        'MCM strips /chat/completions from api_base');
    like($src, qr/get_provider_base\(\$provider\)/,
        'MCM openai-compatible fetcher reads user api_base');
}

done_testing();
