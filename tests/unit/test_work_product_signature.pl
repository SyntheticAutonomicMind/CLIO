#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Unit tests for _extract_work_product_signature and _extract_running_todos
# in CLIO::Memory::YaRN, plus the _inject_thread_summary anchor path
# in CLIO::Core::WorkflowOrchestrator.
#
# The work-product signature is the mechanism that lets _inject_thread_summary
# decide whether the thread_summary anchor needs regenerating: if the
# signature hasn't changed since the last summary was generated, the
# existing summary is reused (cache-stable). If it has changed (new commit,
# new decision, todo transition), YaRN::compress_messages regenerates a
# fresh work-product summary.
#
# See scratch/csss.md for the full design rationale.

use strict;
use warnings;
use utf8;
use lib './lib';
use Test::More;

# Pre-load YaRN so CLIO::Core::WorkflowOrchestrator can find it when
# _inject_thread_summary calls CLIO::Memory::YaRN->new().
require CLIO::Memory::YaRN;
use CLIO::Memory::YaRN;
use CLIO::Core::WorkflowOrchestrator;

# ---------------------------------------------------------------------------
# _extract_work_product_signature
# ---------------------------------------------------------------------------

# Test 1: Empty / no-op messages produce a stable empty-ish signature.
{
    my $sig = CLIO::Memory::YaRN::_extract_work_product_signature([]);
    ok(defined $sig && $sig eq '', 'Empty messages => empty signature');
}

# Test 2: Identical message sets produce identical signatures (determinism).
{
    my $msgs_a = [
        { role => 'user',    content => 'Refactor the bigtext module to handle unicode glyphs' },
        { role => 'assistant', content => 'Reading the file now.' },
    ];
    my $msgs_b = [
        { role => 'user',    content => 'Refactor the bigtext module to handle unicode glyphs' },
        { role => 'assistant', content => 'Reading the file now.' },
    ];
    is(CLIO::Memory::YaRN::_extract_work_product_signature($msgs_a),
       CLIO::Memory::YaRN::_extract_work_product_signature($msgs_b),
       'Identical messages produce identical signature');
}

# Test 3: A git commit in a tool result increments the commit count.
{
    my $sig_no_commit = CLIO::Memory::YaRN::_extract_work_product_signature([
        { role => 'user', content => 'Fix the bug in the parser' },
    ]);
    my $sig_with_commit = CLIO::Memory::YaRN::_extract_work_product_signature([
        { role => 'user', content => 'Fix the bug in the parser' },
        { role => 'tool', content => '[abc1234] Fix the parser bug' },
    ]);
    ok($sig_no_commit ne $sig_with_commit,
       'Commit in tool result changes the signature');
}

# Test 4: Two commits produce a different signature than one commit.
{
    my $sig_one = CLIO::Memory::YaRN::_extract_work_product_signature([
        { role => 'tool', content => '[abc1234] first commit' },
    ]);
    my $sig_two = CLIO::Memory::YaRN::_extract_work_product_signature([
        { role => 'tool', content => '[abc1234] first commit' },
        { role => 'tool', content => '[def5678] second commit' },
    ]);
    ok($sig_one ne $sig_two,
       'Two commits produce a different signature than one');
}

# Test 5: File operations do NOT change the signature (investigation, not work product).
{
    my $sig_before = CLIO::Memory::YaRN::_extract_work_product_signature([
        { role => 'user', content => 'Read the codebase and find the bug' },
    ]);
    my $sig_after = CLIO::Memory::YaRN::_extract_work_product_signature([
        { role => 'user', content => 'Read the codebase and find the bug' },
        { role => 'assistant', content => 'Reading files',
          tool_calls => [
            { id => 'tc1', function => { name => 'file_operations',
                arguments => '{"operation":"read_file","path":"lib/CLIO/Core/Bug.pm"}' } }
          ] },
        { role => 'tool', tool_call_id => 'tc1', content => '... file contents ...' },
    ]);
    is($sig_before, $sig_after,
       'File operations do NOT change the work product signature');
}

# Test 6: Decision phrases in assistant text change the signature.
{
    my $sig_no_decision = CLIO::Memory::YaRN::_extract_work_product_signature([
        { role => 'user', content => 'What approach should we take for the refactor?' },
        { role => 'assistant', content => 'I am reading the relevant modules first.' },
    ]);
    my $sig_with_decision = CLIO::Memory::YaRN::_extract_work_product_signature([
        { role => 'user', content => 'What approach should we take for the refactor?' },
        { role => 'assistant', content => 'I have identified the root cause: the parser does not handle unicode glyphs. The fix is to add glyph-width detection.' },
    ]);
    ok($sig_no_decision ne $sig_with_decision,
       'Decision phrases change the signature');
}

# Test 7: No-decision assistant text does NOT change the signature.
{
    my $sig_a = CLIO::Memory::YaRN::_extract_work_product_signature([
        { role => 'user', content => 'Investigate the codebase structure for me' },
        { role => 'assistant', content => 'Reading the file structure now.' },
    ]);
    my $sig_b = CLIO::Memory::YaRN::_extract_work_product_signature([
        { role => 'user', content => 'Investigate the codebase structure for me' },
        { role => 'assistant', content => 'Looking at the directory listing next.' },
    ]);
    is($sig_a, $sig_b,
       'Non-decision assistant chatter does not change the signature');
}

# ---------------------------------------------------------------------------
# _extract_running_todos
# ---------------------------------------------------------------------------

# Test 8: Correctly parse todo_operations "write" arguments.
{
    my $args = '{"operation":"write","todoList":[{"id":1,"title":"Fix the parser","status":"in-progress","priority":"high"},{"id":2,"title":"Add tests","status":"not-started","priority":"medium"}]}';
    my $todos = CLIO::Memory::YaRN::_extract_running_todos($args);
    is(scalar(@$todos), 2, 'Parsed 2 todos from write operation');
    is($todos->[0]{id}, 1, 'First todo has id=1');
    is($todos->[0]{title}, 'Fix the parser', 'First todo title correct');
    is($todos->[0]{status}, 'in-progress', 'First todo status correct');
    is($todos->[1]{id}, 2, 'Second todo has id=2');
    is($todos->[1]{title}, 'Add tests', 'Second todo title correct');
}

# Test 9: Correctly parse todo_operations "add" arguments (newTodos).
{
    my $args = '{"operation":"add","newTodos":[{"title":"Write documentation","status":"not-started"}]}';
    my $todos = CLIO::Memory::YaRN::_extract_running_todos($args);
    is(scalar(@$todos), 1, 'Parsed 1 todo from add operation');
    is($todos->[0]{title}, 'Write documentation', 'Todo title correct from newTodos');
}

# Test 10: Empty/undefined arguments return empty array.
{
    my $todos = CLIO::Memory::YaRN::_extract_running_todos('');
    is(ref($todos), 'ARRAY', 'Empty string returns arrayref');
    is(scalar(@$todos), 0, 'Empty string returns empty array');

    $todos = CLIO::Memory::YaRN::_extract_running_todos(undef);
    is(ref($todos), 'ARRAY', 'undef returns arrayref');
    is(scalar(@$todos), 0, 'undef returns empty array');
}

# Test 11: Non-JSON fallback (partial / corrupt JSON) still extracts what it can.
{
    my $args = q({"operation":"write","todoList":[
        {"id":1,"title":"Fix bug","status":"in-progress"},
        {"id":2,"title":"Add tests","status":"not-started"}
    ]});
    my $todos = CLIO::Memory::YaRN::_extract_running_todos($args);
    ok(scalar(@$todos) >= 1, 'Fallback regex extracts at least 1 todo from valid JSON-like input');
}

# ---------------------------------------------------------------------------
# _inject_thread_summary integration
# ---------------------------------------------------------------------------

# Set up a minimal WorkflowOrchestrator instance for method calls.
# We bless a hashref directly — _inject_thread_summary only uses $self
# for the _find_substantive_user_task call, which needs no instance state
# when messages + user_input are provided.

my $orch = bless({}, 'CLIO::Core::WorkflowOrchestrator');

# Test 12: First-injection path produces a summary message.
{
    my $task = 'This is a substantive user task that is long enough to trigger the anchor injection logic on the very first turn of a new session.';
    my $messages = [
        { role => 'system', content => '<systemPrompt>... CLIO instructions ...</systemPrompt>' },
        { role => 'user',   content => $task },
    ];
    $orch->_inject_thread_summary($messages, $task);

    my $has_summary = 0;
    for my $m (@$messages) {
        if (ref($m) eq 'HASH' && ($m->{role} // '') eq 'system'
            && ($m->{content} // '') =~ /\A<threadSummary>/) {
            $has_summary = 1;
            ok(defined $m->{_metadata}, 'Summary message has _metadata');
            ok(defined $m->{_metadata}{work_product_signature},
               'Summary has work_product_signature in metadata');
            ok($m->{_metadata}{anchor_summary},
               'Summary is tagged as anchor_summary');
            last;
        }
    }
    ok($has_summary, 'First-injection path produces a thread_summary message');
}

# Test 13: Existing summary with matching signature is NOT regenerated (cache-stable).
{
    my $task = 'This is a substantive user task that is long enough to trigger the anchor injection logic on the very first turn of a new session.';
    my $signature = 'abc123fake';
    my $messages = [
        { role => 'system', content => '<systemPrompt>...</systemPrompt>' },
        { role => 'user',   content => $task },
        { role => 'system', content => '<threadSummary>Current task: existing</threadSummary>',
          _metadata => { work_product_signature => $signature, anchor_summary => 1 } },
    ];
    # We need the signature to match. Since _extract_work_product_signature
    # computes from the messages, and the messages include the summary itself,
    # we need to pre-compute what the signature would be. But _inject_thread_summary
    # calls _extract_work_product_signature on the messages (including the existing
    # summary). The signature in the existing summary is 'abc123fake', which
    # won't match the computed signature. So it will try to regenerate.
    #
    # To test the "match" path properly, we pre-compute the signature of the
    # messages WITHOUT the existing summary's metadata, then set the existing
    # summary's signature to match.
    #
    # Actually, _extract_work_product_signature ignores _metadata — it only
    # looks at role, content, tool_calls. So the signature is the same whether
    # or not the summary has metadata. We can pre-compute it.
    my $computed_sig = CLIO::Memory::YaRN::_extract_work_product_signature($messages);

    # Update the existing summary's signature to match what _inject would compute.
    $messages->[2]{_metadata}{work_product_signature} = $computed_sig;

    my $before = $messages->[2]{content};
    $orch->_inject_thread_summary($messages, $task);
    my $after = $messages->[2]{content};

    is($before, $after,
       'Existing summary with matching signature is NOT regenerated (cache-stable)');
}

# Test 14: Short user input (< 50 chars) does not trigger anchor injection.
{
    my $messages = [
        { role => 'system', content => '<systemPrompt>...</systemPrompt>' },
        { role => 'user',   content => 'continue' },
    ];
    my $before_count = scalar(@$messages);
    $orch->_inject_thread_summary($messages, 'continue');
    is(scalar(@$messages), $before_count,
       'Short user input does not trigger anchor injection');
}

# Test 15: Multiple thread_summary messages — the first one is treated as canonical.
# (Edge case: there should only be one, but _inject_thread_summary guards against
#  duplicates by finding the first <threadSummary> and using that position.)
{
    my $task = 'This is a substantive user task that is long enough to trigger the anchor injection logic on the very first turn of a new session.';
    my $messages = [
        { role => 'system', content => '<systemPrompt>...</systemPrompt>' },
        { role => 'user',   content => $task },
        { role => 'system', content => '<threadSummary>Current task: first</threadSummary>',
          _metadata => { work_product_signature => 'old', anchor_summary => 1 } },
        { role => 'system', content => '<threadSummary>Current task: second</threadSummary>' },
    ];
    $orch->_inject_thread_summary($messages, $task);
    # The first summary (index 2) should be the one retained; the second
    # should not have been injected as a duplicate.
    my $summary_count = 0;
    for my $m (@$messages) {
        $summary_count++ if ref($m) eq 'HASH'
            && ($m->{content} // '') =~ /\A<threadSummary>/;
    }
    is($summary_count, 1,
       'Only one thread_summary remains after _inject_thread_summary');
}

done_testing();
