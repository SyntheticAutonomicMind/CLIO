#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Integration test: WorkflowOrchestrator loop with the WorkflowCompletion gate.
#
# The gate only detects two premature-stop conditions:
#   1. finish_reason=length (API truncation)
#   2. Empty response after tool activity (reasoning-only turn)
#
# When the gate fires and retries remain, the orchestrator nudges the model
# with a continuation message and retries. When retries are exhausted, the
# workflow ends gracefully with the agent's content (success => 1) — no
# error is surfaced to the user.
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
my $api_manager = MockAPIManager->new(config => $config, debug => 0);
my $session = MockSession->new();

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

# Bypass heavy prompt/context machinery
*CLIO::Core::WorkflowOrchestrator::_build_turn_context = sub {
    my ($self, $user_input, $session_obj, $image_attachments) = @_;
    return (
        [ { role => 'system', content => 'You are a helpful assistant.' },
          { role => 'user', content => $user_input } ],
        $self->{tools},
    );
};

*CLIO::Core::WorkflowOrchestrator::_call_api = sub {
    my ($self, @args) = @_;
    return $self->{api_manager}->send_request_streaming(undef, @args);
};

print "=" x 60 . "\n";
print "WorkflowOrchestrator Completion Gate Integration Tests\n";
print "=" x 60 . "\n\n";

# ── Test 1: Empty response after tool activity triggers nudge ──
# To simulate "empty response after tool activity" without actual tool
# calls in the mock (which requires real tool execution), we test the
# truncation case which has the same nudging mechanism.
{
    $api_manager->{response_queue} = [];
    $api_manager->{request_count} = 0;
    push @{$api_manager->{response_queue}},
        { content => "Here is the beginning of the explanation", finish_reason => 'length' },
        { content => "The full explanation is complete. Done.", finish_reason => 'stop' };

    $session->{messages} = [];
    my $result = $orchestrator->process_input("Explain something", $session);

    ok($result->{success}, 'Test 1: Eventually succeeds after truncation nudge');
    ok($api_manager->{request_count} >= 2, 'Test 1: API called at least twice (nudge occurred)');
    like($result->{content}, qr/complete|Done/, 'Test 1: Final content is the complete response');
}

# ── Test 2: Complete response returns success with one API call ──
{
    $api_manager->{response_queue} = [];
    $api_manager->{request_count} = 0;
    push @{$api_manager->{response_queue}},
        { content => "All done. The fix is complete.", finish_reason => 'stop' };

    $session->{messages} = [];
    my $result = $orchestrator->process_input("Fix the bug", $session);

    ok($result->{success}, 'Test 2: Complete response returns success=True');
    ok(length($result->{content}) > 0, 'Test 2: Content is non-empty');
    is($api_manager->{request_count}, 1, 'Test 2: API called exactly once (no nudge)');
}

# ── Test 3: Exhausted budget ends gracefully (success=1, no error) ──
{
    $api_manager->{response_queue} = [];
    $api_manager->{request_count} = 0;
    # Always return truncated — model keeps hitting output limits
    push @{$api_manager->{response_queue}},
        { content => "Beginning", finish_reason => 'length' },
        { content => "Beginning", finish_reason => 'length' },
        { content => "Beginning", finish_reason => 'length' };

    $session->{messages} = [];
    my $result = $orchestrator->process_input("Explain something very complex", $session);

    # Exhausted budget should NOT surface an error — the workflow ends
    # with the agent's content as success.
    ok($result->{success}, 'Test 3: Exhausted budget returns success=True (graceful end)');
    ok(!defined $result->{error} || !$result->{error}, 'Test 3: No error message surfaced to user');
    is($api_manager->{request_count}, 3,
        'Test 3: API called 3 times (initial + 2 nudges)');
    like($result->{content}, qr/Beginning/,
        'Test 3: Partial content is the last API response');
}

# ── Test 4: Reduction flags on truncation-retry ──
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

    ok($result->{success}, 'Test 4: Eventually succeeds after truncation');
    ok($api_manager->{reduce_thinking_calls} >= 1,
        'Test 4: reduce_thinking was passed on truncation-retry nudge');
    ok($api_manager->{max_out_override_calls} >= 1,
        'Test 4: max_output_tokens_override was passed on truncation-retry nudge');
}

# ── Test 5: No false positive nudge on genuinely complete response ──
{
    $api_manager->{response_queue} = [];
    $api_manager->{request_count} = 0;
    push @{$api_manager->{response_queue}},
        { content => "Fixed. All tests pass.", finish_reason => 'stop' };

    $session->{messages} = [];
    my $result = $orchestrator->process_input("Fix the bug", $session);

    ok($result->{success}, 'Test 5: Complete response returns success');
    is($api_manager->{request_count}, 1,
        'Test 5: API called exactly once (no false-positive nudge)');
}

# ── Test 6: No false positive nudge on short response after no tools ──
{
    $api_manager->{response_queue} = [];
    $api_manager->{request_count} = 0;
    push @{$api_manager->{response_queue}},
        { content => "OK", finish_reason => 'stop' };

    $session->{messages} = [];
    my $result = $orchestrator->process_input("Do something", $session);

    ok($result->{success}, 'Test 6: Short response returns success');
    is($api_manager->{request_count}, 1, 'Test 6: No nudge on short response without tools');
}

# ── Test 7: Exhausted budget preserves partial content ──
{
    $api_manager->{response_queue} = [];
    $api_manager->{request_count} = 0;
    push @{$api_manager->{response_queue}},
        { content => "I still need to investigate further", finish_reason => 'length' },
        { content => "I still need to investigate further", finish_reason => 'length' },
        { content => "I still need to investigate further", finish_reason => 'length' };

    $session->{messages} = [];
    my $result = $orchestrator->process_input("Investigate something", $session);

    ok($result->{success}, 'Test 7: Exhausted budget returns success=True');
    ok(defined $result->{content}, 'Test 7: Content preserved');
    like($result->{content}, qr/I still need to investigate/,
        'Test 7: Partial content preserved in result');
}

# ── Test 8: Verification command failure does NOT block completion ──
{
    $api_manager->{response_queue} = [];
    $api_manager->{request_count} = 0;
    push @{$api_manager->{response_queue}},
        { content => "Done. All tests pass.", finish_reason => 'stop' };

    $session->{messages} = [];
    my $result = $orchestrator->process_input("Fix the bug and run the tests", $session);

    ok($result->{success}, 'Test 8: Complete response returns success');
    is($api_manager->{request_count}, 1, 'Test 8: API called exactly once (no spurious nudge)');
}

# ── Test 9: reduce_thinking NOT set on non-truncated responses ──
{
    $api_manager->{response_queue} = [];
    $api_manager->{request_count} = 0;
    $api_manager->{reduce_thinking_calls} = 0;
    $api_manager->{max_out_override_calls} = 0;
    push @{$api_manager->{response_queue}},
        { content => "The task is complete.", finish_reason => 'stop' };

    $session->{messages} = [];
    my $result = $orchestrator->process_input("Fix the bug", $session);

    ok($result->{success}, 'Test 9: Complete response returns success');
    is($api_manager->{reduce_thinking_calls}, 0,
        'Test 9: reduce_thinking NOT set on non-truncated response');
    is($api_manager->{max_out_override_calls}, 0,
        'Test 9: max_output_tokens_override NOT set on non-truncated response');
}

# ── Test 10: No continuation prompt accumulation ──
{
    $api_manager->{response_queue} = [];
    $api_manager->{request_count} = 0;
    $api_manager->{last_messages} = [];
    push @{$api_manager->{response_queue}},
        { content => "Here is the beginning", finish_reason => 'length' },
        { content => "Done.", finish_reason => 'stop' };

    $session->{messages} = [];
    my $result = $orchestrator->process_input("Explain something", $session);

    ok($result->{success}, 'Test 10: Eventually succeeds');
    my $last = $api_manager->{last_messages};
    my @user_msgs = grep { $_->{role} eq 'user' } @$last;
    my @continuation = grep {
        ($_->{content} // '') =~ /not complete|cut short|empty|continue/i
    } @user_msgs;
    is(scalar(@continuation), 1, 'Test 10: Exactly one continuation prompt (no accumulation)');
}

done_testing();
