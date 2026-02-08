#!/usr/bin/env perl
# Test: Session history is NOT truncated
# Bug: WorkflowOrchestrator was limiting history to 10 messages
# Fix: Removed truncation - Session::State manages context properly

use strict;
use warnings;
use lib './lib';
use Test::More tests => 3;
use CLIO::Session::Manager;
use File::Temp qw(tempdir);
use Cwd qw(getcwd);

# Create temporary test directory
my $orig_dir = getcwd();
my $temp_dir = tempdir(CLEANUP => 1);
chdir($temp_dir) or die "Cannot chdir to $temp_dir: $!";
mkdir('.clio') or die "Cannot create .clio: $!";
mkdir('.clio/sessions') or die "Cannot create .clio/sessions: $!";

print "# Test: Session history truncation bug fix\n";
print "# Creating session with 20 messages...\n";

# Create a session
my $session = CLIO::Session::Manager->create(debug => 0);
ok($session, "Session created");

# Add 20 messages (10 user, 10 assistant)
for my $i (1..10) {
    $session->add_message('user', "User message $i");
    $session->add_message('assistant', "Assistant response $i");
}

# Save and reload session
$session->save();
my $session_id = $session->{session_id};
my $reloaded = CLIO::Session::Manager->load($session_id, debug => 0);

# Get history count
my $history = $reloaded->get_conversation_history();
my $history_count = scalar(@$history);

print "# Session ID: $session_id\n";
print "# History count: $history_count\n";

ok($history_count == 20, "Session stores all 20 messages (got $history_count)");
ok($history_count >= 15, "CRITICAL: No truncation - at least 15 messages preserved");

# Cleanup
chdir($orig_dir);

print "# Test complete: Session::Manager preserves full history\n";
print "# NOTE: WorkflowOrchestrator must also NOT truncate when loading\n";
done_testing();
