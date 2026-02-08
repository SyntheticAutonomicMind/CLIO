#!/usr/bin/env perl

=head1 NAME

test_e2e_subagent.pl - End-to-end test for sub-agent functionality

=head1 DESCRIPTION

Tests the full sub-agent workflow with real AI models:
1. Single agent test - one sub-agent completes a task
2. Multi-agent test - two agents collaborate

Requires: CLIO configured with API access (GitHub Copilot or OpenAI)

=cut

use strict;
use warnings;
use lib './lib';
use Cwd;
use File::Path qw(make_path remove_tree);
use Time::HiRes qw(sleep);

# Configuration
my $CLIO = "./clio";
my $SCRATCH_DIR = "scratch/e2e-test-" . time();
my $TIMEOUT = 120;  # 2 minutes per test

print "\n" . "=" x 60 . "\n";
print "  CLIO Sub-Agent End-to-End Tests\n";
print "=" x 60 . "\n\n";

# Create scratch directory
make_path($SCRATCH_DIR) or die "Cannot create $SCRATCH_DIR: $!";
print "Created test directory: $SCRATCH_DIR\n\n";

# Test 1: Single agent (oneshot mode)
print "=" x 60 . "\n";
print "TEST 1: Single Agent (Oneshot Mode)\n";
print "=" x 60 . "\n\n";

my $task1 = "Create a file at $SCRATCH_DIR/agent-test.txt with the content 'Hello from sub-agent'";
print "Task: $task1\n\n";

my $result1 = run_clio_test(
    input => "/subagent spawn \"$task1\" --model gpt-5-mini",
    wait_for_completion => 1,
);

# Check if file was created
sleep 5;  # Wait for agent to complete
if (-f "$SCRATCH_DIR/agent-test.txt") {
    my $content = do { local $/; open my $fh, '<', "$SCRATCH_DIR/agent-test.txt"; <$fh> };
    if ($content && $content =~ /Hello/i) {
        print "PASS: File created with expected content\n";
        print "  Content: $content\n";
    } else {
        print "FAIL: File exists but content doesn't match\n";
        print "  Content: $content\n";
    }
} else {
    print "FAIL: File was not created\n";
    print "  Checking agent log...\n";
    my @logs = glob("/tmp/clio-agent-*.log");
    if (@logs) {
        my $log = $logs[-1];
        print "  Last log: $log\n";
        system("tail -20 '$log'");
    }
}

# Test 2: Two agents collaborating
print "\n" . "=" x 60 . "\n";
print "TEST 2: Two Agents Collaborating\n";
print "=" x 60 . "\n\n";

my $task2a = "Create a file at $SCRATCH_DIR/part1.txt with the text 'Part 1 from agent A'";
my $task2b = "Create a file at $SCRATCH_DIR/part2.txt with the text 'Part 2 from agent B'";

print "Task A (gpt-5-mini): $task2a\n";
print "Task B (gpt-4.1): $task2b\n\n";

# Spawn both agents in parallel using a session
my $input2 = <<INPUT;
/subagent spawn "$task2a" --model gpt-5-mini
/subagent spawn "$task2b" --model gpt-4.1
/exit
INPUT

my $result2 = run_clio_session($input2);

# Wait for agents to complete
print "Waiting for agents to complete...\n";
sleep 10;

# Check results
my $pass2 = 1;
for my $file ("$SCRATCH_DIR/part1.txt", "$SCRATCH_DIR/part2.txt") {
    if (-f $file) {
        my $content = do { local $/; open my $fh, '<', $file; <$fh> };
        print "PASS: $file created\n";
        print "  Content: $content\n";
    } else {
        print "FAIL: $file was not created\n";
        $pass2 = 0;
    }
}

# Summary
print "\n" . "=" x 60 . "\n";
print "  Test Summary\n";
print "=" x 60 . "\n\n";

print "Test 1 (Single Agent): " . (-f "$SCRATCH_DIR/agent-test.txt" ? "PASS" : "FAIL") . "\n";
print "Test 2 (Multi-Agent): " . ($pass2 ? "PASS" : "FAIL") . "\n";

print "\nTest artifacts in: $SCRATCH_DIR\n";
print "Agent logs in: /tmp/clio-agent-*.log\n";
print "\n";

# Helper functions
sub run_clio_test {
    my %args = @_;
    my $input = $args{input};
    
    print "Running: $CLIO --input '$input' --exit\n\n";
    my $output = `$CLIO --input '$input' --exit 2>&1`;
    print $output;
    return $output;
}

sub run_clio_session {
    my ($input) = @_;
    
    # Create temp file with commands
    my $tmp = "/tmp/clio-e2e-input-$$.txt";
    open my $fh, '>', $tmp or die "Cannot write $tmp: $!";
    print $fh $input;
    close $fh;
    
    print "Running CLIO session with commands:\n$input\n";
    my $output = `$CLIO --new < '$tmp' 2>&1`;
    unlink $tmp;
    
    print $output;
    return $output;
}
