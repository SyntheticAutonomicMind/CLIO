#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test for the category-based tool error signature.
#
# The OLD signature was tool|operation|first80chars(error). Two failure modes:
#   1. Slight variance in the raw error text (timestamps, IDs, line
#      numbers, word reordering) reset the loop count to 1.
#   2. Different operation names that resolve to the same root cause
#      reset the count.
#
# The signature is now tool|operation|category|arguments-digest, where the
# category is the stable enum produced by ToolErrorGuidance::categorize_error.
# This test drives the real accounting method (not a copy of it), so a change
# to the code fails the test instead of drifting away from it.

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";

use Test::More;
use File::Temp qw(tempdir);
use CLIO::Core::Config;
use CLIO::Core::WorkflowOrchestrator;
use CLIO::Core::ToolErrorGuidance;

sub build_orchestrator {
    my $dir = tempdir(CLEANUP => 1);
    open my $fh, '>', "$dir/config.json" or die $!;
    print $fh q({"provider":"github_copilot","api_key":"sk-test-key"});
    close $fh;
    return CLIO::Core::WorkflowOrchestrator->new(
        config  => CLIO::Core::Config->new(config_dir => $dir),
        debug   => 0,
        session => undef,
    );
}

subtest 'raw error noise does not reset the count' => sub {
    my $orch = build_orchestrator();
    my $guidance = CLIO::Core::ToolErrorGuidance->new();

    # Same root cause, different raw text. The categorizer collapses all of
    # these to one category, so the accounting sees one failure mode.
    my @errors = (
        "Missing required parameter: command",
        "Missing 'command' parameter",
        "Missing required parameters: command (1 missing)",
        "Missing or empty 'command' parameter",
    );

    my @verdicts;
    my $iteration = 0;
    for my $error (@errors) {
        my $category = $guidance->categorize_error($error, 'terminal_operations');
        is($category, 'missing_required', "category for '$error'");
        push @verdicts, $orch->track_tool_error_loop(
            tool        => 'terminal_operations',
            operation   => 'exec',
            category    => $category,
            args_digest => 'same-arguments',
            iteration   => ++$iteration,
        );
    }

    is($verdicts[1]{identical}, 2, 'second form of the same error counts as a repeat');
    is($verdicts[3]{identical}, 4, 'fourth form still counts, despite different wording');
    ok(defined $verdicts[3]{guidance}, 'a note is produced once the pattern is real');
};

subtest 'different categories are counted separately' => sub {
    my $orch = build_orchestrator();
    my $guidance = CLIO::Core::ToolErrorGuidance->new();

    my $missing = $guidance->categorize_error('Missing required parameter: path', 'file_operations');
    my $invalid = $guidance->categorize_error('Unknown operation: list_directory', 'file_operations');
    isnt($missing, $invalid, 'the two errors have different categories');

    $orch->track_tool_error_loop(
        tool => 'file_operations', operation => '', category => $missing,
        args_digest => 'a', iteration => 1);
    my $v = $orch->track_tool_error_loop(
        tool => 'file_operations', operation => '', category => $invalid,
        args_digest => 'b', iteration => 2);

    is($v->{same_mode}, 1, 'a different category starts its own count');
    is($v->{identical}, 1, 'a different category is not an identical retry');
};

subtest 'a changed argument set is a new attempt, not a repeat' => sub {
    my $orch = build_orchestrator();

    my $first = $orch->track_tool_error_loop(
        tool => 'todo_operations', operation => 'update',
        category => 'todo_validation_failed', args_digest => 'attempt-1', iteration => 1);
    my $second = $orch->track_tool_error_loop(
        tool => 'todo_operations', operation => 'update',
        category => 'todo_validation_failed', args_digest => 'attempt-2', iteration => 2);

    is($first->{identical}, 1,  'first attempt: identical count 1');
    is($second->{identical}, 1, 'changed arguments: identical count stays 1');
    is($second->{same_mode}, 2, 'but the failure mode is still counted');
    is($second->{guidance}, undef, 'no note yet: the model is still trying');
};

done_testing();
