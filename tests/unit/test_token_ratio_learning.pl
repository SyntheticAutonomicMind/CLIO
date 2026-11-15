#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test: the learned chars/token ratio tracks the model and is
# not clamped below what the model actually produces.
#
# Measured on a local model: 5.54 characters per token on the margin. The
# old ceiling of 4.0 meant the estimate was always ~39% high, so the trim
# fired at 58% of the context window and the provider re-prefilled the
# conversation every few turns.
#
# Also asserts that tool definitions are part of the measurement: they are
# counted in prompt_tokens but are not part of the messages array, so
# leaving them out reads the ratio low by the tool share of the prompt.

use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/../../lib";

use Test::More;
use CLIO::Core::Defaults ();
use CLIO::Memory::TokenEstimator ();

sub set_learned_ratio { CLIO::Memory::TokenEstimator::set_learned_ratio(@_) }
sub get_effective_ratio { CLIO::Memory::TokenEstimator::get_effective_ratio() }
sub estimate_tokens { CLIO::Memory::TokenEstimator::estimate_tokens(@_) }

# ── Bounds ──────────────────────────────────────────────────────────────
set_learned_ratio(5.54);
is(get_effective_ratio(), 5.54, 'a measured ratio above 5.0 survives');

set_learned_ratio(9.5);
is(get_effective_ratio(), 9.5, 'a measured ratio above 9.5 survives');

set_learned_ratio(50);
is(get_effective_ratio(), CLIO::Core::Defaults::TOKEN_RATIO_MAX(),
    'an implausible ratio is clamped to the ceiling');

set_learned_ratio(0.2);
is(get_effective_ratio(), CLIO::Core::Defaults::TOKEN_RATIO_MIN(),
    'an implausible ratio is clamped to the floor');

set_learned_ratio(4.0);
set_learned_ratio(-1);
is(get_effective_ratio(), 4.0,
    'a negative ratio is ignored, leaving the previous value');

# ── Estimation follows the learned ratio ────────────────────────────────
{
    set_learned_ratio(5.54);
    is(estimate_tokens('x' x 5540), 1000, '5540 characters at 5.54 is 1000 tokens');

    set_learned_ratio(4.0);
    is(estimate_tokens('x' x 5540), 1385, 'the same text at 4.0 estimates 39% higher');
}

# ── APIManager learns from real usage ───────────────────────────────────
{
    require CLIO::Core::APIManager;

    # A prompt of 9,000 characters of messages plus 10,000 characters of
    # tool definitions, measured by the provider at 3,430 tokens. The true
    # ratio is (9000 + 10000) / 3430 = 5.54.
    my @messages = ({ role => 'user', content => 'x' x 9000 });
    my $usage = { prompt_tokens => 3430 };

    my $manager = bless {
        learned_token_ratio => 2.5,
        _request_tool_chars => 10000,
        debug               => 0,
    }, 'CLIO::Core::APIManager';

    my $ratio = CLIO::Core::APIManager::_learn_from_api_response($manager, $usage, \@messages);

    cmp_ok($ratio, '>', 4.0,
        "one large observation moves the ratio past the old ceiling ($ratio)");
    is($manager->{learned_token_ratio}, $ratio,
        'the manager keeps the learned ratio');
    is(get_effective_ratio(), $ratio,
        'the learned ratio reaches the shared estimator');

    # Without the tool characters the same response reads 2.62 chars/token,
    # which pulls the learned ratio down instead of up.
    my $without_tools = bless {
        learned_token_ratio => 2.5,
        _request_tool_chars => 0,
        debug               => 0,
    }, 'CLIO::Core::APIManager';
    my $low = CLIO::Core::APIManager::_learn_from_api_response($without_tools, $usage, \@messages);
    cmp_ok($low, '<', $ratio,
        "tool definitions are counted in the ratio ($low < $ratio)");

    # Repeated identical observations converge on the measured value.
    for (1 .. 10) {
        $ratio = CLIO::Core::APIManager::_learn_from_api_response($manager, $usage, \@messages);
    }
    cmp_ok(abs($ratio - 5.54), '<', 0.05,
        "repeated observations converge on the measured ratio ($ratio)");
}

# ── Small prompts barely move the ratio ─────────────────────────────────
{
    # Both observations measure 5.54 chars/token, so any movement comes
    # from the prompt size alone. A small prompt is a weak sample.
    my $measure = sub {
        my ($tokens) = @_;
        my $manager = bless {
            learned_token_ratio => 4.0,
            _request_tool_chars => 0,
            debug               => 0,
        }, 'CLIO::Core::APIManager';
        my @messages = ({ role => 'user', content => 'x' x int($tokens * 5.54) });
        my $ratio = CLIO::Core::APIManager::_learn_from_api_response(
            $manager, { prompt_tokens => $tokens }, \@messages,
        );
        return abs($ratio - 4.0);
    };

    my $small = $measure->(200);
    my $large = $measure->(20000);

    cmp_ok($large, '>', 1.0, "a 20K-token observation moves the ratio ($large)");
    cmp_ok($small * 5, '<', $large,
        "a 200-token observation moves it far less ($small vs $large)");
}

done_testing();
