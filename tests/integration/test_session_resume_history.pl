#!/usr/bin/env perl
# Integration test for session resume history bug fix
# Tests that user messages are preserved when resuming a session

use strict;
use warnings;
use lib 'lib';

print "Testing session resume history preservation...\n\n";

# Test 1: Create session with one exchange (use --debug to see session ID)
print "[TEST 1] Creating new session with one Q&A exchange...\n";
my $output1 = `./clio --debug --input "What is 2+2?" --exit 2>&1`;

# Look for session ID in the format: [SESSION] Using session: <uuid>
my ($session_id) = $output1 =~ /\[SESSION\]\s+Using\s+session:\s+([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})/i;

if (!$session_id) {
    print "FAIL: Could not extract session ID from output:\n";
    print "=" x 60 . "\n";
    # Show lines containing "session"
    for my $line (split /\n/, $output1) {
        print "$line\n" if $line =~ /session/i;
    }
    print "=" x 60 . "\n";
    die "Cannot continue without session ID\n";
}

print "[OK] Created session: $session_id\n";
print "[OK] Session received response\n\n";

# Test 2: Resume the session and ask the agent to repeat what was asked
print "[TEST 2] Resuming session and checking if history preserved...\n";
my $output2 = `./clio --resume $session_id --input "What did I just ask you in my previous message?" --exit 2>&1`;

print "\n[OUTPUT FROM RESUME]:\n";
print "=" x 60 . "\n";
# Show only the response part, not all debug output
for my $line (split /\n/, $output2) {
    print "$line\n" if $line =~ /\[RESPONSE\]|asked|previous|2\+2|message|session/i;
}
print "=" x 60 . "\n\n";

# Check if the output contains reference to the original question
if ($output2 =~ /2\+2|two plus two|2 plus 2|addition|arithmetic/i) {
    print "[OK] Agent remembered the previous question!\n";
    print "[PASS] Session history preserved correctly\n";
    exit 0;
} elsif ($output2 =~ /couldn't find|can't recall|don't have.*previous/i) {
    print "[FAIL] Agent could not find the previous message\n";
    print "[FAIL] User message was NOT saved to session\n";
    exit 1;
} else {
    print "[UNCERTAIN] Could not determine if history was preserved\n";
    print "[INFO] Full output:\n$output2\n";
    exit 2;
}
