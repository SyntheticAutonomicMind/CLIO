#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# Tests for CLIO::Core::RouteManager — role-aware route normalization,
# role resolution, candidate selection, and validation.

use strict;
use warnings;
use utf8;
use Test::More;
use CLIO::Core::RouteManager;

# We don't need a live APIManager for most tests. For classification tests
# that need LLM, we skip or mock.

#---------------------------------------------------------------------------
# normalize_route
#---------------------------------------------------------------------------

subtest 'normalize_route: sequential arrayref' => sub {
    my $raw = ['openrouter/foo', 'kilo/bar'];
    my $norm = CLIO::Core::RouteManager->normalize_route($raw);
    is($norm->{strategy}, 'sequential', 'sequential strategy');
    is(scalar(@{$norm->{models}}), 2, 'two models');
    is($norm->{models}[0], 'openrouter/foo', 'first model preserved');
    is($norm->{models}[1], 'kilo/bar', 'second model preserved');
};

subtest 'normalize_route: extended hashref' => sub {
    my $raw = {
        strategy => 'role-aware',
        models => ['openrouter/foo'],
        roles => { coding => { model => 'kilo/bar' } },
        default_role => 'coding',
    };
    my $norm = CLIO::Core::RouteManager->normalize_route($raw);
    is($norm->{strategy}, 'role-aware', 'strategy preserved');
    is($norm->{default_role}, 'coding', 'default_role preserved');
    is($norm->{roles}{coding}{model}, 'kilo/bar', 'role model preserved');
    # Ensure we got a copy, not a reference
    $norm->{strategy} = 'mutated';
    is($raw->{strategy}, 'role-aware', 'original not mutated');
};

subtest 'normalize_route: undef input' => sub {
    my $norm = CLIO::Core::RouteManager->normalize_route(undef);
    ok(!defined $norm, 'returns undef for undef input');
};

subtest 'normalize_route: fills defaults' => sub {
    my $raw = { strategy => 'role-aware' };
    my $norm = CLIO::Core::RouteManager->normalize_route($raw);
    is(ref($norm->{models}), 'ARRAY', 'default models is arrayref');
    is(scalar(@{$norm->{models}}), 0, 'default models is empty');
    is(ref($norm->{roles}), 'HASH', 'default roles is hashref');
    is(scalar(keys %{$norm->{roles}}), 0, 'default roles is empty');
    is($norm->{default_role}, 'reasoning', 'default default_role is reasoning');
};

#---------------------------------------------------------------------------
# get_strategy / is_sequential / is_role_aware
#---------------------------------------------------------------------------

subtest 'get_strategy' => sub {
    my $rm = CLIO::Core::RouteManager->new();
    is($rm->get_strategy({ strategy => 'sequential' }), 'sequential');
    is($rm->get_strategy({ strategy => 'role-aware' }), 'role-aware');
    is($rm->get_strategy({ strategy => 'intelligent' }), 'intelligent');
    is($rm->get_strategy({}), 'sequential', 'defaults to sequential');
    is($rm->get_strategy(undef), undef, 'returns undef for undef');
};

subtest 'is_sequential' => sub {
    my $rm = CLIO::Core::RouteManager->new();
    ok($rm->is_sequential({ strategy => 'sequential' }), 'sequential strategy');
    ok(!$rm->is_sequential({ strategy => 'role-aware' }), 'not sequential');
};

subtest 'is_role_aware' => sub {
    my $rm = CLIO::Core::RouteManager->new();
    ok(!$rm->is_role_aware({ strategy => 'sequential' }), 'sequential not role-aware');
    ok($rm->is_role_aware({ strategy => 'role-aware' }), 'role-aware');
    ok($rm->is_role_aware({ strategy => 'intelligent' }), 'intelligent is role-aware');
};

#---------------------------------------------------------------------------
# get_role_models / get_role_fallbacks / get_route_candidates
#---------------------------------------------------------------------------

subtest 'get_role_models' => sub {
    my $rm = CLIO::Core::RouteManager->new();
    my $cfg = {
        strategy => 'role-aware',
        roles => {
            coding    => { model => 'openrouter/deepseek' },
            reasoning => { model => 'kilo/deepseek' },
        },
    };
    is($rm->get_role_models($cfg, 'coding'), 'openrouter/deepseek');
    is($rm->get_role_models($cfg, 'reasoning'), 'kilo/deepseek');
    ok(!defined $rm->get_role_models($cfg, 'documentation'), 'missing role returns undef');
    ok(!defined $rm->get_role_models($cfg, ''), 'empty role returns undef');
};

subtest 'get_role_fallbacks' => sub {
    my $rm = CLIO::Core::RouteManager->new();
    my $cfg = {
        strategy => 'role-aware',
        roles    => { coding => { model => 'openrouter/deepseek' } },
        fallbacks => {
            coding   => ['kilo/deepseek-v3', 'vercel/deepseek-v3'],
            design   => ['openrouter/deepseek-v3'],
        },
    };
    my $fb = $rm->get_role_fallbacks($cfg, 'coding');
    is(scalar(@$fb), 2, 'two fallbacks for coding');
    is($fb->[0], 'kilo/deepseek-v3', 'first fallback');
    is($fb->[1], 'vercel/deepseek-v3', 'second fallback');

    my $empty_fb = $rm->get_role_fallbacks($cfg, 'reasoning');
    is(scalar(@$empty_fb), 0, 'no fallbacks for reasoning returns empty arrayref');
};

subtest 'get_route_candidates: role-aware' => sub {
    my $rm = CLIO::Core::RouteManager->new();
    my $cfg = {
        strategy => 'role-aware',
        models   => [],
        roles    => {
            coding => { model => 'openrouter/deepseek' },
        },
        fallbacks => {
            coding => ['kilo/deepseek', 'openrouter/deepseek'],
        },
    };
    my $cands = $rm->get_route_candidates($cfg, 'coding');
    is(scalar(@$cands), 2, 'candidates = primary + unique fallbacks');
    is($cands->[0], 'openrouter/deepseek', 'primary is first');
    is($cands->[1], 'kilo/deepseek', 'fallback is second');
    # Duplicate 'openrouter/deepseek' in fallbacks should be deduplicated
};

subtest 'get_route_candidates: sequential ignores role' => sub {
    my $rm = CLIO::Core::RouteManager->new();
    my $cfg = {
        strategy => 'sequential',
        models   => ['openrouter/foo', 'kilo/bar'],
        roles    => { coding => { model => 'kilo/bar' } },
    };
    my $cands = $rm->get_route_candidates($cfg, 'coding');
    is(scalar(@$cands), 2, 'sequential returns models list');
    is($cands->[0], 'openrouter/foo', 'sequential candidate');
};

#---------------------------------------------------------------------------
# get_all_roles / route_has_roles
#---------------------------------------------------------------------------

subtest 'get_all_roles' => sub {
    my $rm = CLIO::Core::RouteManager->new();
    my $cfg = { roles => { coding => { model => 'foo' }, design => { model => 'bar' } } };
    my @roles = $rm->get_all_roles($cfg);
    is(scalar(@roles), 2, 'two roles');
};

subtest 'route_has_roles' => sub {
    my $rm = CLIO::Core::RouteManager->new();
    ok(!$rm->route_has_roles({ roles => {} }), 'empty roles');
    ok(!$rm->route_has_roles({}), 'no roles key');
    ok($rm->route_has_roles({ roles => { coding => { model => 'foo' } } }), 'has roles');
};

#---------------------------------------------------------------------------
# resolve_role
#---------------------------------------------------------------------------

subtest 'resolve_role: sequential returns undef' => sub {
    my $rm = CLIO::Core::RouteManager->new();
    my $cfg = { strategy => 'sequential', models => ['openrouter/foo'] };
    ok(!defined $rm->resolve_role($cfg, 'write code', undef), 'sequential returns undef');
};

subtest 'resolve_role: single role returns immediately' => sub {
    my $rm = CLIO::Core::RouteManager->new();
    my $cfg = {
        strategy => 'role-aware',
        roles => { coding => { model => 'openrouter/foo' } },
        default_role => 'coding',
    };
    is($rm->resolve_role($cfg, 'fix a bug', undef), 'coding', 'single role returned without classification');
};

subtest 'resolve_role: no roles returns default' => sub {
    my $rm = CLIO::Core::RouteManager->new();
    my $cfg = {
        strategy => 'role-aware',
        roles => {},
        default_role => 'reasoning',
    };
    is($rm->resolve_role($cfg, 'do something', undef), 'reasoning', 'no roles returns default');
};

subtest 'resolve_role: rules match coding keywords' => sub {
    my $rm = CLIO::Core::RouteManager->new();
    my $cfg = {
        strategy => 'role-aware',
        roles => {
            coding    => { model => 'openrouter/foo' },
            reasoning => { model => 'kilo/bar' },
        },
        default_role => 'reasoning',
    };
    is($rm->resolve_role($cfg, 'fix the bug in the login function and add a unit test', undef), 'coding', 'coding keywords matched');
};

subtest 'resolve_role: rules match documentation keywords' => sub {
    my $rm = CLIO::Core::RouteManager->new();
    my $cfg = {
        strategy => 'role-aware',
        roles => {
            coding        => { model => 'openrouter/foo' },
            documentation => { model => 'kilo/bar' },
        },
        default_role => 'coding',
    };
    is($rm->resolve_role($cfg, 'write a README explaining how to use this library', undef), 'documentation', 'documentation keywords matched');
};

subtest 'resolve_role: rules match design keywords' => sub {
    my $rm = CLIO::Core::RouteManager->new();
    my $cfg = {
        strategy => 'role-aware',
        roles => {
            coding    => { model => 'openrouter/foo' },
            design    => { model => 'kilo/bar' },
            reasoning => { model => 'vercel/baz' },
        },
        default_role => 'reasoning',
    };
    is($rm->resolve_role($cfg, 'what are the architecture tradeoffs of this approach', undef), 'design', 'design keywords matched');
};

subtest 'resolve_role: ambiguous task falls to default' => sub {
    my $rm = CLIO::Core::RouteManager->new();
    my $cfg = {
        strategy => 'role-aware',
        roles => {
            coding    => { model => 'openrouter/foo' },
            reasoning => { model => 'kilo/bar' },
        },
        default_role => 'reasoning',
    };
    # "hello" has no role keywords — falls back to default
    is($rm->resolve_role($cfg, 'hello', undef), 'reasoning', 'ambiguous task uses default role');
};

#---------------------------------------------------------------------------
# validate_route_config
#---------------------------------------------------------------------------

subtest 'validate_route_config: valid sequential' => sub {
    my ($ok, $err) = CLIO::Core::RouteManager->validate_route_config({
        strategy => 'sequential',
        models   => ['openrouter/foo'],
    });
    ok($ok, 'valid sequential route passes');
    is($err, '', 'no error message');
};

subtest 'validate_route_config: valid role-aware' => sub {
    my ($ok, $err) = CLIO::Core::RouteManager->validate_route_config({
        strategy => 'role-aware',
        models   => [],
        roles    => {
            coding    => { model => 'openrouter/foo' },
            reasoning => { model => 'kilo/bar' },
        },
        default_role => 'reasoning',
        fallbacks => {
            coding => ['vercel/foo'],
        },
    });
    ok($ok, 'valid role-aware route passes');
    is($err, '', 'no error message');
};

subtest 'validate_route_config: invalid strategy' => sub {
    my ($ok, $err) = CLIO::Core::RouteManager->validate_route_config({
        strategy => 'bogus',
        models   => ['openrouter/foo'],
    });
    ok(!$ok, 'invalid strategy rejected');
    like($err, qr/Invalid strategy/, 'error message mentions strategy');
};

subtest 'validate_route_config: role without model' => sub {
    my ($ok, $err) = CLIO::Core::RouteManager->validate_route_config({
        strategy => 'role-aware',
        models   => [],
        roles    => {
            coding => {},  # No model key
        },
    });
    ok(!$ok, 'role without model rejected');
    like($err, qr/must have a.*model/, 'error message mentions model');
};

subtest 'validate_route_config: default_role not in roles' => sub {
    my ($ok, $err) = CLIO::Core::RouteManager->validate_route_config({
        strategy => 'role-aware',
        models   => [],
        roles    => { coding => { model => 'foo' } },
        default_role => 'design',  # Not in roles
    });
    ok(!$ok, 'default_role not in roles rejected');
    like($err, qr/default_role.*not a configured role/, 'error message mentions default_role');
};

subtest 'validate_route_config: non-hashref input' => sub {
    my ($ok, $err) = CLIO::Core::RouteManager->validate_route_config('not a hash');
    ok(!$ok, 'non-hashref rejected');
};

done_testing();
