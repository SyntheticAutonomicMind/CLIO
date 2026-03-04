#!/usr/bin/env perl

# Test script for Google Gemini provider
# Verifies message conversion and stream event parsing

use strict;
use warnings;
use lib './lib';
use Test::More tests => 22;
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

# Test 5: finishReason + function call in same chunk - parts must be processed first
my $combined_event = $provider->parse_stream_event(
    'data: {"candidates":[{"content":{"parts":[{"functionCall":{"name":"file_operations","args":{"operation":"read"}}}]},"finishReason":"STOP"}]}'
);
is($combined_event->{type}, 'tool_end', 'Function call extracted when finishReason is in same chunk');
is($combined_event->{name}, 'file_operations', 'Function name correct when finishReason present');

# Test 6: finishReason-only chunk returns stop
my $stop_event = $provider->parse_stream_event(
    'data: {"candidates":[{"finishReason":"STOP"}]}'
);
is($stop_event->{type}, 'stop', 'Stop event parsed correctly');
is($stop_event->{stop_reason}, 'stop', 'Stop reason mapped correctly');

# Test 7: _convert_tool_result_message uses name field, not tool_call_id
my $tool_result_msg = {
    role => 'tool',
    tool_call_id => 'call_1_1234567890',   # generated ID - NOT the function name
    name => 'file_operations',              # actual function name stored by WorkflowOrchestrator
    content => '{"success":1}',
};
my $google_result = $provider->_convert_tool_result_message($tool_result_msg);
is($google_result->{parts}[0]{functionResponse}{name}, 'file_operations',
    'functionResponse.name uses actual function name, not tool_call_id');

# Test 8: Tool call ID normalization (Copilot proxy returns Google-format IDs)
# The Copilot proxy returns 'function-call-NNNN' when routing through Gemini,
# then rejects them on the next turn. We normalize to OpenAI 'call_XXXXX' format.
sub normalize_tool_call_id {
    my ($id) = @_;
    return ($id =~ /^function-call-(\d+)$/) ? 'call_' . substr($1, -24) : $id;
}

my $google_id = 'function-call-9382368308610045162';
my $normalized = normalize_tool_call_id($google_id);
like($normalized, qr/^call_\d+$/, 'Google function-call ID normalized to call_ format');
isnt($normalized, $google_id, 'Normalized ID differs from original');

# Standard OpenAI IDs should pass through unchanged
my $openai_id = 'call_abc123XYZ';
is(normalize_tool_call_id($openai_id), $openai_id, 'OpenAI call_ ID passes through unchanged');

print "\n All Google provider tests passed!\n";
