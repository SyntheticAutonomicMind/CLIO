#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Andrew Wyatt
#
# Regression tests for the ResponseHandler rate-limit-code bug:
#
#   Bug: _handle_error_response_impl used numeric == comparison on
#   $detected_rate_limit_code in the Z.AI code 1308/1310 branch and the
#   1302/1303/1305 branch. When a provider supplied a non-numeric string
#   code (e.g. GitHub Copilot's "user_global_rate_limited"), Perl's ==
#   operator coerced the string to 0 and emitted:
#
#       Argument "user_global_rate_limited" isn't numeric
#
#   under use warnings. The fix guards both elsif branches with
#   $detected_rate_limit_code =~ /^\d+$/ before the == comparison, so
#   non-numeric codes fall through to the string-code branches above.
#
# These tests verify:
#   - Non-numeric rate limit codes (1308/1302 branches) emit NO warning
#   - Numeric Z.AI codes (1308, 1310, 1302, 1303, 1305) still classify
#     correctly after the fix

use strict;
use warnings;
use utf8;
use lib './lib';
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Test::More;
use CLIO::Util::JSON qw(encode_json);
use CLIO::Core::API::ResponseHandler;

# ──────────────────────────────────────────────────────────────────────
# Mock fixtures (mirrors the pattern in test_provider_rate_limit_guards.pl)
# ──────────────────────────────────────────────────────────────────────

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
            code        => $opts{code} // 200,
            status_line => $opts{status_line} // "$opts{code} Error",
            content     => defined $opts{content} ? $opts{content} : '{}',
            headers     => $opts{headers} || MockHeaders->new(),
            message     => $opts{message} // '',
        }, $class;
    }
    sub code             { $_[0]->{code} }
    sub status_line      { $_[0]->{status_line} }
    sub decoded_content  { $_[0]->{content} }
    sub is_success       { $_[0]->{code} >= 200 && $_[0]->{code} < 300 }
    sub header            { return undef }
    sub headers           { $_[0]->{headers} }
    sub message           { $_[0]->{message} }
}

# Fake session with selected_model (needed for the 1308/1310 branch
# which reads _get_current_provider from session state).
{
    package FakeSession;
    sub new {
        my $class = shift;
        return bless {
            state => { selected_model => "zai-coder", selected_provider => "zai" },
        }, $class;
    }
    sub state { $_[0]->{state} }
}

# Helper: build a 429 response with a given error code.
sub make_429_resp {
    my ($code, $message) = @_;
    $message //= "Rate limited";
    my $body = encode_json({ error => { message => $message, code => $code } });
    return MockResponse->new(
        code        => 429,
        status_line => '429 Too Many Requests',
        content     => $body,
    );
}

# Helper: capture warnings emitted ONLY from CLIO source files.
# We filter by caller package path containing "lib/CLIO" so that
# Test::Builder assertion warnings (whose test names might contain the
# word "numeric") don't pollute the capture.
sub capture_clio_warnings {
    my ($code) = @_;
    my @warnings;
    local $SIG{__WARN__} = sub {
        my $msg = shift;
        # Only capture warnings from CLIO source files
        my (undef, $file) = caller(0);
        if (defined $file && $file =~ m{lib/CLIO}) {
            push @warnings, $msg;
        }
    };
    $code->();
    return @warnings;
}

# Helper: call handle_error_response and return (result, warnings)
sub call_handler {
    my ($handler, $resp) = @_;
    my $result;
    my @warnings = capture_clio_warnings(sub {
        $result = $handler->handle_error_response($resp, "{}", 0);
    });
    return ($result, @warnings);
}

# ──────────────────────────────────────────────────────────────────────
# Test 1: Non-numeric string rate limit code does not trigger
#         "isn't numeric" warnings.
#
# Before the fix, codes like "user_global_rate_limited" (a Copilot string
# code that falls through the weekly/monthly regex) would hit the ==
# comparisons in the 1308/1302 elsif branches, coercing the string to 0
# and emitting a warning.
# ──────────────────────────────────────────────────────────────────────

subtest 'Non-numeric rate limit code emits no numeric-comparison warning' => sub {
    # user_global_rate_limited: a Copilot string code that is NOT
    # user_weekly_rate_limited or user_monthly_rate_limited, so it
    # previously fell through to the == comparison branches.
    my $handler = CLIO::Core::API::ResponseHandler->new(session => FakeSession->new());
    my $resp = make_429_resp('user_global_rate_limited');
    my ($result, @warnings) = call_handler($handler, $resp);

    ok($result->{success} == 0, 'Result is failure');
    is($result->{error_type}, 'rate_limit', 'Error type is rate_limit');

    my @numeric_warnings = grep { /isn't numeric/i } @warnings;
    is(scalar(@numeric_warnings), 0,
        'No numeric-comparison warning for user_global_rate_limited');

    # Test other non-numeric string codes that providers may send
    for my $code_str (qw(user_model_rate_limited upstream_provider_rate_limit
                         integration_rate_limited agent_mode_limit_exceeded
                         zai_usage_limit some_unknown_code)) {
        my $h = CLIO::Core::API::ResponseHandler->new(session => FakeSession->new());
        my $r = make_429_resp($code_str);
        my ($res, @w) = call_handler($h, $r);

        my @nw = grep { /isn't numeric/i } @w;
        is(scalar(@nw), 0,
            "No numeric-comparison warning for code: $code_str");
    }
};

# ──────────────────────────────────────────────────────────────────────
# Test 2: Numeric Z.AI codes still classify correctly after the fix.
#   The /^\d+$/ guard must NOT prevent legitimate numeric codes from
#   being matched.
# ──────────────────────────────────────────────────────────────────────

subtest 'Numeric Z.AI code 1308 -> non-retryable usage limit' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new(session => FakeSession->new());
    my $resp = make_429_resp(1308, "Usage limit reached for 5 hour. Your limit will reset at 2026-04-17 07:03:43");
    my ($result, @warnings) = call_handler($handler, $resp);

    ok($result->{success} == 0, 'Result is failure');
    is($result->{retryable}, 0, '1308 is non-retryable');
    is($result->{error_type}, 'rate_limit', 'Error type is rate_limit');
    like($result->{error}, qr/Z\.AI usage limit/i, 'Error mentions Z.AI usage limit');

    my @nw = grep { /isn't numeric/i } @warnings;
    is(scalar(@nw), 0, 'No numeric-comparison warning for code 1308');
};

subtest 'Numeric Z.AI code 1310 -> non-retryable weekly/monthly limit' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new(session => FakeSession->new());
    my $resp = make_429_resp(1310, "Weekly/Monthly Limit Exhausted. Your limit will reset at 2026-04-24 02:02:21");
    my ($result, @warnings) = call_handler($handler, $resp);

    ok($result->{success} == 0, 'Result is failure');
    is($result->{retryable}, 0, '1310 is non-retryable');
    is($result->{error_type}, 'rate_limit', 'Error type is rate_limit');
    like($result->{error}, qr/Z\.AI usage limit/i, 'Error mentions Z.AI usage limit');

    my @nw = grep { /isn't numeric/i } @warnings;
    is(scalar(@nw), 0, 'No numeric-comparison warning for code 1310');
};

subtest 'Numeric Z.AI code 1302 -> retryable concurrency limit' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = make_429_resp(1302, "High concurrency detected");
    my ($result, @warnings) = call_handler($handler, $resp);

    ok($result->{success} == 0, 'Result is failure');
    is($result->{retryable}, 1, '1302 is retryable');
    is($result->{retry_after}, 3, '1302 retry_after is 3 seconds');
    like($result->{error}, qr/Z\.AI concurrency/i, 'Error mentions Z.AI concurrency limit');

    my @nw = grep { /isn't numeric/i } @warnings;
    is(scalar(@nw), 0, 'No numeric-comparison warning for code 1302');
};

subtest 'Numeric Z.AI code 1303 -> retryable frequency limit' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = make_429_resp(1303, "High frequency detected");
    my ($result, @warnings) = call_handler($handler, $resp);

    ok($result->{success} == 0, 'Result is failure');
    is($result->{retryable}, 1, '1303 is retryable');
    is($result->{retry_after}, 5, '1303 retry_after is 5 seconds');
    like($result->{error}, qr/Z\.AI frequency/i, 'Error mentions Z.AI frequency limit');

    my @nw = grep { /isn't numeric/i } @warnings;
    is(scalar(@nw), 0, 'No numeric-comparison warning for code 1303');
};

subtest 'Numeric Z.AI code 1305 -> retryable general rate limit' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();
    my $resp = make_429_resp(1305, "Rate limit exceeded");
    my ($result, @warnings) = call_handler($handler, $resp);

    ok($result->{success} == 0, 'Result is failure');
    is($result->{retryable}, 1, '1305 is retryable');
    is($result->{retry_after}, 30, '1305 retry_after is 30 seconds');
    like($result->{error}, qr/Z\.AI.*limit/i, 'Error mentions Z.AI rate limit');

    my @nw = grep { /isn't numeric/i } @warnings;
    is(scalar(@nw), 0, 'No numeric-comparison warning for code 1305');
};

done_testing();
