#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test: tool usage counts ("Tools:" with "N calls") are NOT
# rendered in any <threadSummary> output. Counts are useless noise —
# what matters is the persisted chunk table (toolCallId + path + bytes)
# which lets the model re-read the actual content.

use strict;
use warnings;
use utf8;
use lib '/home/deck/repositories/CLIO/lib';
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Test::More;
use CLIO::Memory::YaRN;

# ── Flat renderer does not emit tool counts ───────────────────────────
{
    my $bucket = {
        user_requests           => ['Implement the routing feature for provider selection'],
        commits                 => ['feat: add routing'],
        files_touched           => ['lib/CLIO/Routing.pm'],
        decisions               => ['Use hash-based routing'],
        collaboration_exchanges => [],
        tool_counts             => { 'file_operations' => 42, 'terminal_operations' => 7 },
        persisted_chunks        => [],
    };

    my $out = CLIO::Memory::YaRN::_render_flat_summary($bucket,
        original_task => 'Implement the routing feature for provider selection',
    );

    unlike($out, qr/Tools:\s*$/m,
       'Flat render: no "Tools:" section header');
    unlike($out, qr/- file_operations: \d+ calls/,
       'Flat render: no "file_operations: N calls" line');
    unlike($out, qr/- terminal_operations: \d+ calls/,
       'Flat render: no "terminal_operations: N calls" line');
    unlike($out, qr/\d+\s+calls/,
       'Flat render: no "N calls" anywhere');
}

# ── Task-block renderer does not emit tool counts ──────────────────────
{
    my $block = CLIO::Memory::YaRN::_render_single_task_block('task-1', {
        name                    => 'routing',
        user_requests           => ['Implement routing'],
        commits                 => [],
        files_touched           => [],
        decisions               => [],
        collaboration_exchanges => [],
        tool_counts             => { 'file_operations' => 99, 'git_operations' => 33 },
        persisted_chunks        => [],
        todo_id                 => undef,
        status                  => 'in_progress',
    });

    unlike($block, qr/Tools:\s/,
       'Task-block render: no "Tools:" line');
    unlike($block, qr/file_operations:\s*\d+/,
       'Task-block render: no file_operations count');
    unlike($block, qr/\d+\s+calls/,
       'Task-block render: no "N calls" anywhere');
}

# ── Full compress_messages does not emit tool counts ───────────────────
{
    my @messages = (
        { role => 'user',      content => 'I need to implement a routing system for API provider selection in CLIO. This involves creating a new routing module, adding CLI options, and updating documentation.' },
        { role => 'assistant', content => 'I will create the routing module first.', tool_calls => [{ function => { name => 'file_operations' } }] },
        { role => 'tool',      content => 'done', tool_call_id => 'call_1' },
        { role => 'assistant', content => 'Now I will add the CLI option.', tool_calls => [{ function => { name => 'terminal_operations' } }] },
        { role => 'tool',      content => 'done', tool_call_id => 'call_2' },
        { role => 'user',      content => 'Check if the tests pass.' },
    );

    my $yarn = CLIO::Memory::YaRN->new();
    my $result = $yarn->compress_messages(\@messages,
        original_task => 'I need to implement a routing system for API provider selection in CLIO. This involves creating a new routing module, adding CLI options, and updating documentation.'
    );

    my $content = $result->{content};
    unlike($content, qr/Tools:\s*$/m,
           'compress_messages: no "Tools:" header');
    unlike($content, qr/\d+\s+calls/,
           'compress_messages: no call counts');
    like($content, qr/Current task:/,
         'compress_messages: still has Current task line');
}

done_testing();
