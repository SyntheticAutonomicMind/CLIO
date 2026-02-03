#!/usr/bin/perl
use strict;
use warnings;
use utf8;
use lib './lib';

use CLIO::Core::ToolErrorGuidance;

# Test the error guidance system
my $guidance = CLIO::Core::ToolErrorGuidance->new();

# Simulate a user_collaboration error
my $user_collab_def = {
    name => 'user_collaboration',
    description => 'Request user input',
    parameters => {
        type => 'object',
        properties => {
            operation => {
                type => 'string',
                enum => ['request_input'],
                description => 'Operation to perform'
            },
            message => {
                type => 'string',
                description => 'The question/update for the user'
            },
            context => {
                type => 'string',
                description => 'Optional context'
            }
        },
        required => ['operation', 'message']
    }
};

print "Testing error guidance system...\n\n";
print "=" x 80 . "\n";

# Test 1: Missing required parameter
print "Test 1: Missing required parameter (message)\n";
print "-" x 80 . "\n";
my $enhanced1 = $guidance->enhance_tool_error(
    error => 'Missing required parameter: message',
    tool_name => 'user_collaboration',
    tool_definition => $user_collab_def,
    attempted_params => { operation => 'request_input' }
);
print $enhanced1;
print "\n" . "=" x 80 . "\n\n";

# Test 2: Invalid operation
print "Test 2: Invalid operation\n";
print "-" x 80 . "\n";
my $enhanced2 = $guidance->enhance_tool_error(
    error => 'Unknown operation: invalid_op',
    tool_name => 'user_collaboration',
    tool_definition => $user_collab_def,
    attempted_params => { operation => 'invalid_op' }
);
print $enhanced2;
print "\n" . "=" x 80 . "\n\n";

# Test 3: File operations - missing path
print "Test 3: File operations - missing path\n";
print "-" x 80 . "\n";
my $file_op_def = {
    name => 'file_operations',
    description => 'File operations',
    parameters => {
        type => 'object',
        properties => {
            operation => {
                type => 'string',
                enum => ['read_file', 'write_file', 'grep_search'],
                description => 'Operation to perform'
            },
            path => {
                type => 'string',
                description => 'File path'
            }
        },
        required => ['operation', 'path']
    }
};

my $enhanced3 = $guidance->enhance_tool_error(
    error => 'Missing required parameters: operation, path',
    tool_name => 'file_operations',
    tool_definition => $file_op_def,
    attempted_params => {}
);
print $enhanced3;
print "\n" . "=" x 80 . "\n\n";

print "All tests completed!\n";
