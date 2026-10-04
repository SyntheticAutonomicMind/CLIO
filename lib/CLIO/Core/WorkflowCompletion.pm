# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Core::WorkflowCompletion;

use strict;
use warnings;
use utf8;
use CLIO::Core::Logger qw(log_debug log_warning should_log);
use CLIO::Util::JSON qw(decode_json);

=head1 NAME

CLIO::Core::WorkflowCompletion - Layered workflow-completion evaluation

=head1 DESCRIPTION

Determines whether an AI agent is entitled to stop (produce a final
answer) based on objective execution evidence rather than text length
and punctuation heuristics.

The evaluator inspects evidence in priority order:

  1. API transport state — finish_reason from APIManager (e.g.
     C<length> indicates token-limit truncation).
     APIManager already surfaces full stream-level truncation (no
     finish_reason) as a retryable error; this layer only needs to see
     C<finish_reason> to catch deterministic truncation that the API
     layer does not flag as a transport error.

  2. Unresolved tool failures — structured C<success => 0> results from
     the most recent tool-call round.

  3. Failed verification — a verification command (test, lint, build,
     etc.) that ran and exited non-zero.

  4. Verification obligation — explicit requirement (from user input
     or todo description) C<plus> file modifications C<but> no
     verification performed.

  5. Todo/task state — in-progress or blocked todos that the workflow
     has not addressed.

  6. Textual unfinished-intent signals (secondary) — phrases like
     "I still need to...", "Next I will...", etc.

  7. Empty response after tool activity.

Textual and length-based signals are advisory; strong objective evidence
dominates.

=head1 SYNOPSIS

    use CLIO::Core::WorkflowCompletion;

    my $eval = CLIO::Core::WorkflowCompletion->new(debug => 1);

    my $result = $eval->evaluate(
        content          => $api_response->{content} // '',
        api_response     => $api_response,
        tool_calls       => \@tool_calls_made,
        session          => $session,
        user_input       => $user_input,
        retry_count      => $premature_stop_retries,
        max_retries      => $max_premature_stop_retries,
    );

    if ($result->{decision} eq 'continue') {
        # nudge the model with $result->{continuation}
    }

=cut

# Reason codes used by the evaluator. Stable so diagnostics/tests can
# depend on them.
our @REASON_CODES = qw(
    api_truncated
    tool_error
    verification_failed
    verification_pending
    todo_in_progress
    todo_blocked
    todo_external_block
    explicit_unfinished_intent
    empty_response
    incomplete_structure
    text_unfinished
);

# Patterns that indicate the model itself stated it has more work to do.
# These are advisory signals only.
my @UNFINISHED_INTENT_PATTERNS = (
    qr/I still need to\b/i,
    qr/I still need to\s+\w/i,
    qr/Next I will\b/i,
    qr/next step is\b/i,
    qr/The next step is\b/i,
    qr/I'll now\b/i,
    qr/I will now\b/i,
    qr/Before I finish\b/i,
    qr/I need to fix\b/i,
    qr/I need to\b/i,
    qr/Let me check\b/i,
    qr/Let me verify\b/i,
    qr/I still have to\b/i,
    qr/Going to\b/i,
    qr/I'm going to\b/i,
    qr/Will now\b/i,
    qr/Let me continue\b/i,
);

# Patterns that identify an actual verification COMMAND in terminal_operations
# exec calls (broad, permissive — if a command contains any of these, we
# treat it as a verification action).
my @VERIFICATION_COMMAND_PATTERNS = (
    qr/\bprove\b/i,
    qr/\bpytest\b/i,
    qr/\bnpm\s+(test|run\s+test)/i,
    qr/\byarn\s+test\b/i,
    qr/\bmake\s+test\b/i,
    qr/\bmake\s+check\b/i,
    qr/\bcargo\s+test\b/i,
    qr/\bgo\s+test\b/i,
    qr/\btclint\b/i,
    qr/\brubocop\b/i,
    qr/\beslint\b/i,
    qr/\bclang-format\b/i,
    qr/\bpylint\b/i,
    qr/\btype-check\b/i,
    qr/\btypecheck\b/i,
    qr/\baudit\b/i,
    qr/\bphpunit\b/i,
    qr/\bjest\b/i,
    qr/\bmocha\b/i,
    qr/\bjunit\b/i,
);

# Patterns that identify an EXPLICIT verification instruction in user input
# or todo descriptions. These are deliberately narrow: "run tests",
# "verify the fix", "lint the code" — not just the bare word "test".
# A user instruction to "write a test script" does NOT count.
my @VERIFICATION_INSTRUCTION_PATTERNS = (
    qr/\brun\s+(the\s+)?test/i,
    qr/\brun\s+(the\s+)?lint/i,
    qr/\brun\s+(the\s+)?build/i,
    qr/\brun\s+(the\s+)?check/i,
    qr/\brun\s+(the\s+)?verif/i,
    qr/\brun\s+the\s+test\s+suite/i,
    qr/\bmake\s+sure.*pass/i,
    qr/\bensure.*pass/i,
    qr/\bensure.*test/i,
    qr/\bverify.*fix\b/i,
    qr/\bverify.*work\b/i,
    qr/\bverify.*correct/i,
    qr/\blint.*code\b/i,
    qr/\baudit.*code\b/i,
    qr/\bcheck.*pass\b/i,
    qr/\btests.*pass\b/i,
    qr/\btest.*should\b/i,
    qr/\bshould.*test\b/i,
);

=head2 new

    my $eval = CLIO::Core::WorkflowCompletion->new(debug => 1);

=cut

sub new {
    my ($class, %args) = @_;
    return bless {
        debug => $args{debug} || 0,
    }, $class;
}

=head2 evaluate

Evaluate whether the workflow is complete.

Arguments (all hash keys):

    content          - The assistant's final response content (string)
    api_response     - Full api_response hashref from APIManager (for
                       finish_reason, reasoning, etc.)
    tool_calls       - Arrayref of tool-call records (from @tool_calls_made,
                       enriched with name/operation/success/error/exit_code)
    session          - Session object (may be undef)
    user_input       - Original user input string
    retry_count      - Current premature-stop retry count
    max_retries      - Maximum premature-stop retries allowed

Returns a hashref:

    {
        decision      => 'complete' | 'continue' | 'uncertain',
        reasons       => [...],          # all reason codes found
        blockers      => [...],          # reason codes that block completion
        evidence      => [...],          # human-readable evidence strings
        continuation  => '...',          # evidence-specific continuation message
        finish_reason => '...',          # from API (if available)
        exhausted     => 0 | 1,          # retry budget exhausted
    }

=cut

sub evaluate {
    my ($self, %args) = @_;

    my $content       = $args{content}       // '';
    my $api_response  = $args{api_response}  || {};
    my $tool_calls    = $args{tool_calls}    || [];
    my $session       = $args{session};
    my $user_input    = $args{user_input}    // '';
    my $retry_count   = $args{retry_count}   // 0;
    my $max_retries   = $args{max_retries}   // 2;

    my @reasons;
    my @blockers;
    my @evidence;

    my $finish_reason = $api_response->{finish_reason};
    my $content_length = length($content // '');

    # ── Layer 1: API transport state ──────────────────────────────────
    # Respect APIManager's completion/truncation state. APIManager surfaces
    # full stream-level truncation (no finish_reason) as a retryable error
    # (success => 0, error_type => 'truncated') — that is handled upstream
    # in _handle_api_error before we ever get here. We only need to catch
    # deterministic truncation that APIManager does NOT flag as an error:
    #   - finish_reason=length  (hit output token limit)
    #   - finish_reason=content_filter (content filter stopped generation)
    # These look like clean completions but the model was cut off.
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

    # ── Layer 2: Unresolved tool failures (structured) ────────────────
    # Use the structured success/error fields on tool_calls_made, NOT text
    # searching. Check the most recent tool-call round (last N entries)
    # for failures that were not followed by a retry.
    if ($tool_calls && @$tool_calls) {
        my $recent_failures = $self->_check_unresolved_tool_failures($tool_calls, \@evidence);
        if ($recent_failures) {
            push @blockers, 'tool_error';
            push @reasons,  'tool_error';
        }
    }

    # ── Layer 3: Failed verification ──────────────────────────────────
    # A verification command that was run and failed is strong evidence
    # the workflow is not complete. This overrides "done" prose.
    my $verification_failed = $self->_check_failed_verification($tool_calls, $content, \@evidence);
    if ($verification_failed) {
        push @blockers, 'verification_failed';
        push @reasons,  'verification_failed';
    }

    # ── Layer 4: Verification obligation ──────────────────────────────
    # Only if no verification has been performed yet. Requires:
    #   (a) an explicit verification requirement (user input or todo text)
    #   (b) file-modifying tool calls
    #   (c) no verification command has been run
    # Do NOT impose "run tests after every file modification."
    unless ($verification_failed) {
        my $verification_pending = $self->_check_verification_obligation(
            $tool_calls, $user_input, $session, 'content' => $content,
            'evidence' => \@evidence,
        );
        if ($verification_pending) {
            push @blockers, 'verification_pending';
            push @reasons,  'verification_pending';
        }
    }

    # ── Layer 5: Todo / task state ────────────────────────────────────
    # Inspect both session_goals (State.pm) and TodoStore for incomplete todos.
    # An in-progress todo is a strong signal work remains. A blocked todo
    # may be actionable (agent can resolve it) or external (user/third-party
    # dependency) — only external blocks do NOT block completion.
    my $todo_result = $self->_check_todo_state($session, $content, \@evidence);
    if ($todo_result) {
        push @reasons, $todo_result->{reason};
        if ($todo_result->{blocks}) {
            push @blockers, $todo_result->{reason};
        }
    }

    # ── Layer 6: Textual unfinished-intent signals (secondary) ────────
    # These are advisory only. They must not trigger continuation merely
    # because the response is short — the objective layers above dominate.
    # Pattern-based signals ("I still need to...", "Next I will...")
    # are explicit statements of unfinished intent and block regardless
    # of tool activity. Structure-based signals (incomplete_structure —
    # no terminal punctuation on a short response) only block when there
    # has been tool activity, since a brief first-iteration answer with no
    # tools is a legitimate response, not a mid-workflow stop.
    my $text_signals = $self->_check_textual_signals($content, \@evidence);
    if ($text_signals) {
        push @reasons, @$text_signals;
        # Separate pattern-based from structure-based signals.
        my @pattern_signals = grep { $_ eq 'text_unfinished' } @$text_signals;
        my @structure_signals = grep { $_ ne 'text_unfinished' } @$text_signals;

        # Pattern-based signals (explicit "I still need to..." etc.) block
        # independently — they indicate the model itself stated unfinished work.
        if (@pattern_signals && !@blockers) {
            push @blockers, @pattern_signals;
        }
        # Structure-based signals only block with tool activity AND no
        # other blockers already found.
        elsif (@structure_signals && !@blockers && @$tool_calls) {
            push @blockers, @structure_signals;
        }
    }

    # ── Layer 7: Empty response after tool activity ──────────────────
    # An entirely empty response after meaningful tool activity is
    # suspicious — the model may have emitted reasoning-only content that
    # was stripped, or gone silent. But some providers expose reasoning
    # separately (DeepSeek API, Anthropic thinking) — check that.
    if (@$tool_calls && $content_length == 0) {
        my $has_separate_reasoning = $self->_has_separate_reasoning($api_response);
        if (!$has_separate_reasoning) {
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

    # Build evidence-specific continuation message.
    my $continuation = $self->_build_continuation($decision, \@blockers, \@evidence, $exhausted);

    # Debug logging
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

=head2 _check_unresolved_tool_failures

Check the most recent tool-call round for failures that were not
subsequently retried. Returns 1 if an unresolved actionable failure
exists, 0 otherwise.

Only the last contiguous run of tool calls is examined. A tool failure
followed by a successful retry of the same tool in a later round is
considered resolved.

=cut

sub _check_unresolved_tool_failures {
    my ($self, $tool_calls, $evidence_ref) = @_;

    return 0 unless $tool_calls && @$tool_calls;
    return 0 unless ref($tool_calls) eq 'ARRAY';

    # Walk backwards: find the last tool call that succeeded. Any failures
    # after that point are unresolved (not retried).
    my $saw_success = 0;
    for my $i (reverse 0 .. $#$tool_calls) {
        my $tc = $tool_calls->[$i];
        next unless ref($tc) eq 'HASH';

        my $is_error = 0;
        if (exists $tc->{success} && !$tc->{success}) {
            $is_error = 1;
        } elsif (!exists $tc->{success} && defined $tc->{error} && length($tc->{error})) {
            # Backward compat: older tool_calls_made entries without success field
            # but with an error string. Only count if the result text looks like
            # an error (starts with ERROR: or contains a structured error).
            $is_error = 1;
        }

        if ($is_error) {
            if (!$saw_success) {
                my $name = $tc->{name} || 'unknown';
                my $op   = $tc->{operation} || '';
                my $err  = $tc->{error} || 'unknown error';
                push @$evidence_ref, "unresolved tool failure: $name" . ($op ? ".$op" : '') . " - $err";
                return 1;
            }
            # Failure was followed by a success — resolved. Keep walking.
        } else {
            $saw_success = 1;
        }
    }

    return 0;
}

=head2 _check_failed_verification

Detect whether a verification command was run and failed.

Scans tool_calls for terminal_operations exec calls that:
  (a) ran a command matching a verification pattern (test, lint, build, etc.)
  (b) returned a non-zero exit_code

Returns 1 if a failed verification is found, 0 otherwise.

=cut

sub _check_failed_verification {
    my ($self, $tool_calls, $content, $evidence_ref) = @_;

    return 0 unless $tool_calls && @$tool_calls;
    return 0 unless ref($tool_calls) eq 'ARRAY';

    for my $tc (@$tool_calls) {
        next unless ref($tc) eq 'HASH';
        next unless ($tc->{name} // '') eq 'terminal_operations';
        next unless ($tc->{operation} // '') eq 'exec';

        # Extract the command string from arguments
        my $args = $tc->{arguments};
        my $command;
        if (ref($args) eq 'HASH') {
            $command = $args->{command};
        } elsif (defined $args) {
            eval {
                my $parsed = decode_json($args);
                $command = $parsed->{command} if ref($parsed) eq 'HASH';
            };
        }
        next unless defined $command && length $command;

        # Check if this is a verification command
        my $is_verification = 0;
        for my $pattern (@VERIFICATION_COMMAND_PATTERNS) {
            if ($command =~ $pattern) {
                $is_verification = 1;
                last;
            }
        }
        next unless $is_verification;

        # Check exit code
        my $exit_code = $tc->{exit_code};
        if (defined $exit_code && $exit_code != 0) {
            push @$evidence_ref, "verification command failed: '$command' (exit_code=$exit_code)";
            return 1;
        }

        # Also check if the result text contains failure indicators
        # (fallback when exit_code is not available, e.g. older tool_calls_made)
        my $result = $tc->{result} // '';
        if (length $result && $result =~ /\b(fail|error|FAILED|FAIL)\b/i) {
            push @$evidence_ref, "verification command likely failed: '$command'";
            return 1;
        }
    }

    return 0;
}

=head2 _check_verification_obligation

Detect whether the workflow has an explicit verification obligation
that was not fulfilled.

Triggers when ALL of:
  (a) The user input or a todo explicitly requires verification
      (contains "test", "lint", "verify", "build", "audit", etc.)
  (b) File-modifying tools were used (file_operations write/apply_patch)
  (c) No verification command was run (no terminal_operations exec matching
      verification patterns)

This is deliberately conservative: file modification alone is NOT enough.
The task must explicitly require verification.

=cut

sub _check_verification_obligation {
    my ($self, $tool_calls, $user_input, $session, %opts) = @_;
    my $content      = $opts{content} // '';
    my $evidence_ref = $opts{evidence} || [];

    return 0 unless $tool_calls && @$tool_calls;
    return 0 unless ref($tool_calls) eq 'ARRAY';

    # (a) Check for explicit verification requirement
    my $requires_verification = 0;

    # From user input
    if (defined $user_input && length $user_input) {
        for my $pattern (@VERIFICATION_INSTRUCTION_PATTERNS) {
            if ($user_input =~ $pattern) {
                $requires_verification = 1;
                push @$evidence_ref, "user input mentions verification";
                last;
            }
        }
    }

    # From todo descriptions (session_goals in State.pm)
    if (!$requires_verification && $session && $session->can('state')) {
        my $state = $session->state();
        if ($state && ref($state) eq 'HASH' && $state->{session_goals}) {
            for my $goal (@{$state->{session_goals}}) {
                next unless ref($goal) eq 'HASH';
                my $title = $goal->{title} || '';
                my $desc  = $goal->{description} || '';
                my $text  = "$title $desc";
                for my $pattern (@VERIFICATION_INSTRUCTION_PATTERNS) {
                    if ($text =~ $pattern) {
                        $requires_verification = 1;
                        push @$evidence_ref, "todo requires verification: '$title'";
                        last;
                    }
                }
                last if $requires_verification;
            }
        }
    }

    return 0 unless $requires_verification;

    # (b) Check if file-modifying tools were used
    my $file_modified = 0;
    for my $tc (@$tool_calls) {
        next unless ref($tc) eq 'HASH';
        my $name = $tc->{name} // '';
        my $op   = $tc->{operation} || '';

        if ($name eq 'file_operations' && $op =~ /^(write_file|replace_string|multi_replace_string|append_file|insert_at_line)$/) {
            $file_modified = 1;
            last;
        }
        if ($name eq 'apply_patch') {
            $file_modified = 1;
            last;
        }
    }

    return 0 unless $file_modified;

    # (c) Check if a verification command was actually run
    my $verification_ran = 0;
    for my $tc (@$tool_calls) {
        next unless ref($tc) eq 'HASH';
        next unless ($tc->{name} // '') eq 'terminal_operations';
        next unless ($tc->{operation} // '') eq 'exec';

        my $args = $tc->{arguments};
        my $command;
        if (ref($args) eq 'HASH') {
            $command = $args->{command};
        } elsif (defined $args) {
            eval {
                my $parsed = decode_json($args);
                $command = $parsed->{command} if ref($parsed) eq 'HASH';
            };
        }
        next unless defined $command;

        for my $pattern (@VERIFICATION_COMMAND_PATTERNS) {
            if ($command =~ $pattern) {
                $verification_ran = 1;
                last;
            }
        }
        last if $verification_ran;
    }

    if (!$verification_ran) {
        push @$evidence_ref, "files modified but verification was not performed";
        return 1;
    }

    return 0;
}

=head2 _check_todo_state

Inspect session_goals (State.pm) and TodoStore for incomplete todos.

Returns a hashref with:
  - reason => reason code string (todo_in_progress, todo_blocked,
              todo_external_block) or undef if nothing actionable
  - blocks => 1 if this should block completion, 0 if advisory only

Rules:
  - An in-progress todo blocks: work is actively underway.
  - A blocked todo with an actionable reason blocks: the agent could
    resolve it.
  - A blocked todo whose reason mentions external/user dependency does
    NOT block: the model is entitled to explain the block and stop.
  - Pending/not-started todos are weak signals (advisory only, not blocking).

=cut

sub _check_todo_state {
    my ($self, $session, $content, $evidence_ref) = @_;

    my @todos;
    my $got_from_store = 0;

    # Collect todos from BOTH sources:
    #   1. session_goals (State.pm) — set via memory_operations tool
    #   2. TodoStore — set via todo_list tool
    # These are independent systems; an agent may use one, both, or neither.
    # Checking both ensures we don't miss stale state from either.

    # 1. session_goals from State.pm (authoritative, in-memory)
    if ($session && $session->can('state')) {
        my $state = $session->state();
        if ($state && ref($state) eq 'HASH' && $state->{session_goals}
            && ref($state->{session_goals}) eq 'ARRAY' && @{$state->{session_goals}}) {
            push @todos, @{$state->{session_goals}};
        }
    }

    # 2. TodoStore (file-based, always fresh from disk)
    eval {
        require CLIO::Session::TodoStore;
        require CLIO::Util::PathResolver;
    };
    if (!$@ && $session && $session->can('id')) {
        my $sessions_dir = eval { CLIO::Util::PathResolver::get_sessions_dir() };
        if ($sessions_dir) {
            my $store = CLIO::Session::TodoStore->new(
                sessions_dir => $sessions_dir,
                session_id   => $session->id(),
            );
            my $ts_todos = $store->read();
            if ($ts_todos && ref($ts_todos) eq 'ARRAY' && @$ts_todos) {
                push @todos, @$ts_todos;
                $got_from_store = 1;
            }
        }
    }

    return undef unless @todos;

    # Normalize: extract status from both {status} (session_goals) and
    # {status} (TodoStore) formats.
    my @normalized;
    for my $todo (@todos) {
        next unless ref($todo) eq 'HASH';
        my $status = $todo->{status} // 'pending';
        # 'pending' is an alias for 'not-started' in TodoStore
        $status = 'not-started' if $status eq 'pending';
        my $title    = $todo->{title}    // $todo->{content} // '';
        my $desc     = $todo->{description} // '';
        my $block    = $todo->{blockedReason} // '';
        push @normalized, {
            status => $status,
            title  => $title,
            desc   => $desc,
            block  => $block,
        };
    }

    # Check for in-progress todos (strong blocker)
    for my $t (@normalized) {
        if ($t->{status} eq 'in-progress') {
            push @$evidence_ref, "todo in-progress: $t->{title}";
            return { reason => 'todo_in_progress', blocks => 1 };
        }
    }

    # Check for blocked todos
    for my $t (@normalized) {
        if ($t->{status} eq 'blocked') {
            # Determine if the block is external (user/third-party dependency)
            # vs actionable (something the agent could resolve).
            my $block_text = ($t->{block} // '') . ' ' . ($t->{desc} // '');
            if ($block_text =~ /\b(user|external|third.?party|waiting on|waiting for|require.*\binput\b|need.*\binput\b|dependenc)\b/i) {
                push @$evidence_ref, "todo blocked (external): $t->{title} - $t->{block}";
                # External block: does NOT block completion. The model is
                # entitled to explain the block and stop.
                return { reason => 'todo_external_block', blocks => 0 };
            }
            # Actionable block — the agent could resolve it
            push @$evidence_ref, "todo blocked (actionable): $t->{title} - $t->{block}";
            return { reason => 'todo_blocked', blocks => 1 };
        }
    }

    # Pending/not-started todos are weak signals — return undef (no block)
    # but could add to evidence. We don't block on these.

    return undef;
}

=head2 _check_textual_signals

Detect phrases in the response content that indicate the model
intended to continue working. Returns an arrayref of reason codes.

These are advisory signals only — the caller decides whether to treat
them as blockers based on the presence of objective evidence.

=cut

sub _check_textual_signals {
    my ($self, $content, $evidence_ref) = @_;

    my @found;

    return \@found unless defined $content && length $content;

    for my $pattern (@UNFINISHED_INTENT_PATTERNS) {
        if ($content =~ $pattern) {
            push @found, 'text_unfinished';
            push @$evidence_ref, "textual signal: unfinished intent detected";
            last;  # One is enough
        }
    }

    # Check for incomplete structure: response that starts a sentence
    # but never terminates it (no terminal punctuation at end), AND is
    # short enough that it's plausibly an incomplete sentence rather than
    # a deliberate terse final answer.
    my $trimmed = $content;
    $trimmed =~ s/\s+$//;
    if (length($trimmed) > 0 && length($trimmed) < 120) {
        if ($trimmed =~ /[.!?][)\]'"*]*\s*$/) {
            # Has terminal punctuation — not incomplete
        } elsif ($trimmed !~ /[a-z]\s*$/i) {
            # Doesn't end in a letter — probably an incomplete fragment
            if (length($trimmed) < 80) {
                push @found, 'incomplete_structure';
                push @$evidence_ref, "incomplete sentence structure (no terminal punctuation, short response)";
            }
        }
    }

    return \@found;
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

    # DeepSeek / OpenRouter reasoning_content
    if (defined $api_response->{reasoning_content} && length($api_response->{reasoning_content})) {
        return 1;
    }

    # Accumulated reasoning string
    if (defined $api_response->{accumulated_reasoning} && length($api_response->{accumulated_reasoning})) {
        return 1;
    }

    # reasoning_details array
    if ($api_response->{reasoning_details} && ref($api_response->{reasoning_details}) eq 'ARRAY'
        && @{$api_response->{reasoning_details}}) {
        return 1;
    }

    # Responses API reasoning items
    if ($api_response->{responses_reasoning_items} && ref($api_response->{responses_reasoning_items}) eq 'ARRAY'
        && @{$api_response->{responses_reasoning_items}}) {
        return 1;
    }

    return 0;
}

=head2 _build_continuation

Build an evidence-specific continuation message based on the blockers
found. The message tells the model WHAT remains unresolved, not just
"continue."

=cut

sub _build_continuation {
    my ($self, $decision, $blockers, $evidence, $exhausted) = @_;

    # If exhausted, return a message that explains the state
    if ($exhausted) {
        return "The workflow could not reach a verified completion state after "
             . scalar(@$blockers) . " continuation attempt(s). "
             . "Blockers: " . join('; ', @$blockers) . ". "
             . "Please review the remaining issues and produce your final response, "
             . "or indicate that the workflow cannot proceed.";
    }

    # Don't build continuation for 'complete' decisions
    return '' unless $decision eq 'continue';

    return '' unless @$blockers;

    # Build the most specific message based on the strongest blocker.
    # Priority: verification_failed > tool_error > verification_pending >
    #           todo_in_progress > todo_blocked > empty_response >
    #           explicit_unfinished_intent > incomplete_structure >
    #           text_unfinished > api_truncated

    my $msg;
    my %b = map { $_ => 1 } @$blockers;

    if ($b{api_truncated}) {
        $msg = "The workflow is not complete. Your previous response was cut "
             . "short by the API. Continue from where you left off and "
             . "produce only the remaining content or tool calls needed to "
             . "finish. Do not repeat what was already written.";
    }
    elsif ($b{verification_failed}) {
        my $detail = join('; ', grep { /verification command failed/ } @$evidence);
        $detail = "A verification command reported failure." unless $detail;
        $msg = "The workflow is not complete.\n"
             . $detail . "\n"
             . "Investigate and resolve the failures before producing the final response.";
    }
    elsif ($b{tool_error}) {
        my $detail = join('; ', grep { /unresolved tool failure/ } @$evidence);
        $detail = "A tool call returned an error that was not resolved." unless $detail;
        $msg = "The workflow is not complete.\n"
             . $detail . "\n"
             . "Fix the error and retry the tool call before producing the final response.";
    }
    elsif ($b{verification_pending}) {
        $msg = "The workflow is not complete.\n"
             . "You modified the implementation but have not completed the required verification. "
             . "Run the relevant verification (tests, lint, build, etc.) before producing the final response.";
    }
    elsif ($b{todo_in_progress}) {
        my $detail = join('; ', grep { /todo in-progress/ } @$evidence) || '';
        $msg = "The workflow is not complete.\n"
             . "A task remains in-progress" . ($detail ? " ($detail)" : '') . ". "
             . "Complete the in-progress work before producing the final response.";
    }
    elsif ($b{todo_blocked}) {
        my $detail = join('; ', grep { /todo blocked/ } @$evidence) || '';
        $msg = "The workflow is not complete.\n"
             . "A task is blocked" . ($detail ? ": $detail" : '') . ". "
             . "Resolve the block before producing the final response.";
    }
    elsif ($b{empty_response}) {
        $msg = "The workflow is not complete.\n"
             . "The last response was empty after tool activity. "
             . "Produce the remaining content or tool calls needed to finish.";
    }
    elsif ($b{explicit_unfinished_intent} || $b{text_unfinished}) {
        $msg = "The workflow is not complete.\n"
             . "You stated that you still needed to perform further action. "
             . "Complete that action before producing the final response.";
    }
    elsif ($b{incomplete_structure}) {
        $msg = "The workflow is not complete.\n"
             . "The response appears to be incomplete (no terminal punctuation, fragment-like structure). "
             . "Finish your response before producing the final answer.";
    }
    else {
        # Fallback — generic but evidence-informed
        $msg = "The workflow is not complete.\n"
             . "Blockers: " . join(', ', @$blockers) . ". "
             . "Resolve these issues before producing the final response.";
    }

    return $msg;
}

1;
