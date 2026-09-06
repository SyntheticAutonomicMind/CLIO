#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test: messages past the anchor cap must surface in the
# compressed_tail instead of being silently lost.
#
# Bug (BUG #1 in QA review 2026-09-02): ContextBuilder capped the
# anchor turn at MAX_ANCHOR_MESSAGES=8 and silently dropped messages
# 9..N of the anchor. For long first turns (95+ messages), the model's
# final summary on the original task vanished from the model's context.
#
# Fix: capture the trimmed portion and append it to @dropped_turns
# so _build_compressed_tail surfaces it in "Earlier work".
#
# As of 2026-09-02, the compressed_tail uses YaRN compression, so
# the surfaced content is YaRN's structured summary (file paths,
# tool counts, decisions) rather than verbatim assistant text. The
# test asserts the BUG #1 invariant - messages past the cap are not
# lost - by checking the dropped tool calls show up in the output.

use strict;
use warnings;
use utf8;
use lib './lib';

use Test::More;
use CLIO::Core::ContextBuilder;

# Build a history with one massive anchor turn and one recent turn.
# The original user message is substantive (not just repeated filler)
# so YaRN's find_substantive_task picks it up.
my @anchor_msgs;
push @anchor_msgs, { role => 'user', content => 'Original task: investigate the role-based history refactor and check whether the anchor cap drops messages past position 8 silently.' };
for my $i (1..15) {
    push @anchor_msgs, {
        role => 'assistant',
        content => "ANCHOR_MSG_$i: " . ('detail ' x 30),
        tool_calls => [{ id => "tc_a_$i", function => { name => "tool_$i", arguments => "{}" } }],
    };
    push @anchor_msgs, {
        role => 'tool',
        content => "tool result $i: " . ('data ' x 30),
        tool_call_id => "tc_a_$i",
    };
}

my @turn2 = (
    { role => 'user', content => 'later work: ' . ('detail ' x 30) },
    { role => 'assistant', content => 'later response' },
);

my @history = (@anchor_msgs, @turn2);
my $proj = CLIO::Core::ContextBuilder::build_projection(
    history => \@history,
    user_input => 'ping',
);

# Anchor is still capped at 8 (preserves the original cap behavior).
is(scalar(@{$proj->{anchor}}), 8, 'anchor capped at 8 messages (original cap unchanged)');

# The 15 tool calls past the cap were silently dropped before BUG
# #1. They now surface in compressed_tail. YaRN extracts them as
# tool usage counts. Assert at least 3 of the dropped tool names
# (tool_5 through tool_15, the ones past the cap) are in the output.
my $compressed = $proj->{compressed_tail} || '';
my @dropped_tool_names = map { "tool_$_" } (5..15);
my @found = grep { $compressed =~ /\Q$_\E/ } @dropped_tool_names;
ok(@found >= 3,
    'compressed_tail surfaces dropped tool calls (BUG #1 fix via YaRN tool counts)')
    or diag("Expected >= 3 of " . join(",", @dropped_tool_names) . " in:\n$compressed");

# Belt-and-suspenders: count the tool names that surface in the
# tail. With 11 trimmed anchor tool calls (tool_5..tool_15) in
# the dropped section, YaRN should report at least 10 of them.
my @tools_in_tail = ($compressed =~ /^-\s+(tool_\d+):/mg);
ok(@tools_in_tail >= 10,
    'compressed_tail surfaces at least 10 dropped tool calls (BUG #1 fix)')
    or diag("Found " . scalar(@tools_in_tail) . " tool names in:\n$compressed");

done_testing();
