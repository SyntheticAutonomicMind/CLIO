#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Unit tests for CLIO::Core::WorkflowCompletion — the layered
# workflow-completion gate that replaces the old _looks_premature_stop
# heuristic.
#
# The old heuristic decided completion primarily by response length and
# punctuation. The new gate inspects: API finish_reason, structured tool
# results, verification commands, todo state, and textual signals — with
# strong objective evidence dominating weak text signals.

use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../lib";

use Test::More;
use CLIO::Core::WorkflowCompletion;

my $eval = CLIO::Core::WorkflowCompletion->new(debug => 0);

# Helper: build a mock session with session_goals in its state.
sub make_session {
    my ($goals) = @_;
    return bless {
        session_id => 'test-' . int(rand(99999)),
        _state     => { session_goals => $goals || [] },
    }, 'MockSession';
}
sub MockSession::state { return $_[0]->{_state} }
sub MockSession::id   { return $_[0]->{session_id} }

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

# ── 1. Short legitimate final response after successful tool work ──
{
    my $r = $eval->evaluate(
        content      => "Fixed the issue and all tests pass.",
        tool_calls   => [tc(name => 'terminal_operations', operation => 'exec', exit_code => 0, result => "All tests pass")],
        user_input   => "Fix the bug and run the tests",
        retry_count  => 0,
    );
    is($r->{decision}, 'complete', 'Test 1: Short legitimate final response after successful tool work = complete');
    is(scalar(@{$r->{blockers}}), 0, 'Test 1: no blockers');
}

# ── 2. Short final response with no terminal punctuation, workflow state complete ──
{
    my $r = $eval->evaluate(
        content      => "All done",
        tool_calls   => [],
        user_input   => "fix it",
        retry_count  => 0,
    );
    # No tool activity → no premature-stop check fires. Short response with
    # no tools is a legitimate first-iteration answer.
    is($r->{decision}, 'complete', 'Test 2: Short response with no punctuation, no tool activity = complete');
}

# ── 3. Long final response that is genuinely complete ──
{
    my $long = "I have analyzed the codebase and identified the root cause. "
             . "The issue was in the WorkflowOrchestrator, specifically in the "
             . "premature-stop heuristic. I have replaced it with a layered "
             . "completion gate that inspects objective evidence. All tests pass." x 3;
    my $r = $eval->evaluate(
        content      => $long,
        tool_calls   => [],
        user_input   => "investigate and fix",
        retry_count  => 0,
    );
    is($r->{decision}, 'complete', 'Test 3: Long genuinely complete response = complete');
}

# ── 4. A task that legitimately requires no verification ──
{
    my $r = $eval->evaluate(
        content      => "Created the file.",
        tool_calls   => [tc(name => 'file_operations', operation => 'write_file', success => 1)],
        user_input   => "Create a hello world script",
        retry_count  => 0,
    );
    is($r->{decision}, 'complete', 'Test 4: Write-only task with no verification requirement = complete');
}

# ── 5. Blocked todo (external) with final response explaining the block ──
{
    my $session = make_session([{
        id => 1, title => 'Wait for API', status => 'blocked',
        blockedReason => 'waiting for user to provide API key',
    }]);
    my $r = $eval->evaluate(
        content      => "I am blocked waiting for the API key.",
        tool_calls   => [],
        session      => $session,
        user_input   => "fix the code",
        retry_count  => 0,
    );
    is($r->{decision}, 'complete', 'Test 5: External blocked todo with explanation = complete');
    ok(!grep { $_ eq 'todo_blocked' } @{$r->{blockers}}, 'Test 5: does not block on external todo');
    ok(grep { $_ eq 'todo_external_block' } @{$r->{reasons}}, 'Test 5: records external block as reason');
}

# ── 6. Agent edits a file and stops before explicitly required verification ──
{
    my $r = $eval->evaluate(
        content      => "Fixed the bug.",
        tool_calls   => [tc(name => 'file_operations', operation => 'replace_string', success => 1)],
        user_input   => "Fix the bug and run the tests to verify the fix",
        retry_count  => 0,
    );
    is($r->{decision}, 'continue', 'Test 6: File modified, verification required, not run = continue');
    ok(grep { $_ eq 'verification_pending' } @{$r->{blockers}}, 'Test 6: blocks on verification_pending');
    like($r->{continuation}, qr/verification/i, 'Test 6: continuation mentions verification');
}

# ── 7. Agent runs tests and they fail, then says done ──
{
    my $r = $eval->evaluate(
        content      => "Done.",
        tool_calls   => [
            tc(name => 'file_operations', operation => 'write_file', success => 1),
            tc(name => 'terminal_operations', operation => 'exec', success => 1,
               exit_code => 1, arguments => '{"command":"npm test"}',
               result => "3 failing tests"),
        ],
        user_input   => "Fix the bug and run the tests",
        retry_count  => 0,
    );
    is($r->{decision}, 'continue', 'Test 7: Tests failed, says done = continue');
    ok(grep { $_ eq 'verification_failed' } @{$r->{blockers}}, 'Test 7: blocks on verification_failed');
}

# ── 8. Agent creates a regression test but never runs it when verification required ──
{
    my $r = $eval->evaluate(
        content      => "I created a regression test.",
        tool_calls   => [
            tc(name => 'file_operations', operation => 'write_file', success => 1),
        ],
        user_input   => "Fix the bug and run the tests to verify",
        retry_count  => 0,
    );
    is($r->{decision}, 'continue', 'Test 8: Test created but not run when required = continue');
    ok(grep { $_ eq 'verification_pending' } @{$r->{blockers}}, 'Test 8: blocks on verification_pending');
}

# ── 9. Agent says "I still need to..." and stops ──
{
    my $r = $eval->evaluate(
        content      => "I still need to run the tests, but I will do that next.",
        tool_calls   => [tc(name => 'file_operations', operation => 'write_file', success => 1)],
        user_input   => "fix the bug",
        retry_count  => 0,
    );
    is($r->{decision}, 'continue', 'Test 9: "I still need to..." = continue');
    ok(grep { $_ eq 'text_unfinished' } @{$r->{blockers}}, 'Test 9: blocks on text_unfinished');
}

# ── 10. Agent performs an intermediate tool action and produces a clearly unfinished continuation ──
{
    my $r = $eval->evaluate(
        content      => "Let me check the next file",
        tool_calls   => [tc(name => 'file_operations', operation => 'read_file', success => 1)],
        user_input   => "examine the codebase",
        retry_count  => 0,
    );
    is($r->{decision}, 'continue', 'Test 10: Unfinished continuation after tool = continue');
}

# ── 11. Empty response after meaningful tool work ──
{
    my $r = $eval->evaluate(
        content      => "",
        tool_calls   => [tc(name => 'file_operations', operation => 'read_file', success => 1)],
        user_input   => "read the file",
        retry_count  => 0,
    );
    is($r->{decision}, 'continue', 'Test 11: Empty response after tools = continue');
    ok(grep { $_ eq 'empty_response' } @{$r->{blockers}}, 'Test 11: blocks on empty_response');
}

# ── 12. Relevant todo remains in-progress when workflow has more work ──
{
    my $session = make_session([{
        id => 1, title => 'Fix bug', status => 'in-progress',
        description => 'Fix the login bug',
    }]);
    my $r = $eval->evaluate(
        content      => "Done.",
        tool_calls   => [],
        session      => $session,
        user_input   => "fix the bug",
        retry_count  => 0,
    );
    is($r->{decision}, 'continue', 'Test 12: In-progress todo = continue');
    ok(grep { $_ eq 'todo_in_progress' } @{$r->{blockers}}, 'Test 12: blocks on todo_in_progress');
}

# ── 13. Blocked todo whose block IS resolvable by agent should not be treated as legitimate completion ──
{
    my $session = make_session([{
        id => 1, title => 'Fix test', status => 'blocked',
        blockedReason => 'test needs updating',
    }]);
    my $r = $eval->evaluate(
        content      => "All done.",
        tool_calls   => [],
        session      => $session,
        user_input   => "fix things",
        retry_count  => 0,
    );
    is($r->{decision}, 'continue', 'Test 13: Actionable blocked todo = continue');
    ok(grep { $_ eq 'todo_blocked' } @{$r->{blockers}}, 'Test 13: blocks on todo_blocked');
}

# ── 14. APIManager reports stream truncation ──
{
    # APIManager surfaces truncation as success => 0 with error_type =>
    # 'truncated'. The completion gate only sees api_response with
    # finish_reason. When finish_reason is absent entirely, that's a
    # transport error handled by _handle_api_error before reaching us.
    # Here we verify the gate handles a missing finish_reason gracefully.
    my $r = $eval->evaluate(
        content       => "Partial response",
        api_response  => { success => 1, content => "Partial response" },
        tool_calls    => [],
        user_input    => "explain",
        retry_count   => 0,
    );
    is($r->{decision}, 'complete', 'Test 14: Missing finish_reason but content present = complete (transport errors handled upstream)');
}

# ── 15. Legitimate finish_reason=stop with complete content ──
{
    my $r = $eval->evaluate(
        content       => "The task is complete.",
        api_response  => { finish_reason => 'stop' },
        tool_calls    => [],
        user_input    => "do something",
        retry_count   => 0,
    );
    is($r->{decision}, 'complete', 'Test 15: finish_reason=stop with complete content = complete');
    is($r->{finish_reason}, 'stop', 'Test 15: finish_reason is surfaced');
}

# ── 16. finish_reason=length = deterministic truncation ──
{
    my $r = $eval->evaluate(
        content       => "Here is the beginning of",
        api_response  => { finish_reason => 'length' },
        tool_calls    => [],
        user_input    => "explain",
        retry_count   => 0,
    );
    is($r->{decision}, 'continue', 'Test 16: finish_reason=length = continue');
    ok(grep { $_ eq 'api_truncated' } @{$r->{blockers}}, 'Test 16: blocks on api_truncated');
}

# ── 17. Responses API completion ──
{
    my $r = $eval->evaluate(
        content       => "Done.",
        api_response  => { finish_reason => 'stop', responses_reasoning_items => [{ type => 'reasoning' }] },
        tool_calls    => [],
        user_input    => "explain",
        retry_count   => 0,
    );
    is($r->{decision}, 'complete', 'Test 17: Responses API with reasoning_items = complete (not truncated)');
}

# ── 18. OpenAI-compatible streaming completion ──
{
    my $r = $eval->evaluate(
        content       => "All done.",
        api_response  => { finish_reason => 'stop', tool_calls => [] },
        tool_calls    => [],
        user_input    => "fix it",
        retry_count   => 0,
    );
    is($r->{decision}, 'complete', 'Test 18: Streaming stop with complete content = complete');
}

# ── 19. Reasoning-only / empty-visible-content provider responses ──
{
    my $r = $eval->evaluate(
        content       => "",
        api_response  => {
            reasoning_content => "The answer is 42.",
            finish_reason     => 'stop',
        },
        tool_calls    => [tc(name => 'file_operations', operation => 'read_file', success => 1)],
        user_input    => "answer a question",
        retry_count   => 0,
    );
    is($r->{decision}, 'complete', 'Test 19: Empty content but separate reasoning = complete (not premature)');
}

# ── Additional: Tool error followed by successful retry → resolved ──
{
    my $r = $eval->evaluate(
        content      => "Done.",
        tool_calls   => [
            tc(name => 'terminal_operations', operation => 'exec', success => 0, error => "command not found", exit_code => 127),
            tc(name => 'terminal_operations', operation => 'exec', success => 1, exit_code => 0, result => "All tests pass"),
        ],
        user_input   => "run tests",
        retry_count  => 0,
    );
    is($r->{decision}, 'complete', 'Additional: Error then retry = complete (resolved)');
}

# ── Additional: Verification obligation does NOT trigger when no verification mentioned ──
{
    my $r = $eval->evaluate(
        content      => "Done.",
        tool_calls   => [tc(name => 'file_operations', operation => 'write_file', success => 1)],
        user_input   => "Write a test script for connectivity",
        retry_count  => 0,
    );
    is($r->{decision}, 'complete', 'Additional: "write a test script" does not trigger verification obligation');
}

# ── Additional: Exhausted budget surfaces as uncertain ──
{
    my $r = $eval->evaluate(
        content      => "I still need to fix this.",
        tool_calls   => [tc(name => 'file_operations', operation => 'read_file', success => 1)],
        user_input   => "check something",
        retry_count  => 2,
        max_retries  => 2,
    );
    is($r->{decision}, 'uncertain', 'Additional: Exhausted budget = uncertain');
    ok($r->{exhausted}, 'Additional: exhausted flag is set');
    ok(length($r->{continuation}) > 10, 'Additional: exhausted continuation message is meaningful');
}

# ── Additional: Long mid-sentence response with tools = not premature ──
{
    my $r = $eval->evaluate(
        content      => "I have started the analysis and gathered the initial data, but I still need to",
        tool_calls   => [tc(name => 'file_operations', operation => 'read_file', success => 1)],
        user_input   => "analyze code",
        retry_count  => 0,
    );
    # Long content with "I still need to" → blocks on textual signal
    is($r->{decision}, 'continue', 'Additional: Long mid-sentence with "I still need to" = continue');
}

# ── Additional: Short complete response after tool work, terminal punct ──
{
    my $r = $eval->evaluate(
        content      => "The fix is complete. The tests pass.",
        tool_calls   => [tc(name => 'terminal_operations', operation => 'exec', success => 1, exit_code => 0, result => "All tests passed!")],
        user_input   => "Fix the bug and run the tests",
        retry_count  => 0,
    );
    is($r->{decision}, 'complete', 'Additional: Short complete summary after successful test = complete');
}

# ── Additional: Non-verification terminal command (ls) does not count as verification ──
{
    my $r = $eval->evaluate(
        content      => "Here are the files.",
        tool_calls   => [
            tc(name => 'file_operations', operation => 'write_file', success => 1),
            tc(name => 'terminal_operations', operation => 'exec', success => 1, exit_code => 0,
               arguments => '{"command":"ls -la"}', result => "total 0"),
        ],
        user_input   => "Fix the bug and run the tests",
        retry_count  => 0,
    );
    # ls is not a verification command, so verification_pending should NOT fire
    # even though requirements (a) and (b) are met
    is($r->{decision}, 'continue', 'Additional: ls does not satisfy verification obligation');
    ok(grep { $_ eq 'verification_pending' } @{$r->{blockers}}, 'Additional: verification still pending because ls is not verification');
}

# ── Additional: Content wrapped in [conversation] tags should not false-positive ──
{
    # APIManager wraps non-streaming responses in [conversation]...[/conversation].
    # The orchestrator strips this before calling evaluate(). Here we simulate
    # the stripped content to verify "OK" is treated as complete (not
    # incomplete_structure because it ends in a letter).
    my $r = $eval->evaluate(
        content      => "OK",
        tool_calls   => [tc(name => 'file_operations', operation => 'read_file', success => 1)],
        user_input   => "read the file",
        retry_count  => 0,
    );
    is($r->{decision}, 'complete', 'Additional: "OK" after tool work = complete (ends in letter, no unfinished intent)');
}

# ── Additional: Both session_goals and TodoStore checked independently ──
{
    # session_goals has a completed todo, TodoStore has an in-progress todo
    my $session = make_session([
        { id => 1, title => 'Completed goal', status => 'completed' },
    ]);
    # Simulate TodoStore having an in_progress todo by making the session
    # state also have it (in real usage, TodoStore is a separate file).
    # The evaluator should check session_goals first, find nothing blocking,
    # then check TodoStore. Since we can't easily mock TodoStore in a
    # unit test, we test session_goals here.
    my $r = $eval->evaluate(
        content      => "Done.",
        tool_calls   => [],
        session      => $session,
        user_input   => "do something",
        retry_count  => 0,
    );
    is($r->{decision}, 'complete', 'Additional: Completed session_goals todo = complete');
}

# ── Additional: Tool error with no following success = unresolved ──
{
    my $r = $eval->evaluate(
        content      => "Done.",
        tool_calls   => [
            tc(name => 'file_operations', operation => 'write_file', success => 1),
            tc(name => 'file_operations', operation => 'replace_string', success => 0, error => "Permission denied"),
        ],
        user_input   => "fix the file",
        retry_count  => 0,
    );
    is($r->{decision}, 'continue', 'Additional: Unresolved tool error = continue');
    ok(grep { $_ eq 'tool_error' } @{$r->{blockers}}, 'Additional: blocks on unresolved tool error');
}

# ── Additional: finish_reason=stop with tool_calls present ──
{
    # The completion gate is only reached when there are no tool calls in
    # the CURRENT api_response. But finish_reason=stop is the normal case.
    my $r = $eval->evaluate(
        content      => "The fix is complete.",
        api_response  => { finish_reason => 'stop' },
        tool_calls   => [tc(name => 'terminal_operations', operation => 'exec', success => 1, exit_code => 0, result => "All pass")],
        user_input   => "Fix the bug and run tests",
        retry_count  => 0,
    );
    is($r->{decision}, 'complete', 'Additional: finish_reason=stop with successful tools = complete');
}

# ── Additional: Multiple unfinished intent patterns in one response ──
{
    my $r = $eval->evaluate(
        content      => "I still need to fix this and then verify the tests.",
        tool_calls   => [],
        user_input   => "fix it",
        retry_count  => 0,
    );
    is($r->{decision}, 'continue', 'Additional: Multiple unfinished intent phrases = continue');
    ok(grep { $_ eq 'text_unfinished' } @{$r->{blockers}}, 'Additional: blocks on text_unfinished');
}

# ── Additional: "Before I finish" pattern ──
{
    my $r = $eval->evaluate(
        content      => "Before I finish, let me note that the tests need updating.",
        tool_calls   => [],
        user_input   => "fix it",
        retry_count  => 0,
    );
    is($r->{decision}, 'continue', 'Additional: "Before I finish" = continue');
}

# ── Additional: "The next step is" pattern ──
{
    my $r = $eval->evaluate(
        content      => "The next step is to run the test suite.",
        tool_calls   => [],
        user_input   => "fix it",
        retry_count  => 0,
    );
    is($r->{decision}, 'continue', 'Additional: "The next step is" = continue');
}

# ── Additional: Incomplete structure (ends with colon, short, no tools) ──
{
    # No tool calls -> completion gate doesn't block on textual signals
    # (the old heuristic also only fired with tool calls). But the
    # shim passes synthetic tool calls. This test is for the raw evaluator.
    my $r = $eval->evaluate(
        content      => "Here are the results:",
        tool_calls   => [],
        user_input   => "check something",
        retry_count  => 0,
    );
    is($r->{decision}, 'complete', 'Additional: Short response ending with colon, no tools = complete (no tool activity)');
}

# ── Additional: Verification command succeeds (exit 0) with verification required ──
{
    my $r = $eval->evaluate(
        content      => "All tests pass.",
        tool_calls   => [
            tc(name => 'file_operations', operation => 'write_file', success => 1),
            tc(name => 'terminal_operations', operation => 'exec', success => 1, exit_code => 0,
               arguments => '{"command":"npm test"}', result => "All pass"),
        ],
        user_input   => "Fix the bug and run the tests to verify the fix",
        retry_count  => 0,
    );
    is($r->{decision}, 'complete', 'Additional: Verification succeeded = complete');
}

# ── Additional: Backward compat — tool_calls_made without success field ──
{
    # Older tool_calls_made entries only have {name, arguments, result}.
    # The evaluator should handle missing success field gracefully.
    my $r = $eval->evaluate(
        content      => "Done.",
        tool_calls   => [{
            name => 'file_operations',
            arguments => '{}',
            result => 'some output',
            # no success field, no error field
        }],
        user_input   => "fix it",
        retry_count  => 0,
    );
    # Without success field and without error field, the tool should be
    # treated as successful (backward compat).
    is($r->{decision}, 'complete', 'Additional: Missing success field treated as success (backward compat)');
}

done_testing();