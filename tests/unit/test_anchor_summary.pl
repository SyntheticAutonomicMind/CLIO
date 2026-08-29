#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test: thread_summary anchor is emitted on the very first
# turn (before any trim has fired) so the model has a stable work-product
# reference for the original task across turns.
#
# Bug: Without the anchor summary, the model falls back to the "Session
# Start Protocol" template from default.md on every turn because it has
# no other way to orient itself after the original task drops out of
# the context. Observed in sessions 00128874 (Ayaneo Flip, Qwen3.6-35B
# UD-Q4_K_XL) and 6b09ac2d (PhotonTERM, Laguna-S-2.1-UD): the model
# emitted "Let me start by following the Session Start Protocol and
# then systematically examine the codebase" 8+ turns in, with no
# thread_summary ever present, because the budget walk never dropped
# anything (every individual unit fit, so no summary was generated).
#
# Fix: When no summary exists AND no units were dropped, generate a
# minimal anchor summary from the most recent substantive user task.
# The anchor is "<thread_summary>\n\nCurrent task: X\n\n</thread_summary>"
# (~44 tokens for a typical task), small enough to fit in the budget
# even on 64K-context models, and stable enough to anchor the model
# across turns.

use strict;
use warnings;
use utf8;
use lib '/home/deck/repositories/CLIO/lib';
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Test::More;
use CLIO::Core::API::MessageValidator;

# ── Test 1: _make_anchor_summary produces a thread_summary block ─────
{
    my $r = CLIO::Core::API::MessageValidator::_make_anchor_summary(
        'I would like you to do a full QA audit of the CLIO codebase'
    );
    ok($r, '_make_anchor_summary returns a result for a substantive task');
    is($r->{role}, 'system', 'Anchor summary has role=system');
    like($r->{content}, qr/\A<thread_summary>/, 'Anchor content starts with <thread_summary>');
    like($r->{content}, qr/Current task: /, 'Anchor content has "Current task:" line');
    like($r->{content}, qr/<\/thread_summary>/, 'Anchor content has closing </thread_summary> tag');
    is($r->{_metadata}{anchor_summary}, 1, 'Anchor summary marker is set in _metadata');
}

# ── Test 2: Anchor summary is small enough for 64K context ─────────
{
    my $r = CLIO::Core::API::MessageValidator::_make_anchor_summary(
        'I would like you to do a full QA audit of the CLIO codebase - examine everything, report your findings'
    );
    my $tokens = $r->{_metadata}{compressed_tokens};
    cmp_ok($tokens, '<', 100, "Anchor summary tokens ($tokens) under 100 (fits 64K context)");
}

# ── Test 3: Anchor summary is undef for empty input only ────────────
{
    is(CLIO::Core::API::MessageValidator::_make_anchor_summary(undef),
       undef, 'undef input returns undef');
    is(CLIO::Core::API::MessageValidator::_make_anchor_summary(''),
       undef, 'empty string returns undef');
    my $r = CLIO::Core::API::MessageValidator::_make_anchor_summary('x');
    ok(defined $r, '1-char string still produces a summary (degenerate but not undef)');
}

# ── Test 4: Anchor summary is anchored to start of content (CSSS) ────
{
    # The legacy /<thread_summary>/ substring match would catch the
    # system prompt's CSSS section. The anchor regex /\A<thread_summary>/
    # (anchored) only matches messages that ARE a thread_summary.
    my $r = CLIO::Core::API::MessageValidator::_make_anchor_summary('test task');
    like($r->{content}, qr/\A<thread_summary>/,
         'Anchor content starts with <thread_summary> (anchored match works)');
}

# ── Test 5: Anchor summary is the work product, not metadata ───────
{
    # The anchor summary should be a system message (treated as part of
    # the model's working memory, not as metadata for the framework).
    my $r = CLIO::Core::API::MessageValidator::_make_anchor_summary('test');
    is($r->{role}, 'system', 'Anchor is a system message (work product, not framework metadata)');
}

# ── Test 6: Anchor summary integrates with the full flow ──────────
# (functional smoke test - verify the wiring doesn't crash on a
# minimal messages array)
{
    require CLIO::Core::WorkflowOrchestrator;
    my $wo = CLIO::Core::WorkflowOrchestrator->new();
    my $messages = [
        { role => 'system', content => "# CLIO System Prompt\n\nYou are CLIO." },
        { role => 'user', content => 'I would like you to do a full QA audit of the CLIO codebase' },
    ];
    my $result = $wo->_inject_thread_summary($messages, $messages->[-1]{content});
    ok($result, '_inject_thread_summary returns a result');
    is(ref($result), 'ARRAY', 'Result is an arrayref');
    # Verify a thread_summary system message is in the output
    my $found_summary = 0;
    for my $msg (@$result) {
        if ($msg->{role} eq 'system' && $msg->{content} =~ /\A<thread_summary>/) {
            $found_summary++;
        }
    }
    cmp_ok($found_summary, '>=', 1, '_inject_thread_summary emits a thread_summary system message');
}

# ── Test 7: Anchor is no-op when a thread_summary already exists ─────
{
    require CLIO::Core::WorkflowOrchestrator;
    my $wo = CLIO::Core::WorkflowOrchestrator->new();
    my $existing_summary = "<thread_summary>\n\nCurrent task: existing summary\n\n</thread_summary>\n";
    my $messages = [
        { role => 'system', content => "# CLIO System Prompt" },
        { role => 'system', content => $existing_summary },
        { role => 'user', content => 'I would like you to do a full QA audit of the CLIO codebase' },
    ];
    my $result = $wo->_inject_thread_summary($messages, $messages->[-1]{content});
    is(scalar @$result, scalar @$messages, 'No new message added when thread_summary already exists');
    is($result->[1]{content}, $existing_summary, 'Existing thread_summary content preserved unchanged');
}

done_testing();
