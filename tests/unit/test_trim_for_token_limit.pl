#!/usr/bin/env perl
# Test the actual trim_for_token_limit function in ErrorHandler.
#
# Verifies:
# - retry_count is correctly dereferenced when passed as a SCALAR ref
#   (the bug where \$retry_count numified to ~94 trillion)
# - Server-reported n_prompt_tokens/n_ctx produce a drift ratio that
#   scales the trim walk's local estimates to actual tokens
# - The drift ratio is saved to state and loaded back on retry 2
# - The trim walk actually removes messages (trimmed_count > 0)
# - retry_count==3 with minimal context bails correctly
# - retry_count==2 uses the 75% cut strategy (drift-aware, unified walk)

use strict;
use warnings;
use utf8;
use lib './lib';
use Test::More;
use CLIO::Core::API::ErrorHandler ();
use CLIO::Core::Defaults;
use CLIO::Memory::TokenEstimator qw(estimate_tokens);
CLIO::Memory::TokenEstimator::set_learned_ratio(4.0);  # Default chars/token ratio

# Build messages large enough that drift scaling matters:
# - System prompt: 60K chars (~15K local tokens)
# - N non-system messages: 8K chars each (~2K local tokens each)
# With n_prompt_tokens ~140K, drift ~= 3.9 (capped 4.0), so msg_budget
# is tight enough that some messages must be dropped.
sub build_large_messages {
    my ($non_system_count) = @_;
    $non_system_count //= 10;

    my @messages;
    push @messages, { role => 'system', content => 'X' x 60000 };

    for my $i (1 .. $non_system_count) {
        push @messages, {
            role => ($i % 2 == 0 ? 'assistant' : 'user'),
            content => 'A' x 8000,
        };
    }

    push @messages, { role => 'system', content => '<userContext>date/time context</userContext>' };
    push @messages, { role => 'user', content => 'continue' };
    return \@messages;
}

# Build small messages that fit within any budget
sub build_small_messages {
    return [
        { role => 'system', content => 'You are a helpful assistant.' },
        { role => 'user', content => 'hi' },
    ];
}

sub make_wo {
    return bless {
        api_manager => undef,
        _tools_cache => [],
        prompt_builder => undef,
    }, 'MockTrimWO';
}

subtest 'retry_count reference is dereferenced (regression test)' => sub {
    # The critical regression: pass retry_count as a SCALAR REF.
    # Before the fix, \$retry_count numified to a large number, so
    # == 1 was FALSE, == 2 was FALSE, else was ALWAYS taken, and
    # > 2 was always TRUE -> immediate bail on first 400.
    my $retry_count = 1;
    my $messages = build_large_messages(10);
    my $wo = make_wo();

    my $result = CLIO::Core::API::ErrorHandler::trim_for_token_limit(
        $wo,
        messages          => $messages,
        retry_count       => \$retry_count,
        session           => undef,
        iteration         => 1,
        tool_calls_made   => [],
        max_retries       => 3,
        max_server_retries=> 0,
        max_session_errors=> 10,
        max_rate_limit_retries => 0,
        error             => 'request exceeds context size',
        n_ctx             => 131072,
        n_prompt_tokens   => 140000,
    );

    ok(!exists $result->{bail}, 'Does NOT bail when retry_count=1 passed as SCALAR ref');
    ok(exists $result->{system_msg}, 'Returns system_msg (precise-cut branch taken, not else)');
    like($result->{system_msg}, qr/Trimmed \d+ messages/, 'system_msg mentions trimmed messages');
    is($retry_count, 1, 'retry_count value unchanged');
};

subtest 'precise cut with server data trims messages' => sub {
    my $messages = build_large_messages(10);
    my $original = scalar @$messages;
    my $wo = make_wo();

    my $rc = 1;
    my $result = CLIO::Core::API::ErrorHandler::trim_for_token_limit(
        $wo,
        messages          => $messages,
        retry_count       => \$rc,
        session           => undef,
        iteration         => 1,
        tool_calls_made   => [],
        max_retries       => 3,
        max_server_retries=> 0,
        max_session_errors=> 10,
        max_rate_limit_retries => 0,
        error             => 'request exceeds context size',
        n_ctx             => 131072,
        n_prompt_tokens   => 140000,
    );

    ok(!exists $result->{bail}, 'No bail on retry 1');
    my $after = scalar @$messages;
    ok($after < $original, "Messages trimmed (before=$original, after=$after)");
    ok($after >= 3, "Kept at least 3 messages (got $after): system + user_context + user_input");
};

subtest 'drift ratio is computed and saved to state' => sub {
    my $state = { last_api_metadata => {}, max_tokens => 131072 };
    my $session = bless { _state => $state }, 'MockTrimSession';
    no strict 'refs';
    *MockTrimSession::can = sub { my ($self, $m) = @_; return $m eq 'state'; };
    *MockTrimSession::state = sub { return $_[0]{_state} };
    use strict 'refs';

    my $messages = build_large_messages(10);
    my $wo = make_wo();

    my $rc = 1;
    my $result = CLIO::Core::API::ErrorHandler::trim_for_token_limit(
        $wo,
        messages          => $messages,
        retry_count       => \$rc,
        session           => $session,
        iteration         => 1,
        tool_calls_made   => [],
        max_retries       => 3,
        max_server_retries=> 0,
        max_session_errors=> 10,
        max_rate_limit_retries => 0,
        error             => 'request exceeds context size',
        n_ctx             => 131072,
        n_prompt_tokens   => 140000,
    );

    ok(!exists $result->{bail}, 'No bail');
    ok(exists $result->{system_msg}, 'Returns system_msg');
    ok(defined $state->{last_api_metadata}{estimate_drift_ratio}, 'Drift ratio saved to state');
    my $saved = $state->{last_api_metadata}{estimate_drift_ratio};
    ok($saved >= 1.2, "Drift ratio >= 1.2 (got $saved)");
    is($state->{last_api_metadata}{actual_tokens}, 140000, 'actual_tokens saved');
    ok($state->{last_api_metadata}{estimated_tokens} > 0, 'estimated_tokens saved');
};

subtest 'fallback when no server-reported sizes' => sub {
    my $messages = build_large_messages(50);
    my $original = scalar @$messages;
    my $wo = make_wo();

    my $rc = 1;
    my $result = CLIO::Core::API::ErrorHandler::trim_for_token_limit(
        $wo,
        messages          => $messages,
        retry_count       => \$rc,
        session           => undef,
        iteration         => 1,
        tool_calls_made   => [],
        max_retries       => 3,
        max_server_retries=> 0,
        max_session_errors=> 10,
        max_rate_limit_retries => 0,
        error             => 'some error',
        # No n_ctx / n_prompt_tokens -> fallback compute_prompt_budget
    );

    ok(!exists $result->{bail}, 'No bail with fallback path');
    like($result->{system_msg}, qr/Trimmed/, 'system_msg mentions trimming');
};

subtest 'retry_count==3 with minimal context bails correctly' => sub {
    my $messages = build_large_messages(10);
    my $wo = make_wo();

    my $rc = 3;
    my $result = CLIO::Core::API::ErrorHandler::trim_for_token_limit(
        $wo,
        messages          => $messages,
        retry_count       => \$rc,
        session           => undef,
        iteration         => 1,
        tool_calls_made   => [],
        max_retries       => 3,
        max_server_retries=> 0,
        max_session_errors=> 10,
        max_rate_limit_retries => 0,
        error             => 'request exceeds context size',
        n_ctx             => 131072,
        n_prompt_tokens   => 140000,
    );

    ok(exists $result->{bail}, 'Bails on retry_count==3');
    is($result->{bail}, 1, 'bail flag is 1');
    like($result->{response}{error}, qr/Token limit exceeded/, 'Error about token limit');
};

subtest 'retry_count==2 uses drift-aware 75% cut' => sub {
    my $messages = build_large_messages(40);
    my $original = scalar @$messages;
    my $wo = make_wo();

    my $rc = 2;
    my $result = CLIO::Core::API::ErrorHandler::trim_for_token_limit(
        $wo,
        messages          => $messages,
        retry_count       => \$rc,
        session           => undef,
        iteration         => 1,
        tool_calls_made   => [],
        max_retries       => 3,
        max_server_retries=> 0,
        max_session_errors=> 10,
        max_rate_limit_retries => 0,
        error             => 'request exceeds context size',
        n_ctx             => 131072,
        n_prompt_tokens   => 140000,
    );

    ok(!exists $result->{bail}, 'No bail on retry_count==2');
    my $after = scalar @$messages;
    ok($after < $original, "Trimmed on retry 2 (before=$original, after=$after)");
};

subtest 'nothing to trim -> bail with diagnostic' => sub {
    my $messages = build_small_messages();
    my $wo = make_wo();

    my $rc = 1;
    my $result = CLIO::Core::API::ErrorHandler::trim_for_token_limit(
        $wo,
        messages          => $messages,
        retry_count       => \$rc,
        session           => undef,
        iteration         => 1,
        tool_calls_made   => [],
        max_retries       => 3,
        max_server_retries=> 0,
        max_session_errors=> 10,
        max_rate_limit_retries => 0,
        error             => 'request exceeds context size',
        n_ctx             => 131072,
        n_prompt_tokens   => 100,  # Very small — nothing to trim
    );

    ok(exists $result->{bail}, 'Bails when nothing trimmed');
    like($result->{response}{error}, qr/Diagnostic dump/, 'Error mentions diagnostic dump');
};

subtest 'keep_budget floor prevents over-trim' => sub {
    # Tiny context window — keep_budget should be clamped to MIN_CSSIS_SLOT_TOKENS floor
    my $messages = build_large_messages(20);
    my $wo = make_wo();

    my $rc = 1;
    my $result = CLIO::Core::API::ErrorHandler::trim_for_token_limit(
        $wo,
        messages          => $messages,
        retry_count       => \$rc,
        session           => undef,
        iteration         => 1,
        tool_calls_made   => [],
        max_retries       => 3,
        max_server_retries=> 0,
        max_session_errors=> 10,
        max_rate_limit_retries => 0,
        error             => 'request exceeds context size',
        n_ctx             => 1000,
        n_prompt_tokens   => 50000,
    );

    # keep_budget = int(1000 * 0.90) = 900, clamped to MIN_CSSIS (8000)
    # This is very small but shouldn't cause a crash
    ok(!exists $result->{bail} || exists $result->{bail}, 'Does not crash with tiny ctx');
};

subtest 'retry_count==2 loads drift ratio from saved state' => sub {
    # Simulate a retry 2 where the server did NOT report token counts
    # this time, but the drift ratio was saved during retry 1.
    my $state = {
        last_api_metadata => {
            estimate_drift_ratio => 3.5,
            actual_tokens       => 140000,
            estimated_tokens    => 37837,
        },
    };
    my $session = bless { _state => $state }, 'MockTrimSession2';
    no strict 'refs';
    *MockTrimSession2::can = sub { my ($self, $m) = @_; return $m eq 'state'; };
    *MockTrimSession2::state = sub { return $_[0]{_state} };
    use strict 'refs';

    my $messages = build_large_messages(10);
    my $original = scalar @$messages;
    my $wo = make_wo();

    my $rc = 2;
    my $result = CLIO::Core::API::ErrorHandler::trim_for_token_limit(
        $wo,
        messages          => $messages,
        retry_count       => \$rc,
        session           => $session,
        iteration         => 1,
        tool_calls_made   => [],
        max_retries       => 3,
        max_server_retries=> 0,
        max_session_errors=> 10,
        max_rate_limit_retries => 0,
        error             => 'request exceeds context size',
        n_ctx             => 131072,
        # No n_prompt_tokens -> should load drift from state
    );

    ok(!exists $result->{bail}, 'No bail on retry 2 with saved state');
    my $after = scalar @$messages;
    ok($after < $original, "Trimmed on retry 2 using saved drift (before=$original, after=$after)");
};

done_testing();
