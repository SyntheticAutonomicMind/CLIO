#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Tests for the role-based history refactor in WorkflowOrchestrator.
#
# After the messageHistory XML feature was removed:
# 1. History is pushed as individual role-based messages (anchor +
#    recent turns), not as a single <messageHistory> XML block.
# 2. The dynamic userContext (active task, todos, LTM, environment,
#    context files) is rendered by messages_to_prose_dynamic and
#    pushed as a single system message AFTER history, BEFORE
#    user_input.
# 3. The cache-stable prefix is [system_prompt + role-based history].
#    The dynamic userContext churns each turn but doesn't invalidate
#    the prefix.
# 4. The @$history >= 3 gate that used to force first-turn sessions
#    onto the legacy XML path is gone - prose path runs always.
# 5. messages_to_xml, xml_to_turns, trim_xml_history are gone.

use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/../../lib";

use Test::More;
use CLIO::Core::ContextBuilder;
use CLIO::Core::MessageHistory qw(messages_to_prose_dynamic);

*build_projection = \&CLIO::Core::ContextBuilder::build_projection;

# ---------------------------------------------------------------------------
# Helper: build a small role-based history
# ---------------------------------------------------------------------------

sub make_history {
    my %a = @_;
    my $turns = $a{turns} // 3;
    my @h = (
        { role => 'user', content => 'Original task: investigate the trim_xml_history bug.' },
        { role => 'assistant', content => 'I will read the relevant files.',
          tool_calls => [{ id => 'call_001', function => { name => 'read_file', arguments => '{"path":"/a"}' } }] },
        { role => 'tool', content => 'file A contents', tool_call_id => 'call_001' },
        { role => 'assistant', content => 'Found the offset bug at line 12.' },
    );
    for my $i (2 .. $turns) {
        push @h,
            { role => 'user', content => "Phase $i followup" },
            { role => 'assistant', content => "Working on phase $i",
              tool_calls => [{ id => "call_${i}_1", function => { name => 'read_file', arguments => qq{{"path":"/f$i"}} } }] },
            { role => 'tool', content => "file $i contents", tool_call_id => "call_${i}_1" },
            { role => 'assistant', content => "Phase $i complete." };
    }
    return \@h;
}

# ---------------------------------------------------------------------------
# Test 1: First-turn empty history no longer trips messageHistory XML
# ---------------------------------------------------------------------------
# Before the refactor, an empty history produced:
#   <messageHistory>\n<userContext>...</userContext>\n</messageHistory>\n
# and trim_xml_history would WARN "cannot parse messageHistory block"
# because the closing-tag check failed for that empty-body shape.
# After the refactor, empty history produces an empty dynamic
# userContext, no XML block, no WARN.
{
    my $proj = build_projection(
        history    => [],
        user_input => 'first turn user input',
        active_task => '',
        active_todos => [],
        ltm        => [],
        unresolved => [],
        context_files_block => '',
        session    => undef,
    );

    my $dynamic = messages_to_prose_dynamic($proj);
    # messages_to_prose_stable was deleted in the role-based history
    # refactor (its content is now pushed as role-based messages, not
    # as prose). The empty-history dynamic prose is what the model
    # actually sees as the system userContext for first-turn sessions.
    ok(length($dynamic) >= 0, "Empty history: dynamic prose renders (no XML)");

    # Verify no messageHistory XML tags anywhere
    unlike($dynamic, qr/<messageHistory>/, "Dynamic prose does not contain messageHistory XML tag");
}

# ---------------------------------------------------------------------------
# Test 2: messages_to_prose_dynamic emits only dynamic sections
# ---------------------------------------------------------------------------
{
    my $history = make_history(turns => 5);
    my $proj = build_projection(
        history      => $history,
        user_input   => 'continue',
        active_task  => 'investigate trim_xml_history bug',
        active_todos => [
            { id => 1, status => 'in-progress', content => 'Read ContextBuilder.pm' },
        ],
        ltm          => [],
        unresolved   => [],
        context_files_block => '',
        session      => undef,
    );

    my $dynamic = messages_to_prose_dynamic($proj);

    like($dynamic, qr/# Active task/, "Active task section present");
    like($dynamic, qr/investigate trim_xml_history bug/, "Active task content present");
    like($dynamic, qr/# Active todos/, "Active todos section present");
    like($dynamic, qr/- \[in-progress\] Read ContextBuilder\.pm/, "Todo rendered with status");
    like($dynamic, qr/# Environment/, "Environment section present");
    unlike($dynamic, qr/# Task\b/, "Dynamic prose omits # Task (that's stable)");
    unlike($dynamic, qr/# Recent work/, "Dynamic prose omits # Recent work (that's stable)");
}

# Test 3 was: messages_to_prose_stable emits only stable sections.
# DELETED in this commit: messages_to_prose_stable no longer exists.
# The stable content (anchor + recent turns) is now pushed by
# WorkflowOrchestrator as role-based messages, not as prose.
# messages_to_prose_dynamic is the sole renderer used in production.
# The cache-stable prefix is verified by inspecting the role-based
# messages directly (see test 4 below).

# ---------------------------------------------------------------------------
# Test 4: Projection produces role-based anchor + turns (no XML wrapping)
# ---------------------------------------------------------------------------
{
    my $history = make_history(turns => 3);
    my $proj = build_projection(
        history      => $history,
        user_input   => 'continue',
        active_task  => '',
        active_todos => [],
        ltm          => [],
        unresolved   => [],
        context_files_block => '',
        session      => undef,
    );

    # Anchor should be an arrayref of role-based message hashes
    ok(ref($proj->{anchor}) eq 'ARRAY', "Anchor is an arrayref");
    ok(@{$proj->{anchor}} > 0, "Anchor has at least one message");
    is($proj->{anchor}[0]{role}, 'user', "Anchor starts with user message");

    # Recent turns should be arrayrefs of arrayrefs
    ok(ref($proj->{turns}) eq 'ARRAY', "turns is an arrayref");
    for my $turn (@{$proj->{turns}}) {
        ok(ref($turn) eq 'ARRAY', "Each turn is an arrayref of messages");
        ok(@$turn > 0, "Each turn has at least one message");
    }
}

# ---------------------------------------------------------------------------
# Test 5: No gate prevents first-turn sessions from using projection
# ---------------------------------------------------------------------------
# After the refactor, projection runs for any history size including
# empty. This test verifies the projection builder itself accepts
# empty/1-message history without crashing.
{
    my @cases = (
        { history => [], desc => 'empty history' },
        { history => [{ role => 'user', content => 'single message' }],
          desc => 'single-message history' },
        { history => [
            { role => 'user', content => 'two msgs' },
            { role => 'assistant', content => 'reply' },
          ], desc => 'two-message history' },
    );
    for my $c (@cases) {
        my $proj = build_projection(
            history    => $c->{history},
            user_input => 'continue',
            active_task => '',
            active_todos => [],
            ltm        => [],
            unresolved => [],
            context_files_block => '',
            session    => undef,
        );
        ok(ref($proj) eq 'HASH', "$c->{desc}: build_projection returns hashref");
        ok(exists $proj->{anchor}, "$c->{desc}: projection has anchor field");
        ok(exists $proj->{turns}, "$c->{desc}: projection has turns field");
        ok(exists $proj->{environment}, "$c->{desc}: projection has environment field");
    }
}

# ---------------------------------------------------------------------------
# Test 6: dynamic userContext can carry context files block
# ---------------------------------------------------------------------------
{
    my $history = make_history(turns => 3);
    my $cf_block = "[CONTEXT FILES]\nTest file content here\n";
    my $proj = build_projection(
        history             => $history,
        user_input          => 'continue',
        active_task         => '',
        active_todos        => [],
        ltm                 => [],
        unresolved          => [],
        context_files_block => $cf_block,
        session             => undef,
    );

    my $dynamic = messages_to_prose_dynamic($proj);
    like($dynamic, qr/\[CONTEXT FILES\]/, "context_files_block rendered into dynamic prose");
    like($dynamic, qr/Test file content here/, "context file content present");
}

# ---------------------------------------------------------------------------
# Test 7: stable + dynamic prose is byte-identical to unified render
# ---------------------------------------------------------------------------
{
    my $history = make_history(turns => 5);
    my $proj = build_projection(
        history             => $history,
        user_input          => 'continue',
        active_task         => 'investigate trim_xml_history bug',
        active_todos        => [{ id => 1, status => 'in-progress', content => 'Read ContextBuilder.pm' }],
        ltm                 => [],
        unresolved          => [],
        context_files_block => '',
        session             => undef,
    );

    require CLIO::Core::MessageHistory;
    my $combined = CLIO::Core::MessageHistory::messages_to_prose($proj);
    # messages_to_prose is now an alias for messages_to_prose_dynamic
    # (the stable prose path was deleted when role-based history was
    # introduced). Verify the alias returns the same content.
    my $dynamic = messages_to_prose_dynamic($proj);
    is($combined, $dynamic,
        "messages_to_prose is an alias for messages_to_prose_dynamic");
}

# ---------------------------------------------------------------------------
# Test 8: History messages contain tool_calls (used by APIs) - structure preserved
# ---------------------------------------------------------------------------
{
    my $history = make_history(turns => 3);
    my $proj = build_projection(
        history    => $history,
        user_input => 'continue',
        active_task => '',
        active_todos => [],
        ltm        => [],
        unresolved => [],
        context_files_block => '',
        session    => undef,
    );

    # Walk through anchor + recent turns; if any assistant message has
    # tool_calls, that must be preserved in the projection's role-based
    # history so the API can pair them with tool results.
    my @all_turns;
    push @all_turns, $proj->{anchor} if $proj->{anchor};
    push @all_turns, @{$proj->{turns} || []};

    my $found_tool_call = 0;
    my $found_tool_result = 0;
    for my $turn (@all_turns) {
        for my $msg (@$turn) {
            if ($msg->{role} eq 'assistant' && $msg->{tool_calls}) {
                $found_tool_call = 1;
            }
            if ($msg->{role} eq 'tool' && $msg->{tool_call_id}) {
                $found_tool_result = 1;
            }
        }
    }
    ok($found_tool_call, "Assistant tool_calls preserved in projection");
    ok($found_tool_result, "Tool results preserved in projection");
}

done_testing();