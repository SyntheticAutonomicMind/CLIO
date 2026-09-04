#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test: proactive trim in WorkflowOrchestrator::process_input
# must run on iteration 1, not just on iteration 2+.
#
# Bug (SMELL #6 in QA review 2026-09-02): the call site for the
# proactive trim in process_input was guarded with `&& $iteration > 1`
# to avoid double-trimming on the first iteration. But trim_with_noise_
# dropping already runs in _build_turn_context on the history portion
# (which doesn't include the dynamic userContext) and uses a softer
# budget. If the projection emits a huge dynamic UC (large todo list,
# big LTM, big context files), iteration 1 would send an over-budget
# array and the API would reject with token_limit_exceeded. The guard
# prevented the safety-net trim from running on the very iteration it
# was most needed.
#
# Fix: removed the `&& $iteration > 1` guard so every iteration
# (including iteration 1) gets the proactive trim safety net.
#
# This test is structural: it reads WorkflowOrchestrator.pm, locates
# the proactive trim block (the one with the SMELL #6 comment AND
# the validate_and_truncate call), and asserts that the condition
# gating the trim does NOT include `$iteration > 1`. Combined with
# test_proactive_trim.pl (which exercises the trim function itself),
# this pins both "the function works" and "it gets called on
# iteration 1." A behavioral test that drives process_input directly
# would require building a mock API manager + session + UI; this
# structural test gives the same guarantee with one file and no mocks.

use strict;
use warnings;
use utf8;
use lib './lib';

use Test::More;
use FindBin qw($RealBin);

# Locate WorkflowOrchestrator.pm.
my @candidates = (
    "$RealBin/../../lib/CLIO/Core/WorkflowOrchestrator.pm",
    "$RealBin/../lib/CLIO/Core/WorkflowOrchestrator.pm",
);
my $wfo_path;
for my $cand (@candidates) {
    if (-f $cand) {
        $wfo_path = $cand;
        last;
    }
}
plan skip_all => "WorkflowOrchestrator.pm not found" unless $wfo_path;

open my $fh, '<:encoding(UTF-8)', $wfo_path or die "Cannot open $wfo_path: $!";
my $source = do { local $/; <$fh> };
close $fh;

# Find the proactive trim block. It is the only block that:
#   1. has a comment referencing "SMELL #6" (the fix marker)
#   2. has a comment referencing "proactive trim" (the intent)
#   3. contains a validate_and_truncate call within ~30 lines
# Capture from the SMELL #6 comment through the closing `}` of the
# `if ($self->{api_manager})` block (the trim's own guard).
my ($smell_comment) = $source =~ /(#[^\n]*SMELL\s+\#6[^\n]*\n(?:(?:#[^\n]*\n)|(?:\s*\n)){0,15})/;
ok(defined $smell_comment, 'SMELL #6 fix comment found in WorkflowOrchestrator.pm')
    or diag("The SMELL #6 fix comment was removed; either re-add it or document the new behavior.");

# Find the if-block that calls validate_and_truncate, starting from
# the `if ($self->{api_manager})` line that follows the SMELL #6
# comment. We anchor on the API manager presence check, which is
# unique to the proactive trim block.
my ($trim_block) = $source =~ /(
    if\s*\(\s*\$self->\{api_manager\}\s*\)\s*\{    # the guard line
    (?:[^\n]*\n){0,40}                              # up to 40 lines
    ^\s*\}                                           # closing brace at col 0
)/xm;

ok(defined $trim_block, 'proactive trim block (if api_manager) found')
    or diag("Could not locate the proactive trim block; either the structure changed or the fix was reverted.");

# The guard condition for the proactive trim is `if ($self->{api_manager})`
# (from the captured block above). The fix removed `&& $iteration > 1`
# from this guard, so the block runs on every iteration. We assert
# that the block does NOT contain `$iteration > 1` ANYWHERE in its
# condition. The unrelated `if ($iteration > 1` at line 572 (for the
# dynamic userContext refresh) lives in a separate block, so matching
# only the captured trim_block avoids false positives.
if ($trim_block) {
    unlike(
        $trim_block,
        qr/\$iteration\s*>\s*1/,
        'proactive trim guard does not include $iteration > 1 (SMELL #6 fix)'
    ) or diag("Block text:\n$trim_block");

    like(
        $trim_block,
        qr/validate_and_truncate\s*\(/,
        'proactive trim block actually calls validate_and_truncate'
    ) or diag("Block text:\n$trim_block");
}

done_testing();
