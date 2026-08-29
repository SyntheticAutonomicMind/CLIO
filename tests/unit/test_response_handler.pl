#!/usr/bin/env perl
# Test CLIO::Core::API::ResponseHandler - response processing and rate limiting
#
# Tests error classification, rate limit header parsing, quota tracking,
# broker slot management, and stateful marker storage.

use strict;
use warnings;
use lib './lib';
use Test::More;

use CLIO::Core::API::ResponseHandler;

# =============================================================================
# Constructor tests
# =============================================================================

subtest 'constructor - defaults' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    ok(defined $handler, 'Handler created');
    is($handler->{debug}, 0, 'Debug defaults to 0');
    is($handler->{_dynamic_min_delay}, 1.0, 'Default delay is 1.0s');
    ok(!defined $handler->{rate_limit_until}, 'No rate limit initially');
};

subtest 'constructor - with options' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new(
        debug => 1,
        session => { _stateful_markers => [] },
    );
    is($handler->{debug}, 1, 'Debug set');
    ok(defined $handler->{session}, 'Session set');
};

# =============================================================================
# set_session / set_broker_request_id tests
# =============================================================================

subtest 'set_session' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    $handler->set_session({ id => 'test' });
    is($handler->{session}{id}, 'test', 'Session updated');
};

subtest 'set_broker_request_id' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    $handler->set_broker_request_id('req-123');
    is($handler->{_current_broker_request_id}, 'req-123', 'Broker request ID set');
};

# =============================================================================
# handle_error_response tests (using mock HTTP::Response)
# =============================================================================

# Simple mock for HTTP::Response
{
    package MockResponse;
    sub new {
        my ($class, %opts) = @_;
        return bless {
            code => $opts{code} // 200,
            status_line => $opts{status_line} // "$opts{code} Error",
            content => defined $opts{content} ? $opts{content} : '{}',
            headers => $opts{headers} || MockHeaders->new(),
            message => $opts{message} // '',
        }, $class;
    }
    sub code { $_[0]->{code} }
    sub status_line { $_[0]->{status_line} }
    sub decoded_content { $_[0]->{content} }
    sub is_success { $_[0]->{code} >= 200 && $_[0]->{code} < 300 }
    sub header { return undef }
    sub headers { $_[0]->{headers} }
    sub message { $_[0]->{message} }

    package MockHeaders;
    sub new { bless {}, $_[0] }
    sub scan { }
}

subtest 'handle_error_response - 429 rate limit' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 429,
        status_line => '429 Too Many Requests',
        content => '{"error":{"message":"Please retry in 30s"}}',
    );

    my $result = $handler->handle_error_response($resp, '{}', 0);
    ok($result->{retryable}, 'Rate limit is retryable');
    is($result->{error_type}, 'rate_limit', 'Error type is rate_limit');
    ok($result->{retry_after} > 0, 'Has retry_after');
};

subtest 'handle_error_response - 429 with no headers/body hint uses DEFAULT_RATE_LIMIT_RETRY_AFTER' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 429,
        status_line => '429 Too Many Requests',
        content => '{"error":{"message":"rate limited"}}',
    );
    my $result = $handler->handle_error_response($resp, '{}', 0);
    is($result->{retryable}, 1, 'Still retryable');
    is($result->{error_type}, 'rate_limit', 'Error type is rate_limit');
    is($result->{retry_after}, 5, 'Blind default is 5s (was 60s before 2026-08-29)');
};

subtest 'handle_error_response - 502 server error' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 502,
        status_line => '502 Bad Gateway',
    );

    my $result = $handler->handle_error_response($resp, '{}', 1);
    ok($result->{retryable}, 'Server error is retryable');
    is($result->{error_type}, 'server_error', 'Error type is server_error');
    is($result->{retry_after}, 2, 'Retry after 2s for server error');
};

subtest 'handle_error_response - 401 with recovery callback' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 401,
        status_line => '401 Unauthorized',
    );

    # Test with successful recovery
    my $result = $handler->handle_error_response($resp, '{}', 0,
        attempt_token_recovery => sub { return 1; });
    ok($result->{retryable}, 'Auth error with recovery is retryable');
    is($result->{error_type}, 'auth_recovered', 'Error type is auth_recovered');
};

subtest 'handle_error_response - 401 without recovery' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 401,
        status_line => '401 Unauthorized',
    );

    my $result = $handler->handle_error_response($resp, '{}', 0,
        attempt_token_recovery => sub { return 0; });
    ok(!$result->{retryable}, 'Auth error without recovery is not retryable');
    is($result->{error_type}, 'auth_failed', 'Error type is auth_failed');
};

subtest 'handle_error_response - 400 token limit' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 400,
        status_line => '400 Bad Request',
        content => '{"error":{"message":"model_max_prompt_tokens_exceeded"}}',
    );

    my $result = $handler->handle_error_response($resp, '{}', 0);
    ok($result->{retryable}, 'Token limit is retryable');
    is($result->{error_type}, 'token_limit_exceeded', 'Error type is token_limit_exceeded');
};

subtest 'handle_error_response - generic 500' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 500,
        status_line => '500 Internal Server Error',
    );

    my $result = $handler->handle_error_response($resp, '{}', 0);
    ok($result->{retryable}, 'Generic 500 is retryable (transient server error)');
};

# =============================================================================
# Stateful marker tests
# =============================================================================

subtest 'store_stateful_marker - basic' => sub {
    my $session = {};
    my $handler = CLIO::Core::API::ResponseHandler->new(session => $session);

    $handler->store_stateful_marker('marker_abc123', 'gpt-4', 1);
    ok($session->{_stateful_markers}, 'Markers array created');
    is(scalar(@{$session->{_stateful_markers}}), 1, 'One marker stored');
    is($session->{_stateful_markers}[0]{marker}, 'marker_abc123', 'Correct marker value');
    is($session->{_stateful_markers}[0]{model}, 'gpt-4', 'Correct model');
};

subtest 'store_stateful_marker - skips iteration > 1' => sub {
    my $session = {};
    my $handler = CLIO::Core::API::ResponseHandler->new(session => $session);

    $handler->store_stateful_marker('marker_1', 'gpt-4', 1);
    $handler->store_stateful_marker('marker_2', 'gpt-4', 2);
    is(scalar(@{$session->{_stateful_markers}}), 1, 'Only iteration 1 stored');
};

subtest 'store_stateful_marker - limit 10' => sub {
    my $session = {};
    my $handler = CLIO::Core::API::ResponseHandler->new(session => $session);

    for my $i (1..15) {
        $handler->store_stateful_marker("marker_$i", "model_$i", 1);
    }
    is(scalar(@{$session->{_stateful_markers}}), 10, 'Maximum 10 markers kept');
};

subtest 'get_stateful_marker_for_model - found' => sub {
    my $session = {
        _stateful_markers => [
            { model => 'gpt-4', marker => 'found_marker', timestamp => time() },
        ],
    };
    my $handler = CLIO::Core::API::ResponseHandler->new(session => $session);

    my $marker = $handler->get_stateful_marker_for_model('gpt-4');
    is($marker, 'found_marker', 'Correct marker returned');
};

subtest 'get_stateful_marker_for_model - not found' => sub {
    my $session = {
        _stateful_markers => [
            { model => 'gpt-4', marker => 'some_marker', timestamp => time() },
        ],
    };
    my $handler = CLIO::Core::API::ResponseHandler->new(session => $session);

    my $marker = $handler->get_stateful_marker_for_model('claude-3');
    ok(!defined $marker, 'undef for non-matching model');
};

subtest 'get_stateful_marker_for_model - no session' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $marker = $handler->get_stateful_marker_for_model('gpt-4');
    ok(!defined $marker, 'undef without session');
};

# =============================================================================
# release_broker_slot tests
# =============================================================================

subtest 'release_broker_slot - no broker client' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    # Should not die
    $handler->release_broker_slot(undef, 200);
    ok(1, 'No crash without broker client');
};

subtest 'release_broker_slot - no request id' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new(
        broker_client => bless({}, 'FakeBroker'),
    );
    # Should not die (no current request id)
    $handler->release_broker_slot(undef, 200);
    ok(1, 'No crash without request id');
};

# =============================================================================
# Error parsing improvements tests
# =============================================================================

subtest 'handle_error_response - Google array-wrapped error' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 599,
        status_line => '599 Internal Exception',
        content => '[{"error":{"code":429,"message":"You exceeded your current quota, please retry in 35.228042346s.","status":"RESOURCE_EXHAUSTED"}}]',
    );
    my $result = $handler->handle_error_response($resp, '{}', 1);
    is($result->{retryable}, 1, 'Rate limit is retryable (embedded 429)');
    is($result->{error_type}, 'rate_limit', 'Error type is rate_limit');
    ok($result->{retry_after} && $result->{retry_after} > 0, 'Has retry_after value');
};

subtest 'handle_error_response - OpenRouter provider error with metadata.raw' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 599,
        status_line => '599 Internal Exception',
        content => '{"error":{"message":"Provider returned error","code":400,"metadata":{"raw":"[{\"error\":{\"code\":400,\"message\":\"thinking is not supported by this model\",\"status\":\"INVALID_ARGUMENT\"}}]"}}}',
    );
    my $result = $handler->handle_error_response($resp, '{}', 1);
    is($result->{retryable}, 1, 'Reasoning not supported is retryable');
    is($result->{error_type}, 'unsupported_param', 'Error type is unsupported_param');
    is($handler->{_no_reasoning}, 1, 'Model flagged as not supporting reasoning');
};

subtest 'handle_error_response - embedded 429 overrides HTTP 200' => sub {
   my $handler = CLIO::Core::API::ResponseHandler->new();
   my $resp = MockResponse->new(
       code => 200,
       status_line => '200 OK',
       content => '{"error":{"message":"Rate limit exceeded","code":429}}',
   );
   my $result = $handler->handle_error_response($resp, '{}', 0);
   is($result->{retryable}, 1, 'Embedded 429 treated as rate limit');
   like($result->{error}, qr/rate limit/i, 'Error message from embedded error');
};

subtest 'handle_error_response - GitHub user_model_rate_limited (200 with string code)' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 200,
        status_line => '200 OK',
        content => '{"error":{"message":"You have exhausted this model rate limit","code":"user_model_rate_limited"}}',
    );
    my $result = $handler->handle_error_response($resp, '{}', 1);
    is($result->{retryable}, 1, 'String rate limit code treated as retryable');
    is($result->{error_type}, 'rate_limit', 'Error type is rate_limit');
    ok($result->{retry_after} && $result->{retry_after} > 0, 'Has retry_after value');
    like($result->{error}, qr/rate limit/i, 'Error message mentions rate limit');
};

subtest 'handle_error_response - 599 connection error (curl failure)' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 599,
        status_line => '599 Connection reset by server',
        message => 'Connection reset by server',
        content => '',
    );
    my $result = $handler->handle_error_response($resp, '{}', 1);
    is($result->{retryable}, 1, '599 is retryable');
    is($result->{error_type}, 'connection_error', 'Error type is connection_error');
    ok($result->{retry_after} >= 3, 'Has retry_after >= 3');
    like($result->{error}, qr/Connection/, 'Error mentions connection');
};

subtest 'handle_error_response - status 0 (bogus HTTP/2 status)' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 0,
        status_line => '0 ',
        message => '',
        content => '',
    );
    my $result = $handler->handle_error_response($resp, '{}', 1);
    is($result->{retryable}, 1, 'Status 0 is retryable');
    is($result->{error_type}, 'connection_error', 'Error type is connection_error');
};

# =============================================================================
# 401/403 handling tests
# =============================================================================

subtest 'handle_error_response - 403 subscription required (permanent failure)' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 403,
        status_line => '403 Forbidden',
        content => '{"error":{"message":"this model requires a subscription, upgrade for access: https://ollama.com/upgrade","code":"subscription_required"}}',
    );

    # No recovery callback - should return immediately with the subscription error
    my $result = $handler->handle_error_response($resp, '{}', 0);
    is($result->{retryable}, 0, 'Subscription 403 is NOT retryable');
    is($result->{error_type}, 'auth_failed', 'Error type is auth_failed');
    like($result->{error}, qr/subscription|upgrade/i, 'Error contains subscription message');
};

subtest 'handle_error_response - 403 plain string error (ollama style)' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    # Simulate Ollama's plain string error - error_obj is just a string, not a hash
    my $resp = MockResponse->new(
        code => 403,
        status_line => '403 Forbidden',
        content => '{"error":"this model requires a subscription, upgrade for access: https://ollama.com/upgrade"}',
    );

    my $result = $handler->handle_error_response($resp, '{}', 0);
    is($result->{retryable}, 0, 'Subscription 403 is NOT retryable (plain string error)');
    is($result->{error_type}, 'auth_failed', 'Error type is auth_failed');
    like($result->{error}, qr/subscription|upgrade/i, 'Error contains subscription message');
};

subtest 'handle_error_response - 403 with recovery callback (transient auth issue)' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 403,
        status_line => '403 Forbidden',
        content => '{"error":{"message":"Token invalid","code":"token_invalid"}}',
    );

    # With recovery callback that succeeds
    my $result = $handler->handle_error_response($resp, '{}', 0,
        attempt_token_recovery => sub { return 1; }
    );
    is($result->{retryable}, 1, '403 with recovery is retryable');
    is($result->{error_type}, 'auth_recovered', 'Error type is auth_recovered');
    like($result->{error}, qr/refreshed/i, 'Error says token refreshed');
};

subtest 'handle_error_response - 401 with recovery (invalid token)' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 401,
        status_line => '401 Unauthorized',
        content => '{"error":{"message":"Invalid token"}}',
    );

    # With recovery callback that succeeds
    my $result = $handler->handle_error_response($resp, '{}', 0,
        attempt_token_recovery => sub { return 1; }
    );
    is($result->{retryable}, 1, '401 with recovery is retryable');
    is($result->{error_type}, 'auth_recovered', 'Error type is auth_recovered');
};

# =============================================================================
# Copilot session rate limit tests
# =============================================================================

subtest 'handle_error_response - Copilot session rate limit message' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 429,
        status_line => '429 Too Many Requests',
        content => '{"error":{"message":"You have used 51% of your session rate limit","code":"session_limit"}}',
    );

    my $result = $handler->handle_error_response($resp, '{}', 0);
    is($result->{retryable}, 0, 'Copilot session limit is NOT retryable');
    is($result->{error_type}, 'rate_limit', 'Error type is rate_limit');
    is($result->{rate_limit_code}, 'copilot_session_limit', 'Rate limit code is copilot_session_limit');
    like($result->{error}, qr/51%.*session.*rate.*limit/i, 'Error contains the quota message');
};


# =============================================================================
# Anthropic self-describing mode-mismatch tests
# =============================================================================
# The Anthropic API returns the correct thinking.type directly in the
# 400 error message:
#
#   "thinking.type.enabled" is not supported for this model.
#   Use "thinking.type.adaptive" and "output_config.effort" ...
#
# This is a much better signal than guessing from the model name - the
# API itself tells us the right answer. ResponseHandler extracts the
# correct mode and stashes it on _correct_reasoning_mode so the
# caller's retry loop can rebuild the request and persist the learning.

subtest 'handle_error_response - Anthropic self-describing mode mismatch (enabled rejected, adaptive correct)' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 400,
        status_line => '400 Bad Request',
        content => '{"type":"error","error":{"type":"invalid_request_error","message":"\"thinking.type.enabled\" is not supported for this model. Use \"thinking.type.adaptive\" and \"output_config.effort\" to control thinking behavior."}}',
    );

    my $result = $handler->handle_error_response($resp, '{}', 0);
    is($result->{retryable}, 1, 'Mode mismatch is retryable (we know the right mode)');
    is($result->{error_type}, 'unsupported_param', 'Error type is unsupported_param');
    is($handler->{_correct_reasoning_mode}, 'adaptive',
        'Correct mode extracted from error text: enabled rejected -> adaptive correct');
    like($result->{error}, qr/adaptive/i,
        'Retry info mentions the correct mode');
};

subtest 'handle_error_response - Anthropic self-describing (adaptive rejected, enabled correct)' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 400,
        status_line => '400 Bad Request',
        content => '{"error":{"message":"thinking.type.adaptive is not supported for this model. Use thinking.type.enabled to control thinking behavior."}}',
    );

    my $result = $handler->handle_error_response($resp, '{}', 0);
    is($result->{retryable}, 1, 'Reverse mismatch is also retryable');
    is($handler->{_correct_reasoning_mode}, 'enabled',
        'Correct mode extracted: adaptive rejected -> enabled correct');
};

subtest 'handle_error_response - Anthropic self-describing ignores _no_reasoning flag' => sub {
    # The mode-mismatch branch is more specific than the generic
    # "thinking is not supported" branch - it must take precedence and
    # set _correct_reasoning_mode instead of _no_reasoning.
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 400,
        status_line => '400 Bad Request',
        content => '{"error":{"message":"thinking.type.enabled is not supported for this model. Use thinking.type.adaptive."}}',
    );

    $handler->handle_error_response($resp, '{}', 0);
    is($handler->{_correct_reasoning_mode}, 'adaptive',
        'Mode-mismatch branch sets _correct_reasoning_mode');
    ok(!$handler->{_no_reasoning},
        'Mode-mismatch branch does NOT set _no_reasoning (we know the right mode, not that thinking is forbidden)');
};

subtest 'handle_error_response - non-mode-mismatch 400 still uses _no_reasoning path' => sub {
    # If the 400 doesn't have the "Use thinking.type.X" pattern, fall
    # through to the generic "thinking is not supported" branch which
    # sets _no_reasoning.
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 400,
        status_line => '400 Bad Request',
        content => '{"error":{"message":"thinking is not supported by this model"}}',
    );

    $handler->handle_error_response($resp, '{}', 0);
    ok(!defined $handler->{_correct_reasoning_mode},
        'Generic thinking-not-supported leaves _correct_reasoning_mode undef');
    is($handler->{_no_reasoning}, 1,
        'Generic thinking-not-supported still sets _no_reasoning');
};

subtest 'handle_error_response - unknown mode in error falls through' => sub {
    # Defensive: if the API ever returns a mode we don't recognize,
    # don't set _correct_reasoning_mode (so retry won't loop forever).
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 400,
        status_line => '400 Bad Request',
        content => '{"error":{"message":"thinking.type.enabled is not supported. Use thinking.type.futuremode"}}',
    );

    my $result = $handler->handle_error_response($resp, '{}', 0);
    ok(!defined $handler->{_correct_reasoning_mode},
        'Unknown correct mode -> _correct_reasoning_mode stays undef');
};
# =============================================================================
# Provider backend unavailability tests (NVIDIA NIM DEGRADED function, etc.)
# =============================================================================
# These errors are NOT retryable: the model itself is unavailable on the
# provider's infrastructure, so retrying or trimming context cannot help.
# Misclassifying these as retryable bad_request causes the misleading
# "Token limit exceeded even with minimal conversation history" message.

subtest 'handle_error_response - NVIDIA DEGRADED function (400)' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 400,
        status_line => '400 Bad Request',
        content => '{"status":400,"title":"Bad Request","detail":"Function id \'948fe171-ce7a-4332-8bc0-5e14e90259f9\': DEGRADED function cannot be invoked"}',
    );

    my $result = $handler->handle_error_response($resp, '{}', 0);
    is($result->{retryable}, 0, 'NVIDIA DEGRADED function is NOT retryable');
    is($result->{error_type}, 'provider_unavailable', 'Error type is provider_unavailable');
    like($result->{error}, qr/unavailable/i, 'Error mentions unavailability');
    like($result->{error}, qr/DEGRADED function/, 'Error preserves provider detail');
};

subtest 'handle_error_response - 503 model_not_available' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 503,
        status_line => '503 Service Unavailable',
        content => '{"error":{"message":"The model gpt-99 is currently unavailable","code":"model_not_available"}}',
    );

    my $result = $handler->handle_error_response($resp, '{}', 0);
    is($result->{retryable}, 0, 'model_not_available is NOT retryable');
    is($result->{error_type}, 'provider_unavailable', 'Error type is provider_unavailable');
};

subtest 'handle_error_response - 400 generic model unavailable' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 400,
        status_line => '400 Bad Request',
        content => '{"error":{"message":"model is unavailable on this endpoint"}}',
    );

    my $result = $handler->handle_error_response($resp, '{}', 0);
    is($result->{retryable}, 0, 'model unavailable is NOT retryable');
    is($result->{error_type}, 'provider_unavailable', 'Error type is provider_unavailable');
};

subtest 'handle_error_response - 503 service unavailable' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 503,
        status_line => '503 Service Unavailable',
        content => '{"error":{"message":"service unavailable, please try again later"}}',
    );

    my $result = $handler->handle_error_response($resp, '{}', 0);
    is($result->{retryable}, 0, 'service unavailable is NOT retryable');
    is($result->{error_type}, 'provider_unavailable', 'Error type is provider_unavailable');
};

subtest 'handle_error_response - generic 400 still retryable (regression check)' => sub {
    # Confirm we did NOT change behavior for genuine 400s that should still retry.
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 400,
        status_line => '400 Bad Request',
        content => '{"error":{"message":"Invalid request payload"}}',
    );

    my $result = $handler->handle_error_response($resp, '{}', 0);
    is($result->{retryable}, 1, 'Generic 400 still retryable');
    is($result->{error_type}, 'bad_request', 'Error type is still bad_request');
};
# =============================================================================
# Non-retryable error type tests (Layer 2 - billing/model_not_found/etc)
# =============================================================================
# These errors are NEVER retryable. No amount of waiting fixes an empty balance,
# a missing model, a regional lock, or a deactivated account.

subtest 'handle_error_response - 400 billing_error (insufficient credit)' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 400,
        status_line => '400 Bad Request',
        content => '{"error":{"message":"You have insufficient credit balance to use this model. Please top up your account.","type":"insufficient_credit"}}',
    );

    my $result = $handler->handle_error_response($resp, '{}', 0);
    is($result->{retryable}, 0, 'Insufficient credit is NOT retryable');
    is($result->{error_type}, 'billing_error', 'Error type is billing_error');
    like($result->{error}, qr/credits or hit a billing limit/i, 'User-facing message mentions billing');
};

subtest 'handle_error_response - 402 payment_required' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 402,
        status_line => '402 Payment Required',
        content => '{"error":{"message":"Payment required to access this model"}}',
    );

    my $result = $handler->handle_error_response($resp, '{}', 0);
    is($result->{retryable}, 0, '402 Payment Required is NOT retryable');
    is($result->{error_type}, 'billing_error', 'Error type is billing_error');
};

subtest 'handle_error_response - 402 OpenRouter in_flight_budget_exhausted (retryable)' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 402,
        status_line => '402 Payment Required',
        content => '{"error":{"message":"This request would exceed your available credits given your current in-flight requests. Retry after in-flight requests settle, or add credits.","code":402,"metadata":{"reason":"in_flight_budget_exhausted","limit_source":"openrouter_in_flight_budget","remedy_hint":"Retry after your in-flight requests settle (see the Retry-After header). Adding credits at https://openrouter.ai/settings/credits raises your in-flight budget, up to a capped ceiling."}}}',
    );

    my $result = $handler->handle_error_response($resp, '{}', 0, headers => { 'retry-after' => '120' });
    is($result->{retryable}, 1, 'in_flight_budget_exhausted with Retry-After IS retryable');
    is($result->{error_type}, 'rate_limit', 'Error type is rate_limit');
    is($result->{retry_after}, 120, 'retry_after extracted from Retry-After header (120s)');
    like($result->{error}, qr/in-flight budget exhausted/i, 'User message names the failure mode');
};

subtest 'handle_error_response - 402 OpenRouter in_flight_budget_exhausted without Retry-After' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 402,
        status_line => '402 Payment Required',
        content => '{"error":{"message":"in-flight budget exhausted","metadata":{"reason":"in_flight_budget_exhausted"}}}',
    );

    my $result = $handler->handle_error_response($resp, '{}', 0);
    is($result->{retryable}, 0, 'in_flight_budget_exhausted WITHOUT Retry-After is NOT retryable (we do not know when to retry)');
    is($result->{error_type}, 'billing_error', 'Error type is billing_error when retry timing unknown');
    like($result->{error}, qr/no Retry-After/i, 'User message explains why we cannot auto-retry');
};

subtest 'handle_error_response - 402 OpenRouter openrouter_credits (hard stop with hint)' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 402,
        status_line => '402 Payment Required',
        content => '{"error":{"message":"This request requires more credits, or fewer max_tokens. You requested up to 131072 tokens, but can only afford 12843. To increase, visit https://openrouter.ai/settings/credits and add more credits","code":402,"metadata":{"reason":"openrouter_credits","limit_source":"openrouter_credits"}}}',
    );

    my $result = $handler->handle_error_response($resp, '{}', 0);
    is($result->{retryable}, 0, 'openrouter_credits 402 is NOT retryable (real credit exhaustion)');
    is($result->{error_type}, 'billing_error', 'Error type is billing_error');
    like($result->{error}, qr/131072/, 'User message surfaces requested token count');
    like($result->{error}, qr/12843/, 'User message surfaces affordable token count');
    like($result->{error}, qr/credits/i, 'User message points to credits');
    ok(index($result->{error}, 'Provider detail:') == -1, 'No raw provider dump appended (deduped)');
};

subtest 'handle_error_response - 400 billing_error (payment required string)' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 400,
        status_line => '400 Bad Request',
        content => '{"error":{"message":"Payment required for this endpoint"}}',
    );

    my $result = $handler->handle_error_response($resp, '{}', 0);
    is($result->{retryable}, 0, 'payment required string is NOT retryable');
    is($result->{error_type}, 'billing_error', 'Error type is billing_error');
};

subtest 'handle_error_response - 400 model_not_found' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 404,
        status_line => '404 Not Found',
        content => '{"error":{"message":"The model `gpt-99-turbo` does not exist or you do not have access to it.","code":"model_not_found"}}',
    );

    my $result = $handler->handle_error_response($resp, '{}', 0);
    is($result->{retryable}, 0, 'Model not found is NOT retryable');
    is($result->{error_type}, 'model_not_found', 'Error type is model_not_found');
    like($result->{error}, qr/switch models|different model/i, 'User-facing message mentions switching models');
};

subtest 'handle_error_response - 400 "no such model" string' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 400,
        status_line => '400 Bad Request',
        content => '{"error":{"message":"No such model: claude-fake-99"}}',
    );

    my $result = $handler->handle_error_response($resp, '{}', 0);
    is($result->{retryable}, 0, 'No such model is NOT retryable');
    is($result->{error_type}, 'model_not_found', 'Error type is model_not_found');
};

subtest 'handle_error_response - 403 region_unavailable' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 403,
        status_line => '403 Forbidden',
        content => '{"error":{"message":"This model is not available in your region. Please try a model deployed in a supported region.","code":"region_unavailable"}}',
    );

    my $result = $handler->handle_error_response($resp, '{}', 0);
    is($result->{retryable}, 0, 'Region unavailable is NOT retryable');
    is($result->{error_type}, 'region_unavailable', 'Error type is region_unavailable');
};

subtest 'handle_error_response - 400 account_disabled' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 403,
        status_line => '403 Forbidden',
        content => '{"error":{"message":"Your organization has been deactivated. Please contact support.","code":"account_deactivated"}}',
    );

    my $result = $handler->handle_error_response($resp, '{}', 0);
    is($result->{retryable}, 0, 'Account deactivated is NOT retryable');
    is($result->{error_type}, 'account_disabled', 'Error type is account_disabled');
};

subtest 'handle_error_response - 400 organization inactive' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 400,
        status_line => '400 Bad Request',
        content => '{"error":{"message":"Organization inactive - access denied"}}',
    );

    my $result = $handler->handle_error_response($resp, '{}', 0);
    is($result->{retryable}, 0, 'Org inactive is NOT retryable');
    is($result->{error_type}, 'account_disabled', 'Error type is account_disabled');
};

# =============================================================================
# Retryable-but-specific error type tests (Layer 2 - timeout/overloaded)
# =============================================================================
# These should be retried with a longer backoff than generic 2s.

subtest 'handle_error_response - 504 Gateway Timeout' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 504,
        status_line => '504 Gateway Timeout',
        content => '{"error":{"message":"Upstream provider timed out"}}',
    );

    my $result = $handler->handle_error_response($resp, '{}', 0);
    is($result->{retryable}, 1, '504 Gateway Timeout IS retryable');
    is($result->{error_type}, 'timeout', 'Error type is timeout');
    is($result->{retry_after}, 30, 'Timeout retry_after is 30s (longer than generic 2s)');
};

subtest 'handle_error_response - 408 Request Timeout' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 408,
        status_line => '408 Request Timeout',
        content => '{"error":{"message":"Request took too long"}}',
    );

    my $result = $handler->handle_error_response($resp, '{}', 0);
    is($result->{retryable}, 1, '408 Request Timeout IS retryable');
    is($result->{error_type}, 'timeout', 'Error type is timeout');
};

subtest 'handle_error_response - 500 engine_overloaded' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 503,
        status_line => '503 Service Unavailable',
        content => '{"error":{"message":"engine_overloaded","code":"engine_overloaded"}}',
    );

    my $result = $handler->handle_error_response($resp, '{}', 0);
    is($result->{retryable}, 1, 'engine_overloaded IS retryable');
    is($result->{error_type}, 'overloaded', 'Error type is overloaded (not server_error)');
    is($result->{retry_after}, 10, 'Overloaded retry_after is 10s');
};

subtest 'handle_error_response - 500 model overloaded string' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 500,
        status_line => '500 Internal Server Error',
        content => '{"error":{"message":"model_overloaded - please retry after a short wait"}}',
    );

    my $result = $handler->handle_error_response($resp, '{}', 0);
    is($result->{retryable}, 1, 'model_overloaded string IS retryable');
    is($result->{error_type}, 'overloaded', 'Error type is overloaded');
};

subtest 'handle_error_response - 500 upstream_error' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 502,
        status_line => '502 Bad Gateway',
        content => '{"error":{"message":"upstream_error: provider returned an empty response"}}',
    );

    my $result = $handler->handle_error_response($resp, '{}', 0);
    is($result->{retryable}, 1, 'upstream_error IS retryable');
    is($result->{error_type}, 'overloaded', 'Error type is overloaded (not server_error)');
};

# =============================================================================
# Generic 400 fallback improvement tests (Layer 1)
# =============================================================================
# The new behavior preserves the actual provider error message instead of
# overwriting it with a generic retry notice.

subtest 'handle_error_response - generic 400 preserves provider error' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 400,
        status_line => '400 Bad Request',
        content => '{"error":{"message":"Invalid request payload: missing required field \'messages\'"}}',
    );

    my $result = $handler->handle_error_response($resp, '{}', 0);
    is($result->{retryable}, 1, 'Generic 400 still retryable');
    is($result->{error_type}, 'bad_request', 'Error type is still bad_request');
    like($result->{error}, qr/Invalid request payload: missing required field/, 'Error preserves actual provider message');
};

subtest 'handle_error_response - generic 400 with no error_obj shows hint' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 400,
        status_line => '400 Bad Request',
        content => 'plain text body',
    );

    my $result = $handler->handle_error_response($resp, '{}', 0);
    is($result->{retryable}, 1, 'Generic 400 still retryable');
    is($result->{error_type}, 'bad_request', 'Error type is bad_request');
    like($result->{error}, qr/\/tmp\/clio_api_400\.log/, 'Empty-body 400 hint points to diagnostic log');
};

# Regression check: NVIDIA DEGRADED function still classified correctly with new patterns in place
subtest 'handle_error_response - NVIDIA DEGRADED still classified correctly (regression)' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 400,
        status_line => '400 Bad Request',
        content => '{"status":400,"title":"Bad Request","detail":"Function id \'abc\': DEGRADED function cannot be invoked"}',
    );

    my $result = $handler->handle_error_response($resp, '{}', 0);
    is($result->{error_type}, 'provider_unavailable', 'DEGRADED function still classified as provider_unavailable');
    is($result->{retryable}, 0, 'DEGRADED function still NOT retryable');
};
done_testing();
