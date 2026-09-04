#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Tests for CLIO::Core::MessageHistory::messages_to_prose
#
# Verifies the prose renderer:
# - Consumes the ContextBuilder projection structure correctly
# - Emits no XML tags (the whole point of prose)
# - Drops framework narration (tier labels, footers, session id, etc.)
# - Renders tool calls as delimited prose blocks
# - Is deterministic across runs
# - Has a cache-stable prefix (the # Task block + # Earlier work)

use strict;
use warnings;
use utf8;

use Test::More;
use CLIO::Core::ContextBuilder ();
use CLIO::Core::MessageHistory qw(messages_to_prose);

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

sub make_fragment {
    return (
        { role => 'user', content => 'Fix the qa-messageHistory-fix bug. We need to stop the messageHistory XML from leaking framework narration.' },
        { role => 'assistant', content => 'Reading the serializer.', tool_calls => [
            { id => 'tc1', type => 'function', function => { name => 'file_operations', arguments => '{"operation":"read_file","path":"lib/CLIO/Core/MessageHistory.pm"}' } }
        ]},
        { role => 'tool', tool_call_id => 'tc1', content => 'package CLIO::Core::MessageHistory; ... [8000 chars] ...' },
        # The follow-up user message is a fresh question (NOT a
        # continuation prompt) so the cross-turn dedup doesn't fire
        # and we can verify both turns appear in the prose.
        { role => 'user', content => 'What does the messages_to_xml function actually do?' },
        { role => 'assistant', content => 'Inspecting it.', tool_calls => [
            { id => 'tc2', type => 'function', function => { name => 'file_operations', arguments => '{"operation":"read_file","path":"lib/CLIO/Core/MessageHistory.pm"}' } }
        ]},
        { role => 'tool', tool_call_id => 'tc2', content => 'package CLIO::Core::MessageHistory; ... [8000 chars] ...' },
    );
}

sub build_projection {
    my (%overrides) = @_;
    my @fragment = make_fragment();
    my @ltm = (
        { confidence => 0.92, type => 'pattern', content => 'messageHistory XML serialization pattern prompt caching' },
        { confidence => 0.85, type => 'pattern', content => 'framework narration in user context causes model to call memory_operations recovery' },
        { confidence => 0.50, type => 'discovery', content => 'unrelated thing' },
    );
    return CLIO::Core::ContextBuilder::build_projection(
        history       => \@fragment,
        user_input    => 'fix the messageHistory XML serialization bug narration leakage',
        active_task   => 'fix the qa-messageHistory-fix bug stop framework narration leakage',
        active_todos  => [ { id => 1, status => 'in_progress', content => 'verify prose rendering' } ],
        ltm           => \@ltm,
        unresolved    => [],
        budget_tokens => 8000,
        %overrides,
    );
}

# ---------------------------------------------------------------------------
# 1. Smoke test
# ---------------------------------------------------------------------------

my $projection = build_projection();
my $prose = messages_to_prose($projection);

ok(defined $prose && length($prose), 'messages_to_prose returns non-empty string');
# messages_to_prose is now an alias for messages_to_prose_dynamic -
# the "stable" prose sections (Task, Recent work) are pushed as
# role-based messages by WorkflowOrchestrator, not as prose. So the
# dynamic-only test ensures we don't accidentally regress to
# rendering stable content as prose (which would invalidate the
# cache-stable prefix design).
like($prose, qr/# Environment\n/, 'starts with # Environment (dynamic-only renderer)');

# ---------------------------------------------------------------------------
# 2. No XML tags
# ---------------------------------------------------------------------------

for my $tag (qw(
    <messageHistory> <messageHistory/> </messageHistory>
    <turn > </turn>
    <userMessage> </userMessage>
    <assistantMessage> </assistantMessage>
    <tools> </tools>
    <tool > </tool>
    <arguments> </arguments>
    <result> </result>
    <resultDigest> </resultDigest>
    <userContext> </userContext>
    <activeTask> </activeTask>
    <activeTodos> </activeTodos>
    <activeTodo > </activeTodo>
    <unresolvedState> </unresolvedState>
    <relevantMemory > </relevantMemory>
    <memory > </memory>
    <environment> </environment>
    <dateTime > </dateTime>
    <workingDirectory> </workingDirectory>
    <language> </language>
)) {
    unlike($prose, qr/\Q$tag\E/, "no XML tag '$tag' in prose output");
}

# ---------------------------------------------------------------------------
# 3. No framework narration
# ---------------------------------------------------------------------------

for my $forbidden (
    'After context trimming',
    '[UNVERIFIED]',
    '[TRUSTED]',
    'Showing X of Y',
    'Showing 12 of 55',
    'informational context only',
    'do not reference or repeat',
    'memory_operations(recall_sessions)',
    # 'memory_operations(operation: "search"' is now an intentional
    # affordance in the dynamic userContext (H3: on-demand LTM
    # search). The model is told to call it when relevant entries
    # are filtered out. The affordance is hard-coded in the prose
    # renderer (NOT run through sanitize_narration) so the literal
    # tool name reaches the model.
    'use memory_operations',
    '**Session ID:**',
    '<dynamicContext>',
    '</dynamicContext>',
) {
    unlike($prose, qr/\Q$forbidden\E/, "no framework narration '$forbidden' in prose output");
}

# ---------------------------------------------------------------------------
# 4. Required sections present
# ---------------------------------------------------------------------------

# The # Task and # Recent work sections are no longer rendered by
# messages_to_prose (the role-based history path pushes them as
# individual messages). The dynamic-only renderer is what's tested
# below.
unlike($prose, qr/^# Task\n/, 'does NOT render # Task (stable content pushed as role-based messages)');
unlike($prose, qr/# Recent work/, 'does NOT render # Recent work (stable content pushed as role-based messages)');
unlike($prose, qr/## Turn 1\n/, 'does NOT render per-turn prose blocks (role-based messages do this)');
unlike($prose, qr/User: Fix the qa-messageHistory-fix bug/, 'does NOT render anchor user content as prose');
like($prose, qr/# Active todos\n/, '# Active todos section present');
like($prose, qr/- \[in_progress\] verify prose rendering\b/, 'todo rendered with status only (no internal id)');
like($prose, qr/# Environment\n/, '# Environment section present');
like($prose, qr/Working directory: /, 'environment has working directory');
like($prose, qr/Language: /, 'environment has language');
like($prose, qr/Date: \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/, 'environment has ISO timestamp');

# DELETED in this commit: tests 5-8 verified the prose renderer
# rendered tool calls and the cache-stable # Task block. The role-based
# history refactor pushed anchor + recent turns as role-based messages
# rather than prose, so the prose renderer is now dynamic-only. These
# assertions no longer apply. Test 9 (empty projection) and test 10
# (missing optional fields) below are still meaningful.

# ---------------------------------------------------------------------------
# 6. Determinism: same input -> same output
# ---------------------------------------------------------------------------

my $p1 = messages_to_prose(build_projection());
my $p2 = messages_to_prose(build_projection());
is($p1, $p2, 'messages_to_prose is deterministic across runs');

# ---------------------------------------------------------------------------
# 7. Dynamic-only rendering: no # Task or # Recent work sections
# ---------------------------------------------------------------------------

# The cache-stable prefix (anchor + recent turns) is now pushed as
# role-based messages, not as prose. Verify the prose renderer stays
# dynamic-only.
unlike($p1, qr/^# Task\b/m, 'Prose renderer does NOT emit # Task (now role-based)');
unlike($p1, qr/^# Recent work\b/m, 'Prose renderer does NOT emit # Recent work (now role-based)');
unlike($p1, qr/Tool call:/, 'Prose renderer does NOT render tool calls (now role-based)');
unlike($p1, qr/Args: /, 'Prose renderer does NOT render tool args (now role-based)');
like($p1, qr/# Environment/, 'Prose renderer still emits # Environment');

# ---------------------------------------------------------------------------
# 8. Tool result truncation
# ---------------------------------------------------------------------------
# DELETED: tool results are now part of the role-based messages
# (not prose). Truncation happens in ConversationManager / role-based
# tail walk, not the prose renderer.

# ---------------------------------------------------------------------------
# 9. Empty projection is safe
# ---------------------------------------------------------------------------

my $empty = messages_to_prose({});
ok(defined $empty, 'empty projection returns defined output');
is(length($empty), 0, 'empty projection returns empty string');

# ---------------------------------------------------------------------------
# 10. Missing optional fields don't crash
# ---------------------------------------------------------------------------

# Minimal projection: only the dynamic userContext fields. Anchor and
# turns are now role-based, so passing them to messages_to_prose has
# no effect (the renderer is dynamic-only). The result is an empty
# string (no dynamic sections either).
my $minimal_proj = {
    anchor => [ { role => 'user', content => 'just a task' } ],
};
my $minimal = messages_to_prose($minimal_proj);
is(length($minimal), 0, 'minimal projection (no dynamic fields) renders empty');

# ---------------------------------------------------------------------------
# 11. messages_to_prose is an alias for messages_to_prose_dynamic
# ---------------------------------------------------------------------------
# The split (stable + dynamic) was deleted when role-based history
# was introduced. messages_to_prose is now a thin alias.
my $dynamic_only = CLIO::Core::MessageHistory::messages_to_prose_dynamic($projection);
is($prose, $dynamic_only, 'messages_to_prose == messages_to_prose_dynamic');

done_testing();