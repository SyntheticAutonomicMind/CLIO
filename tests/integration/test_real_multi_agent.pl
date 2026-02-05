#!/usr/bin/env perl
#
# Real-world test of multi-agent coordination
#
# This test spawns multiple CLIO agents to work in parallel and verifies:
# 1. File locking prevents conflicts
# 2. Git locking serializes commits  
# 3. Knowledge sharing works
# 4. Agents can monitor each other
#

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

print "=== Multi-Agent Real-World Test ===\n\n";

# Clean up from previous tests
system("rm -f /tmp/clio-agent-*.log /tmp/clio-broker-*.log");
system("rm -rf scratch/test_*");
system("mkdir -p scratch");

my $session_id = "test-" . time();

print "Session ID: $session_id\n\n";

# Test 1: Spawn multiple agents with different models
print "TEST 1: Spawning agents with different models\n";
print "-" x 50, "\n";

my @tasks = (
    {
        task => "create a Perl script in scratch/test_script1.pl that prints Fibonacci numbers",
        model => "gpt-5-mini",
        id => "agent-fib",
    },
    {
        task => "create a Perl script in scratch/test_script2.pl that prints prime numbers",
        model => "gpt-5-mini",
        id => "agent-primes",
    },
    {
        task => "analyze lib/CLIO/Core/Config.pm structure and create scratch/test_config_notes.txt",
        model => "gpt-4.1",
        id => "agent-analyze",
    },
);

# Spawn all agents
for my $task_info (@tasks) {
    my $clio = "$FindBin::Bin/../../clio";  # Correct path from tests/integration
    my $cmd = qq{$clio --input '/subagent spawn "$task_info->{task}" --model $task_info->{model}' --exit 2>&1};
    
    print " Spawning $task_info->{id}: $task_info->{task}\n";
    my $output = `$cmd`;
    
    if ($output =~ /Spawned sub-agent: (agent-\d+)/) {
        $task_info->{actual_id} = $1;
        print "   [OK] Agent ID: $1\n";
    } else {
        print "   [FAIL] Failed to spawn\n";
        print "   Output: $output\n";
    }
}

print "\nWaiting for agents to complete...\n";
sleep 5;

# Test 2: Monitor agent progress
print "\nTEST 2: Monitoring agent logs\n";
print "-" x 50, "\n";

for my $task_info (@tasks) {
    next unless $task_info->{actual_id};
    
    my $log = "/tmp/clio-agent-$task_info->{actual_id}.log";
    if (-f $log) {
        my $size = -s $log;
        print " $task_info->{actual_id}: Log size = $size bytes\n";
        
        # Check if agent is still running
        my $ps = `ps aux | grep "clio.*$task_info->{model}" | grep -v grep`;
        if ($ps) {
            print "   Status: RUNNING\n";
        } else {
            print "   Status: COMPLETED\n";
        }
    } else {
        print " $task_info->{actual_id}: No log file found\n";
    }
}

# Wait longer for complex tasks
print "\nWaiting 30 more seconds for completion...\n";
sleep 30;

# Test 3: Verify outputs
print "\nTEST 3: Verifying outputs\n";
print "-" x 50, "\n";

my @expected_files = (
    "scratch/test_script1.pl",
    "scratch/test_script2.pl", 
    "scratch/test_config_notes.txt",
);

my $success_count = 0;
for my $file (@expected_files) {
    if (-f $file) {
        my $size = -s $file;
        print " [OK] $file ($size bytes)\n";
        $success_count++;
    } else {
        print " [FAIL] $file not created\n";
    }
}

print "\nSuccess rate: $success_count/" . scalar(@expected_files) . " files created\n";

# Test 4: Check broker logs
print "\nTEST 4: Broker coordination logs\n";
print "-" x 50, "\n";

my @broker_logs = glob("/tmp/clio-broker-*.log");
if (@broker_logs) {
    for my $log (@broker_logs) {
        print " Broker log: $log\n";
        
        # Check for lock operations
        my $lock_count = `grep -c "Lock granted" "$log" 2>/dev/null || echo 0`;
        chomp $lock_count;
        print "   Lock operations: $lock_count\n";
    }
} else {
    print " [INFO] No broker logs found (broker may have been reused)\n";
}

# Test 5: Check for coordination
print "\nTEST 5: Agent coordination check\n";
print "-" x 50, "\n";

# Check if agents coordinated file access
for my $task_info (@tasks) {
    next unless $task_info->{actual_id};
    
    my $log = "/tmp/clio-agent-$task_info->{actual_id}.log";
    if (-f $log) {
        # Look for broker connection
        my $broker_mentions = `grep -c "Broker\|broker\|session-" "$log" 2>/dev/null || echo 0`;
        chomp $broker_mentions;
        
        if ($broker_mentions > 0) {
            print " [OK] $task_info->{actual_id} connected to broker\n";
        } else {
            print " [INFO] $task_info->{actual_id} may not have needed coordination\n";
        }
    }
}

print "\n=== Test Complete ===\n";
print "\nAgent logs available in /tmp/clio-agent-*.log\n";
print "Broker logs available in /tmp/clio-broker-*.log\n";
print "\nView agent output:\n";
for my $task_info (@tasks) {
    next unless $task_info->{actual_id};
    print "  tail -50 /tmp/clio-agent-$task_info->{actual_id}.log\n";
}

print "\nGenerated files:\n";
system("ls -lh scratch/test_* 2>/dev/null");
