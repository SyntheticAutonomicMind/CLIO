#!/usr/bin/env perl

# Test script for Google Gemini provider
# Verifies message conversion and stream event parsing

use strict;
use warnings;
use lib './lib';
use Test::More tests => 14;
use JSON::PP qw(encode_json decode_json);

use_ok('CLIO::Providers::Base');
use_ok('CLIO::Providers::Google');

# Create provider instance (without real API key for testing)
my $provider = CLIO::Providers::Google->new(
    api_key => 'test-key',
    model => 'gemini-2.5-flash',
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

my $google_tool = $provider->convert_tool($openai_tool);
is($google_tool->{name}, 'file_operations', 'Tool name converted');
is($google_tool->{description}, 'File operations: read, write, etc.', 'Tool description converted');
is($google_tool->{parameters}{type}, 'OBJECT', 'Tool type uppercased for Google');

# Test 2: Message conversion
my $messages = [
    { role => 'user', content => 'Hello' },
    { role => 'assistant', content => 'Hi there!' },
];

my $contents = $provider->convert_messages($messages);
is(scalar(@$contents), 2, 'Two messages converted');
is($contents->[0]{role}, 'user', 'User role preserved');
is($contents->[1]{role}, 'model', 'Assistant -> model role');
is($contents->[0]{parts}[0]{text}, 'Hello', 'User text in parts');

# Test 3: Stream event parsing - text
my $text_event = $provider->parse_stream_event(
    'data: {"candidates":[{"content":{"parts":[{"text":"Hello world"}]}}]}'
);
is($text_event->{type}, 'text', 'Text event parsed');
is($text_event->{content}, 'Hello world', 'Text content extracted');

# Test 4: Stream event parsing - function call
my $tool_event = $provider->parse_stream_event(
    'data: {"candidates":[{"content":{"parts":[{"functionCall":{"name":"file_operations","args":{"operation":"read"}}}]}}]}'
);
is($tool_event->{type}, 'tool_end', 'Function call parsed as tool_end');
is($tool_event->{name}, 'file_operations', 'Function name extracted');

print "\n All Google provider tests passed!\n";
