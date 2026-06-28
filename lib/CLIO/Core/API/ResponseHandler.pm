package CLIO::Core::API::ResponseHandler;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;

use CLIO::Core::Logger qw(should_log log_error log_warning log_info log_debug);
use CLIO::Util::JSON qw(decode_json encode_json safe_decode_json safe_encode_json);
use CLIO::Util::RateLimit qw(format_reset_message);
use Scalar::Util qw(blessed);

=head1 NAME

CLIO::Core::API::ResponseHandler - API response processing and rate limiting

=head1 DESCRIPTION

Handles API response processing including error classification, rate limit
header parsing, GitHub Copilot quota tracking, broker slot management, and
stateful marker storage for session continuation.

Extracted from APIManager to reduce module size and improve separation of
concerns. Uses OO style since it maintains shared state with the parent
APIManager instance.

=head1 SYNOPSIS

    use CLIO::Core::API::ResponseHandler;

    my $handler = CLIO::Core::API::ResponseHandler->new(
        session       => $session,
        broker_client => $broker_client,
        debug         => 1,
    );

    # Process error responses
    my $result = $handler->handle_error_response($resp, $json, $is_streaming);

    # Process rate limit headers
    $handler->process_rate_limit_headers($headers);

    # Process quota headers
    $handler->process_quota_headers($headers, $response_id);

    # Release broker slot
    $handler->release_broker_slot($resp, $status);

    # Stateful marker management
    $handler->store_stateful_marker($marker, $model, $iteration);
    my $marker = $handler->get_stateful_marker_for_model($model);

=cut

=head2 _get_current_provider

Get the current provider from session state.

Returns: Provider string (e.g. 'github_copilot', 'zai_coding') or 'unknown'

=cut

sub _get_current_provider {
    my ($self) = @_;
    if ($self->{session}) {
        if ($self->{session}->can('state') && $self->{session}->state() && $self->{session}->state()->{selected_provider}) {
            return $self->{session}->state()->{selected_provider};
        }
        return $self->{session}{selected_provider} if $self->{session}{selected_provider};
    }
    return 'unknown';
}

sub new {
    my ($class, %opts) = @_;
    return bless {
        session                   => $opts{session},
        broker_client             => $opts{broker_client},
        debug                     => $opts{debug} // 0,
        # Rate limiting state
        rate_limit_until          => undef,
        _rate_limit_info          => undef,
        _rate_limit_reset_in      => undef,
        _dynamic_min_delay        => 1.0,
        # Broker state
        _current_broker_request_id => undef,
        # Error tracking
        last_failed_tool          => undef,
    }, $class;
}

=head2 set_session

Update the session reference (called when session changes).

=cut

sub set_session {
    my ($self, $session) = @_;
    $self->{session} = $session;
}

=head2 set_broker_request_id

Set the current broker request ID for slot tracking.

=cut

sub set_broker_request_id {
    my ($self, $id) = @_;
    $self->{_current_broker_request_id} = $id;
}

=head2 _get_rate_limit_user_message

Generate a user-friendly message for rate limit errors based on error codes.

Based on GitHub Copilot's error code hierarchy:
- agent_mode_limit_exceeded: Agent mode specific rate limit
- model_overloaded: Upstream model provider overloaded
- upstream_provider_rate_limit: Upstream provider rate limit
- user_global_rate_limited: Global user rate limit
- user_model_rate_limited: Per-model rate limit
- integration_rate_limited: Integration-wide rate limit

Arguments:
- $info: Hashref with optional 'code' and 'retry_after' fields

Returns: User-friendly message string

=cut

sub _get_rate_limit_user_message {
    my ($info) = @_;
    return undef unless $info && $info->{code};

    my $code           = $info->{code};
    my $retry_after    = $info->{retry_after} // 0;
    my $reset_timestamp = $info->{reset_timestamp};

    # Agent mode rate limit exceeded
    if ($code =~ /agent_mode_limit_exceeded/i) {
        return "Sorry, you have exceeded the agent mode rate limit. Please switch to ask mode and try again.";
    }

    # Upstream model/provider overloaded
    if ($code =~ /model_overloaded/i || $code =~ /upstream_provider_rate_limit/i) {
        return "Sorry, the upstream model provider is currently experiencing high demand. Please try again.";
    }

    # User global rate limit
    if ($code =~ /user_global_rate_limited/i) {
        return "You've hit your global rate limit. Please upgrade your plan or wait before making more requests.";
    }

    # Per-model rate limit
    if ($code =~ /user_model_rate_limited/i) {
        return "You've hit the rate limit for this model. Please try again.";
    }

    # Integration-wide rate limit
    if ($code =~ /integration_rate_limited/i) {
        return "Sorry, GitHub Copilot is currently experiencing high demand. Please try again in a few moments.";
    }

    # Weekly rate limit - don't suggest retry time (it's weekly, not seconds)
    if ($code =~ /user_weekly_rate_limited/i) {
        return "Sorry, you've exceeded your weekly rate limit. Please review your usage.";
    }

    # Monthly rate limit - don't suggest retry time (it's monthly, not seconds)
    if ($code =~ /user_monthly_rate_limited/i) {
        return "Sorry, you've exceeded your monthly rate limit. Please review your usage.";
    }

    # Generic rate limit (no specific code match)
    return undef;
}

=head2 _get_quota_exceeded_user_message

Generate a user-friendly message for quota exceeded errors based on error codes.

Based on GitHub Copilot's quota error code hierarchy:
- free_quota_exceeded: Free tier quota exhausted
- quota_exceeded: AI Credits exhausted
- overage_limit_reached: Overage limit reached

Arguments:
- $info: Hashref with optional 'code' field
- $copilot_plan: User's Copilot plan (free, individual, individual_pro)

Returns: User-friendly message string

=cut

sub _get_quota_exceeded_user_message {
    my ($info, $copilot_plan) = @_;

    my $code = $info && $info->{code} ? $info->{code} : '';

    # Free tier quota exceeded
    if ($code eq 'free_quota_exceeded') {
        return "You've reached your monthly chat messages quota. Upgrade to Copilot Pro (30-day free trial) or wait for your quota to reset.";
    }

    # General quota exceeded
    if ($code eq 'quota_exceeded') {
        if ($copilot_plan eq 'free') {
            return "You've reached your monthly chat messages quota. Upgrade to Copilot Pro for higher limits.";
        }
        if ($copilot_plan eq 'individual' || $copilot_plan eq 'individual_pro') {
            return "You've exhausted your AI Credits. Please enable additional paid usage or switch to Auto mode.";
        }
        return "You've exhausted your AI Credits. To continue working, switch to Auto mode.";
    }

    # Overage limit reached
    if ($code eq 'overage_limit_reached') {
        return "You cannot accrue additional AI Credits at this time. Please contact GitHub Support if you need assistance.";
    }

    # Z.AI insufficient balance (code 1113)
    if ($code eq '1113') {
        return "Your Z.AI account has insufficient balance or no active resource package. Please recharge your account to continue.";
    }

    # Generic quota exceeded
    return "You've reached your API quota limit. Please check your plan details.";
}

=head2 handle_error_response

Classify and handle API error responses.

Determines if errors are retryable (rate limits, server errors, auth recovery)
or fatal (auth failures, unknown errors). Returns structured result with
retry guidance.

Arguments:
- $resp: HTTP::Response object
- $json: Original request JSON (for debugging)
- $is_streaming: Boolean, true if this was a streaming request

Returns:
- Hashref with: success, error, retryable, retry_after, error_type

=cut

sub handle_error_response {
    my ($self, @args) = @_;
    return $self->_handle_error_response_impl(@args);
}

sub _handle_error_response_impl {

    my ($self, $resp, $json, $is_streaming, %opts) = @_;

    my $attempt_token_recovery = $opts{attempt_token_recovery};
    my $passed_headers = $opts{headers};

    # Parse the error response (decoded body, extracted error object, normalized status)
    my $parsed = $self->_parse_error_response($resp, $is_streaming);
    my $status = $parsed->{status};
    my $error = $parsed->{error};
    my $content = $parsed->{content};
    my $error_obj = $parsed->{error_obj};
    my $detected_rate_limit_code = $parsed->{detected_rate_limit_code};

    my $retryable = 0;
    my $retry_after = undef;
    my $retry_info = '';
    my $is_retryable_error = 0;
    my $error_type = undef;

    # Handle rate limiting (429)
    if ($status == 429) {
        $is_retryable_error = 1;
        $retryable = 1;
        $retry_after = 60;
        $error_type = 'rate_limit';

        # Extract retry_after from multiple sources, in order of reliability
        my $retry_source = 'default';
        my $retry_after_header;
        my $reset_timestamp = '';  # Initialize to avoid uninitialized warnings in log messages

        # Extract reset/retry info from headers first (before main extraction loop)
        if ($passed_headers) {
            # Use headers passed directly (from streaming responses)
            # $passed_headers may be a plain hash or a HTTP::Headers object
            if (ref($passed_headers) eq 'HASH') {
                $retry_after_header = $passed_headers->{'retry-after'} || $passed_headers->{'x-ratelimit-user-retry-after'};
                $reset_timestamp = $passed_headers->{'x-ratelimit-reset'};
            } elsif ($passed_headers->can('header')) {
                $retry_after_header = $passed_headers->header('Retry-After') // $passed_headers->header('X-RateLimit-User-Retry-After');
                $reset_timestamp = $passed_headers->header('X-RateLimit-Reset');
            }
        }
        
        # Debug: log all rate limit headers for weekly/monthly limit diagnosis
        if ($detected_rate_limit_code && $detected_rate_limit_code =~ /user_weekly_rate_limited|user_monthly_rate_limited/i) {
            my $header_debug = 'Rate limit headers debug: ';
            if (ref($passed_headers) eq 'HASH') {
                $header_debug .= "hash{retry-after}=$passed_headers->{'retry-after'}, ";
                $header_debug .= "hash{x-ratelimit-user-retry-after}=$passed_headers->{'x-ratelimit-user-retry-after'}, ";
                $header_debug .= "hash{x-ratelimit-reset}=$passed_headers->{'x-ratelimit-reset'}";
            } elsif (ref($passed_headers) && $passed_headers->can('header')) {
                $header_debug .= "object{" . ref($passed_headers) . "}";
                $header_debug .= " Retry-After=" . (defined($passed_headers->header('Retry-After')) ? "'" . $passed_headers->header('Retry-After') . "'" : 'undef');
                $header_debug .= " X-RateLimit-User-Retry-After=" . (defined($passed_headers->header('X-RateLimit-User-Retry-After')) ? "'" . $passed_headers->header('X-RateLimit-User-Retry-After') . "'" : 'undef');
                $header_debug .= " X-RateLimit-Reset=" . (defined($passed_headers->header('X-RateLimit-Reset')) ? "'" . $passed_headers->header('X-RateLimit-Reset') . "'" : 'undef');
            } else {
                $header_debug .= "passed_headers is " . (defined($passed_headers) ? "'$passed_headers' (" . ref($passed_headers) . ")" : 'undef');
            }
            log_info('ResponseHandler', $header_debug);
        }

        if ($error =~ /(?:retry\s+in|please\s+wait)\s+([\d.]+)\s*s(?:econds?)?/i) {
            $retry_after = int($1) + 1;
            $retry_source = 'error_message';
        } elsif ($retry_after_header) {
            $retry_after = $retry_after_header;
            $retry_source = 'header';
        }
        # Also check for retryAfter in the error body (GitHub Copilot may return this)
        elsif (ref($error_obj) eq 'HASH' && $error_obj->{retryAfter}) {
            $retry_after = $error_obj->{retryAfter};
            $retry_source = 'body_retryAfter';
        }
        # Check for reset timestamp (GitHub may return epoch seconds)
        elsif (ref($error_obj) eq 'HASH' && $error_obj->{retryAfterTimestamp}) {
            $retry_after = int($error_obj->{retryAfterTimestamp} - time());
            $retry_after = 1 if $retry_after < 1;
            $retry_source = 'body_timestamp';
        }
        
        # Fallback: ensure retry_after has a value if not set by any branch
        $retry_after //= 60;
        
        # Ensure reset_timestamp is defined for logging
        $reset_timestamp //= '';
        $retry_source //= 'unknown';

        log_debug('ResponseHandler', "Rate limit detected (code=$detected_rate_limit_code), retry_after=$retry_after (source=$retry_source), reset_timestamp=$reset_timestamp");
        # Log raw error body for debugging rate limit timing info
        if ($content && ref($content) eq 'HASH') {
            log_debug('ResponseHandler', "Rate limit error body: " . encode_json($content));
        }

        # Try to get user-friendly message based on error code
        my $rate_limit_info = {
            retry_after     => $retry_after,
            code           => $detected_rate_limit_code,
            reset_timestamp => $reset_timestamp,
        };
        my $user_message = _get_rate_limit_user_message($rate_limit_info);

        # Also check for Copilot-style quota messages ("You've used X% of your session rate limit")
        # These come in error_obj.message or error_obj.reason and should be preserved as system_message
        if (!$user_message && $error_obj && ref($error_obj) eq 'HASH') {
            my $quota_msg = $error_obj->{message} // $error_obj->{reason} // '';
            # Match both "you've used" and "you have used" patterns
            if ($quota_msg =~ /you(?:'ve| have) used \d+%? of your? (session )?rate limit/i ||
                $quota_msg =~ /percent_remaining/i) {
                $user_message = $quota_msg;
                log_info('ResponseHandler', "Captured Copilot quota message: $quota_msg");
            }
        }

        # Weekly/monthly limits don't reset quickly - don't use misleading retry_after header
        # The header might say "retry in 1 second" but the actual limit takes days to reset
        log_debug('ResponseHandler', "Rate limit check: detected_code=$detected_rate_limit_code, retry_after=$retry_after, reset_ts=$reset_timestamp");
        log_debug('ResponseHandler', "Rate limit error_obj: " . encode_json($error_obj)) if $error_obj;
        if ($detected_rate_limit_code && $detected_rate_limit_code =~ /user_weekly_rate_limited|user_monthly_rate_limited/i) {
            # For weekly/monthly limits, we need the actual reset time from x-ratelimit-user-retry-after
            # The short retry-after header (e.g., "4") is misleading for weekly limits
            my $actual_retry_after;
            my $long_retry_header;
            
            # Try to get the long-duration retry header specifically
            if (ref($passed_headers) eq 'HASH') {
                $long_retry_header = $passed_headers->{'x-ratelimit-user-retry-after'};
            } elsif ($passed_headers && $passed_headers->can('header')) {
                $long_retry_header = $passed_headers->header('X-RateLimit-User-Retry-After');
            }
            
            if ($long_retry_header && $long_retry_header =~ /^\d+$/) {
                # x-ratelimit-user-retry-after is already in seconds
                $actual_retry_after = int($long_retry_header);
                log_info('ResponseHandler', "Using x-ratelimit-user-retry-after: ${actual_retry_after}s");
            } elsif ($reset_timestamp && $reset_timestamp =~ /^\d+$/ && $reset_timestamp > time()) {
                $actual_retry_after = int($reset_timestamp - time());
            } elsif (defined $self->{_rate_limit_reset_in} && $self->{_rate_limit_reset_in} > 0) {
                # Use cached reset time from previous successful responses
                $actual_retry_after = $self->{_rate_limit_reset_in};
                log_info('ResponseHandler', "Using cached rate limit reset time: ${actual_retry_after}s");
            } else {
                # API didn't provide accurate reset time - don't show misleading value
                log_info('ResponseHandler', "No reset time available: long_retry_header=" . 
                    (defined $long_retry_header ? $long_retry_header : 'undef') . 
                    ", retry_after_header=" . (defined $retry_after_header ? $retry_after_header : 'undef') .
                    ", reset_timestamp=$reset_timestamp, _rate_limit_reset_in=" . 
                    (defined $self->{_rate_limit_reset_in} ? $self->{_rate_limit_reset_in} : 'undef'));
                $actual_retry_after = undef;
            }
            $retry_after = 0;  # Don't suggest a retry time - it's not accurate
            $is_retryable_error = 0;  # Don't retry weekly/monthly limits
            $retryable = 0;
            
            # Build error message with expiration time if available
            my $expiration_str = '';
            if (defined($actual_retry_after) && $actual_retry_after > 0) {
                my $days = int($actual_retry_after / 86400);
                my $hours = int(($actual_retry_after % 86400) / 3600);
                if ($days > 0) {
                    $expiration_str = sprintf(" This limit expires in ~%d hours (%d days).", $actual_retry_after / 3600, $days);
                } elsif ($hours > 0) {
                    $expiration_str = sprintf(" This limit expires in ~%d hours.", $hours);
                } else {
                    $expiration_str = sprintf(" This limit expires in ~%d minutes.", int($actual_retry_after / 60));
                }
            }
            
            # Check if alternative providers are available for provider switch suggestion
            my $provider_switch = '';
            eval {
                require CLIO::Providers;
                my @providers = CLIO::Providers::list_providers();
                if (@providers > 1) {
                    $provider_switch = " Please switch to another provider to continue this session.";
                }
            };
            
            $error = "Sorry, you've exceeded your weekly rate limit.${provider_switch}${expiration_str}";
            # Pass via error_obj for WorkflowOrchestrator to extract
            $error_obj->{_preserved_retry_after} = $actual_retry_after if defined($actual_retry_after);
            
            # Don't set rate_limit_until for weekly/monthly limits - the short retry_after
            # is misleading and the /usage display would show wrong info
            $self->{rate_limit_until} = 0;
            
            # Store rate limit per-provider for /usage display
            my $rl_provider = $self->_get_current_provider();
            if ($self->{session} && $self->{session}->can('state')) {
                my $state = $self->{session}->state();
                $state->{rate_limits} //= {};
                $state->{rate_limits}{$rl_provider} //= {};
                $state->{rate_limits}{$rl_provider}{rate_limit_until} = 0;
                $state->{rate_limits}{$rl_provider}{rate_limit_code} = $detected_rate_limit_code;
            } elsif ($self->{session}) {
                $self->{session}{rate_limit_until} = 0;
                $self->{session}{rate_limit_code} = $detected_rate_limit_code;
            }
            
            log_info('ResponseHandler', "Weekly/monthly rate limit detected: $detected_rate_limit_code" . 
                (defined($actual_retry_after) ? sprintf(", expires in %d seconds (~%.1f hours)", $actual_retry_after, $actual_retry_after / 3600) : " (reset time unknown)"));
            
            # Build result directly for weekly/monthly limits (skip else/elsif chains)
            my $weekly_result = { success => 0, error => $error, _error => $error };
            $weekly_result->{retryable} = 0;
            $weekly_result->{error_type} = 'rate_limit';
            $weekly_result->{rate_limit_code} = $detected_rate_limit_code if $detected_rate_limit_code;
            $weekly_result->{error_obj} = $error_obj if $error_obj;
            
            log_debug('ResponseHandler', "Final error being returned: $error");
            return $weekly_result;
        }
        # Handle Z.AI usage limit (codes 1308 and 1310) - non-retryable, resets at specific time
        # Error message format: "Usage limit reached for 5 hour. Your limit will reset at 2026-04-17 07:03:43"
        # Code 1310: "Weekly/Monthly Limit Exhausted. Your limit will reset at 2026-04-24 02:02:21"
        elsif ($detected_rate_limit_code && ($detected_rate_limit_code == 1308 || $detected_rate_limit_code == 1310)) {
            my $actual_retry_after;
            my $reset_str;
            
            # Parse reset time from error message: "Your limit will reset at YYYY-MM-DD HH:MM:SS"
            # Z.AI returns datetime in CST (Beijing Time, UTC+8)
            if ($error =~ /reset at (\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})/) {
                $reset_str = $1;
                eval {
                    require Time::Piece;
                    # Parse as CST (UTC+8) explicitly by appending timezone marker
                    my $reset_time = Time::Piece->strptime($reset_str . " +0800", "%Y-%m-%d %H:%M:%S %z");
                    $actual_retry_after = int($reset_time->epoch - time());
                    log_debug('ResponseHandler', "Parsed Z.AI reset time: $reset_str (CST) -> ${actual_retry_after}s until reset");
                };
                if ($@ || !defined($actual_retry_after)) {
                    log_warning('ResponseHandler', "Failed to parse Z.AI reset time '$reset_str': $@");
                    $actual_retry_after = undef;
                }
            } else {
                log_debug('ResponseHandler', "No reset time found in Z.AI error message");
            }
            
            $retry_after = 0;
            $is_retryable_error = 0;
            $retryable = 0;
            
            # Build error message with human-readable reset time and local time
            my $expiration_str = '';
            if (defined($actual_retry_after) && $actual_retry_after > 0) {
                my $days = int($actual_retry_after / 86400);
                my $hours = int(($actual_retry_after % 86400) / 3600);
                my $mins = int(($actual_retry_after % 3600) / 60);
                
                my $delta_str;
                if ($days > 0) {
                    $delta_str = sprintf("%dd %dh", $days, $hours);
                } elsif ($hours > 0) {
                    $delta_str = sprintf("%dh %dm", $hours, $mins);
                } else {
                    $delta_str = sprintf("%dm", $mins);
                }
                
                # Also show local time of reset for clarity
                require Time::Piece;
                my $reset_epoch = Time::Piece->strptime($reset_str . " +0800", "%Y-%m-%d %H:%M:%S %z")->epoch;
                my $reset_local = Time::Piece->new($reset_epoch)->strftime("%H:%M %Z");
                $expiration_str = sprintf(" This limit expires in %s (reset at %s local).", $delta_str, $reset_local);
            }
            
            # Check if alternative providers are available
            my $provider_switch = '';
            eval {
                require CLIO::Providers;
                my @providers = CLIO::Providers::list_providers();
                if (@providers > 1) {
                    $provider_switch = " Please switch to another provider to continue this session.";
                }
            };
            
            $error = "Sorry, you've exceeded your Z.AI usage limit.${provider_switch}${expiration_str}";
            
            # Store reset info in session for /usage display
            $error_obj->{_preserved_retry_after} = $actual_retry_after if defined($actual_retry_after);
            $self->{rate_limit_until} = 0;
            
            if ($self->{session} && $self->{session}->can('state')) {
                my $state = $self->{session}->state();
                my $rl_provider = $self->_get_current_provider();
                $state->{rate_limits} //= {};
                $state->{rate_limits}{$rl_provider} //= {};
                $state->{rate_limits}{$rl_provider}{rate_limit_until} = 0;
                $state->{rate_limits}{$rl_provider}{rate_limit_code} = 'zai_usage_limit';
                # Store human-readable reset time for /usage display
                if ($reset_str) {
                    $state->{zai_reset_time} = $reset_str . " CST";
                }
                if (defined $actual_retry_after) {
                    $state->{zai_reset_in} = $actual_retry_after;
                }
            } elsif ($self->{session}) {
                $self->{session}{rate_limit_until} = 0;
                $self->{session}{rate_limit_code} = 'zai_usage_limit';
                if ($reset_str) {
                    $self->{session}{zai_reset_time} = $reset_str . " CST";
                }
                if (defined $actual_retry_after) {
                    $self->{session}{zai_reset_in} = $actual_retry_after;
                }
            }
            
            log_info('ResponseHandler', "Z.AI usage limit detected (code=$detected_rate_limit_code)" . 
                (defined($actual_retry_after) ? sprintf(", expires in %d seconds (~%.1f hours)", $actual_retry_after, $actual_retry_after / 3600) : " (reset time unknown)"));
            
            my $zai_result = { success => 0, error => $error, _error => $error };
            $zai_result->{retryable} = 0;
            $zai_result->{error_type} = 'rate_limit';
            $zai_result->{rate_limit_code} = 'zai_usage_limit';
            $zai_result->{error_obj} = $error_obj if $error_obj;
            
            log_debug('ResponseHandler', "Final error being returned: $error");
            return $zai_result;
        }
        # Handle Z.AI concurrency/frequency limits (codes 1302, 1303, 1305)
        # 1302 = High concurrency, 1303 = High frequency -> short retry (3-5s)
        # 1305 = General rate limit -> medium retry (30s)
        # These are retryable with shorter backoff than the default 60s
        elsif ($detected_rate_limit_code &&
               ($detected_rate_limit_code == 1302 ||
                $detected_rate_limit_code == 1303 ||
                $detected_rate_limit_code == 1305)) {
            my $zai_rl_type;
            if ($detected_rate_limit_code == 1302) {
                $zai_rl_type = 'concurrency';
                $retry_after = 3;
            } elsif ($detected_rate_limit_code == 1303) {
                $zai_rl_type = 'frequency';
                $retry_after = 5;
            } else {
                $zai_rl_type = 'rate_limit';
                $retry_after = 30;
            }

            $is_retryable_error = 1;
            $retryable = 1;
            $retry_info = sprintf("Z.AI %s limit (code %s). Retrying in %ds...",
                $zai_rl_type, $detected_rate_limit_code, $retry_after);
            $error = $retry_info;
            log_info('ResponseHandler', "Z.AI $zai_rl_type limit (code=$detected_rate_limit_code), retry_after=${retry_after}s");
        } elsif ($user_message) {
            $retry_info = sprintf("%s Retrying in %d seconds.", $user_message, $retry_after);
            $error = $retry_info;
        } else {
            $retry_info = sprintf("API rate limit exceeded. Retrying in %d seconds.", $retry_after);
            $error = $retry_info;
        }

        # Handle Copilot-style quota messages ("You've used X% of your session rate limit")
        # These are non-retryable - the user needs to wait for reset, can't fix with retry
        if ($user_message && $user_message =~ /you(?:'ve| have) used \d+%? of your? (session )?rate limit/i) {
            $is_retryable_error = 0;
            $retryable = 0;
            $retry_after = 0;
            $error_type = 'rate_limit';
            $error = $user_message;  # Return the message directly, no "Retrying in X seconds"
            log_info('ResponseHandler', "Copilot session rate limit detected (non-retryable): $user_message");

            my $copilot_result = { success => 0, error => $error, _error => $error };
            $copilot_result->{retryable} = 0;
            $copilot_result->{retry_after} = 0;
            $copilot_result->{error_type} = 'rate_limit';
            $copilot_result->{rate_limit_code} = 'copilot_session_limit';
            $copilot_result->{system_message} = $user_message;
            $copilot_result->{error_obj} = $error_obj if $error_obj;
            log_debug('ResponseHandler', "Final error being returned: $error");
            return $copilot_result;
        }
    }
    # Handle quota exceeded errors (non-retryable - user must take action)
    # Detected via semantic codes in error body, not HTTP status
    elsif (ref($error_obj) eq 'HASH' && $error_obj->{code} &&
           ($error_obj->{code} eq 'quota_exceeded' ||
            $error_obj->{code} eq 'free_quota_exceeded' ||
            $error_obj->{code} eq 'overage_limit_reached' ||
            $error_obj->{code} eq '1113')) {
        $is_retryable_error = 0;
        $retryable = 0;
        $error_type = 'quota_exceeded';

        # Get user-friendly message based on error code
        my $copilot_plan = $self->{session}{copilot_plan} if $self->{session};
        my $user_message = _get_quota_exceeded_user_message($error_obj, $copilot_plan);
        $error = $user_message;
        log_info('ResponseHandler', "Quota exceeded (code=$error_obj->{code}): $user_message");
    }
    # Handle authentication failures (401, 403)
    # RFC 9110: 401 = "I don't know you" (invalid credentials), 403 = "I know you but you're not allowed"
    # We treat these differently:
    #   - 401: Token is invalid, recovery makes sense
    #   - 403: Check if it's a permanent failure (subscription required, model unavailable) before recovering
    elsif ($status == 401 || $status == 403) {
        # For 403, check if the error message indicates a permanent failure that token recovery won't fix
        my $is_permanent_auth_failure = 0;
        my $original_error_msg = $error;  # Preserve original error for permanent failures

        if ($status == 403) {
            # Check for subscription/upgrade/payment required errors
            # These are permanent - retrying won't help
            # Handle both hash errors ({message => "...", code => "..."}) and plain string errors
            my $err_msg = '';
            if (ref($error_obj) eq 'HASH') {
                $err_msg = $error_obj->{message} // '';
            } elsif (!ref($error_obj)) {
                # Plain string error - use the error string directly
                $err_msg = "$error_obj";
            }

            if ($err_msg =~ /subscription|upgrade|paid|requires? (a |the )?(subscription|model|plan)/i) {
                $is_permanent_auth_failure = 1;
                log_info('ResponseHandler', "403 permanent auth failure detected (subscription/upgrade required): $err_msg");
            }
        }

        if ($is_permanent_auth_failure) {
            # Permanent failure - don't attempt recovery, just report the original error
            $is_retryable_error = 0;
            $retryable = 0;
            $error_type = 'auth_failed';
            # Preserve the actual provider error message
            $error = $original_error_msg;
            log_info('ResponseHandler', "Returning permanent 403 error without recovery attempt");
        }
        else {
            # Potentially transient auth failure (401, or 403 without subscription keywords)
            log_info('ResponseHandler', "Authentication error ($status), attempting token recovery");

            my $recovered = 0;
            if ($attempt_token_recovery) {
                $recovered = $attempt_token_recovery->();
            }

            if ($recovered) {
                $is_retryable_error = 1;
                $retryable = 1;
                $retry_after = 1;
                $error_type = 'auth_recovered';
                $retry_info = "Authentication token refreshed. Retrying request...";
                $error = $retry_info;
            } else {
                $error = "Authentication failed (HTTP $status). Your token may have expired or been revoked. "
                       . "Please run /api logout then /api login to re-authenticate.";
                $error_type = 'auth_failed';
            }
        }
    }
    # Handle transient server errors (5xx except 599 which is handled as connection_error)
    elsif ($status >= 500 && $status < 599) {
        $is_retryable_error = 1;
        $retryable = 1;
        $retry_after = 2;
        $error_type = 'server_error';
        $retry_info = "Server temporarily unavailable ($status). Retrying...";
        $error = $retry_info;
    }
    # Handle connection errors (599 = curl/HTTP::Tiny internal failure)
    elsif ($status == 599 || $status < 100) {
        $is_retryable_error = 1;
        $retryable = 1;
        $retry_after = 3;
        $error_type = 'connection_error';
        my $reason = eval { $resp->message } // 'unknown';
        $retry_info = "Connection error: $reason. Retrying...";
        $error = $retry_info;
    }
    # Handle token limit exceeded (400)
    elsif ($status == 400 && $error =~ /model_max_prompt_tokens_exceeded|context_length_exceeded|prompt token count.*exceeds/i) {
        $is_retryable_error = 1;
        $retryable = 1;
        $retry_after = 0;
        $error_type = 'token_limit_exceeded';
        $error = "Token limit exceeded: The conversation history is too long for the model's context window. "
               . "Will attempt to trim conversation history and retry.";
        log_info('ResponseHandler', "Token limit exceeded - will retry after trimming");
    }
    # Handle malformed tool call JSON (400)
    elsif ($status == 400 && ($error =~ /invalid.*json.*tool.*call|tool.*call.*invalid.*json/i ||
                               $error =~ /request body is not valid json|invalid.*json|json.*parse|malformed.*json/i)) {
        $is_retryable_error = 1;
        $retryable = 1;
        $retry_after = 1;
        $error_type = 'malformed_tool_json';

        if ($json) {
            if (open my $fh, '>>', '/tmp/clio_json_errors.log') {
                print $fh "\n" . "=" x 80 . "\n";
                print $fh "[" . scalar(localtime) . "] API Rejected JSON\n";
                print $fh "HTTP Status: $status\n";
                print $fh "Error: $error\n";
                print $fh "Payload (first 5000 chars):\n";
                print $fh substr($json, 0, 5000) . "\n";
                if (length($json) > 5000) {
                    print $fh "... (truncated, total length: " . length($json) . " bytes)\n";
                }
                close $fh;
            }
            log_debug('ResponseHandler', "API rejected JSON payload - logged to /tmp/clio_json_errors.log");
        }

        # Try to extract failed tool name
        my $failed_tool = undef;
        my $response_body = $resp->decoded_content;
        if ($response_body =~ /"name":\s*"([^"]+)"/ || $response_body =~ /tool[_\s]name['":\s]+([a-zA-Z_]+)/) {
            $failed_tool = $1;
            log_debug('ResponseHandler', "Extracted failed tool name: $failed_tool");
        }

        $retry_info = "AI generated malformed tool call JSON. Retrying request...";
        $error = $retry_info;
        log_info('ResponseHandler', "Detected malformed tool JSON error - will retry");
        $self->{last_failed_tool} = $failed_tool;
    }
    # Handle previous_response_id not supported (400)
    # Some models report Responses API support but don't accept previous_response_id
    elsif ($status == 400 && $error =~ /previous_response_id.*not supported/i) {
        $is_retryable_error = 1;
        $retryable = 1;
        $retry_after = 0;
        $error_type = 'unsupported_param';

        # Clear the stateful marker so it won't be sent again
        $self->clear_stateful_markers();
        # Flag that this model doesn't support previous_response_id
        $self->{_no_previous_response_id} = 1;

        $retry_info = "Model doesn't support previous_response_id. Retrying without it.";
        $error = $retry_info;
        log_info('ResponseHandler', "Cleared stateful markers - model rejects previous_response_id");
    }

    # Handle reasoning/thinking not supported (400)
    # Some models reject the reasoning parameter (e.g. Claude via Copilot Responses API)
    elsif ($status == 400 && $error =~ /(?:thinking|reasoning)\s+is\s+not\s+supported/i) {
        $is_retryable_error = 1;
        $retryable = 1;
        $retry_after = 0;
        $error_type = 'unsupported_param';

        # Flag that this model doesn't support reasoning parameters
        $self->{_no_reasoning} = 1;

        $retry_info = "Model doesn't support reasoning/thinking. Retrying without it.";
        $error = $retry_info;
        log_info('ResponseHandler', "Flagged model as not supporting reasoning - will strip from future requests");
    }

    # Handle temperature incompatible with thinking (Anthropic 400)
    # When extended thinking is enabled, Anthropic requires temperature=1 and
    # forbids top_k. This should be handled in Anthropic.pm's build_request,
    # but catch it here as a safety net so we retry with corrected params.
    elsif ($status == 400 && $error =~ /temperature.*only.*be set to 1.*thinking/i) {
        $is_retryable_error = 1;
        $retryable = 1;
        $retry_after = 0;
        $error_type = 'unsupported_param';

        $retry_info = "Temperature must be 1 when thinking is enabled. Retrying with corrected parameters.";
        $error = $retry_info;
        log_info('ResponseHandler', "Anthropic requires temperature=1 with thinking - will correct on retry");
    }

    # Handle max_tokens must be greater than thinking.budget_tokens (Anthropic 400)
    # When extended thinking is enabled, Anthropic requires max_tokens > budget_tokens.
    # The Anthropic provider should handle this in build_request, but catch it here
    # as a safety net so we can retry with thinking disabled.
    elsif ($status == 400 && $error =~ /max_tokens.*(?:must be greater|greater than).*budget_tokens/i) {
        $is_retryable_error = 1;
        $retryable = 1;
        $retry_after = 0;
        $error_type = 'param_conflict';

        # Flag that thinking params caused a conflict - retry without thinking
        $self->{_no_reasoning} = 1;

        $retry_info = "max_tokens must be greater than thinking budget_tokens. Retrying without extended thinking.";
        $error = $retry_info;
        log_info('ResponseHandler', "Anthropic max_tokens/budget_tokens conflict - disabling thinking for retry");
    }

    # Handle content filter errors (non-retryable)
    # Content was flagged by the safety system - user needs to modify their request
    elsif (($status == 400 || $status == 403) &&
           ($error =~ /content.?filter|content.?policy|safety|harmful|inappropriate/i ||
            (ref($error_obj) eq 'HASH' && $error_obj->{code} && $error_obj->{code} =~ /content.?filter|content.?policy/i))) {
        $is_retryable_error = 0;
        $retryable = 0;
        $error_type = 'content_filter';
        $error = "Your request was flagged by the content safety system. "
               . "Please modify your request to comply with the API's usage policies.";
        log_info('ResponseHandler', "Content filter triggered: $error");
    }

    # Handle generic 400 (transient backend error, content encoding issue, etc.)
    # These arrive with no recognizable error string - treat as retryable with short backoff.
    # The raw response body is logged to /tmp/clio_api_400.log for diagnosis.
    elsif ($status == 400) {
        $is_retryable_error = 1;
        $retryable = 1;
        $retry_after = 2;
        $error_type = 'bad_request';

        # Capture response body for diagnosis (body may be in raw_response_body or decoded_content)
        my $body = eval { $resp->decoded_content } // '';
        if (!$body || $body !~ /\S/) {
            # Try injected raw body (APIManager sets $resp->{content} as fallback for streaming)
            $body = $resp->{content} // '';
        }
        if ($body && $body =~ /\S/) {
            log_info('ResponseHandler', "API 400 response body: " . substr($body, 0, 500));
            if (open my $fh, '>>', '/tmp/clio_api_400.log') {
                print $fh "\n" . "=" x 80 . "\n";
                print $fh "[" . scalar(localtime) . "] API 400 Bad Request\n";
                print $fh "Error: $error\n";
                print $fh "Response body:\n$body\n";
                close $fh;
            }
        } else {
            log_info('ResponseHandler', "API 400 Bad Request (empty response body)");
        }

        $retry_info = "API 400 Bad Request - retrying after short delay...";
        # Don't overwrite $error if it was already set from JSON body extraction above
        # (e.g., OpenRouter metadata errors, Anthropic error messages)
        $error = $retry_info unless $error_obj;
    }

    # Log error details
    if ($is_retryable_error) {
        log_debug('ResponseHandler', "Retryable error ($status): $error");
    } else {
        log_debug('ResponseHandler', "$error");
        if ($is_streaming) {
            my $body = eval { $resp->decoded_content } // '';
            log_debug('ResponseHandler', "Response body: $body");
            log_debug('ResponseHandler', "Request was: " . substr($json // '', 0, 500) . "...");
        } elsif ($self->{debug}) {
            log_error('ResponseHandler', $error);
        }
    }

    # Build result via helper
    my $result = $self->_build_error_result(
        is_streaming             => $is_streaming,
        error                    => $error,
        retryable                => $retryable,
        retry_after              => $retry_after,
        error_type               => $error_type,
        detected_rate_limit_code => $detected_rate_limit_code,
        error_obj                => $error_obj,
    );
    return $result;


=head2 _parse_error_response

Parse an API error response into a normalized state hash.

Reads $resp->code, $resp->decoded_content, and (for streaming responses)
$resp->{content}. Returns the inferred status, user-facing error string,
decoded content, extracted error object, and provider-specific rate limit
code (e.g. user_weekly_rate_limited, zai_usage_limit).

This consolidates the response-body-shape variations across providers
(OpenAI / OpenRouter / Anthropic / Google / GitHub) into a single entry
point so the dispatcher can work with uniform state.

Arguments:
- $resp: HTTP::Response object
- $is_streaming: boolean, true for streaming requests

Returns:
- Hashref with: status, error, content, error_obj, detected_rate_limit_code

=cut

sub _parse_error_response {
    my ($self, $resp, $is_streaming) = @_;

    my $status = $resp->code;
    my $error_prefix = $is_streaming ? "Streaming request failed" : "Request failed";
    my $error = "$error_prefix: " . $resp->status_line;

    # Try to extract detailed error from response body
    # Providers return errors in different formats:
    #   OpenAI/OpenRouter: {"error": {"message": "...", "code": 400}}
    #   Google native:     [{"error": {"message": "...", "code": 429, "status": "RESOURCE_EXHAUSTED"}}]
    my $content = safe_decode_json($resp->decoded_content);
    # For streaming errors, decoded_content may be empty because the body was
    # captured in raw_response_body and injected as $resp->{content} by APIManager.
    if (!$content && $resp->{content}) {
        $content = safe_decode_json($resp->{content});
    }
    my $error_obj;
    if ($content) {
        if (ref($content) eq 'HASH' && $content->{error}) {
            $error_obj = $content->{error};
        } elsif (ref($content) eq 'ARRAY' && @$content && ref($content->[0]) eq 'HASH' && $content->[0]{error}) {
            $error_obj = $content->[0]{error};
        }
    }
    if ($error_obj) {
        # Handle both string errors ("Internal Server Error") and hash errors ({message => "...", code => ...})
        if (ref($error_obj) eq 'HASH') {
            $error = $error_obj->{message} // $error;
            # Extract detailed error from OpenRouter metadata.raw for better user messages
            if ($error_obj->{metadata} && ref($error_obj->{metadata}) eq 'HASH' && $error_obj->{metadata}{raw}) {
                my $raw = safe_decode_json($error_obj->{metadata}{raw});
                if ($raw) {
                    my $inner_error;
                    if (ref($raw) eq 'ARRAY' && @$raw && ref($raw->[0]) eq 'HASH' && $raw->[0]{error}) {
                        $inner_error = $raw->[0]{error};
                    } elsif (ref($raw) eq 'HASH' && $raw->{error}) {
                        $inner_error = $raw->{error};
                    }
                    if ($inner_error && ref($inner_error) eq 'HASH' && $inner_error->{message}) {
                        $error = $inner_error->{message};
                        log_debug('ResponseHandler', "Extracted inner error from provider metadata: $error");
                    }
                }
            }
            # Use embedded error code when HTTP status is uninformative (200 or 599)
            if (($status == 200 || $status >= 500) && $error_obj->{code} && $error_obj->{code} =~ /^\d+$/) {
                $status = int($error_obj->{code});
                log_debug('ResponseHandler', "Using embedded error code $status from response body");
            }
            # Detect rate limit from semantic string codes (e.g. GitHub's user_model_rate_limited)
            if ($status == 200 && $error_obj->{code} && $error_obj->{code} =~ /rate.lim/i) {
                $status = 429;
                log_debug('ResponseHandler', "Detected rate limit via code '$error_obj->{code}', treating as 429");
            }
        } else {
            # $error_obj is a plain string error from the provider
            $error = $error_obj;
        }
    }

    my $detected_rate_limit_code = (ref($error_obj) eq 'HASH' && $error_obj->{code}) ? $error_obj->{code} : '';

    return {
        status                    => $status,
        error                     => $error,
        content                   => $content,
        error_obj                 => $error_obj,
        detected_rate_limit_code  => $detected_rate_limit_code,
    };
}
}

=head2 _build_error_result

Construct the result hash for a classified API error response.

Tries to keep the result shape stable across retryable, non-retryable,
and streaming paths. Mutates $self->{last_failed_tool} (consumes the slot).

Arguments:
- is_streaming: boolean
- error: user-facing error string
- retryable: boolean
- retry_after: seconds to wait before retry, if known
- error_type: classification string (rate_limit, quota_exceeded, etc.)
- detected_rate_limit_code: provider-specific code if present
- error_obj: full error object from response body

Returns:
- Hashref suitable for the AI consumer

=cut

sub _build_error_result {
    my ($self, %state) = @_;

    my $is_streaming             = $state{is_streaming};
    my $error                    = $state{error};
    my $retryable                = $state{retryable};
    my $retry_after              = $state{retry_after};
    my $error_type               = $state{error_type};
    my $detected_rate_limit_code = $state{detected_rate_limit_code};
    my $error_obj                = $state{error_obj};

    my $result;
    if ($is_streaming) {
        $result = { success => 0, error => $error };
    } else {
        $result = { success => 0, error => $error, _error => $error };
    }

    if ($retryable) {
        $result->{retryable} = 1;
        $result->{retry_after} = $retry_after if $retry_after;
        $result->{error_type} = $error_type if $error_type;
        # Pass rate_limit_code for specific rate limit type messaging (e.g., user_weekly_rate_limited)
        $result->{rate_limit_code} = $detected_rate_limit_code if $detected_rate_limit_code;
        # Pass error_obj for richer error messaging (e.g. GitHub rate limit codes)
        $result->{error_obj} = $error_obj if $error_obj;
        if ($self->{last_failed_tool}) {
            $result->{failed_tool} = $self->{last_failed_tool};
            delete $self->{last_failed_tool};
        }
    } elsif ($error_type) {
        # Include error_type even for non-retryable errors (for classification)
        $result->{error_type} = $error_type;
        $result->{retryable} = 0;  # Explicitly mark as non-retryable
        log_debug('ResponseHandler', "Non-retryable error: retryable=0, error_type=$error_type");
    }

    # Always pass rate_limit_code if detected (for routing decisions)
    $result->{rate_limit_code} = $detected_rate_limit_code if $detected_rate_limit_code;

    # Debug: log the final error we're returning
    log_debug('ResponseHandler', "Final error being returned: $error");

    return $result;
}

=head2 process_rate_limit_headers

Parse rate limit headers from API response and apply adaptive throttling.

Supports:
- Standard X-RateLimit-* headers (OpenAI, Anthropic)
- GitHub Copilot quota snapshot headers
- Retry-After headers (from 429 responses)

Arguments:
- $headers: HTTP::Headers object

Returns:
- Hashref with rate_limit_info and dynamic_min_delay, or undef if no rate limit headers

=cut

sub process_rate_limit_headers {
    my ($self, $headers) = @_;

    return unless $headers;

    my %rate_limit = ();
    my $copilot_quota_header = undef;

    my $scan_cb = sub {
        my ($name, $value) = @_;
        my $lc_name = lc($name);

        if ($lc_name eq 'x-ratelimit-limit-requests') {
            $rate_limit{limit_requests} = $value;
        }
        elsif ($lc_name eq 'x-ratelimit-remaining-requests') {
            $rate_limit{remaining_requests} = $value;
        }
        elsif ($lc_name eq 'x-ratelimit-reset-requests') {
            $rate_limit{reset_requests} = $value;
        }
        elsif ($lc_name eq 'x-ratelimit-limit-tokens') {
            $rate_limit{limit_tokens} = $value;
        }
        elsif ($lc_name eq 'x-ratelimit-remaining-tokens') {
            $rate_limit{remaining_tokens} = $value;
        }
        elsif ($lc_name eq 'x-ratelimit-reset-tokens') {
            $rate_limit{reset_tokens} = $value;
        }
        elsif ($lc_name eq 'retry-after') {
            $rate_limit{retry_after} = $value;
        }
        elsif ($lc_name eq 'x-quota-snapshot-premium_interactions' ||
               $lc_name eq 'x-quota-snapshot-premium_models') {
            $copilot_quota_header = $value;
        }
        elsif ($lc_name eq 'x-github-total-quota-used') {
            $rate_limit{quota_used} = $value;
            $rate_limit{quota_timestamp} = time();
        }
    };

    if (ref($headers) eq 'HASH') {
        $scan_cb->($_, $headers->{$_}) for keys %$headers;
    } else {
        $headers->scan($scan_cb);
    }

    # Parse GitHub Copilot quota header if no standard headers
    if ($copilot_quota_header && !$rate_limit{limit_requests}) {
        for my $pair (split /&/, $copilot_quota_header) {
            my ($key, $value) = split /=/, $pair, 2;
            next unless defined $value;
            $value =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;

            if ($key eq 'ent') {
                $rate_limit{limit_requests} = $value unless $value == -1;
            }
            elsif ($key eq 'rem') {
                if (defined $rate_limit{limit_requests} && $rate_limit{limit_requests} > 0) {
                    $rate_limit{remaining_requests} = int($rate_limit{limit_requests} * $value / 100);
                }
                $rate_limit{_copilot_percent_remaining} = $value;
            }
            elsif ($key eq 'rst') {
                # Store quota reset SEPARATELY - don't conflate with rate limit reset
                $rate_limit{quota_reset} = $value;
            }
        }
    }

    return unless keys %rate_limit;

    # Store quota_used in session for UI display (mirrors Broker.pm behavior)
    if (defined $rate_limit{quota_used} && $self->{session}) {
        my $rl_provider = $self->_get_current_provider();
        if ($self->{session}->can('state')) {
            my $state = $self->{session}->state();
            $state->{rate_limits} //= {};
            $state->{rate_limits}{$rl_provider} //= {};
            $state->{rate_limits}{$rl_provider}{rate_limit_quota_used} = $rate_limit{quota_used};
            $state->{rate_limits}{$rl_provider}{rate_limit_quota_timestamp} = $rate_limit{quota_timestamp};
        } else {
            $self->{session}{rate_limit_quota_used} = $rate_limit{quota_used};
            $self->{session}{rate_limit_quota_timestamp} = $rate_limit{quota_timestamp};
        }
        log_debug('ResponseHandler', "Quota used: $rate_limit{quota_used}%");
    }

    if (should_log('DEBUG')) {
        log_debug('ResponseHandler', "Rate limit headers received:");
        for my $key (sort keys %rate_limit) {
            log_debug('ResponseHandler', "$key: $rate_limit{$key}");
        }
    }

    # Calculate dynamic delay based on remaining quota
    my $percent_remaining;
    if (defined $rate_limit{_copilot_percent_remaining}) {
        $percent_remaining = $rate_limit{_copilot_percent_remaining};
    }
    elsif (defined $rate_limit{limit_requests} && defined $rate_limit{remaining_requests}) {
        my $limit = $rate_limit{limit_requests};
        my $remaining = $rate_limit{remaining_requests};
        if ($limit > 0) {
            $percent_remaining = ($remaining / $limit) * 100;
        }
    }
    # Also consider x-github-total-quota-used header (percentage already used)
    elsif (defined $rate_limit{quota_used}) {
       $percent_remaining = 100 - $rate_limit{quota_used};
   }

    # Token quota throttling (Azure APIM proxies rate-limit by uncached input tokens)
    if (defined $rate_limit{limit_tokens} && defined $rate_limit{remaining_tokens}) {
        my $limit = $rate_limit{limit_tokens};
        my $remaining = $rate_limit{remaining_tokens};
        if ($limit > 0) {
            my $token_pct = ($remaining / $limit) * 100;
            if (!defined $percent_remaining || $token_pct < $percent_remaining) {
                $percent_remaining = $token_pct;
                log_debug('ResponseHandler', sprintf("Token quota: %.1f%% remaining (%d/%d)", $token_pct, $remaining, $limit));
            }
        }
    }

    my $dynamic_min_delay = $self->{_dynamic_min_delay} // 1.0;
    
    if (defined $percent_remaining) {
        my $new_delay;
        if ($percent_remaining > 50) {
            $new_delay = 1.0;
        } elsif ($percent_remaining > 20) {
            $new_delay = 1.5;
        } elsif ($percent_remaining > 10) {
            $new_delay = 2.0;
        } else {
            $new_delay = 2.5;
        }

        my $old_delay = $dynamic_min_delay;
        $dynamic_min_delay = $new_delay;

        if ($new_delay != $old_delay) {
            my $limit = $rate_limit{limit_requests} || 'N/A';
            my $remaining = $rate_limit{remaining_requests} || 'N/A';
            log_info('ResponseHandler', sprintf(
                "Quota: %.1f%% remaining. Adjusting delay: %.1fs -> %.1fs",
                $percent_remaining, $old_delay, $new_delay
            ));
        }
    }

    # Calculate time until reset
    if ($rate_limit{reset_requests}) {
        my $reset_time = $rate_limit{reset_requests};
        my $now = time();
        if ($reset_time > $now) {
            $rate_limit{seconds_until_reset} = $reset_time - $now;
        }
    }

    # Return rate limit info and new delay (stateless - caller decides what to do with it)
    return {
        rate_limit_info => \%rate_limit,
        dynamic_min_delay => $dynamic_min_delay,
    };
}

=head2 process_quota_headers

Process GitHub Copilot quota tracking headers.

Extracts AI Credit usage, calculates deltas, and stores quota
information in the session for UI display and billing tracking.

Arguments:
- $headers: HTTP::Headers object
- $response_id: API response ID for logging

=cut

sub process_quota_headers {
    my ($self, $headers, $response_id) = @_;

    return unless $self->{session};

    my $premium_models;
   my $premium_interactions;
   my $chat_quota;

    my $quota_scan = sub {
        my ($name, $value) = @_;
        if ($name =~ /^x-quota-snapshot-premium_models$/i) {
            $premium_models = $value;
        }
        elsif ($name =~ /^x-quota-snapshot-premium_interactions$/i) {
            $premium_interactions = $value;
        }
        elsif ($name =~ /^x-quota-snapshot-chat$/i) {
            $chat_quota = $value;
        }
    };

    if (ref($headers) eq 'HASH') {
        $quota_scan->($_, $headers->{$_}) for keys %$headers;
    } else {
        $headers->scan($quota_scan);
    }

    my $quota_header = $premium_models || $premium_interactions || $chat_quota;
    my $quota_source;
    if ($premium_models) {
        $quota_source = 'x-quota-snapshot-premium_models';
    } elsif ($premium_interactions) {
        $quota_source = 'x-quota-snapshot-premium_interactions';
    } elsif ($chat_quota) {
        $quota_source = 'x-quota-snapshot-chat';
    }

    unless ($quota_header) {
        log_debug('ResponseHandler', "No quota header in response");
        return;
    }

    log_debug('ResponseHandler', "Using quota from: $quota_source");

    my %quota;
    for my $pair (split /&/, $quota_header) {
        my ($key, $value) = split /=/, $pair, 2;
        $quota{$key} = $value if defined $value;
    }

    my $entitlement = int($quota{ent} || 0);
    my $overage_used = $quota{ov} || 0.0;
    my $overage_permitted = ($quota{ovPerm} || '') eq 'true';
    my $percent_remaining = $quota{rem} || 0.0;
    my $reset_date = $quota{rst} || 'unknown';

    my $used = int($entitlement * (1.0 - $percent_remaining / 100.0));
    $used = 0 if $used < 0;
    my $available = $entitlement - $used;

    # Store quota info in session
    $self->{session}{quota} = {
        entitlement => $entitlement,
        used => $used,
        available => $available,
        percent_remaining => $percent_remaining,
        overage_used => $overage_used,
        overage_permitted => $overage_permitted,
        reset_date => $reset_date,
        last_updated => time(),
    };

    # Calculate delta
    my $delta = undef;
    my $state = $self->{session};

    if ($state && defined $state->{_last_premium_used}) {
        $delta = $used - $state->{_last_premium_used};
        log_debug('ResponseHandler', "Calculated delta: $delta");

        if ($delta > 0) {
            my $percent_used = 100.0 - $percent_remaining;
            my $charge_msg = sprintf("+%d AI Credit%s charged (%d/%s - %.1f%% used)",
                $delta,
                $delta > 1 ? "s" : "",
                $used,
                $entitlement == -1 ? "unlimited" : $entitlement,
                $percent_used);
            $state->{_premium_charge_message} = $charge_msg;
            log_info('ResponseHandler', "$charge_msg");
        } elsif ($delta < 0) {
            log_warning('ResponseHandler', "Quota decreased by $delta (unexpected)");
        } else {
            log_info('ResponseHandler', "+0 AI Credits (session continuity working)");
        }
    } else {
        log_info('ResponseHandler', "Initial request - establishing baseline");
    }

    return unless $state;
    $state->{_last_premium_used} = $used;
    $state->{_last_quota_delta} = $delta;

    if (defined $delta && $delta > 0) {
        if (exists $state->{billing}{total_premium_requests}) {
            # Check if we need to reconcile the initial upfront charge
            if (delete $state->{billing}{_initial_premium_charged}) {
                # First non-zero delta: the upfront charge already covers this,
                # so skip this delta to avoid double-counting.
                # After this, all future deltas are tracked normally.
                log_info('ResponseHandler', "Reconciled initial credit charge with first quota delta ($delta)");
            } else {
                # Normal operation: increment by actual charge from quota headers
                $state->{billing}{total_premium_requests} += $delta;
                log_info('ResponseHandler', "+$delta AI Credit(s) charged from quota headers");
            }
        }
    }

    # Persist session
    if ($self->{session} && ref($self->{session}) && blessed($self->{session}) && $self->{session}->can('save')) {
        $self->{session}->save();
    }

    my $req_id_short = $response_id ? substr($response_id, 0, 8) : 'unknown';
    log_info('ResponseHandler', "GitHub Copilot AI Credits [req:$req_id_short]:");
    log_info('ResponseHandler', "- Entitlement: " . ($entitlement == -1 ? "Unlimited" : $entitlement));
    log_info('ResponseHandler', "- Used: $used");
    log_info('ResponseHandler', "- Remaining: " . sprintf("%.1f%%", $percent_remaining) . " ($available available)");
    log_info('ResponseHandler', "- Overage: " . sprintf("%.1f", $overage_used) . " (permitted: " . ($overage_permitted ? 'yes' : 'no') . ")");
    log_info('ResponseHandler', "- Reset Date: $reset_date");

    if ($available < 10 && $available > 0) {
        log_warning('ResponseHandler', "Only $available AI Credits remaining!");
    } elsif ($available <= 0 && !$overage_permitted) {
        log_debug('ResponseHandler', "AI Credits exhausted! Requests may fail.");
    }
}

=head2 release_broker_slot

Release the API slot back to the broker after request completes.

Arguments:
- $resp: HTTP::Response object (optional)
- $status: HTTP status code (optional, defaults to 200)

=cut

sub release_broker_slot {
    my ($self, $resp, $status) = @_;

    return unless $self->{broker_client};
    return unless $self->{_current_broker_request_id};

    $status ||= 200;

    my %headers;
    if ($resp && $resp->can('headers')) {
        my $h = $resp->headers;
        $h->scan(sub {
            my ($name, $value) = @_;
            my $lc_name = lc($name);
            if ($lc_name =~ /ratelimit|retry-after|quota/) {
                $headers{$lc_name} = $value;
            }
        });
    }

    my $request_id = $self->{_current_broker_request_id};
   eval {
       local $SIG{PIPE} = 'IGNORE';
       $self->{broker_client}->release_api_slot(
           request_id => $request_id,
           status     => $status,
           headers    => \%headers,
       );
        log_debug('ResponseHandler', "Released broker slot (request_id=$request_id, status=$status)");
    };
    if ($@) {
        log_warning('ResponseHandler', "Failed to release broker slot: $@");
    }

    $self->{_current_broker_request_id} = undef;
}

=head2 store_stateful_marker

Store stateful_marker for session continuation and billing.

Stateful marker for session continuation, preventing duplicate credit charges.

Arguments:
- $marker: The stateful_marker string from API response
- $model: Model ID this marker is associated with
- $iteration: Tool-calling iteration number (only stores on iteration 1)

=cut

sub store_stateful_marker {
    my ($self, $marker, $model, $iteration) = @_;

    return unless $self->{session};
    return unless defined $marker && $marker ne '';

    $iteration ||= 1;
    if ($iteration > 1) {
        log_debug('ResponseHandler', "Skipping stateful_marker storage (iteration $iteration)");
        return;
    }

    $self->{session}{_stateful_markers} ||= [];

    unshift @{$self->{session}{_stateful_markers}}, {
        model => $model,
        marker => $marker,
        timestamp => time()
    };

    splice(@{$self->{session}{_stateful_markers}}, 10);

    log_info('ResponseHandler', "Stored stateful_marker for model '$model': " . substr($marker, 0, 30) .
        "... (total markers: " . scalar(@{$self->{session}{_stateful_markers}}) . ")");

    if (ref($self->{session}) && blessed($self->{session}) && $self->{session}->can('save')) {
        $self->{session}->save();
        log_info('ResponseHandler', "Session saved with stateful_marker");
    } else {
        log_debug('ResponseHandler', "Session object cannot save! stateful_marker will be lost!");
    }
}

=head2 get_stateful_marker_for_model

Retrieve the most recent stateful_marker for a given model.

Arguments:
- $model: The model ID to search for

Returns:
- Stateful marker string, or undef if none found

=cut

sub get_stateful_marker_for_model {
    my ($self, $model) = @_;

    unless ($self->{session}) {
        log_debug('ResponseHandler', "Cannot get stateful_marker - no session object!");
        return undef;
    }

    unless ($self->{session}{_stateful_markers} && @{$self->{session}{_stateful_markers}}) {
        log_debug('ResponseHandler', "No stateful_markers for model '$model' (will use response_id fallback)");
        return undef;
    }

    my $count = scalar(@{$self->{session}{_stateful_markers}});
    log_debug('ResponseHandler', "Searching for stateful_marker (model='$model', total markers=$count)");

    for my $marker_obj (@{$self->{session}{_stateful_markers}}) {
        if ($marker_obj->{model} eq $model) {
            log_info('ResponseHandler', "Found stateful_marker for model '$model': " . substr($marker_obj->{marker}, 0, 30) . "...");
            return $marker_obj->{marker};
        }
    }

    log_debug('ResponseHandler', "No stateful_marker for model '$model' (searched $count markers)");

    if (should_log('DEBUG') && $count > 0) {
        my @models = map { $_->{model} } @{$self->{session}{_stateful_markers}};
        log_debug('ResponseHandler', "Available models in markers: " . join(', ', @models));
    }

    return undef;
}

=head2 clear_stateful_markers

Clear all stored stateful markers. Called when a model rejects
previous_response_id to prevent re-sending on retry.

=cut

sub clear_stateful_markers {
    my ($self) = @_;
    if ($self->{session} && $self->{session}{_stateful_markers}) {
        $self->{session}{_stateful_markers} = [];
        log_debug('ResponseHandler', "Cleared all stateful markers");
    }
    # Also clear session-level fallback
    if ($self->{session}) {
        delete $self->{session}{lastGitHubCopilotResponseId};
    }
}

1;

__END__

=head1 AUTHOR

Andrew Wyatt (Fewtarius)

=head1 LICENSE

GPL-3.0-only

=cut

1;
