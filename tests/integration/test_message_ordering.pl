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

=cut

# Simple test: parse CLI output and verify ordering
my $test_input = "List 5 files from lib/CLIO/Core/ using file_operations";
my $session_id = `./clio --new --input "$test_input" --exit 2>&1`;

# Look for key markers
if ($session_id =~ /AGENT:.*?SYSTEM:\s*\[file_operations\]/s) {
    print "✓ Test PASSED: Agent message appears before tool output\n";
    exit 0;
} else {
    print "✗ Test FAILED: Agent message and tool output not in correct order\n";
    print "Output was:\n$session_id\n";
    exit 1;
}
