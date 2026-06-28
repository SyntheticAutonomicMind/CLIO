#!/usr/bin/env perl
# Regression test: ReadLine control signals must not leak as user input
#
# Bug: ReadLine returns hash refs like { type => '__TIMEOUT__' } when its
# idle timer expires. Chat.pm's get_input did not recognize these signals
# and stored them as user messages, corrupting the session and confusing
# the model with a phantom "you pasted a Perl hash ref" exchange.
#
# This test verifies three layers of defense:
#   1. Chat.pm get_input handles hash returns by re-prompting (not leaking)
#   2. SessionState.add_message coerces non-string content to a safe string
#   3. WorkflowOrchestrator validates user_input is a string before storing

use strict;
use warnings;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use Test::More tests => 14;

sub ok_str {
    my ($got, $expected, $label) = @_;
    is($got, $expected, $label);
}

sub ok_match {
    my ($got, $regex, $label) = @_;
    like($got, $regex, $label);
}

# --- Layer 1: ReadLine returns the documented control signal shape ---
{
    require CLIO::Core::ReadLine;
    my $rl_pm = "$RealBin/../../lib/CLIO/Core/ReadLine.pm";
    open my $fh, '<', $rl_pm or die "Cannot read ReadLine.pm: $!";
    my $content = do { local $/; <$fh> };
    close $fh;
    like($content, qr/__TIMEOUT__/,
        "ReadLine.pm still emits __TIMEOUT__ control signal");
}

# --- Layer 2: SessionState.add_message coerces non-string content ---
{
    require CLIO::Session::State;
    require CLIO::Memory::YaRN;
    require CLIO::Memory::ShortTerm;

    # Create an in-memory state object. We bypass the constructor's disk
    # I/O by using a temp dir + minimal init.
    use File::Temp qw(tempdir);
    my $tmpdir = tempdir(CLEANUP => 1);
    my $session_id = 'test-' . $$ . '-' . time();

    # Build a minimal State instance. YaRN-backed.
    my $yarn = CLIO::Memory::YaRN->new(directory => $tmpdir);
    my $short = CLIO::Memory::ShortTerm->new(directory => $tmpdir);
    my $state = CLIO::Session::State->new(
        session_id => $session_id,
        max_tokens => 128000,
        yarn => $yarn,
        short_term => $short,
    );

    # Inject a hash ref like the bug produces
    my $corrupted = { type => '__TIMEOUT__', partial_input => '' };
    $state->add_message('user', $corrupted);

    # Verify the stored message is a string (defense-in-depth fired)
    my $history = $state->{history};
    is(scalar(@$history), 1, "add_message added one entry even when given a ref");
    my $stored = $history->[-1]{content};
    ok_match($stored, qr/CORRUPTED INPUT/,
        "Stored user message is a corruption-marker string, not a hash ref");
    ok_match($stored, qr/__TIMEOUT__/,
        "Stored message mentions the leaked signal type for diagnosis");
}

# --- Layer 3: WorkflowOrchestrator defends against non-string user_input ---
{
    require CLIO::Core::WorkflowOrchestrator;

    my $wf_pm = "$RealBin/../../lib/CLIO/Core/WorkflowOrchestrator.pm";
    open my $fh, '<', $wf_pm or die "Cannot read WorkflowOrchestrator.pm: $!";
    my $content = do { local $/; <$fh> };
    close $fh;

    # The bug surfaced here: add_message('user', $history_content) was
    # called with $user_input = { type => '__TIMEOUT__' }. Verify there's
    # now a guard that catches non-string refs and replaces them with a
    # safe string before they reach the session.
    like($content, qr/ref\s+\$user_input/,
        "WorkflowOrchestrator validates \$user_input is a string");
    like($content, qr/INVALID INPUT/i,
        "WorkflowOrchestrator replaces non-string user_input with a marker");
    like($content, qr/\$session->add_message\('user',\s*\$history_content\)/,
        "WorkflowOrchestrator still calls add_message('user', ...)");
}

# --- Layer 4: Chat.pm get_input loop handles hash returns ---
{
    my $chat_pm = "$RealBin/../../lib/CLIO/UI/Chat.pm";
    open my $fh, '<', $chat_pm or die "Cannot read Chat.pm: $!";
    my $content = do { local $/; <$fh> };
    close $fh;

    # The primary fix: get_input must loop when readline returns a control
    # signal, never letting the hash leak as user input.
    like($content, qr/ref\s+\$input\s+eq\s+'HASH'/, "Chat get_input detects hash returns");
    like($content, qr/__TIMEOUT__/, "Chat get_input handles __TIMEOUT__ signal");
}

# --- Layer 5: Reproduce the bug scenario and verify the fix ---
{
    # Simulate the exact flow: ReadLine returns a timeout hash, then the
    # downstream add_message call receives that hash. With the fix, the
    # state stores a safe string instead of the hash ref.
    require CLIO::Session::State;
    require CLIO::Memory::YaRN;
    require CLIO::Memory::ShortTerm;

    use File::Temp qw(tempdir);
    my $tmpdir = tempdir(CLEANUP => 1);
    my $session_id = 'bug-test-' . $$ . '-' . time();

    my $yarn = CLIO::Memory::YaRN->new(directory => $tmpdir);
    my $short = CLIO::Memory::ShortTerm->new(directory => $tmpdir);
    my $state = CLIO::Session::State->new(
        session_id => $session_id,
        max_tokens => 128000,
        yarn => $yarn,
        short_term => $short,
    );

    # Add a legitimate user message
    $state->add_message('user', "let's continue");
    # Simulate the phantom 5-minute timeout hash
    $state->add_message('user', { type => '__TIMEOUT__', partial_input => '' });
    # Now a real follow-up
    $state->add_message('user', "what was that?");

    my $history = $state->{history};
    is(scalar(@$history), 3, "All 3 messages stored");
    is(ref($history->[1]{content}), '',
        "Middle message content is a string (defense fired)");
    ok_match($history->[1]{content}, qr/CORRUPTED INPUT/,
        "Phantom timeout message marked as corruption, not real input");
    is($history->[0]{content}, "let's continue", "First user message preserved");
    is($history->[2]{content}, "what was that?", "Last user message preserved");
}
