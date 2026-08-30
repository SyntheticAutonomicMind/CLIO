#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test: tag naming is standardized to camelCase.
# Context tags use camelCase (threadSummary, userContext, activeTask,
# sessionGoals, activeTodos, dynamicContext) and recovery section tags
# (currentTopic, taskRecovery, recentContext, gitRecovery, sessionProgress).
#
# Old lowercase tags (thread_summary, user_context, active_task, etc.)
# must never appear in model-facing output.

use strict;
use warnings;
use utf8;
use lib '/home/deck/repositories/CLIO/lib';
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Test::More;

# Helper: slurp a file's content.
sub slurp { my ($f) = @_; local $/; open my $fh, '<', $f or die "open($f): $!"; return <$fh>; }

# ── No old lowercase tags in model-facing source ─────────────────────
{
    # These files generate or match tags that the model sees.
    my @model_facing = (
        'lib/CLIO/Core/WorkflowOrchestrator.pm',
        'lib/CLIO/Core/API/MessageValidator.pm',
        'lib/CLIO/Core/ConversationManager.pm',
        'lib/CLIO/Core/PromptBuilder.pm',
        'lib/CLIO/Memory/YaRN.pm',
        'lib/CLIO/Util/TextSanitizer.pm',
        'lib/CLIO/Session/State.pm',
        'lib/CLIO/Core/prompts/default.md',
    );

    my @old_tags = (
        '<thread_summary',
        '</thread_summary',
        '<user_context',
        '</user_context',
        '<active_task',
        '</active_task',
        '<session_goals',
        '</session_goals',
        '<active_todos',
        '</active_todos',
        '<current_topic',
        '</current_topic',
        '<task_recovery',
        '</task_recovery',
        '<recent_context',
        '</recent_context',
        '<git_recovery',
        '</git_recovery',
        '<session_progress',
        '</session_progress',
    );

    for my $file (@model_facing) {
        my $content = slurp($file);
        for my $tag (@old_tags) {
            is(index($content, $tag), -1,
               "$file: no old lowercase tag '$tag'");
        }
    }
}

# ── New camelCase tags present in generation code ────────────────────
{
    my $yarn = slurp('lib/CLIO/Memory/YaRN.pm');
    like($yarn, qr/<threadSummary>.*?<\/threadSummary>/s,
         'YaRN generates <threadSummary>...</threadSummary>');

    my $mv = slurp('lib/CLIO/Core/API/MessageValidator.pm');
    like($mv, qr/<threadSummary>/,
         'MessageValidator _make_anchor_summary uses <threadSummary>');

    my $pb = slurp('lib/CLIO/Core/PromptBuilder.pm');
    like($pb, qr/<activeTask>/,      'PromptBuilder generates <activeTask>');
    like($pb, qr/<sessionGoals>/,     'PromptBuilder generates <sessionGoals>');
    like($pb, qr/<activeTodos>/,      'PromptBuilder generates <activeTodos>');
    like($pb, qr/<dynamicContext>/,  'PromptBuilder generates <dynamicContext>');
    like($pb, qr/<userContext>/,      'PromptBuilder generates <userContext>');
}

# ── Recovery tags are camelCase in WorkflowOrchestrator ────────────────
{
    my $wo = slurp('lib/CLIO/Core/WorkflowOrchestrator.pm');
    like($wo, qr/<currentTopic>/,        'Recovery uses <currentTopic>');
    like($wo, qr/<taskRecovery>/,        'Recovery uses <taskRecovery>');
    like($wo, qr/<recentContext>/,       'Recovery uses <recentContext>');
    like($wo, qr/<gitRecovery>/,        'Recovery uses <gitRecovery>');
    like($wo, qr/<sessionProgress>/,     'Recovery uses <sessionProgress>');
}

# ── TextSanitizer strips ALL tags (old and new) ───────────────────────
{
    my $ts = slurp('lib/CLIO/Util/TextSanitizer.pm');
    like($ts, qr{<threadSummary>.+?<\\/threadSummary>}s,
         'TextSanitizer strips <threadSummary>');
    like($ts, qr{<activeTask>.+?<\\/activeTask>}s,
         'TextSanitizer strips <activeTask>');
    like($ts, qr{<activeTodos>.+?<\\/activeTodos>}s,
         'TextSanitizer strips <activeTodos>');
    like($ts, qr{<currentTopic>.+?<\\/currentTopic>}s,
         'TextSanitizer strips <currentTopic>');
    like($ts, qr{<gitRecovery>.+?<\\/gitRecovery>}s,
         'TextSanitizer strips <gitRecovery>');
    like($ts, qr{<sessionProgress>.+?<\\/sessionProgress>}s,
         'TextSanitizer strips <sessionProgress>');
}

# ── Functional: YaRN render contains the disclaimer ────────────────────
{
    require CLIO::Memory::YaRN;
    my $yarn = CLIO::Memory::YaRN->new();

    # Build a minimal bucket and render it.
    my $bucket = {
        user_requests           => ['Fix a bug in the router'],
        commits                 => [],
        files_touched           => [],
        decisions               => [],
        collaboration_exchanges => [],
        tool_counts             => {},
        persisted_chunks        => [],
    };

    my $flat = test_yarn_render($yarn, $bucket,
        original_task => 'Fix a bug in the router module on the CLIO codebase',
        carried_task  => '',
        carried_original => '',
    );
    like($flat, qr/<threadSummary>/,
         'Flat render starts with <threadSummary>');
    like($flat, qr/<\/threadSummary>/,
         'Flat render ends with </threadSummary>');
    like($flat, qr/do not reference or repeat/,
         'Thread summary contains the disclaimer');
    like($flat, qr/Current task:.*Fix a bug/,
         'Thread summary contains Current task line');
}

# Helper to call the internal renderer.
sub test_yarn_render {
    my ($yarn, $bucket, %opts) = @_;
    return CLIO::Memory::YaRN::_render_flat_summary($bucket, %opts);
}

done_testing();
