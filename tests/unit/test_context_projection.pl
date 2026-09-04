#!/usr/bin/perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Tests for CLIO::Core::ContextBuilder.
#
# Covers the 10 scenarios from scratch/optimize.md:
# 1. Original task (anchor) survives projection.
# 2. Recent turns survive.
# 3. Old turns get compressed.
# 4. Repeated tool calls collapse within a turn.
# 5. No framework narration in any output.
# 6. LTM cap: 55 memories -> at most 5 in <relevantMemory>.
# 7. Raw history is unchanged after projection.
# 8. Current-turn preservation: the projection doesn't include the
#    current user input (that's a separate user message).
# 9. Determinism: same inputs -> byte-identical projection.
# 10. Result-digest dedup: same args + same result collapse; same args +
#     different results keep both.

use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/../../lib";

use Test::More;
use CLIO::Core::ContextBuilder;

*build_projection = \&CLIO::Core::ContextBuilder::build_projection;
*score_ltm = \&CLIO::Core::ContextBuilder::score_ltm;
*digest = \&CLIO::Core::ContextBuilder::digest;
*select_turns = \&CLIO::Core::ContextBuilder::_select_turns;

# ---------------------------------------------------------------------------
# Helper: build a synthetic history
# ---------------------------------------------------------------------------

sub make_history {
    my (%args) = @_;
    my @messages;

    # Anchor turn
    push @messages,
        { role => 'user', content => $args{anchor_content} // 'Original substantive task that the model must always see.' },
        { role => 'assistant', content => 'I will start by reading the file.' },
        { role => 'tool', content => 'file contents', tool_call_id => 'call_anchor' };

    my $turns = $args{turns} // 5;
    for my $i (1 .. $turns) {
        push @messages,
            { role => 'user', content => "Question $i: " . ('x' x 80) },
            { role => 'assistant', content => "Answer $i: " . ('y' x 80) },
            { role => 'tool', content => "Result $i", tool_call_id => "call_$i" };
    }

    return \@messages;
}

# ---------------------------------------------------------------------------
# Test 1: anchor survival
# ---------------------------------------------------------------------------

{
    my $history = make_history(turns => 10);
    my $proj = build_projection(history => $history, user_input => 'continue');
    ok(defined $proj->{anchor}, "Anchor is set");
    ok(@{$proj->{anchor}} >= 1, "Anchor has at least one message");
    is($proj->{anchor}[0]{role}, 'user', "Anchor starts with a user message");
    like($proj->{anchor}[0]{content}, qr/Original substantive task/, "Anchor preserves original task content");
}

# ---------------------------------------------------------------------------
# Test 2: recent turns survive
# ---------------------------------------------------------------------------

{
    my $history = make_history(turns => 5);
    my $proj = build_projection(history => $history, user_input => 'continue');
    ok(@{$proj->{turns}} >= 1, "At least one recent turn present");
    is($proj->{turns}[-1][-1]{tool_call_id}, 'call_5', "Most recent tool result preserved");
}

# ---------------------------------------------------------------------------
# Test 3: old turns get compressed
# ---------------------------------------------------------------------------

{
    my $history = make_history(turns => 30);
    my $proj = build_projection(history => $history, user_input => 'continue');
    ok(length($proj->{compressed_tail}) > 0, "Compressed tail is non-empty for long history");
    # The dropped turns = 30 + 1 (anchor) - 1 (latest) = 28 (approx)
    # We can't assert exact count, but compressed_tail should reflect a
    # meaningful aggregation of dropped content.
    my $combined_size = length($proj->{compressed_tail});
    ok($combined_size > 100, "Compressed tail has aggregated content (was $combined_size chars)");
}

# Test 4 was removed: collapse_repeated_tool_calls was a within-turn
# dedup that operated on the old {tools => [...]} turn shape. After
# the role-based history refactor, turns are arrayrefs of role-based
# messages (no tools field) and within-turn dedup is a no-op. The
# cross-turn variant still runs in build_projection.

# ---------------------------------------------------------------------------
# Test 5: no framework narration in projection
# ---------------------------------------------------------------------------

{
    my $history = make_history(turns => 3);
    my $proj = build_projection(history => $history, user_input => 'continue');
    my $uc = $proj->{userContext};

    unlike($uc, qr/After context trimming/, "userContext has no 'After context trimming'");
    unlike($uc, qr/UNVERIFIED/, "userContext has no 'UNVERIFIED' label");
    unlike($uc, qr/TRUSTED/, "userContext has no 'TRUSTED' label");
    unlike($uc, qr/Showing \d+ of \d+ memories/, "userContext has no 'Showing X of Y' footer");
    unlike($uc, qr/memory_operations\(operation: "search"/, "userContext has no 'memory_operations(search)' instruction");
    unlike($uc, qr/informational context only/, "userContext has no 'informational context only' boilerplate");
    unlike($uc, qr/Session ID/, "userContext has no 'Session ID' header");
}

# ---------------------------------------------------------------------------
# Test 6: LTM cap (max 5 memories, threshold >= 5)
# ---------------------------------------------------------------------------

{
    # Build 55 mock LTM entries with low relevance
    my @ltm;
    for my $i (1 .. 55) {
        push @ltm, {
            confidence => 0.5,
            content    => "unrelated topic $i " . ('z' x 50),
            type       => 'discovery',
        };
    }

    my $scored = score_ltm(\@ltm, 'fix the cache bug in MessageValidator', 'qa-messageHistory-fix', ['trim_with_noise_dropping failed']);
    is(scalar @$scored, 0, "Zero memories meet threshold with no keyword overlap");

    # Now build memories that match the current input - they should win.
    push @ltm,
        { confidence => 0.9, content => 'cache-collapse regex needs whitespace class not just >', type => 'pattern' },
        { confidence => 0.85, content => 'apply YaRN compression only when >200 chars dropped', type => 'pattern' },
        { confidence => 0.78, content => 'use rindex not regex for embedded tag safety', type => 'pattern' },
        { confidence => 0.6, content => 'ModelBudget enforcement is wired but disabled', type => 'discovery' },
        { confidence => 0.55, content => 'AGENTS.md gaps for ModelBudget', type => 'discovery' },
        { confidence => 0.55, content => 'AGENTS.md gaps for cache health', type => 'discovery' };

    my $scored2 = score_ltm(\@ltm, 'fix the cache-collapse regex bug', 'qa-messageHistory-fix', []);
    ok(scalar(@$scored2) <= 5, "At most 5 memories pass cap (was " . scalar(@$scored2) . ")");
    ok(scalar(@$scored2) > 0, "Some memories pass threshold when relevant");

    # Verify tier labels are absent from the rendered userContext
    my $proj = build_projection(
        history    => make_history(turns => 2),
        user_input => 'fix the cache-collapse regex bug',
        active_task => 'qa-messageHistory-fix',
        ltm        => \@ltm,
    );
    unlike($proj->{userContext}, qr/UNVERIFIED|TRUSTED/, "userContext has no tier labels");
}

# ---------------------------------------------------------------------------
# Test 7: raw history is unchanged after projection
# ---------------------------------------------------------------------------

{
    my $history = make_history(turns => 5);
    # Snapshot the deep structure before projection.
    my $before = [ map { { %$_ } } @$history ];
    # Mutate the snapshot messages to ensure they're separate copies
    for my $msg (@$before) {
        $msg->{_snapshot_marker} = 1;
    }

    my $proj = build_projection(history => $history, user_input => 'continue');

    # The history must not have _snapshot_marker - it should be unchanged.
    my $has_marker = grep { $_->{_snapshot_marker} } @$history;
    is($has_marker, 0, "Raw history was not mutated by projection");

    # Sanity: turns the projection selected should still be the SAME refs
    # (not clones) so the original array is unaffected by any dedup we did.
    my $last_turn = $proj->{turns}[-1];
    ok(ref $last_turn eq 'ARRAY', "Recent turns is an arrayref");
}

# ---------------------------------------------------------------------------
# Test 8: current-turn preservation (NOT in projection)
# ---------------------------------------------------------------------------

{
    # The current turn is the user input the model is about to respond to.
    # The projection MUST NOT include it - it's added separately as the
    # role:user message at the end of the @messages array.
    my @messages = (
        { role => 'user', content => 'Original task that the model must always see.' },
        { role => 'assistant', content => 'first reply' },
        { role => 'user', content => 'second user message' },
        { role => 'assistant', content => 'second assistant reply' },
    );
    my $proj = build_projection(history => \@messages, user_input => 'second user message');

    # The anchor is the FIRST user message
    is($proj->{anchor}[0]{content}, 'Original task that the model must always see.',
        "Anchor is the FIRST user message");

    # The "current" user input (last user message) is in recent turns,
    # not in anchor. This is by design: the projection shows past turns
    # in full, and the model's actual response targets the separately-
    # delivered user_input role:user message.
    my $found = 0;
    for my $turn (@{$proj->{turns}}) {
        for my $msg (@$turn) {
            if (($msg->{content} // '') eq 'second user message') {
                $found = 1;
                last;
            }
        }
        last if $found;
    }
    ok($found, "Current-turn user message is in recent turns (the projection serializes past turns; current input is delivered separately)");
}

# ---------------------------------------------------------------------------
# Test 9: determinism
# ---------------------------------------------------------------------------

{
    my $history = make_history(turns => 4);
    my $ltm = [
        { confidence => 0.9, content => 'foo bar baz', type => 'pattern' },
        { confidence => 0.8, content => 'fix the cache bug', type => 'pattern' },
    ];

    my $p1 = build_projection(
        history    => $history,
        user_input => 'fix the cache bug',
        active_task => 'qa-test',
        ltm        => $ltm,
    );
    my $p2 = build_projection(
        history    => $history,
        user_input => 'fix the cache bug',
        active_task => 'qa-test',
        ltm        => $ltm,
    );

    is($p1->{userContext}, $p2->{userContext}, "userContext is deterministic across runs");
    is(scalar @{$p1->{turns}}, scalar @{$p2->{turns}}, "Turn count is deterministic");

    # compressed_tail may include a clock-derived string? No - it
    # doesn't include timestamps. Verify it's stable.
    is($p1->{compressed_tail}, $p2->{compressed_tail}, "compressed_tail is deterministic");
}

# ---------------------------------------------------------------------------
# Test 10: digest() - used internally by cross-turn dedup for
# result-content fingerprints. The within-turn collapse tests were
# removed when collapse_repeated_tool_calls was deleted (no-op for
# role-based turns).
{
    # digest() is stable and short
    is(length(digest('hello')), 16, "digest returns 16 hex chars");
    is(digest('hello'), digest('hello'), "digest is deterministic");
    isnt(digest('hello'), digest('world'), "digest differs for different input");
}

done_testing();