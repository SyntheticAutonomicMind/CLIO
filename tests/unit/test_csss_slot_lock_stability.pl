#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

# Regression test for CSSS (Cache-Stable Summary Slot) behavior across
# multiple trim cycles.
#
# Earlier versions locked the slot size to MIN_CSSS_SLOT_TOKENS via
# padding. The padding was thousands of x characters inside the
# <thread_summary> block and was visible to the model as a massive
# artifact (the user-reported bug).
#
# Current behavior (2026-08-27 fix):
#   - Summary grows organically with dropped content (no padding).
#   - Summary is bounded above by MAX_CSSS_SLOT_TOKENS via proactive
#     growth (slot expands by 1.5x when dropped content exceeds 1.5x
#     current slot, capped at MAX).
#   - MIN_CSSS_SLOT_TOKENS is no longer a padding floor; it remains
#     only as a resume fast-path gate (see WorkflowOrchestrator).
#   - YaRN.pm:_fit_summary_to_target is a CEILING, not a target.
#
# These tests verify:
#   - First-trim summary size is bounded by MAX (was: >= MIN).
#   - Across 5 trims, summary size stays under MAX (organic growth,
#     never padded to fill).
#   - When dropped content vastly exceeds slot, summary grows up to
#     but does not exceed MAX.
#   - No 'csss:padding' marker ever appears in summaries.

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";

use Test::More;
use CLIO::Core::API::MessageValidator qw(validate_and_truncate);
use CLIO::Core::Defaults qw(MAX_CSSS_SLOT_TOKENS);

# Check that no summary message contains the csss:padding marker.
sub no_padding_in_result {
    my ($result) = @_;
    for my $m (@$result) {
        if (($m->{role} // '') eq 'system' && ($m->{content} // '') =~ /<thread_summary>/) {
            return 0 if $m->{content} =~ /csss:padding/;
        }
    }
    return 1;
}

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

# First-trim summary is bounded above by MAX (no padding floor).
subtest 'first trim produces summary <= MAX ceiling (no padding inflation)' => sub {
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
    ok($tokens <= MAX_CSSS_SLOT_TOKENS + 1000,
        "first trim produces summary <= MAX ceiling (got $tokens, max=${\ MAX_CSSS_SLOT_TOKENS })");
    ok(no_padding_in_result($result),
        "no csss:padding marker in first-trim summary (the bug)");
};

# Across 5 trims, summary grows organically and stays bounded by MAX.
subtest 'summary stays within 0..MAX across 5 trims (organic growth, no padding)' => sub {
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
        ok($tokens <= MAX_CSSS_SLOT_TOKENS + 1000,
            "iter $iter: summary tokens <= MAX+buffer (got $tokens)");
        ok(no_padding_in_result($result),
            "iter $iter: no csss:padding in summary");
    }

    # Summaries grow with dropped content, so they don't have to be
    # constant across iterations. What matters is the ceiling is honored.
    my $min = (sort { $a <=> $b } @slack)[0];
    my $max = (sort { $b <=> $a } @slack)[0];
    my $drift = $max > 0 ? sprintf("%.1f", 100 * ($max - $min) / $max) : 0;
    cmp_ok($drift, '<=', 50,
        "CSSS slot drift across 5 trims <= 50% (got $drift%, range $min..$max)");
};

# When dropped content vastly exceeds current slot, proactive growth
# pushes the ceiling toward MAX. The summary should grow but stay
# under MAX (no padding inflation past the ceiling).
subtest 'summary grows toward MAX ceiling when dropped content exceeds 1.5x slot, no padding' => sub {
    # Build a HUGE session that forces massive drops. The summary
    # should grow toward MAX_CSSS_SLOT_TOKENS.
    my @msgs = (
        { role => 'system', content => 'CLIO System Prompt ' . ('S' x 6000) },
        { role => 'user', content => 'initial task: study the codebase' },
    );
    for my $i (1..30) {
        my $tc = "tc_huge_$i";
        push @msgs, {
            role => 'user',
            content => "Subtask $i: refactor the optimizer " . ('detailed instructions for the refactor ' x 50),
        };
        push @msgs, {
            role => 'assistant',
            content => "Reasoning $i " . ('reasoning about the optimization strategy ' x 50),
            tool_calls => [{ id => $tc, type => 'function',
                            function => { name => 'foo', arguments => '{}' } }],
        };
        push @msgs, {
            role => 'tool',
            tool_call_id => $tc,
            content => "Result $i " . ('lines of code that were modified ' x 100),
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
    # With 30 dropped units of substantive content each, the summary
    # should grow toward MAX. The ceiling is enforced via proactive
    # growth (1.5x slot bumps), capped at MAX_CSSS_SLOT_TOKENS.
    ok($tokens <= MAX_CSSS_SLOT_TOKENS + 1000,
        "summary tokens <= MAX ceiling (got $tokens)");
    ok($tokens > 100,
        "summary has substantive content (got $tokens tokens, was likely trimmed)");
    ok(no_padding_in_result($result),
        "no csss:padding marker in summary even with massive drop (the bug)");
};

done_testing();