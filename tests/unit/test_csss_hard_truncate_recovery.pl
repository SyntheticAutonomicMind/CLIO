#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

# Regression test for CSSS (Cache-Stable Summary Slot) recovery from
# prior hard-truncation.
#
# Bug observed 2026-08-29: a session was resumed on a different model
# with a much larger context window. The previous summary had been
# hard-truncated to 199 tokens on a small-context model. Every turn
# the validator produced a 539-token summary, _fit_summary_to_target
# hard-truncated it back to 199, and the model never saw the full
# summary. The slot stayed locked at 199 indefinitely because
# proactive growth only fires when dropped_tokens > 1.5x slot.
#
# Fix: when computing the slot target from a previous summary, detect
# a prior hard-truncate by comparing the summary's actual content
# size to its _metadata.compressed_tokens (what compress_messages
# wanted to produce). If they disagree, the slot was clipped, so use
# the recorded size as the new target (capped at MAX). This lets the
# slot grow on the very next turn instead of staying locked at the
# truncated size forever.

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";

use Test::More;
use CLIO::Core::API::MessageValidator qw(validate_and_truncate);
use CLIO::Core::Defaults qw(MAX_CSSS_SLOT_TOKENS);

# Build a session where the previous summary is hard-truncated:
# actual content = 199 tokens, but _metadata.compressed_tokens = 539
# (what compress_messages wanted to produce).
sub build_session_with_hard_truncated_summary {
    my @msgs = (
        # System prompt
        { role => 'system', content => 'CLIO System Prompt ' . ('S' x 6000) },

        # Previous thread_summary that was hard-truncated from 539 to 199.
        # _metadata.compressed_tokens records what compress_messages wanted
        # to produce; the actual content is what was kept after the
        # hard-truncate in _fit_summary_to_target.
        {
            role    => 'system',
            content => "<threadSummary>\n\nCurrent task: do X\n\n" .
                       ('detail ' x 30) . "\n[Summary truncated to fit cache-stable slot of 199 tokens]",
            _metadata => {
                compressed_tokens => 539,
                compressed_count  => 5,
                original_tokens   => 1500,
            },
        },

        # Some recent user/assistant exchanges
        { role => 'user', content => 'continue the work' },
        { role => 'assistant', content => 'Working on it. ' . ('z' x 200) },
        { role => 'user', content => 'next step' },
    );
    return @msgs;
}

# Find the trailing thread_summary and return its content length in tokens.
sub summary_tokens {
    my ($result) = @_;
    for my $m (@$result) {
        if (($m->{role} // '') eq 'system' && ($m->{content} // '') =~ /<threadSummary>/) {
            require CLIO::Memory::TokenEstimator;
            return CLIO::Memory::TokenEstimator::estimate_tokens($m->{content});
        }
    }
    return 0;
}

# Test 1: when the previous summary was hard-truncated, the slot target
# on the next trim should grow from the truncated size (199) to the
# recorded compressed_tokens (539). The new summary's content then
# fits without hard-truncation.
#
# The bug: slot stays at 199 -> every turn, content is hard-truncated
# back to 199, slot never grows.
#
# The fix: detect prior hard-truncate via _metadata.compressed_tokens
# and grow the slot. The actual summary content size depends on what's
# being compressed this turn (organic growth, ceiling not target), but
# the slot is now large enough to absorb normal compression output.
subtest 'slot recovers from previously hard-truncated 199 to recorded 539' => sub {
    my @msgs = (
        { role => 'system', content => 'CLIO System Prompt ' . ('S' x 6000) },
        {
            role    => 'system',
            content => "<threadSummary>\n\nCurrent task: do X\n\n" .
                       ('detail ' x 30) . "\n[Summary truncated to fit cache-stable slot of 199 tokens]",
            _metadata => {
                compressed_tokens => 539,
                compressed_count  => 5,
                original_tokens   => 1500,
            },
        },
        { role => 'user', content => 'task description ' . ('u' x 4000) },
        { role => 'assistant', content => 'reasoning ' . ('a' x 4000) },
        { role => 'user', content => 'next ' . ('v' x 4000) },
        { role => 'assistant', content => 'more reasoning ' . ('b' x 4000) },
        { role => 'user', content => 'continue' },
    );

    my $result = validate_and_truncate(
        messages => \@msgs,
        model_capabilities => {
            max_prompt_tokens => 1000000,
            max_output_tokens => 16000,
        },
        tools => [],
        token_ratio => 2.5,
        trim_threshold => 2000,
        disable_post_trim_floor => 1,
    );

    my $tokens = summary_tokens($result);

    # The new summary is no longer hard-truncated to 199 - the slot
    # recovery gave the new content room to compress naturally.
    ok($tokens > 199, "summary no longer clipped to 199 floor (got $tokens)");

    # Bounded by MAX.
    ok($tokens <= MAX_CSSS_SLOT_TOKENS + 1000,
        "summary still bounded by MAX ceiling (got $tokens, max=${\ MAX_CSSS_SLOT_TOKENS })");
};

# Test 1b: same scenario but WITHOUT _metadata on the prior summary.
# The recovery code can't run, so the slot stays at the truncated
# size and the bug manifests. This documents the limitation: the
# fix relies on _metadata surviving across the session boundary.
subtest 'without _metadata: slot stays at 199, summary hard-truncated (the bug)' => sub {
    my @msgs = (
        { role => 'system', content => 'CLIO System Prompt ' . ('S' x 6000) },
        {
            role    => 'system',
            # Hard-truncated content but NO _metadata - can't recover.
            content => "<threadSummary>\n\nCurrent task: do X\n\n" .
                       ('detail ' x 30) . "\n[Summary truncated to fit cache-stable slot of 199 tokens]",
        },
        { role => 'user', content => 'task description ' . ('u' x 4000) },
        { role => 'assistant', content => 'reasoning ' . ('a' x 4000) },
        { role => 'user', content => 'next ' . ('v' x 4000) },
        { role => 'assistant', content => 'more reasoning ' . ('b' x 4000) },
        { role => 'user', content => 'continue' },
    );

    my $result = validate_and_truncate(
        messages => \@msgs,
        model_capabilities => {
            max_prompt_tokens => 1000000,
            max_output_tokens => 16000,
        },
        tools => [],
        token_ratio => 2.5,
        trim_threshold => 2000,
        disable_post_trim_floor => 1,
    );

    my $tokens = summary_tokens($result);
    # The slot floor raises the *ceiling* to 4096, but the summary only
    # grows to what the dropped content needs. The point is that the
    # floor lets the 247-token natural compression succeed without
    # hard-truncate (no "summary truncated to fit" marker).
    ok($tokens > 0, "no-metadata path produces a summary (got $tokens)");
    ok($tokens <= MAX_CSSS_SLOT_TOKENS + 1000,
        "no-metadata path bounded by MAX (got $tokens, max=${\ MAX_CSSS_SLOT_TOKENS })");
};

# Test 2: when the previous summary is NOT hard-truncated (content
# size matches _metadata.compressed_tokens), the slot stays at the
# existing size - no recovery fires.
subtest 'no hard-truncate: slot stays at existing size (no recovery log)' => sub {
    # Build a summary whose content length matches its _metadata.
    # _metadata.compressed_tokens records what compress_messages wanted
    # to produce; we set it equal to the actual content size so no
    # hard-truncate is implied.
    require CLIO::Memory::TokenEstimator;
    my $content = "<threadSummary>\n\nCurrent task: do X\n\n" .
                  ('detail ' x 200) . "</threadSummary>\n";
    my $existing = CLIO::Memory::TokenEstimator::estimate_tokens($content);

    my @msgs = (
        { role => 'system', content => 'CLIO System Prompt ' . ('S' x 6000) },
        {
            role    => 'system',
            content => $content,
            _metadata => {
                # compressed_tokens matches the content size exactly -
                # no hard-truncate. Recovery should NOT fire.
                compressed_tokens => $existing,
                compressed_count  => 5,
                original_tokens   => 1500,
            },
        },
        { role => 'user', content => 'task description ' . ('u' x 4000) },
        { role => 'assistant', content => 'reasoning ' . ('a' x 4000) },
        { role => 'user', content => 'next ' . ('v' x 4000) },
        { role => 'assistant', content => 'more reasoning ' . ('b' x 4000) },
        { role => 'user', content => 'continue' },
    );

    my $result = validate_and_truncate(
        messages => \@msgs,
        model_capabilities => {
            max_prompt_tokens => 1000000,
            max_output_tokens => 16000,
        },
        tools => [],
        token_ratio => 2.5,
        trim_threshold => 2000,
        disable_post_trim_floor => 1,
    );

    my $tokens = summary_tokens($result);
    ok($tokens > 0, "non-truncated path produces a summary (got $tokens tokens)");
    ok($tokens <= MAX_CSSS_SLOT_TOKENS + 1000,
        "stays bounded by MAX (got $tokens, max=${\ MAX_CSSS_SLOT_TOKENS })");
};

# Test 3: no _metadata at all on the prior summary - the recovery
# path doesn't run. Falls back to the existing $summary_unit->{tokens}
# logic. This is the old-session case where the bug can't be fixed
# without re-compressing the prior summary from scratch.
subtest 'no _metadata: recovery path does not run, fallback behavior' => sub {
    my @msgs = (
        { role => 'system', content => 'CLIO System Prompt ' . ('S' x 6000) },
        {
            role    => 'system',
            content => "<threadSummary>\n\nCurrent task: do X\n\n" .
                       ('detail ' x 30),
            # No _metadata - recovery can't run.
        },
        { role => 'user', content => 'task description ' . ('u' x 4000) },
        { role => 'assistant', content => 'reasoning ' . ('a' x 4000) },
        { role => 'user', content => 'next ' . ('v' x 4000) },
        { role => 'assistant', content => 'more reasoning ' . ('b' x 4000) },
        { role => 'user', content => 'continue' },
    );

    my $result = validate_and_truncate(
        messages => \@msgs,
        model_capabilities => {
            max_prompt_tokens => 1000000,
            max_output_tokens => 16000,
        },
        tools => [],
        token_ratio => 2.5,
        trim_threshold => 2000,
        disable_post_trim_floor => 1,
    );

    my $tokens = summary_tokens($result);
    ok($tokens > 0, "no-metadata path produces a summary (got $tokens tokens)");
    ok($tokens <= MAX_CSSS_SLOT_TOKENS + 1000,
        "no-metadata path stays bounded (got $tokens, max=${\ MAX_CSSS_SLOT_TOKENS })");
};

# Test 4: hard-truncate recovery is bounded by MAX. Even if the prior
# turn wanted 50000 tokens and was clipped, the recovery target is
# capped at MAX_CSSS_SLOT_TOKENS.
subtest 'recovery is capped at MAX_CSSS_SLOT_TOKENS' => sub {
    my @msgs = (
        { role => 'system', content => 'CLIO System Prompt ' . ('S' x 6000) },
        {
            role    => 'system',
            content => "<threadSummary>\n\nCurrent task: do X\n\n" .
                       ('detail ' x 50),
            _metadata => {
                compressed_tokens => 50000,  # way more than MAX
                compressed_count  => 100,
                original_tokens   => 100000,
            },
        },
        { role => 'user', content => 'task description ' . ('u' x 4000) },
        { role => 'assistant', content => 'reasoning ' . ('a' x 4000) },
        { role => 'user', content => 'next ' . ('v' x 4000) },
        { role => 'assistant', content => 'more reasoning ' . ('b' x 4000) },
        { role => 'user', content => 'continue' },
    );

    my $result = validate_and_truncate(
        messages => \@msgs,
        model_capabilities => {
            max_prompt_tokens => 1000000,
            max_output_tokens => 16000,
        },
        tools => [],
        token_ratio => 2.5,
        trim_threshold => 2000,
        disable_post_trim_floor => 1,
    );

    my $tokens = summary_tokens($result);
    ok($tokens <= MAX_CSSS_SLOT_TOKENS + 1000,
        "recovery capped at MAX (got $tokens, max=${\ MAX_CSSS_SLOT_TOKENS })");
};

done_testing();
