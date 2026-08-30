#!/usr/bin/env perl
# Test: Task-aware compression in YaRN
#
# When <task_boundary ...> system messages are present in the dropped set,
# compress_messages should group extracted items by task and render one
# <task> block per task. Without task boundaries, the legacy flat layout
# should be used.
#
# Round-trip stability: a rendered task summary must parse back into the
# same buckets so subsequent trims preserve accumulated history.

use strict;
use warnings;
use utf8;
use lib './lib';
use Test::More;
use CLIO::Memory::YaRN;

sub make_messages_with_tasks {
    my @messages;
    push @messages, { role => 'system', content => '<task_boundary id="task-A" name="refactor" todo_id="1" status="active" started_at="100" />' };
    push @messages, { role => 'user', content => 'Refactor the bigtext module to handle unicode glyphs correctly across all supported terminals.' };
    push @messages, { role => 'assistant', content => 'Reading the file.', tool_calls => [
        { id => 't1', function => { name => 'file_operations', arguments => '{"path":"lib/bigtext.pm"}' } }
    ] };
    push @messages, { role => 'tool', tool_call_id => 't1', content => 'package bigtext; sub render { ... }' };
    push @messages, { role => 'system', content => '<task_boundary id="task-A" name="refactor" todo_id="1" status="completed" completed_at="200" />' };
    push @messages, { role => 'system', content => '<task_boundary id="task-B" name="implement-b-glyph" todo_id="2" status="active" started_at="300" />' };
    push @messages, { role => 'user', content => 'Now implement the B glyph width consistency check between the unicode-aware and ASCII renderers.' };
    push @messages, { role => 'assistant', content => 'Checking the width tables.' };
    return @messages;
}

# Test 1: Task-aware layout is chosen when <task_boundary> markers exist.
{
    my $yarn = CLIO::Memory::YaRN->new();
    my @messages = make_messages_with_tasks();
    my $result = $yarn->compress_messages(\@messages,
        original_task => 'Refactor the bigtext module to handle unicode glyphs.');

    like($result->{content}, qr/<task\s+id="task-A"/, 'task-A block present');
    like($result->{content}, qr/<task\s+id="task-B"/, 'task-B block present');
    like($result->{content}, qr/Task: refactor/, 'task-A name rendered');
    like($result->{content}, qr/Task: implement-b-glyph/, 'task-B name rendered');
    like($result->{content}, qr/Current task:/, 'Current task line present');
}

# Test 2: Legacy flat layout is used when no <task_boundary> markers exist.
{
    my $yarn = CLIO::Memory::YaRN->new();
    my @messages = (
        { role => 'user', content => 'Just a flat conversation with no task markers at all involved here.' },
        { role => 'assistant', content => 'OK.' },
    );
    my $result = $yarn->compress_messages(\@messages,
        original_task => 'Just a flat conversation with no task markers at all involved here.');

    unlike($result->{content}, qr/<task\s/, 'No <task> blocks in flat layout');
    like($result->{content}, qr/Recent user requests:/, 'Flat layout has Recent user requests');
    like($result->{content}, qr/Current task:/, 'Current task line still present');
}

# Test 3: Files touched in task A do not bleed into task B's bucket.
{
    my $yarn = CLIO::Memory::YaRN->new();
    my @messages = make_messages_with_tasks();
    my $result = $yarn->compress_messages(\@messages,
        original_task => 'Refactor the bigtext module.');

    # The file path /lib/bigtext.pm belongs to task-A's file_operations call.
    # It must appear inside task-A's block, not task-B's.
    my ($task_a_section) = $result->{content} =~ /(<task\s+id="task-A".*?<\/task>)/s;
    like($task_a_section, qr/lib\/bigtext\.pm/, 'lib/bigtext.pm appears in task-A block');

    my ($task_b_section) = $result->{content} =~ /(<task\s+id="task-B".*?<\/task>)/s;
    unlike($task_b_section, qr/lib\/bigtext\.pm/, 'lib/bigtext.pm NOT in task-B block');
}

# Test 4: Round-trip stability - parse a rendered summary, use it as
# previous_summary for a second compression pass, verify accumulated
# content survives.
{
    my $yarn = CLIO::Memory::YaRN->new();

    # First pass: render task summary from task-A's work
    my @first_messages = (
        { role => 'system', content => '<task_boundary id="task-A" name="refactor" status="completed" />' },
        { role => 'user', content => 'Work on task A with enough context to fill out a summary.' },
        { role => 'assistant', content => 'Done with A.', tool_calls => [
            { id => 't1', function => { name => 'file_operations', arguments => '{"path":"src/a.pl"}' } }
        ] },
        { role => 'tool', tool_call_id => 't1', content => 'a code' },
        { role => 'system', content => '<task_boundary id="task-B" name="implement" status="active" />' },
        { role => 'user', content => 'Now working on B with its own substantial context for testing compression.' },
        { role => 'assistant', content => 'On it.', tool_calls => [
            { id => 't2', function => { name => 'file_operations', arguments => '{"path":"src/b.pl"}' } }
        ] },
        { role => 'tool', tool_call_id => 't2', content => 'b code' },
    );
    my $first = $yarn->compress_messages(\@first_messages);

    # Second pass: no new messages, just reseed with previous summary
    my $second = $yarn->compress_messages([],
        previous_summary => $first->{content});

    # Both tasks should be present in the second summary
    like($second->{content}, qr/<task\s+id="task-A"/, 'task-A preserved from previous_summary');
    like($second->{content}, qr/<task\s+id="task-B"/, 'task-B preserved from previous_summary');
}

# Test 5: CSSS drop-oldest-task shrinks a 3-task summary down to fit.
{
    my $yarn = CLIO::Memory::YaRN->new();

    # Build a 3-task summary manually so we don't depend on per-task
    # content volume to be enough to overflow the target.
    my $large_summary = <<'EOF';
<threadSummary>

Current task: gamma

<task id="task-A" status="completed">
Task: alpha
Decisions:
- Decision alpha 1
- Decision alpha 2
Files:
- /very/long/path/to/alpha/file1.pm
- /very/long/path/to/alpha/file2.pm
- /very/long/path/to/alpha/file3.pm
Commits:
- abc1234: alpha commit 1
- def5678: alpha commit 2
Tools: file_operations: 5, terminal_operations: 3, apply_patch: 2
</task>

<task id="task-B" status="completed">
Task: beta
Decisions:
- Decision beta 1
Files:
- /very/long/path/to/beta/file1.pm
Commits:
- 1112222: beta commit 1
Tools: file_operations: 3
</task>

<task id="task-C" status="active">
Task: gamma
Tools: file_operations: 1
</task>

</threadSummary>
EOF

    # Force a small target so oldest task gets dropped
    my $fitted = CLIO::Memory::YaRN::_fit_summary_to_target($large_summary, 150);

    # Most-recent task must always survive
    like($fitted, qr/task id="task-C"/, 'Most recent task (task-C) survives CSSS fit');
    # task-A is the oldest - it should be dropped first under pressure
    unlike($fitted, qr/task id="task-A"/, 'Oldest task (task-A) dropped first');
}

# Test 6: CSSS does NOT drop the most recent task even under extreme pressure.
{
    my $yarn = CLIO::Memory::YaRN->new();

    my $two_task_summary = <<'EOF';
<threadSummary>

Current task: second

<task id="first" status="completed">
Task: first
Lots of content here padding the size significantly for the test.
</task>

<task id="second" status="active">
Task: second
Active task content.
</task>

</threadSummary>
EOF

    # A target small enough to force dropping 'first' but not 'second'.
    my $fitted = CLIO::Memory::YaRN::_fit_summary_to_target($two_task_summary, 30);

    # After dropping 'first', only 'second' should remain
    unlike($fitted, qr/task id="first"/, 'Oldest task dropped');
    like($fitted, qr/task id="second"/, 'Most recent task preserved');
}

done_testing();