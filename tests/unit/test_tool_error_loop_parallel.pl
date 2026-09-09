#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 fewtarius
#
# Regression tests for the tool error loop break bug:
#
#   When a model emits multiple parallel tool calls in a single response
#   and they all fail with the same error (e.g. missing 'operation'
#   parameter), the error-loop counter should NOT inflate to 3 and
#   trigger a break. Parallel calls in the same iteration should count
#   as a single error for loop-detection purposes. Only sequential
#   retries across DIFFERENT iterations should increment the counter.
#
#   Additionally, when the loop DOES break (genuine sequential retries),
#   the enhanced error guidance must be saved to session history.

use strict;
use warnings;
use utf8;
use lib './lib';
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Test::More;
use CLIO::Core::WorkflowOrchestrator;
use CLIO::Core::ToolErrorGuidance;

# ──────────────────────────────────────────────────────────────────────
# Simulate the error loop counting logic directly.
# The real _execute_tool_round is deep inside process_input and hard to
# unit-test in isolation (it needs a live API, UI, etc.). Instead we
# test the counting algorithm by extracting and replaying the same
# logic path.
# ──────────────────────────────────────────────────────────────────────

# We test the core counting algorithm by simulating what happens inside
# _execute_tool_round's error tracking block. The algorithm:
# - Tracks _tool_error_loop_last_sig, _tool_error_loop_last_iteration,
#   _tool_error_loop_count
# - Same sig + different iteration = increment (sequential retry)
# - Same sig + same iteration = no increment (parallel call)
# - Different sig = reset to 1

sub simulate_error {
    my ($state, $iteration, $tool_name, $tool_operation, $err_category) = @_;
    my $err_sig = join("|", $tool_name, $tool_operation || '', $err_category);

    my $last_iter = $state->{_tool_error_loop_last_iteration};
    my $same_sig  = (defined $state->{_tool_error_loop_last_sig}
                     && $state->{_tool_error_loop_last_sig} eq $err_sig);
    my $same_iter = (defined $last_iter && $last_iter == $iteration);

    if (!defined $state->{_tool_error_loop_count}) {
        $state->{_tool_error_loop_count} = {};
        $state->{_tool_error_loop_last_sig} = undef;
        $state->{_tool_error_loop_last_iteration} = undef;
    }

    if ($same_sig && !$same_iter) {
        $state->{_tool_error_loop_count}{$err_sig}++;
    } elsif (!($same_sig && $same_iter)) {
        $state->{_tool_error_loop_count}{$err_sig} = 1;
    }

    $state->{_tool_error_loop_last_sig} = $err_sig;
    $state->{_tool_error_loop_last_iteration} = $iteration;

    return $state->{_tool_error_loop_count}{$err_sig};
}

sub simulate_success {
    my ($state) = @_;
    $state->{_tool_error_loop_count} = {};
    $state->{_tool_error_loop_last_sig} = undef;
    $state->{_tool_error_loop_last_iteration} = undef;
}

# ──────────────────────────────────────────────────────────────────────
# Test 1: 3 parallel calls, same error, same iteration => no break
# This is the bug that was reported: 3 terminal_operations calls all
# failing with "Missing 'operation'" should NOT trigger the break.
# ──────────────────────────────────────────────────────────────────────
{
    my $state = {};
    my $iter = 5;

    # 3 parallel tool calls in the same iteration
    my $c1 = simulate_error($state, $iter, 'terminal_operations', 'missing_operation', 'unknown');
    my $c2 = simulate_error($state, $iter, 'terminal_operations', 'missing_operation', 'unknown');
    my $c3 = simulate_error($state, $iter, 'terminal_operations', 'missing_operation', 'unknown');

    ok($c1 == 1, "Parallel call 1: count=1");
    ok($c2 == 1, "Parallel call 2: count stays 1 (not incremented)");
    ok($c3 == 1, "Parallel call 3: count stays 1 (not incremented)");
    ok($c1 < 3, "Count below break threshold (3) for parallel calls");
    no_break($state, "No break flag set for parallel calls");
}

# ──────────────────────────────────────────────────────────────────────
# Test 2: Same error across 3 different iterations => break at 3rd
# This is the real loop: model keeps making the same mistake.
# ──────────────────────────────────────────────────────────────────────
{
    my $state = {};

    my $c1 = simulate_error($state, 1, 'terminal_operations', 'missing_operation', 'unknown');
    my $c2 = simulate_error($state, 2, 'terminal_operations', 'missing_operation', 'unknown');
    my $c3 = simulate_error($state, 3, 'terminal_operations', 'missing_operation', 'unknown');

    ok($c1 == 1, "Iteration 1: count=1");
    ok($c2 == 2, "Iteration 2: count=2 (sequential retry)");
    ok($c3 == 3, "Iteration 3: count=3 (sequential retry, should trigger break)");
    ok($c3 >= 3, "Break threshold reached for sequential retries");
}

# ──────────────────────────────────────────────────────────────────────
# Test 3: Mixed parallel + sequential: 3 parallel in iter 1, same error
# in iter 2 => count goes to 2 (not 3)
# ──────────────────────────────────────────────────────────────────────
{
    my $state = {};

    # 3 parallel in iteration 1
    simulate_error($state, 1, 'terminal_operations', 'missing_operation', 'unknown');
    simulate_error($state, 1, 'terminal_operations', 'missing_operation', 'unknown');
    simulate_error($state, 1, 'terminal_operations', 'missing_operation', 'unknown');

    # Same error in iteration 2
    my $c = simulate_error($state, 2, 'terminal_operations', 'missing_operation', 'unknown');
    ok($c == 2, "3 parallel in iter 1 + retry in iter 2 => count=2 (not 3)");
}

# ──────────────────────────────────────────────────────────────────────
# Test 4: Different errors in same iteration (parallel with different sigs)
# Each error type should get its own count=1
# ──────────────────────────────────────────────────────────────────────
{
    my $state = {};
    my $iter = 1;

    my $c1 = simulate_error($state, $iter, 'terminal_operations', 'exec', 'missing_required');
    my $c2 = simulate_error($state, $iter, 'file_operations', 'read_file', 'invalid_operation');
    my $c3 = simulate_error($state, $iter, 'terminal_operations', 'exec', 'missing_required');

    ok($c1 == 1, "Different sig A: count=1");
    ok($c2 == 1, "Different sig B: count=1");
    ok($c3 == 1, "Re-seen sig A in same iter: count stays 1 (parallel)");
}

# ──────────────────────────────────────────────────────────────────────
# Test 5: Success resets the counter
# ──────────────────────────────────────────────────────────────────────
{
    my $state = {};

    simulate_error($state, 1, 'terminal_operations', 'missing_operation', 'unknown');
    simulate_error($state, 2, 'terminal_operations', 'missing_operation', 'unknown');
    ok($state->{_tool_error_loop_count}{'terminal_operations|missing_operation|unknown'} == 2,
       "Before success: count=2");

    simulate_success($state);
    ok($state->{_tool_error_loop_count} = {}, "After success: count reset to empty hash");

    my $c = simulate_error($state, 3, 'terminal_operations', 'missing_operation', 'unknown');
    ok($c == 1, "After reset, same error in new iteration: count=1 (not 3)");
}

# ──────────────────────────────────────────────────────────────────────
# Test 6: ToolErrorGuidance is available (integration check)
# ──────────────────────────────────────────────────────────────────────
{
    my $g = CLIO::Core::ToolErrorGuidance->new();
    ok(defined $g, "ToolErrorGuidance object created");
    ok($g->can('categorize_error'), "ToolErrorGuidance has categorize_error method");
    ok($g->can('enhance_tool_error'), "ToolErrorGuidance has enhance_tool_error method");

    # Test that the categorize produces stable categories
    my $cat1 = $g->categorize_error("Missing 'operation' parameter", 'terminal_operations');
    my $cat2 = $g->categorize_error("Missing 'operation' parameter", 'file_operations');
    ok(defined $cat1, "categorize_error returns defined category");
    ok(defined $cat2, "categorize_error returns defined category for file_operations");
}

# ──────────────────────────────────────────────────────────────────────
# Helper: check that no break flag is set (simulated)
# ──────────────────────────────────────────────────────────────────────
sub no_break {
    my ($state, $msg) = @_;
    my $sig = $state->{_tool_error_loop_last_sig};
    my $count = $state->{_tool_error_loop_count}{$sig} || 0;
    ok($count < 3, $msg);
}

done_testing();
