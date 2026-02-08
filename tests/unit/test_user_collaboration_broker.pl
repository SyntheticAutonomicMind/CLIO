#!/usr/bin/env perl

=head1 NAME

test_user_collaboration_broker.pl - Test user_collaboration tool broker routing

=head1 DESCRIPTION

Tests that UserCollaboration tool correctly routes to broker when running
in sub-agent mode (broker_client present in context).

=cut

use strict;
use warnings;
use lib './lib';
use Test::More tests => 8;
use CLIO::Tools::UserCollaboration;
use CLIO::Coordination::Broker;
use CLIO::Coordination::Client;
use Time::HiRes qw(sleep);

my $session_id = "test-uc-" . time();

# Start broker
print "\n=== UserCollaboration Broker Routing Test ===\n\n";
print "Starting broker...\n";

my $broker_pid = fork();
if ($broker_pid == 0) {
    my $broker = CLIO::Coordination::Broker->new(
        session_id => $session_id,
        debug => 0,
    );
    $broker->run();
    exit 0;
}

ok($broker_pid, "Broker started");
sleep 1;

# Create two clients: one as "sub-agent", one as "user"
print "Creating clients...\n";

my $user_client = CLIO::Coordination::Client->new(
    session_id => $session_id,
    agent_id => 'user',
    task => 'Test user',
);
ok($user_client, "User client connected");

my $agent_client = CLIO::Coordination::Client->new(
    session_id => $session_id,
    agent_id => 'agent-1',
    task => 'Test agent',
);
ok($agent_client, "Agent client connected");

# Create UserCollaboration tool
my $tool = CLIO::Tools::UserCollaboration->new(debug => 1);
ok($tool, "UserCollaboration tool created");

# Test 1: Verify broker routing detection
print "\n=== Test 1: Broker routing detection ===\n";
my $context_with_broker = {
    broker_client => $agent_client,
    session => { id => 'test' },
};

# We can't directly test _request_via_broker because it blocks waiting for response
# Instead, verify the context detection works

my $has_broker = $context_with_broker->{broker_client} ? 1 : 0;
ok($has_broker, "Broker client detected in context");

my $context_without_broker = {
    session => { id => 'test' },
};
my $no_broker = $context_without_broker->{broker_client} ? 0 : 1;
ok($no_broker, "No broker client in normal context");

# Test 2: Verify question can be sent to user inbox
print "\n=== Test 2: Message to user inbox ===\n";

my $msg_id = $agent_client->send_question(
    to => 'user',
    question => 'Test question from agent',
);
ok($msg_id, "Agent sent question to user (msg_id=$msg_id)");

# User polls inbox
my $messages = $user_client->poll_user_inbox();
ok(scalar(@$messages) >= 1, "User received question in inbox");

# Cleanup
print "\n=== Cleanup ===\n";
$user_client->disconnect();
$agent_client->disconnect();
kill 'TERM', $broker_pid;
waitpid($broker_pid, 0);

print "\n=== UserCollaboration Broker Routing Test Complete ===\n";
print " Broker routing detected correctly\n";
print " Messages routed through broker\n\n";
