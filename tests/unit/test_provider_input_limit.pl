#!/usr/bin/perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Tests for the provider-reported input limit.
#
# A model listing describes the model, not the endpoint that serves it.
# A gateway can route a 1M-context model to a provider that enforces a
# smaller window, and tokenizers differ enough that a prompt can mirror
# the listing's window and still be too large upstream. When that happens
# the rejection names the real limit; it must be kept, not discarded after
# one retry.
#
# 1. compute_prompt_budget caps the budget to provider_input_limit.
# 2. The cap never raises a budget.
# 3. APIManager records it per model, monotonically.
# 4. It survives a capability cache refresh through _learned_input_limits.

use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/../../lib";

use Test::More;
use File::Temp qw(tempdir);
use File::Spec;

# Isolate every config and cache write. ModelCapabilitiesManager persists
# to the config dir, and a test must never touch the user's real cache.
my $SANDBOX = tempdir(CLEANUP => 1);
$ENV{CLIO_CONFIG_DIR} = $SANDBOX;
{
    open my $cf, '>', File::Spec->catfile($SANDBOX, 'config.json') or die $!;
    print $cf q({"provider":"openrouter","api_key":"sk-test"});
    close $cf;
}

use CLIO::Memory::TokenEstimator;
use CLIO::Core::APIManager;
use CLIO::Core::Config;

subtest 'budget is capped to the reported input limit' => sub {
    my $caps = {
        max_context_window_tokens => 1048576,
        max_output_tokens         => 131072,
    };
    my $unbounded = CLIO::Memory::TokenEstimator::compute_prompt_budget($caps);

    my $bounded = CLIO::Memory::TokenEstimator::compute_prompt_budget({
        %$caps,
        provider_input_limit => 262144,
    });

    is($bounded, 262144, 'budget equals the reported limit');
    cmp_ok($bounded, '<', $unbounded, 'budget shrank');
};

subtest 'the cap never raises a budget' => sub {
    my $caps = {
        max_context_window_tokens => 131072,
        max_output_tokens         => 16384,
        provider_input_limit      => 999999,
    };
    my $with_cap = CLIO::Memory::TokenEstimator::compute_prompt_budget($caps);
    my $without  = CLIO::Memory::TokenEstimator::compute_prompt_budget({
        max_context_window_tokens => 131072,
        max_output_tokens         => 16384,
    });
    is($with_cap, $without, 'a larger cap changes nothing');
};

subtest 'APIManager records the limit per model, monotonically' => sub {
    my $api = CLIO::Core::APIManager->new(
        config => CLIO::Core::Config->new(config_dir => $SANDBOX),
        debug  => 0,
    );

    my $model = 'openrouter/vendor/model';
    ok($api->note_provider_input_limit($model, 262144), 'first report recorded');
    is($api->{_learned_input_limits}{$model}, 262144, 'stored');
    is($api->note_provider_input_limit($model, 400000), 0,
        'a larger later report is ignored');
    is($api->{_learned_input_limits}{$model}, 262144, 'limit unchanged');
    ok($api->note_provider_input_limit($model, 131072), 'a smaller report is accepted');
    is($api->{_learned_input_limits}{$model}, 131072, 'limit lowered');

    is($api->note_provider_input_limit($model, 0), 0, 'zero rejected');
    is($api->note_provider_input_limit($model, 'abc'), 0, 'non-numeric rejected');
};

subtest 'the cap reaches the caps hash after a cache refresh' => sub {
    my $api = CLIO::Core::APIManager->new(
        config => CLIO::Core::Config->new(config_dir => $SANDBOX),
        debug  => 0,
    );

    my $model = 'openrouter/vendor/model';
    $api->note_provider_input_limit($model, 200000);

    # Rebuild the cached caps without the learned field, as a refresh
    # would, and confirm the override reapplies it.
    $api->{_model_capabilities_cache}{$model} = {
        max_prompt_tokens         => 1048576,
        max_context_window_tokens => 1048576,
        max_output_tokens         => 131072,
    };

    my $caps = $api->get_model_capabilities($model);
    is($caps->{provider_input_limit}, 200000,
        'learned limit reapplied to the capability hash');
    is(CLIO::Memory::TokenEstimator::compute_prompt_budget($caps), 200000,
        'the budget the validator sees is capped');
};

subtest 'mutating a cache entry does not discard the rest of the cache' => sub {
    require CLIO::Core::ModelCapabilitiesManager;
    my $mcm = CLIO::Core::ModelCapabilitiesManager->new(debug => 0);

    # Seed a second entry (as a capability fetch would), then learn a
    # limit for a different model through a fresh instance that has not
    # loaded the cache yet.
    $mcm->_ensure_cache_loaded();
    $mcm->{cache}{'openrouter:seeded'} = {
        provider => 'openrouter', model => 'seeded',
        context_window => 200000, _cached_at => time,
    };
    $mcm->_save_cache();

    my $fresh = CLIO::Core::ModelCapabilitiesManager->new(debug => 0);
    $fresh->set_provider_input_limit('openrouter', 'other-model', 123456);

    my $reloaded = CLIO::Core::ModelCapabilitiesManager->new(debug => 0);
    $reloaded->_ensure_cache_loaded();
    ok($reloaded->{cache}{'openrouter:seeded'},
        'the pre-existing entry survived');
    is(
        ($reloaded->{cache}{ $reloaded->_build_cache_key('openrouter', 'other-model') } || {})->{provider_input_limit},
        123456,
        'the new entry was written',
    );
};

done_testing();
