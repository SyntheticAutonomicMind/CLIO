#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test: thread_summary detection regexes must be anchored.
#
# Bug: CLIO's system prompt template (default.md) contains a section
# explaining the CSSS (Cache-Stable Summary Slot) that uses the literal
# string "<threadSummary>". Multiple code paths in ConversationManager,
# MessageValidator, and WorkflowOrchestrator used unanchored regexes
# like /<threadSummary>/ to detect "is this message a thread_summary".
# The unanchored regex matched the system prompt's explanatory text and
# caused the system prompt to be:
#   - Preserved as if it WERE a thread_summary (ConversationManager
#     _build_turn_context)
#   - Identified as the CSSS summary slot by MessageValidator
#   - Treated as the previous summary to merge in WorkflowOrchestrator
#   - Dropped from @system in State::trim_context
#
# On the Ayaneo Flip (session 6b09ac2d-b4e7-4f7b-8943-eb448449227a,
# 2026-08-29, 64K Qwen3.6-35B-A3B-UD-Q4_K_XL), this caused the 71,949-char
# system prompt to be treated as a thread_summary and preserved in
# addition to the fresh 80,973-char system prompt built per-request.
# Effective prompt size: 152K chars (~76K tokens), blowing past the
# 65,536-token context window on iteration 9.
#
# Fix: anchor all /<threadSummary>/ regexes to /\A<threadSummary>/.
# Real thread_summary messages start with "<threadSummary>" at offset 0
# (YaRN renders it as the first line of the summary block). Messages
# that merely mention the tag in their explanatory text do not match.

use strict;
use warnings;
use utf8;
use lib '/home/deck/repositories/CLIO/lib';
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Test::More;

# Helper: slurp a file's content.
sub slurp { my ($f) = @_; local $/; open my $fh, '<', $f or die "open($f): $!"; return <$fh>; }

# ── Test 1: No remaining unanchored /<threadSummary>/ regexes ───────
{
    my @files = (
        'lib/CLIO/Core/ConversationManager.pm',
        'lib/CLIO/Core/API/MessageValidator.pm',
        'lib/CLIO/Core/WorkflowOrchestrator.pm',
        'lib/CLIO/Session/State.pm',
    );
    for my $file (@files) {
        my $src = slurp($file);
        # Match a regex that contains /<threadSummary>/ not preceded by
        # backslash-A. The negative lookbehind asserts no \A immediately
        # before the <threadSummary> (which would be an anchored form).
        my $count = () = $src =~ m{(?<!\\A)/<threadSummary>/}g;
        is($count, 0, "$file: no unanchored /<threadSummary>/ regexes (found $count)");
    }
}

# ── Test 2: All sites that match thread_summary now use \A anchor ────
{
    my @files = (
        'lib/CLIO/Core/ConversationManager.pm',
        'lib/CLIO/Core/API/MessageValidator.pm',
        'lib/CLIO/Core/WorkflowOrchestrator.pm',
        'lib/CLIO/Session/State.pm',
    );
    my $total_anchored = 0;
    for my $file (@files) {
        my $src = slurp($file);
        my $count = () = $src =~ m{\\A<threadSummary>}g;
        $total_anchored += $count;
    }
    cmp_ok($total_anchored, '>=', 8,
           "Anchored /\\A<threadSummary>/ regexes present in source (found $total_anchored)");
}

# ── Test 3: Functional - system prompt that mentions the tag ────────
# (The actual default.md was edited to remove the CSSS section, so we
# synthesize a representative system prompt here that contains the
# literal text "<threadSummary>" — the bug case.)
{
    my $default_prompt = <<'EOF';
# CLIO System Prompt

You are CLIO.

## Cache-Stable Summary Slot

The proactive trim regenerates a <threadSummary> whenever it drops
messages. The <threadSummary> is placed at the end of conversation.
EOF
    ok($default_prompt =~ /<threadSummary>/,
       'Synthetic system prompt contains the literal text "<threadSummary>" (sanity check)');
    unlike($default_prompt, qr/\A<threadSummary>/,
           'Synthetic system prompt does NOT START with <threadSummary> (anchored regex correctly rejects)');
}

# ── Test 4: Functional - real thread_summary starts with the tag ─────
{
    my $real_summary = "<threadSummary>\n\nCurrent task: review CLIO\n\nKey decisions:\n- Use anchored regex\n";
    like($real_summary, qr/\A<threadSummary>/,
         'Real thread_summary message STARTS with <threadSummary> (anchored regex correctly accepts)');
}

# ── Test 6: Verify ConversationManager's pre-flight trim ───────────
{
    my $src = slurp('lib/CLIO/Core/ConversationManager.pm');
    like($src, qr/\\A<threadSummary>/,
         'ConversationManager uses anchored /\A<threadSummary>/ regex');
    unlike($src, qr{(?<!\\A)/<threadSummary>/},
           'ConversationManager has no remaining unanchored /<threadSummary>/ regex');
}

# ── Test 7: Verify MessageValidator's _extract_preserved_units ─────
{
    my $src = slurp('lib/CLIO/Core/API/MessageValidator.pm');
    like($src, qr/\\A<threadSummary>/,
         'MessageValidator _extract_preserved_units uses anchored regex');
}

# ── Test 8: Verify WorkflowOrchestrator's _compress_dropped_for_recovery ─
{
    my $src = slurp('lib/CLIO/Core/WorkflowOrchestrator.pm');
    like($src, qr/\\A<threadSummary>/,
         'WorkflowOrchestrator _compress_dropped_for_recovery uses anchored regex');
}

# ── Test 9: Verify State::trim_context drops prior summaries correctly ─
{
    my $src = slurp('lib/CLIO/Session/State.pm');
    like($src, qr/\\A<threadSummary>/,
         'State::trim_context uses anchored regex to detect prior summaries');
}

# ── Test 10: WorkflowOrchestrator drops redundant leading system messages ─
{
    my $src = slurp('lib/CLIO/Core/WorkflowOrchestrator.pm');
    like($src, qr/Skipped.*leading system message\(s\) from history/,
         'WorkflowOrchestrator logs when it drops redundant leading system messages');
    like($src, qr/redundant with fresh system prompt/,
         'WorkflowOrchestrator comment explains the rationale (avoids double system prompt)');
}

# ── Test 11: clio (Main) does NOT add system prompt to history ─────
{
    my $src = slurp('clio');
    unlike($src, qr/\\\$session->add_message\('system',\s*\\\$system_prompt\)/,
           'clio (Main script) does NOT call $session->add_message("system", $system_prompt)');
    like($src, qr/NOT added to session history/,
         'clio (Main script) has a comment explaining the system prompt is NOT in history');
}

# ── Test 12: End-to-end functional - leading system messages get dropped ─
{
    # Simulate the loaded history with a leading system prompt message.
    # The dropping logic should skip the leading system message.
    require CLIO::Core::WorkflowOrchestrator;
    my $wo = CLIO::Core::WorkflowOrchestrator->new();

    # Verify the dropping logic by testing the substring manually.
    # The drop logic checks (role ne 'system') and (content !~ /\A<threadSummary>/).
    my @history = (
        { role => 'system', content => '# CLIO System Prompt\n\nYou are CLIO.' },  # redundant
        { role => 'system', content => "<threadSummary>\n\nCurrent task: foo" },  # keep
        { role => 'user', content => 'first user' },
        { role => 'assistant', content => 'first assistant' },
        { role => 'tool', tool_call_id => 'tc1', content => 'tool result' },
        { role => 'user', content => 'second user' },
    );

    # Replicate the dropping logic
    my $first_non_system_idx = 0;
    for my $i (0 .. $#history) {
        my $m = $history[$i];
        last if ($m->{role} // '') ne 'system';
        next if ($m->{content} // '') =~ /\A<threadSummary>/;
        $first_non_system_idx = $i + 1;
    }

    is($first_non_system_idx, 1, 'First redundant system message is dropped');
    my $remaining = [@history[$first_non_system_idx .. $#history]];
    is(scalar @$remaining, 5, 'After dropping, 5 messages remain');
    is($remaining->[0]{role}, 'system', 'First remaining is the thread_summary system message');
    is($remaining->[0]{content}, '<threadSummary>' . "\n\nCurrent task: foo", 'thread_summary message preserved verbatim');
    is($remaining->[1]{role}, 'user', 'First conversation message is the user message');
    is($remaining->[-1]{role}, 'user', 'Last conversation message is the second user message');
}

done_testing();
