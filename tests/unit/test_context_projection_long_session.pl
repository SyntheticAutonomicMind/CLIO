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
use CLIO::Core::MessageHistory qw(messages_to_prose);
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
    my $dynamic_usercontext = messages_to_prose($proj);
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

    ok(defined $proj->{anchor}, "Projection has anchor");
    ok(@{$proj->{anchor}} >= 1, "Anchor has messages");
    is($proj->{anchor}[0]{role}, 'user', "Anchor starts with user message");
    like($proj->{anchor}[0]{content}, qr/Original substantive task/,
        "Anchor contains original task text");
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

# ---------------------------------------------------------------------------
# Test: stable + dynamic split for the prose renderer
# DELETED in this commit: messages_to_prose_stable no longer exists.
# The role-based history refactor pushed the stable content (anchor +
# recent turns) as role-based messages, not as prose. The active
# renderer is messages_to_prose_dynamic (the system userContext).
# messages_to_prose is now an alias for messages_to_prose_dynamic.
{
    my $history = make_long_history(turns => 50);
    my $proj = build_projection(
        history    => $history,
        user_input => 'continue',
    );

    my $combined = messages_to_prose($proj);
    my $dynamic = CLIO::Core::MessageHistory::messages_to_prose_dynamic($proj);

    # Dynamic prose contains the dynamic sections.
    like($combined, qr/# Environment/, "Prose renderer emits # Environment section");
    # No # Task or # Recent work sections in prose (those are now
    # pushed as role-based messages by WorkflowOrchestrator).
    unlike($combined, qr/# Task\b/, "Prose renderer omits # Task (now role-based)");
    unlike($combined, qr/# Recent work/, "Prose renderer omits # Recent work (now role-based)");

    # messages_to_prose is the dynamic renderer.
    is($combined, $dynamic, "messages_to_prose is messages_to_prose_dynamic");
}

# ---------------------------------------------------------------------------
# Test: raw history unchanged
# ---------------------------------------------------------------------------

{
    my $history = make_long_history(turns => 30);
    my $before_count = scalar @$history;

    my $proj = build_projection(history => $history, user_input => 'continue');

    is(scalar @$history, $before_count, "Raw history count unchanged ($before_count)");
    # Anchor + recent turn messages must be the SAME refs (not clones).
    # If ContextBuilder were cloning, the hashrefs would differ.
    my $first_anchor_msg = $proj->{anchor}[0];
    my $found_in_history = 0;
    for my $msg (@$history) {
        if ($msg == $first_anchor_msg) {
            $found_in_history = 1;
            last;
        }
    }
    ok($found_in_history, "Anchor messages are the SAME hashrefs as in raw history (no cloning)");
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
    # After the role-based history refactor, unresolved state is
    # surfaced via the prose renderer's dynamic userContext
    # (messages_to_prose_dynamic). The userContext XML field is
    # unused but kept as an empty string for backwards compatibility.
    require CLIO::Core::MessageHistory;
    my $dynamic = CLIO::Core::MessageHistory::messages_to_prose_dynamic($proj2);
    like($dynamic, qr/unresolved state|tool_error: undefined variable in file_x/,
        "unresolved state surfaces when unresolved arg is provided");
}

done_testing();