#!/usr/bin/env perl

=head1 NAME

test_subagent_persistent.pl - Manual test for persistent sub-agents

=head1 DESCRIPTION

This is a MANUAL test demonstrating persistent sub-agent functionality.

A persistent agent stays alive between tasks and can receive multiple
work items via the message bus or direct interaction.

=head1 USAGE

    perl tests/integration/test_subagent_persistent.pl

This will spawn a persistent agent that you can interact with.

=cut

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use File::Temp qw(tempdir);

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

print "\n";
print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n";
print "  Persistent Sub-Agent Manual Test\n";
print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n";

# Setup test directory
my $test_dir = tempdir(CLEANUP => 0);  # Don't clean up so you can inspect files
print "[INFO] Test directory: $test_dir\n";
print "[INFO] Files will persist after test completes.\n\n";

# Task 1: Spawn persistent agent
print "━━━ STEP 1: Spawning Persistent Agent ━━━\n\n";
print "Command:\n";
my $task1 = "Create three files in $test_dir named file1.txt file2.txt and file3.txt";
print "  Task: $task1\n\n";

my $spawn_cmd = qq{$RealBin/../../clio --input '/subagent spawn --persistent "$task1" --model gpt-4o-mini' --exit};
print "Executing: $spawn_cmd\n\n";

system($spawn_cmd);

print "\n";
print "━━━ STEP 2: Check Agent Status ━━━\n\n";
print "Run this command to see the agent:\n";
print "  ./clio --input '/subagent list' --exit\n\n";

print "━━━ STEP 3: View Agent Log ━━━\n\n";
print "The agent log is at:\n";
print "  /tmp/clio-agent-agent-1.log\n\n";
print "Tail the log with:\n";
print "  tail -f /tmp/clio-agent-agent-1.log\n\n";

print "━━━ STEP 4: Verify Files Created ━━━\n\n";
print "Check if the agent created the files:\n";
print "  ls -la $test_dir/\n\n";

print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n";
print "  Test Complete\n";
print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n";

print "What to look for:\n";
print "  1. Agent spawned with ID 'agent-1'\n";
print "  2. Agent shows as PERSISTENT mode in status\n";
print "  3. Files created in test directory\n";
print "  4. Agent stays alive after task completes (check /subagent list)\n";
print "  5. You can send more tasks to the same agent\n\n";

print "Test directory: $test_dir\n";
print "Agent log: /tmp/clio-agent-agent-1.log\n\n";

print "[SUCCESS] Manual test setup complete.\n";
print "Check the outputs above to verify persistent agent functionality.\n\n";

exit 0;
