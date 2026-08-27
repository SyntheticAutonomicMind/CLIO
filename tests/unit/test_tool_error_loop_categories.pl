#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

# Regression test for the category-based tool error loop signature.
#
# The OLD signature was tool|operation|first80chars(error). Two failure modes:
#   1. Slight variance in the raw error text (timestamps, IDs, line
#      numbers, word reordering) reset the loop count to 1.
#   2. Different operation names that resolve to the same root cause
#      reset the count.
#
# The NEW signature is tool|operation|error_category where error_category
# is the stable enum produced by ToolErrorGuidance::categorize_error.
# This test verifies the new signature is robust to noise in the raw
# error text.

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";

use Test::More;
use CLIO::Core::ToolErrorGuidance;

# Build a FakeOrchestrator that mirrors the new signature: tool +
# operation + error_category. This is the canonical reference for what
# WorkflowOrchestrator does at lib/CLIO/Core/WorkflowOrchestrator.pm:2489.
package FakeOrchestrator;

sub new {
    my ($class) = @_;
    return bless {
        _tool_error_loop_count => {},
        _tool_error_loop_last_sig => undef,
        _error_guidance => CLIO::Core::ToolErrorGuidance->new(),
    }, $class;
}

sub _err_category {
    my ($self, $error, $tool_name) = @_;
    return $self->{_error_guidance}->categorize_error($error // '', $tool_name // '');
}

sub record_tool_outcome {
    my ($self, $tool_name, $tool_operation, $result_data) = @_;
    return ($self->{_tool_error_loop_count}, $self->{_tool_error_loop_last_sig})
        unless $result_data && ref($result_data) eq 'HASH';

    my $is_error = exists $result_data->{success} && !$result_data->{success};
    my $err_category = $is_error
        ? $self->_err_category($result_data->{error} // '', $tool_name)
        : 'unknown';
    my $err_sig = join("|",
        $tool_name,
        $tool_operation || '',
        $err_category
    );

    if ($is_error) {
        if (defined $self->{_tool_error_loop_last_sig}
            && $self->{_tool_error_loop_last_sig} eq $err_sig) {
            $self->{_tool_error_loop_count}{$err_sig}++;
        } else {
            $self->{_tool_error_loop_count}{$err_sig} = 1;
            $self->{_tool_error_loop_last_sig} = $err_sig;
        }
        my $count = $self->{_tool_error_loop_count}{$err_sig};
        return ($self->{_tool_error_loop_count}, $count, $err_sig);
    } else {
        $self->{_tool_error_loop_count} = {};
        $self->{_tool_error_loop_last_sig} = undef;
        return ($self->{_tool_error_loop_count}, 0, undef);
    }
}

package main;

subtest 'category-based signature is stable across raw error noise' => sub {
    my $orc = FakeOrchestrator->new();

    # Same root cause (missing required parameter) with slightly different
    # raw text. The OLD signature would reset to 1 each time. The NEW
    # signature keeps the count incrementing.
    my @errors = (
        "Missing required parameter: command",
        "Missing 'command' parameter",
        "Missing required parameters: command (1 missing)",
        "Missing or empty 'command' parameter",
    );

    my @sigs;
    for my $err (@errors) {
        my ($count_h, $count, $sig) = $orc->record_tool_outcome(
            'terminal_operations', 'exec',
            { success => 0, error => $err }
        );
        push @sigs, $sig;
    }

    # All four signatures should be the same because the categorizer
    # reduces them all to 'missing_required'.
    is($sigs[0], $sigs[1], 'sig 0 == sig 1 (same category)');
    is($sigs[1], $sigs[2], 'sig 1 == sig 2 (same category)');
    is($sigs[2], $sigs[3], 'sig 2 == sig 3 (same category)');

    # And the signature should NOT contain the raw error text.
    unlike($sigs[0], qr/Missing required parameter/,
        'signature does not contain raw error text');
    like($sigs[0], qr/missing_required/, 'signature contains category name');
};

subtest 'different categories reset the count' => sub {
    my $orc = FakeOrchestrator->new();

    # First: missing_required (3 times -> count 3)
    $orc->record_tool_outcome('terminal_operations', 'exec',
        { success => 0, error => "Missing required parameter: command" });
    $orc->record_tool_outcome('terminal_operations', 'exec',
        { success => 0, error => "Missing 'command' parameter" });
    my ($h, $count1) = $orc->record_tool_outcome('terminal_operations', 'exec',
        { success => 0, error => "Missing or empty 'command' parameter" });
    is($count1, 3, '3 missing_required errors -> count=3');

    # Different category (invalid_operation) -> reset to 1
    my ($h2, $count2, $sig2) = $orc->record_tool_outcome(
        'terminal_operations', 'exec',
        { success => 0, error => "Unknown operation: foo" });
    is($count2, 1, 'switching to invalid_operation resets count to 1');
    like($sig2, qr/invalid_operation/, 'signature reflects new category');
};

subtest 'categorize_error public wrapper is callable' => sub {
    my $eg = CLIO::Core::ToolErrorGuidance->new();
    is($eg->categorize_error("Missing required parameter: foo", "test_tool"),
        'missing_required', 'missing_required category');
    is($eg->categorize_error("Unknown operation: bar", "test_tool"),
        'invalid_operation', 'invalid_operation category');
    is($eg->categorize_error("Working directory does not exist", "test_tool"),
        'directory_not_found', 'directory_not_found category');
    is($eg->categorize_error("permission denied", "test_tool"),
        'permission_denied', 'permission_denied category');
    is($eg->categorize_error("", "test_tool"),
        'generic_error', 'empty error -> generic_error');
};

subtest 'same root cause across different operations stays in same category' => sub {
    my $orc = FakeOrchestrator->new();

    # Two different operation names, same missing-parameter root cause.
    my ($h1, $count1, $sig1) = $orc->record_tool_outcome('file_operations', 'read_file',
        { success => 0, error => "Missing 'path' parameter" });
    my ($h2, $count2, $sig2) = $orc->record_tool_outcome('file_operations', 'write_file',
        { success => 0, error => "Missing 'path' parameter" });

    # Different operations => different signatures => count resets.
    # (This is intentional: the operation is part of the signature so
    # we don't conflate "missing path in read" with "missing path in
    # write" - they need different fixes.)
    isnt($sig1, $sig2,
        'different operations produce different signatures');
    is($count1, 1, 'first op error count=1');
    is($count2, 1, 'second op error count=1 (different op = different sig)');
};

subtest 'successful call resets tracking even after many errors' => sub {
    my $orc = FakeOrchestrator->new();

    $orc->record_tool_outcome('terminal_operations', 'exec',
        { success => 0, error => "Missing required parameter: foo" });
    $orc->record_tool_outcome('terminal_operations', 'exec',
        { success => 0, error => "Missing required parameter: foo" });
    my ($h, $count) = $orc->record_tool_outcome('terminal_operations', 'exec',
        { success => 0, error => "Missing required parameter: foo" });
    is($count, 3, '3 errors before success');

    my ($h2, $count_after, $sig_after) = $orc->record_tool_outcome(
        'terminal_operations', 'exec',
        { success => 1, result => 'ok' });
    is($count_after, 0, 'success resets count to 0');
    is($sig_after, undef, 'success clears last signature');
};

done_testing();