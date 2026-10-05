# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Core::WorkflowCompletion;

use strict;
use warnings;
use utf8;
use CLIO::Core::Logger qw(log_debug should_log);

=head1 NAME

CLIO::Core::WorkflowCompletion - Detect when an AI agent stopped mid-workflow

=head1 DESCRIPTION

An internal retry guard. The WorkflowOrchestrator loop uses this to
decide whether the model's last response looks like a genuine final
answer or a premature stop that warrants a nudge (continuation prompt)
before retrying.

The only case it guards against is the one it was designed for: the
model emits thinking/reasoning (or goes silent) with no visible content
and no tool calls after previously being active in the workflow. In that
situation the API reports finish_reason=stop but the model never
actually finished — it just emitted its chain-of-thought and stopped.

A bounded retry budget (default 2) limits how many nudges are injected.
When the budget is exhausted, the workflow ends and whatever content
exists (partial or empty) is returned as the final answer. The gate
never surfaces errors to the user — it is an internal mechanism.

=cut

=head2 new

    my $eval = CLIO::Core::WorkflowCompletion->new();

=cut

sub new {
    my ($class, %args) = @_;
    return bless {
        debug => $args{debug} || 0,
    }, $class;
}

=head2 evaluate

Evaluate whether the workflow looks prematurely stopped.

Arguments (all hash keys):

    content       - The assistant's final response content (string)
    api_response  - Full api_response hashref from APIManager (for
                    finish_reason, reasoning_content, etc.)
    tool_calls    - Arrayref of tool-call records from @tool_calls_made
                    (enriched with name/operation/success/exit_code)
    retry_count   - Current premature-stop retry count
    max_retries   - Maximum premature-stop retries allowed (default 2)

Returns a hashref:

    {
        decision      => 'complete' | 'continue' | 'uncertain',
        reasons       => [...],          # reason codes found
        blockers      => [...],          # reason codes that block completion
        evidence      => [...],          # human-readable evidence strings
        continuation  => '...',          # nudging message for the model
        finish_reason => '...',          # from API (if available)
        exhausted     => 0 | 1,          # retry budget exhausted
    }

=cut

sub evaluate {
    my ($self, %args) = @_;

    my $content       = $args{content}       // '';
    my $api_response  = $args{api_response}  || {};
    my $tool_calls    = $args{tool_calls}    || [];
    my $retry_count   = $args{retry_count}   // 0;
    my $max_retries   = $args{max_retries}   // 2;

    my @reasons;
    my @blockers;
    my @evidence;

    my $finish_reason = $api_response->{finish_reason};
    my $content_length = length($content // '');

    # ── Layer 1: API truncation ──────────────────────────────────────
    # finish_reason=length means the model hit its output token ceiling.
    # This is deterministic truncation — the model was cut off, not done.
    # (Transport-level truncation — no finish_reason — is handled upstream
    # by APIManager as a retryable error, so we don't see it here.)
    if (defined $finish_reason && $finish_reason eq 'length') {
        push @blockers, 'api_truncated';
        push @reasons,  'api_truncated';
        push @evidence, "finish_reason=length (output truncated by token limit)";
    }
    elsif (defined $finish_reason && $finish_reason eq 'content_filter') {
        push @blockers, 'api_truncated';
        push @reasons,  'api_truncated';
        push @evidence, "finish_reason=content_filter";
    }

    # ── Layer 2: Empty response after tool activity ─────────────────
    # The core case this gate was designed for: the model was active in the
    # workflow (tool calls were made) but the final response has no content.
    # This usually means the model emitted only thinking/reasoning and no
    # actual answer — APIManager strips thinking from the visible content,
    # so the orchestrator sees an empty string. We check whether the API
    # exposed reasoning separately; if so, the empty visible content is
    # legitimate (provider surfaces reasoning in a separate channel).
    if (@$tool_calls && $content_length == 0) {
        if (!$self->_has_separate_reasoning($api_response)) {
            push @blockers, 'empty_response';
            push @reasons,  'empty_response';
            push @evidence, "empty assistant response after " . scalar(@$tool_calls) . " tool calls (no separate reasoning channel detected)";
        }
    }

    # ── Decision ──────────────────────────────────────────────────────
    my $decision = @blockers ? 'continue' : 'complete';

    # ── Retry budget ──────────────────────────────────────────────────
    my $exhausted = 0;
    if ($decision eq 'continue' && $retry_count >= $max_retries) {
        $exhausted = 1;
        $decision  = 'uncertain';
        push @evidence, "Continuation budget exhausted ($retry_count/$max_retries retries used)";
    }

    my $continuation = $self->_build_continuation($decision, \@blockers, \@evidence, $exhausted);

    if (should_log('DEBUG')) {
        log_debug('WorkflowCompletion', "Completion evaluation:");
        log_debug('WorkflowCompletion', "  decision=" . ($decision // 'undef'));
        log_debug('WorkflowCompletion', "  blockers=" . (join(',', @blockers) || '(none)'));
        log_debug('WorkflowCompletion', "  evidence=" . (join('; ', @evidence) || '(none)'));
        log_debug('WorkflowCompletion', "  continuation=" . substr($continuation, 0, 120));
    }

    return {
        decision       => $decision,
        reasons        => \@reasons,
        blockers       => \@blockers,
        evidence       => \@evidence,
        continuation   => $continuation,
        finish_reason  => $finish_reason,
        exhausted      => $exhausted ? 1 : 0,
    };
}

=head2 _has_separate_reasoning

Check whether the api_response has reasoning content in a separate
channel (not in the visible content). Some providers expose reasoning
separately (DeepSeek reasoning_content, Anthropic thinking blocks,
OpenAI Responses reasoning items). When the visible content is empty
but separate reasoning exists, an empty response is NOT premature — it
may be a reasoning-only turn that the provider legitimately emitted.

=cut

sub _has_separate_reasoning {
    my ($self, $api_response) = @_;

    return 0 unless ref($api_response) eq 'HASH';

    if (defined $api_response->{reasoning_content} && length($api_response->{reasoning_content})) {
        return 1;
    }
    if (defined $api_response->{accumulated_reasoning} && length($api_response->{accumulated_reasoning})) {
        return 1;
    }
    if ($api_response->{reasoning_details} && ref($api_response->{reasoning_details}) eq 'ARRAY'
        && @{$api_response->{reasoning_details}}) {
        return 1;
    }
    if ($api_response->{responses_reasoning_items} && ref($api_response->{responses_reasoning_items}) eq 'ARRAY'
        && @{$api_response->{responses_reasoning_items}}) {
        return 1;
    }

    return 0;
}

=head2 _build_continuation

Build a continuation message for the model when the workflow is not
complete but retries remain.

=cut

sub _build_continuation {
    my ($self, $decision, $blockers, $evidence, $exhausted) = @_;

    if ($exhausted) {
        return "The workflow could not reach completion. "
             . "Blockers: " . join('; ', @$blockers) . ". "
             . "Please review the remaining issues and produce your final response.";
    }

    return '' unless $decision eq 'continue';
    return '' unless @$blockers;

    my $msg;
    my %b = map { $_ => 1 } @$blockers;

    if ($b{api_truncated}) {
        $msg = "Your previous response was cut short by the output token limit. "
             . "Continue from where you left off and produce only the remaining "
             . "content or tool calls needed to finish. Do not repeat what was already written.";
    }
    elsif ($b{empty_response}) {
        $msg = "Your previous response was empty after tool activity. "
             . "Produce the remaining content or tool calls needed to finish.";
    }
    else {
        $msg = "The workflow is not complete. Continue from where you stopped.";
    }

    return $msg;
}

1;
