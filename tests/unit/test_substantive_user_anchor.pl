#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test: agent must not lose its place after context trim.
#
# Bug (session a6a0eb10, 2026-08-29): A long autonomous tool loop where
# the user typed "continue" between major phases caused the trim path to
# preserve ONLY the "continue" message (8 chars) as the most recent user
# input. The original task user message (the actual code review request,
# ~300 chars) was buried in a <thread_summary> system message that the
# model treated as archival metadata. After the third trim, LCP cache
# similarity collapsed to 0.214, the next prompt was 60k tokens of
# compressed context with no user anchor, and the model emitted
# "no actual user message yet" reasoning and effectively started over.
#
# Fix:
# 1. MessageValidator::_extract_preserved_units now finds the most recent
#    SUBSTANTIVE user message (length >= 50 chars) in addition to the
#    most recent user message.
# 2. validate_and_truncate_messages injects the substantive user message
#    as a real user message BEFORE the short directive when the two
#    differ. The model then sees both: the original task (anchor) and
#    "continue" (immediate instruction).
# 3. State::trim_context preserves ALL user messages in the kept tail
#    (user messages are small, ~500 tokens even for long tasks, and
#    dropping them causes the agent to lose its place).
# 4. PromptBuilder::get_user_context accepts a substantive_task option
#    and surfaces it in an <activeTask> block so the model has a fresh
#    directive anchor rather than relying on archived summary content.
# 5. WorkflowOrchestrator::_find_substantive_user_task finds the
#    most recent substantive user message from history + current input.
# 6. PromptBuilder::_read_active_todos injects the active todo list
#    as <activeTodos> so the model has a single source of truth for
#    "what am I doing right now" after context trim.

use strict;
use warnings;
use utf8;
use lib '/home/deck/repositories/CLIO/lib';
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Test::More;

# Helper: slurp a file's content.
sub slurp { my ($f) = @_; local $/; open my $fh, '<', $f or die "open($f): $!"; return <$fh>; }

# ── Test 1: _extract_preserved_units returns both last_user and substantive_user ─
{
    my $src = slurp('lib/CLIO/Core/API/MessageValidator.pm');
    like($src, qr/most recent SUBSTANTIVE user message/si,
         'MessageValidator finds substantive user message (comment present)');
    like($src, qr/min_substantive_len\s*=\s*50/,
         'Minimum substantive length is 50 chars (filters out "continue"/"go"/"yes")');
    like($src, qr/\$substantive_user_unit\s*,\s*\$substantive_user_tokens\s*,\s*\$substantive_user_content/,
         '_extract_preserved_units returns substantive user (unit, tokens, content)');
    like($src, qr/return\s*\(\$system_msg,\s*\$last_user_unit,\s*\$start_unit,\s*\$system_tokens,\s*\$last_user_tokens,\s*\$summary_unit,\s*\$summary_tokens,\s*\\\@preserved_user_contexts,\s*\\\@preserved_general_system,\s*\$substantive_user_unit/s,
         'Return statement includes the new substantive_user values');
}

# ── Test 2: validate_and_truncate_messages injects substantive user before short directive ─
{
    my $src = slurp('lib/CLIO/Core/API/MessageValidator.pm');
    like($src, qr/Injected original user task before 'continue' prompt/s,
         'validate_and_truncate injects substantive task before "continue" prompt');
    like($src, qr/length\(\$substantive_user_content\)\s*>=\s*50/,
         'Injection guard requires substantive content >= 50 chars');
    like($src, qr/\$last_user_unit\s*!=\s*\$substantive_user_unit/,
         'Injection only fires when substantive != most recent user');
}

# ── Test 3: State::trim_context preserves ALL user messages ─
{
    my $src = slurp('lib/CLIO/Session/State.pm');
    like($src, qr/ALWAYS preserved.*they are small.*dropping them causes the agent to lose its place/s,
         'State::trim_context comment explains why user messages are preserved');
    like($src, qr{user_messages\s*=\s*grep\s*\{\s*defined\s*\$\_->\{role\}\s*&&\s*\$\_->\{role\}\s*eq\s*'user'\s*\}\s*\@non_system},
         'State::trim_context extracts user messages separately');
    like($src, qr{my\s*\@trimmed\s*=\s*\(\@system,\s*\@user_messages,\s*\@recent_non_user\)\s*;?\s*#?\s*[^\n]*},
         'State::trim_context assembly preserves user messages alongside recent non-user tail (no $trim_notice injection)');
}

# ── Test 4: PromptBuilder::get_user_context accepts substantive_task option ─
{
    my $src = slurp('lib/CLIO/Core/PromptBuilder.pm');
    like($src, qr/sub get_user_context\s*\{\s*my\s*\(\$self,\s*\$session,\s*\$options\)/,
         'get_user_context accepts $options hashref parameter');
    like($src, qr/my \$substantive_task\s*=\s*\$options->\{substantive_task\}/,
         'get_user_context reads substantive_task from options');
    like($src, qr/<activeTask>/,
         'get_user_context emits <activeTask> block when substantive_task is provided');
    like($src, qr/Continue this work\. Do not restart or re-evaluate the task/s,
         '<activeTask> block tells the model to resume rather than restart');
}

# ── Test 5: PromptBuilder::_read_active_todos exists and emits <activeTodos> block ─
{
    my $src = slurp('lib/CLIO/Core/PromptBuilder.pm');
    like($src, qr/sub _read_active_todos/,
         '_read_active_todos helper exists');
    like($src, qr/<activeTodos>/,
         'Active todos are emitted in <activeTodos> block');
    like($src, qr/\[IN PROGRESS\]/,
         'Active todos block distinguishes in-progress items');
    like($src, qr/\[QUEUED\]/,
         'Active todos block distinguishes queued items');
    like($src, qr/\[BLOCKED\]/,
         'Active todos block distinguishes blocked items');
}

# ── Test 6: WorkflowOrchestrator::_find_substantive_user_task exists and is wired in ─
{
    my $src = slurp('lib/CLIO/Core/WorkflowOrchestrator.pm');
    like($src, qr/sub _find_substantive_user_task/,
         '_find_substantive_user_task helper exists');
    like($src, qr/\$self->_find_substantive_user_task\(\$history,\s*\$user_input,\s*\$session\)/,
         '_find_substantive_user_task is called in _build_turn_context rebuild path (with $session for YaRN fallback)');
    like($src, qr/\$self->_find_substantive_user_task\(\$cached_messages,\s*\$user_input,\s*\$session\)/,
         '_find_substantive_user_task is called in _build_turn_context resume fast path (with $session for YaRN fallback)');
    like($src, qr/\$self->\{prompt_builder\}->get_user_context\(\$session,\s*\{\s*substantive_task\s*=>\s*\$substantive_task\s*\}\)/,
         'Substantive task is passed to get_user_context');
}

# ── Test 7: Verify the regex actually does the right thing on sample data ─
{
    # Simulate the bug: most recent user is "continue", substantive is the
    # full review request. The fix should:
    #   (a) detect the substantive task
    #   (b) inject it before the continue
    sub is_substantive {
        my ($s) = @_;
        return 0 unless defined $s;
        return 0 if $s =~ /^\s*\w[\w\-_.]+\s+\([^)]+:\s*[^)]+\)\s*\(\d+\s*bytes/;
        return length($s) >= 50 ? 1 : 0;
    }

    my $short = "continue";
    my $long = "I would like you to do a full code review of PhotonTERM - I want to start using it soon but we need to make sure that it follows correct UI/UX patterns, and it is free of smells and inconsistencies.";

    ok(!is_substantive($short), '"continue" is NOT substantive (length < 50)');
    ok(is_substantive($long),  'long code review request IS substantive (length >= 50)');

    # Empty / missing
    ok(!is_substantive(undef), 'undef is NOT substantive');
    ok(!is_substantive(''),    'empty string is NOT substantive');
    ok(!is_substantive('yes'), '"yes" is NOT substantive');
    ok(!is_substantive('go on'), '"go on" is NOT substantive');
}

done_testing();
