#!/usr/bin/env perl
# Demo: Multi-agent coordination system with broker, manager, and sub-agents

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use CLIO::Coordination::Broker;
use CLIO::Coordination::Client;
use CLIO::Coordination::SubAgent;
use Time::HiRes qw(sleep time);

my $SESSION_ID = "demo-" . time();

print "=== CLIO Multi-Agent System Demo ===\n\n";

# Start broker
my $broker_pid = fork();
die "Fork failed: $!" unless defined $broker_pid;

if ($broker_pid == 0) {
    open(STDERR, '>>', '/tmp/clio-demo-broker.log');
    my $broker = CLIO::Coordination::Broker->new(
        session_id => $SESSION_ID,
        debug => 1,
    );
    $broker->run();
    exit 0;
}

sleep 1;
print "[Manager] Broker started (PID: $broker_pid)\n";

# Create sub-agent manager
my $manager = CLIO::Coordination::SubAgent->new(
    session_id => $SESSION_ID,
    broker_pid => $broker_pid,
);

# Spawn three agents with different tasks
print "[Manager] Spawning agents...\n";
my $agent1_id = $manager->spawn_agent("Analyze lib/CLIO/Core/", duration => 3);
my $agent2_id = $manager->spawn_agent("Fix bugs in tests/", duration => 4);
my $agent3_id = $manager->spawn_agent("Update documentation", duration => 2);

print "[Manager] Spawned: $agent1_id, $agent2_id, $agent3_id\n\n";

# Monitor agents
print "[Manager] Monitoring agent status...\n";
for (1..5) {
    my $agents = $manager->list_agents();
    print "[Manager] Active agents: ";
    for my $id (sort keys %$agents) {
        my $agent = $agents->{$id};
        print "$id($agent->{status}) ";
    }
    print "\n";
    sleep 1;
}

# Wait for all to complete
print "\n[Manager] Waiting for all agents to finish...\n";
$manager->wait_all();

print "[Manager] All agents completed!\n\n";

# Show final status
my $final_agents = $manager->list_agents();
for my $id (sort keys %$final_agents) {
    my $agent = $final_agents->{$id};
    print "  - $id: $agent->{task} [$agent->{status}]\n";
}

# Cleanup
print "\n[Manager] Shutting down broker...\n";
kill 'TERM', $broker_pid;
waitpid($broker_pid, 0);

print "\n=== Demo complete! ===\n";
print "Check broker log: /tmp/clio-demo-broker.log\n";
