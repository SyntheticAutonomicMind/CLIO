#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test: a triggered proactive trim lands on the trim target,
# not on the effective limit.
#
# The tail walk drops whole messages from the oldest end, so the provider's
# cached prefix ends at the first dropped message and the next request
# re-prefills every surviving message. Trimming only until the array fits
# spends a full re-prefill to reclaim almost nothing, and the conversation
# re-triggers a few turns later. Measured on a real session: each trim
# reclaimed a median 1,383 tokens (0.5% of the window), fired every 3
# turns, and 82 such trims cost 6.3 hours of re-prefill.
#
# Two properties are asserted:
#   1. An array that is over the target but under the effective limit is
#      not trimmed at all - the trigger is unchanged.
#   2. A triggered trim reaches the target (CONTEXT_TRIM_TARGET of the
#      effective limit), so the next trim is many turns away.

use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/../../lib";

use Test::More;
use CLIO::Core::Defaults ();
use CLIO::Memory::TokenEstimator ();
use CLIO::Core::API::MessageValidator qw(validate_and_truncate);

my $RATIO = 4.0;
my $CAPS = {
    max_context_window_tokens => 128000,
    max_output_tokens         => 16000,
};

my $budget = CLIO::Memory::TokenEstimator::compute_prompt_budget($CAPS);
my $target = int($budget * CLIO::Core::Defaults::CONTEXT_TRIM_TARGET());

my $BODY = 'word ' x 800;    # 4000 characters

sub _estimate {
    my ($messages) = @_;
    return CLIO::Core::API::MessageValidator::_estimate_tokens($messages, $RATIO);
}

# One exchange costs this much. Interpolated into the message so every
# message is the same size and the arithmetic below is exact.
my $turn_tokens = _estimate([{ role => 'assistant', content => $BODY }]);

sub _build {
    my ($turns) = @_;
    my @messages = ({ role => 'user', content => 'Original task anchor.' });
    for my $i (1 .. $turns) {
        push @messages, {
            role    => ($i % 2) ? 'assistant' : 'user',
            content => $BODY,
        };
    }
    push @messages, { role => 'user', content => 'Current turn input.' };
    return \@messages;
}

sub _trim {
    my ($messages, $caps) = @_;
    $caps ||= $CAPS;
    return validate_and_truncate(
        messages           => $messages,
        model_capabilities => $caps,
        tools              => [],
        token_ratio        => $RATIO,
        debug              => 0,
        model              => 'test-model',
    );
}

diag("prompt budget $budget, trim target $target, ${turn_tokens} tokens per turn");

# The walk decides its cut on the messages it keeps, then folds the
# <thread_summary> of what it dropped into the last user message. That
# summary is added after the cut, so the finished array can exceed the
# target by its size. It is bounded by a small share of the window, and
# the headroom the target buys absorbs it.
my $summary_allowance = int($budget * 0.05);

# ── 1. Well under the target: nothing is dropped ────────────────────────
{
    my $messages = _build(40);
    my $trimmed  = _trim($messages);
    is(scalar(@$trimmed), scalar(@$messages),
        'conversation under the target is returned untouched');
}

# ── 2. Over the target, under the limit: nothing is dropped ─────────────
# This is the case the old "trim to fit" policy left alone and the new
# policy must also leave alone. The target is a landing point after a
# trim, not a trigger.
{
    my $turns = int(($target + ($budget - $target) / 2) / $turn_tokens);
    my $messages = _build($turns);
    my $before = _estimate($messages);
    my $trimmed = _trim($messages);

    ok($before > $target && $before <= $budget,
        "fixture sits between the target and the limit ($before)");
    is(scalar(@$trimmed), scalar(@$messages),
        'no trim while the array still fits the effective limit');
}

# ── 3. Over the limit: the trim lands on the target ─────────────────────
{
    my $messages = _build(int($budget * 1.6 / $turn_tokens));
    my $before   = _estimate($messages);
    my $trimmed  = _trim($messages);
    my $after    = _estimate($trimmed);

    ok($before > $budget, "fixture exceeds the effective limit ($before > $budget)");
    cmp_ok($after, '<=', $target + $summary_allowance,
        "trim reached the target ($after <= $target + $summary_allowance)");
    cmp_ok($after, '>', $target - (2 * $turn_tokens),
        'trim did not drop far past the target');

    # The regression this guards: trimming only until the array fits left
    # the result just under the limit, so a few turns of growth triggered
    # the next trim.
    cmp_ok($after, '<', $budget,
        'result is below the limit, not merely at it');

    is($trimmed->[0]{role}, 'user', 'first message is still the task anchor');
    is($trimmed->[0]{content}, 'Original task anchor.',
        'first user message survives the trim');
    is($trimmed->[-1]{role}, 'user', 'last message is still the current turn');
    like($trimmed->[-1]{content}, qr/Current turn input\./,
        'current turn input survives the trim');

    ok(scalar(@$trimmed) < scalar(@$messages),
        'messages were actually dropped');
}

# ── 4. A larger context window trims proportionally further down ────────
# The target is a fraction of the budget, so a 256K model keeps far more
# after a trim than a 128K model - the point of paying for the window.
{
    my $big_caps = {
        max_context_window_tokens => 262144,
        max_output_tokens         => 16384,
    };
    my $big_budget = CLIO::Memory::TokenEstimator::compute_prompt_budget($big_caps);
    my $big_target = int($big_budget * CLIO::Core::Defaults::CONTEXT_TRIM_TARGET());

    my $messages = _build(int($big_budget * 1.2 / $turn_tokens));
    my $trimmed  = validate_and_truncate(
        messages           => $messages,
        model_capabilities => $big_caps,
        tools              => [],
        token_ratio        => $RATIO,
        debug              => 0,
        model              => 'test-model',
    );
    my $after = _estimate($trimmed);

    my $big_allowance = int($big_budget * 0.05);
    cmp_ok($after, '<=', $big_target + $big_allowance,
        "256K model trims to its own target ($after <= $big_target + $big_allowance)");
    cmp_ok($after, '>', 2 * $target,
        '256K model retains more context than a 128K model after trimming');
}

# ── 5. Pinned content larger than the target still trims ────────────────
# Hysteresis needs something to drop. When the pinned messages (system
# prompt, task anchor, current input) exceed the target on their own, the
# walk has to fall back to the limit instead of keeping everything.
{
    my $tiny_caps = {
        max_context_window_tokens => 2048,
        max_output_tokens         => 256,
    };
    my $tiny_budget = CLIO::Memory::TokenEstimator::compute_prompt_budget($tiny_caps);
    my $tiny_target = int($tiny_budget * CLIO::Core::Defaults::CONTEXT_TRIM_TARGET());

    my @messages = ({ role => 'system', content => 'S' . ('x' x 2999) });
    push @messages, { role => 'user', content => 'Original task anchor.' };
    for my $i (1 .. 20) {
        push @messages, { role => ($i % 2) ? 'assistant' : 'user', content => $BODY };
    }
    push @messages, { role => 'user', content => 'Current turn input.' };

    my $trimmed = _trim(\@messages, $tiny_caps);

    ok(_estimate([$messages[0], $messages[1], $messages[-1]]) > $tiny_target,
        'fixture: pinned messages exceed the target on their own');
    ok(scalar(@$trimmed) < scalar(@messages),
        'trim still drops messages when pinned content exceeds the target');
    ok((grep { ($_->{content} // '') eq 'Original task anchor.' } @$trimmed),
        'task anchor survives the fallback trim');
    like($trimmed->[-1]{content}, qr/Current turn input\./,
        'current turn input survives the fallback trim');
}

done_testing();
