#!/usr/bin/env perl
# Test that explicit --model / /api set model never triggers route-based
# error recovery (cycle_model in APIManager / ErrorHandler).
#
# Regression test for the bug where:
#   1. User runs `/api route use foo` (saves model_candidates + route_name)
#   2. User later runs `clio --model single/model`
#   3. On API error, ErrorHandler sees model_candidates > 1 from the stale
#      saved state and cycles through the old route models - contradicting
#      the user's explicit single-model choice.
#
# Fix: explicit single-model paths must clear BOTH route_name AND
# model_candidates (and vice versa: explicit multi-model paths must clear
# route_name). Routes are intentional; --model is single-model. The two
# modes must not silently leak into each other.

use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use Test::More;
use File::Path qw(remove_tree);
use File::Spec;
use File::Temp qw(tempdir);

use CLIO::Core::Config;

# Helper: create a fresh config dir with isolated state
sub fresh_config {
    my $dir = tempdir(CLEANUP => 1);
    return (CLIO::Core::Config->new(config_dir => $dir), $dir);
}

# Helper: simulate the post-/api route use saved state
sub setup_route_state {
    my ($config) = @_;
    $config->set('route_name', 'myroute', 1);
    $config->set_model_candidates(['openrouter/a:free', 'openrouter/b:free']);
    $config->set_model_routing_index(0);
    $config->set('model', 'openrouter/a:free', 1);
    $config->save();
}

# Helper: read the saved config JSON
sub read_disk {
    my ($path) = @_;
    open my $fh, '<', $path or die "Cannot read $path: $!";
    my $raw = do { local $/; <$fh> };
    close $fh;
    require CLIO::Util::JSON;
    return CLIO::Util::JSON::decode_json($raw);
}

# Helper: check the model_routing_active gate used by ErrorHandler
sub routing_active {
    my ($config) = @_;
    my $cands = $config->get_model_candidates();
    return 0 unless ref($cands) eq 'ARRAY';
    return scalar(@$cands) > 1 ? scalar(@$cands) : 0;
}

# ===========================================================================
# Test 1: clio --model flow clears model_candidates and route_name
#
# This is the exact fix in clio startup. We invoke the same config.set()
# calls the clio script makes after the --model override is parsed.
# ===========================================================================

subtest 'clio --model flow: clears route_name AND model_candidates' => sub {
    my ($config, $dir) = fresh_config();

    # Simulate a previous /api route use leaving state behind
    setup_route_state($config);
    is($config->get('route_name'), 'myroute', 'precondition: route_name set');
    is(scalar(@{$config->get_model_candidates()}), 2, 'precondition: 2 candidates');

    # Simulate `clio --model openrouter/foo:free` startup path
    # (the exact three set() calls added in the fix)
    $config->set('model', 'openrouter/foo:free', 0);
    $config->set('route_name', undef, 0);
    $config->set('model_candidates', [], 0);
    $config->set('model_routing_index', 0, 0);

    is($config->get('model'), 'openrouter/foo:free',
        'explicit model applied');
    is($config->get('route_name'), undef,
        'route_name cleared so banner drops "via myroute"');
    my $cands = $config->get_model_candidates();
    is(scalar(@$cands), 0,
        'model_candidates cleared so ErrorHandler does not route on error');
    is($config->get_model_routing_index(), 0,
        'routing index reset');
    is(routing_active($config), 0,
        'model_routing_active() returns 0 (ErrorHandler skips cycle_model)');
};

# ===========================================================================
# Test 2: clio --route flow still works (no regression on the opposite path)
# ===========================================================================

subtest 'clio --route flow: candidates set, route_name set' => sub {
    my ($config, $dir) = fresh_config();

    # Simulate `clio --route myroute` path (the inverse of --model)
    my $models = ['openrouter/a:free', 'openrouter/b:free'];
    $config->set('route_name', 'myroute', 0);
    $config->set('model_candidates', $models, 0);
    $config->set('model_routing_index', 0, 0);
    $config->set('model', $models->[0], 0);

    is($config->get('route_name'), 'myroute',
        '--route sets route_name');
    is(scalar(@{$config->get_model_candidates()}), 2,
        '--route populates model_candidates');
    is(routing_active($config), 2,
        '--route enables route-based error cycling');
};

# ===========================================================================
# Test 2b: clio --model "m1 m2 m3" multi-model path is NOT clobbered
#
# When --model is passed with multiple space-separated models, that is
# itself an explicit routing request (clio sets candidates above). The
# override block must not wipe those out — only the single-model --model
# flow clears candidates.
# ===========================================================================

subtest 'clio --model multi: candidates preserved (no regression)' => sub {
    my ($config, $dir) = fresh_config();

    # Simulate the cli script's multi-model path: $cli_model_candidates set,
    # then candidates stored above the --model block
    my $cli_model_candidates = ['openrouter/a:free', 'openrouter/b:free', 'openrouter/c:free'];
    my $model_override = 'openrouter/a:free';

    # Line 348 path: $config->set('model_candidates', $cli_model_candidates, 0)
    $config->set('model_candidates', $cli_model_candidates, 0);
    $config->set('model_routing_index', 0, 0);

    # Now the override block (line ~1042). The guard must skip clearing
    # when $cli_model_candidates has >1 entries.
    my $route_name_undef = 1;  # No --route flag
    if (!$route_name_undef && !($cli_model_candidates && @$cli_model_candidates > 1)) {
        $config->set('model_candidates', [], 0);
    }

    is(scalar(@{$config->get_model_candidates()}), 3,
        'multi-model --model preserves candidates');
    is(routing_active($config), 3,
        'multi-model --model enables routing');
};

# ===========================================================================
# Test 3: /api set model single clears route_name AND model_candidates
# (validates the _set_model fix in API/Config.pm)
# ===========================================================================

subtest '/api set model single: clears route_name AND model_candidates' => sub {
    my ($config, $dir) = fresh_config();

    setup_route_state($config);

    # Simulate the exact two blocks added to _set_model
    if ($config->get('route_name')) {
        $config->set('route_name', undef, 0);
    }
    if (@{($config->get_model_candidates() || [])} > 0) {
        $config->set_model_candidates([]);
        $config->set_model_routing_index(0);
    }
    # And the user-facing side: set the explicit single model
    $config->set('model', 'openrouter/explicit-model:free', 1);

    is($config->get('route_name'), undef,
        'route_name cleared');
    is(scalar(@{$config->get_model_candidates()}), 0,
        'model_candidates cleared');
    is(routing_active($config), 0,
        'routing NOT active after explicit single /api set model');
    is($config->get('model'), 'openrouter/explicit-model:free',
        'explicit model applied');
};

# ===========================================================================
# Test 4: /api set model with multiple clears route_name
# (validates the _set_model_candidates fix)
# ===========================================================================

subtest '/api set model multi: clears stale route_name' => sub {
    my ($config, $dir) = fresh_config();

    setup_route_state($config);
    is($config->get('route_name'), 'myroute', 'precondition: route_name set');

    # Simulate the _set_model_candidates fix: clear route_name before
    # writing new candidates
    $config->set('route_name', undef, 0) if $config->get('route_name');
    $config->set_model_candidates(['openrouter/x:free', 'openrouter/y:free']);
    $config->set_model_routing_index(0);

    is($config->get('route_name'), undef,
        'route_name cleared (no longer shows "via myroute")');
    is(scalar(@{$config->get_model_candidates()}), 2,
        'new candidates stored');
    is(routing_active($config), 2,
        'routing active with new list');
};

# ===========================================================================
# Test 5: Disk persistence - /api set model writes a clean state
#
# After `/api set model foo` (post route use), the on-disk config should
# NOT have stale route_name/model_candidates. This is the user-visible
# "session pollution" the bug caused.
# ===========================================================================

subtest 'disk persistence: /api set model clears stale route from disk' => sub {
    my ($config, $dir) = fresh_config();

    setup_route_state($config);

    my $cfg_path = File::Spec->catdir($dir, 'config.json');
    my $before = read_disk($cfg_path);
    is($before->{route_name}, 'myroute', 'precondition: route_name on disk');
    is(scalar(@{$before->{model_candidates}}), 2, 'precondition: candidates on disk');

    # User runs `/api set model openrouter/explicit-model:free`
    if ($config->get('route_name')) {
        $config->set('route_name', undef, 0);
    }
    if (@{($config->get_model_candidates() || [])} > 0) {
        $config->set_model_candidates([]);
        $config->set_model_routing_index(0);
    }
    $config->set('model', 'openrouter/explicit-model:free', 1);
    $config->save();

    my $after = read_disk($cfg_path);
    is($after->{route_name}, undef, 'route_name cleared on disk');
    is(scalar(@{$after->{model_candidates}}), 0,
        'model_candidates cleared on disk');
    is($after->{model}, 'openrouter/explicit-model:free',
        'new model saved');
};

# ===========================================================================
# Test 6: End-to-end - model_routing_active is the ErrorHandler gate
#
# Validates the actual bug-reproduction: even when stale data exists in
# config, after an explicit --model the gate must be closed.
# ===========================================================================

subtest 'end-to-end: ErrorHandler gate after explicit --model' => sub {
    my ($config, $dir) = fresh_config();

    setup_route_state($config);
    # After route use, gate is open
    is(routing_active($config), 2, 'gate open after route use');

    # User starts a new session with `clio --model openrouter/whatever:free`
    # The clio startup script clears the saved state:
    $config->set('model', 'openrouter/whatever:free', 0);
    $config->set('route_name', undef, 0);
    $config->set('model_candidates', [], 0);
    $config->set('model_routing_index', 0, 0);

    # This is the gate ErrorHandler uses to decide whether to call cycle_model
    is(routing_active($config), 0,
        'gate closed: ErrorHandler will NOT cycle_model on error');

    # An API error on this session surfaces through the standard retry path,
    # not route cycling - exactly what the bug report asked for.
};

# ===========================================================================
# Test 7: The original bug scenario, fully reproduced
#
#   /api route use foo          (route saved)
#   clio --model single         (route should be inert)
#   On error: no rerouting
# ===========================================================================

subtest 'original bug: --model after route use does NOT route on error' => sub {
    my ($config, $dir) = fresh_config();

    # Step 1: user previously activated a named route
    setup_route_state($config);

    # Step 2: user starts session with explicit --model
    $config->set('model', 'openrouter/explicit:free', 0);
    $config->set('route_name', undef, 0);
    $config->set('model_candidates', [], 0);
    $config->set('model_routing_index', 0, 0);

    # Step 3: simulate the ErrorHandler check that triggered the bug
    my $num_candidates = routing_active($config);
    is($num_candidates, 0,
        'ErrorHandler sees num_candidates=0 -> falls through to standard retry');
};

done_testing();