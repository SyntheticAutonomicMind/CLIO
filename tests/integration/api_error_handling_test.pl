#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

=head1 NAME

api_error_handling_test.pl - API error classification tests

=head1 DESCRIPTION

Verifies how CLIO classifies API errors, because the classification decides
whether an error is retried, whether model routing treats it as actionable, and
whether the session error budget is spent on it.

This suite is hermetic: it needs no network access and no configured API key.
Everything is exercised through in-process calls with synthetic responses.

The regression it guards: an unconfigured API key used to be reported as a bare
error with neither C<retryable> nor C<error_type> set, so it fell through to the
generic retry path and was attempted repeatedly before finally surfacing. Each
attempt also incremented the session error counter, so the eventual message told
the user to start a new session because the budget was exhausted.

=cut

use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use Test::More;
use CLIO::Core::Config;
use CLIO::Core::APIManager;
use CLIO::Core::API::ErrorHandler;

# ── Missing credential is permanent ──────────────────────────────────────────
{
    my $config = CLIO::Core::Config->new();
    $config->set('provider', 'openai', 0);
    # Test-mode Config points at an empty temp directory, so provider defaults
    # are not derived from a file. Set the endpoint explicitly to keep this
    # hermetic and to let APIManager construct.
    $config->set('api_base', 'https://api.openai.com/v1/chat/completions', 0);
    $config->set('model',    'openai/gpt-4.1', 0);

    my $api = CLIO::Core::APIManager->new(config => $config, debug => 0);
    $api->{api_key} = undef;

    my $result = eval { $api->send_request(messages => [{ role => 'user', content => 'hi' }]) };
    is($@, '', 'send_request does not die without an API key');
    is(ref $result, 'HASH', 'a structured error is returned');

    is($result->{success}, 0, 'the result reports failure');
    is($result->{retryable}, 0,
        'a missing API key is not retryable - no retry can produce a key');
    is($result->{error_type}, 'auth_failed',
        'a missing API key is classified as auth_failed');

    like($result->{error}, qr/API key/i,
        'the message tells the user what is missing');
    like($result->{error}, qr{/api},
        'the message names the command that fixes it');
}

# ── Routing treats account-level failures as non-actionable ─────────────────
# Cycling to another model cannot conjure a credential or a balance, so these
# must not consume routing attempts.
{
    my @account_level = (
        ['auth_failed',         'auth_failed'],
        ['billing_error',       'billing_error'],
        ['model_not_found',     'model_not_found'],
        ['account_disabled',    'account_disabled'],
        ['region_unavailable',  'region_unavailable'],
        ['token_limit_exceeded','token_limit_exceeded'],
        ['user_interrupt',      'user_interrupt'],
    );

    for my $case (@account_level) {
        my ($type, $label) = @$case;
        ok(CLIO::Core::API::ErrorHandler::_routing_should_skip({ error_type => $type }),
            "routing is skipped for $label");
    }
}

# ── Transient conditions stay routable ──────────────────────────────────────
# A different provider may well answer when one is rate limited or degraded.
{
    for my $type (qw(rate_limit server_error connection_error timeout provider_unavailable)) {
        ok(!CLIO::Core::API::ErrorHandler::_routing_should_skip({ error_type => $type }),
            "routing is still attempted for $type");
    }
}

# ── An unknown error is not silently treated as non-actionable ──────────────
{
    ok(!CLIO::Core::API::ErrorHandler::_routing_should_skip({ error_type => 'something_new' }),
        'an unrecognized error type does not skip routing');
    ok(!CLIO::Core::API::ErrorHandler::_routing_should_skip({}),
        'an error with no type does not skip routing');
}

# ── Weekly and monthly caps are account-level regardless of error type ──────
{
    ok(CLIO::Core::API::ErrorHandler::_routing_should_skip({
            error_type      => 'rate_limit',
            rate_limit_code => 'user_weekly_rate_limited',
        }),
        'a weekly usage cap skips routing');
    ok(CLIO::Core::API::ErrorHandler::_routing_should_skip({
            error_type      => 'rate_limit',
            rate_limit_code => 'user_monthly_rate_limited',
        }),
        'a monthly usage cap skips routing');
    ok(!CLIO::Core::API::ErrorHandler::_routing_should_skip({
            error_type      => 'rate_limit',
            rate_limit_code => 'per_minute',
        }),
        'an ordinary per-minute limit stays routable');
}

done_testing();
