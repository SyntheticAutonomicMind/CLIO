#!/usr/bin/env perl

=head1 NAME

api_provider_test.pl - Test API provider functionality with mock

=head1 DESCRIPTION

Tests API provider setup and basic functionality without requiring real API keys.
Uses MockAPI for testing.

=cut

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../lib";
use Test::More;
use Data::Dumper;

use CLIO::Test::MockAPI;
use CLIO::Session::Manager;

# Create session (in temp dir to avoid polluting project)
use File::Temp qw(tempdir);
my $test_dir = tempdir(CLEANUP => 1);
chdir $test_dir;
mkdir '.clio';
mkdir '.clio/sessions';

my $session = CLIO::Session::Manager->create(debug => 0);
ok($session, "Session created");
ok($session->{session_id}, "Session has ID: " . $session->{session_id});

# Create mock API
my $mock_api = CLIO::Test::MockAPI->new(
    model => 'mock-gpt-4',
    provider => 'mock-openai',
);
ok($mock_api, "MockAPI created");

# Test basic chat completion
my $messages = [
    { role => 'user', content => 'Hi, can you hear me?' }
];

$mock_api->set_response({
    content => "Yes, I can hear you! How can I help?",
});

my $result = $mock_api->chat_completion(messages => $messages);
ok($result, "Got response from mock");
ok($result->{choices}, "Response has choices");
is($result->{choices}[0]{message}{content}, "Yes, I can hear you! How can I help?", "Content matches expected");
is($result->{choices}[0]{finish_reason}, 'stop', "Finish reason is 'stop'");

# Test request tracking
my @requests = $mock_api->get_requests();
is(scalar(@requests), 1, "One request tracked");
is($requests[0]->{messages}[0]{content}, 'Hi, can you hear me?', "Request content recorded");

# Test tool calls response
$mock_api->set_response({
    tool_calls => [{
        id => 'call_123',
        type => 'function',
        function => {
            name => 'file_operations',
            arguments => '{"operation": "read_file", "path": "test.txt"}'
        }
    }]
});

my $tool_result = $mock_api->chat_completion(messages => $messages);
ok($tool_result->{choices}[0]{message}{tool_calls}, "Response has tool_calls");
is($tool_result->{choices}[0]{message}{tool_calls}[0]{function}{name}, 'file_operations', "Tool name correct");
is($tool_result->{choices}[0]{finish_reason}, 'tool_calls', "Finish reason is 'tool_calls'");

# Test error simulation
$mock_api->set_error("Rate limit exceeded");
eval {
    $mock_api->chat_completion(messages => $messages);
};
like($@, qr/Rate limit exceeded/, "Error properly thrown");

# Test usage tracking
$mock_api->clear_error();
$mock_api->set_response({ content => "Test response" });
my $usage_result = $mock_api->chat_completion(messages => $messages);
ok($usage_result->{usage}, "Response has usage data");
ok($usage_result->{usage}{prompt_tokens} > 0, "Prompt tokens counted");
ok($usage_result->{usage}{completion_tokens} > 0, "Completion tokens counted");

# Cleanup
chdir '/';

done_testing();
