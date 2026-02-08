#!/usr/bin/env perl

use strict;
use warnings;
use lib './lib';
use Test::More tests => 10;
use CLIO::Coordination::Broker;
use CLIO::Coordination::Client;
use Time::HiRes qw(sleep);

my $session_id = "test-messaging-" . time();

# Test 1: Start broker
my $broker_pid = fork();
if ($broker_pid == 0) {
    my $broker = CLIO::Coordination::Broker->new(
        session_id => $session_id,
        debug => 1,
    );
    $broker->run();
    exit 0;
}

ok($broker_pid, "Broker started");
sleep 0.5;  # Give broker time to start

# Test 2-3: Connect two clients
my $client1 = CLIO::Coordination::Client->new(
    session_id => $session_id,
    agent_id => 'agent-1',
    task => 'Test agent 1',
    debug => 1,
);
ok($client1, "Client 1 connected");

my $client2 = CLIO::Coordination::Client->new(
    session_id => $session_id,
    agent_id => 'agent-2',
    task => 'Test agent 2',
    debug => 1,
);
ok($client2, "Client 2 connected");

# Test 4: Agent 1 sends message to user
my $msg_id = $client1->send_message(
    to => 'user',
    message_type => 'question',
    content => 'Should I proceed?',
);
ok($msg_id, "Agent 1 sent message to user");

# Test 5: Poll user inbox
my $user_messages = $client1->poll_user_inbox();
ok(scalar(@$user_messages) == 1, "User inbox has 1 message");
is($user_messages->[0]{from}, 'agent-1', "Message from agent-1");
is($user_messages->[0]{content}, 'Should I proceed?', "Correct content");

# Test 6: Agent 1 sends message to Agent 2
$msg_id = $client1->send_message(
    to => 'agent-2',
    message_type => 'discovery',
    content => 'Found a bug in module X',
);
ok($msg_id, "Agent 1 sent message to Agent 2");

# Test 7: Agent 2 polls inbox
my $agent2_messages = $client2->poll_my_inbox();
ok(scalar(@$agent2_messages) == 1, "Agent 2 inbox has 1 message");
is($agent2_messages->[0]{content}, 'Found a bug in module X', "Correct message received");

# Cleanup
$client1->disconnect();
$client2->disconnect();
kill 'TERM', $broker_pid;
waitpid($broker_pid, 0);

print "\n=== Message Bus Test Complete ===\n";
print "All messaging features working!\n";

done_testing();
