#!/usr/bin/env perl
# Test script to verify session resume history preservation
# Bug: User messages were not being saved to session, causing history loss on resume

use strict;
use warnings;
use lib 'lib';
use Test::More;
use CLIO::Session::Manager;
use CLIO::Util::PathResolver;
use File::Temp qw(tempdir);

# Create temporary directory for test sessions
my $temp_dir = tempdir(CLEANUP => 1);
$ENV{HOME} = $temp_dir;

# Initialize clio directories in temp home
my $clio_dir = "$temp_dir/.clio";
mkdir $clio_dir or die "Cannot create .clio dir: $!";
mkdir "$clio_dir/sessions" or die "Cannot create sessions dir: $!";

print STDERR "[TEST] Using temp home: $temp_dir\n";
print STDERR "[TEST] Sessions dir: $clio_dir/sessions\n";

# Create a new session
my $session = CLIO::Session::Manager->create(debug => 1);
ok(defined $session, "Session created");

my $session_id = $session->{session_id};
ok(defined $session_id, "Session ID exists: $session_id");

# Simulate adding a user message (this is what Chat.pm should do)
$session->add_message('user', 'What is the capital of France?');
$session->add_message('assistant', 'The capital of France is Paris.');

# Get conversation history before cleanup
my $history_before = $session->get_conversation_history();
is(scalar(@$history_before), 2, "Session has 2 messages before save") or do {
    print STDERR "[TEST] History before save:\n";
    use Data::Dumper;
    print STDERR Dumper($history_before);
};

# Save session
$session->save();
print STDERR "[TEST] Session saved to: " . $session->{state}->{file} . "\n";

# Verify file exists
ok(-e $session->{state}->{file}, "Session file exists: " . $session->{state}->{file});

# Release lock only (cleanup() would delete the session file)
if ($session->{lock}) {
    $session->{lock}->release();
    delete $session->{lock};
}

# Load the session (simulating resume)
print STDERR "[TEST] Attempting to load session: $session_id\n";
my $resumed_session = CLIO::Session::Manager->load($session_id, debug => 1);

if (!defined $resumed_session) {
    print STDERR "[TEST] ERROR: Session load returned undef\n";
    print STDERR "[TEST] Session file still exists? " . (-e $session->{state}->{file} ? "YES" : "NO") . "\n";
    
    # Try to read the file directly
    if (-e $session->{state}->{file}) {
        open my $fh, '<', $session->{state}->{file} or die "Cannot read session file: $!";
        my $content = do { local $/; <$fh> };
        close $fh;
        print STDERR "[TEST] Session file content length: " . length($content) . " bytes\n";
        print STDERR "[TEST] First 200 chars: " . substr($content, 0, 200) . "\n";
    }
    
    fail("Session resumed successfully");
    done_testing();
    exit 1;
}

ok(defined $resumed_session, "Session resumed successfully");

# Verify conversation history was preserved
my $history_after = $resumed_session->get_conversation_history();

print STDERR "\n[TEST] History before cleanup: " . scalar(@$history_before) . " messages\n";
print STDERR "[TEST] History after resume: " . scalar(@$history_after) . " messages\n";

for my $i (0 .. $#{$history_after}) {
    my $msg = $history_after->[$i];
    print STDERR "[TEST] Message $i: role=" . $msg->{role} . 
        ", content=" . substr($msg->{content}, 0, 50) . "...\n";
}

is(scalar(@$history_after), 2, "Session history preserved after resume (2 messages)");

# Verify the first message is the user question
is($history_after->[0]->{role}, 'user', "First message is user message");
like($history_after->[0]->{content}, qr/capital of France/, "User message content preserved");

# Verify the second message is the assistant response
is($history_after->[1]->{role}, 'assistant', "Second message is assistant message");
like($history_after->[1]->{content}, qr/Paris/, "Assistant message content preserved");

# Cleanup
$resumed_session->cleanup();

done_testing();

