#!/usr/bin/env perl
# Test CLIO::Core::Config - --model override preserves configured provider
#
# Regression test for: --model switching providers via direct config
# manipulation must NOT lose the user-configured provider on save().
#
# Bug (fixed in f83a114): The old code path in clio called set_provider()
# for the temp switch, then deleted user_set->{provider} to avoid
# persisting the temporary switch. This also nuked the ORIGINAL
# user-configured provider's user_set flag, so save() omitted provider
# from config.json. Next launch -> "No provider set".

use strict;
use warnings;
use lib './lib';
use Test::More;
use File::Temp qw(tempdir);

use CLIO::Core::Config;
use CLIO::Util::JSON qw(decode_json);

# ==========================================================================
# Test: save() preserves user-configured provider after direct
# config manipulation (the --model handler's fixed code path)
# ==========================================================================

subtest 'save preserves user-configured provider after temp switch' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);

    my $config = CLIO::Core::Config->new(config_dir => $tmpdir);

    # Initial setup: user configures deepseek via /api set provider
    $config->set_provider('deepseek');
    $config->save();

    is($config->{user_set}{provider}, 1, 'deepseek marked user_set');

    {
        my $raw = do { open my $fh, '<', "$tmpdir/config.json"; local $/; <$fh> };
        my $saved = decode_json($raw);
        is($saved->{provider}, 'deepseek', 'config.json has deepseek before temp switch');
    }

    # Simulate --model nvidia/some-model via the FIXED code path:
    # direct config manipulation, never touching user_set
    require CLIO::Providers;
    my $pcfg = CLIO::Providers::get_provider('nvidia');
    $config->{config}->{provider} = 'nvidia';
    $config->{config}->{api_base} = $pcfg->{api_base};
    $config->set('model', 'nvidia/deepseek-ai/deepseek-v4-flash', 0);

    # Provider in config hash is nvidia (temporary)
    is($config->{config}->{provider}, 'nvidia', 'config hash has temp nvidia');

    # user_set still flags deepseek as the configured provider
    is($config->{user_set}{provider}, 1,
        'user_set provider flag still intact after temp switch');

    $config->save();

    {
        my $raw = do { open my $fh, '<', "$tmpdir/config.json"; local $/; <$fh> };
        my $saved = decode_json($raw);

        # REGRESSION TEST: With the old bug, provider would be missing
        # from config.json entirely (user_set was deleted).
        ok(exists $saved->{provider}, 'provider EXISTS in config.json after temp switch');

        # Model should NOT be persisted (marked user_set=0)
        ok(!$saved->{model} || $saved->{model} eq '',
            'model NOT persisted (temporary --model override)');
    }
};

# ==========================================================================
# Test: The OLD buggy pattern would corrupt config.json.
# Included to prove the test catches the regression.
# ==========================================================================

subtest 'OLD bug: set_provider + delete user_set loses provider' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);

    my $config = CLIO::Core::Config->new(config_dir => $tmpdir);

    $config->set_provider('deepseek');
    $config->save();

    {
        my $raw = do { open my $fh, '<', "$tmpdir/config.json"; local $/; <$fh> };
        my $saved = decode_json($raw);
        is($saved->{provider}, 'deepseek', 'initial: deepseek saved');
    }

    # Old buggy --model handler:
    # 1. set_provider for temp provider
    $config->set_provider('nvidia');
    # 2. Delete user_set to "avoid persisting"
    delete $config->{user_set}->{provider};
    delete $config->{user_set}->{api_base};
    delete $config->{user_set}->{model};

    ok(!$config->{user_set}{provider},
        'OLD BUG: user_set provider flag is gone');

    $config->save();

    {
        my $raw = do { open my $fh, '<', "$tmpdir/config.json"; local $/; <$fh> };
        my $saved = decode_json($raw);

        ok(!exists $saved->{provider} || !$saved->{provider},
            'OLD BUG CONFIRMED: provider missing from config.json');
    }
};

# ==========================================================================
# Test: First --model with provider prefix when no provider configured
# should PERSIST the derived provider.
# ==========================================================================

subtest 'first --model with provider prefix persists provider' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);

    my $config = CLIO::Core::Config->new(config_dir => $tmpdir);

    # No provider configured, but user has a deepseek API key
    $config->{config} = {};
    $config->{user_set} = {};
    $config->{config}{api_keys} = { deepseek => 'sk-deepseek-test' };
    $config->{user_set}{api_keys} = 1;

    # Simulate: clio --model deepseek/deepseek-v4-pro
    # Fixed code: set_provider + save
    $config->set_provider('deepseek');
    $config->save();

    {
        my $raw = do { open my $fh, '<', "$tmpdir/config.json"; local $/; <$fh> };
        my $saved = decode_json($raw);
        is($saved->{provider}, 'deepseek',
            'provider persisted after first --model with prefix');
    }

    ok($config->{user_set}{provider},
        'user_set provider flag set after auto-derive + save');
};

done_testing();
