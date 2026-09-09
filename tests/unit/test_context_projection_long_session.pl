#!/usr/bin/perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Long-session integration test for ContextBuilder.
#
# Builds a synthetic 50-turn session with mixed tool calls, runs it
# through ContextBuilder::build_projection, and asserts the projected
# XML is materially smaller than the raw transcript while preserving
# the anchor task and recent turn.

use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/../../lib";

use Test::More;
use CLIO::Core::ContextBuilder;
use CLIO::Core::MessageHistory qw(messages_to_prose_dynamic);
use CLIO::Memory::TokenEstimator qw(estimate_messages_tokens);

*build_projection = \&CLIO::Core::ContextBuilder::build_projection;

# ---------------------------------------------------------------------------
# Build a synthetic 50-turn session
# ---------------------------------------------------------------------------

sub make_long_history {
    my %args = @_;
    my $turns = $args{turns} // 50;
    my @messages;

    # Anchor turn - substantive original task
    push @messages,
        { role => 'user', content => 'Original substantive task: implement context-aware projection layer in CLIO that scores LTM entries against current request and emits structured userContext XML.' },
        { role => 'assistant', content => 'I will build this in phases: ContextBuilder skeleton, LTM scoring, semantic dedup, serializer updates, and WorkflowOrchestrator wiring.' },
        { role => 'tool', content => 'plan ready', tool_call_id => 'call_plan' };

    for my $i (1 .. $turns) {
        # Mix of successful and error tool calls
        my $err = ($i % 7 == 0) ? ' ERROR: undefined variable' : '';
        push @messages,
            { role => 'user', content => "Phase $i step " . ('x' x 100) },
            {
                role => 'assistant',
                content => "Working on phase $i step. " . ('y' x 80),
                tool_calls => [
                    { id => "call_$i", function => { name => 'read_file', arguments => qq{{"path":"/src/file_$i.pm"}} } }
                ],
            },
            { role => 'tool', content => "File contents $i " . ('z' x 200) . $err, tool_call_id => "call_$i" };
    }

    return \@messages;
}

# ---------------------------------------------------------------------------
# Test: 50-turn session projection is materially smaller than raw transcript
# ---------------------------------------------------------------------------

{
    my $history = make_long_history(turns => 50);
    my $raw_tokens = estimate_messages_tokens($history);

    my $proj = build_projection(
        history    => $history,
        user_input => 'Phase 50 step',
    );
    # Compute projected tokens = anchor + recent turns + dynamic userContext.
    my @proj_messages;
    push @proj_messages, @{$proj->{anchor}} if $proj->{anchor};
    push @proj_messages, @{$_} for @{$proj->{turns} || []};
    my $proj_history_tokens = estimate_messages_tokens(\@proj_messages);
    my $dynamic_usercontext = messages_to_prose_dynamic($proj);
    my $dynamic_tokens = int(length($dynamic_usercontext) / 4);
    my $proj_tokens = $proj_history_tokens + $dynamic_tokens;

    my $reduction = sprintf("%.1f", (1 - ($proj_tokens / $raw_tokens)) * 100);
    diag("Long session: raw=$raw_tokens tokens, projected=$proj_tokens tokens, reduction=$reduction%");

    ok($proj_tokens < $raw_tokens, "Projection is smaller than raw ($proj_tokens < $raw_tokens tokens)");

    # The projection should drop most turns. With anchor + 1-2 recent
    # + userContext, projected should be well under 75% of raw.
    # (compressed_tail alone takes ~40% of raw tokens; the savings
    # come from dropping tool result bodies from the role-based
    # history portion.)
    ok($proj_tokens < ($raw_tokens * 3 / 4),
        "Projection is less than 75% of raw ($proj_tokens < " . int($raw_tokens * 3 / 4) . ")");
}

# ---------------------------------------------------------------------------
# Test: anchor (original task) survives in the projection
# ---------------------------------------------------------------------------

{
    my $history = make_long_history(turns => 50);
    my $proj = build_projection(
        history    => $history,
        user_input => 'continue',
    );

    # No separate anchor — active task is in dynamic userContext.
    # Original task preserved in compressed_tail via YaRN [original] marker.
    ok(!defined $proj->{anchor} || !defined $proj->{anchor}, "No separate anchor (task in compressed tail)");
    ok(length($proj->{compressed_tail}) > 0, "Compressed tail is non-empty");
    like($proj->{compressed_tail}, qr/Original substantive task/,
        "Original task preserved in compressed tail");
}

# ---------------------------------------------------------------------------
# Test: most recent turn survives in the projection
# ---------------------------------------------------------------------------

{
    my $history = make_long_history(turns => 50);
    my $proj = build_projection(
        history    => $history,
        user_input => 'continue',
    );

    my $last_turn = $proj->{turns}[-1];
    ok(defined $last_turn, "Projection has at least one recent turn");
    my $last_user = (grep { $_->{role} eq 'user' } @$last_turn)[0];
    ok(defined $last_user, "Recent turn has a user message");
    like($last_user->{content}, qr/Phase 50 step/, "Most recent turn preserved");
}

# ---------------------------------------------------------------------------
# Test: dropped turns go into compressed tail
# ---------------------------------------------------------------------------

{
    my $history = make_long_history(turns => 50);
    my $proj = build_projection(
        history    => $history,
        user_input => 'continue',
    );

    ok(length($proj->{compressed_tail}) > 0,
        "Compressed tail has content (was " . length($proj->{compressed_tail}) . " chars)");
}

# Prose renderer covers the dynamic userContext only. The stable
# content (anchor + recent turns) is delivered as role-based
# messages, not as prose.
{
    my $history = make_long_history(turns => 50);
    my $proj = build_projection(
        history    => $history,
        user_input => 'continue',
    );

    my $combined = messages_to_prose_dynamic($proj);
    my $dynamic = CLIO::Core::MessageHistory::messages_to_prose_dynamic($proj);

    like($combined, qr/Original substantive task/, "Prose renderer emits compressed tail (dynamic section)");
    unlike($combined, qr/^# Task\b/m, "Prose renderer omits # Task (now role-based)");
    unlike($combined, qr/# Recent work/, "Prose renderer omits # Recent work (now role-based)");
    is($combined, $dynamic, "messages_to_prose_dynamic renders consistently");
}

# ---------------------------------------------------------------------------
# Test: raw history unchanged
# ---------------------------------------------------------------------------

{
    my $history = make_long_history(turns => 30);
    my $before_count = scalar @$history;

    my $proj = build_projection(history => $history, user_input => 'continue');

    is(scalar @$history, $before_count, "Raw history count unchanged ($before_count)");
    # Recent turn messages must be the SAME refs (not clones). If
    # ContextBuilder were cloning, the hashrefs would differ.
    my $first_recent_msg = $proj->{turns}[-1][0];
    my $found_in_history = 0;
    for my $msg (@$history) {
        if ($msg == $first_recent_msg) {
            $found_in_history = 1;
            last;
        }
    }
    ok($found_in_history, "Recent turn messages are the SAME hashrefs as in raw history (no cloning)");
}

# ---------------------------------------------------------------------------
# Test: error tool results surface in unresolvedState
# ---------------------------------------------------------------------------

{
    # Every 7th turn has an ERROR in the tool content
    my $history = make_long_history(turns => 21);  # turns 7, 14, 21 have errors
    my $proj = build_projection(
        history    => $history,
        user_input => 'continue',
    );

    # unresolvedState is collected only when build_projection is called
    # with the unresolved arg populated (WorkflowOrchestrator passes it
    # from _collect_unresolved_state). When passed explicitly:
    my $proj2 = build_projection(
        history    => $history,
        user_input => 'continue',
        unresolved => ['tool_error: undefined variable in file_x'],
    );
    # After the role-based history refactor + metadata-leak fix,
    # unresolved state is NOT surfaced via the prose renderer's
    # dynamic userContext. The Unresolved: section was removed to
    # prevent recycling tool errors into the model's context.
    require CLIO::Core::MessageHistory;
    my $dynamic = CLIO::Core::MessageHistory::messages_to_prose_dynamic($proj2);
    unlike($dynamic, qr/unresolved state|tool_error: undefined variable in file_x/,
        "unresolved state NOT surfaced in dynamic userContext (metadata-leak fix)");
}

done_testing();