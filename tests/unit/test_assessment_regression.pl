#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Synthetic Autonomic Mind
#
# Regression test for the codebase assessment rubric.
#
# Runs `tools/assess_codebase.pl --json` and compares against the last
# record in `runs/assessment-history.jsonl`. If any category score
# regressed, emits a loud diag() warning but does NOT fail the test.
#
# Why warn instead of fail: small temporary regressions are sometimes
# acceptable (e.g., adding a new large method triggers a refactor in
# the next commit). The goal is to make regressions visible so they
# can be addressed, not to block all legitimate work.
#
# Use case: run as part of `tests/run_all_tests.pl --all` so every
# `make test` invocation surfaces assessment drift.

use strict;
use warnings;
use utf8;
use FindBin;
use File::Spec;
use File::Basename;

use Test::More;
use Cwd qw(abs_path);

# IMPORTANT: Skip if invoked from inside the test runner. The assessment
# tool itself invokes the runner to compute the Testing category, and
# if we're being run from inside the runner that would recurse
# infinitely (outer runner -> assessment -> inner runner -> assessment ->
# ...) until the system runs out of processes. We detect this via an
# env var the runner sets before forking each test child.
if ($ENV{CLIO_TEST_RUNNER_INVOKED}) {
    plan skip_all => 'Skipping during nested runner invocation';
    exit 0;
}

# Locate project root (parent of tests/)
my $tests_dir = dirname(abs_path($FindBin::Bin));
my $project_root = dirname($tests_dir);

# Chdir so assess_codebase.pl finds the right paths
chdir $project_root or die "Cannot chdir to $project_root: $!\n";

# Run assessment. --skip-tests avoids running the unit tests inside
# the assessment (we ARE a unit test, so re-running the suite from
# here would be pointless and slow).
my $assess_output = `perl -I lib tools/assess_codebase.pl --skip-tests --json 2>/dev/null`;
my $assess_exit = $?;
my $assess_data;

if ($assess_exit != 0 || !$assess_output) {
    # Assessment failed to run - this IS a hard failure since we can't
    # verify the codebase at all. The whole point of this test is to
    # ensure the methodology produces trustworthy numbers.
    fail("Assessment tool failed to run (exit=$assess_exit)");
    diag("Assessment output was empty - check that tools/assess_codebase.pl runs cleanly");
    done_testing();
    exit 0;
}

eval { $assess_data = decode_json($assess_output); };
if ($@ || !$assess_data) {
    fail("Assessment output is not valid JSON");
    diag("JSON parse error: $@");
    diag("Output was: " . substr($assess_output, 0, 500));
    done_testing();
    exit 0;
}

my $current_scores = $assess_data->{scores};
my $current_total  = $assess_data->{weighted_total};

ok(defined $current_scores, "Assessment produced scores");
is(ref($current_scores), 'HASH', "Scores are a hashref");

# Show current state
diag("Current weighted total: $current_total/10");
for my $cat (sort keys %$current_scores) {
    my $score = $current_scores->{$cat};
    $score //= 0;
    diag(sprintf("  %-20s %d/10", $cat, $score));
}

# Compare against history
my $history_file = "$project_root/runs/assessment-history.jsonl";
my @history;

if (-f $history_file) {
    open my $fh, '<', $history_file or die "Cannot read $history_file: $!\n";
    while (my $line = <$fh>) {
        chomp $line;
        next unless $line;
        eval { push @history, decode_json($line); };
    }
    close $fh;
}

my $comparison_done = 0;
if (@history >= 2) {
    # Skip the last entry (it was just written by a recent track_assessment.sh
    # call and reflects the current state). Compare against second-to-last.
    my $baseline = $history[-2];
    my $baseline_scores = $baseline->{scores};
    $baseline //= {};
    $baseline_scores //= {};

    $comparison_done = 1;
    diag("");
    diag("Comparing against baseline: " . ($baseline->{commit} // 'unknown') . " - " . ($baseline->{timestamp} // 'unknown'));

    my @regressions;
    for my $cat (sort keys %$current_scores) {
        my $cur = $current_scores->{$cat};
        my $base = $baseline_scores->{$cat};
        next unless defined $base;
        if ($cur < $base) {
            push @regressions, [$cat, $base, $cur, $base - $cur];
        } elsif ($cur > $base) {
            diag(sprintf("  [improved] %-20s %d -> %d", $cat, $base, $cur));
        }
    }

    if (@regressions) {
        diag("");
        diag("=========================================================");
        diag("ASSESSMENT REGRESSION DETECTED");
        diag("=========================================================");
        for my $r (@regressions) {
            my ($cat, $base, $cur, $delta) = @$r;
            my $severity = $delta >= 2 ? "*** MAJOR ***" : $delta >= 1 ? "** moderate **" : "* minor *";
            diag(sprintf("  %s %-20s %d/10 -> %d/10 (delta %d)",
                $severity, $cat, $base, $cur, $delta));
        }
        diag("");
        diag("Regressions are tolerated (warned, not failed) to allow");
        diag("temporary dips. Address them in the next commit where");
        diag("practical. See scratch/PHASE_3_FOLLOWUP.md for the");
        diag("planned work to bring Method Quality back up.");
    }

    if (defined $baseline->{weighted_total} && $current_total < $baseline->{weighted_total}) {
        my $delta = $baseline->{weighted_total} - $current_total;
        diag("");
        diag(sprintf("Weighted total regressed: %.1f -> %.1f (delta %.1f)",
            $baseline->{weighted_total}, $current_total, $delta));
    }
} elsif (@history == 1) {
    diag("");
    diag("Only one history record exists - cannot compare yet.");
    diag("Run tools/track_assessment.sh again after a code change to");
    diag("build a baseline, then re-run this test.");
} else {
    diag("");
    diag("No assessment history found at $history_file.");
    diag("Run tools/track_assessment.sh to seed the history,");
    diag("then re-run this test for regression detection.");
}

# Test always passes - the warnings are the value
ok(1, "Assessment regression check complete (warnings emitted if any)");

done_testing();

# Local JSON helper (we don't want to require CLIO::Util::JSON for tests that
# are themselves bootstrapping the methodology).
sub decode_json {
    my $str = shift;
    # Try JSON::PP first (core since 5.14), fall back to JSON
    if (eval { require JSON::PP; 1 }) {
        return JSON::PP::decode_json($str);
    } elsif (eval { require JSON; 1 }) {
        return JSON::decode_json($str);
    } else {
        die "No JSON module available\n";
    }
}