#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Test: the recent window is token-budgeted, not turn-counted.
#
# The window used to be a band on the number of turns (3/5/8/10). That
# is blind to turn size: one agentic "turn" can be hundreds of tool
# calls, so a count either keeps far more than the budget allows or
# discards hundreds of thousands of tokens while the window is mostly
# empty.
#
# The contract now:
#   - no usable budget        -> keep every turn (the proactive trim
#                                still enforces the limit)
#   - turns fit within fill   -> keep every turn
#   - turns exceed fill       -> drop from the oldest end until below
#                                the low watermark (hysteresis)
#   - the last RECENT_MIN_TURNS always survive

use strict;
use warnings;
use utf8;
use lib './lib';

use Test::More;
use CLIO::Core::ContextBuilder;

# Helper: N turns of a fixed size, for budget arithmetic.
sub make_sized_turns {
    my ($count, $chars) = @_;
    my @turns;
    for my $i (1 .. $count) {
        push @turns, [
            { role => 'user',      content => "turn $i: " . ('x' x $chars) },
            { role => 'assistant', content => "response $i: " . ('y' x $chars) },
        ];
    }
    return \@turns;
}

subtest 'no budget keeps every turn' => sub {
    my $turns = make_sized_turns(40, 200);
    is(CLIO::Core::ContextBuilder::_recent_count_for_budget($turns, {}),
        40, 'no budget information -> keep all');
    is(CLIO::Core::ContextBuilder::_recent_count_for_budget($turns, { prompt_budget => 0 }),
        40, 'zero budget -> keep all');
};

subtest 'turns that fit the budget all stay' => sub {
    my $turns = make_sized_turns(5, 40);
    is(CLIO::Core::ContextBuilder::_recent_count_for_budget(
            $turns, { prompt_budget => 100000 }),
        5, 'small session under the fill threshold keeps all turns');
};

subtest 'over the fill threshold drops to the low watermark' => sub {
    my $turns = make_sized_turns(200, 400);
    my $keep = CLIO::Core::ContextBuilder::_recent_count_for_budget(
        $turns, { prompt_budget => 20000 });

    cmp_ok($keep, '<', 200, 'window shrank');
    cmp_ok($keep, '>=', $CLIO::Core::ContextBuilder::RECENT_MIN_TURNS, 'min turns floor honored');

    # The kept turns must fit under the low watermark.
    my $kept_cost = 0;
    $kept_cost += CLIO::Memory::TokenEstimator::estimate_messages_tokens($_)
        for @$turns[ -$keep .. -1 ];
    my $low = int(20000 * $CLIO::Core::ContextBuilder::RECENT_LOW_FRACTION);
    cmp_ok($kept_cost, '<=', $low, "kept turns ($kept_cost) fit the low watermark ($low)");
};

subtest 'min turns survive an impossible budget' => sub {
    my $turns = make_sized_turns(10, 4000);
    my $keep = CLIO::Core::ContextBuilder::_recent_count_for_budget(
        $turns, { prompt_budget => 2000 });
    is($keep, $CLIO::Core::ContextBuilder::RECENT_MIN_TURNS,
        'min turns kept even when they exceed the budget');
};

subtest 'a larger budget keeps at least as many turns' => sub {
    my $turns = make_sized_turns(100, 400);
    my $prev = 0;
    for my $budget (5000, 10000, 20000, 40000, 200000) {
        my $keep = CLIO::Core::ContextBuilder::_recent_count_for_budget(
            $turns, { prompt_budget => $budget });
        cmp_ok($keep, '>=', $prev, "budget $budget keeps >= $prev turns");
        $prev = $keep;
    }
    is($prev, 100, 'large enough budget keeps every turn');
};

subtest '_select_turns consumes the budget' => sub {
    my $turns = make_sized_turns(200, 400);
    my ($anchor, $recent, $dropped) = CLIO::Core::ContextBuilder::_select_turns(
        $turns, undef, [], '', { prompt_budget => 20000 },
    );

    cmp_ok(scalar(@$recent), '<', 200, 'recent window bounded by the budget');
    cmp_ok(scalar(@$dropped), '>', 0, 'dropped turns tracked for compression');
    is(scalar(@$recent) + scalar(@$dropped), 200, 'every turn is either kept or dropped');
};

subtest 'no budget means no projection-level drop' => sub {
    my $turns = make_sized_turns(200, 400);
    my ($anchor, $recent, $dropped) = CLIO::Core::ContextBuilder::_select_turns(
        $turns, undef, [], '',
    );
    is(scalar(@$recent), 200, 'all turns kept without a budget');
    is(scalar(@$dropped), 0, 'nothing dropped without a budget');
};

# ===========================================================================
# Tests for _select_turns: trailing + mid-window incomplete turn handling
# (Bug #2 regression: single 'if' only popped the last incomplete turn;
#      prior orphaned user messages were lost and mid-window incomplete
#      turns could create consecutive user messages in the projection.)
# ===========================================================================

# Helper: make a complete (user + assistant + tool) turn.
sub make_turn {
    my ($i) = @_;
    return [
        { role => 'user',    content => "turn $i question" },
        { role => 'assistant', content => "turn $i answer" },
        { role => 'tool', content => "turn $i result", tool_call_id => "call_$i" },
    ];
}

# Helper: make an incomplete turn (user message only, no assistant/tool).
sub make_incomplete_turn {
    my ($label) = @_;
    return [
        { role => 'user', content => $label // 'orphan user message' },
    ];
}

subtest 'multiple trailing incomplete turns all popped' => sub {
    # Scenario: session resume left two orphan user messages at the end
    # (user_90 and user_91) plus the current turn (user_92).
    # The old code only popped user_92 (the last). With the fix, all
    # three are popped, user_92 (current) is discarded, and user_90
    # + user_91 are moved to the dropped set for compression.
    my @turns = (
        make_turn(1),
        make_turn(2),
        make_turn(3),
        make_incomplete_turn('user_90 orphan'),
        make_incomplete_turn('user_91 orphan'),
        make_incomplete_turn('current user input'),
    );

    my ($anchor, $recent, $dropped) = CLIO::Core::ContextBuilder::_select_turns(
        \@turns, undef, [], '',
    );

    # Recent should be the last complete turns (not the incomplete ones)
    my $recent_count = scalar(@$recent);
    ok($recent_count >= 3, "Recent window has >= 3 complete turns (got $recent_count)")
        or diag("Got $recent_count recent turns");

    # No incomplete turn in the recent window
    for my $turn (@$recent) {
        for my $msg (@$turn) {
            ok(($msg->{content} // '') ne 'user_90 orphan', "user_90 not in recent");
            ok(($msg->{content} // '') ne 'user_91 orphan', "user_91 not in recent");
            ok(($msg->{content} // '') ne 'current user input', "current input not in recent");
        }
    }

    # Dropped should contain the prior incomplete turns
    my $dropped_labels = join('|',
        map { $_->[0]{content} // '' } @$dropped
    );
    like($dropped_labels, qr/user_90 orphan/, "user_90 moved to dropped set");
    like($dropped_labels, qr/user_91 orphan/, "user_91 moved to dropped set");
    unlike($dropped_labels, qr/current user input/, "current turn NOT in dropped (discarded)");
};

subtest 'single trailing incomplete turn still works' => sub {
    # Backwards-compatibility: the old single-pop behavior must still work.
    my @turns = (
        make_turn(1),
        make_turn(2),
        make_incomplete_turn('current input'),
    );

    my ($anchor, $recent, $dropped) = CLIO::Core::ContextBuilder::_select_turns(
        \@turns, undef, [], '',
    );

    ok(scalar(@$recent) >= 2, "Recent window has >= 2 turns for 3-turn session with 1 incomplete");
    unlike((join '|', map { $_->[0]{content} // '' } @$dropped), qr/current input/, "current turn discarded, not in dropped");
};

subtest 'current turn alone (no complete turns) returns empty recent' => sub {
    my @turns = (
        make_incomplete_turn('just the current input'),
    );

    my ($anchor, $recent, $dropped) = CLIO::Core::ContextBuilder::_select_turns(
        \@turns, undef, [], '',
    );

    is(scalar(@$recent), 0, "No recent turns when only current turn exists");
    is(scalar(@$dropped), 0, "No dropped turns when only current turn exists");
};

subtest 'mid-window incomplete turn moved to dropped' => sub {
    # An incomplete turn in the MIDDLE (from a prior interrupted session
    # that was resumed with new work). It must be moved to the dropped
    # set rather than appearing in the recent window and creating
    # consecutive user messages.
    my @turns = (
        make_turn(1),
        make_turn(2),
        make_incomplete_turn('orphan mid-window'),
        make_turn(3),
        make_turn(4),
    );

    # No budget is passed, so every complete turn is in the recent
    # window and the orphaned turn necessarily falls inside it.
    @turns = (
        make_turn(1), make_turn(2), make_turn(3),
        make_turn(4), make_turn(5), make_turn(6),
        make_incomplete_turn('orphan mid-window'),
        make_turn(7), make_turn(8), make_turn(9),
    );

    my ($anchor, $recent, $dropped) = CLIO::Core::ContextBuilder::_select_turns(
        \@turns, undef, [], '',
    );

    # Check that the orphan is not in the recent window
    my $recent_contents = join('|',
        map { $_->[0]{content} // '...' } @$recent
    );
    unlike($recent_contents, qr/orphan mid-window/, "Mid-window incomplete turn moved out of recent");

    # Check that the orphan IS in the dropped set
    my $dropped_contents = join('|',
        map { $_->[0]{content} // '...' } @$dropped
    );
    like($dropped_contents, qr/orphan mid-window/, "Mid-window incomplete turn moved to dropped set");
};

done_testing();
