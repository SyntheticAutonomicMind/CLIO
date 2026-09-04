#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test: _select_turns caps the anchor turn size to keep
# the cache-stable prefix bounded.
#
# Problem: a long anchor turn (95 messages with thousands of tool
# result bodies) bloats the cache-stable prefix, pushes the dynamic
# userContext off recency, and duplicates content the model can
# re-derive via memory_operations.
#
# Fix: cap anchor at MAX_ANCHOR_MESSAGES (8). The first user message
# is force-included even if the cap would drop it (the anchor MUST
# carry the original task).
#
# This test simulates a long anchor turn (20 messages) and asserts
# the projection's anchor is at most MAX_ANCHOR_MESSAGES, with the
# first user message preserved.

use strict;
use warnings;
use utf8;
use lib './lib';

use Test::More;
use CLIO::Core::ContextBuilder;

# Build a history where turn 0 is a long investigation:
#   user (substantive, >=50 chars) +
#   many assistant/tool pairs (tool calls + tool results)
my @long_anchor_msgs;
push @long_anchor_msgs, { role => 'user', content => 'Please do a full QA workup on this branch - compare to main - look for smells, context loss, budget bugs' };
for my $i (1..20) {
    push @long_anchor_msgs, {
        role    => 'assistant',
        content => '',
        tool_calls => [{ id => "tc_$i", function => { name => "tool_$i", arguments => "{}" } }],
    };
    push @long_anchor_msgs, {
        role => 'tool',
        content => "Tool result $i: " . ("x" x 500),
        tool_call_id => "tc_$i",
    };
}
# Recent turn.
my @recent_msgs = (
    { role => 'user', content => 'continue' },
    { role => 'assistant', content => 'investigation continues', tool_calls => [{ id => 'tc_recent', function => { name => 'foo' } }] },
    { role => 'tool', content => 'recent tool result', tool_call_id => 'tc_recent' },
);

my @history = (@long_anchor_msgs, @recent_msgs);

my $proj = CLIO::Core::ContextBuilder::build_projection(
    history    => \@history,
    user_input => 'ping',
);

ok(defined $proj->{anchor}, 'anchor is defined for long anchor turn');
ok(ref($proj->{anchor}) eq 'ARRAY', 'anchor is arrayref');
ok(scalar(@{$proj->{anchor}}) <= 8,
    'anchor turn is capped at MAX_ANCHOR_MESSAGES (8)');
ok(scalar(@{$proj->{anchor}}) >= 1, 'anchor turn is not empty');

# The user message MUST be the first element of the anchor (the cap
# is allowed to drop everything after, but never the original task).
is($proj->{anchor}[0]{role}, 'user',
    'anchor[0] is the user role (original task is preserved)');
like($proj->{anchor}[0]{content}, qr/full QA workup/,
    'anchor[0] contains the original task content');

done_testing();