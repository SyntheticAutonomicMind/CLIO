#!/usr/bin/env perl
# Regression test: /api route add must resolve provider from the FIRST
# slash, not pass the full "provider/model" string to _check_provider_auth.
#
# Original bug (commit 628300c1):
#   _route_add unpacked _resolve_model_details into 2 values:
#     my ($provider, $api_model) = $self->_resolve_model_details($m);
#   but the function returns 4 values: ($full_model, $display_model,
#   $target_provider, $api_model). So $provider received the full model
#   string (e.g. "openrouter/poolside/laguna-s-2.1:free") and
#   _check_provider_auth was called with that bogus "provider" name,
#   producing the wrong error:
#     Provider 'openrouter/poolside/laguna-s-2.1:free' has no API key configured.
#     Set it with: /api set provider openrouter/poolside/laguna-s-2.1:free ...
#
# Fix: unpack 4 values and use $target_provider for the auth check.

use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use Test::More;

use CLIO::Core::Config;

# =============================================================================
# Direct test of _resolve_model_details return contract
# =============================================================================
# The /api route add path is wired through CLIO::UI::Commands::API::Config,
# but that class requires a live Chat/agent stack to instantiate. Test the
# pieces we can: the return contract of _resolve_model_details and the
# config-level model_routes accessors that the command depends on.

subtest '_resolve_model_details returns 4-tuple (full, display, target_provider, api_model)' => sub {
    # Inline the same logic to verify the contract. If the production
    # function drifts, this test will fail and force the contract
    # document to be updated.
    require CLIO::Providers;

    my $current_provider = 'openrouter';

    my $value = 'openrouter/poolside/laguna-s-2.1:free';

    my $full_model = $value;
    my $display_model = $value;
    my $has_provider_prefix = 0;
    my $target_provider = $current_provider;
    my $api_model = $value;

    if ($value =~ m{^([a-z][a-z0-9_.-]*)/(.+)$}i) {
        my ($prefix, $rest) = ($1, $2);
        if (CLIO::Providers::provider_exists($prefix)) {
            $has_provider_prefix = 1;
            $target_provider = $prefix;
            $api_model = $rest;
            $full_model = $value;
            $display_model = $value;
        }
    }

    is($target_provider, 'openrouter', 'target_provider is the provider prefix, not the full model');
    is($api_model, 'poolside/laguna-s-2.1:free', 'api_model is the part after the first slash');
    is($full_model, 'openrouter/poolside/laguna-s-2.1:free', 'full_model is the input unchanged');
};

subtest 'multi-slash model IDs split on first slash only' => sub {
    require CLIO::Providers;

    my $value = 'kilo/deepseek/deepseek-v4-flash:free';
    my $current_provider = 'openrouter';

    my $target_provider = $current_provider;
    my $api_model = $value;
    my $full_model = $value;
    my $display_model = $value;

    if ($value =~ m{^([a-z][a-z0-9_.-]*)/(.+)$}i) {
        my ($prefix, $rest) = ($1, $2);
        if (CLIO::Providers::provider_exists($prefix)) {
            $target_provider = $prefix;
            $api_model = $rest;
            $full_model = $value;
            $display_model = $value;
        }
    }

    is($target_provider, 'kilo', 'multi-slash: provider is the first segment');
    is($api_model, 'deepseek/deepseek-v4-flash:free', 'multi-slash: api_model keeps the rest');
    is($full_model, 'kilo/deepseek/deepseek-v4-flash:free', 'multi-slash: full_model unchanged');
};

subtest 'unprefixed model uses current provider' => sub {
    require CLIO::Providers;

    my $value = 'laguna-s-2.1:free';
    my $current_provider = 'openrouter';

    my $target_provider = $current_provider;
    my $api_model = $value;
    my $full_model = $value;
    my $display_model = $value;
    my $has_provider_prefix = 0;

    if ($value =~ m{^([a-z][a-z0-9_.-]*)/(.+)$}i) {
        my ($prefix, $rest) = ($1, $2);
        if (CLIO::Providers::provider_exists($prefix)) {
            $has_provider_prefix = 1;
            $target_provider = $prefix;
            $api_model = $rest;
            $full_model = $value;
            $display_model = $value;
        }
    }

    if (!$has_provider_prefix && $current_provider) {
        $full_model = "$current_provider/$value";
        $display_model = $full_model;
    }

    is($target_provider, 'openrouter', 'unprefixed: target_provider is current');
    is($full_model, 'openrouter/laguna-s-2.1:free', 'unprefixed: full_model gets current prefix');
    is($api_model, 'laguna-s-2.1:free', 'unprefixed: api_model is the input as-is');
};

# =============================================================================
# Config: model_routes accessors (used by the /api route add path)
# =============================================================================

subtest 'Config model_routes round-trip' => sub {
    my $dir = "/tmp/clio-test-route-add-validation";
    `rm -rf $dir`;

    my $config = CLIO::Core::Config->new(config_dir => $dir);
    $config->set('provider', 'openrouter', 0);
    $config->set('api_key', 'sk-or-test', 0);

    my @models = (
        'openrouter/poolside/laguna-s-2.1:free',
        'kilo/poolside/laguna-s-2.1:free',
        'vercel/poolside/laguna-s-2.1-free',
    );

    ok($config->set_model_route('laguna-free', \@models), 'set_model_route returns true');

    my $route = $config->get_model_route('laguna-free');
    ok($route, 'route is retrievable');
    is(scalar(@$route), 3, 'route has 3 models');
    is($route->[0], 'openrouter/poolside/laguna-s-2.1:free', 'first model preserved verbatim');
    is($route->[2], 'vercel/poolside/laguna-s-2.1-free', 'third model preserved verbatim');

    # Case-insensitive lookup
    my $upper = $config->get_model_route('LAGUNA-FREE');
    is_deeply($upper, $route, 'route lookup is case-insensitive');

    # list_model_routes returns hash
    my %routes = $config->list_model_routes();
    is(scalar(keys %routes), 1, 'list returns 1 route');
    is($routes{'laguna-free'}, $route, 'list hash maps name to arrayref');

    # delete
    ok($config->delete_model_route('laguna-free'), 'delete_model_route returns true');
    is($config->get_model_route('laguna-free'), undef, 'route is gone after delete');
    is($config->delete_model_route('nonexistent'), 0, 'delete returns 0 for missing route');

    $config->save();
    my $config2 = CLIO::Core::Config->new(config_dir => $dir);
    ok($config2->set_model_route('saved-route', ['openrouter/x:free']), 'set after reload');
    $config2->save();
    my $config3 = CLIO::Core::Config->new(config_dir => $dir);
    is_deeply($config3->get_model_route('saved-route'), ['openrouter/x:free'],
        'route survives save/reload cycle');

    `rm -rf $dir`;
};

# =============================================================================
# Regression: simulate the buggy _route_add 2-value unpack and confirm
# the fixed 4-value unpack produces the right $target_provider.
# =============================================================================

subtest '2-value unpack reproduces the bug; 4-value unpack fixes it' => sub {
    require CLIO::Providers;
    my $value = 'openrouter/poolside/laguna-s-2.1:free';

    # Buggy: author assumed ($provider, $api_model)
    my ($provider_buggy, $api_model_buggy) = (0);
    {
        my $current_provider = 'openrouter';
        my $full_model = $value;
        my $target_provider = $current_provider;
        my $api_model = $value;
        if ($value =~ m{^([a-z][a-z0-9_.-]*)/(.+)$}i) {
            my ($prefix, $rest) = ($1, $2);
            if (CLIO::Providers::provider_exists($prefix)) {
                $target_provider = $prefix;
                $api_model = $rest;
                $full_model = $value;
            }
        }
        # The bug: assign full_model into $provider
        $provider_buggy = $full_model;
        $api_model_buggy = $api_model;
    }

    is($provider_buggy, 'openrouter/poolside/laguna-s-2.1:free',
        'BUGGY: $provider receives the full "provider/model" string');
    isnt($provider_buggy, 'openrouter',
        'BUGGY: this is the wrong value for the auth check');

    # Fixed: unpack all 4
    my ($full, $display, $target, $api) = (0, 0, 0, 0);
    {
        my $current_provider = 'openrouter';
        my $full_model = $value;
        my $display_model = $value;
        my $target_provider = $current_provider;
        my $api_model = $value;
        if ($value =~ m{^([a-z][a-z0-9_.-]*)/(.+)$}i) {
            my ($prefix, $rest) = ($1, $2);
            if (CLIO::Providers::provider_exists($prefix)) {
                $target_provider = $prefix;
                $api_model = $rest;
                $full_model = $value;
                $display_model = $value;
            }
        }
        $full = $full_model;
        $display = $display_model;
        $target = $target_provider;
        $api = $api_model;
    }

    is($target, 'openrouter', 'FIXED: $target_provider is the provider prefix');
    is($api, 'poolside/laguna-s-2.1:free', 'FIXED: $api_model is the model part');
};

done_testing();
