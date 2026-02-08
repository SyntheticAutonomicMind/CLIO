#!/usr/bin/env perl
# Test script for multi-agent coordination system
# This demonstrates two agents competing for the same file lock

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use CLIO::Coordination::Broker;
use CLIO::Coordination::Client;
use Time::HiRes qw(sleep time);

my $SESSION_ID = "test-" . time();
my $BROKER_LOG = "/tmp/clio-broker-test.log";

print "=== CLIO Multi-Agent Coordination Test ===\n\n";
print "[Main] Session ID: $SESSION_ID\n";
print "[Main] Broker log: $BROKER_LOG\n\n";

# Fork broker process
my $broker_pid = fork();
die "Fork failed: $!" unless defined $broker_pid;

if ($broker_pid == 0) {
    # Child process - run broker
    # Redirect STDERR to log file
    open(STDERR, '>>', $BROKER_LOG) or die "Cannot open log: $!";
    
    my $broker = CLIO::Coordination::Broker->new(
        session_id => $SESSION_ID,
        debug => 1,
    );
    $broker->run();
    exit 0;
}

# Parent process - give broker time to start
sleep 1;

print "[Main] Broker started (PID: $broker_pid)\n\n";

# Test 1: Single agent file lock
print "TEST 1: Single agent requesting file lock\n";
print "-" x 50 . "\n";

eval {
    my $agent1 = CLIO::Coordination::Client->new(
        session_id => $SESSION_ID,
        agent_id => 'agent-1',
        task => 'Test file locking',
        debug => 0,  # Disable debug output for cleaner test output
    );
    
    my $success = $agent1->request_file_lock(['lib/Test/Module.pm']);
    if ($success) {
        print "[agent-1] [OK] Got file lock\n";
        $agent1->release_file_lock(['lib/Test/Module.pm']);
        print "[agent-1] [OK] Released file lock\n";
    } else {
        print "[agent-1] [FAIL] Could not get file lock\n";
    }
    
    $agent1->disconnect();
};
if ($@) {
    print "[agent-1] [ERROR] $@\n";
}

print "\n";

# Test 2: Two agents competing for same file
print "TEST 2: Two agents competing for same file\n";
print "-" x 50 . "\n";

eval {
    my $agent1 = CLIO::Coordination::Client->new(
        session_id => $SESSION_ID,
        agent_id => 'agent-1',
        task => 'Hold file lock',
        debug => 0,
    );
    
    my $agent2 = CLIO::Coordination::Client->new(
        session_id => $SESSION_ID,
        agent_id => 'agent-2',
        task => 'Compete for file lock',
        debug => 0,
    );
    
    # Agent 1 locks the file
    print "[agent-1] Requesting file lock...\n";
    if ($agent1->request_file_lock(['lib/Shared/File.pm'])) {
        print "[agent-1] [OK] Got file lock\n";
        
        # Agent 2 tries to lock the same file
        print "[agent-2] Requesting same file lock...\n";
        if ($agent2->request_file_lock(['lib/Shared/File.pm'])) {
            print "[agent-2] [FAIL] Got file lock (should have been denied!)\n";
        } else {
            print "[agent-2] [OK] File lock denied (already held by agent-1)\n";
        }
        
        # Agent 1 releases, agent 2 tries again
        print "[agent-1] Releasing file lock...\n";
        $agent1->release_file_lock(['lib/Shared/File.pm']);
        
        sleep 0.2;
        
        print "[agent-2] Requesting file lock again...\n";
        if ($agent2->request_file_lock(['lib/Shared/File.pm'])) {
            print "[agent-2] [OK] Got file lock after agent-1 released\n";
            $agent2->release_file_lock(['lib/Shared/File.pm']);
        } else {
            print "[agent-2] [FAIL] Should have gotten lock\n";
        }
    }
    
    $agent1->disconnect();
    $agent2->disconnect();
};
if ($@) {
    print "[TEST 2] [ERROR] $@\n";
}

print "\n";

# Test 3: Git lock coordination
print "TEST 3: Git lock coordination\n";
print "-" x 50 . "\n";

eval {
    my $agent1 = CLIO::Coordination::Client->new(
        session_id => $SESSION_ID,
        agent_id => 'agent-1',
        task => 'Test git locking',
        debug => 0,
    );
    
    my $agent2 = CLIO::Coordination::Client->new(
        session_id => $SESSION_ID,
        agent_id => 'agent-2',
        task => 'Compete for git lock',
        debug => 0,
    );
    
    print "[agent-1] Requesting git lock...\n";
    if ($agent1->request_git_lock()) {
        print "[agent-1] [OK] Got git lock\n";
        
        print "[agent-2] Requesting git lock...\n";
        if ($agent2->request_git_lock()) {
            print "[agent-2] [FAIL] Got git lock (should have been denied!)\n";
        } else {
            print "[agent-2] [OK] Git lock denied (held by agent-1)\n";
        }
        
        print "[agent-1] Releasing git lock...\n";
        $agent1->release_git_lock();
        
        sleep 0.2;
        
        print "[agent-2] Requesting git lock again...\n";
        if ($agent2->request_git_lock()) {
            print "[agent-2] [OK] Got git lock after agent-1 released\n";
            $agent2->release_git_lock();
        } else {
            print "[agent-2] [FAIL] Should have gotten git lock\n";
        }
    }
    
    $agent1->disconnect();
    $agent2->disconnect();
};
if ($@) {
    print "[TEST 3] [ERROR] $@\n";
}

print "\n";

# Test 4: Status query
print "TEST 4: Querying broker status\n";
print "-" x 50 . "\n";

eval {
    my $agent1 = CLIO::Coordination::Client->new(
        session_id => $SESSION_ID,
        agent_id => 'agent-1',
        task => 'Query status',
        debug => 0,
    );
    
    my $status = $agent1->get_status();
    if ($status && $status->{type} eq 'status') {
        print "[agent-1] [OK] Broker status received:\n";
        print "  Agents: " . scalar(keys %{$status->{agents}}) . "\n";
        print "  File locks: " . scalar(keys %{$status->{file_locks}}) . "\n";
        print "  Git lock holder: " . ($status->{git_lock}{holder} || 'none') . "\n";
    } else {
        print "[agent-1] [FAIL] Could not get status\n";
    }
    
    $agent1->disconnect();
};
if ($@) {
    print "[TEST 4] [ERROR] $@\n";
}

print "\n";

# Test 5: Knowledge sharing
print "TEST 5: Knowledge sharing (discoveries and warnings)\n";
print "-" x 50 . "\n";

eval {
    my $agent1 = CLIO::Coordination::Client->new(
        session_id => $SESSION_ID,
        agent_id => 'agent-1',
        task => 'Share knowledge',
        debug => 0,
    );
    
    my $agent2 = CLIO::Coordination::Client->new(
        session_id => $SESSION_ID,
        agent_id => 'agent-2',
        task => 'Receive knowledge',
        debug => 0,
    );
    
    # Agent 1 shares a discovery
    print "[agent-1] Sending discovery...\n";
    $agent1->send_discovery("All config files use Config::IniFiles", "pattern");
    
    # Agent 1 shares a warning
    print "[agent-1] Sending warning...\n";
    $agent1->send_warning("Don't edit lib/Core/API.pm - circular dependencies", "high");
    
    sleep 0.2;
    
    # Agent 2 retrieves discoveries
    print "[agent-2] Retrieving discoveries...\n";
    my $discoveries = $agent2->get_discoveries();
    if (@$discoveries) {
        print "[agent-2] [OK] Found " . scalar(@$discoveries) . " discovery(ies):\n";
        for my $d (@$discoveries) {
            print "         - [$d->{category}] $d->{content} (from $d->{agent})\n";
        }
    } else {
        print "[agent-2] [FAIL] No discoveries found\n";
    }
    
    # Agent 2 retrieves warnings
    print "[agent-2] Retrieving warnings...\n";
    my $warnings = $agent2->get_warnings();
    if (@$warnings) {
        print "[agent-2] [OK] Found " . scalar(@$warnings) . " warning(s):\n";
        for my $w (@$warnings) {
            print "         - [$w->{severity}] $w->{content} (from $w->{agent})\n";
        }
    } else {
        print "[agent-2] [FAIL] No warnings found\n";
    }
    
    $agent1->disconnect();
    $agent2->disconnect();
};
if ($@) {
    print "[TEST 5] [ERROR] $@\n";
}

print "\n";

# Cleanup
print "=== Cleanup ===\n";
kill 'TERM', $broker_pid;
waitpid($broker_pid, 0);
print "[Main] Broker shut down\n";
print "[Main] Check broker log: $BROKER_LOG\n";

print "\n=== All tests complete! ===\n";
