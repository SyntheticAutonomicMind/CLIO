#!/usr/bin/env perl
# Regression test: ensure thread_summary system messages are preserved
# through load_conversation_history.
#
# Bug: In PhotonTERM session a6a0eb10, the agent lost context because the
# [CONTEXT TRIM:...] system message containing <threadSummary> was filtered
# out by load_conversation_history. The model then had no anchor to the
# original task, and started reading files from scratch.
#
# Fix: load_conversation_history now preserves system messages containing
# <threadSummary> or starting with "[CONTEXT TRIM:" so the proactive trim
# can position them at the END for CSSS cache stability.

use strict;
use warnings;
use utf8;
use lib '../../lib';
use Test::More;
use CLIO::Core::ConversationManager qw(load_conversation_history);

# Build a fake session with a thread_summary at position 1
my @history = (
    { role => 'system', content => 'CLIO System Prompt (will be rebuilt fresh)' },
    {
        role => 'system',
        content => <<'END_SUMMARY',
[CONTEXT TRIM: 36 messages compressed]
Older messages summarized below. Recent 10 messages preserved in full.

<threadSummary>

Current task: I would like you to do a full code review of PhotonTERM - I want to start using it soon but we need to make sure that it follows correct UI/UX patterns, and it is free of smells and inconsistencies.  Analyze and report first, we'll discuss the plan and then begin implementing any changes needed.

Recent user requests:
- I would like you to do a full code review of PhotonTERM - I want to start using it soon but we need to make sure that it follows correct UI/UX patterns, and it is free of smells and inconsistencies.  Analyze and report first, we'll discuss the plan and then begin implementing any changes needed.

Files created/modified:
- /home/deck/repositories/PhotonTERM/src/photonterm/photon_main.c

Tool usage:
- file_operations: 24 calls
- todo_operations: 1 calls

</threadSummary>

DO NOT read handoff documents in ai-assisted/ - use the tools above instead.
END_SUMMARY
    },
    { role => 'assistant', content => 'Now let me read the UI widgets.' },
    { role => 'tool', tool_call_id => 'tc1', content => '/* file content */' },
);

# Session object exposes get_conversation_history
my $session = bless { conversation_history => \@history }, 'FakeSession';

my $loaded = load_conversation_history($session, debug => 0);

ok(scalar(@$loaded) >= 2, "Loaded at least 2 messages (assistant + summary; tool msgs may be filtered as orphans)");

# Find the preserved summary
my $summary;
for my $m (@$loaded) {
    if ($m->{role} eq 'system' && $m->{content} =~ /<threadSummary>/) {
        $summary = $m;
        last;
    }
}

ok(defined $summary, "thread_summary system message preserved through load_conversation_history");
SKIP: {
    skip "no summary preserved", 3 unless $summary;

    like($summary->{content}, qr/<threadSummary>/, "summary contains <threadSummary> tag");
    like($summary->{content}, qr/Current task:/, "summary contains 'Current task:' from the original user request");
    like($summary->{content}, qr/full code review of PhotonTERM/, "summary preserves the original task wording");
}

# Also verify: a system message without thread_summary is still skipped
{
    my @h2 = (
        { role => 'system', content => 'Random non-summary system message' },
        { role => 'user', content => 'Hello' },
    );
    my $s2 = bless { conversation_history => \@h2 }, 'FakeSession';
    my $loaded2 = load_conversation_history($s2, debug => 0);

    my $has_random = grep { $_->{role} eq 'system' && $_->{content} eq 'Random non-summary system message' } @$loaded2;
    ok(!$has_random, "Non-summary system messages are still filtered out (only summary is preserved)");

    my $has_user = grep { $_->{role} eq 'user' && $_->{content} eq 'Hello' } @$loaded2;
    ok($has_user, "User messages are still preserved");
}

# Edge case: a [CONTEXT TRIM: ...] system message without <threadSummary> tag
# (an older format that some sessions have)
{
    my @h3 = (
        { role => 'system', content => "[CONTEXT TRIM: 5 messages archived]\nUse memory_operations to recover." },
        { role => 'user', content => 'Hi' },
    );
    my $s3 = bless { conversation_history => \@h3 }, 'FakeSession';
    my $loaded3 = load_conversation_history($s3, debug => 0);

    my $has_trim = grep { $_->{role} eq 'system' && $_->{content} =~ /^\[CONTEXT TRIM:/ } @$loaded3;
    ok($has_trim, "[CONTEXT TRIM: ...] system message without <threadSummary> is also preserved");
}

done_testing();

package FakeSession;

sub get_conversation_history {
    my ($self) = @_;
    return $self->{conversation_history};
}
