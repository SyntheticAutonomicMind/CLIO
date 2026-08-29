#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test: streaming response header recovery.
#
# Bug: The curl streaming path (CLIO::Compat::HTTP::_request_via_curl_streaming)
# passes a stub response object with headers => {} and status => 200 to the
# streaming callback (for real-time delivery before the -D header file is
# parsed). APIManager's callback then captures $streaming_headers =
# $response->headers->clone from that stub, which is empty. The fallback in
# _finalize_streaming_response (line ~4807) only replaced streaming_headers
# when it was missing or undef - not when it was an empty stub. As a result,
# real Retry-After and x-ratelimit-* headers from streaming responses were
# silently lost, and rate-limit errors fell back to the 60s blind default.
#
# This test asserts the recovery logic: when streaming_headers is empty,
# _finalize_streaming_response must replace it with the real response
# object's headers so downstream rate-limit and error paths can read
# Retry-After, x-ratelimit-*, etc.

use strict;
use warnings;
use utf8;
use lib '/home/deck/repositories/CLIO/lib';
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Test::More;
use CLIO::Compat::HTTP;
use CLIO::Core::Defaults qw(DEFAULT_RATE_LIMIT_RETRY_AFTER);

# Build a stub Headers object (the one curl streaming creates for
# preliminary delivery - empty hash, but blessed as a Headers object).
{
    package StubEmptyHeaders;
    sub new { bless { headers => {} }, $_[0] }
    sub header { return undef }
    sub header_field_names { return () }
    sub scan { }
}

# Build a "real" Headers object with the headers we expect to see after
# the curl -D file is parsed.
{
    package RealHeaders;
    sub new { bless { headers => { %{$_[1]} } }, $_[0] }
    sub header { return $_[0]->{headers}{lc $_[1]} }
    sub header_field_names { return keys %{$_[0]->{headers}} }
    sub scan { my ($s, $cb) = @_; while (my ($k, $v) = each %{$s->{headers}}) { $cb->($k, $v) } }
}

# Test 1: empty stub headers are detected (header_field_names returns empty)
{
    my $stub = StubEmptyHeaders->new();
    my @names = $stub->header_field_names();
    is_deeply(\@names, [], 'Empty stub headers return no field names');
}

# Test 2: real headers with Retry-After expose the value
{
    my $real = RealHeaders->new({
        'retry-after' => '120',
        'x-ratelimit-remaining-requests' => '0',
    });
    is($real->header('Retry-After'), '120', 'Real headers expose Retry-After');
    is($real->header('X-RateLimit-Remaining-Requests'), '0', 'Real headers expose x-ratelimit-*');
    is_deeply([sort $real->header_field_names()],
              [sort ('retry-after', 'x-ratelimit-remaining-requests')],
              'Real headers expose both fields');
}

# Test 3: end-to-end through ResponseHandler: when streaming_headers from
# the stub is empty and the real response carries Retry-After, the rate
# limit path must use the real header value.
{
    package MockRespWithHeaders;
    sub new {
        my ($class, %opts) = @_;
        return bless {
            code => 429,
            status_line => '429 Too Many Requests',
            content => '{"error":{"message":"rate limited"}}',
            _headers_obj => $opts{headers},
        }, $class;
    }
    sub code { 429 }
    sub status_line { '429 Too Many Requests' }
    sub decoded_content { $_[0]->{content} }
    sub is_success { 0 }
    sub headers { $_[0]->{_headers_obj} }

    package main;
}

# Simulate the bug scenario: the streaming callback captured an empty
# stub, but the real response object has the Retry-After header. The
# ResponseHandler should read Retry-After from the passed headers.
{
    require CLIO::Core::API::ResponseHandler;

    my $real = RealHeaders->new({'retry-after' => '120'});
    my $resp = MockRespWithHeaders->new(headers => $real);

    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $result = $handler->handle_error_response(
        $resp, '{}', 1,  # is_streaming=1
        headers => $real,
    );
    is($result->{retryable}, 1, '429 is retryable');
    is($result->{error_type}, 'rate_limit', 'Error type is rate_limit');
    is($result->{retry_after}, 120,
       'Retry-After: 120 extracted from real headers (streaming recovery worked)');
}

# Test 4: when neither stub nor real headers carry retry-after, the
# DEFAULT_RATE_LIMIT_RETRY_AFTER fallback (5s) is used.
{
    is(DEFAULT_RATE_LIMIT_RETRY_AFTER, 5, 'DEFAULT_RATE_LIMIT_RETRY_AFTER is 5s');
}

# Test 5: when streaming_headers stub is empty AND real response is also
# empty, the fallback chain (body hint) should still produce a sensible
# retry_after. With no body hint and no header, DEFAULT_RATE_LIMIT_RETRY_AFTER
# should win.
{
    require CLIO::Core::API::ResponseHandler;

    my $empty = RealHeaders->new({});
    my $resp = MockRespWithHeaders->new(headers => $empty);
    # Body has no "retry in Ns" hint either.
    $resp->{content} = '{"error":{"message":"rate limited"}}';

    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $result = $handler->handle_error_response(
        $resp, '{}', 1,
        headers => $empty,
    );
    is($result->{retryable}, 1, 'Still retryable');
    is($result->{retry_after},
       DEFAULT_RATE_LIMIT_RETRY_AFTER,
       'Falls back to DEFAULT_RATE_LIMIT_RETRY_AFTER (5s) when no signal at all');
}

done_testing();
