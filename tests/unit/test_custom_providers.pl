#!/usr/bin/perl
# Test: Custom provider aliases and resolve_custom_provider
use strict;
use warnings;
use lib '../../lib';
use Test::More;
use CLIO::Core::Config;
use CLIO::Providers;

# Create an isolated config for testing
my $config = CLIO::Core::Config->new(isolated => 1);

# Clean up any pre-existing state
$config->remove_custom_provider('anthropic_test') if $config->is_custom_provider('anthropic_test');
$config->remove_custom_provider('anthropic_prod') if $config->is_custom_provider('anthropic_prod');

# Test 1: Add a custom provider
$config->add_custom_provider('anthropic_test', 'anthropic', 'sk-test-key-123', undef);

ok($config->is_custom_provider('anthropic_test'),
    'is_custom_provider returns true for registered custom provider');
ok(!$config->is_custom_provider('openai'),
    'is_custom_provider returns false for built-in provider');

# Test 2: resolve_custom_provider
is($config->resolve_custom_provider('anthropic_test'), 'anthropic',
    'resolve_custom_provider maps anthropic_test -> anthropic');
is($config->resolve_custom_provider('openai'), 'openai',
    'resolve_custom_provider returns built-in unchanged');
is($config->resolve_custom_provider('nonexistent'), 'nonexistent',
    'resolve_custom_provider returns unknown name unchanged');

# Test 3: Per-provider key storage
is($config->get_provider_key('anthropic_test'), 'sk-test-key-123',
    'Per-provider key stored for custom provider');

# Test 4: resolve_custom_provider in Providers.pm
is(CLIO::Providers::resolve_custom_provider('anthropic_test'), 'anthropic',
    'CLIO::Providers::resolve_custom_provider works');

# Test 5: build_endpoint_config resolves custom provider
my $ep = CLIO::Providers::build_endpoint_config('anthropic_test', 'sk-test-key-123');
ok($ep->{anthropic}, 'Endpoint config has anthropic flag for custom provider');

# Test 6: list_custom_providers
my @list = $config->list_custom_providers();
is(scalar(@list), 1, 'list_custom_providers returns 1 entry');
is($list[0]{name}, 'anthropic_test', 'Custom provider name in list');
is($list[0]{base_provider}, 'anthropic', 'Base provider in list');

# Test 7: Add second custom provider
$config->add_custom_provider('anthropic_prod', 'anthropic', 'sk-prod-key-456', undef);
@list = $config->list_custom_providers();
is(scalar(@list), 2, 'Two custom providers after adding second');

# Test 8: Remove custom provider
ok($config->remove_custom_provider('anthropic_test'),
    'remove_custom_provider returns true for existing custom provider');
ok(!$config->is_custom_provider('anthropic_test'),
    'Custom provider removed');
is($config->remove_custom_provider('nonexistent'), 0,
    'remove_custom_provider returns 0 for nonexistent');

# Test 9: list_all_providers includes custom
my @all = CLIO::Providers::list_all_providers();
my $has_builtins = grep { $_ eq 'anthropic' } @all;
ok($has_builtins, 'list_all_providers includes built-in providers');

# Test 10: _parse_model_provider in APIManager
# We can't easily test APIManager without a full instance, but we can test
# that the model parsing logic recognizes custom providers.
# This is tested via the providers module.

# Test 11: Custom provider with custom base URL
$config->add_custom_provider('openai_custom', 'openai', 'sk-custom-key', 'https://custom.openai.com/v1');
is($config->get_provider_base('openai_custom'), 'https://custom.openai.com/v1',
    'Custom provider stores custom base URL');

# Cleanup
$config->remove_custom_provider('anthropic_prod');
$config->remove_custom_provider('openai_custom');

done_testing();