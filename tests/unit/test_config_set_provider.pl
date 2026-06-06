#!/usr/bin/env perl
# Test CLIO::Core::Config - set_provider key preservation
#
# Tests that switching providers preserves the top-level api_key
# when no per-provider key exists (regression test for key deletion bug).

use strict;
use warnings;
use lib './lib';
use Test::More;

use CLIO::Core::Config;
use CLIO::Providers qw(provider_exists);

# =============================================================================
# Test: set_provider preserves api_key when no per-provider key
#
# We test the internal behavior by directly manipulating the config hash
# to avoid filesystem coupling with real user config.
# =============================================================================

subtest 'set_provider keeps api_key when no per-provider key stored' => sub {
    my $config = CLIO::Core::Config->new(config_dir => '/tmp/clio_test_config_XXXX');

    # Clear all user-set values and config to start fresh
    $config->{config} = {};
    $config->{user_set} = {};

    # Set up: only top-level api_key, NO api_keys hash
    $config->{config}{api_key} = 'sk-test-key-preserved';
    $config->{user_set}{api_key} = 1;

    # Set up current provider and api_base
    $config->{config}{provider} = 'github_copilot';
    $config->{user_set}{provider} = 1;
    $config->{config}{api_base} = 'https://api.githubcopilot.com';

    # Verify internal state before switch
    is($config->{config}{api_key}, 'sk-test-key-preserved',
        'api_key set in config hash');

    # Switch to openai - which has no stored key in our empty config
    my $result = $config->set_provider('openai');
    ok($result, 'set_provider returned success');

    # The api_key should still be present (this was the bug: it was deleted)
    ok(exists $config->{config}{api_key},
        'api_key still exists after provider switch');
    is($config->{config}{api_key}, 'sk-test-key-preserved',
        'api_key value preserved after provider switch to openai');
};

subtest 'set_provider uses per-provider key when available' => sub {
    my $config = CLIO::Core::Config->new(config_dir => '/tmp/clio_test_config_YYYY');

    # Clear everything
    $config->{config} = {};
    $config->{user_set} = {};

    # Set up: both top-level and per-provider keys
    $config->{config}{api_key} = 'sk-global';
    $config->{user_set}{api_key} = 1;

    # Store a per-provider key for openai
    $config->{config}{api_keys} = { openai => 'sk-openai-specific' };
    $config->{user_set}{api_keys} = 1;

    # Set current provider
    $config->{config}{provider} = 'github_copilot';
    $config->{user_set}{provider} = 1;
    $config->{config}{api_base} = 'https://api.githubcopilot.com';

    # Switch to openai with stored key
    my $result = $config->set_provider('openai');
    ok($result, 'set_provider returned success');

    # Per-provider key should take precedence
    is($config->{config}{api_key}, 'sk-openai-specific',
        'Per-provider key loaded instead of global key');
};

subtest 'set_provider does not delete api_key for unknown providers' => sub {
    my $config = CLIO::Core::Config->new(config_dir => '/tmp/clio_test_config_ZZZZ');

    # Clear everything
    $config->{config} = {};
    $config->{user_set} = {};

    # Only top-level api_key, no api_keys hash at all
    $config->{config}{api_key} = 'sk-only-key';
    $config->{user_set}{api_key} = 1;

    # Current provider is github_copilot
    $config->{config}{provider} = 'github_copilot';
    $config->{user_set}{provider} = 1;
    $config->{config}{api_base} = 'https://api.githubcopilot.com';

    # Switch to minimax (no stored key)
    my $result = $config->set_provider('minimax');
    ok($result, 'set_provider to minimax succeeded');

    # Key must NOT be deleted
    ok(exists $config->{config}{api_key},
        'api_key exists after switch to minimax');
    is($config->{config}{api_key}, 'sk-only-key',
        'api_key unchanged after switch to minimax');
};

# Clean up temp directories
END {
    system('rm -rf /tmp/clio_test_config_*');
}

done_testing();
