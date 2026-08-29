#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test: model-facing content must never expose framework-internal
# events (trim notifications, recovery instructions, [SYSTEM: ...] nudge
# prefixes) that would prime the model to second-guess its own state.
#
# Background: When the model sees structural metadata like
#   [CONTEXT TRIM: 12 messages compressed]
#   "To recover more context: 1. memory_operations(...)..."
# it becomes uncertain about its own state, re-verifies assumptions, and
# sometimes abandons productive trajectories entirely. The same applies to
# the "[SYSTEM: Your previous response ended without completing your work...]"
# nudge that was injected when the model stopped mid-workflow.
#
# The fix: keep only the work product (the YaRN <thread_summary> block,
# the original task, the current todo state) and strip every meta-message
# about "what the framework did" or "how to recover".

use strict;
use warnings;
use utf8;
use lib '/home/deck/repositories/CLIO/lib';
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Test::More;

# Helper: slurp a file's content.
sub slurp { my ($f) = @_; local $/; open my $fh, '<', $f or die "open($f): $!"; return <$fh>; }

# ── Smell 1: Session::State::trim_context no longer injects trim notices ─
{
    my $state = slurp('lib/CLIO/Session/State.pm');

    # The trim notice builder block should be gone.
    unlike($state, qr/Build trim notification/,
           'Session/State.pm no longer builds a trim notification message');
    unlike($state, qr/To recover more context:/,
           'Session/State.pm no longer emits "To recover more context:" instructions');
    unlike($state, qr/To recover context, use these in order:/,
           'Session/State.pm no longer emits "To recover context, use these in order:" instructions');
    unlike($state, qr/DO NOT read handoff documents in ai-assisted\//,
           'Session/State.pm no longer emits the "DO NOT read handoff documents" warning');
    unlike($state, qr/\$trim_notice\s*=\s*\{/,
           'Session/State.pm no longer creates a $trim_notice hash');

    # The work product (YaRN summary) is still injected as a system message.
    like($state, qr/push \@system, \{\s*role\s*=>\s*'system',\s*content\s*=>\s*\$compressed_summary/s,
         'Session/State.pm still injects the YaRN <thread_summary> as a system message');

    # Stale prior summaries are removed to avoid double-summary bloat.
    like($state, qr/<thread_summary>/,
         'Session/State.pm detects prior <thread_summary> messages to replace them');
}

# ── Smell 2: PromptManager LTM section no longer references trim ─────
{
    my $pm = slurp('lib/CLIO/Core/PromptManager.pm');
    unlike($pm, qr/After context trimming, use these patterns/s,
           'PromptManager no longer emits the "After context trimming" LTM line');
}

# ── Smell 3: System prompt no longer describes the trim system ────────
{
    my $prompt = slurp('lib/CLIO/Core/prompts/default.md');
    unlike($prompt, qr/## Context Survival Across Trims/,
           'default.md no longer has the "Context Survival Across Trims" section');
    unlike($prompt, qr/Goals survive context trimming/s,
           'default.md no longer tells the model that goals survive context trimming');
    unlike($prompt, qr/automatically preserves.*across context trimming/s,
           'default.md no longer describes the trim preservation system to the model');
    unlike($prompt, qr/Session Goals \(user context, not system prompt\)/s,
           'default.md no longer mentions the user-context-vs-system-prompt split');
}

# ── Smell 4: Premature-stop nudge is neutral, not framework metadata ──
{
    my $wo = slurp('lib/CLIO/Core/WorkflowOrchestrator.pm');

    # The push site should be neutral.
    unlike($wo, qr/content\s*=>\s*"\Q[SYSTEM: Your previous response ended without completing your work.\E/,
           'Premature-stop nudge no longer has the [SYSTEM: ...] framework prefix');
    unlike($wo, qr/You were actively using tools and appear to have stopped mid-workflow/,
           'Premature-stop nudge no longer tells the model "you were actively using tools"');
    unlike($wo, qr/review your recent tool results and proceed with your plan/,
           'Premature-stop nudge no longer tells the model to "review recent tool results"');

    # The replacement is neutral and clean.
    like($wo, qr/content\s*=>\s*"Please continue\."/,
         'Premature-stop nudge is now a neutral "Please continue."');

    # The strip function should still strip the legacy form (backward compat)
    # AND the new neutral form.
    like($wo, qr/\^Please continue\\\.\\s\*\$/,
         '_strip_continuation_nudges matches the neutral nudge');
    like($wo, qr/\\\[SYSTEM: Your previous response ended without completing your work/,
         '_strip_continuation_nudges still matches the legacy [SYSTEM: ...] form for backward compat');
}

# ── Functional: the YaRN summary itself is still a self-contained block ─
{
    # Sanity check: the YaRN summary format is still a work-product block,
    # not a meta-message about the trim event.
    my $yarn = slurp('lib/CLIO/Memory/YaRN.pm');
    like($yarn, qr/<thread_summary>/,
         'YaRN summary still uses <thread_summary>...</thread_summary> format (work product)');
    like($yarn, qr/Current task:/,
         'YaRN summary still contains the "Current task:" work-product line');
}

# ── No new framework-leak terms in model-facing paths ────────────────
{
    # Search all model-facing content (default.md, prompts, system prompt
    # template fragments) for the previously-leaked terms.
    my @model_facing = (
        'lib/CLIO/Core/prompts/default.md',
    );
    for my $file (@model_facing) {
        my $content = slurp($file);
        unlike($content, qr/\[SYSTEM: /,
               "$file: no [SYSTEM: ...] tags");
        unlike($content, qr/CONTEXT TRIM/,
               "$file: no CONTEXT TRIM markers");
        unlike($content, qr/archive[d]?\b.*messages|archived to YaRN|session was trimmed/i,
               "$file: no 'messages archived to YaRN' style leak");
    }
}

done_testing();
