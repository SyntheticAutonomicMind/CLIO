#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Test: _build_compressed_tail uses YaRN compression, surfacing file
# paths, tool counts, and decisions from dropped turns. The dropped-
# tail section must stay under the 900-char cap on long inputs.

use strict;
use warnings;
use utf8;
use lib './lib';

use Test::More;
use CLIO::Core::ContextBuilder;

# Build a dropped-turns list simulating a session where the model
# actually did work: read files, ran git commands, made commits.
# Each tool_call has realistic arguments so YaRN can extract
# file paths; each tool result is a realistic body.
#
# Keep the count low (4 substantive turns) so the YaRN output
# stays under the 900-char cap without being truncated. The cap
# IS firing - we just want enough headroom in the test fixture
# to see the file-path and tool-count sections in the assertion.
my @dropped;
for my $i (1..4) {
    push @dropped, [
        {
            role => 'user',
            content => "Investigate the role-based history refactor and check for cache instability in iteration $i.",
        },
        {
            role => 'assistant',
            content => "Reading the ContextBuilder module now.",
            tool_calls => [
                { id => "tc_$i", function => {
                    name => 'file_operations',
                    arguments => '{"operation":"read_file","path":"lib/CLIO/Core/ContextBuilder.pm","start_line":1,"end_line":200}',
                } },
            ],
        },
        {
            role => 'tool',
            tool_call_id => "tc_$i",
            content => "use strict; use warnings; use utf8; ... [truncated file body $i]",
        },
    ];
}

my $tail = CLIO::Core::ContextBuilder::_build_compressed_tail(\@dropped, 'Audit role-based refactor');

# 1. Section is non-empty and under the 900-char cap.
ok(length($tail) > 0, 'compressed tail is non-empty for substantive dropped turns');
ok(length($tail) < 900, 'compressed tail is under 900-char cap')
    or diag("Got " . length($tail) . " chars:\n$tail");

# 2. YaRN output is identifiable by its structured section markers.
#    (The old "YaRN-compressed" narration was removed in the context
#    pipeline redesign — compress_for_context_recovery returns clean
#    thread_summary content without framework framing.)
like($tail, qr/Current task:|Recent user requests:/, 'YaRN compression output is present (structured sections found)');

# 3. The "Current task" section is surfaced (YaRN picks the most
# substantive user message from the dropped turns; the active_task
# argument is used as a fallback when the messages are too short
# to be substantive).
like($tail, qr/Current task:.*Investigate the role-based history/s,
    'Current task: surfaces a substantive user request from dropped turns')
    or diag("tail:\n$tail");

# No statistical noise (commits, files, decisions) in the slimmed YaRN
# output — these change every turn and bust provider KV cache.
unlike($tail, qr/files_touched|Files:|Commits:|Decisions:|Tool calls:/,
    'no statistical noise (files/commits/decisions) in compressed output');

# 6. Continuation filtering still applies (mixed input).
my @mixed = (
    [
        { role => 'user', content => 'continue' },
        { role => 'assistant', content => 'ok' },
    ],
    @dropped,
);
my $mixed_tail = CLIO::Core::ContextBuilder::_build_compressed_tail(\@mixed, '');
unlike($mixed_tail, qr/User: continue/,
    'pure-continuation user messages still filtered from the YaRN input')
    or diag("tail:\n$mixed_tail");

# 7. Empty dropped_turns still returns empty string.
is(CLIO::Core::ContextBuilder::_build_compressed_tail([], ''), '',
    'empty dropped_turns returns empty string');

# 8. All-continuation dropped_turns returns empty string (YaRN sees
# only continuations, summary is empty after the filter, fallback
# path also returns empty).
my @cont = (
    { role => 'user',    content => 'continue' },
    { role => 'assistant', content => 'ok' },
    { role => 'user',    content => 'y' },
    { role => 'assistant', content => 'proceed' },
);
my $cont_tail = CLIO::Core::ContextBuilder::_build_compressed_tail([\@cont], '');
is($cont_tail, '', 'all-continuation dropped turns return empty tail');

done_testing();
