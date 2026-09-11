#!/usr/bin/perl
# Test: custom provider aliases are recognized as valid providers and by
# Config::set_provider.
#
# Regression coverage for the custom-provider-prefix bug where the clio
# launcher and Config::set_provider only recognized built-in providers (via
# CLIO::Providers::provider_exists), silently rejecting custom aliases and
# double-prefixing models with the wrong provider.
#
# Isolation: an explicit tempdir config_dir is used so the real ~/.clio is
# never touched (mirrors test_config_set_provider.pl's pattern, NOT the
# broken "isolated => 1" param that is silently ignored).

use strict;
use warnings;
use lib '../../lib';
use Test::More;
use File::Temp qw(tempdir);

use CLIO::Core::Config;
use CLIO::Providers qw(provider_exists get_provider);

# Private config dir -> never touches the user's real ~/.clio/config.json.
my $tmpdir = tempdir(CLEANUP => 1);

sub fresh_config {
    my $c = CLIO::Core::Config->new(config_dir => $tmpdir);
    # Clean slate
    $c->{config} = {};
    $c->{user_set} = {};
    return $c;
}

# =============================================================================
# is_valid_provider: built-in vs custom vs unknown
# =============================================================================
subtest 'is_valid_provider recognizes built-ins, custom aliases, and rejects unknown' => sub {
    my $config = fresh_config();

    ok($config->is_valid_provider('openai'),
        'built-in openai is valid');
    ok($config->is_valid_provider('anthropic'),
        'built-in anthropic is valid');
    ok($config->is_valid_provider('github_copilot'),
        'built-in github_copilot is valid');
    ok(!$config->is_valid_provider('totally_bogus'),
        'unknown provider is not valid');
    ok(!$config->is_valid_provider(''),
        'empty string is not valid');
    ok(!$config->is_valid_provider(undef),
        'undef is not valid');

    # Register a custom alias to anthropic (the bug-report scenario).
    ok($config->add_custom_provider('proxy_04', 'anthropic', 'sk-proxy-123', undef),
        'add custom alias proxy_04 -> anthropic');

    ok($config->is_valid_provider('proxy_04'),
        'custom alias proxy_04 is valid (this is the fix)');
    ok(!provider_exists('proxy_04'),
        'provider_exists alone still says false for the alias (sanity check)');
};

# =============================================================================
# set_provider: custom alias must switch provider/key/model, not silently fail
# =============================================================================
subtest 'set_provider accepts a custom alias (used to return 0)' => sub {
    my $config = fresh_config();
    $config->add_custom_provider('proxy_04', 'anthropic', 'sk-proxy-123', undef);

    # First land on a known built-in so there is a current provider/base to switch from.
    ok($config->set_provider('openai'), 'switch to openai baseline');
    is($config->{config}{provider}, 'openai', 'baseline provider is openai');
    is($config->{config}{model}, 'openai/gpt-4.1', 'baseline model is openai/gpt-4.1');

    # This is the core regression: set_provider used to reject custom aliases.
    my $ret = $config->set_provider('proxy_04');
    ok($ret, 'set_provider returns true for custom alias');
    is($config->{config}{provider}, 'proxy_04',
        'provider set to the custom alias (not silently left as openai)');
    is($config->{config}{api_key}, 'sk-proxy-123',
        'custom alias API key loaded into api_key');
    is($config->{config}{model}, 'proxy_04/claude-sonnet-4-20250514',
        'default model prefixed with the alias, not the base provider');
    is($config->resolve_custom_provider('proxy_04'), 'anthropic',
        'alias still resolves to its base provider anthropic');
};

# =============================================================================
# set_provider: keep_model_prefix providers (nvidia) get the alias re-prefixed,
# not a doubled "nvidia" token (custom alias -> nvidia).
# =============================================================================
subtest 'set_provider re-prefixes keep_model_prefix provider for a custom alias' => sub {
    my $config = fresh_config();
    $config->add_custom_provider('nvidia_proxy', 'nvidia', 'sk-nv-456', undef);

    ok($config->set_provider('openai'), 'baseline openai');

    my $ret = $config->set_provider('nvidia_proxy');
    ok($ret, 'set_provider returns true for nvidia alias');
    is($config->{config}{provider}, 'nvidia_proxy', 'provider is the alias');
    is($config->{config}{api_key}, 'sk-nv-456', 'nvidia alias key loaded');
    is($config->{config}{model}, 'nvidia_proxy/nemotron-3-ultra-550b-a55b',
        'keep_model_prefix base prefix stripped and replaced with alias (no doubled nvidia)');
};

# =============================================================================
# set_provider: genuinely unknown provider still fails (guard intact)
# =============================================================================
subtest 'set_provider rejects genuinely unknown providers' => sub {
    my $config = fresh_config();
    ok(!$config->set_provider('nope_not_a_provider'),
        'set_provider returns false for unknown provider');
    is($config->{config}{provider}, undef,
        'provider unchanged after failed set_provider');
};

done_testing();
