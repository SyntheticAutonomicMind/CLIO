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
            code => $opts{code} || 200,
            status_line => $opts{status_line} || "$opts{code} Error",
            content => $opts{content} || '{}',
            headers => $opts{headers} || MockHeaders->new(),
        }, $class;
    }
    sub code { $_[0]->{code} }
    sub status_line { $_[0]->{status_line} }
    sub decoded_content { $_[0]->{content} }
    sub is_success { $_[0]->{code} >= 200 && $_[0]->{code} < 300 }
    sub header { return undef }
    sub headers { $_[0]->{headers} }

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
    ok(!$result->{retryable}, 'Generic 500 is not retryable');
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

done_testing();
