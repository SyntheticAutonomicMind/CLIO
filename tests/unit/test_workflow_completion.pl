#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Unit tests for CLIO::Core::WorkflowCompletion — the internal nudge
# guard that detects when an AI agent stopped mid-workflow.
#
# The gate checks only two conditions:
#   1. API finish_reason=length (token-limit truncation)
#   2. Empty response after tool activity (reasoning-only turn, provider
#      doesn't surface reasoning separately)
#
# When the gate detects incompleteness and retries remain, it nudges the
# model with a continuation message (bounded to max_retries). When retries
# are exhausted, the orchestrator ends the workflow with whatever content
# exists — the gate never returns success=0 or surfaces errors to the user.

use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../lib";

use Test::More;
use CLIO::Core::WorkflowCompletion;

my $eval = CLIO::Core::WorkflowCompletion->new(debug => 0);

# Helper: build a tool call record
sub tc {
    my %h = @_;
    return {
        name      => $h{name}      // 'file_operations',
        operation => $h{operation}  // 'read_file',
        arguments => $h{arguments} // '{}',
        result    => $h{result}    // '',
        success   => exists $h{success} ? $h{success} : 1,
        error     => $h{error},
        exit_code => $h{exit_code},
    };
}

# ── 1. Normal final response (no tools) = complete ──
{
    my $r = $eval->evaluate(
        content      => "The fix is complete. All tests pass.",
        tool_calls   => [],
        retry_count  => 0,
    );
    is($r->{decision}, 'complete', 'Test 1: Normal final response = complete');
    is(scalar(@{$r->{blockers}}), 0, 'Test 1: no blockers');
}

# ── 2. Empty response with no tool calls = complete ──
{
    my $r = $eval->evaluate(
        content      => "",
        tool_calls   => [],
        retry_count  => 0,
    );
    # No tool activity -> not the gate's concern. The orchestrator's
    # outer loop (max_iterations) would catch this independently.
    is($r->{decision}, 'complete', 'Test 2: Empty response, no tools = complete');
}

# ── 3. finish_reason=stop with content = complete ──
{
    my $r = $eval->evaluate(
        content       => "The task is complete.",
        api_response  => { finish_reason => 'stop' },
        tool_calls    => [],
        retry_count   => 0,
    );
    is($r->{decision}, 'complete', 'Test 3: finish_reason=stop with content = complete');
}

# ── 4. Empty response after tool activity (no separate reasoning) = continue ──
{
    my $r = $eval->evaluate(
        content      => "",
        api_response  => { finish_reason => 'stop' },
        tool_calls    => [tc(name => 'file_operations', operation => 'read_file', success => 1)],
        retry_count  => 0,
    );
    is($r->{decision}, 'continue', 'Test 4: Empty response after tools = continue');
    ok(grep { $_ eq 'empty_response' } @{$r->{blockers}}, 'Test 4: blocks on empty_response');
}

# ── 5. Empty response but provider has separate reasoning = complete ──
{
    my $r = $eval->evaluate(
        content      => "",
        api_response => {
            finish_reason     => 'stop',
            reasoning_content => "The answer is 42.",
        },
        tool_calls => [tc(name => 'file_operations', operation => 'read_file', success => 1)],
        retry_count => 0,
    );
    is($r->{decision}, 'complete', 'Test 5: Empty content but separate reasoning = complete');
    ok(!grep { $_ eq 'empty_response' } @{$r->{blockers}}, 'Test 5: NOT a blocker when reasoning is separate');
}

# ── 6. finish_reason=length = continue (truncation) ──
{
    my $r = $eval->evaluate(
        content      => "Here is the beginning of",
        api_response => { finish_reason => 'length' },
        tool_calls   => [],
        retry_count  => 0,
    );
    is($r->{decision}, 'continue', 'Test 6: finish_reason=length = continue');
    ok(grep { $_ eq 'api_truncated' } @{$r->{blockers}}, 'Test 6: blocks on api_truncated');
}

# ── 7. finish_reason=content_filter = continue ──
{
    my $r = $eval->evaluate(
        content      => "I can't",
        api_response => { finish_reason => 'content_filter' },
        tool_calls   => [],
        retry_count  => 0,
    );
    is($r->{decision}, 'continue', 'Test 7: finish_reason=content_filter = continue');
    ok(grep { $_ eq 'api_truncated' } @{$r->{blockers}}, 'Test 7: blocks on api_truncated');
}

# ── 8. Non-truncated finish with separate reasoning channel = complete ──
{
    my $r = $eval->evaluate(
        content       => "Done.",
        api_response  => {
            finish_reason     => 'stop',
            responses_reasoning_items => [{ type => 'reasoning' }],
        },
        tool_calls    => [],
        retry_count   => 0,
    );
    is($r->{decision}, 'complete', 'Test 8: Responses API with reasoning_items = complete');
}

# ── 9: Tool error does NOT block (agent should handle, not the gate) ──
{
    my $r = $eval->evaluate(
        content      => "I hit an error but I'll fix it.",
        tool_calls   => [
            tc(name => 'file_operations', operation => 'write_file', success => 1),
            tc(name => 'file_operations', operation => 'replace_string', success => 0, error => "Permission denied"),
        ],
        retry_count  => 0,
    );
    # Tool errors are not the gate's concern — the orchestrator's loop
    # handles retries via the error loop. The gate only looks at the
    # final text response.
    is($r->{decision}, 'complete', 'Test 9: Tool error does not block completion');
    ok(!grep { $_ eq 'tool_error' } @{$r->{blockers}}, 'Test 9: tool_error not a blocker');
}

# ── 10: Verification command failure does NOT block (agent's concern) ──
{
    my $r = $eval->evaluate(
        content      => "Done.",
        tool_calls   => [
            tc(name => 'file_operations', operation => 'write_file', success => 1),
            tc(name => 'terminal_operations', operation => 'exec', success => 1,
               exit_code => 1, arguments => '{"command":"npm test"}',
               result => "3 failing tests"),
        ],
        retry_count  => 0,
    );
    is($r->{decision}, 'complete', 'Test 10: Verification command failure does not block the gate');
    ok(!grep { $_ eq 'verification_failed' } @{$r->{blockers}}, 'Test 10: verification_failed not a blocker');
}

# ── 11: Pre-existing/verification-failure-explained content = complete ──
{
    my $r = $eval->evaluate(
        content      => "TestPreWarming fails identically on the original code. "
                      . "These are pre-existing failures.",
        tool_calls   => [
            tc(name => 'terminal_operations', operation => 'exec', success => 1,
               exit_code => 1, arguments => '{"command":"npm test"}',
               result => "4 failing"),
        ],
        retry_count  => 0,
    );
    is($r->{decision}, 'complete', 'Test 11: Agent explains pre-existing failures = complete');
}

# ── 12: Short response after tools = complete (no false positive) ──
{
    my $r = $eval->evaluate(
        content      => "Done.",
        tool_calls   => [tc(name => 'file_operations', operation => 'read_file', success => 1)],
        retry_count  => 0,
    );
    is($r->{decision}, 'complete', 'Test 12: Short response with terminal punct after tools = complete');
}

# ── 13: Short response without terminal punct after tools = complete ──
{
    my $r = $eval->evaluate(
        content      => "All done",
        tool_calls   => [tc(name => 'file_operations', operation => 'read_file', success => 1)],
        retry_count  => 0,
    );
    # We removed the incomplete_structure check — a short "All done"
    # is a perfectly valid final response. The agent knows its own work.
    is($r->{decision}, 'complete', 'Test 13: Short response without terminal punct = complete');
}

# ── 14: "I still need to..." pattern does NOT block ──
{
    my $r = $eval->evaluate(
        content      => "I still need to do more work.",
        tool_calls   => [],
        retry_count  => 0,
    );
    # Textual intent signals are not the gate's concern. The agent
    # decides when it's done — the gate only catches empty/reasoning-only.
    is($r->{decision}, 'complete', 'Test 14: "I still need to..." does not block (textual signals removed)');
}

# ── 15: "OK" after tool work = complete ──
{
    my $r = $eval->evaluate(
        content      => "OK",
        tool_calls   => [tc(name => 'file_operations', operation => 'read_file', success => 1)],
        retry_count  => 0,
    );
    is($r->{decision}, 'complete', 'Test 15: "OK" after tool work = complete');
}

# ── 16: Exhausted budget = uncertain (but content is still returned) ──
{
    my $r = $eval->evaluate(
        content      => "",
        api_response  => { finish_reason => 'stop' },
        tool_calls    => [tc(name => 'file_operations', operation => 'read_file', success => 1)],
        retry_count  => 2,
        max_retries  => 2,
    );
    is($r->{decision}, 'uncertain', 'Test 16: Exhausted budget = uncertain');
    ok($r->{exhausted}, 'Test 16: exhausted flag set');
    ok(length($r->{continuation}) > 10, 'Test 16: continuation message is meaningful');
}

# ── 17: Exhausted budget continuation message does not say "attempt(s)" ──
{
    my $r = $eval->evaluate(
        content      => "",
        api_response  => { finish_reason => 'stop' },
        tool_calls    => [tc(name => 'file_operations', operation => 'read_file', success => 1)],
        retry_count  => 2,
        max_retries  => 2,
    );
    unlike($r->{continuation}, qr/continuation attempt/i,
        'Test 17: Exhausted message does not say "continuation attempt"');
    like($r->{continuation}, qr/Blockers:/i,
        'Test 17: Exhausted message says "Blockers:"');
}

# ── 18: api_truncated continuation mentions continuing ──
{
    my $r = $eval->evaluate(
        content      => "Here is the beginning of",
        api_response => { finish_reason => 'length' },
        tool_calls   => [],
        retry_count  => 0,
    );
    like($r->{continuation}, qr/continue|cut short|finish|remaining/i,
        'Test 18: api_truncated continuation mentions continuing');
    unlike($r->{continuation}, qr/token.?budget|max.?token/i,
        'Test 18: api_truncated continuation does NOT mention token budgets');
}

# ── 19: empty_response continuation ──
{
    my $r = $eval->evaluate(
        content      => "",
        api_response  => { finish_reason => 'stop' },
        tool_calls    => [tc(name => 'file_operations', operation => 'read_file', success => 1)],
        retry_count  => 0,
    );
    like($r->{continuation}, qr/empty|continue|finish/i,
        'Test 19: empty_response continuation is meaningful');
}

# ── 20: No separate reasoning + thinking_content absent = empty_response ──
{
    my $r = $eval->evaluate(
        content      => "",
        api_response => {
            finish_reason => 'stop',
            reasoning_details => [],
            responses_reasoning_items => [],
        },
        tool_calls => [tc(name => 'file_operations', operation => 'read_file', success => 1)],
        retry_count => 0,
    );
    is($r->{decision}, 'continue', 'Test 20: Empty + no reasoning channels = continue');
    ok(grep { $_ eq 'empty_response' } @{$r->{blockers}}, 'Test 20: blocks on empty_response');
}

# ── 21: Multiple reasoning channels = complete ──
{
    my $r = $eval->evaluate(
        content      => "",
        api_response => {
            finish_reason => 'stop',
            reasoning_content => "thinking",
            accumulated_reasoning => "more thinking",
        },
        tool_calls => [tc(name => 'file_operations', operation => 'read_file', success => 1)],
        retry_count => 0,
    );
    is($r->{decision}, 'complete', 'Test 21: Empty content + multiple reasoning channels = complete');
}

done_testing();
