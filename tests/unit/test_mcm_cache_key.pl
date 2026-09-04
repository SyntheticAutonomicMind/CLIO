#!/usr/bin/perl
# SPDX-License-Identifier: GPL-3.0-only
use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../../lib";

# Regression: MCM cache key was "${provider}:${model}" - a flat
# namespace that did not invalidate on /api set base changes. When
# the user changed the api_base for a provider, the old cache entry
# (data fetched from the old URL) was still served for up to 1 hour
# (the TTL). For the llama.cpp / proxy case this meant the wrong
# context_window was reported until the TTL expired.
#
# Two improvements:
#
# 1. Model name normalization: cache key normalizes the model name
#    (lowercase + strip leading org/ segment) so "MiniMax-M3",
#    "minimax-m3", "minimax/MiniMax-M3", "minimax/minimax-m3" all
#    share a single cache entry. Before this, each was a distinct
#    key, creating 4 sibling entries for the same model. The model
#    name is what the user types, and case/prefix variations are
#    not semantically different - the same model is being looked up.
#
# 2. api_base included in cache key: when the user changes /api set
#    base, the cache key changes, so the old entry is unreachable
#    and expires after TTL. Combined with #1, this means
#    provider+model+api_base uniquely identifies a cache entry.
#
# The fix: new _build_cache_key helper that constructs the key
# with the normalized model and current api_base. Both get_capabilities
# and refresh_capabilities use it.

use Test::More;

use CLIO::Core::ModelCapabilitiesManager;
use CLIO::Core::Config;

my $mcm = CLIO::Core::ModelCapabilitiesManager->new();

# Test 1: Model name normalization - same model with different casings
# share a single cache key
{
    my @variants = qw(MiniMax-M3 minimax-m3 minimax/MiniMax-M3
                      minimax/minimax-m3 minimaxai/MiniMax-M3);
    my %keys;
    for my $model (@variants) {
        $keys{$mcm->_build_cache_key('minimax', $model)} = 1;
    }
    is(scalar keys %keys, 1,
        '5 case/prefix variants of MiniMax-M3 all share 1 cache key');
}

# Test 2: Different model names produce different keys
{
    my $key_m3 = $mcm->_build_cache_key('minimax', 'MiniMax-M3');
    my $key_m2 = $mcm->_build_cache_key('minimax', 'MiniMax-M2.7');
    isnt($key_m3, $key_m2, 'different models produce different cache keys');
}

# Test 3: Different providers produce different keys
{
    my $key_minimax = $mcm->_build_cache_key('minimax', 'some-model');
    my $key_anthropic = $mcm->_build_cache_key('anthropic', 'some-model');
    isnt($key_minimax, $key_anthropic,
        'different providers produce different cache keys');
}

# Test 4: api_base is included in cache key construction
# We verify this by source inspection rather than runtime integration
# because the api_base reading goes through Config::new() which loads
# from disk and ignores in-memory mutations. The integration with
# Config is exercised by Config's own tests; MCM just needs to use
# the helper consistently.
{
    my $src = do { local $/; open my $fh, '<', 'lib/CLIO/Core/ModelCapabilitiesManager.pm' or die; <$fh> };

    # The helper must call get_provider_base
    my $helper_start = index($src, 'sub _build_cache_key');
    my $helper_end   = index($src, 'sub ', $helper_start + 1);
    my $helper_body  = $helper_start >= 0 && $helper_end > $helper_start
        ? substr($src, $helper_start, $helper_end - $helper_start)
        : '';
    like($helper_body, qr/get_provider_base/,
        '_build_cache_key reads user api_base via Config::get_provider_base');
}

# Test 5: get_capabilities uses the new key (no direct read of the
# old key format). This is a source-level check because we can't
# easily populate the cache file and then read it in a test.
{
    my $src = do { local $/; open my $fh, '<', 'lib/CLIO/Core/ModelCapabilitiesManager.pm' or die; <$fh> };
    like($src, qr/sub _build_cache_key/,
        '_build_cache_key helper is defined');
    like($src, qr/\$cache_key = \$self->_build_cache_key\(\$provider, \$model\)/,
        'get_capabilities uses _build_cache_key');
    # The old hardcoded format should not be present
    unlike($src, qr/\$\s*cache_key\s*=\s*"\$?\{provider\}:\$?\{model\}"/,
        'old hardcoded "${provider}:${model}" cache key is removed');
}

# Test 6: get_capabilities, refresh_capabilities, and the static_map
# lookup path all use the same cache key construction
{
    my $src = do { local $/; open my $fh, '<', 'lib/CLIO/Core/ModelCapabilitiesManager.pm' or die; <$fh> };

    my $count = () = $src =~ /_build_cache_key\(\$provider, \$model\)/g;
    ok($count >= 2, "cache key helper used $count times (get_capabilities + refresh_capabilities minimum)");
}

# Test 7: Model with no prefix and no slash - just gets lowercased
{
    my $key = $mcm->_build_cache_key('anthropic', 'claude-sonnet-4-20250514');
    # Cache key includes provider:normalized_model:api_base
    # api_base may be set from user config - just verify structure
    like($key, qr/^anthropic:claude-sonnet-4-20250514:/,
        'Anthropic model name with date is preserved as-is (lowercased)');
}

# Test 8: Model name with deep org path - only first org/ is stripped
{
    my $key = $mcm->_build_cache_key('nvidia', 'nvidia/llama-3.1-nemotron-nano-8b-v1');
    # 'nvidia/llama-3.1-nemotron-nano-8b-v1' -> strip 'nvidia/' -> 'llama-3.1-nemotron-nano-8b-v1'
    like($key, qr/^nvidia:llama-3\.1-nemotron-nano-8b-v1:/,
        'single leading org/ segment is stripped from model name');
}

# Test 9: Model name with no path - just lowercased.
# The cache key includes the api_base as the third component
# (see docblock at top - provider+model+api_base is the cache
# dimension). This test was previously asserting an empty third
# component, which contradicted the docblock and the api_base
# test (#4). Updated to assert the full key shape.
{
    my $key = $mcm->_build_cache_key('github_copilot', 'claude-sonnet-4.6');
    like($key, qr/^github_copilot:claude-sonnet-4\.6:/,
        'bare model name is just lowercased');
    is($key, 'github_copilot:claude-sonnet-4.6:' . (
        eval { my $c = CLIO::Core::Config->new(); $c->get_provider_base('github_copilot'); } || ''
    ), 'cache key ends with the configured api_base');
}

# Test 10: Special characters in model name (e.g. dots, dashes)
{
    my $key = $mcm->_build_cache_key('zai', 'glm-5.1');
    is($key, 'zai:glm-5.1:',
        'model name with dots/dashes is preserved');
}

done_testing();
