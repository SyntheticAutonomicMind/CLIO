#!/usr/bin/env perl

=head1 NAME

test_tool_restrictions.pl - Test tool restrictions for sub-agents

=head1 DESCRIPTION

Tests that certain tools are blocked or restricted for sub-agents:
1. remote_execution is not registered for sub-agents
2. Sub-agents cannot spawn additional sub-agents

=cut

use strict;
use warnings;
use lib './lib';
use Test::More tests => 6;

# Mock broker client
package MockBrokerClient;
sub new { return bless {}, shift }
package main;

print "\n=== Tool Restrictions Test ===\n\n";

# Test 1: WorkflowOrchestrator without broker_client (normal mode)
print "=== Test 1: Normal mode - all tools registered ===\n";

require CLIO::Core::WorkflowOrchestrator;

# Create orchestrator without broker_client (primary agent mode)
my $orchestrator_normal = CLIO::Core::WorkflowOrchestrator->new(
    debug => 0,
);

my $registry_normal = $orchestrator_normal->{tool_registry};
my $remote_tool_normal = $registry_normal->get_tool('remote_execution');
ok(defined $remote_tool_normal, "Normal mode: remote_execution tool is registered");

# Test 2: WorkflowOrchestrator with broker_client (sub-agent mode)
print "=== Test 2: Sub-agent mode - remote_execution blocked ===\n";

my $mock_broker = MockBrokerClient->new();

my $orchestrator_subagent = CLIO::Core::WorkflowOrchestrator->new(
    debug => 0,
    broker_client => $mock_broker,
);

my $registry_subagent = $orchestrator_subagent->{tool_registry};
my $remote_tool_subagent = $registry_subagent->get_tool('remote_execution');
ok(!defined $remote_tool_subagent, "Sub-agent mode: remote_execution tool is NOT registered");

# Test 3: Other tools still available in sub-agent mode
print "=== Test 3: Sub-agent mode - other tools available ===\n";

my $file_ops = $registry_subagent->get_tool('file_operations');
ok(defined $file_ops, "Sub-agent mode: file_operations available");

my $version_control = $registry_subagent->get_tool('version_control');
ok(defined $version_control, "Sub-agent mode: version_control available");

my $user_collab = $registry_subagent->get_tool('user_collaboration');
ok(defined $user_collab, "Sub-agent mode: user_collaboration available");

# Test 4: SubAgent spawn command blocks if already a sub-agent
print "=== Test 4: Sub-agent spawn blocking ===\n";

# Simulate sub-agent environment
$ENV{CLIO_BROKER_AGENT_ID} = 'test-agent';

require CLIO::UI::Commands::SubAgent;

# Create mock chat object
my $mock_chat = { session => { id => 'test-session' } };
my $subagent_cmd = CLIO::UI::Commands::SubAgent->new(chat => $mock_chat);

my $result = $subagent_cmd->cmd_spawn("test task");
like($result, qr/Sub-agents cannot spawn/i, "Sub-agent cannot spawn additional sub-agents");

# Clean up
delete $ENV{CLIO_BROKER_AGENT_ID};

print "\n=== Tool Restrictions Test Complete ===\n";
print " remote_execution blocked for sub-agents\n";
print " Other tools remain available\n";
print " Sub-agent spawn correctly blocked\n\n";
