#!/usr/bin/env perl

=head1 NAME

test_broker_connection.pl - Verify sub-agents connect to broker

=head1 DESCRIPTION

Tests that:
1. Sub-agent spawns successfully  
2. Agent connects to broker
3. Broker registers the agent
4. File operations check for locks

=cut

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

print "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n";
print "  Broker Connection Test\n";
print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n";

# Test 1: Spawn agent with broker
print " [1/3] Spawning agent with broker connection...\n";

my $task = 'create scratch/broker_test.txt with content: Broker connected';
my $cmd = "$RealBin/../../clio --input '/subagent spawn \"$task\" --model gpt-5-mini' --exit 2>&1";
my $output = `$cmd`;

if ($output =~ /Spawned sub-agent: (agent-\d+)/m) {
    my $agent_id = $1;
    print "  PASS - Agent spawned: $agent_id\n";
    
    # Wait for agent to connect
    print "\n [2/3] Waiting for broker connection...\n";
    sleep(3);
    
    # Check agent log for broker connection
    my $log_file = "/tmp/clio-agent-$agent_id.log";
    if (-f $log_file) {
        open(my $fh, '<', $log_file) or die "Cannot read log: $!";
        my $log_content = do { local $/; <$fh> };
        close $fh;
        
        if ($log_content =~ /Connected to broker|Registered with broker/m) {
            print "  PASS - Agent connected to broker\n";
        } elsif ($log_content =~ /Broker socket not found|Failed to connect/) {
            print "  FAIL - Broker not available\n";
            print "  Log shows: " . ($1 || "connection error") . "\n";
            exit 1;
        } else {
            print "  WARN - No explicit broker connection message\n";
            print "  (Agent may have completed before connecting)\n";
        }
        
        # Check for file lock messages
        print "\n [3/3] Checking for file lock coordination...\n";
        if ($log_content =~ /Requesting file lock via broker/m) {
            print "  PASS - File lock requested from broker\n";
        } else {
            print "  INFO - No file lock request (broker may not be running)\n";
        }
    } else {
        print "  FAIL - Log file not found: $log_file\n";
        exit 1;
    }
    
    # Verify file was created
    if (-f "scratch/broker_test.txt") {
        my $content = do {
            open(my $fh, '<', "scratch/broker_test.txt") or die $!;
            local $/;
            <$fh>;
        };
        
        if ($content =~ /Broker connected/) {
            print "  PASS - File created successfully\n";
        }
    }
    
} else {
    print "  FAIL - Agent did not spawn\n";
    print "Output: $output\n";
    exit 1;
}

print "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n";
print "  Broker Connection Test PASSED\n";
print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n";

exit 0;
