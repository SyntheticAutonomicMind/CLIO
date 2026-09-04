#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test: LTM sanitization must NOT rewrite tool/function
# names in code patterns or problem solutions. Those entries
# legitimately need the tool names so the model can recall
# "use this specific tool to do this specific thing" - the whole
# point of LTM. The sanitizer's replacement table maps
# "apply_patch" -> "patch operations", "validate_and_truncate" ->
# "context validation", etc. For code patterns / problem solutions
# that mapping destroys the entry's value.
#
# Discovered 2026-09-03 during QA review. _prepare_for_storage was
# called unconditionally from add_code_pattern and add_problem_solution,
# which meant every tool/function name in those entries got rewritten
# on write, and again on read in ContextBuilder::score_ltm.
#
# Fix: add a sibling helper _prepare_for_storage_code (and a public
# sanitize_narration_drop_only) that runs only the drop-phrase
# pass - not the tool-replacement pass. Wire add_code_pattern and
# add_problem_solution to use it. In score_ltm, sanitize
# code_patterns / problem_solutions entries with the drop-only
# variant; sanitize everything else with the full variant.

use strict;
use warnings;
use utf8;
use lib './lib';

use Test::More;
use CLIO::Memory::LongTerm;

# Build a LongTerm instance without persisting (so we don't
# pollute the real ltm.json).
my $ltm = CLIO::Memory::LongTerm->new();

# ---------------------------------------------------------------------------
# Test 1: _prepare_for_storage_code preserves tool/function names
# ---------------------------------------------------------------------------
{
    my $code_pattern = "When fixing ContextBuilder.pm, use apply_patch "
        . "to update the role-based history implementation. The "
        . "trim_with_noise_dropping call in _build_turn_context is "
        . "where the over-trim happens.";

    my $stored = $ltm->_prepare_for_storage_code($code_pattern);

    # The whole point of the entry is to remember these specific
    # tool/function names. All of them must survive.
    like($stored, qr/apply_patch/,
        'code pattern entry preserves apply_patch');
    like($stored, qr/trim_with_noise_dropping/,
        'code pattern entry preserves trim_with_noise_dropping');
    like($stored, qr/ContextBuilder\.pm/,
        'code pattern entry preserves ContextBuilder.pm');
    like($stored, qr/_build_turn_context/,
        'code pattern entry preserves _build_turn_context');
}

# ---------------------------------------------------------------------------
# Test 2: _prepare_for_storage_code still drops narration sentences
# ---------------------------------------------------------------------------
{
    my $mixed = "After context trimming, use these patterns. "
        . "The real bug was in apply_patch, not the trigger code.";

    my $stored = $ltm->_prepare_for_storage_code($mixed);

    unlike($stored, qr/After context trimming/,
        'narration sentence is dropped even in code patterns');
    like($stored, qr/apply_patch/,
        'tool name is preserved even though narration was dropped');
}

# ---------------------------------------------------------------------------
# Test 3: _prepare_for_storage (full sanitize) still rewrites
# tool names for non-code entries. This is the desired behavior
# for discoveries, context rules, and the like.
# ---------------------------------------------------------------------------
{
    my $entry = "When fixing ContextBuilder.pm, use apply_patch "
        . "to update the role-based history implementation.";

    my $stored = $ltm->_prepare_for_storage($entry);

    unlike($stored, qr/apply_patch/,
        'discoveries still get tool names rewritten (full sanitize)');
    like($stored, qr/patch operations/,
        'discoveries see the replacement phrase instead');
}

# ---------------------------------------------------------------------------
# Test 4: sanitize_narration_drop_only is the public form used
# by ContextBuilder::score_ltm at read time. It must behave the
# same as _prepare_for_storage_code (minus the date pass).
# ---------------------------------------------------------------------------
{
    my $entry = "When fixing ContextBuilder.pm, use apply_patch "
        . "to update the role-based history implementation.";

    my $cleaned = $ltm->sanitize_narration_drop_only($entry);

    like($cleaned, qr/apply_patch/,
        'drop_only public form preserves tool names');
    like($cleaned, qr/ContextBuilder\.pm/,
        'drop_only public form preserves function/module names');
}

# ---------------------------------------------------------------------------
# Test 5: end-to-end via add_code_pattern. The stored entry on
# disk must contain the tool names verbatim.
# ---------------------------------------------------------------------------
{
    # Use a unique session id so this test doesn't interact with
    # any real LTM data.
    my $tmp_pattern = "Test sanitizer regression: use file_operations to "
        . "read ContextBuilder.pm before calling validate_and_truncate.";

    $ltm->add_code_pattern($tmp_pattern, 0.9);

    my $entries = $ltm->get_entries_for_projection();
    my ($found) = grep { $_->{content} =~ /Test sanitizer regression/ } @$entries;
    ok(defined $found, 'code pattern was stored');
    ok(defined $found, 'entry was found in projection output');

    if ($found) {
        like($found->{content}, qr/file_operations/,
            'stored code pattern preserves file_operations');
        like($found->{content}, qr/validate_and_truncate/,
            'stored code pattern preserves validate_and_truncate');
        like($found->{content}, qr/ContextBuilder\.pm/,
            'stored code pattern preserves ContextBuilder.pm');
        is($found->{type}, 'pattern',
            'entry has type=pattern so score_ltm uses drop_only');
    }
}

done_testing();
