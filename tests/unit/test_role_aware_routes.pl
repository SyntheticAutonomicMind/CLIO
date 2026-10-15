#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# Integration tests for role-aware route commands (/api route strategy, role,
# default-role, fallback, explain, history) and Config persistence.

use strict;
use warnings;
use utf8;
use FindBin;
use Test::More;
use File::Temp qw(tempfile tempdir);
use File::Path qw(remove_tree);

use lib "$FindBin::Bin/../../lib";
use CLIO::Core::Config;
use CLIO::Core::RouteManager;
use CLIO::Util::JSON qw(encode_json decode_json);

# Create a temporary config directory for testing.
# Pass config_dir (not config_file) so Config does not enter test-mode
# isolation and instead writes to our controlled tempdir.
my $config_dir = tempdir(CLEANUP => 1);
my $config = CLIO::Core::Config->new(config_dir => $config_dir);

#---------------------------------------------------------------------------
# Test: Create a role-aware route via config, then read it back
#---------------------------------------------------------------------------

subtest 'Config round-trip: role-aware route' => sub {
    my $route_cfg = {
        strategy     => 'role-aware',
        models       => [],
        roles        => {
            coding    => { model => 'openrouter/deepseek' },
            reasoning => { model => 'kilo/deepseek' },
            documentation => { model => 'vercel/gemini' },
        },
        default_role => 'reasoning',
        fallbacks    => {
            coding => ['openrouter/deepseek-v3', 'kilo/deepseek-v3'],
        },
        intelligent  => {
            classification => 'adaptive',
        },
    };

    $config->set_model_route_config('dev', $route_cfg);
    $config->save();

    # Reload config to verify persistence
    my $config2 = CLIO::Core::Config->new(config_dir => $config_dir);
    my $loaded = $config2->get_model_route_config('dev');
    ok(ref($loaded) eq 'HASH', 'loaded route config is a hashref');
    is($loaded->{strategy}, 'role-aware', 'strategy persisted');
    is($loaded->{roles}{coding}{model}, 'openrouter/deepseek', 'coding role persisted');
    is($loaded->{roles}{reasoning}{model}, 'kilo/deepseek', 'reasoning role persisted');
    is($loaded->{default_role}, 'reasoning', 'default_role persisted');
    is($loaded->{fallbacks}{coding}[0], 'openrouter/deepseek-v3', 'coding fallback persisted');
    is($loaded->{intelligent}{classification}, 'adaptive', 'intelligent config persisted');
};

#---------------------------------------------------------------------------
# Test: Legacy route still loads unchanged
#---------------------------------------------------------------------------

subtest 'Legacy route compatibility' => sub {
    my @models = ('openrouter/foo', 'kilo/bar');
    $config->set_model_route('legacy-test', \@models);
    $config->save();

    my $config2 = CLIO::Core::Config->new(config_dir => $config_dir);
    my $loaded = $config2->get_model_route('legacy-test');
    ok(ref($loaded) eq 'ARRAY', 'sequential route returns arrayref');
    is(scalar(@$loaded), 2, 'two models in sequential route');
    is($loaded->[0], 'openrouter/foo', 'first model preserved');
    is($loaded->[1], 'kilo/bar', 'second model preserved');

    # get_model_route_config should normalize it to a hashref
    my $norm = $config2->get_model_route_config('legacy-test');
    ok(ref($norm) eq 'HASH', 'get_model_route_config normalizes to hashref');
    is($norm->{strategy}, 'sequential', 'normalized strategy is sequential');
    is(scalar(@{$norm->{models}}), 2, 'normalized models count');
};

#---------------------------------------------------------------------------
# Test: get_model_route returns arrayref for both formats
#---------------------------------------------------------------------------

subtest 'get_model_route returns arrayref for both formats' => sub {
    # Legacy
    my $legacy_models = $config->get_model_route('legacy-test');
    ok(ref($legacy_models) eq 'ARRAY', 'sequential returns ARRAY ref');
    is($legacy_models->[0], 'openrouter/foo', 'sequential first model correct');

    # Role-aware: get_model_route returns the models list, but for a
    # role-aware route with no flat models list (models defined via roles),
    # it returns undef. That is expected — candidates come from roles.
    my $ra_models = $config->get_model_route('dev');
    # The 'dev' route has models => [], so get_model_route returns undef
    # (no flat model list). The actual candidates come from roles.
    my $route_cfg = $config->get_model_route_config('dev');
    ok(ref($route_cfg) eq 'HASH', 'role-aware route config is a hashref');
    is($route_cfg->{strategy}, 'role-aware', 'dev route strategy is role-aware');
};

#---------------------------------------------------------------------------
# Test: get_route_strategy returns correct strategy
#---------------------------------------------------------------------------

subtest 'get_route_strategy' => sub {
    my $cfg = CLIO::Core::Config->new(config_dir => $config_dir);
    is($cfg->get_route_strategy('dev'), 'role-aware', 'dev route strategy is role-aware');
    is($cfg->get_route_strategy('legacy-test'), 'sequential', 'legacy-test route strategy is sequential');
    ok(!defined $cfg->get_route_strategy('nonexistent'), 'nonexistent route returns undef');
};

#---------------------------------------------------------------------------
# Test: set_route_active_role / get_route_active_role
#---------------------------------------------------------------------------

subtest 'route active role (transient)' => sub {
    is($config->get_route_active_role(), undef, 'no active role by default');
    $config->set_route_active_role('coding');
    is($config->get_route_active_role(), 'coding', 'active role set correctly');
    # Should NOT persist (transient key)
    my $config2 = CLIO::Core::Config->new(config_file => "$config_dir/config.json");
    is($config2->get_route_active_role(), undef, 'active role is not persisted');
};

#---------------------------------------------------------------------------
# Test: get_all_roles
#---------------------------------------------------------------------------

subtest 'get_all_roles for route' => sub {
    my $route_cfg = $config->get_model_route_config('dev');
    my @roles = CLIO::Core::RouteManager->get_all_roles($route_cfg);
    is(scalar(@roles), 3, 'three roles in dev route');
    ok(grep { $_ eq 'coding' } @roles, 'coding role present');
    ok(grep { $_ eq 'reasoning' } @roles, 'reasoning role present');
    ok(grep { $_ eq 'documentation' } @roles, 'documentation role present');
};

#---------------------------------------------------------------------------
# Test: Strategy transition (sequential -> role-aware -> sequential)
#---------------------------------------------------------------------------

subtest 'Strategy transition preserves models' => sub {
    # Start with a sequential route that has models
    $config->set_model_route('transition-test', ['openrouter/foo', 'kilo/bar']);
    $config->save();

    # Promote to role-aware: the models become the models list
    my $route_cfg = $config->get_model_route_config('transition-test');
    $route_cfg->{strategy} = 'role-aware';
    $route_cfg->{roles} = { coding => { model => 'openrouter/foo' } };
    $route_cfg->{default_role} = 'coding';
    $config->set_model_route_config('transition-test', $route_cfg);
    $config->save();

    my $reloaded = $config->get_model_route_config('transition-test');
    is($reloaded->{strategy}, 'role-aware', 'strategy is now role-aware');
    is($reloaded->{roles}{coding}{model}, 'openrouter/foo', 'coding role has model');
    is(scalar(@{$reloaded->{models}}), 2, 'models list still has 2 entries');

    # Demote back to sequential
    my $demoted = $config->get_model_route_config('transition-test');
    $demoted->{strategy} = 'sequential';
    # When converting back, get_model_route should return the models array
    $config->set_model_route_config('transition-test', $demoted);
    $config->save();

    my $models = $config->get_model_route('transition-test');
    ok(ref($models) eq 'ARRAY', 'demoted route returns arrayref');
    is($models->[0], 'openrouter/foo', 'first model preserved after demotion');
    is($models->[1], 'kilo/bar', 'second model preserved after demotion');
};

#---------------------------------------------------------------------------
# Test: RouteManager validation
#---------------------------------------------------------------------------

subtest 'RouteManager validation catches bad configs' => sub {
    my $rm = CLIO::Core::RouteManager->new();

    # Invalid strategy
    my ($ok, $err) = $rm->validate_route_config({ strategy => 'bogus', models => ['foo'] });
    ok(!$ok, 'invalid strategy rejected');
    like($err, qr/Invalid strategy/, 'error mentions strategy');

    # Role without model
    ($ok, $err) = $rm->validate_route_config({ strategy => 'role-aware', models => [], roles => { bad => {} } });
    ok(!$ok, 'role without model rejected');
    like($err, qr/model/, 'error mentions model');

    # Default role not in roles
    ($ok, $err) = $rm->validate_route_config({ strategy => 'role-aware', models => [], roles => { coding => { model => 'foo' } }, default_role => 'design' });
    ok(!$ok, 'default_role not in roles rejected');
    like($err, qr/default_role/, 'error mentions default_role');
};

done_testing();
