package CLIO::Core::API::ResponseHandler;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use CLIO::Core::Logger qw(should_log log_error log_warning log_info log_debug);
use CLIO::Util::JSON qw(decode_json);
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
    my ($self, $resp, $json, $is_streaming, %opts) = @_;

    my $attempt_token_recovery = $opts{attempt_token_recovery};

    my $status = $resp->code;
    my $error_prefix = $is_streaming ? "Streaming request failed" : "Request failed";
    my $error = "$error_prefix: " . $resp->status_line;

    # Try to extract detailed error from response body
    my $content = eval { decode_json($resp->decoded_content) };
    if ($content && $content->{error}) {
        $error = $content->{error}{message} || $content->{error} || $error;
    }

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

        if ($error =~ /retry in ([\d.]+)\s*s(?:econds?)?/i) {
            $retry_after = int($1) + 1;
        } elsif (my $header_value = $resp->header('Retry-After')) {
            $retry_after = $header_value;
        }

        $self->{rate_limit_until} = time() + $retry_after;

        $retry_info = sprintf("API rate limit exceeded. Retrying in %d seconds.", $retry_after);
        $error = $retry_info;
    }
    # Handle authentication failures (401, 403)
    elsif ($status == 401 || $status == 403) {
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
    # Handle transient server errors (502, 503)
    elsif ($status == 502 || $status == 503) {
        $is_retryable_error = 1;
        $retryable = 1;
        $retry_after = 2;
        $error_type = 'server_error';
        $retry_info = "Server temporarily unavailable ($status). Retrying...";
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

    # Log error details
    if ($is_retryable_error) {
        log_debug('ResponseHandler', "Retryable error ($status): $error");
        if ($is_streaming && should_log('DEBUG')) {
            log_debug('ResponseHandler', "Response body: " . $resp->decoded_content);
            log_debug('ResponseHandler', "Request was: " . substr($json, 0, 500) . "...");
        }
    } else {
        log_debug('ResponseHandler', "$error");
        if ($is_streaming) {
            log_debug('ResponseHandler', "Response body: " . $resp->decoded_content);
            log_debug('ResponseHandler', "Request was: " . substr($json, 0, 500) . "...");
        } elsif ($self->{debug}) {
            warn "[ERROR] $error\n";
        }
    }

    # Build result
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
        if ($self->{last_failed_tool}) {
            $result->{failed_tool} = $self->{last_failed_tool};
            delete $self->{last_failed_tool};
        }
    } elsif ($error_type) {
        # Include error_type even for non-retryable errors (for classification)
        $result->{error_type} = $error_type;
    }

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

=cut

sub process_rate_limit_headers {
    my ($self, $headers) = @_;

    return unless $headers;

    my %rate_limit = ();
    my $copilot_quota_header = undef;

    $headers->scan(sub {
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
    });

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
                $rate_limit{reset_requests} = $value;
            }
        }
    }

    return unless keys %rate_limit;

    $self->{_rate_limit_info} = \%rate_limit;

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

        my $old_delay = $self->{_dynamic_min_delay} // 1.0;
        $self->{_dynamic_min_delay} = $new_delay;

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

        if ($reset_time =~ /^\d+$/) {
            # Already Unix timestamp
        }
        elsif ($reset_time =~ /(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})/) {
            eval {
                require Time::Local;
                $reset_time = Time::Local::timegm($6, $5, $4, $3, $2-1, $1);
            };
        }

        if ($reset_time =~ /^\d+$/ && $reset_time > $now) {
            my $seconds_until_reset = $reset_time - $now;
            $self->{_rate_limit_reset_in} = $seconds_until_reset;
            log_debug('ResponseHandler', "Rate limit resets in ${seconds_until_reset}s");
        }
    }

    # Handle explicit Retry-After header
    if ($rate_limit{retry_after}) {
        my $retry_after = $rate_limit{retry_after};
        if ($retry_after =~ /^\d+$/) {
            $self->{rate_limit_until} = time() + $retry_after;
            log_info('ResponseHandler', "Retry-After header: waiting ${retry_after}s before next request");
        }
    }
}

=head2 process_quota_headers

Process GitHub Copilot quota tracking headers.

Extracts premium request usage, calculates deltas, and stores quota
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

    $headers->scan(sub {
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
    });

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
            my $charge_msg = sprintf("+%d premium request%s charged (%d/%s - %.1f%% used)",
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
            log_info('ResponseHandler', "+0 premium requests (session continuity working)");
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
                log_info('ResponseHandler', "Reconciled initial premium charge with first quota delta ($delta)");
            } else {
                # Normal operation: increment by actual charge from quota headers
                $state->{billing}{total_premium_requests} += $delta;
                log_info('ResponseHandler', "+$delta premium request(s) charged from quota headers");
            }
        }
    }

    # Persist session
    if ($self->{session} && ref($self->{session}) && blessed($self->{session}) && $self->{session}->can('save')) {
        $self->{session}->save();
    }

    my $req_id_short = $response_id ? substr($response_id, 0, 8) : 'unknown';
    log_info('ResponseHandler', "GitHub Copilot Premium Quota [req:$req_id_short]:");
    log_info('ResponseHandler', "- Entitlement: " . ($entitlement == -1 ? "Unlimited" : $entitlement));
    log_info('ResponseHandler', "- Used: $used");
    log_info('ResponseHandler', "- Remaining: " . sprintf("%.1f%%", $percent_remaining) . " ($available available)");
    log_info('ResponseHandler', "- Overage: " . sprintf("%.1f", $overage_used) . " (permitted: " . ($overage_permitted ? 'yes' : 'no') . ")");
    log_info('ResponseHandler', "- Reset Date: $reset_date");

    if ($available < 10 && $available > 0) {
        log_warning('ResponseHandler', "Only $available premium requests remaining!");
    } elsif ($available <= 0 && !$overage_permitted) {
        log_debug('ResponseHandler', "Premium quota exhausted! Requests may fail.");
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

    eval {
        $self->{broker_client}->release_api_slot(
            $self->{_current_broker_request_id},
            $status,
            \%headers,
        );
        log_debug('ResponseHandler', "Released broker slot (request_id=$self->{_current_broker_request_id}, status=$status)");
    };
    if ($@) {
        log_warning('ResponseHandler', "Failed to release broker slot: $@");
    }

    $self->{_current_broker_request_id} = undef;
}

=head2 store_stateful_marker

Store stateful_marker for session continuation and billing optimization.

The stateful_marker from GitHub Copilot API responses enables session
continuation, preventing multiple premium charges for the same conversation.

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

1;

__END__

=head1 AUTHOR

Andrew Wyatt (Fewtarius)

=head1 LICENSE

GPL-3.0-only

=cut
