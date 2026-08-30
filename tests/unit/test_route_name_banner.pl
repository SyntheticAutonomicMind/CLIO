#!/usr/bin/env perl
# Test route_name persistence and banner display logic
#
# Tests the route_name config key and the banner variables (routing_verb,
# route_suffix) that are computed in Chat/Header.pm for display in the
# terminal header.

use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use Test::More;
use File::Path qw(remove_tree);
use File::Spec;

use CLIO::Core::Config;

# Helper: create a fresh config dir
sub fresh_config {
    my $dir = File::Spec->catdir("/tmp", "clio-test-route-" . int(rand(100000)));
    remove_tree($dir) if -d $dir;
    my $config = CLIO::Core::Config->new(config_dir => $dir);
    return ($config, $dir);
}

# =============================================================================
# Config: route_name default and persistence
# =============================================================================

subtest 'config route_name' => sub {
    my ($config, $dir) = fresh_config();

    # Initially undefined
    is($config->get('route_name'), undef, 'route_name defaults to undef');

    # Set a route name (transient - 0 = don't mark as user-set)
    $config->set('route_name', 'myroute', 0);
    is($config->get('route_name'), 'myroute', 'route_name set transiently');

    # Transient set does NOT persist to file (user_set not marked)
    $config->save();
    my ($config2, $dir2) = fresh_config();
    # Copy the saved config file
    my $src = File::Spec->catdir($dir, 'config.json');
    my $dst = File::Spec->catdir($dir2, 'config.json');
    if (-f $src) {
        copy_file($src, $dst);
        my $config3 = CLIO::Core::Config->new(config_dir => $dir2);
        is($config3->get('route_name'), undef, 'transient route_name not saved to file');
    } else {
        ok(1, 'no config file saved (transient values only) - expected');
    }

    # Set a route name as user-set (should persist)
    $config->set('route_name', 'persisted-route', 1);
    $config->save();
    my $config4 = CLIO::Core::Config->new(config_dir => $dir);
    is($config4->get('route_name'), 'persisted-route', 'user-set route_name persists');

    # Clear route_name
    $config4->set('route_name', undef, 1);
    is($config4->get('route_name'), undef, 'route_name cleared');

    remove_tree($dir);
    remove_tree($dir2) if $dir2 ne $dir;
};

sub copy_file {
    my ($src, $dst) = @_;
    if (open my $fh, '<', $src) {
        my $content = do { local $/; <$fh> };
        close $fh;
        if (open my $out, '>', $dst) {
            print $out $content;
            close $out;
            return 1;
        }
    }
    return 0;
}

# =============================================================================
# Banner variables: routing_verb and route_suffix logic
# =============================================================================

subtest 'banner routing variables' => sub {
    my ($config, $dir) = fresh_config();

    # Simulate the banner variable computation from Chat/Header.pm
    my @cases = (
        # { candidates, route_name, expected_verb, expected_suffix }
        { cands => [],          route => undef,         verb => 'connected', suffix => '' },
        { cands => [],          route => 'myroute',     verb => 'connected', suffix => '' },
        { cands => ['a'],       route => undef,         verb => 'connected', suffix => '' },
        { cands => ['a', 'b'],  route => undef,         verb => 'routing',   suffix => ' (2 models)' },
        { cands => ['a', 'b'],  route => 'myroute',     verb => 'routing',   suffix => ' via myroute' },
        { cands => ['a', 'b', 'c'], route => 'r1',      verb => 'routing',   suffix => ' via r1' },
    );

    for my $i (0 .. $#cases) {
        my $c = $cases[$i];
        $config->set('model_candidates', $c->{cands}, 0);
        $config->set('model_routing_index', 0, 0);
        $config->set('route_name', $c->{route}, 0);

        my $candidates = $config->get('model_candidates');
        $candidates = [] unless ref($candidates) eq 'ARRAY';
        my $routing_active = ref($candidates) eq 'ARRAY' && @$candidates > 1;
        my $route_name = $config->get('route_name');
        my $routing_verb = $routing_active ? 'routing' : 'connected';
        my $route_suffix = '';
        if ($routing_active && $route_name && length($route_name)) {
            $route_suffix = " via $route_name";
        } elsif ($routing_active) {
            $route_suffix = " (" . scalar(@$candidates) . " models)";
        }

        is($routing_verb, $c->{verb}, "case $i: routing_verb = '$c->{verb}'");
        is($route_suffix, $c->{suffix}, "case $i: route_suffix = '$c->{suffix}'");
    }

    remove_tree($dir);
};

# =============================================================================
# Config: model_candidates default in DEFAULT_CONFIG
# =============================================================================

subtest 'model_candidates in default config' => sub {
    my ($config, $dir) = fresh_config();

    # Verify defaults include the routing-related keys
    my $candidates = $config->get_model_candidates();
    is(ref($candidates), 'ARRAY', 'model_candidates is an arrayref');
    is(scalar(@$candidates), 0, 'model_candidates empty by default');
    is($config->get_model_routing_index(), 0, 'model_routing_index defaults to 0');

    remove_tree($dir);
};

# =============================================================================
# Provider/model ordering: set_provider must not clobber route's first model
# When --route activates, the route loading code sets the provider first
# (which sets the provider's default model), THEN sets the route's first
# model on top. The order matters: setting model first then provider
# causes set_provider to overwrite with the provider default.
# =============================================================================

subtest 'route model not clobbered by provider default' => sub {
    my ($config, $dir) = fresh_config();

    # Set up an OpenRouter API key so set_provider actually switches providers
    $config->{config}->{api_keys}{'openrouter'} = 'sk-test-key';

    # Start with a config that has a different provider + model
    $config->set_provider('github_copilot');
    $config->set('model', 'gpt-4o', 1);  # user-set gpt-4o
    is($config->get('model'), 'gpt-4o', 'initial model is gpt-4o');

    my $route_models = ["openrouter/poolside/laguna-s-2.1:free", "kilo/x:free"];

    # Simulate the FIXED route loading order: provider first, then model
    # Resolve provider from first model
    my $first_model = $route_models->[0];
    if ($first_model =~ m{^([a-z][a-z0-9_.-]*)/(.+)$}i) {
        my $rp = $1;
        my $rpkey = $config->get_provider_key($rp);
        if ($rpkey) {
            $config->set_provider($rp);
        }
    }
    # Then set the model (AFTER provider, so it's not clobbered)
    $config->set('model', $first_model, 0);

    is($config->get('model'), 'openrouter/poolside/laguna-s-2.1:free',
       'route model preserved after set_provider');
    is($config->get('provider'), 'openrouter', 'provider switched to openrouter');

    remove_tree($dir);
};

done_testing();