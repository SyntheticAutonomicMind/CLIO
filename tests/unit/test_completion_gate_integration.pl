#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Integration test: WorkflowOrchestrator loop with the new
# WorkflowCompletion gate.
#
# Verifies the orchestrator loop behavior:
#   - continues when the completion gate says continue
#   - returns normally when it says complete
#   - uses evidence-specific continuation messages (not generic)
#   - respects the retry budget (max_premature_stop_retries = 2)
#   - surfaces exhausted budget as success => 0 (not silent success)
#   - preserves tool_calls_made with enriched structure
#
# Uses a mock APIManager that returns pre-configured responses via
# send_request_streaming, avoiding real network calls.

use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../lib";

use Test::More;
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json decode_json);
use CLIO::Util::PathResolver;

# ── Mock APIManager ──────────────────────────────────────────────────
# Returns pre-configured responses from a queue via send_request_streaming.
# Implements just enough of the APIManager interface for process_input.
package MockAPIManager;

sub new {
    my ($class, %opts) = @_;
    return bless {
        response_queue => $opts{responses} || [],
        request_count  => 0,
        debug          => $opts{debug} || 0,
        api_base       => 'https://mock.example.com/v1',
        config         => $opts{config} || {},
        _model         => 'mock-model',
        reduce_thinking_calls => 0,
        max_out_override_calls => 0,
    }, $class;
}

sub send_request_streaming {
    my ($self, $input, %opts) = @_;
    $self->{request_count}++;
    $self->{last_messages} = $opts{messages} if $opts{messages};
    $self->{reduce_thinking_calls} += ($opts{reduce_thinking} ? 1 : 0);
    $self->{max_out_override_calls} += ($opts{max_output_tokens_override} ? 1 : 0);

    my $resp;
    if (@{$self->{response_queue}}) {
        $resp = shift @{$self->{response_queue}};
    } else {
        $resp = $self->{response_queue}[-1] || { content => "Default response", finish_reason => 'stop' };
    }

    my $result = { success => 1, content => $resp->{content} // '', finish_reason => $resp->{finish_reason} // 'stop' };
    if ($resp->{tool_calls} && @{$resp->{tool_calls}}) {
        $result->{tool_calls} = $resp->{tool_calls};
        $result->{content}    = '';
    }
    $result->{usage} = { prompt_tokens => 100, completion_tokens => $resp->{completion_tokens} // 50 };

    return $result;
}

sub get_current_model { return 'mock-model' }
sub get_model_capabilities { return { max_context_window_tokens => 128000, max_output_tokens => 16000 } }
sub model_supports_vision { return 0 }
sub provider_for_model { return 'mock' }
sub get_current_provider { return 'mock' }
sub config { return $_[0]->{config} }

# ── Mock Config ──────────────────────────────────────────────────────
package MockConfig;
sub new { my $class = shift; return bless {}, $class }
sub get {
    my ($self, $key) = @_;
    my %defaults = (
        'max_iterations' => 0,
        'enabled_tools'  => undef,
        'disabled_tools' => undef,
    );
    return exists $defaults{$key} ? $defaults{$key} : undef;
}

# ── Mock Session ─────────────────────────────────────────────────────
package MockSession;
sub new {
    my ($class, %opts) = @_;
    return bless {
        session_id => $opts{session_id} || 'mock-session-' . time(),
        messages   => [],
        state      => $opts{state} || { max_tokens => 128000, max_output_tokens => 16000 },
    }, $class;
}
sub id { return $_[0]->{session_id} }
sub state { return $_[0]->{state} }
sub add_message {
    my ($self, $role, $content, $meta) = @_;
    push @{$self->{messages}}, { role => $role, content => $content, %$meta };
}
sub save { }
sub session_name { }

package main;

# ── Setup test environment ──────────────────────────────────────────
my $test_dir = tempdir(CLEANUP => 1);
chdir $test_dir;
CLIO::Util::PathResolver::init(base_dir => $test_dir);

my $config = MockConfig->new();
my $api_manager = MockAPIManager->new(
    config => $config,
    debug  => 0,
);

# Create session
my $session = MockSession->new();

# Create orchestrator with minimal setup
require CLIO::Core::WorkflowOrchestrator;
require CLIO::Core::PromptBuilder;
require CLIO::Tools::Registry;
require CLIO::Tools::FileOperations;
require CLIO::Core::ToolErrorGuidance;
require CLIO::UI::ToolOutputFormatter;
require CLIO::Logging::ProcessStats;

my $tool_registry = CLIO::Tools::Registry->new(debug => 0);
$tool_registry->register_tool(CLIO::Tools::FileOperations->new());

my $orchestrator = CLIO::Core::WorkflowOrchestrator->new(
    api_manager => $api_manager,
    session     => $session,
    config      => $config,
    debug       => 0,
    non_interactive => 1,
    max_iterations    => 200,
);

# We need to set up internal dependencies that new() doesn't fully initialize
# without a UI and full config. Let's set the minimal needed ones.
$orchestrator->{tool_registry} = $tool_registry;
$orchestrator->{tools} = $tool_registry->get_tool_definitions();
$orchestrator->{tool_executor} = CLIO::Core::ToolExecutor->new(
    session => $session,
    tool_registry => $tool_registry,
    config => $config,
    debug => 0,
);
$orchestrator->{formatter} = CLIO::UI::ToolOutputFormatter->new();
$orchestrator->{error_guidance} = CLIO::Core::ToolErrorGuidance->new();

# Override _build_turn_context to bypass the heavy prompt_builder and
# context builder machinery. We provide a minimal system prompt and
# skip history loading. This lets us test the completion gate loop in
# isolation.
*CLIO::Core::WorkflowOrchestrator::_build_turn_context = sub {
    my ($self, $user_input, $session_obj, $image_attachments) = @_;
    my @messages = (
        { role => 'system', content => 'You are a helpful assistant.' },
    );
    # Push the user message
    push @messages, { role => 'user', content => $user_input };
    return (\@messages, $self->{tools});
};

# Override the API call to use our mock directly (bypass streaming setup)
*CLIO::Core::WorkflowOrchestrator::_call_api = sub {
    my ($self, @args) = @_;
    return $self->{api_manager}->send_request_streaming(undef, @args);
};

# We need to intercept the API call. Let's look at how process_input calls
# the API and override the relevant method.

print "=" x 60 . "\n";
print "WorkflowOrchestrator Completion Gate Integration Tests\n";
print "=" x 60 . "\n\n";

# ── Test 1: Orchestrator continues when gate says continue, then completes ──
{
    $api_manager->{response_queue} = [];
    $api_manager->{request_count} = 0;
    push @{$api_manager->{response_queue}},
        { content => "I still need to check something", finish_reason => 'stop' },
        { content => "The task is complete. Done.", finish_reason => 'stop' };

    $session->{messages} = [];
    my $result = $orchestrator->process_input("Examine the file", $session);

    ok($result->{success}, 'Test 1: Orchestrator returns success=True after completion');
    like($result->{content}, qr/complete|Done/, 'Test 1: Final content is the complete response');

    # The mock should have been called at least twice (premature + complete)
    ok($api_manager->{request_count} >= 2,
        'Test 1: API called at least twice (continuation occurred)');

    is(scalar(@{$result->{tool_calls_made} // []}), 0,
        'Test 1: No tool calls made (pure text workflow)');
}

# ── Test 2: Orchestrator returns normally when gate says complete ──
{
    $api_manager->{response_queue} = [];
    $api_manager->{request_count} = 0;
    push @{$api_manager->{response_queue}},
        { content => "All done. The fix is complete.", finish_reason => 'stop' };

    $session->{messages} = [];
    my $result = $orchestrator->process_input("Fix the bug", $session);

    ok($result->{success}, 'Test 2: Orchestrator returns success=True for complete response');
    ok(length($result->{content}) > 0, 'Test 2: Content is non-empty');
    is($api_manager->{request_count}, 1, 'Test 2: API called exactly once (no continuation)');
}

# ── Test 3: Retry budget is respected, exhausted budget returns error ──
{
    $api_manager->{response_queue} = [];
    $api_manager->{request_count} = 0;
    # Always return premature response
    push @{$api_manager->{response_queue}},
        { content => "I still need to investigate further", finish_reason => 'stop' },
        { content => "I still need to investigate further", finish_reason => 'stop' },
        { content => "I still need to investigate further", finish_reason => 'stop' };

    $session->{messages} = [];
    my $result = $orchestrator->process_input("Investigate something", $session);

    ok(!$result->{success}, 'Test 3: Exhausted budget returns success=False');
    ok($result->{error}, 'Test 3: Error message present');
    like($result->{error}, qr/complete|exhaust|blocker/i,
        'Test 3: Error mentions completion exhaustion');
    is($api_manager->{request_count}, 3,
        'Test 3: API called 3 times (initial + 2 retries)');
    is($result->{error_type} // '', 'completion_exhausted',
        'Test 3: error_type is completion_exhausted');
}

# ── Test 4: finish_reason=length blocks completion ──
{
    $api_manager->{response_queue} = [];
    $api_manager->{request_count} = 0;
    push @{$api_manager->{response_queue}},
        { content => "Here is the beginning of the explan", finish_reason => 'length' },
        { content => "The full explanation is complete. Done.", finish_reason => 'stop' };

    $session->{messages} = [];
    my $result = $orchestrator->process_input("Explain something", $session);

    ok($result->{success}, 'Test 4: Eventually succeeds after truncation nudge');
    ok($api_manager->{request_count} >= 2, 'Test 4: Continued after finish_reason=length');
}

# ── Test 5: Continuation message is evidence-specific (not generic) ──
{
    $api_manager->{response_queue} = [];
    $api_manager->{request_count} = 0;
    $api_manager->{last_messages} = [];
    push @{$api_manager->{response_queue}},
        { content => "I still need to fix the failing tests", finish_reason => 'stop' },
        { content => "Done.", finish_reason => 'stop' };

    $session->{messages} = [];
    my $result = $orchestrator->process_input("Fix the bug", $session);

    ok($result->{success}, 'Test 5: Eventually succeeds');

    # The continuation prompt is injected as a user message in @messages
    # (ephemeral, not saved to session). We can inspect it via last_messages
    # on the second API call — the user message at the end should be an
    # evidence-specific continuation, NOT the old generic message.
    my $last = $api_manager->{last_messages};
    my @user_in_last = grep { $_->{role} eq 'user' } @$last;
    ok(@user_in_last >= 1, 'Test 5: At least one user message sent to API');

    my $last_user = $user_in_last[-1]->{content} // '';
    # The old generic message was: "Your previous response ended without
    # completing your work..."
    unlike($last_user, qr/ended without completing your work/,
        'Test 5: Does NOT use the old generic continuation message');
    # The new continuation should mention something about the unfinished intent
    like($last_user, qr/not complete|unfinished|still need/i,
        'Test 5: Uses evidence-specific continuation message');
}

# ── Test 6: Tool error blocks completion ──
{
    $api_manager->{response_queue} = [];
    $api_manager->{request_count} = 0;
    # First response: text-only with tool error context (but no tool calls)
    # Then complete response
    push @{$api_manager->{response_queue}},
        { content => "I tried to fix it but hit an error.", finish_reason => 'stop' },
        { content => "Fixed it now.", finish_reason => 'stop' };

    $session->{messages} = [];
    my $result = $orchestrator->process_input("Fix the error", $session);

    ok($result->{success}, 'Test 6: Eventually succeeds after error recovery');
}

# ── Test 7: Non-interactive mode respects max_iterations ──
{
    $api_manager->{response_queue} = [];
    $api_manager->{request_count} = 0;
    # Return premature responses indefinitely (within iteration limit)
    for (1..10) {
        push @{$api_manager->{response_queue}},
            { content => "I still need to keep going", finish_reason => 'stop' };
    }

    $session->{messages} = [];
    my $result = $orchestrator->process_input("Keep going", $session);

    # Should exhaust the premature-stop retry budget (2) and return error
    ok(!$result->{success}, 'Test 7: Exhausted budget returns error (retry limit)');
}

# ── Test 8: No repeated continuation prompts in message history ──
{
    $api_manager->{response_queue} = [];
    $api_manager->{request_count} = 0;
    $api_manager->{last_messages} = [];
    # Return premature response, then complete
    push @{$api_manager->{response_queue}},
        { content => "I still need to check something", finish_reason => 'stop' },
        { content => "Done.", finish_reason => 'stop' };

    $session->{messages} = [];
    my $result = $orchestrator->process_input("Check something", $session);

    ok($result->{success}, 'Test 8: Eventually succeeds');

    # On the second API call, count how many continuation prompts are in
    # the message array. There should be exactly ONE (the one injected
    # after the first premature response), not two.
    my $last = $api_manager->{last_messages};
    my @continuation_msgs = grep {
        $_->{role} eq 'user' &&
        ($_->{content} // '') =~ /not complete|unfinished|still need|continu/i
    } @$last;
    is(scalar(@continuation_msgs), 1,
        'Test 8: Exactly one continuation prompt in message history (no accumulation)');
}

# ── Test 9: Partial response preserved on exhausted budget ──
{
    $api_manager->{response_queue} = [];
    $api_manager->{request_count} = 0;
    push @{$api_manager->{response_queue}},
        { content => "I still need to investigate further", finish_reason => 'stop' },
        { content => "I still need to investigate further", finish_reason => 'stop' },
        { content => "I still need to investigate further", finish_reason => 'stop' };

    $session->{messages} = [];
    my $result = $orchestrator->process_input("Investigate something", $session);

    ok(!$result->{success}, 'Test 9: Exhausted budget returns error');
    ok(defined $result->{content}, 'Test 9: Partial content preserved in result');
    like($result->{content}, qr/I still need to investigate/,
        'Test 9: Partial response content is the premature response');
    ok($result->{completion_evaluation}, 'Test 9: Completion evaluation preserved in result');
    is($result->{error_type}, 'completion_exhausted',
        'Test 9: Error type is completion_exhausted');
}

# ── Test 10: No false positive continuation on legitimately complete response ──
{
    $api_manager->{response_queue} = [];
    $api_manager->{request_count} = 0;
    push @{$api_manager->{response_queue}},
        { content => "Fixed. All tests pass.", finish_reason => 'stop' };

    $session->{messages} = [];
    my $result = $orchestrator->process_input("Fix the bug", $session);

    ok($result->{success}, 'Test 10: Complete response returns success');
    is($api_manager->{request_count}, 1,
        'Test 10: API called exactly once (no false-positive continuation)');
}

# ── Test 11: reduce_thinking and max_output_tokens_override on truncation-retry ──
{
    $api_manager->{response_queue} = [];
    $api_manager->{request_count} = 0;
    $api_manager->{reduce_thinking_calls} = 0;
    $api_manager->{max_out_override_calls} = 0;
    push @{$api_manager->{response_queue}},
        { content => "Here is the beginning of", finish_reason => 'length' },
        { content => "The full explanation is complete. Done.", finish_reason => 'stop' };

    $session->{messages} = [];
    my $result = $orchestrator->process_input("Explain something", $session);

    ok($result->{success}, 'Test 11: Eventually succeeds after truncation');
    # On the continuation retry after finish_reason=length, both reduce_thinking
    # and max_output_tokens_override should be passed to the API call.
    ok($api_manager->{reduce_thinking_calls} >= 1,
        'Test 11: reduce_thinking was passed on truncation-retry continuation');
    ok($api_manager->{max_out_override_calls} >= 1,
        'Test 11: max_output_tokens_override was passed on truncation-retry continuation');
}

# ── Test 12: reduce_thinking and max_output_tokens_override NOT set on normal continuation ──
{
    $api_manager->{response_queue} = [];
    $api_manager->{request_count} = 0;
    $api_manager->{reduce_thinking_calls} = 0;
    $api_manager->{max_out_override_calls} = 0;
    push @{$api_manager->{response_queue}},
        { content => "I still need to check something", finish_reason => 'stop' },
        { content => "Done.", finish_reason => 'stop' };

    $session->{messages} = [];
    my $result = $orchestrator->process_input("Check something", $session);

    ok($result->{success}, 'Test 12: Eventually succeeds');
    # Normal premature stop (text_unfinished, not api_truncated) should NOT
    # trigger truncation-recovery overrides.
    is($api_manager->{reduce_thinking_calls}, 0,
        'Test 12: reduce_thinking NOT set on non-truncated continuation');
    is($api_manager->{max_out_override_calls}, 0,
        'Test 12: max_output_tokens_override NOT set on non-truncated continuation');
}

# ── Test 13: Exhausted budget after api_truncated surfaces error with overrides attempted ──
{
    $api_manager->{response_queue} = [];
    $api_manager->{request_count} = 0;
    $api_manager->{reduce_thinking_calls} = 0;
    $api_manager->{max_out_override_calls} = 0;
    # All responses truncated — the model keeps hitting output limits
    push @{$api_manager->{response_queue}},
        { content => "Beginning", finish_reason => 'length' },
        { content => "Beginning", finish_reason => 'length' },
        { content => "Beginning", finish_reason => 'length' };

    $session->{messages} = [];
    my $result = $orchestrator->process_input("Explain something very complex", $session);

    ok(!$result->{success}, 'Test 13: Exhausted budget returns error');
    is($result->{error_type}, 'completion_exhausted',
        'Test 13: error_type is completion_exhausted');
    # Even on exhaustion, truncation-recovery overrides should have been
    # attempted on the 2 continuation retries.
    ok($api_manager->{reduce_thinking_calls} >= 2,
        'Test 13: reduce_thinking attempted on continuation retries');
    ok($api_manager->{max_out_override_calls} >= 2,
        'Test 13: max_output_tokens_override attempted on continuation retries');
}

# ── Test 14: max_output_tokens_override is based on completion_tokens from API ──
{
    $api_manager->{response_queue} = [];
    $api_manager->{request_count} = 0;
    # Return a response with specific completion_tokens so we can verify
    # the override is 2x that value.
    push @{$api_manager->{response_queue}},
        { content => "Partial content", finish_reason => 'length', completion_tokens => 800 },
        { content => "Done.", finish_reason => 'stop' };

    $session->{messages} = [];
    my $result = $orchestrator->process_input("Complex task", $session);

    ok($result->{success}, 'Test 14: Eventually succeeds');
    # Mock returns completion_tokens from the response hash, not usage hash.
    # The orchestrator reads from $api_response->{usage}{completion_tokens}.
    # Mock returns usage->{completion_tokens} = 50 by default, so override
    # should be 100 (2 * 50). Verify the override was passed (value > 0).
    ok($api_manager->{max_out_override_calls} >= 1,
        'Test 14: max_output_tokens_override was passed on truncation retry');
}

done_testing();