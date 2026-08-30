#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test: the reactive-trim recovery path (_compress_dropped_for_recovery
# in WorkflowOrchestrator) must contain ONLY work product — no framework
# narration about "what the framework did" or "how to recover".
#
# The recovery content is injected as a user message that the model MUST
# respond to, so any meta-commentary primes the model to second-guess its
# own state, re-verify assumptions, and sometimes abandon productive
# trajectories entirely.

use strict;
use warnings;
use utf8;
use lib '/home/deck/repositories/CLIO/lib';
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Test::More;

# Helper: slurp a file's content.
sub slurp { my ($f) = @_; local $/; open my $fh, '<', $f or die "open($f): $!"; return <$fh>; }

my $wo = slurp('lib/CLIO/Core/WorkflowOrchestrator.pm');

# ── No framework narration in the recovery content ─────────────────────
{
    # These phrases were in the OLD recovery template and must not exist.
    my @forbidden = (
        qr/Older conversation history has been summarized below/,
        qr/Continue your current work - do not announce/,
        qr/Continue working on whatever you were doing/,
        qr/Do NOT say things like/,
        qr/I've recovered context/,
        qr/Let me review what happened/,
        qr/Use todo_operations and git tools for details/,
        qr/review your recent tool results and proceed/,
        qr/You were actively using tools/,
        qr/appear to have stopped mid-workflow/,
    );

    for my $phrase (@forbidden) {
        unlike($wo, $phrase,
               "Recovery: no framework narration phrase ($phrase)");
    }
}

# ── Recovery tags still have the disclaimer ─────────────────────────────
{
    like($wo, qr/<currentTopic>.+do not reference or repeat/s,
         'Recovery: currentTopic has disclaimer');
    like($wo, qr/<taskRecovery>.+do not reference or repeat/s,
         'Recovery: taskRecovery has disclaimer');
    like($wo, qr/<recentContext>.+do not reference or repeat/s,
         'Recovery: recentContext has disclaimer');
    like($wo, qr/<gitRecovery>.+do not reference or repeat/s,
         'Recovery: gitRecovery has disclaimer');
    like($wo, qr/<sessionProgress>.+do not reference or repeat/s,
         'Recovery: sessionProgress has disclaimer');
}

# ── Recovery content is built from work product only ────────────────────
{
    # The @recovery_parts should still be populated (work product).
    like($wo, qr/push \@recovery_parts, "<currentTopic>"/,
         'Recovery still pushes <currentTopic>');
    like($wo, qr/push \@recovery_parts, "<taskRecovery>"/,
         'Recovery still pushes <taskRecovery>');
    like($wo, qr/push \@recovery_parts, "<recentContext>"/,
         'Recovery still pushes <recentContext>');
    like($wo, qr/push \@recovery_parts, "<gitRecovery>"/,
         'Recovery still pushes <gitRecovery>');
    like($wo, qr/push \@recovery_parts, "<sessionProgress>"/,
         'Recovery still pushes <sessionProgress>');

    # @final_parts should NOT have framework narration lines.
    unlike($wo, qr/push \@final_parts, "Older conversation history/,
           'Recovery: no "Older conversation history" push to @final_parts');
    unlike($wo, qr/push \@final_parts, "Continue your current work/,
           'Recovery: no "Continue your current work" push to @final_parts');
    unlike($wo, qr/push \@final_parts, "IMPORTANT: Continue working/,
           'Recovery: no "IMPORTANT: Continue working" push to @final_parts');
    unlike($wo, qr/push \@final_parts, "\$recovery_content = \$user_context/,
           'Recovery: user_context is prepended after final_parts is built, not as narration');
}

done_testing();
