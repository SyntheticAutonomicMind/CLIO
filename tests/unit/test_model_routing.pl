#!/usr/bin/env perl
# Test model routing: multiple models configured, auto-switch on API errors
#
# Tests the model routing feature that allows users to specify multiple
# models (via --model or /api set model) and have CLIO automatically
# switch to the next model when an API error occurs.

use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use Test::More;

use CLIO::Core::Config;
use CLIO::Core::APIManager;
use CLIO::Core::API::ErrorHandler;
use CLIO::Providers qw(list_providers provider_exists);

# =============================================================================
# Config: model_candidates and model_routing_index
# =============================================================================

subtest 'config model candidates' => sub {
    my $dir = "/tmp/clio-test-model-routing";
    `rm -rf $dir`;
    my $config = CLIO::Core::Config->new(config_dir => $dir);

    # Initially no candidates
    my $candidates = $config->get_model_candidates();
    is(ref($candidates), 'ARRAY', 'get_model_candidates returns arrayref by default');
    is(scalar(@$candidates), 0, 'no candidates by default');

    is($config->get_model_routing_index(), 0, 'routing index defaults to 0');

    # Set candidates
    my @models = ('openrouter/foo:free', 'kilo/bar:free', 'vercel/baz-free');
    ok($config->set_model_candidates(\@models), 'set_model_candidates returns true');
    is($config->get_model_routing_index(), 0, 'routing index still 0 after set_candidates');

    # Verify candidates
    $candidates = $config->get_model_candidates();
    is(scalar(@$candidates), 3, '3 candidates set');
    is($candidates->[0], 'openrouter/foo:free', 'first candidate correct');
    is($candidates->[2], 'vercel/baz-free', 'third candidate correct');

    # Set routing index
    ok($config->set_model_routing_index(2), 'set_model_routing_index returns true');
    is($config->get_model_routing_index(), 2, 'routing index is 2');

    # Save and reload
    $config->save();
    my $config2 = CLIO::Core::Config->new(config_dir => $dir);
    my $candidates2 = $config2->get_model_candidates();
    is(scalar(@$candidates2), 3, 'candidates survive save/reload');
    is($candidates2->[0], 'openrouter/foo:free', 'first candidate survives reload');
    is($config2->get_model_routing_index(), 2, 'routing index survives reload');

    `rm -rf $dir`;
};

# =============================================================================
# APIManager: cycle_model and model_routing_active
# =============================================================================

subtest 'api_manager model routing' => sub {
    my $dir = "/tmp/clio-test-model-routing-2";
    `rm -rf $dir`;

    my $config = CLIO::Core::Config->new(config_dir => $dir);
    $config->set("provider", "openrouter", 0);
    $config->set("api_base", "https://openrouter.ai/api/v1/chat/completions", 0);
    $config->set("api_key", "test-key", 0);

    my $api = CLIO::Core::APIManager->new(debug => 0, config => $config);

    # No routing configured
    is($api->model_routing_active(), 0, 'no routing when no candidates');

    # Set up routing
    my @models = ('openrouter/foo:free', 'kilo/bar:free', 'vercel/baz-free');
    $config->set("model_candidates", \@models, 0);
    $config->set("model_routing_index", 0, 0);
    $config->set("model", 'openrouter/foo:free', 0);

    is($api->model_routing_active(), 3, 'routing active with 3 candidates');

    # Cycle to next model
    is($api->get_current_model(), 'openrouter/foo:free', 'initial model correct');

    my ($new, $old) = $api->cycle_model();
    is($new, 'kilo/bar:free', 'cycled to second model');
    is($old, 'openrouter/foo:free', 'old model was first');
    is($api->get_current_model(), 'kilo/bar:free', 'current model updated');
    is($config->get_model_routing_index(), 1, 'routing index is 1');

    # Cycle again
    ($new, $old) = $api->cycle_model();
    is($new, 'vercel/baz-free', 'cycled to third model');
    is($config->get_model_routing_index(), 2, 'routing index is 2');

    # Cycle again - should wrap to first
    ($new, $old) = $api->cycle_model();
    is($new, 'openrouter/foo:free', 'wrapped to first model');
    is($config->get_model_routing_index(), 0, 'routing index wrapped to 0');

    `rm -rf $dir`;
};

# =============================================================================
# APIManager: _parse_model_provider for new providers
# =============================================================================

subtest 'model parsing for new providers' => sub {
    my $dir = "/tmp/clio-test-model-routing-3";
    `rm -rf $dir`;

    my $config = CLIO::Core::Config->new(config_dir => $dir);
    $config->set("provider", "openrouter", 0);
    $config->set("api_base", "https://openrouter.ai/api/v1/chat/completions", 0);
    $config->set("api_key", "test-key", 0);

    my $api = CLIO::Core::APIManager->new(debug => 0, config => $config);

    # OrcaRouter model: orca/openai/gpt-4o-mini
    my ($provider, $model) = $api->_parse_model_provider("orca/openai/gpt-4o-mini");
    is($provider, 'orca', 'orca provider parsed correctly');
    is($model, 'openai/gpt-4o-mini', 'orca model parsed correctly');

    # KiloCode model: kilo/anthropic/claude-sonnet-5
    ($provider, $model) = $api->_parse_model_provider("kilo/anthropic/claude-sonnet-5");
    is($provider, 'kilo', 'kilo provider parsed correctly');
    is($model, 'anthropic/claude-sonnet-5', 'kilo model parsed correctly');

    # Verify providers exist
    ok(provider_exists('orca'), 'orca provider exists');
    ok(provider_exists('kilo'), 'kilo provider exists');

    `rm -rf $dir`;
};

# =============================================================================
# ErrorHandler: model routing on API errors
# =============================================================================

subtest 'error handler model routing' => sub {
    my $dir = "/tmp/clio-test-model-routing-4";
    `rm -rf $dir`;

    my $config = CLIO::Core::Config->new(config_dir => $dir);
    $config->set("provider", "openrouter", 0);
    $config->set("api_base", "https://openrouter.ai/api/v1/chat/completions", 0);
    $config->set("api_key", "orca-key", 0);
    my $keys = $config->{config}->{api_keys};
    $keys->{openrouter} = "orca-key";
    $keys->{kilo} = "kilo-key";
    $config->{user_set}->{api_keys} = 1;

    my $api = CLIO::Core::APIManager->new(debug => 0, config => $config);
    my @models = ('openrouter/foo:free', 'kilo/bar:free');
    $config->set("model_candidates", \@models, 0);
    $config->set("model_routing_index", 0, 0);
    $config->set("model", 'openrouter/foo:free', 0);

    my $wo = bless { api_manager => $api }, "CLIO::Core::WorkflowOrchestrator";
    my $session = { routing_attempts => 0 };
    my @sys_msgs;
    my $on_system_message = sub { push @sys_msgs, $_[0]; };

    # Simulate a 429 rate limit error - should trigger routing
    my $retry_count = 0;
    my $api_response = {
        success => 0,
        error => "Rate limit exceeded",
        retryable => 1,
        error_type => "rate_limit",
        retry_after => 1,
    };

    my $ctx = {
        messages => [],
        retry_count => \$retry_count,
        session_error_count => \my $sec,
        iteration => 1,
        tool_calls_made => [],
        session => $session,
        on_system_message => $on_system_message,
        max_retries => 3,
        max_server_retries => 3,
        max_session_errors => 10,
        max_rate_limit_retries => 3,
    };

    my $result = CLIO::Core::API::ErrorHandler::handle_api_error($wo, $api_response, $ctx);

    is($result, 'retry', 'returns retry on 429 with routing active');
    is($api->get_current_model(), 'kilo/bar:free', 'model switched to kilo');
    is($session->{routing_attempts}, 1, 'routing attempts incremented');
    is($sys_msgs[0], 'API Rate Limit (429), rerouting to kilo/bar:free', 'system message includes error type and status code');
    is($retry_count, 0, 'retry count reset after routing');

    `rm -rf $dir`;
};

# =============================================================================
# ErrorHandler: model routing exhaustion (9 total attempts for 3 models)
# =============================================================================

subtest 'error handler routing exhaustion' => sub {
    my $dir = "/tmp/clio-test-model-routing-5";
    `rm -rf $dir`;

    my $config = CLIO::Core::Config->new(config_dir => $dir);
    $config->set("provider", "openrouter", 0);
    $config->set("api_base", "https://openrouter.ai/api/v1/chat/completions", 0);
    $config->set("api_key", "openrouter-key", 0);
    my $keys = $config->{config}->{api_keys};
    $keys->{openrouter} = "openrouter-key";
    $keys->{kilo} = "kilo-key";
    $keys->{vercel} = "vercel-key";
    $config->{user_set}->{api_keys} = 1;

    my $api = CLIO::Core::APIManager->new(debug => 0, config => $config);
    my @models = ('openrouter/foo:free', 'kilo/bar:free', 'vercel/baz-free');
    $config->set("model_candidates", \@models, 0);
    $config->set("model_routing_index", 0, 0);
    $config->set("model", 'openrouter/foo:free', 0);

    my $wo = bless { api_manager => $api }, "CLIO::Core::WorkflowOrchestrator";
    my $session = { routing_attempts => 0 };
    my @sys_msgs;
    my $on_system_message = sub { push @sys_msgs, $_[0]; };
    my $max_retries = 3;

    # Simulate 10 consecutive errors (should give up after 9)
    my $gave_up = 0;
    for my $attempt (1..10) {
        my $retry_count = 0;
        my $api_response = {
            success => 0,
            error => "429 Too Many Requests",
            retryable => 1,
            error_type => "rate_limit",
            retry_after => 1,
        };

        my $ctx = {
            messages => [],
            retry_count => \$retry_count,
            session_error_count => \my $sec,
            iteration => 1,
            tool_calls_made => [],
            session => $session,
            on_system_message => $on_system_message,
            max_retries => $max_retries,
            max_server_retries => 3,
            max_session_errors => 10,
            max_rate_limit_retries => 3,
        };

        my $result = CLIO::Core::API::ErrorHandler::handle_api_error($wo, $api_response, $ctx);

        if (ref($result) eq 'HASH') {
            ok($result->{error} =~ /routing exhausted/, "attempt $attempt: gave up with routing exhausted message");
            ok($result->{error} =~ /9 total attempts/, "attempt $attempt: mentions 9 total attempts");
            $gave_up = 1;
            last;
        }
        ok($result eq 'retry', "attempt $attempt: retried (routing_attempts=" . $session->{routing_attempts} . ")");
    }

    ok($gave_up, 'routing gave up after exhausting all 9 attempts');

    `rm -rf $dir`;
};

# =============================================================================
# ErrorHandler: no routing when only 1 model configured
# =============================================================================

subtest 'no routing with single model' => sub {
    my $dir = "/tmp/clio-test-model-routing-6";
    `rm -rf $dir`;

    my $config = CLIO::Core::Config->new(config_dir => $dir);
    $config->set("provider", "openrouter", 0);
    $config->set("api_base", "https://openrouter.ai/api/v1/chat/completions", 0);
    $config->set("api_key", "test-key", 0);

    my $api = CLIO::Core::APIManager->new(debug => 0, config => $config);

    is($api->model_routing_active(), 0, 'no routing with single model (no candidates)');

    $config->set("model_candidates", ['openrouter/foo:free'], 0);
    $config->set("model_routing_index", 0, 0);

    is($api->model_routing_active(), 0, 'no routing with 1 candidate');

    `rm -rf $dir`;
};

# =============================================================================
# ErrorHandler: _routing_error_label helper
# =============================================================================

subtest '_routing_error_label' => sub {
    # Rate limit error -> "Rate Limit (429)"
    is(CLIO::Core::API::ErrorHandler::_routing_error_label({
        error => "Rate limit exceeded",
        error_type => "rate_limit",
    }), "Rate Limit (429)", 'rate_limit maps to Rate Limit (429)');

    # Concurrency limit -> also "Rate Limit (429)"
    is(CLIO::Core::API::ErrorHandler::_routing_error_label({
        error => "Concurrency limit reached",
        error_type => "concurrency_limit",
    }), "Rate Limit (429)", 'concurrency_limit maps to Rate Limit (429)');

    # Server error -> "Server Error (500)"
    is(CLIO::Core::API::ErrorHandler::_routing_error_label({
        error => "Internal server error",
        error_type => "server_error",
    }), "Server Error (500)", 'server_error maps to Server Error (500)');

    # Billing error -> "Billing Error (402)"
    is(CLIO::Core::API::ErrorHandler::_routing_error_label({
        error => "insufficient_quota",
        error_type => "billing_error",
    }), "Billing Error (402)", 'billing_error maps to Billing Error (402)');

    # Model not found -> "Model Not Found (404)"
    is(CLIO::Core::API::ErrorHandler::_routing_error_label({
        error => "model not found",
        error_type => "model_not_found",
    }), "Model Not Found (404)", 'model_not_found maps to Model Not Found (404)');

    # Token limit -> "Token Limit (400)"
    is(CLIO::Core::API::ErrorHandler::_routing_error_label({
        error => "Prompt token count exceeds...",
        error_type => "token_limit_exceeded",
    }), "Token Limit (400)", 'token_limit_exceeded maps to Token Limit (400)');

    # Extracted status from error_obj overrides mapped status
    is(CLIO::Core::API::ErrorHandler::_routing_error_label({
        error => "Some error",
        error_type => "server_error",
        error_obj => { code => 503 },
    }), "Server Error (503)", 'extracted status from error_obj overrides mapped status');

    # Extracted status from error message text (no error_obj)
    is(CLIO::Core::API::ErrorHandler::_routing_error_label({
        error => "HTTP 429 Too Many Requests",
        error_type => "server_error",
    }), "Server Error (429)", 'extracted status from error message overrides mapped status');

    # Unknown error type with no extractable status -> "error"
    is(CLIO::Core::API::ErrorHandler::_routing_error_label({
        error => "Some unknown error",
        error_type => "totally_unknown_type",
    }), "error", 'unknown error_type with no extractable status returns "error"');

    # Unknown error type with status in message -> "error (NNN)"
    is(CLIO::Core::API::ErrorHandler::_routing_error_label({
        error => "HTTP 500 Internal Server Error",
        error_type => "totally_unknown_type",
    }), "error (500)", 'unknown error_type with extractable status returns "error (500)"');

    # No error_type, no extractable status -> "error"
    is(CLIO::Core::API::ErrorHandler::_routing_error_label({
        error => "Unknown error",
    }), "error", 'no error_type returns "error"');

    # user_interrupt has undef status -> "User Interrupt" (no code)
    is(CLIO::Core::API::ErrorHandler::_routing_error_label({
        error => "Interrupted",
        error_type => "user_interrupt",
    }), "User Interrupt", 'user_interrupt has no status code (undef)');
};

# =============================================================================
# ErrorHandler: routing message includes error type for server errors
# =============================================================================

subtest 'routing message includes error type for server error' => sub {
    my $dir = "/tmp/clio-test-model-routing-7";
    `rm -rf $dir`;

    my $config = CLIO::Core::Config->new(config_dir => $dir);
    $config->set("provider", "openrouter", 0);
    $config->set("api_base", "https://openrouter.ai/api/v1/chat/completions", 0);
    $config->set("api_key", "orca-key", 0);
    my $keys = $config->{config}->{api_keys};
    $keys->{openrouter} = "orca-key";
    $keys->{kilo} = "kilo-key";
    $config->{user_set}->{api_keys} = 1;

    my $api = CLIO::Core::APIManager->new(debug => 0, config => $config);
    my @models = ('openrouter/foo:free', 'kilo/bar:free');
    $config->set("model_candidates", \@models, 0);
    $config->set("model_routing_index", 0, 0);
    $config->set("model", 'openrouter/foo:free', 0);

    my $wo = bless { api_manager => $api }, "CLIO::Core::WorkflowOrchestrator";
    my $session = { routing_attempts => 0 };
    my @sys_msgs;
    my $on_system_message = sub { push @sys_msgs, $_[0]; };

    # Simulate a server error (500) - should show "Server Error (500)"
    my $retry_count = 0;
    my $api_response = {
        success => 0,
        error => "Internal server error",
        retryable => 1,
        error_type => "server_error",
        retry_after => 2,
    };

    my $ctx = {
        messages => [],
        retry_count => \$retry_count,
        session_error_count => \my $sec,
        iteration => 1,
        tool_calls_made => [],
        session => $session,
        on_system_message => $on_system_message,
        max_retries => 3,
        max_server_retries => 3,
        max_session_errors => 10,
        max_rate_limit_retries => 3,
    };

    my $result = CLIO::Core::API::ErrorHandler::handle_api_error($wo, $api_response, $ctx);

    is($result, 'retry', 'returns retry on 500 with routing active');
    is($sys_msgs[0], 'API Server Error (500), rerouting to kilo/bar:free', 'server error message includes type and status');

    `rm -rf $dir`;
};

done_testing();
