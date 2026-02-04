#!/usr/bin/env perl

use strict;
use warnings;
use lib 'lib';
use CLIO::Core::ToolExecutor;
use CLIO::Tools::Registry;
use CLIO::Tools::FileOperations;
use JSON::PP qw(encode_json decode_json);

print "Testing tool aliasing...\n";

# Setup
my $registry = CLIO::Tools::Registry->new(debug => 0);
$registry->register_tool(CLIO::Tools::FileOperations->new());

my $executor = CLIO::Core::ToolExecutor->new(
    tool_registry => $registry,
    debug => 1
);

# Test 1: Call grep_search as a tool (should be aliased)
print "\nTest 1: Calling 'grep_search' as tool name (should alias to file_operations)...\n";
my $result_json = $executor->execute_tool(
    'test_call_1',
    'grep_search',
    encode_json({ query => 'test', pattern => '*.txt' })
);

my $result = decode_json($result_json);
if ($result->{success} || $result->{error} !~ /Unknown tool/) {
    print "✓ grep_search was aliased successfully!\n";
    print "  Operation used: " . ($result->{operation} || 'grep_search') . "\n";
} else {
    print "✗ FAILED: grep_search not aliased\n";
    print "  Error: $result->{error}\n";
}

# Test 2: Call file_operations normally (should still work)
print "\nTest 2: Calling 'file_operations' normally...\n";
$result_json = $executor->execute_tool(
    'test_call_2',
    'file_operations',
    encode_json({ operation => 'grep_search', query => 'test', pattern => '*.txt' })
);

$result = decode_json($result_json);
if ($result->{success} || $result->{error} !~ /Unknown tool/) {
    print "✓ file_operations works normally!\n";
} else {
    print "✗ FAILED: file_operations broken\n";
    print "  Error: $result->{error}\n";
}

print "\nDone!\n";
