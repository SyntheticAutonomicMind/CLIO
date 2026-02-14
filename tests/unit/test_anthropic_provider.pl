#!/usr/bin/env perl

# Test script for Anthropic provider
# Verifies message conversion and stream event parsing

use strict;
use warnings;
use lib './lib';
use Test::More tests => 12;
use JSON::PP qw(encode_json decode_json);

use_ok('CLIO::Providers::Base');
use_ok('CLIO::Providers::Anthropic');

# Create provider instance (without real API key for testing)
my $provider = CLIO::Providers::Anthropic->new(
    api_key => 'test-key',
    model => 'claude-sonnet-4-20250514',
    debug => 0,
);

ok($provider, 'Provider instantiated');

# Test 1: Tool conversion
my $openai_tool = {
    type => 'function',
    function => {
        name => 'file_operations',
        description => 'File operations: read, write, etc.',
        parameters => {
            type => 'object',
            properties => {
                operation => { type => 'string' },
                path => { type => 'string' },
            },
            required => ['operation'],
        },
    },
};

my $anthropic_tool = $provider->convert_tool($openai_tool);
is($anthropic_tool->{name}, 'file_operations', 'Tool name converted');
is($anthropic_tool->{description}, 'File operations: read, write, etc.', 'Tool description converted');
is_deeply($anthropic_tool->{input_schema}, $openai_tool->{function}{parameters}, 'Tool parameters -> input_schema');

# Test 2: Stream event parsing - text delta
my $text_event = $provider->parse_stream_event(
    'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}'
);
is($text_event->{type}, 'text', 'Text delta parsed');
is($text_event->{content}, 'Hello', 'Text content extracted');

# Test 3: Stream event parsing - tool start
my $tool_start = $provider->parse_stream_event(
    'data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_123","name":"file_operations"}}'
);
is($tool_start->{type}, 'tool_start', 'Tool start parsed');
is($tool_start->{id}, 'toolu_123', 'Tool ID extracted');
is($tool_start->{name}, 'file_operations', 'Tool name extracted');

# Test 4: Message stop event
my $done = $provider->parse_stream_event('data: {"type":"message_stop"}');
is($done->{type}, 'done', 'Message stop -> done');

print "\n✓ All Anthropic provider tests passed!\n";
