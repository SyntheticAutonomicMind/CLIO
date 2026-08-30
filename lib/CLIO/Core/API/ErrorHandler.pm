# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Core::API::ErrorHandler;

use strict;
use warnings;
use utf8;
use CLIO::UI::Terminal qw(ui_char);
use CLIO::Core::Logger qw(log_error log_warning log_info log_debug should_log);
use CLIO::Core::Logger qw(log_error log_warning log_info log_debug);
use CLIO::Memory::TokenEstimator qw(estimate_tokens compute_prompt_budget get_effective_ratio);
use CLIO::Util::JSON qw(safe_encode_json);
use CLIO::Util::RateLimit qw(get_rate_limit_type_name);
use CLIO::Core::Diagnostics qw(dump_diagnostic display_rate_limit_info get_tool_specific_guidance);
use CLIO::Core::Defaults qw(DEFAULT_CONTEXT_WINDOW DEFAULT_POST_TRIM_FLOOR);

=head1 NAME

CLIO::Core::API::ErrorHandler - API error classification and recovery

=head1 DESCRIPTION

Handles API error responses from the AI provider. Classifies errors as
retryable, fatal, or recoverable, and orchestrates the appropriate
recovery strategy (retry with backoff, context trimming, message repair).

Extracted from WorkflowOrchestrator to reduce module size and improve
testability.

=head1 SYNOPSIS

    use CLIO::Core::API::ErrorHandler;

    my $result = CLIO::Core::API::ErrorHandler::handle_api_error(
        $wo,              # WorkflowOrchestrator instance
        $api_response,    # Error response from APIManager
        $ctx,             # Context hashref (messages, retry_count, etc.)
    );

    # Returns: HASHREF (fatal error), 'retry', or 'continue'

=cut

#============================================================================
# Public API
#============================================================================

=head2 handle_api_error($wo, $api_response, $ctx)

Main error handler. Classifies the API error and orchestrates recovery.

Parameters:
    $wo           - WorkflowOrchestrator instance (for state/callbacks)
    $api_response - API error response hashref
    $ctx          - Context hashref with:
        messages            - Arrayref of conversation messages
        retry_count         - Scalar ref to retry counter
        session_error_count - Scalar ref to session error counter
        iteration           - Current iteration number
        tool_calls_made     - Arrayref of tool calls made
        session             - Session object
        on_system_message   - Callback for system messages
        max_retries         - Max retries for API errors
        max_server_retries  - Max retries for server errors
        max_session_errors  - Max session-level errors
        max_rate_limit_retries - Max rate limit retries

Returns:
    HASHREF  - Fatal error (propagate to caller)
    'retry'  - Retryable error (caller should retry)
    'continue' - Recoverable error (caller should continue loop)

=cut

sub handle_api_error {
    my ($wo, $api_response, $ctx) = @_;

    # ErrorHandler calls into WorkflowOrchestrator for some operations
    # (_compress_dropped_for_recovery, _checkpoint_session_progress). WO
    # normally loads first (it `use`s this module), but a direct require
    # of ErrorHandler would leave WO un-loaded and those calls would fail
    # with "Undefined subroutine". Lazy-load here to break the circular
    # dependency at compile time and guarantee WO is available when needed.
    require CLIO::Core::WorkflowOrchestrator;

    my $messages            = $ctx->{messages};
    my $retry_count_ref     = $ctx->{retry_count};
    my $session_error_ref   = $ctx->{session_error_count};
    my $iteration           = $ctx->{iteration};
    my $tool_calls_made     = $ctx->{tool_calls_made};
    my $session             = $ctx->{session};
    my $on_system_message   = $ctx->{on_system_message};
    my $max_retries         = $ctx->{max_retries};
    my $max_server_retries  = $ctx->{max_server_retries};
    my $max_session_errors  = $ctx->{max_session_errors};

    my $max_rate_limit_retries = $ctx->{max_rate_limit_retries} // 0;

    my $error = $api_response->{error} || "Unknown API error";

    # Debug: log full API response for troubleshooting (only when debug logging is enabled,
    # since encode_json is expensive)
    if (should_log('debug')) {
        my $api_response_json = eval { require CLIO::Util::JSON; CLIO::Util::JSON::encode_json($api_response) } // 'undef';
        log_debug('ErrorHandler', "API response for retry check: $api_response_json (retryable=" . ($api_response->{retryable} // 'undef') . ")");
    }

    # ── Model Routing ────────────────────────────────────────────────
    # When multiple models are configured (via --model or /api set model
    # with multiple space-separated entries), switch to the next model on
    # ANY API error (rate limit, server error, billing error, etc.).
    # The _prepare_endpoint_config method resolves the provider/api_base/
    # api_key from the model's prefix on each request, so updating the
    # config model is sufficient for cross-provider routing.
    # Total attempts = len(candidates) * max_retries (e.g. 3 * 3 = 9).
    if ($wo->{api_manager} && $wo->{api_manager}->can('model_routing_active')) {
        my $num_candidates = $wo->{api_manager}->model_routing_active();
        if ($num_candidates > 1) {
            my $routing_attempts = $session && $session->{routing_attempts} ? $session->{routing_attempts} : 0;
            $routing_attempts++;
            $session->{routing_attempts} = $routing_attempts if $session;

            my $max_total = $num_candidates * $max_retries;
            if ($routing_attempts >= $max_total) {
                # All routing attempts exhausted across all models
                if ($session) {
                    delete $session->{routing_attempts};
                }
                log_error('ErrorHandler', "Model routing exhausted: $num_candidates models, $max_total total attempts");
                return {
                    success         => 0,
                    error           => "Model routing exhausted: all $num_candidates models failed after $max_total total attempts. Last error: $error",
                    iterations      => $iteration,
                    tool_calls_made => $tool_calls_made,
                };
            }

            # Cycle to the next model (wraps around at the end)
            my ($new_model, $old_model) = $wo->{api_manager}->cycle_model();
            if ($new_model && $on_system_message) {
                $on_system_message->("API error, rerouting to $new_model");
            }
            # Reset retry count so the new model gets a fresh retry budget
            $$retry_count_ref = 0;
            $wo->{consecutive_errors} = 0 if $wo;
            log_info('ErrorHandler', "Model routing: switched to '$new_model' (attempt $routing_attempts/$max_total total)");
            return 'retry';
        }
    }

    # ── Retryable errors ──────────────────────────────────────────────
    if ($api_response->{retryable}) {
        $$retry_count_ref++;

# Bail out on persistent bad_request after the configured retry limit is exhausted.
        # The previous behavior was to flip error_type to 'token_limit_exceeded' after just
        # 2 retries and try to trim context - that was wrong. Token limit errors have their
        # own specific handler below (model_max_prompt_tokens_exceeded / context_length_exceeded).
        # An unrecognized 400 that's persistent is more likely a backend / model / payload
        # issue than a context size issue. Bail with the actual provider error so the user
        # sees what the provider actually said and can take action (switch model, contact support,
        # check /api logs).
        my $error_type_check = $api_response->{error_type} || '';
        if ($error_type_check eq 'bad_request' && $$retry_count_ref >= $max_retries) {
            log_error('ErrorHandler', "Persistent 400 Bad Request after $$retry_count_ref retries - giving up without context trim.");

            dump_diagnostic(
                trigger      => 'persistent_400',
                messages     => $messages,
                api_manager  => $wo->{api_manager},
                iteration    => $iteration,
                retry_count  => $$retry_count_ref,
                error        => $error,
                api_response => $api_response,
                append       => 1,
                extra        => { retries => $$retry_count_ref },
            );

            # Use the provider's actual error message, plus actionable guidance.
            # Don't synthesize a "Token limit exceeded" message - that's misleading for
            # unrecognized 400s which are usually content/payload/model issues.
            my $user_error = $api_response->{error} || $error;
            $user_error .= "\n\nThe API provider rejected the request with HTTP 400 and no specific classification "
                          . "matched our known patterns. This usually means one of:\n"
                          . "  - The model doesn't support some parameter we sent (reasoning mode, tool format, etc.)\n"
                          . "  - The conversation context has content the model rejects (formatting, encoding)\n"
                          . "  - The provider's backend changed behavior and our error classifier needs an update\n"
                          . "Try a different model, or check /tmp/clio_api_400.log for the full provider response. "
                          . "Run /api model <provider>/<model> to switch.";

            return {
                success         => 0,
                error           => $user_error,
                iterations      => $iteration,
                tool_calls_made => $tool_calls_made,
            };
        }
        # Determine retry limit based on error type
        my $error_type_for_limit = $api_response->{error_type} || '';
        my $retry_limit;
        my $allow_infinite_retry = 0;
        # concurrency_limit is CLIO's local per-provider concurrency slot
        # exhaustion. It is conceptually a rate limit (we are out of allowed
        # requests right now) and must inherit rate_limit's infinite-retry
        # budget. Without this it fell into the generic 3-retry bucket,
        # so any session that briefly had two in-flight requests to the
        # same provider would die with "Maximum retries exceeded" even
        # though the in-flight requests were recoverable.
        if ($error_type_for_limit eq 'rate_limit' || $error_type_for_limit eq 'concurrency_limit') {
            $retry_limit = $max_rate_limit_retries;
            $allow_infinite_retry = 1 if $max_rate_limit_retries == 0;
        } elsif ($error_type_for_limit eq 'server_error' || $error_type_for_limit eq 'connection_error') {
            $retry_limit = $max_server_retries;
            $allow_infinite_retry = 1 if $max_server_retries == 0;
        } elsif ($error_type_for_limit eq 'timeout' || $error_type_for_limit eq 'overloaded') {
            # Upstream timeouts and overload errors get the same retry budget as 5xx
            $retry_limit = $max_server_retries;
            $allow_infinite_retry = 1 if $max_server_retries == 0;
        } elsif ($error_type_for_limit eq 'truncated') {
            # Truncated stream (provider ended without finish_reason). This is a
            # transient network/provider issue that almost always resolves on
            # retry - treat it like a server_error with infinite retries so a
            # flapping provider doesn't blow the per-iteration retry budget on
            # what would otherwise be a single successful retry.
            $retry_limit = $max_server_retries;
            $allow_infinite_retry = 1 if $max_server_retries == 0;
        } elsif ($error_type_for_limit eq 'bad_request') {
            $retry_limit = 4;
        } else {
            $retry_limit = $max_retries;
        }

        # Skip retry limit check for rate limits when infinite retry is enabled
        if (!$allow_infinite_retry && $$retry_count_ref > $retry_limit) {
            log_error('ErrorHandler', "Maximum retries ($retry_limit) exceeded for this iteration");
            return {
                success         => 0,
                error           => "Maximum retries exceeded: $error",
                iterations      => $iteration,
                tool_calls_made => $tool_calls_made,
            };
        }

        my $retry_delay = $api_response->{retry_after} // 2;
        my $error_type;
        my $user_message = $api_response->{user_message};  # Detailed message from ResponseHandler

        # Determine error type - use specific rate limit type if available
        # concurrency_limit surfaces as "Rate limit detected" so the user
        # sees the same UI message they get from provider rate limits
        # (and, importantly, gets infinite retry budget via the matching
        # change in the retry-limit selector above).
        if ($api_response->{error_type} && ($api_response->{error_type} eq 'rate_limit' || $api_response->{error_type} eq 'concurrency_limit')) {
            my $rl_code = $api_response->{rate_limit_code} // '';
            $error_type = get_rate_limit_type_name($rl_code);

            # Weekly/monthly limits don't reset quickly - don't retry, just inform user
            if (!$api_response->{retryable} || $rl_code =~ /user_weekly_rate_limited|user_monthly_rate_limited/i) {
                my $reset_msg = $user_message // "Sorry, you've exceeded your weekly/monthly rate limit. Please review your usage.";
                display_rate_limit_info($rl_code, $retry_delay);
                return {
                    success         => 0,
                    error           => $reset_msg,
                    iterations      => $iteration,
                    tool_calls_made => $tool_calls_made,
                    rate_limit_wait => $retry_delay,
                };
            }
        } else {
            $error_type = "server error";
        }
        # Upstream timeout/overload get accurate labels instead of generic "server error"
        if ($api_response->{error_type} && $api_response->{error_type} eq 'timeout') {
            $error_type = "upstream timeout";
        } elsif ($api_response->{error_type} && $api_response->{error_type} eq 'overloaded') {
            $error_type = "upstream overload";
        } elsif ($api_response->{error_type} && $api_response->{error_type} eq 'truncated') {
            $error_type = "stream truncated";
        }

        # Format retry count display (show ∞ for infinite retries)
        my $retry_display = $allow_infinite_retry ? ui_char('infinity') : $retry_limit;
        my $system_msg = ucfirst($error_type) . " detected. Retrying in ${retry_delay}s... (attempt $$retry_count_ref" . ($allow_infinite_retry ? "" : "/$retry_display") . ")";

        # ── Per-error-type handling ──
        if ($api_response->{error_type} && $api_response->{error_type} eq 'unsupported_param') {
            $error_type  = "unsupported parameter";
            $system_msg  = undef;
            $retry_delay = 0;
            log_info('ErrorHandler', "Retrying without unsupported parameter");
        }
        elsif ($api_response->{error_type} && $api_response->{error_type} eq 'bad_request') {
            $system_msg = undef;
            log_info('ErrorHandler', "API 400 Bad Request - retrying silently (attempt $$retry_count_ref)");
        }
        elsif ($api_response->{error_type} && $api_response->{error_type} eq 'malformed_tool_json') {
            if ($$retry_count_ref == 1) {
                # First attempt: remove bad message, provide schema guidance
                if (@$messages && $messages->[-1]{role} eq 'assistant') {
                    pop @$messages;
                    log_info('ErrorHandler', "Removed malformed assistant message from history");
                }

                my $failed_tool_name = $api_response->{failed_tool} || 'unknown';
                my $tool_schema      = '';

                if ($failed_tool_name ne 'unknown') {
                    my $tool_def = $wo->{tool_registry}->get_tool($failed_tool_name);
                    if ($tool_def) {
                        my $params = $tool_def->{function}{parameters};
                        if ($params) {
                            require JSON::PP;
                            $tool_schema = "\n\nCorrect schema for $failed_tool_name:\n" .
                                           JSON::PP->new->pretty->encode($params);
                        }
                    }
                }

                my $tool_guidance = get_tool_specific_guidance($failed_tool_name);

                push @$messages, {
                    role    => 'system',
                    content => "Your previous tool call had invalid JSON parameters.\n\n" .
                               "Common issues:\n" .
                               "- Missing parameter values (e.g., \"offset\":, instead of \"offset\":0)\n" .
                               "- Unescaped quotes in strings\n" .
                               "- Trailing commas\n" .
                               "- Missing required parameters\n\n" .
                               "ALL parameters must have valid values - no empty/missing values permitted.\n" .
                               "$tool_schema\n\n" .
                               "${tool_guidance}" .
                               "Please retry the operation with correct JSON, or try a different approach if the tool call isn't critical.",
                };

                $error_type = "malformed tool JSON";
                $system_msg = "AI generated invalid JSON parameters. Removed bad message, adding guidance and retrying... (attempt $$retry_count_ref/$max_retries)";
                log_info('ErrorHandler', "Added JSON formatting guidance for tool: $failed_tool_name");
            }
            else {
                # Second attempt failed: let agent recover
                if (@$messages && $messages->[-1]{role} eq 'assistant') {
                    pop @$messages;
                    log_info('ErrorHandler', "Removed second malformed assistant message");
                }

                push @$messages, {
                    role    => 'system',
                    content => "TOOL CALL FAILED: The previous tool call still had invalid JSON after correction attempt. " .
                               "The tool call has been removed from history. You can:\n" .
                               "1. Try a different approach to accomplish the same goal\n" .
                               "2. Continue with other work\n" .
                               "3. Ask the user for clarification if needed\n\n" .
                               "Your conversation context is preserved - continue your work.",
                };

                $$retry_count_ref = 0;
                log_warning('ErrorHandler', "Malformed JSON persisted - agent informed, continuing workflow");
                return 'retry';  # Don't decrement iteration, just continue
            }
        }
        elsif ($api_response->{error_type} && $api_response->{error_type} eq 'token_limit_exceeded') {
            # Pass server-reported n_ctx / n_prompt_tokens from the API response so
            # trim_for_token_limit can compute a precise cut target instead of
            # relying on the local token estimate (which can drift from reality
            # when the learned char/token ratio is wrong).
            my $trim_ctx = { %$ctx };
            $trim_ctx->{n_ctx}           = $api_response->{n_ctx}           if exists $api_response->{n_ctx};
            $trim_ctx->{n_prompt_tokens} = $api_response->{n_prompt_tokens} if exists $api_response->{n_prompt_tokens};
            my $trim_result = trim_for_token_limit($wo, %$trim_ctx);

            # Bail out if trim decided further retries are pointless
            return $trim_result->{response} if $trim_result->{bail};

            $error_type = "token limit exceeded";
            $system_msg = $trim_result->{system_msg};
        }
        elsif ($api_response->{error_type} && ($api_response->{error_type} eq 'server_error' || $api_response->{error_type} eq 'connection_error')) {
            my $backoff_multiplier = 2 ** ($$retry_count_ref - 1);
            $retry_delay = $retry_delay * $backoff_multiplier;
            # Cap backoff at 5 minutes
            $retry_delay = 300 if $retry_delay > 300;

            # Before retrying after connection errors, verify connectivity is restored
            if ($api_response->{error_type} eq 'connection_error' && $$retry_count_ref == 1) {
                log_info('ErrorHandler', "Connection error detected - verifying connectivity before retry...");
                my $endpoint = $wo->{api_manager}{api_base} || '';
                my $connected = $wo->{api_manager}->_check_connectivity($endpoint);
                if (!$connected) {
                    log_warning('ErrorHandler', "Connectivity check failed - continuing with retry path");
                    $system_msg = "Network connectivity issue detected. Retrying anyway... (attempt $$retry_count_ref/$max_retries)";
                }
            }

            $error_type = $api_response->{error_type} eq 'connection_error' ? "connection error" : "server error";
            $system_msg //= "Temporary $error_type. Retrying in ${retry_delay}s... (attempt $$retry_count_ref)";
            log_info('ErrorHandler', "Applying exponential backoff for server error: ${retry_delay}s delay");
        }
        elsif ($api_response->{error_type} && ($api_response->{error_type} eq 'timeout' || $api_response->{error_type} eq 'overloaded')) {
            # Apply exponential backoff for upstream timeouts and overload conditions.
            # retry_after from ResponseHandler sets the base (30s for timeout, 10s for overloaded).
            $error_type = $api_response->{error_type} eq 'timeout' ? "upstream timeout" : "upstream overload";
            my $backoff_multiplier = 2 ** ($$retry_count_ref - 1);
            $retry_delay = $retry_delay * $backoff_multiplier;
            $retry_delay = 300 if $retry_delay > 300;
            $system_msg //= "Upstream $error_type. Retrying in ${retry_delay}s... (attempt $$retry_count_ref)";
            log_info('ErrorHandler', "Applying exponential backoff for $error_type: ${retry_delay}s delay");
        }
        # concurrency_limit hits this branch too - the rate_limit branch above
        # already set $error_type via get_rate_limit_type_name, but this
        # default assignment ensures the user-facing label is correct even if
        # the response lacks a rate_limit_code.
        elsif ($api_response->{error_type} && ($api_response->{error_type} eq 'rate_limit' || $api_response->{error_type} eq 'concurrency_limit')) {
            $error_type = "rate limit";
        }
        elsif ($api_response->{error_type} && $api_response->{error_type} eq 'auth_recovered') {
            $error_type  = "auth recovery";
            $system_msg  = undef;
            $retry_delay = 0;
            log_info('ErrorHandler', "Auth token refreshed, retrying request silently");
        }
        elsif ($api_response->{error_type} && $api_response->{error_type} eq 'message_structure_error') {
            $error_type = "message structure error";
            $system_msg = "Message structure error detected. Rebuilding from session history... (attempt $$retry_count_ref/$max_retries)";

            if ($session && $session->can('get_conversation_history')) {
                my $fresh_history    = $session->get_conversation_history() || [];
                my $system_msg_saved = $messages->[0]{role} eq 'system' ? $messages->[0] : undef;
                my $current_user_msg = $messages->[-1]{role} eq 'user'  ? $messages->[-1] : undef;

                @$messages = ();
                push @$messages, $system_msg_saved if $system_msg_saved;
                push @$messages, @$fresh_history;
                push @$messages, $current_user_msg
                    if $current_user_msg &&
                       (!@$fresh_history || $fresh_history->[-1]{content} ne $current_user_msg->{content});

                log_info('ErrorHandler', "Rebuilt messages from session history (" . scalar(@$messages) . " messages)");
            }

            $retry_delay = 0;
        }

        # Notify UI
        if ($system_msg && $on_system_message) {
            eval { $on_system_message->($system_msg); };
            log_debug('ErrorHandler', "UI callback error: $@") if $@;
        } elsif ($system_msg) {
            log_info('ErrorHandler', "Retryable $error_type detected, retrying in ${retry_delay}s on next iteration (attempt $$retry_count_ref/$max_retries)");
        }

        # Wait before retrying (interruptible)
        if ($retry_delay > 0) {
            log_debug('ErrorHandler', "Waiting ${retry_delay}s before retry...");
            my $remaining = $retry_delay;
            while ($remaining > 0) {
                my $chunk = ($remaining > 1) ? 1 : $remaining;
                sleep($chunk);
                $remaining -= $chunk;

                if ($wo->_check_for_user_interrupt($session)) {
                    log_info('ErrorHandler', "Retry wait interrupted by user");
                    $wo->_handle_interrupt($session, $messages);
                    last;
                }
            }
            log_debug('ErrorHandler', "Retry delay complete, sending request...");
        }

        return 'retry';
    }

    # ── Non-retryable rate limit handling (weekly/monthly limits and Copilot session limits) ─────
    if (defined($api_response->{error_type}) && $api_response->{error_type} eq 'rate_limit' && !$api_response->{retryable}) {
        my $rl_code = $api_response->{rate_limit_code} // '';
        if ($rl_code =~ /user_weekly_rate_limited|user_monthly_rate_limited|copilot_session_limit/i) {
            log_info('ErrorHandler', "Non-retryable rate limit detected ($rl_code) - returning error without retry");
            return {
                success         => 0,
                error           => $api_response->{error},
                iterations      => $iteration,
                tool_calls_made => $tool_calls_made,
                rate_limit_wait => 0,
            };
        }
    }

    # ── Non-retryable auth failures (403 subscription errors) ──────────────────────────────────
    if (defined($api_response->{error_type}) && $api_response->{error_type} eq 'auth_failed') {
        log_info('ErrorHandler', "Permanent auth failure detected - returning error immediately");
        return {
            success         => 0,
            error           => $api_response->{error},
            iterations      => $iteration,
            tool_calls_made => $tool_calls_made,
        };
    }

    # Provider backend unavailability (NVIDIA NIM "DEGRADED function cannot be invoked", etc.).
    # The model itself is unavailable on the provider's infrastructure. Returning immediately
    # avoids the misleading "Token limit exceeded" fallback that the retry/escalate path would
    # produce for a problem that retrying or trimming context cannot fix.
    if (defined($api_response->{error_type}) && $api_response->{error_type} eq 'provider_unavailable') {
        # Demoted from log_warning -> log_info. The themed error display path
        # surfaces the user-facing message; this log was duplicating it on
        # the user's terminal before the styled line.
        log_info('ErrorHandler', "Provider backend unavailable - returning error immediately without retry/trim");
        return {
            success         => 0,
            error           => $api_response->{error},
            iterations      => $iteration,
            tool_calls_made => $tool_calls_made,
        };
    }

    # Billing error - non-retryable. No amount of waiting fixes an empty balance.
    if (defined($api_response->{error_type}) && $api_response->{error_type} eq 'billing_error') {
        # Demoted from log_warning -> log_info. The themed error display path
        # surfaces the user-facing message.
        log_info('ErrorHandler', "Billing error (out of credits) - returning error immediately");
        return {
            success         => 0,
            error           => $api_response->{error},
            iterations      => $iteration,
            tool_calls_made => $tool_calls_made,
        };
    }

    # Model not found - non-retryable. The model literally doesn't exist for this provider/account.
    if (defined($api_response->{error_type}) && $api_response->{error_type} eq 'model_not_found') {
        # Demoted from log_warning -> log_info. The themed error display path
        # surfaces the user-facing message.
        log_info('ErrorHandler', "Model not found - returning error immediately");
        return {
            success         => 0,
            error           => $api_response->{error},
            iterations      => $iteration,
            tool_calls_made => $tool_calls_made,
        };
    }

    # Region unavailable - non-retryable. The model isn't accessible from the user's region.
    if (defined($api_response->{error_type}) && $api_response->{error_type} eq 'region_unavailable') {
        # Demoted from log_warning -> log_info. The themed error display path
        # surfaces the user-facing message.
        log_info('ErrorHandler', "Region unavailable - returning error immediately");
        return {
            success         => 0,
            error           => $api_response->{error},
            iterations      => $iteration,
            tool_calls_made => $tool_calls_made,
        };
    }

    # Account disabled - non-retryable. User must contact support/admin to restore access.
    if (defined($api_response->{error_type}) && $api_response->{error_type} eq 'account_disabled') {
        # Demoted from log_warning -> log_info. The themed error display path
        # surfaces the user-facing message.
        log_info('ErrorHandler', "Account disabled - returning error immediately");
        return {
            success         => 0,
            error           => $api_response->{error},
            iterations      => $iteration,
            tool_calls_made => $tool_calls_made,
        };
    }
    # ── Non-retryable errors ──────────────────────────────────────────
    $$retry_count_ref = 0;

    $$session_error_ref++;
    $session->{_error_count} = $$session_error_ref if $session;
    if ($$session_error_ref > $max_session_errors) {
        log_error('ErrorHandler', "Session error budget exhausted ($$session_error_ref errors). Stopping to prevent cascading failures.");
        return {
            success         => 0,
            error           => "Session error limit reached ($max_session_errors errors). Please start a new request or session. Last error: $error",
            iterations      => $iteration,
            tool_calls_made => $tool_calls_made,
        };
    }

    # Track consecutive identical errors.
    # Guard $wo access because callers under unit tests pass undef for $wo
    # (the lazy-require contract is exercised in isolation); this keeps the
    # debug-and-stats path warning-free under `perl -W`.
    my $last_error           = $wo ? ($wo->{last_error}           // '') : '';
    my $consecutive_errors   = $wo ? ($wo->{consecutive_errors}   // 0)  : 0;
    my $max_consecutive      = $wo ? ($wo->{max_consecutive_errors} // 3) : 3;
    if ($error eq $last_error) {
        $consecutive_errors++;
        log_debug('ErrorHandler', "Consecutive error count: $consecutive_errors/$max_consecutive");
    } else {
        $consecutive_errors = 1;
        $last_error = $error;
    }

    if ($consecutive_errors >= $max_consecutive) {
        log_debug('ErrorHandler', "Same error occurred $consecutive_errors times in a row. Breaking loop.");
        log_debug('ErrorHandler', "Persistent error: $error");
        log_debug('ErrorHandler', "This likely indicates a bug in the request construction or API incompatibility.");
        log_debug('ErrorHandler', "Check /tmp/clio_json_errors.log for details.");

        if ($wo) {
            $wo->{consecutive_errors} = 0;
            $wo->{last_error} = '';
        }
        return {
            success         => 0,
            error           => $error,
            content         => '',
            iterations      => $iteration,
            tool_calls_made => $tool_calls_made,
        };
    }

    # Remove bad assistant message
    if (@$messages && $messages->[-1]{role} eq 'assistant') {
        my $removed_msg = pop @$messages;
        log_warning('ErrorHandler', "Removed bad assistant message due to API error: $error");

        if ($wo->{debug}) {
            my $content_preview = substr($removed_msg->{content} // '', 0, 100);
            log_debug('ErrorHandler', "Removed message content: $content_preview...");
            if ($removed_msg->{tool_calls}) {
                log_debug('ErrorHandler', "Removed message had " . scalar(@{$removed_msg->{tool_calls}}) . " tool_calls");
            }
        }
    }

    # Check if error is token/context limit related
    my $is_token_limit_error = (
        $error =~ /context.length.exceeded/i ||
        $error =~ /maximum.context.length/i ||
        $error =~ /token.limit.exceeded/i ||
        $error =~ /too.many.tokens/i ||
        $error =~ /exceeds?\s+(?:the\s+)?(?:maximum|max)\s+(?:number\s+of\s+)?tokens/i ||
        $error =~ /input.*too\s+(?:long|large)/i ||
        $error =~ /reduce.*(?:prompt|input|context)/i
    );

    if (!$is_token_limit_error) {
        push @$messages, {
            role    => 'user',
            content => "SYSTEM ERROR: Your previous response triggered an API error and was removed.\n\n" .
                       "Error details: $error\n\n" .
                       "Please try a different approach. Avoid repeating the same action that caused this error.",
        };
        log_info('ErrorHandler', "Added error message to conversation, continuing workflow");
    } else {
        # Smart group-based trim for non-retryable token limit errors
        log_warning('ErrorHandler', "Token limit error detected. Using smart context trimming...");

        my $sys_msg    = undef;
        my @non_system = ();
        for my $msg (@$messages) {
            if ($msg->{role} && $msg->{role} eq 'system') {
                $sys_msg = $msg;
            } else {
                push @non_system, $msg;
            }
        }

        # Group messages into logical units
        my @groups        = ();
        my $current_group = [];

        for my $msg (@non_system) {
            if ($msg->{role} eq 'user') {
                push @groups, $current_group if @$current_group > 0;
                $current_group = [$msg];
            } elsif ($msg->{role} eq 'assistant') {
                if (@$current_group > 0 && $current_group->[-1]{role} eq 'user') {
                    push @$current_group, $msg;
                } else {
                    push @groups, $current_group if @$current_group > 0;
                    $current_group = [$msg];
                }
            } elsif ($msg->{role} eq 'tool') {
                push @$current_group, $msg;
            } else {
                push @$current_group, $msg;
            }
        }
        push @groups, $current_group if @$current_group > 0;

        # Keep last 3 complete groups
        my $keep_count = 3;
        $keep_count = scalar(@groups) if $keep_count > scalar(@groups);

        my @kept_groups = @groups[-$keep_count..-1] if $keep_count > 0;

        @$messages = ();
        push @$messages, $sys_msg if $sys_msg;
        for my $group (@kept_groups) {
            push @$messages, @$group;
        }

        my $removed_groups = scalar(@groups) - $keep_count;
        log_info('ErrorHandler', "Smart trim: kept $keep_count of " . scalar(@groups) . " message groups (removed $removed_groups)");
    }

    return 'continue';
}

#============================================================================
# Internal: Context Trimming
#============================================================================

=head2 trim_for_token_limit($wo, %args)

Reactive context trim for token_limit_exceeded errors.
Trims messages in place using a 3-tier strategy based on retry_count.

Parameters:
    $wo   - WorkflowOrchestrator instance
    %args - Same context as handle_api_error

Returns:
    { system_msg => '...' } on success
    { bail => 1, response => {...} } when further retries are pointless

=cut

sub trim_for_token_limit {
    my ($wo, %args) = @_;

    # See comment in handle_api_error: WO functions are called below.
    # Require lazily to break the circular import and guarantee WO is loaded.
    require CLIO::Core::WorkflowOrchestrator;

    my $messages        = $args{messages};
    my $retry_count     = $args{retry_count};
    # Dereference if passed as scalar ref: handle_api_error forwards
    # retry_count => \$retry_count (reference) so the caller can track it.
    # Using the reference as a value causes Perl to numify it to a
    # memory address (~94 trillion), making == 1 and == 2 always FALSE
    # and > 2 always TRUE — the precise-cut and 25%-cut branches become
    # dead code and every 400 immediately bails. (Fixed 2026-08-20.)
    $retry_count = $$retry_count if ref($retry_count) eq 'SCALAR';
    my $session         = $args{session};
    my $tool_calls_made = $args{tool_calls_made};
    my $iteration       = $args{iteration};
    my $max_retries     = $args{max_retries};
    my $max_server_retries = $args{max_server_retries};
    my $error           = $args{error};
    # Server-reported context size and prompt token count from the 400 error object.
    # When present, these pin the cut target precisely: server reported N tokens over
    # M tokens of context, so trim to M * 0.90. Without these, the cut target is an
    # estimate from compute_prompt_budget, which can be off by 1.5x+ when the
    # learned char/token ratio drifts from the model's actual tokenizer ratio
    # (observed on llama.cpp: estimate 104K, actual 163K, ratio off by 1.56x).
    my $srv_ctx         = $args{n_ctx};
    my $srv_prompt_toks = $args{n_prompt_tokens};

    dump_diagnostic(
        trigger     => 'trim',
        phase       => 'reactive_before',
        messages    => $messages,
        api_manager => $wo->{api_manager},
        iteration   => $iteration,
        retry_count => $retry_count,
        extra       => {
            max_retries        => $max_retries,
            max_server_retries => $max_server_retries,
            error_message      => $error || '',
        },
    ) if $ENV{CLIO_TRIM_DIAG};

    # Call WorkflowOrchestrator's checkpoint function
    CLIO::Core::WorkflowOrchestrator::_checkpoint_session_progress($session, $tool_calls_made, $iteration, $messages)
        if $session;

    # Separate system prompt and find most recent user message
    my $system_prompt = undef;
    my @non_system    = ();
    my $last_user_msg = undef;
    my $last_user_idx = -1;

    for my $msg (@$messages) {
        if ($msg->{role} eq 'system' && !$system_prompt) {
            $system_prompt = $msg;
        } else {
            push @non_system, $msg;
            if ($msg->{role} && $msg->{role} eq 'user') {
                $last_user_msg = $msg;
                $last_user_idx = $#non_system;
            }
        }
    }

    my $original_count = scalar(@non_system);

    # Build tool_call_id -> message index maps
    my %tool_call_indices   = ();
    my %tool_result_indices = ();

    for (my $i = 0; $i < @non_system; $i++) {
        my $msg = $non_system[$i];
        if ($msg->{role} && $msg->{role} eq 'assistant' &&
            $msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY') {
            for my $tc (@{$msg->{tool_calls}}) {
                $tool_call_indices{$tc->{id}} = $i if $tc->{id};
            }
        }
        elsif ($msg->{role} && $msg->{role} eq 'tool' && $msg->{tool_call_id}) {
            $tool_result_indices{$msg->{tool_call_id}} = $i;
        }
    }

    # ── Unified drift-aware trim ──────────────────────────────────────────
    #
    # Single parameterized walk replaces the old 3-tier strategy
    # (precise cut / 25% cut / minimal context). The drift ratio is
    # computed for ALL retries (loaded from saved state when server
    # data is unavailable), and the cut target varies by retry count.
    #
    # Cut targets:
    #   retry 1: 90% of ctx (precise)
    #   retry 2: 75% of ctx (moderate)
    #   retry 3+: minimal context (last user + last 2 messages)
    #
    # The walk drops oldest messages first, preserving tool_call/result
    # pairs and the most recent user message. Dropped messages are
    # compressed into a recovery summary.

    my $drift_ratio = 1.0;
    my $use_drift = 0;

    # Compute drift ratio from server-reported sizes (preferred).
    if (defined $srv_prompt_toks && $srv_prompt_toks > 0) {
        require CLIO::Memory::TokenEstimator;
        my $local_total = 0;
        if ($system_prompt) {
            $local_total += CLIO::Memory::TokenEstimator::estimate_tokens($system_prompt->{content} || '');
        }
        for my $msg (@non_system) {
            $local_total += CLIO::Memory::TokenEstimator::estimate_tokens($msg->{content} || '') + 4;
            $local_total += 8 if ($msg->{role} // '') eq 'tool';
            if ($msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY') {
                for my $tc (@{$msg->{tool_calls}}) {
                    my $json = safe_encode_json($tc, '');
                    $local_total += CLIO::Memory::TokenEstimator::estimate_tokens($json || '');
                }
            }
        }
        my $tools = $wo->{_tools_cache};
        if ($tools && ref($tools) eq 'ARRAY' && @$tools) {
            my $tool_chars = 0;
            for my $t (@$tools) {
                my $tjson = safe_encode_json($t, '');
                $tool_chars += length($tjson // '');
            }
            my $ratio = CLIO::Memory::TokenEstimator::get_effective_ratio();
            $local_total += int($tool_chars / $ratio) if $ratio > 0;
        }
        if ($local_total > 0) {
            $drift_ratio = $srv_prompt_toks / $local_total;
            $drift_ratio = 4.0 if $drift_ratio > 4.0;
            $drift_ratio = 1.0 if $drift_ratio < 1.0;
            $use_drift = 1;
            log_info('ErrorHandler', sprintf(
                "Drift ratio: server=%d actual, local=%d estimated, drift=%.3f",
                $srv_prompt_toks, $local_total, $drift_ratio));
        }

        # Save drift ratio to state for future retries / resumes
        if ($session && $session->can('state')) {
            my $state = $session->state();
            if (ref($state) && $state->{last_api_metadata}) {
                $state->{last_api_metadata}{estimate_drift_ratio} = $drift_ratio;
                $state->{last_api_metadata}{actual_tokens} = int($srv_prompt_toks);
                $state->{last_api_metadata}{estimated_tokens} = int($local_total);
            }
        }
    }
    # Fallback: load drift ratio from saved state (for retries 2+ when
    # the server didn't report token counts on this particular 400).
    elsif ($session && $session->can('state')) {
        my $state = $session->state();
        if (ref($state) && $state->{last_api_metadata}
            && $state->{last_api_metadata}{estimate_drift_ratio}) {
            $drift_ratio = $state->{last_api_metadata}{estimate_drift_ratio};
            $use_drift = 1;
            log_debug('ErrorHandler', sprintf("Loaded drift ratio %.3f from saved state", $drift_ratio));
        }
    }

    my $cut_pct;
    my $do_minimal = 0;

    if ($retry_count == 1) {
        $cut_pct = 0.90;
    }
    elsif ($retry_count == 2) {
        $cut_pct = 0.75;
    }
    else {
        # Retry 3+: minimal context (last user + last 2 messages)
        $do_minimal = 1;
    }

    my @dropped_messages;

    if ($do_minimal) {
        # Minimal context: keep last user message + last 2 messages
        @dropped_messages = @non_system;
        my @kept = ();
        push @kept, $last_user_msg if $last_user_msg;
        my @last_two = @non_system[-2..-1];
        for my $msg (@last_two) {
            next if $last_user_msg && defined $msg && $msg == $last_user_msg;
            push @kept, $msg;
        }
        @non_system = @kept;
    }
    else {
        # Drift-aware walk: drop oldest messages first until under budget.
        # Token estimates are scaled by drift_ratio to convert from local
        # char/token estimates to actual server-side tokens.

        my $keep_budget;
        my $_caps = $wo->{api_manager}
            ? ($wo->{api_manager}->get_model_capabilities() || {}) : {};
        if (defined $srv_ctx && $srv_ctx > 0) {
            # Use server-reported context window with output-aware budget.
            # The old int($srv_ctx * $cut_pct) formula ignored the model's
            # max_output_tokens, leaving only (1 - cut_pct) of context for
            # output — too small for models with large output caps, causing
            # the model to run out of tokens mid-output and hallucinate.
            require CLIO::Core::Defaults;
            my $_budget_caps = {
                max_context_window_tokens => $srv_ctx,
                max_output_tokens         => $_caps->{max_output_tokens}
                                           || CLIO::Core::Defaults::DEFAULT_MAX_OUTPUT_TOKENS(),
            };
            $keep_budget = CLIO::Memory::TokenEstimator::compute_prompt_budget($_budget_caps);
            $keep_budget = int($keep_budget * $cut_pct);
        } else {
            $keep_budget = CLIO::Memory::TokenEstimator::compute_prompt_budget($_caps);
            $keep_budget = int($keep_budget * $cut_pct);
            $keep_budget = 40000 if $keep_budget < 40000;
        }

        require CLIO::Core::Defaults;
        my $floor = CLIO::Core::Defaults::DEFAULT_POST_TRIM_FLOOR();
        $keep_budget = $floor if $keep_budget < $floor;

        log_info('ErrorHandler', sprintf(
            "Token-limit cut: retry=%d, ctx=%s, keep_budget=%d (%d%% of ctx, drift=%.3f%s)",
            $retry_count,
            defined $srv_ctx ? $srv_ctx : 'unknown',
            $keep_budget, int($cut_pct * 100), $drift_ratio,
            $use_drift ? '' : ' (no drift scaling)'));

        # Subtract system prompt and tool tokens from keep_budget
        my $system_actual = 0;
        if ($system_prompt) {
            $system_actual = estimate_tokens($system_prompt->{content} || '') * $drift_ratio;
        }
        my $tool_actual = 0;
        my $tools = $wo->{_tools_cache};
        if ($tools && ref($tools) eq 'ARRAY' && @$tools) {
            my $tool_chars = 0;
            for my $t (@$tools) {
                my $tjson = safe_encode_json($t, '');
                $tool_chars += length($tjson // '');
            }
            my $ratio = CLIO::Memory::TokenEstimator::get_effective_ratio() || 4.0;
            $tool_actual = ($tool_chars / $ratio) * $drift_ratio;
        }
        my $msg_budget = $keep_budget - $system_actual - $tool_actual;
        if ($msg_budget < $floor) {
            $msg_budget = $floor;
        }

        my $kept_tokens = 0;
        my $start_idx   = $original_count;
        for (my $i = $original_count - 1; $i >= 0; $i--) {
            my $msg_tokens = (estimate_tokens($non_system[$i]{content} || '') + 10) * $drift_ratio;
            if ($kept_tokens + $msg_tokens <= $msg_budget) {
                $kept_tokens += $msg_tokens;
                $start_idx = $i;
            } else {
                last;
            }
        }

        # Always keep at least the last 10 messages to avoid over-trimming
        my $min_start = $original_count - 10;
        $start_idx = $min_start if $start_idx > $min_start && $min_start >= 0;
        $start_idx = 0 if $start_idx < 0;

        @dropped_messages = @non_system[0..($start_idx - 1)] if $start_idx > 0;

        # Preserve the most recent user message
        my @must_include = ();
        push @must_include, $last_user_idx
            if $last_user_idx >= 0 && $last_user_idx < $start_idx;

        # Preserve assistant tool_call messages that correspond to
        # tool results we're keeping (avoids orphaned tool results)
        for (my $i = $start_idx; $i < $original_count; $i++) {
            my $msg = $non_system[$i];
            if ($msg->{role} && $msg->{role} eq 'tool' && $msg->{tool_call_id}) {
                my $tc_id = $msg->{tool_call_id};
                if (exists $tool_call_indices{$tc_id}) {
                    my $tc_idx = $tool_call_indices{$tc_id};
                    push @must_include, $tc_idx if $tc_idx < $start_idx;
                }
            }
        }

        if (@must_include) {
            @must_include = sort { $a <=> $b } @must_include;
            my @preserved = ();
            my %seen      = ();
            for my $idx (@must_include) {
                next if $seen{$idx}++;
                push @preserved, $non_system[$idx];
            }
            push @preserved, @non_system[$start_idx .. $#non_system];
            @non_system = @preserved;
        } else {
            @non_system = @non_system[$start_idx .. $#non_system];
        }
    }

    # Inject compression summary for dropped messages (always)
    if (@dropped_messages) {
        my $compressed = CLIO::Core::WorkflowOrchestrator::_compress_dropped_for_recovery(
            \@dropped_messages, $last_user_msg, $session, $messages, $wo->{prompt_builder}
        );
        if ($compressed) {
            push @non_system, $compressed;
            log_info('ErrorHandler', "Injected compression summary for " . scalar(@dropped_messages) . " dropped messages (retry $retry_count)");
        }
    }

    my $trimmed_count = $original_count - scalar(@non_system);

    # Rebuild messages array in place
    @$messages = ();
    push @$messages, $system_prompt if $system_prompt;
    push @$messages, @non_system;

    dump_diagnostic(
        trigger     => 'trim',
        phase       => 'reactive_after',
        messages    => $messages,
        api_manager => $wo->{api_manager},
        iteration   => $iteration,
        retry_count => $retry_count,
        extra       => {
            original_count      => $original_count,
            trimmed_count       => $trimmed_count,
            kept_count          => scalar(@non_system),
            last_user_preserved => ($last_user_msg ? 'YES' : 'NO'),
        },
    ) if $ENV{CLIO_TRIM_DIAG};

    my $preserved_info = $last_user_msg ? " (most recent user message preserved)" : "";
    my $recovery_info  = ($trimmed_count > 0) ? " Context summary injected." : "";
    my $system_msg = "Token limit exceeded. Trimmed $trimmed_count messages from conversation history and retrying$preserved_info...$recovery_info (attempt $retry_count/$max_retries)";

    log_info('ErrorHandler', "Trimmed $trimmed_count messages due to token limit (kept " . scalar(@non_system) . " messages, last_user=" . ($last_user_msg ? 'YES' : 'NO') . ")");

    # Nothing trimmed means context isn't the problem
    if ($trimmed_count == 0) {
        # Demoted from log_warning -> log_info. The themed error display
        # below surfaces the user-facing message.
        log_info('ErrorHandler', "Context trim removed 0 messages - problem is not context size. Escalating to non-retryable.");

        dump_diagnostic(
            trigger      => 'persistent_400',
            phase        => 'trim_zero',
            messages     => $messages,
            api_manager  => $wo->{api_manager},
            iteration    => $iteration,
            retry_count  => $retry_count,
            error        => $error,
            append       => 1,
            extra        => {
                escalations    => $wo->{_bad_request_escalations} || 0,
                original_count => $original_count,
                trimmed_count  => 0,
            },
        );

        return {
            bail     => 1,
            response => {
                success         => 0,
                error           => "API error persists after context trim (0 messages removed, $retry_count retries). Diagnostic dump written to /tmp/clio_diag_persistent_400.log. Try a different model, or wait a few minutes and retry.",
                iterations      => $iteration,
                tool_calls_made => $tool_calls_made,
            },
        };
    }

    # Minimal context and still failing
    if ($retry_count > 2 && scalar(@non_system) <= 3) {
        log_debug('ErrorHandler', "Token limit persists even with minimal context - giving up");
        return {
            bail     => 1,
            response => {
                success         => 0,
                error           => "Token limit exceeded even with minimal conversation history. The request may be too large for this model. Try using a model with a larger context window.",
                tool_calls_made => $tool_calls_made,
            },
        };
    }

    return { system_msg => $system_msg };
}

1;
