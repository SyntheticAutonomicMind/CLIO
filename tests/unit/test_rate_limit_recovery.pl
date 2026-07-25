#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 fewtarius
#
# Regression tests for the rate-limit recovery bug:
#
#   1. _finalize_streaming_response must release the rate limiter slot in
#      BOTH early-return paths (the eval-exception $s{error} path and the
#      SSE error chunk path). Before the fix, a leaked slot would pin the
#      per-provider concurrency counter at the limit, so every retry of
#      the original request hit "Concurrency limit reached for $provider"
#      and exhausted the 3-retry budget.
#
#   2. ErrorHandler must treat error_type=concurrency_limit the same as
#      error_type=rate_limit - same infinite-retry budget, same
#      "Rate limit detected" user-facing label. Before the fix it fell
#      into the generic 3-retry bucket and any session that briefly had
#      two in-flight requests to the same provider died with
#      "Maximum retries exceeded: Concurrency limit reached for $provider".

use strict;
use warnings;
use utf8;
use lib './lib';
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Test::More;
use CLIO::Core::APIManager;
use CLIO::Core::API::ErrorHandler;
use CLIO::UI::Terminal qw(ui_char);

# ──────────────────────────────────────────────────────────────────────
# Test fixtures
# ──────────────────────────────────────────────────────────────────────

# Recording stubs - we want to assert *what* was called, not just that
# something was called. Tracked calls lets us prove the rate limiter
# release happens on the early-return paths.
{
    package RecordStub;
    sub new { bless { calls => [] }, shift }
    sub record { my ($self, $name, @args) = @_; push @{$self->{calls}}, { name => $name, args => \@args }; }
    sub calls { my ($self, $name) = @_;
        return $self->{calls} unless defined $name;
        return [grep { $_->{name} eq $name } @{$self->{calls}}];
    }
}

# Stub response_handler that records broker releases.
{
    package StubRH;
    sub new { bless { record => RecordStub->new() }, shift }
    sub record { return $_[0]->{record} }
    sub release_broker_slot { my ($self, @args) = @_; $self->{record}->record('release_broker_slot', @args); }
    sub report_rate_limit_for_model { my ($self, @args) = @_; $self->{record}->record('report_rate_limit_for_model', @args); }
    sub process_rate_limit_headers { return undef }
    sub process_quota_headers { return undef }
    sub store_stateful_marker { }
    sub get_stateful_marker_for_model { return undef }
    sub set_apimanager { }
    sub set_session { }
    sub set_broker_request_id { }
    sub set_last_request_model { }
    sub handle_error_response { return { success => 0, error => 'stub' } }
}

# Stub rate_limiter that records releases.
{
    package StubRL;
    sub new { bless { record => RecordStub->new() }, shift }
    sub record { return $_[0]->{record} }
    sub release { my ($self, @args) = @_; $self->{record}->record('release', @args); }
    sub update_from_headers {}
    sub get_max_concurrent { 2 }
}

# Minimal fake HTTP response - same shape used by test_sse_error_surfacing.pl.
sub fake_resp {
    return bless { headers => bless {}, 'FakeResp' }, 'FakeResp';
}
sub FakeResp::headers { return $_[0]->{headers}; }
sub FakeResp::code { return $_[0]->{code} // 200; }
sub FakeResp::status_line { return $_[0]->{status_line} // '200 OK'; }
sub FakeResp::decoded_content { return $_[0]->{decoded_content} // ''; }

sub make_am {
    my (%overrides) = @_;
    return bless({
        response_handler => StubRH->new(),
        rate_limiter     => StubRL->new(),
        session          => undef,
        %overrides,
    }, 'CLIO::Core::APIManager');
}

# ──────────────────────────────────────────────────────────────────────
# Bug 1a: $s{error} early-return path releases the rate limiter slot
# ──────────────────────────────────────────────────────────────────────

subtest 'Bug 1a: $s{error} early-return path releases rate limiter slot' => sub {
    my $am = make_am();

    # Streaming state with provider_label set (set by send_request_streaming
    # before the eval that produced $s{error}) and $s{error} populated to
    # trigger the eval-exception branch.
    my $s = {
        error               => 'eval died: connection reset by peer',
        resp                => fake_resp(),
        accumulated_content => '',
        accumulated_reasoning => '',
        streaming_usage     => undef,
        streaming_headers   => bless({}, 'FakeResp'),
        token_count         => 0,
        start_time          => time(),
        first_token_time    => undef,
        tool_calls_accumulator => {},
        raw_response_body   => '',
        buffer              => '',
        model               => 'nvidia/nemotron-3-ultra-550b-a55b',
        endpoint_config     => {},
        provider_label      => 'nvidia',
        messages            => [],
        input               => undef,
        json                => '',
        _sse_error          => undef,
        _finish_reason      => undef,
    };

    my $result = $am->_finalize_streaming_response(%$s);

    ok(!$result->{success}, 'eval-exception path returns success=0');
    ok($result->{retryable}, 'eval-exception path returns retryable=1');

    # The fix: rate_limiter->release must be called for the provider before
    # the early return. Without it, the slot is permanently leaked.
    my $releases = $am->{rate_limiter}->record->calls('release');
    cmp_ok(scalar @$releases, '>=', 1,
        'eval-exception path releases rate limiter slot');
    is($releases->[0]{args}[0], 'nvidia',
        'eval-exception path releases slot for the correct provider (lowercased)');
};

# ──────────────────────────────────────────────────────────────────────
# Bug 1b: SSE error early-return path releases the rate limiter slot
# ──────────────────────────────────────────────────────────────────────

subtest 'Bug 1b: SSE error path releases rate limiter slot' => sub {
    my $am = make_am();

    # NVIDIA NIM pattern - SSE error chunk on first chunk, before any
    # content or tool_calls were streamed. No finish_reason.
    my $s = {
        error               => undef,
        resp                => fake_resp(),
        accumulated_content => '',
        accumulated_reasoning => '',
        streaming_usage     => undef,
        streaming_headers   => bless({}, 'FakeResp'),
        token_count         => 0,
        start_time          => time(),
        first_token_time    => undef,
        tool_calls_accumulator => {},
        raw_response_body   => '',
        buffer              => '',
        model               => 'nvidia/nemotron-3-ultra-550b-a55b',
        endpoint_config     => {},
        provider_label      => 'nvidia',
        messages            => [],
        input               => undef,
        json                => '',
        _sse_error          => {
            message => 'ResourceExhausted: Worker local total request limit reached (157/32)',
            code    => '500',
        },
        _finish_reason      => undef,
    };

    my $result = $am->_finalize_streaming_response(%$s);

    ok(!$result->{success}, 'SSE error path returns success=0');
    ok($result->{retryable}, 'SSE error path returns retryable=1');
    is($result->{error_type}, 'rate_limit',
        'SSE error with ResourceExhausted message is classified as rate_limit');

    # The fix: rate_limiter->release must be called before the SSE error
    # early-return. Without it, the slot is permanently leaked and every
    # subsequent request to nvidia sees 2/2 occupied.
    my $releases = $am->{rate_limiter}->record->calls('release');
    cmp_ok(scalar @$releases, '>=', 1,
        'SSE error path releases rate limiter slot');
    is($releases->[0]{args}[0], 'nvidia',
        'SSE error path releases slot for the correct provider (lowercased)');
};

# ──────────────────────────────────────────────────────────────────────
# Bug 1c: SSE error after content streamed but no finish_reason also
# releases the slot (the MiniMax silent-truncation case)
# ──────────────────────────────────────────────────────────────────────

subtest 'Bug 1c: mid-stream SSE error (no finish_reason) releases rate limiter slot' => sub {
    my $am = make_am();

    my $s = {
        error               => undef,
        resp                => fake_resp(),
        accumulated_content => 'partial answer that got truncated',
        accumulated_reasoning => '',
        streaming_usage     => undef,
        streaming_headers   => bless({}, 'FakeResp'),
        token_count         => 5,
        start_time          => time() - 3,
        first_token_time    => time() - 2,
        tool_calls_accumulator => {},
        raw_response_body   => '',
        buffer              => '',
        model               => 'minimax/MiniMax-M3',
        endpoint_config     => {},
        provider_label      => 'MiniMax',
        messages            => [],
        input               => undef,
        json                => '',
        _sse_error          => {
            message => 'upstream connection reset',
            code    => 'overloaded',
        },
        _finish_reason      => undef,
    };

    my $result = $am->_finalize_streaming_response(%$s);

    ok(!$result->{success}, 'mid-stream SSE error returns success=0');
    is($result->{error_type}, 'overloaded',
        'mid-stream SSE error classified correctly');

    my $releases = $am->{rate_limiter}->record->calls('release');
    cmp_ok(scalar @$releases, '>=', 1,
        'mid-stream SSE error path releases rate limiter slot');
    is($releases->[0]{args}[0], 'minimax',
        'mid-stream SSE error releases slot for the correct provider (lowercased)');
};

# ──────────────────────────────────────────────────────────────────────
# Bug 1d: SSE error ignored when finish_reason was received must still
# release the slot - the success path owns that release, not the early
# return. Verify the legitimate-success path still works.
# ──────────────────────────────────────────────────────────────────────

subtest 'Bug 1d: legitimate success (finish_reason=stop, no SSE error) releases slot' => sub {
    my $am = make_am();

    my $s = {
        error               => undef,
        resp                => fake_resp(),
        accumulated_content => 'complete answer',
        accumulated_reasoning => '',
        streaming_usage     => undef,
        streaming_headers   => bless({}, 'FakeResp'),
        token_count         => 5,
        start_time          => time() - 3,
        first_token_time    => time() - 2,
        tool_calls_accumulator => {},
        raw_response_body   => '',
        buffer              => '',
        model               => 'minimax/MiniMax-M3',
        endpoint_config     => {},
        provider_label      => 'minimax',
        messages            => [],
        input               => undef,
        json                => '',
        _sse_error          => undef,
        _finish_reason      => 'stop',
    };

    my $result = $am->_finalize_streaming_response(%$s);

    ok($result->{success}, 'success path returns success=1');

    # The success path is unchanged - it was always releasing. Verify it
    # still does so.
    my $releases = $am->{rate_limiter}->record->calls('release');
    cmp_ok(scalar @$releases, '>=', 1,
        'success path still releases rate limiter slot');
    is($releases->[0]{args}[0], 'minimax',
        'success path releases slot for the correct provider (lowercased)');
};

# ──────────────────────────────────────────────────────────────────────
# Bug 2: ErrorHandler classifies concurrency_limit as rate_limit
# ──────────────────────────────────────────────────────────────────────

# Direct-invocation tests for ErrorHandler::handle_api_error with the
# concurrency_limit error_type shape. We can't trivially spin up a real
# WorkflowOrchestrator, so we hand-craft the $ctx hashref the same way
# WorkflowOrchestrator does (see CLIO/Core/WorkflowOrchestrator.pm ~670).
{
    package StubWO;
    # Minimal stand-in for the WorkflowOrchestrator methods ErrorHandler touches.
    sub new {
        my $class = shift;
        return bless {
            api_manager          => undef,
            tool_registry        => StubTR->new(),
            last_error           => undef,
            consecutive_errors   => 0,
            max_consecutive_errors => 10,
            @_,
        }, $class;
    }
    sub _check_for_user_interrupt { return 0 }
    sub _handle_interrupt { return }

    package StubTR;
    sub new { bless {}, shift }
    sub get_tool { return undef }
}

{
    package StubSession;
    sub new { bless { _error_count => 0 }, shift }
    sub can { return 0 }  # No methods ErrorHandler calls.
}

sub call_handle_api_error {
    my %args = @_;
    my $wo = StubWO->new();
    my $session = StubSession->new();
    my $retry_count = 0;
    my $session_error_count = 0;

    my $ctx = {
        messages            => [],
        retry_count         => \$retry_count,
        session_error_count => \$session_error_count,
        iteration           => 1,
        tool_calls_made     => [],
        session             => $session,
        on_system_message   => $args{on_system_message} || sub {},
        max_retries         => 3,
        max_server_retries  => 0,   # infinite
        max_session_errors  => 50,
        max_rate_limit_retries => 0, # infinite
    };

    return CLIO::Core::API::ErrorHandler::handle_api_error(
        $wo, $args{api_response}, $ctx
    );
}

subtest 'Bug 2a: concurrency_limit is retryable with infinite budget' => sub {
    # Simulate the response from send_request_streaming when rate_limiter
    # acquire() returns 0 (CLIO local concurrency limit hit).
    my $result = call_handle_api_error(
        api_response => {
            success    => 0,
            error      => 'Concurrency limit reached for nvidia, please try again',
            retryable  => 1,
            retry_after => 1,
            error_type => 'concurrency_limit',
        }
    );

    # handle_api_error returns 'retry' for retryable errors. Before the fix
    # it would bail with "Maximum retries exceeded" after only 3 attempts
    # because concurrency_limit fell into the generic else branch.
    is($result, 'retry',
        'concurrency_limit returns retry (not Maximum retries exceeded)');
};

subtest 'Bug 2b: concurrency_limit surfaces "Rate limit detected" to UI' => sub {
    my $msg;
    my $result = call_handle_api_error(
        api_response => {
            success    => 0,
            error      => 'Concurrency limit reached for nvidia, please try again',
            retryable  => 1,
            retry_after => 5,
            error_type => 'concurrency_limit',
        },
        on_system_message => sub { $msg = shift; }
    );

    is($result, 'retry', 'returns retry');
    like($msg, qr/Rate limit detected/i,
        'system message uses "Rate limit detected" label (not "Server error")');
    like($msg, qr/attempt 1/, 'first attempt logged as attempt 1');
};

subtest 'Bug 2c: concurrency_limit has infinite retry budget (no max-attempts cap)' => sub {
    # The previous behavior capped concurrency_limit at max_retries=3 and
    # gave up. After the fix it inherits rate_limit's infinite retry
    # budget (max_rate_limit_retries=0 means unlimited). Verify that even
    # at attempt 50 (well past max_retries=3) we still get 'retry'.
    my $wo = StubWO->new();
    my $session = StubSession->new();
    my $retry_count = 50; # Pretend we've already failed 50 times.
    my $session_error_count = 0;

    my $ctx = {
        messages            => [],
        retry_count         => \$retry_count,
        session_error_count => \$session_error_count,
        iteration           => 1,
        tool_calls_made     => [],
        session             => $session,
        on_system_message   => sub {},
        max_retries         => 3,
        max_server_retries  => 0,
        max_session_errors  => 50,
        max_rate_limit_retries => 0,
    };

    my $result = CLIO::Core::API::ErrorHandler::handle_api_error(
        $wo,
        {
            success    => 0,
            error      => 'Concurrency limit reached for nvidia, please try again',
            retryable  => 1,
            retry_after => 1,
            error_type => 'concurrency_limit',
        },
        $ctx
    );

    is($result, 'retry',
        'concurrency_limit does NOT bail at attempt 50 (infinite retry budget)');
};

subtest 'Bug 2d: rate_limit and concurrency_limit get the same retry budget' => sub {
    # Verify rate_limit still works the same way (regression guard).
    my $result = call_handle_api_error(
        api_response => {
            success      => 0,
            error        => 'Rate limit exceeded',
            retryable    => 1,
            retry_after  => 30,
            error_type   => 'rate_limit',
            rate_limit_code => 'rate_limit_exceeded',
        }
    );

    is($result, 'retry', 'rate_limit still returns retry (no regression)');
};

subtest 'Bug 2e: truncated stream is retryable with infinite budget and accurate label' => sub {
    # Stream truncation (provider ended without finish_reason) is the
    # MiniMax silent-stop bug. The new error_type=truncated must:
    #   1. Get the same infinite retry budget as server_error/timeout
    #   2. Surface a "stream truncated" label (not generic "server error")
    #   3. Not bail after max_retries=3 the way the previous generic-else
    #      branch would have.
    my $result = call_handle_api_error(
        api_response => {
            success    => 0,
            error      => 'Stream truncated: provider ended response without finish_reason (content=39 chars, tool_calls=0)',
            retryable  => 1,
            retry_after => 5,
            error_type => 'truncated',
        }
    );

    is($result, 'retry', 'truncated returns retry (infinite budget, not bailing)');
};

subtest 'Bug 2f: truncated does NOT bail at attempt 50' => sub {
    # Verify the retry budget inheritance works for truncated the same
    # way it does for server_error (max_server_retries=0 -> infinite).
    my $wo = StubWO->new();
    my $session = StubSession->new();
    my $retry_count = 50;
    my $session_error_count = 0;

    my $ctx = {
        messages            => [],
        retry_count         => \$retry_count,
        session_error_count => \$session_error_count,
        iteration           => 1,
        tool_calls_made     => [],
        session             => $session,
        on_system_message   => sub {},
        max_retries         => 3,
        max_server_retries  => 0,    # infinite, inherited by truncated
        max_session_errors  => 50,
        max_rate_limit_retries => 0,
    };

    my $result = CLIO::Core::API::ErrorHandler::handle_api_error(
        $wo,
        {
            success    => 0,
            error      => 'Stream truncated: provider ended response without finish_reason (content=39 chars, tool_calls=0)',
            retryable  => 1,
            retry_after => 5,
            error_type => 'truncated',
        },
        $ctx
    );

    is($result, 'retry',
        'truncated does NOT bail at attempt 50 (infinite retry budget via server_error inheritance)');
};

subtest 'Bug 2g: truncated surfaces "stream truncated" label to UI' => sub {
    my $msg;
    my $result = call_handle_api_error(
        api_response => {
            success    => 0,
            error      => 'Stream truncated: provider ended response without finish_reason',
            retryable  => 1,
            retry_after => 5,
            error_type => 'truncated',
        },
        on_system_message => sub { $msg = shift; }
    );

    is($result, 'retry', 'returns retry');
    like($msg, qr/stream truncated/i,
        'system message uses "stream truncated" label (not generic "server error")');
};

done_testing();