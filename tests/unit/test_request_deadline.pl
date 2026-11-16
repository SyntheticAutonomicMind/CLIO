#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt
#
# Regression tests: a deadline CLIO imposed on itself must be reported as
# such, retried once, and then abort. It must never be reported as
# "Stream truncated detected" and must never be retried forever.
#
# Bug: a local model decoding at ~18 tokens/s was cut off by the flat 900s
# curl --max-time in the middle of a 16,000-token answer. The surfacing code
# saw "no finish_reason" and returned error_type 'truncated', which
# ErrorHandler retried with an infinite budget. Every retry hit the same
# ceiling from scratch, so the session looped on
#   "Stream truncated detected. Retrying in 5s... (attempt N)"
# until it was killed. The API server log shows the two cancelled attempts
# clearly: generated_tokens=15470 finish=cancelled duration_ms=900004.
#
# The 900s ceiling was also unreachable by design: 18 tokens/s * 900s is
# ~16,000 tokens, and CLIO was asking for exactly 16,384.

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";

use Test::More;
use Time::HiRes qw(time sleep);

use CLIO::Core::APIManager;
use CLIO::Core::API::ErrorHandler;
use CLIO::Core::Config;
use CLIO::Compat::HTTP;

# ── Helpers ────────────────────────────────────────────────────────────────

# An APIManager good enough to call the pure-ish helpers directly.
sub am_stub {
    my %extra = @_;
    return bless {
        response_handler => bless({}, 'StubRH'),
        rate_limiter     => bless({}, 'StubRL'),
        %extra,
    }, 'CLIO::Core::APIManager';
}

# Minimal response object shaped like the one CLIO::Compat::HTTP::Tiny
# returns: status/code/curl_exit/reason/headers.
sub fake_resp {
    my (%kw) = @_;
    my $resp = bless {
        status    => $kw{status} // 599,
        code      => $kw{status} // 599,
        curl_exit => $kw{curl_exit},
        reason    => $kw{reason} // 'Connection timed out',
        headers   => {},
    }, 'FakeResp';
    return $resp;
}

{
    package FakeResp;
    sub code    { $_[0]{code} }
    sub headers { $_[0]{headers} }
    sub is_success { ($_[0]{status} // 0) =~ /^2/ ? 1 : 0 }
    sub decoded_content { $_[0]{content} // '' }
    sub content        { $_[0]{content} // '' }
}

{
    package StubRH;
    sub release_broker_slot { }
    sub process_rate_limit_headers { return undef }
}
{
    package StubRL;
    sub release { }
    sub update_from_headers { }
}

# ══════════════════════════════════════════════════════════════════════════
# 1. The ceiling itself: long local generations must fit inside it
# ══════════════════════════════════════════════════════════════════════════

subtest 'request ceiling is derived from the output budget' => sub {
    my $am = am_stub();

    is($am->_provider_http_timeout(
            slow_api => 1, max_tokens => 16384, provider_name => 'llama.cpp'),
        4096, '16384-token answer gets 4096s at the 4 tokens/s floor');

    is($am->_provider_http_timeout(
            slow_api => 1, max_tokens => 2000, provider_name => 'llama.cpp'),
        900, 'small budget keeps the 900s floor');

    is($am->_provider_http_timeout(
            slow_api => 1, max_tokens => 0, provider_name => 'llama.cpp'),
        900, 'zero budget falls back to the floor');

    is($am->_provider_http_timeout(
            slow_api => 1, provider_name => 'llama.cpp'),
        900, 'undef budget falls back to the floor');

    is($am->_provider_http_timeout(
            slow_api => 1, max_tokens => 128_000, provider_name => 'llama.cpp'),
        7200, 'absurd budget is capped at 7200s');

    is($am->_provider_http_timeout(
            route_timeout => 1, max_tokens => 16384, provider_name => 'openrouter'),
        300, 'route providers keep 300s');

    is($am->_provider_http_timeout(
            max_tokens => 16384, provider_name => 'openai'),
        300, 'cloud providers keep 300s');

    is($am->_provider_http_timeout(
            slow_api => 1, route_timeout => 1, max_tokens => 16384, provider_name => 'x'),
        4096, 'slow_api wins over route_timeout');
};

# ══════════════════════════════════════════════════════════════════════════
# 2. Deadline classification
# ══════════════════════════════════════════════════════════════════════════

subtest 'deadline detection needs curl exit 28' => sub {
    my $am = am_stub();

    my $deadline = $am->_deadline_failure_result(
        fake_resp(status => 599, curl_exit => 28, reason => 'Operation timed out'),
        timeout    => 900,
        content    => 'x' x 1200,
        tool_calls => 1,
    );
    ok(ref $deadline, 'curl exit 28 on 599 is a deadline');
    is($deadline->{error_type}, 'request_timeout', 'classified as request_timeout');
    is($deadline->{success}, 0, 'not a success');
    is($deadline->{retryable}, 1, 'one retry is still allowed');
    like($deadline->{error}, qr/900s request ceiling/, 'names the ceiling that expired');
    like($deadline->{error}, qr/1200 characters and 1 tool call/, 'says what was discarded');
    is($deadline->{partial_chars}, 1200, 'reports discarded content length');

    my $empty = $am->_deadline_failure_result(
        fake_resp(status => 599, curl_exit => 28), timeout => 300);
    like($empty->{error}, qr/no content had arrived yet/, 'says nothing had arrived');

    is($am->_deadline_failure_result(
            fake_resp(status => 599), timeout => 300),
        undef, '599 without curl exit 28 stays a connection error');

    is($am->_deadline_failure_result(
            fake_resp(status => 500, curl_exit => 28), timeout => 300),
        undef, 'curl exit 28 on a real HTTP error is not a deadline');

    is($am->_deadline_failure_result(
            fake_resp(status => 200, curl_exit => 28), timeout => 300),
        undef, 'curl exit 28 on a 200 is not treated as an error');

    is($am->_deadline_failure_result(undef, timeout => 300), undef,
        'no response object is not a deadline');
};

# ══════════════════════════════════════════════════════════════════════════
# 3. The streaming finalizer surfaces a deadline, not a truncation
# ══════════════════════════════════════════════════════════════════════════

subtest 'streaming finalizer reports the deadline instead of truncation' => sub {
    my $am = am_stub();

    my $result = $am->_finalize_streaming_response(
        resp                   => fake_resp(status => 599, curl_exit => 28),
        accumulated_content    => 'let me build the replacement DVR',
        accumulated_reasoning  => '',
        tool_calls_accumulator => {},
        token_count            => 7,
        start_time             => time - 900,
        streaming_headers      => {},
        provider_label         => 'llama.cpp',
        timeout                => 900,
        _finish_reason         => undef,
    );

    is($result->{error_type}, 'request_timeout',
        'expired ceiling is request_timeout, not truncated');

    # A provider that declared the response complete is never discarded,
    # even if the socket lingered until curl gave up.
    my $complete = $am->_finalize_streaming_response(
        resp                   => fake_resp(status => 599, curl_exit => 28),
        accumulated_content    => 'complete answer',
        accumulated_reasoning  => '',
        tool_calls_accumulator => {},
        token_count            => 2,
        start_time             => time - 900,
        streaming_headers      => {},
        provider_label         => 'llama.cpp',
        timeout                => 900,
        _finish_reason         => 'stop',
    );
    ok($complete->{success}, 'a response with finish_reason is kept, not discarded');
};

# ══════════════════════════════════════════════════════════════════════════
# 4. ErrorHandler: one retry, then abort with an actionable message
# ══════════════════════════════════════════════════════════════════════════

subtest 'deadline retries are capped at one' => sub {
    my $dir = "/tmp/clio-test-request-deadline-$$";
    `rm -rf $dir`;

    my $config = CLIO::Core::Config->new(config_dir => $dir);
    $config->set("provider", "llama.cpp", 0);
    $config->set("api_base", "http://127.0.0.1:8080/v1/chat/completions", 0);
    $config->set("model", "local-model", 0);
    $config->{config}->{api_keys}{'llama.cpp'} = "local";

    my $api = CLIO::Core::APIManager->new(debug => 0, config => $config);
    my $wo  = bless { api_manager => $api }, "CLIO::Core::WorkflowOrchestrator";

    my $response = {
        success         => 0,
        error           => 'CLIO stopped waiting for the model',
        user_message    => 'The model was still streaming when CLIO\'s 900s request ceiling expired.',
        retryable       => 1,
        retry_after     => 2,
        error_type      => 'request_timeout',
        partial_chars   => 15470,
    };

    my @sys_msgs;
    my $ctx_for = sub {
        my ($count) = @_;
        return {
            messages            => [],
            retry_count         => \(my $rc = $count),
            session_error_count => \(my $sec = 0),
            iteration           => 1,
            tool_calls_made     => [],
            session             => {},
            on_system_message   => sub { push @sys_msgs, $_[0] },
            max_retries         => 3,
            max_server_retries  => 3,
            max_session_errors  => 10,
            max_rate_limit_retries => 3,
        };
    };

    my $first = CLIO::Core::API::ErrorHandler::handle_api_error($wo, $response, $ctx_for->(0));
    is($first, 'retry', 'first deadline allows a retry');
    like($sys_msgs[-1], qr/request deadline.*attempt 1\/1/is,
        'system message names the deadline and shows the one-retry budget');

    my $second = CLIO::Core::API::ErrorHandler::handle_api_error($wo, $response, $ctx_for->(1));
    ok(ref $second, 'second deadline aborts instead of retrying again');
    is($second->{success}, 0, 'abort is a failure result');
    like($second->{error}, qr/will outrun it every time/, 'explains why retrying cannot help');
    like($second->{error}, qr/Raise the request timeout/, 'tells the user what to change');

    `rm -rf $dir`;
};

# ══════════════════════════════════════════════════════════════════════════
# 5. The curl transport reports why it stopped (exit 28 = deadline)
# ══════════════════════════════════════════════════════════════════════════

subtest 'curl streaming transport surfaces its exit code' => sub {
    my $curl = `command -v curl 2>/dev/null`;
    chomp $curl;
    plan skip_all => 'curl not available' unless $curl;

    require IO::Socket::INET;
    my $listener = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 0,
        Proto     => 'tcp',
        Listen    => 5,
        ReuseAddr => 1,
    );
    plan skip_all => 'cannot bind a local listener' unless $listener;
    my $port = $listener->sockport;

    # A listener that never accepts and never answers: curl connects, waits,
    # and --max-time fires. This is the same shape as a local model that is
    # still decoding when the deadline expires.
    my $http = CLIO::Compat::HTTP->new(timeout => 1);
    my $req  = CLIO::Compat::HTTP::Request->new('POST', "http://127.0.0.1:$port/hang");
    $req->header('content-type', 'application/json');
    $req->content('{}');

    my $started = time;
    my $resp = $http->request($req, sub { });
    my $elapsed = time - $started;

    is($resp->{status}, 599, 'a stalled connection becomes status 599');
    is($resp->{curl_exit}, 28, 'curl exit 28 is surfaced to the caller');
    like($resp->{reason} // '', qr/timed out/i, 'reason carries curl\'s explanation');
    ok(!$resp->{success}, 'not marked successful');
    ok($elapsed < 10, "gave up at the deadline, not later (${elapsed}s)");
    close $listener;
};

done_testing();
