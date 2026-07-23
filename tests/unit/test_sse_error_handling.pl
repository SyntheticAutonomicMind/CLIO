#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 fewtarius
#
# Regression test: SSE error chunks (NVIDIA NIM pattern) must surface as
# errors instead of being silently swallowed.
#
# Bug: When a streaming response body is
#   `data: {"error":{"message":"...","code":"..."}}\n\n`,
# the SSE parser logs the chunk fields but does not extract content,
# tool calls, or any error info. `_check_200_body_error` then fails to
# parse the body as JSON (because of the `data:` prefix and trailing
# newlines) and returns undef. The result is a `{success=>1, content=>''}`
# response that exits the workflow with "UNDEF", losing the user's
# in-progress task state.
#
# This test verifies the fix in APIManager's `_check_200_body_error` so
# that streaming error bodies from providers (NVIDIA NIM in particular)
# are recognized and surfaced to the orchestrator for retry handling.

use strict;
use warnings;
use utf8;
use lib '/home/deck/repositories/CLIO/lib';
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Test::More;
use CLIO::Util::JSON qw(decode_json);
use CLIO::Core::APIManager;

# Minimal stub for the response_handler that the function pokes at:
# release_broker_slot() is called when an error is found.
{
    package StubRH;
    sub release_broker_slot {}
}

sub fake_resp {
    return bless { headers => bless {}, 'FakeResp' }, 'FakeResp';
}

sub am_with_stub {
    return bless { response_handler => bless {}, 'StubRH' },
        'CLIO::Core::APIManager';
}

# Test 1: NVIDIA NIM-style SSE error body must be parsed
{
    my $am = am_with_stub();
    my $sse_body = 'data: {"error":{"message":"Upstream provider returned empty response","code":"upstream"}}';

    my $s = {
        accumulated_content => '',
        tool_calls_accumulator => {},
        raw_response_body => $sse_body . "\n\n",
        buffer => '',
    };

    my $resp = fake_resp();
    my $err = $am->_check_200_body_error($resp, $s);

    ok(defined $err, 'Test 1.1: SSE-framed error body parsed');
    is($err->{success}, 0, 'Test 1.2: error response has success=0');
    like($err->{error}, qr/Upstream provider returned empty response/,
         'Test 1.3: error message extracted');
}

# Test 2: Rate-limit SSE error body must be classified as rate_limit
{
    my $am = am_with_stub();
    my $sse_body = 'data: {"error":{"message":"Rate limit exceeded","code":"rate_limit_exceeded"}}';

    my $s = {
        accumulated_content => '',
        tool_calls_accumulator => {},
        raw_response_body => $sse_body . "\n\n",
        buffer => '',
    };

    my $resp = fake_resp();
    my $err = $am->_check_200_body_error($resp, $s);

    ok(defined $err, 'Test 2.1: rate-limit SSE body parsed');
    is($err->{error_type}, 'rate_limit', 'Test 2.2: classified as rate_limit');
    is($err->{retryable}, 1, 'Test 2.3: rate-limit is retryable');
}

# Test 3: Non-SSE (plain JSON) error body must still work (Google/OpenRouter)
{
    my $am = am_with_stub();
    my $plain_body = '{"error":{"message":"Bad gateway","code":"bad_gateway"}}';

    my $s = {
        accumulated_content => '',
        tool_calls_accumulator => {},
        raw_response_body => $plain_body,
        buffer => '',
    };

    my $resp = fake_resp();
    my $err = $am->_check_200_body_error($resp, $s);

    ok(defined $err, 'Test 3.1: plain JSON error body still parsed');
    like($err->{error}, qr/Bad gateway/, 'Test 3.2: plain JSON error message extracted');
}

# Test 4: SSE success body with accumulated content must NOT trigger error path
{
    my $am = am_with_stub();
    my $sse_body = 'data: {"choices":[{"message":{"content":"hello"}}]}';

    my $s = {
        accumulated_content => 'hello',  # Already streamed successfully
        tool_calls_accumulator => {},
        raw_response_body => $sse_body . "\n\n",
        buffer => '',
    };

    my $resp = fake_resp();
    my $err = $am->_check_200_body_error($resp, $s);

    is($err, undef, 'Test 4.1: accumulated content short-circuits error check');
}

# Test 5: Empty body returns undef cleanly
{
    my $am = am_with_stub();
    my $s = {
        accumulated_content => '',
        tool_calls_accumulator => {},
        raw_response_body => '',
        buffer => '',
    };

    my $resp = fake_resp();
    my $err = $am->_check_200_body_error($resp, $s);

    is($err, undef, 'Test 5.1: empty body returns undef');
}

# Test 6: Tool calls present WITH a finish_reason -> response was legitimate,
# ignore the body-level error chunk (it's spurious noise)
{
    my $am = am_with_stub();
    my $sse_body = 'data: {"error":{"message":"late error","code":"late"}}';

    my $s = {
        accumulated_content => '',
        tool_calls_accumulator => { 0 => { id => 'call_1' } },
        raw_response_body => $sse_body . "\n\n",
        buffer => '',
        _finish_reason => 'tool_calls',
    };

    my $resp = fake_resp();
    my $err = $am->_check_200_body_error($resp, $s);

    is($err, undef, 'Test 6.1: tool calls + finish_reason short-circuits body-level error');
}

# Test 7: Tool calls present WITHOUT a finish_reason -> stream was truncated
# before the model could emit its finish marker. Return the body-level error
# so the orchestrator retries (this is the MiniMax-style silent stop).
{
    my $am = am_with_stub();
    my $sse_body = 'data: {"error":{"message":"stream died","code":"trunc"}}';

    my $s = {
        accumulated_content => '',
        tool_calls_accumulator => { 0 => { id => 'call_1' } },
        raw_response_body => $sse_body . "\n\n",
        buffer => '',
    };

    my $resp = fake_resp();
    my $err = $am->_check_200_body_error($resp, $s);

    isa_ok($err, 'HASH', 'Test 7.1: tool_calls without finish_reason surfaces truncated-stream error');
    is($err->{error}, 'stream died', 'Test 7.2: error message preserved');
    is($err->{success}, 0, 'Test 7.3: success flag set');
}

done_testing();
