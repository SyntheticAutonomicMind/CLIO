#!/usr/bin/env perl

# SPDX-License-Identifier: GPL-3.0-or-later
# Tests for Anthropic rate-limit awareness: header parsing, friendly code
# mapping, RFC 3339 reset normalization, and token-bucket preflight throttle.

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use lib "$RealBin/../lib";
use Test::More;

use CLIO::Util::RateLimit qw(
    get_rate_limit_type_name
    parse_anthropic_reset_timestamp
);
use CLIO::Core::API::ResponseHandler;

# =============================================================================
# Section 1: Util::RateLimit friendly code mapping
# =============================================================================
subtest 'get_rate_limit_type_name maps Anthropic bucket codes' => sub {
    is(get_rate_limit_type_name('RateLimitReached'), 'Anthropic rate limit',
        "RateLimitReached -> Anthropic rate limit");
    is(get_rate_limit_type_name('UserByModelByMinuteUncachedInputTokens'),
        'Anthropic uncached input token limit (ITPM)',
        "UserByModelByMinuteUncachedInputTokens -> ITPM");
    is(get_rate_limit_type_name('UserByModelByMinuteUncachedOutputTokens'),
        'Anthropic uncached output token limit (OTPM)',
        "UserByModelByMinuteUncachedOutputTokens -> OTPM");
    is(get_rate_limit_type_name('UserByModelByMinuteInputTokens'),
        'Anthropic input token limit (ITPM)',
        "UserByModelByMinuteInputTokens -> ITPM (cache reads counted)");
    is(get_rate_limit_type_name('UserByModelByMinuteOutputTokens'),
        'Anthropic output token limit (OTPM)',
        "UserByModelByMinuteOutputTokens -> OTPM (cache reads counted)");
    is(get_rate_limit_type_name('UserByModelByMinuteRequests'),
        'Anthropic request rate limit (RPM)',
        "UserByModelByMinuteRequests -> RPM");
    is(get_rate_limit_type_name('anthropic-ratelimit-requests-remaining'),
        'Anthropic rate limit',
        "anthropic-ratelimit-* header code -> Anthropic rate limit");
    # Generic rate limit unknown code falls back
    is(get_rate_limit_type_name('user_global_rate_limited'), 'Global rate limit',
        "GitHub-style code still maps to its existing label");
};

# =============================================================================
# Section 2: RFC 3339 reset parser
# =============================================================================
subtest 'parse_anthropic_reset_timestamp recognises RFC 3339 variants' => sub {
    # 2 minutes in the future. Use gmtime to keep the produced timestamp in
    # UTC - we tag the string with `Z` so the parser MUST treat it as UTC.
    my $future_z = POSIX::strftime('%Y-%m-%dT%H:%M:%SZ', gmtime(time() + 120));
    my $secs = parse_anthropic_reset_timestamp($future_z);
    ok(defined $secs, "Parses ISO Z-suffixed timestamp: $future_z");
    cmp_ok($secs, '>=', 110, "  value is at least 110 seconds");
    cmp_ok($secs, '<=', 130, "  value is at most 130 seconds");

    # UTC offset (e.g. +02:00). Construct from gmtime so the offset relative
    # to UTC is well-defined (the parser subtracts the offset to recover UTC).
    my $future_p2 = POSIX::strftime('%Y-%m-%dT%H:%M:%S+02:00', gmtime(time() + 300));
    my $secs2 = parse_anthropic_reset_timestamp($future_p2);
    ok(defined $secs2, "Parses +HH:MM offset timestamp: $future_p2");
    cmp_ok($secs2, '>=', 280, "  value is at least 280 seconds");

    # Compressed offset (e.g. -0500)
    my $future_m5 = POSIX::strftime('%Y-%m-%dT%H:%M:%S-0500', gmtime(time() + 180));
    my $secs3 = parse_anthropic_reset_timestamp($future_m5);
    ok(defined $secs3, "Parses -HHMM offset timestamp: $future_m5");

    # Already in the past -> 0 (clamped)
    my $past = POSIX::strftime('%Y-%m-%dT%H:%M:%SZ', gmtime(time() - 60));
    is(parse_anthropic_reset_timestamp($past), 0, "Past timestamps clamp to 0");

    # Garbage input -> undef
    is(parse_anthropic_reset_timestamp("not a date"), undef,
        "Garbage input returns undef");
    is(parse_anthropic_reset_timestamp(undef),   undef,
        "undef returns undef");
    is(parse_anthropic_reset_timestamp(""),      undef,
        "Empty string returns undef");
};

# =============================================================================
# Section 3: ResponseHandler parses Anthropic headers + feeds throttle signals
# =============================================================================
subtest 'ResponseHandler extracts Anthropic ITPM/OTPM/RPM headers' => sub {
    my $handler = CLIO::Core::API::ResponseHandler->new();

    # Mock HTTP::Headers-style object
    my %headers;
    my $hdr = bless \%headers, 'MockAnthropicHeaders';

    # Define behavior inline (avoid a second package declaration)
    {
        package MockAnthropicHeaders;
        sub new { bless {}, $_[0] }
        sub scan { my ($s, $cb) = @_; $cb->('anthropic-ratelimit-requests-limit', '1000'); $cb->('anthropic-ratelimit-requests-remaining', '950'); $cb->('anthropic-ratelimit-requests-reset', POSIX::strftime('%Y-%m-%dT%H:%M:%SZ', localtime(time() + 50))); $cb->('anthropic-ratelimit-input-tokens-limit', '250000'); $cb->('anthropic-ratelimit-input-tokens-remaining', '75000'); $cb->('anthropic-ratelimit-input-tokens-reset', POSIX::strftime('%Y-%m-%dT%H:%M:%SZ', localtime(time() + 40))); $cb->('anthropic-ratelimit-output-tokens-limit', '50000'); $cb->('anthropic-ratelimit-output-tokens-remaining', '48000'); $cb->('anthropic-ratelimit-output-tokens-reset', POSIX::strftime('%Y-%m-%dT%H:%M:%SZ', localtime(time() + 30))); }
    }

    my $result = $handler->process_rate_limit_headers($hdr);
    ok(ref($result) eq 'HASH', 'process_rate_limit_headers returns hash');

    my $info = $result->{rate_limit_info};
    ok(ref($info) eq 'HASH', 'rate_limit_info is a hash');
    is($info->{anthropic_input_tokens_limit}, '250000', 'ITPM limit captured');
    is($info->{anthropic_input_tokens_remaining}, '75000', 'ITPM remaining captured');
    is($info->{anthropic_output_tokens_limit}, '50000', 'OTPM limit captured');
    is($info->{anthropic_requests_limit}, '1000', 'RPM limit captured');

    # _rate_limit_reset_in should reflect the soonest Anthropic reset
    ok(defined $handler->{_rate_limit_reset_in},
        "_rate_limit_reset_in was set from the Anthropic reset headers");
    cmp_ok($handler->{_rate_limit_reset_in}, '<=', 50,
        "  _rate_limit_reset_in is within 50s of now (matches soonest header)");
};

# =============================================================================
# Section 4: CLIO::Diagnostics display_rate_limit_info recognises Anthropic
# =============================================================================
subtest 'Diagnostics.display_rate_limit_info surfaces Anthropic ITPM/OTPM/RPM' => sub {
    require CLIO::Core::Diagnostics;
    my $diag = CLIO::Core::Diagnostics->can('display_rate_limit_info') ? 'CLIO::Core::Diagnostics' : undef;
    ok($diag, 'Diagnostics module loaded');

    my $msg = CLIO::Core::Diagnostics::display_rate_limit_info('UserByModelByMinuteUncachedInputTokens', 45);
    like($msg, qr/Anthropic/i, 'Message mentions Anthropic');
    like($msg, qr/ITPM/i,       'Message mentions ITPM');
    like($msg, qr/45 second/,   'Message uses the supplied retry-after');

    my $msg_otpm = CLIO::Core::Diagnostics::display_rate_limit_info('UserByModelByMinuteUncachedOutputTokens', undef);
    like($msg_otpm, qr/OTPM/i, 'Output token message mentions OTPM');
    like($msg_otpm, qr/shortly/i, 'Falls back to default reset phrase when no retry_after supplied');

    my $msg_rpm = CLIO::Core::Diagnostics::display_rate_limit_info('UserByModelByMinuteRequests', 20);
    like($msg_rpm, qr/RPM/i, 'RPM message mentions RPM');

    my $msg_generic = CLIO::Core::Diagnostics::display_rate_limit_info('RateLimitReached', 5);
    like($msg_generic, qr/Anthropic/i, 'RateLimitReached code produces Anthropic-aware message');
};

done_testing();
