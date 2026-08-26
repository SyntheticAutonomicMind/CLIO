#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

# Test: Progress marker + finding capture in thread_summary decisions
#
# When a trim drops an assistant message that contained a clear
# progress or finding statement, the message content must survive into
# the Decisions section of the rendered thread_summary. This catches the
# case where the model says "Done with X, moving to Y" or "The root
# cause is Z" between tool calls — without this, plan progress evaporates
# after a trim cycle.
#
# Three capture paths:
#   1. metadata.collaboration flag (future programmatic use)
#   2. [COLLABORATION] text prefix (existing tag, model-emitted)
#   3. Progress-marker regex (new fallback for what the model forgot)
#
# The regex fallback is conservative — it requires sentence-boundary
# anchoring and a known progress phrase. False positives pollute the
# Decisions bucket so the whitelist is tight.

use strict;
use warnings;
use utf8;
use lib './lib';
use CLIO::Memory::YaRN;

my $passed = 0;
my $failed = 0;
my $total = 0;

sub ok_test {
    my ($cond, $desc) = @_;
    $desc //= '';
    $total++;
    if ($cond) { $passed++; print "ok $total - $desc\n"; }
    else       { $failed++; print "not ok $total - $desc\n"; }
}

# Test 1: positive patterns at sentence boundary
{
    my $yarn = CLIO::Memory::YaRN->new();
    my @positives = (
        ['Done with reading the file', 'done with reading'],
        ['Moving to the next module', 'moving to the next'],
        ['Finished implementing the feature', 'finished implementing'],
        ['I found the bug in line 42', 'i found the bug'],
        ['I have identified the root cause', 'i have identified'],
        ['We have completed the refactor', 'we have completed'],
        ['The plan is to refactor the trim module', 'the plan is to refactor'],
        ['Next step is to write tests', 'next step is to write'],
        ['Item 1 complete: read module', 'item 1 complete'],
        ['Item 2 done: write fix', 'item 2 done'],
        ['Proceeding with implementation', 'proceeding with implementation'],
        ['Now starting the second phase', 'now starting the second'],
    );

    for my $t (@positives) {
        my ($content, $expected_in_decision) = @$t;
        my $text = $content . " Then more work follows.";
        my @msgs = (
            { role => 'user', content => 'Test' },
            { role => 'assistant', content => $text },
        );
        my $r = $yarn->compress_messages(\@msgs, original_task => 'Test');
        my $content = $r->{content} || '';
        ok_test($content =~ /Key decisions:/, "positive: '$content' -> captured");
        ok_test($content =~ /\Q$expected_in_decision\E/i, "positive: '$content' -> keyword '$expected_in_decision' present");
    }
}

# Test 2: negative patterns must NOT capture
{
    my $yarn = CLIO::Memory::YaRN->new();
    my @negatives = (
        'Reading more files now',
        'Let me see what is in here',
        'I will fix this soon',
        'Looking at the bug',
        'The file is broken',
        'I wonder if this is a regex',
    );

    for my $content (@negatives) {
        my $text = $content . " Then more work follows.";
        my @msgs = (
            { role => 'user', content => 'Test' },
            { role => 'assistant', content => $text },
        );
        my $r = $yarn->compress_messages(\@msgs, original_task => 'Test');
        my $c = $r->{content} || '';
        ok_test($c !~ /Key decisions:/, "negative: '$content' -> not captured");
    }
}

# Test 3: [COLLABORATION] tag still works
{
    my $yarn = CLIO::Memory::YaRN->new();
    my @msgs = (
        { role => 'user', content => 'What did you find?' },
        { role => 'assistant', content => '[COLLABORATION] The bug is in the regex pattern.' },
    );
    my $r = $yarn->compress_messages(\@msgs, original_task => 'What did you find?');
    my $content = $r->{content} || '';
    ok_test($content =~ /Key decisions:/, '[COLLABORATION] tag captured');
    ok_test($content =~ /The bug is in the regex pattern/, '[COLLABORATION] content present');
}

# Test 4: mid-sentence "Found" with sentence-boundary anchor
{
    my $yarn = CLIO::Memory::YaRN->new();
    my @msgs = (
        { role => 'user', content => 'Investigate' },
        { role => 'assistant', content => 'Looking at the file. Found insert_mode is not implemented. Bug confirmed.' },
    );
    my $r = $yarn->compress_messages(\@msgs, original_task => 'Investigate');
    my $content = $r->{content} || '';
    ok_test($content =~ /Key decisions:/, 'mid-sentence "Found" captured');
    ok_test($content =~ /insert_mode is not implemented/, 'mid-sentence "Found" content present');
}

# Test 5: PhotonTERM-style realistic scenario
{
    my $yarn = CLIO::Memory::YaRN->new();
    my @msgs = (
        { role => 'user', content => 'Review PhotonTERM' },
        { role => 'assistant', content => 'Reading photon_vte.c.' },
        { role => 'assistant', content => 'Looking at the file. Found insert_mode is not implemented. Bug confirmed.' },
        { role => 'assistant', content => 'Moving to DECCKM cursor key issue.' },
        { role => 'assistant', content => 'Done with review. The plan is to fix 8 items.' },
    );
    my $r = $yarn->compress_messages(\@msgs, original_task => 'Review PhotonTERM');
    my $content = $r->{content} || '';
    ok_test($content =~ /insert_mode/, 'PhotonTERM scenario: insert_mode captured');
    ok_test($content =~ /DECCKM/, 'PhotonTERM scenario: DECCKM captured');
    ok_test($content =~ /plan is to fix 8 items/, 'PhotonTERM scenario: plan captured');
}

# Test 6: decisions dedupe by exact string (avoid bucket bloat)
{
    my $yarn = CLIO::Memory::YaRN->new();
    my @msgs = (
        { role => 'user', content => 'Do step 1' },
        { role => 'assistant', content => 'Done with step 1. Moving to step 2.' },
        { role => 'assistant', content => 'Done with step 1. Moving to step 2.' },
        { role => 'assistant', content => 'Done with step 1. Moving to step 3.' },
    );
    my $r = $yarn->compress_messages(\@msgs, original_task => 'Do step 1');
    my $content = $r->{content} || '';
    # Count occurrences of "Moving to step" — should be 2 (2 and 3), not 3.
    my $count = () = $content =~ /Moving to step/g;
    ok_test($count == 2, 'dedupe: 2 distinct Moving-to-step entries (got ' . $count . ')');
}

# Test 7: short capture (< 15 chars after marker) is rejected
{
    my $yarn = CLIO::Memory::YaRN->new();
    my @msgs = (
        { role => 'user', content => 'Investigate' },
        { role => 'assistant', content => 'Found it.' },  # 'it.' is too short
    );
    my $r = $yarn->compress_messages(\@msgs, original_task => 'Investigate');
    my $content = $r->{content} || '';
    ok_test($content !~ /Key decisions:/, 'short capture rejected');
}

# Test 8: render position is after Files/Commits, before Tool usage
{
    my $yarn = CLIO::Memory::YaRN->new();
    my @msgs = (
        { role => 'user', content => 'Review code' },
        { role => 'assistant', content => 'Reading file.', tool_calls => [
            { id => 'r1', function => { name => 'file_operations', arguments => '{"path":"src/foo.pm"}' } }
        ] },
        { role => 'tool', tool_call_id => 'r1', content => "[1234567] feat: add foo" },
        { role => 'assistant', content => 'Done with review. The plan is to fix the bug.' },
    );
    my $r = $yarn->compress_messages(\@msgs, original_task => 'Review code');
    my $content = $r->{content} || '';
    my $files_idx = index($content, 'Files');
    my $decisions_idx = index($content, 'Key decisions');
    my $tool_idx = index($content, 'Tool usage');
    ok_test($files_idx > 0 && $decisions_idx > $files_idx && $tool_idx > $decisions_idx,
        'render order: Files < Key decisions < Tool usage');
}

print "\n$passed passed, $failed failed\n";
exit($failed > 0 ? 1 : 0);
