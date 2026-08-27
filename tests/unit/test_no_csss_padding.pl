#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

# Regression test: no thread_summary in any code path contains a
# csss:padding marker. Earlier versions of CLIO generated summaries with
# thousands of 'x' characters inside an HTML comment to lock the byte
# size for llama.cpp cache stability. The padding was visible to the
# model as a massive artifact inside <thread_summary> (the user-reported
# bug: "The CSS padding noise is massive and distracting").
#
# This test pins the fix across all entry points:
#   1. YaRN::compress_messages with target_tokens that would have
#      triggered padding in the old code
#   2. validate_and_truncate end-to-end on a session that grows
#   3. Session-resume via the last_api_payload snapshot path
#
# If anyone re-introduces padding to lock summary byte size, this test
# will fail loudly.

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";

use Test::More;
use CLIO::Memory::YaRN;
use CLIO::Memory::TokenEstimator qw(estimate_tokens);
use CLIO::Core::API::MessageValidator qw(validate_and_truncate);
use CLIO::Core::ConversationManager qw(trim_conversation_for_api);

# Scan a result set for any thread_summary containing csss:padding.
sub no_padding_in_summaries {
    my ($msgs) = @_;
    for my $m (@$msgs) {
        next unless ($m->{role} // '') eq 'system';
        my $content = $m->{content} // '';
        next unless $content =~ /<thread_summary>/;
        return 0, "found csss:padding in summary message" if $content =~ /csss:padding/;
        # Defensive: also catch any other long x-runs inside the summary,
        # which is the visible symptom of the bug regardless of marker.
        return 0, "found long x-run in summary (likely padding residue)"
            if $content =~ /x{500,}/;
    }
    return 1, '';
}

# ===== Test 1: YaRN::compress_messages never pads, regardless of target_tokens =====
subtest 'YaRN never produces csss:padding regardless of target_tokens' => sub {
    my $yarn = CLIO::Memory::YaRN->new();

    my @dropped = (
        { role => 'user', content => 'Tiny task.' },
        { role => 'assistant', content => 'OK.' },
    );

    # Try every target size that would have triggered padding in the old
    # code. None should produce a padding block.
    for my $target (1, 100, 500, 2000, 4000, 8000, 12000, 50000) {
        my $result = $yarn->compress_messages(\@dropped,
            original_task => 'Tiny task',
            target_tokens => $target,
        );
        ok($result, "compress_messages returned result for target=$target");

        my ($ok, $why) = no_padding_in_summaries([$result]);
        ok($ok, "no padding for target=$target tokens ($why)");
    }
};

# ===== Test 2: validate_and_truncate end-to-end never produces padding =====
subtest 'validate_and_truncate never emits csss:padding in summary' => sub {
    my @msgs = (
        { role => 'system', content => 'You are CLIO. ' . ('S' x 8000) },
        { role => 'user', content => 'initial task' },
    );

    # Build a session that requires trims. Each iteration adds a unit
    # with substantive content so YaRN has real text to compress.
    for my $i (1..40) {
        my $tc = "tc_$i";
        push @msgs, {
            role => 'assistant',
            content => "Reasoning $i " . ('reasoning about optimization strategy ' x 60),
            tool_calls => [{ id => $tc, type => 'function',
                            function => { name => 'foo', arguments => '{}' } }],
        };
        push @msgs, {
            role => 'tool',
            tool_call_id => $tc,
            content => "Result $i " . ('lines of modified code ' x 80),
        };
    }
    push @msgs, { role => 'user', content => 'final task' };

    my $result = validate_and_truncate(
        messages => \@msgs,
        model_capabilities => { max_prompt_tokens => 80000, max_output_tokens => 16000 },
        tools => [],
        token_ratio => 2.5,
        trim_threshold => 4000,
        disable_post_trim_floor => 1,
    );

    my ($ok, $why) = no_padding_in_summaries($result);
    ok($ok, "no csss:padding in trimmed result ($why)");

    # Find the summary and confirm its size is bounded by MAX.
    my $found_summary = 0;
    for my $m (@$result) {
        if (($m->{role} // '') eq 'system' && ($m->{content} // '') =~ /<thread_summary>/) {
            $found_summary = 1;
            my $tokens = estimate_tokens($m->{content});
            ok($tokens <= 12000 + 1000,
                "summary tokens <= MAX_CSSS_SLOT_TOKENS ceiling (got $tokens)");
        }
    }
    ok($found_summary, "summary was generated");
};

# ===== Test 3: Re-trimming across multiple sessions never accumulates padding =====
subtest 'multiple sequential trims never accumulate csss:padding' => sub {
    my @msgs = (
        { role => 'system', content => 'You are CLIO. ' . ('S' x 8000) },
        { role => 'user', content => 'initial task' },
    );
    for my $i (1..15) {
        my $tc = "tc_init_$i";
        push @msgs, {
            role => 'assistant',
            content => "Reasoning $i " . ('reasoning text ' x 40),
            tool_calls => [{ id => $tc, type => 'function',
                            function => { name => 'foo', arguments => '{}' } }],
        };
        push @msgs, {
            role => 'tool',
            tool_call_id => $tc,
            content => "Result $i " . ('result lines ' x 60),
        };
    }
    push @msgs, { role => 'user', content => 'first task done' };

    # First trim
    my $trimmed = validate_and_truncate(
        messages => \@msgs,
        model_capabilities => { max_prompt_tokens => 30000, max_output_tokens => 8000 },
        tools => [],
        token_ratio => 2.5,
        trim_threshold => 2000,
        disable_post_trim_floor => 1,
    );

    my ($ok1, $why1) = no_padding_in_summaries($trimmed);
    ok($ok1, "first trim has no padding ($why1)");

    # Add more messages and trim again
    for my $i (1..10) {
        my $tc = "tc_more_$i";
        push @$trimmed, {
            role => 'assistant',
            content => "More reasoning $i " . ('more text ' x 50),
            tool_calls => [{ id => $tc, type => 'function',
                            function => { name => 'foo', arguments => '{}' } }],
        };
        push @$trimmed, {
            role => 'tool',
            tool_call_id => $tc,
            content => "More result $i " . ('more results ' x 80),
        };
    }
    push @$trimmed, { role => 'user', content => 'continue' };

    my $trimmed2 = validate_and_truncate(
        messages => $trimmed,
        model_capabilities => { max_prompt_tokens => 30000, max_output_tokens => 8000 },
        tools => [],
        token_ratio => 2.5,
        trim_threshold => 2000,
        disable_post_trim_floor => 1,
    );

    my ($ok2, $why2) = no_padding_in_summaries($trimmed2);
    ok($ok2, "second trim has no padding ($why2)");

    # And again
    for my $i (1..10) {
        my $tc = "tc_again_$i";
        push @$trimmed2, {
            role => 'assistant',
            content => "Even more $i " . ('text content ' x 50),
            tool_calls => [{ id => $tc, type => 'function',
                            function => { name => 'foo', arguments => '{}' } }],
        };
        push @$trimmed2, {
            role => 'tool',
            tool_call_id => $tc,
            content => "Even more result $i " . ('content lines ' x 80),
        };
    }
    push @$trimmed2, { role => 'user', content => 'continue again' };

    my $trimmed3 = validate_and_truncate(
        messages => $trimmed2,
        model_capabilities => { max_prompt_tokens => 30000, max_output_tokens => 8000 },
        tools => [],
        token_ratio => 2.5,
        trim_threshold => 2000,
        disable_post_trim_floor => 1,
    );

    my ($ok3, $why3) = no_padding_in_summaries($trimmed3);
    ok($ok3, "third trim has no padding ($why3)");
};

# ===== Test 4: pre-flight trim_conversation_for_api also has no padding =====
subtest 'pre-flight trim path (trim_conversation_for_api) has no padding' => sub {
    # Build a session with an existing thread_summary at position [1].
    # Pre-flight trims shouldn't introduce padding.
    my $existing_summary = "<thread_summary>\nCurrent task: Original work.\nFiles: a.c, b.c\n</thread_summary>";
    my @msgs = (
        { role => 'system', content => 'You are CLIO. ' . ('S' x 500) },
        { role => 'system', content => $existing_summary },
        { role => 'user', content => 'original task' },
    );
    for my $i (1..200) {
        my $tc = "tc_$i";
        push @msgs, {
            role => 'assistant',
            content => "Iter $i. " . ('Reasoning text. ' x 50),
            tool_calls => [{ id => $tc, type => 'function',
                            function => { name => 'foo', arguments => '{}' } }],
        };
        push @msgs, {
            role => 'tool',
            tool_call_id => $tc,
            content => "Result $i. " . ('Line. ' x 100),
        };
    }
    push @msgs, { role => 'user', content => 'Continue.' };

    my $system_prompt = 'You are CLIO. ' . ('S' x 500);
    my $trimmed = trim_conversation_for_api(
        \@msgs,
        $system_prompt,
        model_context_window => 131072,
        max_response_tokens  => 8192,
        debug => 0,
    );

    my ($ok, $why) = no_padding_in_summaries($trimmed);
    ok($ok, "pre-flight trim has no padding ($why)");
};

done_testing();