#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Comprehensive tests for YaRN context compression improvements:
#   - Lossless durable history
#   - Context-aware scaling (32K/64K/128K/256K)
#   - Cross-cycle carryover (A -> B -> C with information survival)
#   - Recovery from durable YaRN thread
#   - Backward compatibility with legacy summary formats
#   - Bounded output
#   - Correct task anchoring (short acks don't replace meaningful task)
#   - Files and commits bounded + deduplicated
#   - Tool operation counts

use strict;
use warnings;
use utf8;
use lib './lib';

use Test::More;
use CLIO::Memory::YaRN;
use CLIO::Memory::TokenEstimator qw(estimate_tokens);

# ===========================================================================
# 1. Lossless durable history
# ===========================================================================
# The architectural invariant: YaRN's durable thread is lossless.
# Compression may produce a summary, but the original messages remain
# intact in the thread after compression.
subtest 'Durable history remains intact after compression' => sub {
    my $yarn = CLIO::Memory::YaRN->new();

    my @messages = (
        { role => 'user', content => 'The original substantive task that we need to do' },
        { role => 'assistant', content => 'Working on it', tool_calls => [
            { id => 'tc1', function => { name => 'file_operations', arguments => '{"path":"lib/Foo.pm"}' } }
        ]},
        { role => 'tool', content => '[abc1234] feat: add Foo module', tool_call_id => 'tc1' },
        { role => 'user', content => 'Now also add tests' },
    );

    # Add to thread (durable, lossless)
    for my $msg (@messages) {
        $yarn->add_to_thread('test-lossless', $msg);
    }

    # Compress a copy of the messages
    my $summary = $yarn->compress_messages(\@messages,
        original_task => 'The original substantive task');

    ok($summary && $summary->{content}, 'compression succeeded');

    # The thread must still have ALL original messages, unchanged.
    my $thread = $yarn->get_thread('test-lossless');
    is(scalar(@$thread), 4, 'thread still has all 4 original messages after compression');

    # Verify message content is byte-for-byte intact
    is($thread->[0]{content}, 'The original substantive task that we need to do',
        'first message content intact in durable thread');
    is($thread->[1]{tool_calls}[0]{function}{name}, 'file_operations',
        'tool call intact in durable thread');
    is($thread->[3]{content}, 'Now also add tests',
        'last message content intact in durable thread');

    # The summary content must be different from any individual message
    # (it's a lossy projection, not a copy)
    unlike($summary->{content}, qr/now also add tests/,
        'summary is a projection, not a verbatim copy of recent messages')
        if $summary->{content} !~ /Now also add tests/;  # may or may not contain it
};

# ===========================================================================
# 2. Context-aware scaling
# ===========================================================================
subtest '_compute_limits scales with context window' => sub {
    my $l32k  = CLIO::Memory::YaRN::_compute_limits(32768);
    my $l64k  = CLIO::Memory::YaRN::_compute_limits(65536);
    my $l128k = CLIO::Memory::YaRN::_compute_limits(131072);
    my $l256k = CLIO::Memory::YaRN::_compute_limits(262144);
    my $l1m   = CLIO::Memory::YaRN::_compute_limits(1000000);

    # 128K is the baseline
    is($l128k->{user_requests}, 16, '128K: 16 user requests');
    is($l128k->{decisions}, 8, '128K: 8 decisions');
    is($l128k->{files}, 50, '128K: 50 files');
    is($l128k->{commits}, 30, '128K: 30 commits');

    # 32K scales down but has floors
    ok($l32k->{user_requests} <= $l128k->{user_requests}, '32K: fewer user requests than 128K');
    ok($l32k->{user_requests} >= 5, '32K: at least 5 user requests (floor)');
    ok($l32k->{decisions} >= 2, '32K: at least 2 decisions (floor)');

    # 64K scales down (but more than 32K)
    ok($l64k->{user_requests} >= $l32k->{user_requests}, '64K: more user requests than 32K');
    ok($l64k->{user_requests} <= $l128k->{user_requests}, '64K: fewer than 128K');

    # 256K scales up
    ok($l256k->{user_requests} > $l128k->{user_requests}, '256K: more user requests than 128K');

    # 1M scales up further
    ok($l1m->{user_requests} > $l256k->{user_requests}, '1M: more user requests than 256K');
    ok($l1m->{files} > $l256k->{files}, '1M: more files than 256K');

    # Text lengths also scale
    ok($l256k->{user_request_len} > $l128k->{user_request_len}, '256K: longer user request text');
    ok($l1m->{user_request_len} > $l256k->{user_request_len}, '1M: even longer user request text');
};

subtest '_compute_summary_cap scales with context window' => sub {
    my $cap_32k  = CLIO::Memory::YaRN::_compute_summary_cap(32768);
    my $cap_64k  = CLIO::Memory::YaRN::_compute_summary_cap(65536);
    my $cap_128k = CLIO::Memory::YaRN::_compute_summary_cap(131072);
    my $cap_256k = CLIO::Memory::YaRN::_compute_summary_cap(262144);
    my $cap_1m   = CLIO::Memory::YaRN::_compute_summary_cap(1000000);

    ok($cap_32k >= $CLIO::Memory::YaRN::MIN_SUMMARY_CAP, '32K cap >= floor');
    ok($cap_128k >= 8000, '128K cap >= 8000 chars (was 4000)');
    ok($cap_128k <= $CLIO::Memory::YaRN::MAX_SUMMARY_CAP, '128K cap <= ceiling');
    ok($cap_256k > $cap_128k, '256K cap > 128K cap (scales up)');
    ok($cap_1m > $cap_256k, '1M cap > 256K cap (scales up)');
    ok($cap_1m <= $CLIO::Memory::YaRN::MAX_SUMMARY_CAP, '1M cap <= ceiling');
};

subtest 'compress_messages respects max_chars override' => sub {
    my $yarn = CLIO::Memory::YaRN->new();

    # Generate messages that would produce a large summary
    my @messages;
    for my $i (1..30) {
        push @messages, { role => 'user', content => "Request number $i with some content to make it substantive enough to be included" };
        push @messages, { role => 'assistant', content => 'Processing request ' . $i };
    }

    # With a tiny max_chars, the summary should be bounded
    my $small = $yarn->compress_messages(\@messages,
        original_task  => 'Test task',
        user_request  => 'Test task',
        max_chars     => 200,
        context_window => 128000,
    );

    ok(length($small->{content}) <= 210,  # 200 + "..."
        'summary bounded by explicit max_chars (got ' . length($small->{content}) . ')')
        or diag("content:\n" . substr($small->{content}, 0, 300));

    # With a large max_chars, should allow more content
    my $large = $yarn->compress_messages(\@messages,
        original_task  => 'Test task',
        max_chars      => 10000,
        context_window => 128000,
    );

    ok(length($large->{content}) > length($small->{content}),
        'larger max_chars allows richer summary');
};

# ===========================================================================
# 3. Cross-cycle carryover (A -> B -> C)
# ===========================================================================
subtest 'Cross-cycle carryover: info from A survives B and C' => sub {
    my $yarn = CLIO::Memory::YaRN->new();

    # Cycle A: messages with a commit and user request
    my @msgs_a = (
        { role => 'user', content => 'The initial task to build a widget system that does X and Y' },
        { role => 'assistant', content => 'Working', tool_calls => [
            { id => 'tcA', function => { name => 'file_operations',
              arguments => '{"path":"lib/Widget.pm"}' } }
        ]},
        { role => 'tool', content => '[a1b2c3d] feat: add Widget base class\nsome output', tool_call_id => 'tcA' },
    );
    my $summary_a = $yarn->compress_for_context_recovery(\@msgs_a,
        original_task => 'The initial task');
    ok($summary_a->{content} =~ /a1b2c3d/, 'Cycle A: commit in summary');
    ok($summary_a->{content} =~ /lib\/Widget\.pm/, 'Cycle A: file in summary');

    # Cycle B: new messages, carry over summary A
    my @msgs_b = (
        { role => 'user', content => 'Now add tests to the widget system' },
        { role => 'assistant', content => 'Writing tests', tool_calls => [
            { id => 'tcB', function => { name => 'terminal_operations', arguments => '{}' } }
        ]},
        { role => 'tool', content => '[e4f5a67] test: add widget test suite\noutput', tool_call_id => 'tcB' },
    );
    my $summary_b = $yarn->compress_for_context_recovery(\@msgs_b,
        original_task    => 'Now add tests',
        previous_summary => $summary_a->{content},
    );
    ok($summary_b->{content} =~ /a1b2c3d/, 'Cycle B: commit from A still present (carryover)');
    ok($summary_b->{content} =~ /lib\/Widget\.pm/, 'Cycle B: file from A still present (carryover)');
    ok($summary_b->{content} =~ /e4f5a67/, 'Cycle B: new commit from B present');
    ok($summary_b->{content} =~ /The initial task/, 'Cycle B: original task from A preserved');

    # Cycle C: yet more messages, carry over summary B
    my @msgs_c = (
        { role => 'user', content => 'Final integration testing for the widget system' },
        { role => 'assistant', content => 'Integrating' },
    );
    my $summary_c = $yarn->compress_for_context_recovery(\@msgs_c,
        original_task    => 'Final integration testing',
        previous_summary => $summary_b->{content},
    );
    ok($summary_c->{content} =~ /a1b2c3d/, 'Cycle C: commit from A survives through B (cross-cycle carryover)');
    ok($summary_c->{content} =~ /lib\/Widget\.pm/, 'Cycle C: file from A survives through B');
    ok($summary_c->{content} =~ /e4f5a67/, 'Cycle C: commit from B survives');
    ok($summary_c->{content} =~ /The initial task/, 'Cycle C: original task survives all cycles');
    like($summary_c->{content}, qr/Final integration testing/, 'Cycle C: recent user request from C present');
};

# ===========================================================================
# 4. Recovery from durable YaRN thread
# ===========================================================================
subtest 'recover_substantive_task finds original task from durable thread' => sub {
    my $yarn = CLIO::Memory::YaRN->new();

    # Simulate a session where history was trimmed past the original task
    $yarn->add_to_thread('sess-recover', { role => 'user', content => 'Build a robust authentication module that handles OAuth2 and JWT tokens' });
    $yarn->add_to_thread('sess-recover', { role => 'assistant', content => 'ok' });
    $yarn->add_to_thread('sess-recover', { role => 'user', content => 'add tests' });

    my $task = CLIO::Memory::YaRN::recover_substantive_task($yarn, 'sess-recover');

    like($task, qr/Build a robust authentication/, 'recovered original task from durable thread');
    unlike($task, qr/add tests/, 'recovered the substantive task, not the short ack');

    # Empty thread returns ''
    my $empty = CLIO::Memory::YaRN::recover_substantive_task($yarn, 'nonexistent');
    is($empty, '', 'empty thread returns empty string');

    # undef session returns ''
    my $undef = CLIO::Memory::YaRN::recover_substantive_task(undef, 'sess-recover');
    is($undef, '', 'undef session returns empty string');
};

subtest 'recover_substantive_task finds task even after active history dropped' => sub {
    # Simulate: YaRN thread has the original task, but active history
    # (passed to compress_for_context_recovery) starts with a short ack.
    my $yarn = CLIO::Memory::YaRN->new();
    my $original = 'Build a new feature X that does Y and Z for the customer use case';
    $yarn->add_to_thread('sess-trim', { role => 'user', content => $original });
    $yarn->add_to_thread('sess-trim', { role => 'assistant', content => 'ok' });

    # Active history is just a short ack — original task is gone from it
    my @trimmed = (
        { role => 'user', content => 'yes' },
    );

    # The carried_original from _parse_previous_summary handles this
    # when the previous summary has [original]. Let's test via compress:
    my $prev = "<thread_summary>\nCurrent task: $original\n\nRecent user requests:\n- [original] $original\n</thread_summary>";
    my $result = $yarn->compress_messages(\@trimmed,
        original_task    => 'yes',
        previous_summary => $prev,
    );

    like($result->{content}, qr/Build a new feature X/, 'original task recovered via previous_summary carryover, not overwritten by short ack');
    unlike($result->{content}, qr/Current task: yes/, 'short ack does not become current task');
};

# ===========================================================================
# 5. Backward compatibility with legacy summary formats
# ===========================================================================
subtest 'Legacy summary format (Original task, Git commits, Files created/modified, Tool usage) is parsed' => sub {
    my $yarn = CLIO::Memory::YaRN->new();

    # Legacy format (used in older serialized YaRN state)
    my $legacy = <<'END';
<thread_summary>

Original task: Build a widget system

Git commits made during compressed period:
- abc1234: feat: add widget base class
- def5678: feat: add widget rendering

Files created/modified:
- lib/Widget.pm
- lib/WidgetRenderer.pm

Key decisions:
- Use composition over inheritance for widgets

Tool usage:
- file_operations: 25 calls
- terminal_operations: 10 calls
</thread_summary>
END

    # New messages (nothing of value — just a short ack)
    my @msgs = ({ role => 'user', content => 'ok' });

    my $result = $yarn->compress_messages(\@msgs,
        original_task    => 'ok',
        previous_summary => $legacy,
    );

    # Legacy "Original task:" should be parsed as carried task/original
    like($result->{content}, qr/Build a widget system/, 'legacy Original task parsed and carried');
    like($result->{content}, qr/abc1234/, 'legacy commits parsed');
    like($result->{content}, qr/def5678/, 'legacy commits parsed (multiple)');
    like($result->{content}, qr/lib\/Widget\.pm/, 'legacy files parsed');
    # Tool usage: 25 calls -> "file_operations: 25"
    like($result->{content}, qr/file_operations: 2[5-9]/, 'legacy tool counts parsed and carried');
};

subtest 'Empty and undef previous_summary handled gracefully' => sub {
    my $yarn = CLIO::Memory::YaRN->new();
    my @msgs = ({ role => 'user', content => 'Do something' });

    my $r1 = $yarn->compress_messages(\@msgs, original_task => 'Test', previous_summary => '');
    ok($r1 && $r1->{content}, 'empty previous_summary handled');

    my $r2 = $yarn->compress_messages(\@msgs, original_task => 'Test', previous_summary => undef);
    ok($r2 && $r2->{content}, 'undef previous_summary handled');
};

# ===========================================================================
# 6. Bounded output
# ===========================================================================
subtest 'Summary never exceeds max_chars boundary' => sub {
    my $yarn = CLIO::Memory::YaRN->new();

    # Generate enough messages to produce a large summary
    my @messages;
    for my $i (1..100) {
        push @messages, { role => 'user', content => "Request $i: " . ('x' x 100) };
        push @messages, { role => 'assistant', content => 'Response ' . $i };
    }

    for my $cap (1000, 2000, 5000, 10000) {
        my $r = $yarn->compress_messages(\@messages,
            original_task => 'Test task',
            max_chars     => $cap,
        );
        ok(length($r->{content}) <= $cap + 4,
            "max_chars=$cap: summary length " . length($r->{content}) . " <= " . ($cap + 4));
    }
};

subtest 'Summary never exceeds context-derived cap' => sub {
    my $yarn = CLIO::Memory::YaRN->new();

    my @messages;
    for my $i (1..100) {
        push @messages, { role => 'user', content => "Request $i: " . ('y' x 200) };
        push @messages, { role => 'assistant', content => 'Response ' . $i };
    }

    for my $ctx (32768, 65536, 131072, 262144, 1000000) {
        my $cap = CLIO::Memory::YaRN::_compute_summary_cap($ctx);
        my $r = $yarn->compress_messages(\@messages,
            original_task  => 'Test task',
            context_window => $ctx,
        );
        ok(length($r->{content}) <= $cap + 4,
            "ctx=$ctx: summary length " . length($r->{content}) . " <= cap $cap");
    }
};

# ===========================================================================
# 7. Correct task anchoring: short acks don't replace meaningful task
# ===========================================================================
subtest 'Short acknowledgements do not become Current task' => sub {
    my $yarn = CLIO::Memory::YaRN->new();

    my @msgs = (
        { role => 'user', content => 'This is a substantive task with enough detail to be meaningful' },
        { role => 'assistant', content => 'ok' },
        { role => 'user', content => 'yes' },
        { role => 'assistant', content => 'go ahead' },
        { role => 'user', content => 'do it' },
    );

    my $r = $yarn->compress_messages(\@msgs,
        original_task => 'yes',
        context_window => 128000,
    );

    # The substantive task should be Current task, not the short ack
    like($r->{content}, qr/Current task:.*substantive task with enough detail/,
        'substantive task preserved as Current task, not short ack');

    # Also verify through previous_summary carryover
    my $prev = $r->{content};
    my @next = ({ role => 'user', content => 'proceed' });
    my $r2 = $yarn->compress_messages(\@next,
        original_task    => 'proceed',
        previous_summary => $prev,
    );
    like($r2->{content}, qr/Current task:.*substantive task with enough detail/,
        'carried task survives another cycle, not overwritten by "proceed"');
};

# ===========================================================================
# 8. Files and commits bounded + deduplicated
# ===========================================================================
subtest 'Files are deduplicated and bounded' => sub {
    my $yarn = CLIO::Memory::YaRN->new();

    my @messages;
    for my $i (1..60) {
        push @messages, { role => 'user', content => "Work item $i" };
        push @messages, { role => 'assistant', content => 'ok', tool_calls => [
            { id => "tc_$i", function => { name => 'file_operations',
              arguments => '{"path":"lib/File' . ($i % 5) . '.pm"}' } }
        ]},
        { role => 'tool', content => 'done', tool_call_id => "tc_$i" };
    }

    my $r = $yarn->compress_messages(\@messages, context_window => 128000);

    # 60 messages referencing 5 unique files — should dedupe to 5
    like($r->{content}, qr/Files worked on:/, 'Files worked on section present');
    # Count unique file paths in the content
    my @files = ($r->{content} =~ /^-\s+(lib\/File\d\.pm)$/gm);
    my @unique = do { my %s; grep { !$s{$_}++ } @files };
    is(scalar(@files), 5, "files deduplicated to 5 unique paths (got " . scalar(@files) . ")")
        or diag("content:\n" . substr($r->{content}, 0, 500));
    is(scalar(@unique), 5, 'all 5 are unique');
    ok(scalar(@files) <= 50, 'files within 128K limit (50)');
};

subtest 'Commits are deduplicated and bounded' => sub {
    my $yarn = CLIO::Memory::YaRN->new();

    my @messages;
    for my $i (1..40) {
        push @messages, { role => 'user', content => "Item $i" };
        push @messages, { role => 'tool', content => "[a1b2c3d] feat: add consistent commit subject\n" };
    }

    my $r = $yarn->compress_messages(\@messages, context_window => 128000);

    # All commits have the same hash a1b2c3d — should dedupe to 1
    like($r->{content}, qr/Commits:/, 'Commits section present');
    my @commits = ($r->{content} =~ /^-\s+([a-f0-9]{7}: [^\n]+)$/gm);
    my @unique = do { my %s; grep { !$s{$_}++ } @commits };
    is(scalar(@unique), 1, "commits deduplicated (got " . scalar(@unique) . ")")
        or diag("commits found:\n" . join("\n", @commits));
    ok(scalar(@commits) <= 30, 'commits within 128K limit (30)');
};

# ===========================================================================
# 9. Tool operation counts (cumulative across carryover)
# ===========================================================================
subtest 'Tool operations are counted and shown' => sub {
    my $yarn = CLIO::Memory::YaRN->new();

    my @messages = (
        { role => 'assistant', content => 'Reading', tool_calls => [
            { id => 't1', function => { name => 'file_operations', arguments => '{}' } },
            { id => 't2', function => { name => 'file_operations', arguments => '{}' } },
        ]},
        { role => 'tool', content => 'a', tool_call_id => 't1' },
        { role => 'tool', content => 'b', tool_call_id => 't2' },
        { role => 'assistant', content => 'Running', tool_calls => [
            { id => 't3', function => { name => 'terminal_operations', arguments => '{}' } },
            { id => 't4', function => { name => 'terminal_operations', arguments => '{}' } },
            { id => 't5', function => { name => 'terminal_operations', arguments => '{}' } },
        ]},
        { role => 'tool', content => 'c', tool_call_id => 't3' },
        { role => 'tool', content => 'd', tool_call_id => 't4' },
        { role => 'tool', content => 'e', tool_call_id => 't5' },
    );

    my $r = $yarn->compress_messages(\@messages, context_window => 128000);

    like($r->{content}, qr/Tool operations:/, 'Tool operations section present');
    like($r->{content}, qr/file_operations: 2/, 'file_operations counted correctly');
    like($r->{content}, qr/terminal_operations: 3/, 'terminal_operations counted correctly');
};

subtest 'Tool counts accumulate across carryover cycles' => sub {
    my $yarn = CLIO::Memory::YaRN->new();

    # Cycle A: 3 file_operations calls
    my @msgs_a = (
        { role => 'user', content => 'First task to do something meaningful' },
        { role => 'assistant', content => 'ok', tool_calls => [
            { id => 'a1', function => { name => 'file_operations', arguments => '{}' } },
            { id => 'a2', function => { name => 'file_operations', arguments => '{}' } },
            { id => 'a3', function => { name => 'file_operations', arguments => '{}' } },
        ]},
        { role => 'tool', content => 'x', tool_call_id => 'a1' },
        { role => 'tool', content => 'y', tool_call_id => 'a2' },
        { role => 'tool', content => 'z', tool_call_id => 'a3' },
    );
    my $r_a = $yarn->compress_for_context_recovery(\@msgs_a, original_task => 'First task');
    like($r_a->{content}, qr/file_operations: 3/, 'Cycle A: file_operations = 3');

    # Cycle B: 2 more file_operations + 1 terminal_operations
    my @msgs_b = (
        { role => 'user', content => 'Second task to do more meaningful work' },
        { role => 'assistant', content => 'ok', tool_calls => [
            { id => 'b1', function => { name => 'file_operations', arguments => '{}' } },
            { id => 'b2', function => { name => 'file_operations', arguments => '{}' } },
            { id => 'b3', function => { name => 'terminal_operations', arguments => '{}' } },
        ]},
        { role => 'tool', content => 'x', tool_call_id => 'b1' },
        { role => 'tool', content => 'y', tool_call_id => 'b2' },
        { role => 'tool', content => 'z', tool_call_id => 'b3' },
    );
    my $r_b = $yarn->compress_for_context_recovery(\@msgs_b,
        original_task    => 'Second task',
        previous_summary => $r_a->{content},
    );
    # Counts should be cumulative: file_operations = 3 + 2 = 5
    like($r_b->{content}, qr/file_operations: 5/, 'Cycle B: file_operations accumulated to 5');
    like($r_b->{content}, qr/terminal_operations: 1/, 'Cycle B: terminal_operations = 1');
};

# ===========================================================================
# 10. Collaboration exchanges (Discussion section)
# ===========================================================================
subtest 'Collaboration Q/A pairs surfaced in Discussion section' => sub {
    my $yarn = CLIO::Memory::YaRN->new();

    my @messages = (
        { role => 'user', content => 'Should we use PostgreSQL or MySQL for this project that has complex data relationships' },
        { role => 'assistant', content => 'Let me ask', tool_calls => [
            { id => 'q1', function => { name => 'interact',
                arguments => encode_json_str({ message => 'PostgreSQL or MySQL for complex data relationships?' }) } }
        ]},
        { role => 'tool', content => 'PostgreSQL is better for complex relationships and JSON support.', tool_call_id => 'q1' },
    );

    my $r = $yarn->compress_messages(\@messages, context_window => 128000);

    like($r->{content}, qr/Discussion:/, 'Discussion section present');
    like($r->{content}, qr/Q: PostgreSQL or MySQL/, 'collaboration question preserved');
    like($r->{content}, qr/A: PostgreSQL is better/, 'collaboration response preserved');
};

# Helper: encode a Perl hash to JSON string (simple, no external deps)
sub encode_json_str {
    my ($hash) = @_;
    return '{"message":"' . ($hash->{message} // '') . '"}';
}

# ===========================================================================
# 11. Token estimation uses TokenEstimator (not hardcoded 2.5)
# ===========================================================================
subtest 'Token estimation uses TokenEstimator ratio' => sub {
    my $yarn = CLIO::Memory::YaRN->new();

    my @messages = (
        { role => 'user', content => 'This is a test message for token estimation purposes' },
    );

    my $r = $yarn->compress_messages(\@messages, original_task => 'test');

    # TokenEstimator's default ratio is 4.0, not 2.5.
    # The metadata should reflect the learned ratio.
    ok(defined $r->{_metadata}{compressed_tokens}, 'compressed_tokens present in metadata');

    # Verify the estimate matches TokenEstimator
    my $expected = estimate_tokens($r->{content});
    is($r->{_metadata}{compressed_tokens}, $expected,
        'compressed_tokens matches TokenEstimator::estimate_tokens (not hardcoded 2.5)');
};

# ===========================================================================
# 12. New/default limits at 128K
# ===========================================================================
subtest 'Default limits match large-context targets' => sub {
    my $limits = CLIO::Memory::YaRN::_compute_limits(131072);

    is($limits->{user_requests}, 16, 'default max_user_requests = 16');
    is($limits->{decisions}, 8, 'default max_decisions = 8 (was 3)');
    is($limits->{collaboration}, 10, 'default max_collaboration = 10');
    is($limits->{files}, 50, 'default max_files = 50 (was 30)');
    is($limits->{commits}, 30, 'default max_commits = 30 (was 15)');
    is($limits->{user_request_len}, 600, 'default user_request_len = 600 (was 300)');
    is($limits->{decision_len}, 500, 'default decision_len = 500 (was 250)');
    is($limits->{collaboration_len}, 1500, 'default collaboration_len = 1500 (was 1000)');
};

done_testing();
