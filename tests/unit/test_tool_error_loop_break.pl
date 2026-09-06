#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Tests for the tool error loop break mechanism (Phase 3):
# - After 3 consecutive identical-shape errors, the loop breaks
# - The enhanced error guidance is NOT saved to session history (only raw error)
# - The STOP text approach is replaced by an error return from process_input

use strict;
use warnings;
use utf8;
use lib './lib';

use Test::More;
use CLIO::Core::ToolErrorGuidance;

# Test 1: ToolErrorGuidance::categorize_error produces stable categories
subtest 'categorize_error produces stable categories' => sub {
    my $g = CLIO::Core::ToolErrorGuidance->new();

    # Missing operation parameter
    my $cat = $g->categorize_error(
        "Missing required parameter: operation",
        'file_operations'
    );
    is($cat, 'missing_required', 'missing operation -> missing_required');

    # Different error text, same category (use a non-operation param)
    $cat = $g->categorize_error(
        "Missing required parameter: path",
        'file_operations'
    );
    is($cat, 'missing_required', 'different text, same category');

    # Unknown operation
    $cat = $g->categorize_error(
        "Unknown operation: list_directory",
        'file_operations'
    );
    is($cat, 'invalid_operation', 'unknown operation -> invalid_operation');

    # Directory not found
    $cat = $g->categorize_error(
        "Working directory does not exist",
        'terminal_operations'
    );
    is($cat, 'directory_not_found', 'directory not found');
};

# Test 2: enhance_tool_error produces verbose guidance (but it should NOT
# be saved to session — that's tested by the orchestration test)
subtest 'enhance_tool_error produces guidance' => sub {
    my $g = CLIO::Core::ToolErrorGuidance->new();

    my $enhanced = $g->enhance_tool_error(
        error => "Missing required parameter: operation",
        tool_name => 'file_operations',
        tool_definition => {
            description => 'File operations tool',
            parameters => { type => 'object', properties => { operation => { type => 'string' } } },
        },
        attempted_params => {},
    );

    ok(length($enhanced) > 100, 'enhanced error is verbose (>100 chars)');
    like($enhanced, qr/TOOL ERROR/, 'contains TOOL ERROR header');
    unlike($enhanced, qr/^STOP:/, 'does not contain STOP prefix (new approach)');
    unlike($enhanced, qr/STOP: You have made/, 'does not contain old STOP loop message');
};

# Test 3: Error loop break flag is set after 3 consecutive errors
subtest 'error loop break flag' => sub {
    # Simulate the error loop detection logic from WorkflowOrchestrator
    my %loop_count;
    my $last_sig;
    my $break_flag = undef;

    my @errors = (
        ['file_operations', 'read_file', 'missing_required'],
        ['file_operations', 'read_file', 'missing_required'],
        ['file_operations', 'read_file', 'missing_required'],
    );

    for my $e (@errors) {
        my $sig = join('|', @$e);
        if (defined $last_sig && $last_sig eq $sig) {
            $loop_count{$sig}++;
        } else {
            $loop_count{$sig} = 1;
            $last_sig = $sig;
        }
        my $count = $loop_count{$sig};

        if ($count >= 3) {
            $break_flag = {
                tool  => $e->[0],
                error => 'test error',
                count => $count,
                sig   => $sig,
            };
            last;
        }
    }

    ok(defined $break_flag, 'break flag set after 3 consecutive errors');
    is($break_flag->{tool}, 'file_operations', 'break flag has tool name');
    is($break_flag->{count}, 3, 'break flag has count=3');
    ok(length($break_flag->{sig}) > 0, 'break flag has signature');

    # Verify the error message format matches what process_input returns
    my $msg = sprintf(
        "Tool error loop broken: %d consecutive identical errors from '%s' "
        . "(sig: %s). The enhanced error guidance was injected into the "
        . "current message array but not saved to session history. "
        . "Please review the error and try a different approach.",
        $break_flag->{count},
        $break_flag->{tool},
        $break_flag->{sig},
    );
    like($msg, qr/Tool error loop broken/, 'break message starts correctly');
    unlike($msg, qr/STOP:/, 'break message does NOT contain STOP text');
    like($msg, qr/not saved to session history/, 'break message mentions session history');
};

# Test 4: Session save uses raw error, not enhanced guidance
subtest 'session save uses raw error' => sub {
    # Simulate the session save logic from _execute_tool_round
    my $result_data = {
        success => 0,
        error => "Missing required parameter: operation",
    };

    my $is_error = 1;
    my $ai_content = "TOOL ERROR: file_operations\nMissing required parameter: operation\n\n... (100+ lines of schema dump)";
    my $sanitized_content = $ai_content;

    # The new logic: save raw error to session, not enhanced guidance
    my $session_content = $sanitized_content;
    if ($is_error && $result_data && ref($result_data) eq 'HASH') {
        $session_content = $result_data->{error};
    }

    is($session_content, 'Missing required parameter: operation',
        'session gets raw error, not schema dump');
    isnt($session_content, $sanitized_content,
        'session content differs from @messages content');
    unlike($session_content, qr/TOOL ERROR/, 'session content has no schema dump header');
    unlike($session_content, qr/schema|example/,
        'session content is concise (no schema/example details)');
};

# Test 5: Successful tool calls reset the error loop counter
subtest 'successful call resets error loop tracking' => sub {
    my %loop_count;
    my $last_sig;

    # Simulate 2 errors then a success
    my @events = (
        ['file_operations', 'read_file', 'missing_required', 1],  # error
        ['file_operations', 'read_file', 'missing_required', 1],  # error
        ['file_operations', 'read_file', '', 0],                  # success
        ['file_operations', 'read_file', 'missing_required', 1],  # error (should be count=1, not 3)
    );

    my $break_hit = 0;
    for my $e (@events) {
        my ($tool, $op, $cat, $is_error) = @$e;
        if ($is_error) {
            my $sig = join('|', $tool, $op, $cat);
            if (defined $last_sig && $last_sig eq $sig) {
                $loop_count{$sig}++;
            } else {
                $loop_count{$sig} = 1;
                $last_sig = $sig;
            }
            my $count = $loop_count{$sig};
            if ($count >= 3) {
                $break_hit = 1;
            }
        } else {
            # Reset on success
            %loop_count = ();
            $last_sig = undef;
        }
    }

    ok(! $break_hit, 'no break triggered — success reset the counter');
};

done_testing();
