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
    ok(grep(/rerouting to kilo/, @sys_msgs), 'system message mentions rerouting');
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

done_testing();
