#!/usr/bin/env perl

=head1 NAME

test_autonomous_subagent.pl - Verify sub-agents work autonomously

=head1 DESCRIPTION

Spawns a sub-agent with a simple task and verifies:
1. No user_collaboration calls in log
2. Task completes successfully
3. Autonomous behavior throughout

=cut

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use File::Temp qw(tempdir);
use Time::HiRes qw(sleep);

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

print "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n";
print "  Testing Autonomous Sub-Agent Behavior\n";
print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n";

# Setup
my $test_dir = tempdir(CLEANUP => 1);
my $test_file = "$test_dir/autonomous_test.txt";
my $task = "create $test_file with the text 'Autonomous agent test successful'";

print " Task: $task\n";
print " Test dir: $test_dir\n\n";

# Spawn sub-agent via CLIO command
print " [1/4] Spawning sub-agent...\n";
my $cmd = "$RealBin/../../clio --input '/subagent spawn \"$task\" --model gpt-5-mini' --exit 2>&1";
my $output = `$cmd`;
my $exit_code = $? >> 8;

if ($exit_code != 0) {
    print " FAIL - Command failed with exit code $exit_code\n";
    print "Output:\n$output\n";
    exit 1;
}

# Extract agent ID from output
my $agent_id;
if ($output =~ /Spawned sub-agent: (agent-\d+)/m) {
    $agent_id = $1;
    print " PASS - Agent spawned: $agent_id\n";
} else {
    print " FAIL - Could not find agent ID in output\n";
    print "Output:\n$output\n";
    exit 1;
}

# Wait for agent to complete
print "\n [2/4] Waiting for agent to complete (max 30s)...\n";
my $log_file = "/tmp/clio-agent-$agent_id.log";
my $wait_time = 0;
my $max_wait = 30;

while ($wait_time < $max_wait) {
    sleep(1);
    $wait_time++;
    
    if (-f $log_file) {
        my $log_content = do {
            open(my $fh, '<', $log_file) or die "Cannot read log: $!";
            local $/;
            <$fh>;
        };
        
        # Check for completion indicators
        if ($log_content =~ /exit|completed|finished/i) {
            print " PASS - Agent completed after ${wait_time}s\n";
            last;
        }
    }
}

if ($wait_time >= $max_wait) {
    print " WARN - Agent did not complete within ${max_wait}s\n";
}

# Check log for user_collaboration calls (should be NONE)
print "\n [3/4] Checking for user_collaboration calls...\n";
if (-f $log_file) {
    my $log_content = do {
        open(my $fh, '<', $log_file) or die "Cannot read log: $!";
        local $/;
        <$fh>;
    };
    
    if ($log_content =~ /user_collaboration|USER_COLLABORATION|Requesting your input/m) {
        print " FAIL - Found user_collaboration call in log\n";
        print "Log excerpt:\n";
        system("grep -A 3 -B 3 'user_collaboration\\|Requesting your input' $log_file");
        exit 1;
    } else {
        print " PASS - No user_collaboration calls found\n";
    }
} else {
    print " WARN - Log file not found: $log_file\n";
}

# Verify task completion
print "\n [4/4] Verifying task completion...\n";
if (-f $test_file) {
    my $content = do {
        open(my $fh, '<', $test_file) or die "Cannot read test file: $!";
        local $/;
        <$fh>;
    };
    
    if ($content =~ /Autonomous agent test successful/) {
        print " PASS - Task completed successfully\n";
        print "File content: $content\n";
    } else {
        print " FAIL - File created but content incorrect\n";
        print "Expected: 'Autonomous agent test successful'\n";
        print "Got: $content\n";
        exit 1;
    }
} else {
    print " FAIL - Test file not created: $test_file\n";
    exit 1;
}

print "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n";
print "  ✓ All Tests PASSED\n";
print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n";

exit 0;
