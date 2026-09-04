#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test: _build_compressed_tail must filter continuation
# turns from the dropped-turns list. Without this, long sessions
# dominated by "continue" / "ok" prompts render the # Earlier work
# section as pure noise (User: Continue with step N. Assistant:
# Working on step N. repeated 20 times).
#
# As of 2026-09-02 the implementation uses YaRN compression
# (CLIO::Memory::YaRN::compress_messages) for the dropped-turn
# summary. YaRN surfaces a richer view (file paths, tool counts,
# decisions, discussion) than the legacy template, and the
# continuation filter is now applied BEFORE handing turns to YaRN
# so the compressor never sees pure-continuation noise. The size
# cap is unchanged: the section must stay well under the 900-char
# hard cap on the dynamic userContext.

use strict;
use warnings;
use lib './lib';

use Test::More;
use CLIO::Core::ContextBuilder;

# 25 turns: first is substantive, rest are continuation
my @turns;
push @turns, [
    { role => 'user', content => 'Please do a full QA workup on this branch - compare to main - look for smells, context loss, budget bugs.' },
    { role => 'assistant', content => 'Got it. Let me dig into the ContextBuilder.' },
];
for my $i (2..25) {
    push @turns, [
        { role => 'user', content => 'continue' },
        { role => 'assistant', content => "Working on step $i." },
        { role => 'tool', tool_call_id => "tc$i", content => 'stuff' x 50 },
    ];
}

my $tail = CLIO::Core::ContextBuilder::_build_compressed_tail(\@turns, '');

# The hard cap on the dynamic UC is 900 chars. YaRN's output for
# this input is well under that (the substantive first turn is the
# only thing that survives the continuation filter and YaRN
# produces a small summary around it). Assert it's safely under
# the cap, not on the original 300-char limit (which was tied to
# the legacy template's output shape, not the cap).
ok(length($tail) < 600,
    'compressed tail is bounded when most dropped turns are continuations')
    or diag("Got " . length($tail) . " chars:\n$tail");

# Substantive content should be preserved
like($tail, qr/QA workup/, 'substantive first-turn content preserved');
unlike($tail, qr/Working on step 2\./, 'continuation turns filtered out');
unlike($tail, qr/Working on step 25\./, 'later continuation turns filtered out');
unlike($tail, qr/User: continue/, 'pure-continuation user messages filtered out');

# Edge case: all-continuation turns => empty
my @cont_turns;
for my $i (1..10) {
    push @cont_turns, [
        { role => 'user', content => 'continue' },
        { role => 'assistant', content => 'ok' },
    ];
}
my $empty_tail = CLIO::Core::ContextBuilder::_build_compressed_tail(\@cont_turns, '');
is($empty_tail, '', 'all-continuation turns produce empty compressed tail');

# Mixed: some real turns, some continuations - the substantive user
# request must be in the output. YaRN prioritizes user requests and
# may not surface every assistant turn verbatim, so we only assert
# the user side (the intent: "Read ContextBuilder.pm and check for
# the role-based history bug") is preserved.
my @mixed_turns = (
    [
        { role => 'user', content => 'continue' },
        { role => 'assistant', content => 'ok' },
    ],
    [
        { role => 'user', content => 'Read ContextBuilder.pm and check for the role-based history bug. The anchor turn should be preserved through aggressive trimming.' },
        { role => 'assistant', content => 'Reading ContextBuilder.pm now.' },
    ],
    [
        { role => 'user', content => 'ok' },
        { role => 'assistant', content => 'y' },
    ],
);
my $mixed_tail = CLIO::Core::ContextBuilder::_build_compressed_tail(\@mixed_turns, '');
like($mixed_tail, qr/Read ContextBuilder\.pm/,
    'substantive user request kept in mixed set (YaRN prioritizes user requests)');

# Empty dropped_turns
is(CLIO::Core::ContextBuilder::_build_compressed_tail([], ''), '',
    'empty dropped_turns returns empty string');
is(CLIO::Core::ContextBuilder::_build_compressed_tail(undef, ''), '',
    'undef dropped_turns returns empty string');

done_testing();
