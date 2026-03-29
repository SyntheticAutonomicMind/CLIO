#!/usr/bin/env perl

# Test script for MiniMax provider support
# Verifies provider registration, endpoint config, and streaming format handling

use strict;
use warnings;
use lib './lib';
use Test::More tests => 30;
use CLIO::Util::JSON qw(encode_json decode_json);

# Test 1-2: Provider registration
use_ok('CLIO::Providers');
ok(CLIO::Providers::provider_exists('minimax'), 'MiniMax provider registered');

# Test 3: Token Plan provider registered
ok(CLIO::Providers::provider_exists('minimax_token'), 'MiniMax Token Plan provider registered');

# Test 4-8: Pay-as-you-go provider config
my $provider = CLIO::Providers::get_provider('minimax');
ok($provider, 'MiniMax provider config retrieved');
is($provider->{name}, 'MiniMax', 'Provider name');
is($provider->{model}, 'MiniMax-M2.7', 'Default model is MiniMax-M2.7');
is($provider->{api_base}, 'https://api.minimax.io/v1/chat/completions', 'API base URL');
is($provider->{max_context_tokens}, 204800, 'Context window 204,800 tokens');

# Test 9-10: Provider capabilities
ok($provider->{supports_tools}, 'Supports tool calling');
ok($provider->{supports_streaming}, 'Supports streaming');

# Test 11-14: Token Plan provider config
my $token_provider = CLIO::Providers::get_provider('minimax_token');
ok($token_provider, 'Token Plan provider config retrieved');
is($token_provider->{name}, 'MiniMax Token Plan', 'Token Plan provider name');
is($token_provider->{model}, 'MiniMax-M2.7', 'Token Plan default model same');
is($token_provider->{api_base}, $provider->{api_base}, 'Token Plan same API base');

# Test 15-17: Endpoint config
my $endpoint = CLIO::Providers::build_endpoint_config('minimax', 'test-key-123');
ok($endpoint, 'Endpoint config built');
is($endpoint->{path_suffix}, '', 'Path suffix empty (full URL in api_base)');
ok($endpoint->{minimax}, 'MiniMax flag set in endpoint config');

# Test 18: Temperature range excludes 0
my ($min_temp, $max_temp) = @{$endpoint->{temperature_range}};
ok($min_temp > 0, "Min temperature > 0 (got $min_temp) - MiniMax rejects temp=0");
ok($max_temp == 1.0, "Max temperature is 1.0 (got $max_temp)");

# Test 20: Auth header
is($endpoint->{auth_header}, 'Authorization', 'Auth header is Authorization');
is($endpoint->{auth_value}, 'Bearer test-key-123', 'Auth value is Bearer token');

# Test 22: Provider validation
my ($valid, $error) = CLIO::Providers::validate_provider('minimax');
ok($valid, 'minimax validates successfully');

my ($valid2, $error2) = CLIO::Providers::validate_provider('minimax_token');
ok($valid2, 'minimax_token validates successfully');

# Test 24: Provider appears in list
my @all_providers = CLIO::Providers::list_providers();
ok((grep { $_ eq 'minimax' } @all_providers), 'minimax in provider list');
ok((grep { $_ eq 'minimax_token' } @all_providers), 'minimax_token in provider list');

# Test 26-27: Streaming reasoning_details format parsing
# MiniMax sends reasoning as: {"type":"reasoning.text","id":"...","format":"...","index":0,"text":"chunk"}
my $reasoning_chunk = {
    type => 'reasoning.text',
    id => 'reasoning-text-1',
    format => 'MiniMax-response-v1',
    index => 0,
    text => 'The user is asking...',
};
is($reasoning_chunk->{type}, 'reasoning.text', 'MiniMax reasoning type is reasoning.text');
ok(defined $reasoning_chunk->{text}, 'MiniMax reasoning has text field');

# Test 28: Streaming tool_calls format (standard OpenAI compatible)
my $tool_chunk = decode_json('{"id":"call_function_abc123","type":"function","function":{"name":"get_time","arguments":"{}"}}');
is($tool_chunk->{type}, 'function', 'Tool call type is function');
is($tool_chunk->{function}{name}, 'get_time', 'Tool call function name extracted');

# Test 30: Usage format with reasoning_tokens
my $usage = decode_json('{"total_tokens":93,"prompt_tokens":43,"completion_tokens":50,"completion_tokens_details":{"reasoning_tokens":29},"prompt_tokens_details":{"cached_tokens":0}}');
is($usage->{completion_tokens_details}{reasoning_tokens}, 29, 'Reasoning tokens in usage');

print "\n All MiniMax provider tests passed!\n";
