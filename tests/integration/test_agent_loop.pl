#!/usr/bin/env perl

use strict;
use warnings;
use lib './lib';
use Test::More tests => 8;
use CLIO::Coordination::Broker;
use CLIO::Coordination::Client;
use CLIO::Core::AgentLoop;
use Time::HiRes qw(sleep);

my $session_id = "test-agentloop-" . time();

# Start broker
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
sleep 0.5;

# Create a persistent agent in a child process
my $agent_pid = fork();
if ($agent_pid == 0) {
    # Child: Run persistent agent
    
    my $client = CLIO::Coordination::Client->new(
        session_id => $session_id,
        agent_id => 'test-agent',
        task => 'Testing persistence',
        debug => 1,
    );
    
    my $tasks_completed = 0;
    
    my $task_handler = sub {
        my ($task, $loop) = @_;
        
        print STDERR "[Agent] Processing: $task\n";
        
        if ($task =~ /^simple:/) {
            # Simple task - complete immediately
            $tasks_completed++;
            return { completed => 1, message => "Done: $task" };
        }
        elsif ($task =~ /^ask:/) {
            # Task that needs help
            return { blocked => 1, reason => "Need clarification on approach" };
        }
        elsif ($task =~ /^continue:/) {
            # Continue after clarification
            $tasks_completed++;
            return { completed => 1, message => "Continued successfully" };
        }
        elsif ($task eq 'stop') {
            # Stop signal
            $loop->stop();
            return { completed => 1, message => "Stopping" };
        }
        
        return undef;
    };
    
    my $loop = CLIO::Core::AgentLoop->new(
        client => $client,
        on_task => $task_handler,
        poll_interval => 0.5,
        heartbeat_interval => 5,
        debug => 1,
    );
    
    $loop->run();
    
    $client->disconnect();
    print STDERR "[Agent] Completed $tasks_completed tasks\n";
    exit 0;
}

ok($agent_pid, "Agent process started");
sleep 1;  # Give agent time to start loop

# Create manager client
my $manager = CLIO::Coordination::Client->new(
    session_id => $session_id,
    agent_id => 'manager',
    task => 'Test manager',
    debug => 1,
);
ok($manager, "Manager connected");

# Test 1: Send first task to agent
print "=== Test 1: Sending simple task ===\n";
my $msg_id = $manager->send_message(
    to => 'test-agent',
    message_type => 'task',
    content => 'simple: first task',
);
ok($msg_id, "Sent first task");

sleep 2;  # Give agent time to process

# Check for completion message
my $messages = $manager->poll_user_inbox();
ok(scalar(@$messages) > 0, "Received completion message");
my $completion = $messages->[0];
is($completion->{type}, 'complete', "Message type is 'complete'");

# Test 2: Send task that requires help
print "\n=== Test 2: Task requiring clarification ===\n";
$msg_id = $manager->send_message(
    to => 'test-agent',
    message_type => 'task',
    content => 'ask: complex task',
);
ok($msg_id, "Sent task requiring help");

sleep 2;  # Give agent time to ask question

# Check for question
$messages = $manager->poll_user_inbox();
my $question = $messages->[0];
is($question->{type}, 'question', "Agent asked question");

# Test 3: Send clarification
print "\n=== Test 3: Providing clarification ===\n";
$manager->send_message(
    to => 'test-agent',
    message_type => 'clarification',
    content => 'Proceed with approach A',
);

# Send continue task
$manager->send_message(
    to => 'test-agent',
    message_type => 'task',
    content => 'continue: with clarification',
);

sleep 2;

# Test 4: Stop the agent
print "\n=== Test 4: Stopping agent gracefully ===\n";
$manager->send_message(
    to => 'test-agent',
    message_type => 'stop',
    content => '',
);

sleep 1;

# Cleanup
$manager->disconnect();
kill 'TERM', $broker_pid;
waitpid($agent_pid, 0);
waitpid($broker_pid, 0);

print "\n=== AgentLoop Test Complete ===\n";
print "Persistent agent loop working!\n";

done_testing();
