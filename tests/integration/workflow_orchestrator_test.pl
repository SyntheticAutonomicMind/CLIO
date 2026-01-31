#!/usr/bin/env perl

=head1 NAME

workflow_orchestrator_test.pl - Test WorkflowOrchestrator components with mock

=head1 DESCRIPTION

Tests the WorkflowOrchestrator-related components without requiring real API keys.
Uses MockAPI for testing API interactions.

=cut

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../lib";
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json decode_json);

# Setup test environment
my $test_dir = tempdir(CLEANUP => 1);
chdir $test_dir;
mkdir '.clio';
mkdir '.clio/sessions';

print "=" x 60 . "\n";
print "WorkflowOrchestrator Component Test\n";
print "=" x 60 . "\n\n";

# Test 1: Basic module loading
use_ok('CLIO::Core::WorkflowOrchestrator');
use_ok('CLIO::Test::MockAPI');
use_ok('CLIO::Session::Manager');
use_ok('CLIO::Core::ToolExecutor');
use_ok('CLIO::Tools::Registry');
use_ok('CLIO::Tools::FileOperations');

# Test 2: Create components
my $mock_api = CLIO::Test::MockAPI->new(
    model => 'mock-gpt-4',
    debug => 0,
);
ok($mock_api, "MockAPI created");

my $session = CLIO::Session::Manager->create(
    working_directory => $test_dir,
    debug => 0
);
ok($session, "Session created");

# Test 3: Create registry and register file operations
my $registry = CLIO::Tools::Registry->new(debug => 0);
ok($registry, "Registry created");

my $file_ops = CLIO::Tools::FileOperations->new();
ok($file_ops, "FileOperations tool created");

$registry->register_tool($file_ops);
ok($registry->get_tool('file_operations'), "FileOperations registered in registry");

# Test 4: Create ToolExecutor with registry
my $executor = CLIO::Core::ToolExecutor->new(
    session => $session,
    tool_registry => $registry,
    debug => 0,
);
ok($executor, "ToolExecutor created");

# Test 5: Execute a file_operations tool (proper format)
my $tool_call = {
    function => {
        name => 'file_operations',
        arguments => encode_json({
            operation => 'create_file',
            path => 'test.txt',
            content => 'Hello, World!'
        })
    }
};

my $tool_result = $executor->execute_tool($tool_call, 'call_001');
ok($tool_result, "Tool execution returned result");

# Parse the result (it's JSON)
my $result_data = eval { decode_json($tool_result) };
ok($result_data, "Result is valid JSON");
ok($result_data->{success}, "Tool execution succeeded: " . ($result_data->{message} || ''));
ok(-f 'test.txt', "File was created");

# Test 6: Read back the file
my $read_call = {
    function => {
        name => 'file_operations',
        arguments => encode_json({
            operation => 'read_file',
            path => 'test.txt'
        })
    }
};

my $read_result = $executor->execute_tool($read_call, 'call_002');
my $read_data = eval { decode_json($read_result) };
ok($read_data, "Read result is valid JSON");
ok($read_data->{success}, "File read succeeded");
like($read_data->{output}, qr/Hello, World!/, "File content matches (in output field)");

# Test 7: MockAPI response simulation - tool call
$mock_api->set_response({
    tool_calls => [{
        id => 'call_abc123',
        type => 'function',
        function => {
            name => 'file_operations',
            arguments => '{"operation": "read_file", "path": "test.txt"}'
        }
    }]
});

my $api_result = $mock_api->chat_completion(
    messages => [{ role => 'user', content => 'Read test.txt' }]
);
ok($api_result->{choices}[0]{message}{tool_calls}, "MockAPI returns tool calls");
is($api_result->{choices}[0]{finish_reason}, 'tool_calls', "Finish reason is tool_calls");

# Test 8: MockAPI response simulation - final answer
$mock_api->set_response({
    content => 'The file test.txt contains: Hello, World!'
});

my $final_result = $mock_api->chat_completion(
    messages => [
        { role => 'user', content => 'Read test.txt' },
        { role => 'assistant', tool_calls => $api_result->{choices}[0]{message}{tool_calls} },
        { role => 'tool', tool_call_id => 'call_abc123', content => 'Hello, World!' },
    ]
);
like($final_result->{choices}[0]{message}{content}, qr/Hello, World!/, "Final response contains file content");

# Test 9: Error handling in MockAPI
$mock_api->set_error("Simulated API failure");
eval {
    $mock_api->chat_completion(messages => [{ role => 'user', content => 'test' }]);
};
like($@, qr/Simulated API failure/, "Error properly propagated");

# Test 10: Request tracking
$mock_api->clear_error();
$mock_api->clear_requests();
$mock_api->set_response({ content => "response 1" });
$mock_api->chat_completion(messages => [{ role => 'user', content => 'message 1' }]);
$mock_api->set_response({ content => "response 2" });
$mock_api->chat_completion(messages => [{ role => 'user', content => 'message 2' }]);

my @requests = $mock_api->get_requests();
is(scalar(@requests), 2, "Two requests tracked");
is($requests[0]->{messages}[0]{content}, 'message 1', "First request content correct");
is($requests[1]->{messages}[0]{content}, 'message 2', "Second request content correct");

# Cleanup
chdir '/';

print "\n";
print "=" x 60 . "\n";
print "Test Complete\n";
print "=" x 60 . "\n";

done_testing();
