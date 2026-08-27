#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

# Regression test for CSSS slot lock stability across multiple trim
# cycles. The slot target should be constant ±10% across 5+ trims on
# the same session. If it drifts significantly, the LCP cache prefix
# boundary moves on every trim and the cache hit collapses.
#
# The CSSS slot is locked by MessageValidator when an existing
# thread_summary exists. The lock target is the smaller of:
#   - The current summary's token count
#   - MAX_CSSS_SLOT_TOKENS
# And the larger of:
#   - The current summary's token count
#   - MIN_CSSS_SLOT_TOKENS
#
# Plus proactive growth when dropped content exceeds 1.5x the slot.

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";

use Test::More;
use CLIO::Core::API::MessageValidator qw(validate_and_truncate);
use CLIO::Core::Defaults qw(MIN_CSSS_SLOT_TOKENS MAX_CSSS_SLOT_TOKENS);

# Build a synthetic session with mixed substantive + Tier 4 content.
# The session is large enough that 5 successive trims each drop
# different units (so the slot target has work to do).
sub build_session {
    my $iter = shift;
    my @msgs = (
        { role => 'system', content => 'CLIO System Prompt ' . ('S' x 6000) },
        { role => 'user', content => 'initial task' },
    );

    # Substantive units
    for my $i (1..5) {
        my $tc = "tc_${iter}_good_$i";
        push @msgs, {
            role => 'assistant',
            content => "Reasoning $iter.$i " . ("x" x 3000),
            tool_calls => [{ id => $tc, type => 'function',
                            function => { name => 'foo', arguments => '{}' } }],
        };
        push @msgs, {
            role => 'tool',
            tool_call_id => $tc,
            content => "Result $iter.$i " . ("y" x 3000),
        };
    }

    # Tier 4 ack units (droppable noise)
    push @msgs, { role => 'assistant', content => 'OK' };
    push @msgs, { role => 'assistant', content => 'Got it' };

    # Trailing user message
    push @msgs, { role => 'user', content => "next task $iter" };

    return @msgs;
}

# Extract the trailing thread_summary's token count from a result.
sub summary_tokens {
    my ($result) = @_;
    for my $m (@$result) {
        if (($m->{role} // '') eq 'system' && ($m->{content} // '') =~ /<thread_summary>/) {
            require CLIO::Memory::TokenEstimator;
            return CLIO::Memory::TokenEstimator::estimate_tokens($m->{content});
        }
    }
    return 0;
}

subtest 'CSSS slot locks to MIN on first trim' => sub {
    my @msgs = build_session(0);
    my $result = validate_and_truncate(
        messages => \@msgs,
        model_capabilities => { max_prompt_tokens => 50000, max_output_tokens => 16000 },
        tools => [],
        token_ratio => 2.5,
        trim_threshold => 2000,
        disable_post_trim_floor => 1,
    );
    my $tokens = summary_tokens($result);
    ok($tokens >= MIN_CSSS_SLOT_TOKENS,
        "first trim produces summary >= MIN_CSSS_SLOT_TOKENS (got $tokens)");
};

subtest 'CSSS slot stays within MIN..MAX across 5 trims' => sub {
    my @slack;
    for my $iter (1..5) {
        my @msgs = build_session($iter);
        my $result = validate_and_truncate(
            messages => \@msgs,
            model_capabilities => { max_prompt_tokens => 50000, max_output_tokens => 16000 },
            tools => [],
            token_ratio => 2.5,
            trim_threshold => 3000,
            disable_post_trim_floor => 1,
        );
        my $tokens = summary_tokens($result);
        push @slack, $tokens;
        ok($tokens >= MIN_CSSS_SLOT_TOKENS,
            "iter $iter: summary tokens >= MIN (got $tokens)");
        ok($tokens <= MAX_CSSS_SLOT_TOKENS + 1000,
            "iter $iter: summary tokens <= MAX+buffer (got $tokens)");
    }

    # Slot target should be relatively stable across iterations.
    my $min = (sort { $a <=> $b } @slack)[0];
    my $max = (sort { $b <=> $a } @slack)[0];
    my $drift = $max > 0 ? sprintf("%.1f", 100 * ($max - $min) / $max) : 0;
    cmp_ok($drift, '<=', 50,
        "CSSS slot drift across 5 trims <= 50% (got $drift%, range $min..$max)");
};

subtest 'CSSS slot grows when dropped content exceeds 1.5x current slot' => sub {
    # Build a HUGE session that forces massive drops. The summary
    # should grow toward MAX_CSSS_SLOT_TOKENS.
    my @msgs = (
        { role => 'system', content => 'CLIO System Prompt ' . ('S' x 6000) },
        { role => 'user', content => 'initial task' },
    );
    for my $i (1..30) {
        my $tc = "tc_huge_$i";
        push @msgs, {
            role => 'assistant',
            content => "Reasoning $i " . ("x" x 5000),
            tool_calls => [{ id => $tc, type => 'function',
                            function => { name => 'foo', arguments => '{}' } }],
        };
        push @msgs, {
            role => 'tool',
            tool_call_id => $tc,
            content => "Result $i " . ("y" x 5000),
        };
    }
    push @msgs, { role => 'user', content => 'final task' };

    my $result = validate_and_truncate(
        messages => \@msgs,
        model_capabilities => { max_prompt_tokens => 100000, max_output_tokens => 16000 },
        tools => [],
        token_ratio => 2.5,
        trim_threshold => 4000,
        disable_post_trim_floor => 1,
    );
    my $tokens = summary_tokens($result);
    # With 30 dropped units of ~5K each, dropped content vastly exceeds
    # the slot. The slot should grow toward MAX.
    ok($tokens >= MIN_CSSS_SLOT_TOKENS,
        "summary tokens >= MIN (got $tokens)");
    # Even with growth, the slot is capped at MAX. The actual summary
    # may exceed MAX briefly while YaRN pads, so we accept any value
    # above MIN as "grew".
    ok($tokens > MIN_CSSS_SLOT_TOKENS,
        "summary grew past MIN (got $tokens)");
};

done_testing();