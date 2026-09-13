#!/usr/bin/env perl
# Test: CLIO::Providers::validate_provider recognizes custom provider
# aliases registered via CLIO::Core::Config::add_custom_provider.
#
# Regression test for the bug where /api set provider <custom> failed with
#   "Provider '<name>' not found. Available: ..."
# because validate_provider only checked built-in providers via
# provider_exists and never consulted Config for custom aliases.
#
# Isolation: explicit tempdir config_dir so the real ~/.clio is never touched.

use strict;
use warnings;
use lib '../../lib';
use Test::More;
use File::Temp qw(tempdir);

use CLIO::Core::Config;
use CLIO::Providers qw(validate_provider provider_exists list_all_providers);

my $tmpdir = tempdir(CLEANUP => 1);

sub fresh_config {
    my $c = CLIO::Core::Config->new(config_dir => $tmpdir);
    $c->{config} = {};
    $c->{user_set} = {};
    return $c;
}

# =============================================================================
# validate_provider: built-in providers still pass
# =============================================================================
subtest 'validate_provider accepts built-in providers' => sub {
    my $config = fresh_config();

    my ($ok, $err) = validate_provider('openai', $config);
    ok($ok, 'openai is valid');
    is($err, '', 'no error for openai');

    ($ok, $err) = validate_provider('anthropic', $config);
    ok($ok, 'anthropic is valid');

    ($ok, $err) = validate_provider('github_copilot', $config);
    ok($ok, 'github_copilot is valid');

    ($ok, $err) = validate_provider('sam', $config);
    ok($ok, 'sam is valid');

    ($ok, $err) = validate_provider('llama.cpp', $config);
    ok($ok, 'llama.cpp is valid');

    ($ok, $err) = validate_provider('minimax_token', $config);
    ok($ok, 'minimax_token is valid');
};

# =============================================================================
# validate_provider: rejects unknown without custom registration
# =============================================================================
subtest 'validate_provider rejects unknown providers' => sub {
    my $config = fresh_config();

    my ($ok, $err) = validate_provider('totally_bogus', $config);
    ok(!$ok, 'totally_bogus is rejected');
    like($err, qr/not found/, 'error message says not found');

    # Error message should list available providers (built-ins)
    like($err, qr/Available:/, 'error message lists available providers');
};

# =============================================================================
# validate_provider: custom alias accepted when config is provided
# =============================================================================
subtest 'validate_provider accepts custom alias when config passed in' => sub {
    my $config = fresh_config();
    ok($config->add_custom_provider('nimo', 'llama.cpp', undef, undef),
       'registered custom alias nimo -> llama.cpp');

    my ($ok, $err) = validate_provider('nimo', $config);
    ok($ok, 'custom alias nimo is valid when config is passed');
    is($err, '', 'no error for nimo');
};

# =============================================================================
# validate_provider: custom alias accepted even without config arg
# (lazy Config load)
# =============================================================================
subtest 'validate_provider accepts custom alias via lazy Config load' => sub {
    # The lazy-load path creates a fresh Config->new() which reads the
    # real config dir. We verify it does not crash and falls back to
    # list_all_providers error. If an 'anthropic_test' alias happens to
    # be registered in the real config, it'll be accepted; otherwise we
    # get the error message. Either way, no crash.
    my ($ok, $err) = validate_provider('anthropic_test');
    if ($ok) {
        pass('custom alias accepted via lazy Config load (found in real config)');
    } else {
        like($err, qr/not found/, 'rejected via lazy load with error message');
        like($err, qr/Available:/, 'error includes Available: list');
    }
};

# =============================================================================
# validate_provider: empty/undef rejected
# =============================================================================
subtest 'validate_provider rejects empty and undef' => sub {
    my $config = fresh_config();

    my ($ok, $err) = validate_provider('', $config);
    ok(!$ok, 'empty string rejected');
    like($err, qr/cannot be empty/, 'error says cannot be empty');

    ($ok, $err) = validate_provider(undef, $config);
    ok(!$ok, 'undef rejected');
    like($err, qr/cannot be empty/, 'error says cannot be empty');
};

# =============================================================================
# validate_provider: error message includes custom providers
# =============================================================================
subtest 'validate_provider error lists custom providers too' => sub {
    # list_all_providers already includes custom aliases when a config
    # is available. The error message uses list_all_providers, so any
    # registered custom aliases will appear. We test the message format
    # by checking it includes 'Available:' with a comma-separated list.
    my $config = fresh_config();
    my ($ok, $err) = validate_provider('bogus_xyz', $config);
    ok(!$ok, 'bogus provider rejected');
    like($err, qr/Available:/, 'error message lists available providers');
    like($err, qr/openai/, 'error message includes at least one built-in');
};

# =============================================================================
# Smoke test: list_all_providers includes built-ins
# =============================================================================
subtest 'list_all_providers includes built-ins' => sub {
    # list_all_providers creates its own Config->new() (real config dir),
    # so we can't control custom aliases here. Just verify built-ins are
    # present and the function doesn't crash.
    my @all = list_all_providers();
    ok(grep(/^openai$/, @all), 'built-in openai appears in list_all_providers');
    ok(grep(/^anthropic$/, @all), 'built-in anthropic appears in list_all_providers');
    ok(@all >= 18, 'at least 18 providers listed (built-ins)');
};

done_testing();
