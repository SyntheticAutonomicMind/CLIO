#!/usr/bin/env perl
# Regression tests for the routing-exhaustion + reactive-trim token-limit bug.
#
# Two defects combined to break token-limit recovery during model routing:
#   1. _routing_should_skip() did not include token_limit_exceeded, so the
#      router cycled every model in the route (all hit the same limit) and
#      exhausted the routing budget instead of trimming.
#   2. trim_for_token_limit() read retry_count as a value but the caller
#      passes a scalar ref, so the 3-tier trim collapsed to the minimal
#      branch and bailed immediately on the first retry.
#
# These tests pin both fixes: token-limit errors skip routing and fall
# through to a working reactive trim.

use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;

use CLIO::Core::API::ErrorHandler;

# A WorkflowOrchestrator stand-in carrying just what trim_for_token_limit
# needs: api_manager with model_routing_active() (so the routing block is
# entered) and get_model_capabilities() returning SMALL caps so trimming
# is deterministic and easy to trigger.
package FakeCaps {
    sub new { bless {}, shift }
    sub model_routing_active { 3 }          # routing IS active
    sub get_current_model    { 'openrouter/foo' }
    sub get_model_capabilities {
        return { context_window => 10000, max_output_tokens => 2048,
                 max_prompt_tokens => 8000, max_context_window_tokens => 10000 };
    }
}

package FakeWO {
    sub new {
        my ($class, %a) = @_;
        return bless { api_manager => $a{api_manager}, prompt_builder => undef }, $class;
    }
}

sub _big_messages {
    # ~18k tokens (≈72k chars) -- well over the 10k-window / ~1k-budget caps.
    my @m;
    push @m, { role => 'system', content => 'You are a helpful assistant.' };
    for my $i (1..18) {
        push @m, { role => 'user',     content => "user turn $i " . ('a' x 2000) },
                 { role => 'assistant', content => "reply $i " . ('b' x 2000) };
    }
    return @m;
}

# =============================================================================
# 1. Routing skip classification
# =============================================================================

subtest 'token_limit_exceeded is non-actionable across routed models' => sub {
    ok(CLIO::Core::API::ErrorHandler::_routing_should_skip({ error_type => 'token_limit_exceeded' }),
       'token_limit_exceeded -> routing skipped');

    ok(!CLIO::Core::API::ErrorHandler::_routing_should_skip({ error_type => 'rate_limit' }),
       'rate_limit -> routing NOT skipped');
    ok(!CLIO::Core::API::ErrorHandler::_routing_should_skip({ error_type => 'server_error' }),
       'server_error -> routing NOT skipped');
    ok(!CLIO::Core::API::ErrorHandler::_routing_should_skip({ error_type => 'timeout' }),
       'timeout -> routing NOT skipped');

    ok(CLIO::Core::API::ErrorHandler::_routing_should_skip({ error_type => 'model_not_found' }),
       'model_not_found -> routing skipped (unchanged)');
};

# =============================================================================
# 2. trim_for_token_limit dereferences retry_count (scalar ref) correctly.
#    Before the fix this numified to a large address and ALWAYS bailed.
# =============================================================================

subtest 'trim_for_token_limit dereferences retry_count ref' => sub {
    my $wo = FakeWO->new(api_manager => FakeCaps->new);

    for my $attempt (1..3) {
        my @msgs = _big_messages();
        my $rc = 0;                       # retry_count, passed by ref (production shape)
        $rc = $attempt;                   # simulate handle_api_error having incremented it
        my $ctx = {
            messages           => \@msgs,
            retry_count        => \$rc,   # <-- scalar ref, exactly as in production
            session            => undef,
            tool_calls_made    => [],
            iteration          => 1,
            max_retries        => 3,
            max_server_retries => 0,
            error              => 'token limit',
        };
        my $res = CLIO::Core::API::ErrorHandler::trim_for_token_limit($wo, %$ctx);

        if ($attempt <= 2) {
            ok($res->{retried},
               "retry_count=$attempt (ref): trim proceeds (did NOT bail)");
            ok(scalar(@msgs) < 37,
               "retry_count=$attempt (ref): messages were actually trimmed ("
                 . scalar(@msgs) . " remain of 37)");
        } else {
            ok($res->{bail},
               "retry_count=$attempt (ref): bails when minimal context still overflows");
        }
    }

    # Sanity: a plain integer (non-ref) retry_count also works, so the
    # deref guard is not ref-only.
    my @msgs = _big_messages();
    my $ctx = {
        messages           => \@msgs, retry_count => 1, session => undef,
        tool_calls_made    => [], iteration => 1, max_retries => 3,
        max_server_retries => 0, error => 'token limit',
    };
    my $res = CLIO::Core::API::ErrorHandler::trim_for_token_limit($wo, %$ctx);
    ok($res->{retried}, 'retry_count=1 (plain int): trim proceeds (did NOT bail)');
};

# =============================================================================
# 3. Integration: token_limit during routing does NOT burn routing cycles;
#    it trims and retries instead of fatal-exiting with "Model routing
#    exhausted" (the user-reported symptom).
# =============================================================================

subtest 'token_limit_exceeded during routing trims instead of exhausting' => sub {
    my $wo = FakeWO->new(api_manager => FakeCaps->new);
    my @sys_msgs;
    my $on_system_message = sub { push @sys_msgs, $_[0]; };

    my @messages = _big_messages();
    my $session = { routing_attempts => 0 };

    my $retry_count = 0;
    my $api_response = {
        success     => 0,
        error       => "Token limit exceeded: The conversation history is too long for the model's context window. Will attempt to trim conversation history and retry.",
        retryable   => 1,
        error_type  => 'token_limit_exceeded',
        retry_after => 0,
    };
    my $ctx = {
        messages            => \@messages,
        retry_count         => \$retry_count,
        session_error_count => \my $sec,
        iteration           => 1,
        tool_calls_made     => [],
        session             => $session,
        on_system_message   => $on_system_message,
        max_retries         => 3,
        max_server_retries  => 3,
        max_session_errors  => 10,
        max_rate_limit_retries => 3,
    };

    my $result = CLIO::Core::API::ErrorHandler::handle_api_error($wo, $api_response, $ctx);

    # Must NOT be a routing-exhausted fatal: trim path must have been reached.
    if (ref($result) eq 'HASH') {
        ok($result->{error} !~ /Model routing exhausted/,
           "NOT routing-exhausted (got: " . substr($result->{error}//'',0,60) . ")");
    } else {
        is($result, 'retry', 'returns retry (trim engaged, not a model cycle)');
    }

    # routing_attempts must NOT have been burned: token_limit is skipped
    # from routing, so cycling never happens.
    is($session->{routing_attempts}, 0,
       'routing_attempts not incremented (no model cycling for token_limit)');

    # Trim-driven system message must NOT be emitted to the UI — reactive
    # trimming is silent (debug-logged only).
    my $trim_msg = grep { /Token limit exceeded\. Trimmed/ || /trimming/i } @sys_msgs;
    ok(!$trim_msg, 'did NOT emit a trim-driven system message to the UI');
};

done_testing();
