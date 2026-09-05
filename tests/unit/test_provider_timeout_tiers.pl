#!/usr/bin/env perl
# Test that build_endpoint_config properly propagates slow_api and
# route_timeout flags so APIManager can select the correct HTTP timeout.
#
# Background: Previously build_endpoint_config only propagated
# supports_reasoning, llama_user_id_supported, and reasoning_schema.
# The slow_api flag (set for local providers: sam, llama.cpp, lmstudio)
# was missing from the endpoint config, so all providers got the 300s
# cloud default timeout. This test ensures slow_api and route_timeout
# are propagated correctly.

use strict;
use warnings;
use utf8;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";

use CLIO::Providers qw(build_endpoint_config get_provider);

# ── Test 1: slow_api is propagated for local providers ──────────────
{
    my @local_providers = ('sam', 'llama.cpp', 'lmstudio');
    for my $p (@local_providers) {
        my $cfg = build_endpoint_config($p, 'test-key');
        ok($cfg->{slow_api} == 1,
            "build_endpoint_config propagates slow_api for $p");
    }
}

# ── Test 2: slow_api is NOT set for cloud providers ─────────────────
{
    my @cloud_providers = ('openai', 'anthropic', 'google', 'openrouter');
    for my $p (@cloud_providers) {
        my $cfg = build_endpoint_config($p, 'test-key');
        ok(!defined $cfg->{slow_api} || !$cfg->{slow_api},
            "build_endpoint_config does NOT set slow_api for $p");
    }
}

# ── Test 3: route_timeout is propagated for route-based providers ───
{
    my @route_providers = ('openrouter', 'orca');
    for my $p (@route_providers) {
        my $cfg = build_endpoint_config($p, 'test-key');
        ok($cfg->{route_timeout} == 1,
            "build_endpoint_config propagates route_timeout for $p");
    }
}

# ── Test 4: route_timeout is NOT set for non-route providers ────────
{
    my @non_route = ('openai', 'anthropic', 'llama.cpp', 'google');
    for my $p (@non_route) {
        my $cfg = build_endpoint_config($p, 'test-key');
        ok(!defined $cfg->{route_timeout} || !$cfg->{route_timeout},
            "build_endpoint_config does NOT set route_timeout for $p");
    }
}

# ── Test 5: Provider definitions still carry the flags ──────────────
{
    my $sam_def = get_provider('sam');
    ok($sam_def->{slow_api} == 1, "Provider definition has slow_api=1 for sam");

    my $llama_def = get_provider('llama.cpp');
    ok($llama_def->{slow_api} == 1, "Provider definition has slow_api=1 for llama.cpp");

    my $lmstudio_def = get_provider('lmstudio');
    ok($lmstudio_def->{slow_api} == 1, "Provider definition has slow_api=1 for lmstudio");

    my $openrouter_def = get_provider('openrouter');
    ok($openrouter_def->{route_timeout} == 1, "Provider definition has route_timeout=1 for openrouter");

    my $orca_def = get_provider('orca');
    ok($orca_def->{route_timeout} == 1, "Provider definition has route_timeout=1 for orca");
}

# ── Test 6: Timeout tier lookup is consistent ───────────────────────
# Verify that the timeout selection logic in APIManager would pick the
# correct value based on the propagated flags.
{
    my $cloud_timeout = 90;
    my $route_timeout = 120;
    my $slow_timeout  = 600;

    # Simulate APIManager's timeout selection logic
    my sub check_timeout {
        my ($endpoint_config) = @_;
        return $endpoint_config->{slow_api} ? $slow_timeout
             : $endpoint_config->{route_timeout} ? $route_timeout
             : $cloud_timeout;
    }

    my $llama_cfg = build_endpoint_config('llama.cpp', 'key');
    is(check_timeout($llama_cfg), 600,
        "llama.cpp selects slow_timeout (600s)");

    my $openrouter_cfg = build_endpoint_config('openrouter', 'key');
    is(check_timeout($openrouter_cfg), 120,
        "openrouter selects route_timeout (120s)");

    my $openai_cfg = build_endpoint_config('openai', 'key');
    is(check_timeout($openai_cfg), 90,
        "openai selects cloud_timeout (90s)");

    my $anthropic_cfg = build_endpoint_config('anthropic', 'key');
    is(check_timeout($anthropic_cfg), 90,
        "anthropic selects cloud_timeout (90s)");
}

done_testing();
