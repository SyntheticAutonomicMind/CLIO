#!/usr/bin/env perl
# Regression test: ReadLine control signals must not leak as user input.
#
# Originally this bug came from ReadLine emitting { type => '__TIMEOUT__' }
# on a 5-minute idle timer. Chat.pm's get_input passed it through as user
# input, corrupting the session and triggering a phantom "you pasted a Perl
# hash ref" exchange that confused the model.
#
# The root cause was removed by reverting the timeout mechanism in ReadLine.
# This test now verifies two things:
#   1. ReadLine.pm does NOT emit the __TIMEOUT__ signal anymore.
#   2. Defense-in-depth layers (SessionState, WorkflowOrchestrator, Chat)
#      still reject any hash ref that somehow reaches them.
#
# The agent event mechanism (__AGENT_EVENT__) is still in place because
# it's a separate, intentional feature for the multi-agent broker. Chat.pm's
# hash-ref filter catches it before it can leak as user input.

use strict;
use warnings;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use Test::More tests => 15;

sub ok_match {
    my ($got, $regex, $label) = @_;
    like($got, $regex, $label);
}

# --- Layer 1: ReadLine.pm no longer emits __TIMEOUT__ (root cause gone) ---
{
    my $rl_pm = "$RealBin/../../lib/CLIO/Core/ReadLine.pm";
    open my $fh, '<', $rl_pm or die "Cannot read ReadLine.pm: $!";
    my $content = do { local $/; <$fh> };
    close $fh;
    unlike($content, qr/__TIMEOUT__/,
        "ReadLine.pm does NOT emit __TIMEOUT__ (timeout mechanism reverted)");
    unlike($content, qr/my \$timeout = \$opts\{timeout\}/,
        "ReadLine.pm does NOT accept timeout option");
}

# --- Layer 2: SessionState.add_message coerces non-string content ---
{
    require CLIO::Session::State;
    require CLIO::Memory::YaRN;
    require CLIO::Memory::ShortTerm;

    use File::Temp qw(tempdir);
    my $tmpdir = tempdir(CLEANUP => 1);
    my $session_id = 'test-' . $$ . '-' . time();

    my $yarn = CLIO::Memory::YaRN->new(directory => $tmpdir);
    my $short = CLIO::Memory::ShortTerm->new(directory => $tmpdir);
    my $state = CLIO::Session::State->new(
        session_id => $session_id,
        max_tokens => 128000,
        yarn => $yarn,
        short_term => $short,
    );

    # Inject a hash ref like the original bug produced
    my $corrupted = { type => '__TIMEOUT__', partial_input => '' };
    $state->add_message('user', $corrupted);

    my $history = $state->{history};
    is(scalar(@$history), 1, "add_message added one entry even when given a ref");
    my $stored = $history->[-1]{content};
    ok_match($stored, qr/CORRUPTED INPUT/,
        "Stored user message is a corruption-marker string, not a hash ref");
}

# --- Layer 3: WorkflowOrchestrator defends against non-string user_input ---
{
    my $wf_pm = "$RealBin/../../lib/CLIO/Core/WorkflowOrchestrator.pm";
    open my $fh, '<', $wf_pm or die "Cannot read WorkflowOrchestrator.pm: $!";
    my $content = do { local $/; <$fh> };
    close $fh;

    like($content, qr/ref\s+\$user_input/,
        "WorkflowOrchestrator validates \$user_input is a string");
    like($content, qr/INVALID INPUT/i,
        "WorkflowOrchestrator replaces non-string user_input with a marker");
    like($content, qr/\$session->add_message\('user',\s*\$history_content\)/,
        "WorkflowOrchestrator still calls add_message('user', ...)");
}

# --- Layer 4: Chat.pm get_input loop still handles hash returns ---
# (catches __AGENT_EVENT__ from the broker path)
{
    my $chat_pm = "$RealBin/../../lib/CLIO/UI/Chat.pm";
    open my $fh, '<', $chat_pm or die "Cannot read Chat.pm: $!";
    my $content = do { local $/; <$fh> };
    close $fh;

    like($content, qr/ref\s+\$input\s+eq\s+'HASH'/,
        "Chat get_input detects hash returns");
    like($content, qr/__AGENT_EVENT__/,
        "Chat get_input recognizes __AGENT_EVENT__ signal");
    unlike($content, qr/timeout\s+=>\s+300/,
        "Chat get_input does NOT pass timeout option to ReadLine");
}

# --- Layer 5: Defense still fires on any hash input ---
{
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

    $state->add_message('user', "let's continue");
    $state->add_message('user', { type => '__TIMEOUT__', partial_input => '' });
    $state->add_message('user', "what was that?");

    my $history = $state->{history};
    is(scalar(@$history), 3, "All 3 messages stored");
    is(ref($history->[1]{content}), '',
        "Middle message content is a string (defense fired)");
    ok_match($history->[1]{content}, qr/CORRUPTED INPUT/,
        "Hash-ref message marked as corruption, not real input");
    is($history->[0]{content}, "let's continue", "First user message preserved");
    is($history->[2]{content}, "what was that?", "Last user message preserved");
}