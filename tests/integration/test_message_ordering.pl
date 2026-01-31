#!/usr/bin/perl
use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../../lib";

=head1 NAME

test_message_ordering.pl - Verify agent messages appear before tool execution output

=head1 DESCRIPTION

This test ensures that when the AI calls tools, the output ordering is correct:
1. AGENT: label and message should print first
2. Then blank line separator
3. Then SYSTEM: [tool_name] output

REQUIRES: Actual API key configured (makes real API calls)

=cut

# Get the clio path relative to this test's location
my $clio_path = "$FindBin::Bin/../../clio";
unless (-f $clio_path) {
    print "SKIP: Cannot find clio executable at $clio_path\n";
    exit 0;  # Skip rather than fail
}

# Check if we have any API configuration
# This test requires a real API to work
my $config_file = "$ENV{HOME}/.clio/config.json";
unless (-f $config_file) {
    print "SKIP: No API configuration found (requires real API for this test)\n";
    exit 0;
}

# Simple test: parse CLI output and verify ordering
my $test_input = "List 5 files from lib/CLIO/Core/ using file_operations";
my $session_id = `$clio_path --new --input "$test_input" --exit 2>&1`;

# Look for key markers
if ($session_id =~ /AGENT:.*?SYSTEM:\s*\[file_operations\]/s) {
    print "✓ Test PASSED: Agent message appears before tool output\n";
    exit 0;
} else {
    print "✗ Test FAILED: Agent message and tool output not in correct order\n";
    print "Output was:\n$session_id\n";
    exit 1;
}
