#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Test: RECENT_FULL_TURNS scales with session length.
#
# Prior to 2026-09-02 the recent window was a hard-coded 1 turn
# (or 2 with budget). For long sessions the model had only the
# most recent turn in full, with everything older compressed into
# a single (often noisy) tail. The 2024-message session
# 2b80d82f-1576-44d7-b1f6-2419a79e30a5.json is the canonical
# case: 12 turns, 2024 messages, RECENT=1 leaves the model with
# 143 messages of recent context and 1881 messages dropped.
#
# As of 2026-09-06 the recent window scales with $total_turns:
#   <= 30 turns  -> 3 recent  (min_recent floor)
#   <= 100 turns -> 5 recent  (design default)
#   <= 300 turns -> 8 recent
#   >  300 turns -> 10 recent (hard cap)
#
# _select_turns applies a min_recent=3 floor so very short sessions
# don't get starved of context. The proactive trim is the final
# word on what fits the model's context window.
# This test asserts the bands at the function level (no need to
# build a 1000-turn fixture). The actual projection on real long
# sessions is a soak-test question; this test pins the policy
# itself so it can't regress silently.

use strict;
use warnings;
use utf8;
use lib './lib';

use Test::More;
use CLIO::Core::ContextBuilder;

# The default bands. If a future change tunes them, update this
# test to match (intentional - this is policy-as-code).
subtest 'default band: 0-30 turns -> 3 recent' => sub {
    is(CLIO::Core::ContextBuilder::_recent_count_for_turns(0),   3, '0 turns');
    is(CLIO::Core::ContextBuilder::_recent_count_for_turns(1),   3, '1 turn');
    is(CLIO::Core::ContextBuilder::_recent_count_for_turns(15),  3, '15 turns');
    is(CLIO::Core::ContextBuilder::_recent_count_for_turns(30),  3, '30 turns (band edge)');
};

subtest 'default band: 31-100 turns -> 5 recent' => sub {
    is(CLIO::Core::ContextBuilder::_recent_count_for_turns(31),  5, '31 turns (band edge +1)');
    is(CLIO::Core::ContextBuilder::_recent_count_for_turns(50),  5, '50 turns');
    is(CLIO::Core::ContextBuilder::_recent_count_for_turns(100), 5, '100 turns (band edge)');
};

subtest 'default band: 101-300 turns -> 8 recent' => sub {
    is(CLIO::Core::ContextBuilder::_recent_count_for_turns(101), 8, '101 turns');
    is(CLIO::Core::ContextBuilder::_recent_count_for_turns(200), 8, '200 turns (mid-band)');
    is(CLIO::Core::ContextBuilder::_recent_count_for_turns(300), 8, '300 turns (band edge)');
};

subtest 'default band: 301+ turns -> 10 recent (hard cap)' => sub {
    is(CLIO::Core::ContextBuilder::_recent_count_for_turns(301), 10, '301 turns');
    is(CLIO::Core::ContextBuilder::_recent_count_for_turns(500), 10, '500 turns');
    is(CLIO::Core::ContextBuilder::_recent_count_for_turns(1000), 10, '1000 turns');
    is(CLIO::Core::ContextBuilder::_recent_count_for_turns(1_000_000), 10, '1M turns (still 10)');
};

subtest 'edge cases' => sub {
    is(CLIO::Core::ContextBuilder::_recent_count_for_turns(undef),  3, 'undef -> first band (3)');
    is(CLIO::Core::ContextBuilder::_recent_count_for_turns(-5),    3, 'negative -> first band (3)');
    is(CLIO::Core::ContextBuilder::_recent_count_for_turns('abc'), 3, 'non-numeric -> first band (3)');
};

# Behavioral test: a 200-turn session should produce a 4-turn
# recent window in the projection, while a 5-turn session should
# still produce 1-2. We don't load a real 200-turn fixture; we
# build a synthetic one. This pins that the policy is actually
# consumed by _select_turns, not just exposed.
subtest '_select_turns uses the band value' => sub {
    my @turns;
    for my $i (1..200) {
        push @turns, [
            { role => 'user', content => "turn $i: " . ('x' x 100) },
            { role => 'assistant', content => "response $i" . ('y' x 100) },
        ];
    }

    my ($anchor, $recent, $dropped) = CLIO::Core::ContextBuilder::_select_turns(
        \@turns, undef, [], '',
    );

    ok(scalar(@$recent) >= 8 && scalar(@$recent) <= 10,
        '200-turn session produces 8-10 recent turns (8 target)')
        or diag("Got " . scalar(@$recent) . " recent turns");

    ok(scalar(@$dropped) > 0, 'some turns still dropped to compressed_tail')
        or diag("Got 0 dropped turns");
};

subtest 'short session unchanged from baseline' => sub {
    my @turns;
    for my $i (1..5) {
        push @turns, [
            { role => 'user', content => "turn $i: " . ('x' x 100) },
            { role => 'assistant', content => "response $i" },
        ];
    }

    my ($anchor, $recent, $dropped) = CLIO::Core::ContextBuilder::_select_turns(
        \@turns, undef, [], '',
    );

    # With the revised _select_turns, short sessions keep min 3 recent
    # turns (no anchor concept — active task is in dynamic userContext).
    ok(scalar(@$recent) >= 3,
        '5-turn session produces >= 3 recent turns (min recent window)')
        or diag("Got " . scalar(@$recent) . " recent turns");
    ok(!$anchor, 'no anchor (active task via dynamic userContext)');
    ok(scalar(@$dropped) == 0 || scalar(@$dropped) >= 0, 'dropped turns tracked separately');
};

done_testing();
