#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

=head1 NAME

test_mcm_openrouter_fix.pl - Test that OpenRouter models are found in the JSON
database and that tool support is correctly detected.

This test verifies the fix for a bug where OpenRouter (and several other
providers) were invisible to the ModelDataLoader's provider mapping due to
a field name mismatch (provider_mappings vs provider_mapping).

=cut

use strict;
use warnings;
use utf8;
use Test::More;
use CLIO::Core::ModelDataLoader;
use CLIO::Core::ModelCapabilitiesManager;

# Test 1: ModelDataLoader finds OpenRouter models (was broken: provider_mappings
# vs provider_mapping field name mismatch)
my $loader = CLIO::Core::ModelDataLoader->new();

my $caps = $loader->get_model_capabilities_by_provider("openrouter", "poolside/laguna-s-2.1");
ok($caps, "JSON loader finds openrouter/poolside/laguna-s-2.1");
is($caps->{supports_tools}, 1, "laguna-s-2.1 supports_tools=1 from JSON loader");
is($caps->{context_window}, 1048576, "laguna-s-2.1 context_window=1048576 (updated from API)");

# Test 2: Other apikey-compatible providers that were also broken
for my $provider (qw(openai vercel kilo orca ollama_cloud)) {
    # These providers don't have models in models.json, so get_model_capabilities_by_provider
    # returns undef — but the function shouldn't crash and should work for known models
    my $result = $loader->get_model_capabilities_by_provider($provider, "nonexistent-model");
    is($result, undef, "$provider/nonexistent-model returns undef (no crash)");
}

# Test 3: All providers in provider-mapping.json are accessible
my @all_providers = sort keys %{$loader->{_cache}{provider_mapping}};
my @known_providers = qw(anthropic deepseek github_copilot google kilo llama.cpp
    lmstudio minimax minimaxi nvidia ollama_cloud openai openrouter
    orca sam vercel zai zai_coding);
# Just verify openrouter is in the list (the primary bug)
ok(grep { $_ eq 'openrouter' } @all_providers, "openrouter is in provider_mapping");
ok(grep { $_ eq 'openai' } @all_providers, "openai is in provider_mapping");
ok(grep { $_ eq 'vercel' } @all_providers, "vercel is in provider_mapping");

# Test 4: Heuristics include laguna (migrated from Perl to JSON)
my $laguna_heur = $loader->match_heuristics("laguna-s-2.1");
ok($laguna_heur, "Heuristics match laguna-s-2.1");
is($laguna_heur->{supports_tools}, 1, "laguna heuristic supports_tools=1");
is($laguna_heur->{context_window}, 1048576, "laguna heuristic context_window=1048576");

# Test 5: Heuristics include qwen-2.5 (was missing from JSON heuristics)
my $qwen_heur = $loader->match_heuristics("Qwen2.5-7B-chat-Q4_K_M.gguf");
ok($qwen_heur, "Heuristics match Qwen2.5 with quantization suffix");
is($qwen_heur->{context_window}, 131072, "Qwen 2.5 heuristic context_window=131072");

# Test 6: Heuristics include llama-generic (catch-all for older llama models)
my $llama_heur = $loader->match_heuristics("llama-2-7b-chat-hf");
ok($llama_heur, "Heuristics match generic llama-2");
is($llama_heur->{context_window}, 4096, "llama-2 generic heuristic context_window=4096");
is($llama_heur->{supports_tools}, 0, "llama-2 generic heuristic supports_tools=0");

# Test 7: yi model heuristic has tools=1 (was incorrectly 0 in JSON heuristics)
my $yi_heur = $loader->match_heuristics("yi-1.5");
ok($yi_heur, "Heuristics match yi-1.5");
is($yi_heur->{supports_tools}, 1, "yi-1.5 heuristic supports_tools=1 (fixed from 0)");

# Test 8: Perl heuristics function is removed (consolidated into JSON)
my $mcm = CLIO::Core::ModelCapabilitiesManager->new(debug => 0);
ok(!$mcm->can("_llama_cpp_model_heuristics"),
    "_llama_cpp_model_heuristics Perl function removed (consolidated into JSON)");

# Test 9: Cache versioning exists
ok(defined CLIO::Core::ModelCapabilitiesManager::CACHE_VERSION(),
    "CACHE_VERSION constant is defined");
is(CLIO::Core::ModelCapabilitiesManager::CACHE_VERSION(), 2,
    "CACHE_VERSION is 2 (bumped to invalidate stale caches)");

# Test 10: MCM cache rejects old-version entries
my $tmp_cache = TestHelper_temp_file();
my $mcm_v1 = CLIO::Core::ModelCapabilitiesManager->new(
    cache_file => $tmp_cache,
    cache_ttl  => 3600,
);
# Manually write a cache with old version
my $old_cache = {
    "openrouter:test-model:" => {
        context_window => 1024,
        supports_tools => 0,
        _cached_at => time,
        _cache_version => 1,  # Old version
    },
};
write_cache_file($tmp_cache, $old_cache);

my $mcm_v2 = CLIO::Core::ModelCapabilitiesManager->new(
    cache_file => $tmp_cache,
    cache_ttl  => 3600,
);
# The old-version cache entry should be discarded
my $cached = $mcm_v2->{cache}->{"openrouter:test-model:"};
ok(!defined $cached, "Old cache version (1) is discarded, not served");

# Test 11: _fetch_openai_compatible_capabilities detects reasoning from
# the reasoning field even when supported_efforts is absent (OpenRouter
# returns reasoning:{default_enabled:1} without supported_efforts).
# This is tested via source inspection since it requires a live API key.
{
    my $src = do { local $/; open my $fh, '<', 'lib/CLIO/Core/ModelCapabilitiesManager.pm' or die; <$fh> };
    like($src, qr/\$supports_reasoning_flag = 1/,
        "_fetch_openai_compatible_capabilities sets supports_reasoning from reasoning field presence");
    like($src, qr/supports_reasoning\s+=>\s+\$supports_reasoning_flag/,
        "supports_reasoning is set from flag, not just reasoning_mode presence");
}

# Test 12: API-first priority for OpenAI-compatible providers
# The restructured _fetch_provider_capabilities tries the API before
# falling back to JSON. This is verified via source inspection since
# it requires network/API key.
{
    my $src = do { local $/; open my $fh, '<', 'lib/CLIO/Core/ModelCapabilitiesManager.pm' or die; <$fh> };
    # The OpenAI-compatible fetcher should be called before the JSON loader fallback
    my $api_idx = index($src, '_fetch_openai_compatible_capabilities($provider, $model)');
    my $json_idx = index($src, 'JSON loader fallback hit');
    ok($api_idx >= 0, "_fetch_openai_compatible_capabilities call exists");
    ok($json_idx >= 0, 'JSON loader fallback path exists after API fetcher');
    ok($api_idx < $json_idx, "API fetcher is called before JSON loader fallback");
}

# Test 13: provider-mapping.json includes all providers from the registry
{
    require CLIO::Providers;
    my @reg_providers = sort CLIO::Providers::list_providers();
    my $loader2 = CLIO::Core::ModelDataLoader->new();
    $loader2->get_model_capabilities_by_provider("openrouter", "test");
    my %json_providers = map { $_ => 1 } keys %{$loader2->{_cache}{provider_mapping}};
    my @missing = grep { !$json_providers{$_} } @reg_providers;
    is(scalar(@missing), 0, "All registry providers have JSON mapping entries");
    if (@missing) {
        diag("Providers missing from JSON: " . join(", ", @missing));
    }
}

done_testing();

# --- Helpers ---

sub TestHelper_temp_file {
    require File::Temp;
    my $tmp = File::Temp->new(SUFFIX => '.json');
    return $tmp->filename;
}

sub write_cache_file {
    my ($path, $data) = @_;
    require CLIO::Util::JSON;
    my $json = CLIO::Util::JSON::encode_json($data);
    open my $fh, '>:encoding(UTF-8)', $path or die "Cannot write $path: $!";
    print $fh $json;
    close $fh;
}
