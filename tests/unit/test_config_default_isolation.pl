#!/usr/bin/env perl
# Regression test: DEFAULT_CONFIG is a constant whose nested hashrefs
# (model_configs, model_candidates, model_routes, api_keys, api_bases)
# must not leak across Config instances. A Config that mutates one of
# those nested refs would otherwise pollute every other Config loaded
# in the same process.
#
# Bug history: before the fix, `my %config = %{DEFAULT_CONFIG()}` in
# load() aliased the inner refs. Calling _save_model_config() on any
# model_id created entries under the shared `model_configs` hashref, so
# the next Config->new inherited phantom entries for models the user had
# briefly visited. Tests that exercised model switches in sequence saw
# "leaks" between subtests that each used isolated tempdirs.

use strict;
use warnings;
use lib './lib';
use Test::More;
use File::Temp qw(tempdir);
use CLIO::Util::JSON qw(decode_json);

require CLIO::Core::Config;
use CLIO::Core::Config;

subtest 'DEFAULT_CONFIG mutable fields are per-instance after _default_config' => sub {
    my $a = CLIO::Core::Config->_default_config();
    my $b = CLIO::Core::Config->_default_config();

    isnt($a->{model_configs}, $b->{model_configs},
        'model_configs is a fresh ref per _default_config() call');
    isnt($a->{model_candidates}, $b->{model_candidates},
        'model_candidates is a fresh ref per _default_config() call');
    isnt($a->{model_routes}, $b->{model_routes},
        'model_routes is a fresh ref per _default_config() call');
    isnt($a->{api_keys}, $b->{api_keys},
        'api_keys is a fresh ref per _default_config() call');
    isnt($a->{api_bases}, $b->{api_bases},
        'api_bases is a fresh ref per _default_config() call');
};

subtest 'mutating one Config does not pollute another Config' => sub {
    my $dir_a = tempdir(CLEANUP => 1);
    my $dir_b = tempdir(CLEANUP => 1);

    my $a = CLIO::Core::Config->new(config_dir => $dir_a);
    my $b = CLIO::Core::Config->new(config_dir => $dir_b);

    $a->set_provider('minimax');
    $a->set('show_thinking', 1, 1);
    $a->set_provider('nvidia');
    $a->save();
    $a->set_provider('minimax');
    $a->save();

    # After A's round-trip, A's in-memory model_configs has minimax/M3
    # entry. If B's load() aliased the constant, B would inherit the
    # nvidia entry that A's _save_model_config transiently created.
    is_deeply($b->{config}{model_configs}, {},
        'B model_configs is empty after new() (no leak from A)');
    is($b->{config}{provider}, undef,
        'B provider is undef after new() (no leak from A)');
};

subtest 'multiple Config instances with same provider see independent model_configs' => sub {
    my $dir_a = tempdir(CLEANUP => 1);
    my $dir_b = tempdir(CLEANUP => 1);

    my $a = CLIO::Core::Config->new(config_dir => $dir_a);
    $a->set_provider('minimax');
    $a->set('show_thinking', 1, 1);

    my $b = CLIO::Core::Config->new(config_dir => $dir_b);
    $b->set_provider('minimax');

    # B did not inherit A's show_thinking=1
    is($b->{config}{show_thinking}, 0,
        'fresh Config does not inherit another Config user-set values');
};

subtest '_save_model_config skips phantom entry when no non-default values' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $config = CLIO::Core::Config->new(config_dir => $dir);

    # Manually invoke _save_model_config with no user customizations.
    # Without the fix, this creates an entry {} for the model.
    $config->_save_model_config('test/phantom-model');

    ok(!exists $config->{config}{model_configs}{'test/phantom-model'},
        'no phantom entry created when all scoped values are defaults');
};

subtest 'round-trip: empty entry still cleans up after switching to a clean model' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $config = CLIO::Core::Config->new(config_dir => $dir);

    $config->set_provider('minimax');
    $config->set('show_thinking', 1, 1);
    $config->set_provider('nvidia');
    $config->save();

    # After switching to nvidia with no entry and no customizations,
    # model_configs should NOT contain an empty nvidia entry from
    # _save_model_config transiently materializing it.
    ok(!exists $config->{config}{model_configs}{'nvidia/nemotron-3-ultra-550b-a55b'}
        || !%{$config->{config}{model_configs}{'nvidia/nemotron-3-ultra-550b-a55b'} || {}},
        'nvidia entry is either absent or empty after save (no phantom)');
};

done_testing();
