#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

# Test: retry budgets, backoff curve, and retry messages agree
#
# The regression this guards: ErrorHandler used to build the retry message
# before applying exponential backoff, so a persistent 5xx announced
# "Retrying in 3s" on attempt 2 through 12 while the sleep in between grew
# to five minutes. The message and the behavior are now both computed by
# CLIO::Core::API::RetryPolicy from the same numbers, and this test asserts
# that what the user reads is what the code sleeps.

use strict;
use warnings;
use Test::More;
use lib './lib';

use CLIO::Core::API::RetryPolicy qw(
    budget delay describe format_delay
    is_transient is_rate_limited backoff_base
);

# Deterministic rng: 0.5 means jitter contributes exactly zero.
my $NO_JITTER_RNG = sub { 0.5 };

# ── Classification ────────────────────────────────────────────────────────

ok(is_transient($_), "is_transient($_)") for qw(server_error connection_error timeout overloaded truncated);
ok(!is_transient($_), "!is_transient($_)") for qw(rate_limit bad_request request_timeout foo '');

ok(is_rate_limited($_), "is_rate_limited($_)") for qw(rate_limit concurrency_limit);
ok(!is_rate_limited('server_error'), '!is_rate_limited(server_error)');

is(backoff_base('timeout'), 30, 'timeout backs off from 30s');
is(backoff_base('unknown_type'), 2, 'unknown class backs off from 2s');

# ── Budgets ───────────────────────────────────────────────────────────────

my $b = budget(error_type => 'server_error', max_server => 0);
is($b->{limit}, 0, 'server_error with max_server=0 has limit 0');
ok($b->{infinite}, 'server_error with max_server=0 retries forever');
is($b->{kind}, 'transient', 'server_error is a transient class');

$b = budget(error_type => 'server_error', max_server => 3);
ok(!$b->{infinite}, 'server_error with max_server=3 is bounded');
is($b->{limit}, 3, 'server_error with max_server=3 allows 3 retries');

$b = budget(error_type => 'rate_limit', max_rate_limit => 0);
ok($b->{infinite}, 'rate_limit with max_rate_limit=0 retries forever');
is($b->{kind}, 'rate_limit', 'rate_limit is a rate-limit class');

$b = budget(error_type => 'connection_error', max_server => 0);
ok($b->{infinite}, 'connection_error is covered by the transient budget');

$b = budget(error_type => 'request_timeout');
ok(!$b->{infinite}, 'a request that outran the ceiling is not retried forever');
is($b->{limit}, 1, 'request_timeout gets exactly one retry');

$b = budget(error_type => 'bad_request');
is($b->{kind}, 'bad_request', 'bad_request has its own budget');
is($b->{limit}, 4, 'bad_request allows four attempts');

$b = budget(error_type => 'malformed_tool_json', max_generic => 3);
is($b->{kind}, 'generic', 'unclassified errors use the generic budget');
is($b->{limit}, 3, 'generic budget defaults to 3');

# ── Backoff curve ─────────────────────────────────────────────────────────

my @server = map {
    delay(error_type => 'server_error', attempt => $_, rng => $NO_JITTER_RNG)
} 1 .. 6;
is_deeply(\@server, [2, 4, 8, 16, 32, 64],
    'server_error doubles from 2s, measured attempt by attempt');

my $capped = delay(error_type => 'server_error', attempt => 100, max_delay => 300, rng => $NO_JITTER_RNG);
is($capped, 300, 'backoff stops at the ceiling');

# Infinite budgets mean attempt can reach any number. 2**1024 is Inf, and
# Inf * 0 (jitter) is NaN, which would reach the UI as "NaNs".
my $far = delay(error_type => 'server_error', attempt => 100_000, rng => $NO_JITTER_RNG);
is($far, 300, 'attempt 100_000 still returns the ceiling, not Inf/NaN');

# A provider hint worth honoring is honored; one below our floor is not.
is(delay(error_type => 'server_error', attempt => 1, retry_after => 120, rng => $NO_JITTER_RNG),
   120, 'a Retry-After longer than the floor seeds the curve');
is(delay(error_type => 'server_error', attempt => 1, retry_after => 1, rng => $NO_JITTER_RNG),
   2, 'a Retry-After shorter than the floor is ignored');

# Jitter must never produce a wait below the floor.
my @jittered = map {
    delay(error_type => 'rate_limit', attempt => 1, retry_after => 0, jitter => 0.2)
} 1 .. 50;
ok(!(grep { $_ < 1 } @jittered), 'Retry-After: 0 cannot produce a zero-second hot loop');

# Rate limits honor the provider hint and do not grow exponentially.
is(delay(error_type => 'rate_limit', attempt => 9, retry_after => 42, jitter => 0),
   42, 'rate limit waits exactly Retry-After on the ninth attempt too');

my @rl_jittered = map {
    delay(error_type => 'rate_limit', attempt => 1, retry_after => 10, jitter => 0.5)
} 1 .. 50;
ok(!(grep { $_ < 10 } @rl_jittered),
    'rate-limit jitter is upward only: never sooner than the provider asked');

# ── Message formatting ────────────────────────────────────────────────────

is(format_delay(3), '3s', 'whole seconds render without a fraction');
is(format_delay(2.44), '2.4s', 'fractions render to one place');
is(format_delay(17.6), '18s', 'ten seconds and up drop the fraction');

my $msg = describe(
    label   => 'Server error',
    attempt => 3,
    budget  => { limit => 0, infinite => 1 },
    delay   => 17.25,
    detail  => 'HTTP 502',
    infinity => "\x{221e}",
);
is($msg, "Server error (HTTP 502). Retrying in 17s... (attempt 3/\x{221e})",
    'message states the real delay and the infinite budget');

$msg = describe(
    label   => 'Server error',
    attempt => 4,
    budget  => { limit => 3, infinite => 0 },
    delay   => 2,
);
is($msg, 'Server error. Retrying in 2s... (attempt 4/3)',
    'bounded message shows the bounded budget');

$msg = describe(label => 'Auth recovery', attempt => 1, budget => { limit => 3, infinite => 0 }, delay => 0);
like($msg, qr/Retrying immediately/, 'a zero wait is stated as immediate, not "in 0s"');

# The label must not have a verb bolted onto it: "Stream truncated detected"
# is not English, and the old code produced exactly that for every class.
like(describe(label => 'Stream truncated', attempt => 1, budget => { limit => 0, infinite => 1 }, delay => 2),
     qr/^Stream truncated\. Retrying/, 'labels end the sentence on their own');

# ── ErrorHandler integration: message matches the sleep ───────────────────

require CLIO::Core::API::ErrorHandler;

{
    # Capture what the retry path would have slept instead of sleeping it.
    # Must come after the require: the module defines this sub itself.
    no warnings 'redefine';
    *CLIO::Core::API::ErrorHandler::_interruptible_sleep = sub {
        my ($wo, $session, $seconds) = @_;
        push @main::SLEPT, $seconds;
    };
}

package FakeConfig;
sub new { bless { %{ $_[1] } }, $_[0] }
sub get { my ($s, $k) = @_; return $s->{$k} }

package FakeAPIManager;
sub new { bless { api_base => 'https://api.example.com/v1' }, $_[0] }
sub get_current_provider { return '' }

package FakeWO;
sub new {
    my ($class, %args) = @_;
    return bless {
        config      => FakeConfig->new($args{config} || {}),
        api_manager => FakeAPIManager->new,
    }, $class;
}

package main;

sub run_retries {
    my (%args) = @_;
    @main::SLEPT = ();
    my @shown;

    my $wo = FakeWO->new();
    my $messages = [
        { role => 'system', content => 'sys' },
        { role => 'user',   content => 'hello' },
    ];
    my $retry_count    = 0;
    my $session_errors = 0;

    my $ctx = {
        messages            => $messages,
        retry_count         => \$retry_count,
        session_error_count => \$session_errors,
        iteration           => 1,
        tool_calls_made     => 0,
        session             => undef,
        on_system_message   => sub { push @shown, $_[0] },
        max_retries            => 3,
        max_server_retries     => $args{max_server} // 0,
        max_rate_limit_retries => 0,
        max_session_errors     => 3,
    };

    my $result;
    for my $i (1 .. $args{attempts}) {
        $result = CLIO::Core::API::ErrorHandler::handle_api_error(
            $wo, { %{ $args{response} } }, $ctx);
        last unless defined $result && !ref $result && $result eq 'retry';
    }
    return (\@shown, \@main::SLEPT, $result);
}

my ($shown, $slept) = run_retries(
    attempts => 5,
    response => {
        success => 0, retryable => 1, error_type => 'server_error',
        http_status => 502, error => 'HTTP 502',
    },
);

is(scalar @$shown, 5, 'five failures produce five status messages');
is(scalar @$slept, 5, 'five failures produce five waits');

# The message's number must be the number slept, on every attempt. This is
# the assertion that fails if the message is built before backoff is applied.
#
# Above ten seconds the message rounds to whole seconds on purpose ("17s"
# reads better than "17.3s"), so the comparison allows that rounding and
# nothing more: an off-by-a-factor message still fails loudly.
for my $i (0 .. $#$shown) {
    my $n = $i + 1;
    my ($stated) = $shown->[$i] =~ /Retrying in (\d+(?:\.\d+)?)s/;
    ok(defined $stated, "attempt $n states a delay");
    my $tolerance = $stated >= 10 ? 0.5 : 0.05;
    ok(abs($slept->[$i] - $stated) <= $tolerance,
        "attempt $n: slept " . $slept->[$i] . "s, message said ${stated}s");
}

cmp_ok($slept->[4], '>', $slept->[0],
    'later attempts wait longer than the first (real backoff, not a fixed 3s)');
like($shown->[0], qr/attempt 1\/\x{221e}/,
    'an unbounded budget is shown as infinite, not as the generic max_retries');

# A bounded budget stops at the limit rather than looping.
my ($bounded_shown, $bounded_slept, $bounded_result) = run_retries(
    attempts => 10,
    max_server => 2,
    response => {
        success => 0, retryable => 1, error_type => 'server_error',
        http_status => 500, error => 'HTTP 500',
    },
);
is(scalar @$bounded_shown, 2, 'a 2-retry budget shows two waits');
ok(ref $bounded_result eq 'HASH' && !$bounded_result->{success},
    'a bounded budget ends the request instead of looping');

# The connectivity probe is skipped when the transport already named the
# failure. It costs two HTTP requests with a 10s ceiling each, which is
# longer than the first backoff it would precede.
my ($conn_shown, $conn_slept) = run_retries(
    attempts => 2,
    response => {
        success => 0, retryable => 1, error_type => 'connection_error',
        connection_subtype => 'dns_failure', error => 'DNS failure',
    },
);
like($conn_shown->[0], qr/hostname did not resolve/,
    'the connection message carries the transport subtype');
unlike($conn_shown->[0], qr/No network connectivity/,
    'no probe message when the subtype already explains the failure');

# A truncated stream reports how much arrived before the drop.
my ($tr_shown) = run_retries(
    attempts => 1,
    response => {
        success => 0, retryable => 1, error_type => 'truncated',
        tokens_received => 1200, error => 'no finish_reason',
    },
);
like($tr_shown->[0], qr/response ended after 1200 tokens/,
    'truncated stream retry says how much of the response arrived');

# ── Give-up message ───────────────────────────────────────────────────────
#
# When the budget runs out, the last thing the user reads must not promise a
# retry. ResponseHandler used to put the retry narration in the error string,
# so bailing produced "Maximum retries exceeded: Connection error: connection
# refused. Retrying..." - a promise and a surrender in one line.

{
    my (undef, undef, $result) = run_retries(
        attempts => 5,
        max_server => 2,
        response => {
            success => 0, retryable => 1, error_type => 'connection_error',
            http_status => 599, error => 'Connection error: connection refused',
        },
    );

    ok(ref $result eq 'HASH', 'an exhausted budget returns a failure result');
    is($result->{success}, 0, 'the failure result is marked unsuccessful');
    like($result->{error}, qr/Gave up after 2 retries/,
        'the give-up message states how many retries were spent');
    like($result->{error}, qr/retry_max_server_attempts/,
        'the give-up message names the knob that bounded it');
    unlike($result->{error}, qr/Retrying/,
        'the give-up message does not promise another retry');
}

# ── Config getters ────────────────────────────────────────────────────────
#
# The retry loop trusts these values enough to sleep on them, so a typo in
# the config file must not become a zero-second hot loop, a negative attempt
# budget, or a NaN sleep.

require CLIO::Core::Config;

{
    my $cfg = CLIO::Core::Config->new();

    is($cfg->get_retry_max_attempts, 3, 'generic attempt budget defaults to 3');
    is($cfg->get_retry_max_server_attempts, 0, 'server budget defaults to unlimited');
    is($cfg->get_retry_max_rate_limit_attempts, 0, 'rate-limit budget defaults to unlimited');
    is($cfg->get_retry_max_delay, 300, 'transient delay ceiling defaults to 300s');
    is($cfg->get_retry_rate_limit_max_delay, 900, 'rate-limit delay ceiling defaults to 900s');
    is($cfg->get_retry_jitter, 0.2, 'jitter defaults to 0.2');
    is($cfg->get_http_connect_timeout, 10, 'connect ceiling defaults to 10s');
    is($cfg->get_http_stall_timeout, 0, 'stall ceiling defaults to off');

    $cfg->{config}{retry_max_attempts}          = 7;
    $cfg->{config}{retry_max_server_attempts}   = 12;
    $cfg->{config}{retry_max_delay}             = 45;
    $cfg->{config}{retry_jitter}                = 0;
    $cfg->{config}{http_connect_timeout}        = 2.5;
    $cfg->{config}{http_stall_timeout}          = 60;

    is($cfg->get_retry_max_attempts, 7, 'configured generic budget is used');
    is($cfg->get_retry_max_server_attempts, 12, 'configured server budget is used');
    is($cfg->get_retry_max_delay, 45, 'configured delay ceiling is used');
    is($cfg->get_retry_jitter, 0, 'jitter can be turned off');
    is($cfg->get_http_connect_timeout, 2.5, 'fractional connect ceiling is accepted');
    is($cfg->get_http_stall_timeout, 60, 'stall ceiling is used when configured');

    # Garbage in the config file must not become garbage in a sleep().
    $cfg->{config}{retry_max_attempts}   = 'lots';
    $cfg->{config}{retry_max_delay}      = -5;
    $cfg->{config}{retry_jitter}         = 9;
    $cfg->{config}{http_connect_timeout} = 0;
    $cfg->{config}{retry_max_server_attempts} = 2.7;

    is($cfg->get_retry_max_attempts, 3, 'a non-numeric budget falls back to the default');
    is($cfg->get_retry_max_delay, 300, 'a negative delay falls back to the default');
    is($cfg->get_retry_jitter, 0.5, 'jitter above 0.5 is clamped');
    is($cfg->get_http_connect_timeout, 10, 'a zero connect ceiling falls back to the default');
    is($cfg->get_retry_max_server_attempts, 0,
        'a fractional attempt count is rejected rather than truncated');
}

# The ErrorHandler must read the ceiling through the Config getter, not
# straight out of the hash, or a bad value gets past the validation above.
{
    package GettersOnlyConfig;
    sub new { bless {}, shift }
    sub get { die "ErrorHandler must use the typed getter, not get()" }
    sub get_retry_max_delay { return 6 }
    sub get_retry_rate_limit_max_delay { return 11 }
    sub get_retry_jitter { return 0 }
}

{
    package GettersOnlyWO;
    sub new { bless { config => GettersOnlyConfig->new }, shift }
    sub _check_for_user_interrupt { return 0 }
    sub _handle_interrupt { return }
}

is(CLIO::Core::API::ErrorHandler::_retry_max_delay(GettersOnlyWO->new, 'server_error'),
    6, 'transient delay ceiling comes from the config getter');
is(CLIO::Core::API::ErrorHandler::_retry_max_delay(GettersOnlyWO->new, 'rate_limit'),
    11, 'rate-limit delay ceiling comes from the config getter');
is(CLIO::Core::API::ErrorHandler::_retry_jitter(GettersOnlyWO->new),
    0, 'jitter comes from the config getter');

# A config with no getters (a plain hash in older call sites) still works.
{
    package PlainConfig;
    sub new { bless { retry_max_delay => 9, retry_jitter => 0.4 }, shift }
    sub get { my ($self, $key) = @_; return $self->{$key} }
}

{
    package PlainWO;
    sub new { bless { config => PlainConfig->new }, shift }
}

is(CLIO::Core::API::ErrorHandler::_retry_max_delay(PlainWO->new, 'server_error'),
    9, 'a plain-hash config still supplies the delay ceiling');
is(CLIO::Core::API::ErrorHandler::_retry_jitter(PlainWO->new),
    0.4, 'a plain-hash config still supplies jitter');

done_testing();
