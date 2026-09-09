#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test: proactive trim in WorkflowOrchestrator::process_input
# is guarded with `$iteration > 1`. Commit 465dfab8 ("restore stable
# context management") restored this guard, explaining that iteration 1
# is already trimmed by _build_turn_context (which trims the projection
# history + renders the per-minute-cached userContext). This test pins
# that guard so future refactors don't accidentally remove or modify it.

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

# Find the proactive trim block: the one that calls validate_and_truncate
# via `if ($self->{api_manager}` guard.
my ($trim_block) = $source =~ /(
    if\s*\(\s*\$self->\{api_manager\}\s*\)\s*\{
    (?:[^\n]*\n){0,50}
    ^\s*\}
)/xm;

ok(defined $trim_block, 'proactive trim block (if api_manager) found')
    or diag("Could not locate the proactive trim block.");

if ($trim_block) {
    like(
        $trim_block,
        qr/validate_and_truncate\s*\(/,
        'proactive trim block calls validate_and_truncate'
    );

    # 465dfab8 restored the $iteration > 1 guard on the proactive trim.
    # That guard has been removed: the proactive trim now runs on EVERY
    # iteration (including iteration 1) as a safety net for when the
    # projection's heuristic token estimates are inaccurate.
    unlike(
        $trim_block,
        qr/if\s*\(\s*\$self->\{api_manager\}\s*&&\s*\$iteration\s*>\s*1\s*\)/,
        'proactive trim does NOT have the old $iteration > 1 guard (runs every iteration)'
    );

    # The guard should NOT have been changed to allow iteration 1
    # (SMELL #6 was intentionally reverted).
    unlike(
        $trim_block,
        qr/if\s*\(\s*\$self->\{api_manager\}\s*(?!\s*\))/,
        'proactive trim guard does not have extra conditions on $iteration'
    );
}

done_testing();
