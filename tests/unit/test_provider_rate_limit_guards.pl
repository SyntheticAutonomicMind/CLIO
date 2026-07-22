#!/usr/bin/env perl

# SPDX-License-Identifier: GPL-3.0-or-later
# Test that rate limit guards work correctly for all supported providers.
#
# Verifies:
# - DeepSeek model-specific concurrency limits (500 v4-pro, 2500 v4-flash)
# - NVIDIA NIM SSE error chunk detection (ResourceExhausted, Worker limit)
# - OpenAI "Slow Down" 503 with aggressive throttle learning
# - Plain text error body fallback (GitHub Copilot-style)
# - Plain text 403 with subscription keyword routes to permanent auth failure

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use lib "$RealBin/../lib";
use Test::More;

use CLIO::Core::RateLimiter;
use CLIO::Providers;

# Mock objects for ResponseHandler tests
{
    package MockHeaders;
    sub new { bless { headers => $_[1] // {} }, $_[0] }
    sub header { return undef }
    sub can { 1 }
}
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
}

# Fake APIManager for throttle learning verification
{
    package FakeAPIManager;
    sub new { bless { calls => [], apimanager_for_handler => undef }, shift }
    sub report_rate_limit_for_model {
        my ($self, $model) = @_;
        push @{$self->{calls}}, $model;
    }
    sub can { my ($self, $name) = @_; return $name eq "report_rate_limit_for_model" }
}

# Fake session with selected_model
{
    package FakeSession;
    sub new { bless { state => { selected_model => "gpt-4.1", selected_provider => "openai" }, }, shift }
    sub state { $_[0]->{state} }
    sub can { 1 }
}

# ============================================================
# Section 1: DeepSeek model-specific concurrency
# ============================================================
CLIO::Core::RateLimiter->reset_instance();
my $rl = CLIO::Core::RateLimiter->get_instance();
my $configured = CLIO::Providers::configure_rate_limiter($rl);
is($configured, 2, "configure_rate_limiter() configured 2 model concurrency entries");
is($rl->get_max_concurrent("deepseek", "deepseek-v4-pro"), 500,
    "DeepSeek v4-pro limit is 500");
is($rl->get_max_concurrent("deepseek", "deepseek-v4-flash"), 2500,
    "DeepSeek v4-flash limit is 2500");
is($rl->get_max_concurrent("deepseek", "unknown-model"), 2,
    "Unknown DeepSeek model falls back to default concurrency");
is($rl->get_max_concurrent("openai"), 2, "OpenAI uses default concurrency");
is($rl->get_max_concurrent("anthropic"), 2, "Anthropic uses default concurrency");

# Acquire/release accounting
ok($rl->acquire("deepseek", "deepseek-v4-pro"), "Can acquire first slot for v4-pro");
is($rl->get_active_count("deepseek"), 1, "Active count is 1 after acquire");
$rl->release("deepseek");
is($rl->get_active_count("deepseek"), 0, "Active count is 0 after release");

# ============================================================
# Section 2: NVIDIA NIM SSE error chunk pattern matching
# ============================================================
require CLIO::Core::API::ResponseHandler;

# The SSE error detection regex used in _finalize_streaming_response
my $sse_msg_pattern = qr/ResourceExhausted|Worker.*limit|quota|too many requests/i;
my $sse_code_pattern = qr/rate.?lim/i;

for my $msg (
    'ResourceExhausted: Worker local total request limit reached (74/32)',
    'Worker local total request limit reached',
    'Too many requests, please slow down',
    'quota exceeded for this account',
) {
    ok($msg =~ $sse_msg_pattern, "NVIDIA NIM SSE pattern matches: '$msg'");
}

# Generic 'rate limit' string alone does NOT match the SSE msg pattern
# (rate_limit codes are matched via the $code =~ /rate.?lim/i check)
ok(!('Rate limit reached' =~ $sse_msg_pattern),
    "Generic 'rate limit' string alone does not match SSE msg pattern (must be code-driven)");

# Code-driven match (e.g. when SSE error chunk has code='rate_limit')
ok(('rate_limit' =~ $sse_code_pattern),
    "Code 'rate_limit' matches SSE code rate-limit pattern");

# ============================================================
# Section 3: OpenAI "Slow Down" 503 detection + throttle learning
# ============================================================
{
    my $handler = CLIO::Core::API::ResponseHandler->new(session => FakeSession->new());
    my $fake_api = FakeAPIManager->new();
    $handler->set_apimanager($fake_api);

    my $resp = MockResponse->new(
        code => 503,
        status_line => '503 Slow Down',
        content => '{"error":{"message":"Slow down. Please reduce your request rate.","type":"server_error"}}',
    );

    my $result = $handler->handle_error_response($resp, "{}", 0);
    is($result->{error_type}, 'overloaded', "OpenAI Slow Down classified as overloaded");
    is($result->{retryable}, 1, "OpenAI Slow Down is retryable");
    is($result->{retry_after}, 60, "OpenAI Slow Down 60s retry_after");
    is(scalar(@{$fake_api->{calls}}), 1, "Throttle learning called exactly once");
    is($fake_api->{calls}[0], 'gpt-4.1', "Throttle learning got correct model");
    like($result->{error}, qr/OpenAI.*Slow Down/is, "Error message describes OpenAI Slow Down behavior");
}

# ============================================================
# Section 4: Plain-text error body fallback in _parse_error_response
# ============================================================
{
    my $handler = CLIO::Core::API::ResponseHandler->new();

    # GitHub Copilot-style plain text 401
    my $resp = MockResponse->new(
        code => 401,
        status_line => '401 Unauthorized',
        content => 'unauthorized: unauthorized: AuthenticateToken authentication failed',
    );

    my $parsed = $handler->_parse_error_response($resp, 0);
    is($parsed->{status}, 401, "Plain-text 401: status preserved");
    like($parsed->{error}, qr/AuthenticateToken/,
        "Plain-text 401: error contains actual provider message");
    like("$parsed->{error_obj}", qr/AuthenticateToken/,
        "Plain-text 401: error_obj set so dispatchers can pattern match");
}

{
    # Plain-text 403 with subscription keyword - should route to permanent auth failure
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = MockResponse->new(
        code => 403,
        status_line => '403 Forbidden',
        content => 'subscription required: please upgrade to a paid plan',
    );

    my $result = $handler->handle_error_response($resp, "{}", 0);
    is($result->{error_type}, 'auth_failed', "Plain-text 403 subscription -> auth_failed");
    is($result->{retryable}, 0, "Plain-text 403 subscription is NOT retryable");
    like($result->{error}, qr/subscription required/,
        "Plain-text 403: provider message preserved verbatim");
}

done_testing();
