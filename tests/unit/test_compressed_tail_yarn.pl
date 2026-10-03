#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Test: _build_compressed_tail uses YaRN compression, surfacing file
# paths, tool counts, and decisions from dropped turns. The dropped-
# tail section must stay under the context-aware cap.

use strict;
use warnings;
use utf8;
use lib './lib';

use Test::More;
use CLIO::Core::ContextBuilder;
use CLIO::Memory::YaRN ();

# Use a 128K context window so the cap is predictable.
my $CTX = 128000;
my $expected_cap = CLIO::Core::ContextBuilder::_compute_compressed_tail_cap($CTX);

# Build a dropped-turns list simulating a session where the model
# did real work: read files, ran git commands, made commits.
# Each tool_call has realistic arguments so YaRN can extract
# file paths; each tool result is a realistic body.
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

my $tail = CLIO::Core::ContextBuilder::_build_compressed_tail(\@dropped, 'Audit role-based refactor', $CTX);

# 1. Section is non-empty and under the context-aware cap.
ok(length($tail) > 0, 'compressed tail is non-empty for substantive dropped turns');
ok(length($tail) <= $expected_cap, 'compressed tail is under context-aware cap')
    or diag("Got " . length($tail) . " chars, cap was $expected_cap:\n$tail");

# 2. YaRN output is identifiable by its structured section markers.
like($tail, qr/Current task:|Recent user requests:/, 'YaRN compression output is present (structured sections found)');

# 3. The "Current task" section surfaces a substantive user request.
like($tail, qr/Current task:.*Investigate the role-based history/s,
    'Current task: surfaces a substantive user request from dropped turns')
    or diag("tail:\n$tail");

# 4. Files were extracted from tool calls and included in the summary.
like($tail, qr/lib\/CLIO\/Core\/ContextBuilder\.pm/, 'file path extracted from tool calls');

# 5. Tool operations are counted and included.
like($tail, qr/Tool operations:/, 'Tool operations section present');
like($tail, qr/file_operations: \d+/, 'tool operation count present');

# 6. No framework narration or raw variable names in output.
unlike($tail, qr/files_touched|Tool calls:|_metadata|compressed_count/,
    'no raw framework narration in compressed output');

# 7. Continuation filtering still applies (mixed input).
my @mixed = (
    [
        { role => 'user', content => 'continue' },
        { role => 'assistant', content => 'ok' },
    ],
    @dropped,
);
my $mixed_tail = CLIO::Core::ContextBuilder::_build_compressed_tail(\@mixed, '', $CTX);
unlike($mixed_tail, qr/Current task:.*continue$/,
    'pure-continuation user messages still filtered from the YaRN input')
    or diag("tail:\n$mixed_tail");

# 8. Empty dropped_turns still returns empty string.
is(CLIO::Core::ContextBuilder::_build_compressed_tail([], '', $CTX), '',
    'empty dropped_turns returns empty string');

# 9. All-continuation dropped_turns returns empty string (YaRN sees
# only continuations, summary is empty after the filter, fallback
# path also returns empty).
my @cont = (
    { role => 'user',    content => 'continue' },
    { role => 'assistant', content => 'ok' },
    { role => 'user',    content => 'y' },
    { role => 'assistant', content => 'proceed' },
);
my $cont_tail = CLIO::Core::ContextBuilder::_build_compressed_tail([\@cont], '', $CTX);
is($cont_tail, '', 'all-continuation dropped turns return empty tail');

# 10. Context scaling: 32K context produces a smaller cap than 1M.
my $cap_32k  = CLIO::Core::ContextBuilder::_compute_compressed_tail_cap(32768);
my $cap_1m   = CLIO::Core::ContextBuilder::_compute_compressed_tail_cap(1000000);
ok($cap_32k < $cap_1m, '32K context gets smaller cap than 1M context (scaling works)');
ok($cap_32k > 0,   '32K cap is positive');
ok($cap_1m  > $cap_32k * 3, '1M cap is substantially larger than 32K cap');

# 11. YaRN summary cap also scales with context.
my $yarn_cap_32k = CLIO::Memory::YaRN::_compute_summary_cap(32768);
my $yarn_cap_1m  = CLIO::Memory::YaRN::_compute_summary_cap(1000000);
ok($yarn_cap_32k < $yarn_cap_1m, 'YaRN summary cap scales: 32K < 1M');

done_testing();
