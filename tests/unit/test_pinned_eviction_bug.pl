#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test: _role_based_tail_walk must NOT silently drop
# pinned messages when budget is tight enough to require eviction.
#
# The original bug:
#   When the walk accumulates non-pinned content close to budget
#   AND adding a pinned message overflows the budget, the eviction
#   loop did `shift @kept_indices; next;` when the front was pinned,
#   which removed the pinned index from the kept set - defeating
#   the pin. Result: system_prompt, first_user (original task),
#   dynamic userContext, and last user_input could all be silently
#   dropped under budget pressure.
#
# The fix:
#   - Walk budget is reserved for pinned up front so the walk
#     doesn't accumulate past (effective_limit - pinned_total).
#   - The eviction loop now breaks out instead of shifting pinned
#     fronts; if a pinned message can't fit, the function returns
#     the input as-is rather than dropping the pin.
#
# This test exercises tight budget + many large tool pairs to
# force the eviction loop to actually run. The original test
# (test_tail_walk_protect_usercontext.pl) passed by luck because
# its pinned content was small enough to fit without eviction.

use strict;
use warnings;
use utf8;
use lib './lib';

use Test::More;
use CLIO::Core::API::MessageValidator qw(validate_and_truncate);

# ---------------------------------------------------------------------------
# Scenario 1: tight budget + many large tool pairs forces eviction.
# Without the bugfix, system_prompt and first_user are silently
# dropped. With the bugfix, they survive.
# ---------------------------------------------------------------------------
{
    my @messages;
    push @messages, { role => 'system', content => 'SYS' x 5 };  # ~4 tokens
    push @messages, { role => 'user', content => 'ORIGINAL_TASK ' x 50 };  # ~150 tokens
    for my $i (1..40) {
        push @messages, { role => 'user', content => "task $i" . 'x' x 100 };
        push @messages, { role => 'assistant', content => "Work $i", tool_calls => [{id=>"t$i",function=>{name=>'e',arguments=>'{}'}}] };
        push @messages, { role => 'tool', tool_call_id => "t$i", content => "R$i " x 100 };  # ~100 tokens each
    }
    push @messages, { role => 'user', content => 'FINAL_QUESTION' };

    my $result = validate_and_truncate(
        messages => \@messages,
        model_capabilities => { max_context_window_tokens => 5000, max_output_tokens => 2000 },
        tools => [],
    );

    my @roles = map { $_->{role} } @$result;
    my @contents = map { $_->{content} // '' } @$result;

    ok(grep { /SYS/ } @contents,
        'Scenario 1: system_prompt survived aggressive trim with eviction')
        or diag("Roles: @roles");

    ok(grep { /ORIGINAL_TASK/ } @contents,
        'Scenario 1: first user (original task) survived aggressive trim')
        or diag("Roles: @roles");

    ok(grep { /FINAL_QUESTION/ } @contents,
        'Scenario 1: last user (current input) survived aggressive trim')
        or diag("Roles: @roles");

    # When the trim can't fit pinned, it returns as-is. That's
    # acceptable; the regression is silent loss of pinned content.
    my $returned_as_is = (scalar(@$result) == scalar(@messages));
    if ($returned_as_is) {
        diag('Scenario 1: trim returned input as-is (over-budget; pinned could not fit)');
    }
}

# ---------------------------------------------------------------------------
# Scenario 2: small budget with realistic layout (system + anchor +
# recent turns + dynamic userContext + user_input + many tool pairs).
# Tests the test_tail_walk_protect_usercontext.pl shape with a
# budget tight enough to force eviction.
# ---------------------------------------------------------------------------
{
    my @messages;
    push @messages, { role => 'system', content => 'SYSTEM_PROMPT_' . ('x' x 200) };
    push @messages, { role => 'user', content => 'Original anchor task ' . ('x' x 200) };
    push @messages, { role => 'assistant', content => 'Got it.' };
    push @messages, { role => 'user', content => 'Recent turn user ' . ('x' x 100) };
    push @messages, { role => 'assistant', content => 'Recent turn assistant.' };
    push @messages, { role => 'system', content => 'DYNAMIC_USERCONTEXT_' . ('x' x 100) };
    push @messages, { role => 'user', content => 'CURRENT_QUESTION_HERE' };
    for my $i (1..50) {
        push @messages, { role => 'assistant', content => "iter $i", tool_calls => [{id=>"tc_$i",function=>{name=>'fs',arguments=>'{}'}}] };
        push @messages, { role => 'tool', tool_call_id => "tc_$i", content => 'result ' x 200 };
    }

    my $result = validate_and_truncate(
        messages => \@messages,
        model_capabilities => { max_context_window_tokens => 2000, max_output_tokens => 200 },
        tools => [],
    );

    my @contents = map { $_->{content} // '' } @$result;

    ok(grep { /SYSTEM_PROMPT_/ } @contents,
        'Scenario 2: system_prompt survived aggressive trim')
        or diag("Result contents: @contents");

    ok(grep { /Original anchor task/ } @contents,
        'Scenario 2: first user (original task anchor) survived')
        or diag("Result contents: @contents");

    ok(grep { /DYNAMIC_USERCONTEXT_/ } @contents,
        'Scenario 2: dynamic userContext system message survived')
        or diag("Result contents: @contents");

    ok(grep { /CURRENT_QUESTION_HERE/ } @contents,
        'Scenario 2: current turn user_input survived')
        or diag("Result contents: @contents");
}

# ---------------------------------------------------------------------------
# Scenario 3: dynamic userContext with non-trivial size that, before
# the walk-budget fix, would cause the walk to over-accumulate and
# force eviction through a pinned front.
# ---------------------------------------------------------------------------
{
    my @messages;
    # Large system prompt + large dynamic userContext + large first user.
    # Each pinned message is itself larger than the walk budget alone.
    push @messages, { role => 'system', content => 'SYS ' x 300 };  # ~300 tokens
    push @messages, { role => 'user', content => 'TASK ' x 300 };   # ~300 tokens
    for my $i (1..30) {
        push @messages, { role => 'assistant', content => "Work $i", tool_calls => [{id=>"t$i",function=>{name=>'e',arguments=>'{}'}}] };
        push @messages, { role => 'tool', tool_call_id => "t$i", content => "R$i " x 50 };
        push @messages, { role => 'user', content => "continue" };
    }
    push @messages, { role => 'system', content => 'DYN_USERCONTEXT ' x 200 };
    push @messages, { role => 'user', content => 'FINAL_QUESTION_HERE' };

    my $result = validate_and_truncate(
        messages => \@messages,
        model_capabilities => { max_context_window_tokens => 4000, max_output_tokens => 2000 },
        tools => [],
    );

    my @contents = map { $_->{content} // '' } @$result;

    ok(grep { /^SYS / } @contents,
        'Scenario 3: large system_prompt survived even with over-budget pin')
        or diag("Contents: " . join('|', map { substr($_, 0, 30) } @contents));

    ok(grep { /FINAL_QUESTION_HERE/ } @contents,
        'Scenario 3: final user_input survived')
        or diag("Contents: " . join('|', map { substr($_, 0, 30) } @contents));
}

done_testing();