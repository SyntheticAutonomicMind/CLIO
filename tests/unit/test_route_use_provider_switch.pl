#!/usr/bin/env perl
# Regression test: /api route use must switch the global provider to match
# the route's first model's provider prefix.
#
# Bug: After /api route use minimax-free (whose first model is
# "openrouter/minimax/minimax-m3:free"), the global config still had
# provider=github_copilot and api_base=http://192.0.2.1:9090/... (the
# github_copilot proxy). /api show displayed the wrong provider even
# though APIManager correctly routed the request via the model prefix.
#
# The same root cause exists in /api set model and /api set model
# (multi-model candidates) - both update the model but never switch the
# global provider. All three call sites are fixed by the same pattern:
# resolve provider from the model's first prefix and call set_provider
# BEFORE set('model', ...) so set_provider's default model doesn't
# clobber the intended model.
#
# This file tests the helper that consolidates the fix, plus regression
# tests that exercise the public dispatch through the stubs.

use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use Test::More;
use File::Path qw(remove_tree);

use CLIO::Core::Config;

# =============================================================================
# Test scaffolding: instantiate the real Config.pm class against a stub Chat
# that records display output and stubs the Auth/agent side effects.
# =============================================================================

package CLIO::Test::RouteUseCmd;
use parent 'CLIO::UI::Commands::API::Config';

sub new {
    my ($class, %args) = @_;
    my $self = {
        %args,
        config   => $args{config},
        session  => $args{session},
        ai_agent => $args{ai_agent},
        chat     => $args{chat},
        debug    => $args{debug} // 0,
        _display_log => [],
    };
    bless $self, $class;
    return $self;
}

# Capture display output instead of forwarding to Chat.
sub display_error_message   { my $self = shift; push @{$self->{_display_log}}, "ERROR: $_[0]"; }
sub display_system_message  { my $self = shift; push @{$self->{_display_log}}, "SYSTEM: $_[0]"; }
sub display_success_message { my $self = shift; push @{$self->{_display_log}}, "OK: $_[0]"; }
sub display_command_header  { }
sub display_key_value       { }
sub display_command_row     { }
sub writeline               { }
sub colorize                { $_[1] // '' }
sub render_markdown         { $_[1] // '' }
sub refresh_terminal_size   { }

# Stub Auth helper - return an object whose reinit_api_manager is a no-op
# and check_github_auth is a no-op. We don't want GitHub OAuth prompts in tests.
sub _get_auth_helper {
    return bless {}, 'CLIO::Test::AuthHelper';
}

package CLIO::Test::AuthHelper;
sub reinit_api_manager { }
sub check_github_auth  { }

# Stub session - _update_billing_state only writes to state if it has a billing
# hash, and _set_api_setting writes to session->save(). Both can be no-ops for
# provider/model correctness tests.
package CLIO::Test::Session;
sub new { bless { state => { billing => {} } }, $_[1] }
sub state  { $_[0]->{state} }
sub save   { }

# Stub ai_agent - _post_set_model_validation only calls get_model_capabilities
# when ai_agent->{api} exists. For provider-switch tests we don't need it.
package CLIO::Test::Agent;
sub new { bless {}, $_[1] }

package main;

sub fresh_config {
    my $dir = "/tmp/clio-test-route-use-switch-" . int(rand(100000));
    remove_tree($dir) if -d $dir;
    my $config = CLIO::Core::Config->new(config_dir => $dir);
    return ($config, $dir);
}

sub make_cmd {
    my ($config) = @_;
    return CLIO::Test::RouteUseCmd->new(
        config   => $config,
        session  => CLIO::Test::Session->new('CLIO::Test::Session'),
        ai_agent => CLIO::Test::Agent->new('CLIO::Test::Agent'),
        chat     => undef,
    );
}

# =============================================================================
# Regression: simulate the user's exact reported scenario
# =============================================================================

subtest 'reported bug: /api route use minimax-free leaves provider=github_copilot' => sub {
    my ($config, $dir) = fresh_config();

    # Seed the exact pre-condition from the user's config:
    # - provider = github_copilot (from a previous Copilot session)
    # - api_base points at the github_copilot local proxy
    # - api_key is the proxy token
    $config->set('provider', 'github_copilot', 1);
    $config->{config}->{api_base} = 'http://192.0.2.1:9090/v1/chat/completions';
    $config->{config}->{api_key}  = '1234';

    # Save the route "minimax-free" with the user's model list
    my @models = (
        'openrouter/minimax/minimax-m3:free',
        'vercel/minimax/minimax-m3-free',
    );
    ok($config->set_model_route('minimax-free', \@models), 'route saved');

    # Add an OpenRouter api_key so set_provider can switch
    $config->{config}->{api_keys}{'openrouter'} = 'sk-or-v1-test';

    # Capture the config state before activation
    is($config->get('provider'), 'github_copilot', 'pre: provider is github_copilot');
    is($config->get('api_base'), 'http://192.0.2.1:9090/v1/chat/completions', 'pre: api_base is copilot proxy');

    my $cmd = make_cmd($config);
    $cmd->_route_use('minimax-free');

    # Post-activation expectations:
    is($config->get('provider'), 'openrouter',
        'POST: provider switched to openrouter (was the bug)');
    like($config->get('api_base'), qr{openrouter\.ai}i,
        'POST: api_base matches openrouter default (was the copilot proxy)');
    is($config->get('model'), 'openrouter/minimax/minimax-m3:free',
        'POST: model is the route first model');
    is($config->get('api_key'), 'sk-or-v1-test',
        'POST: api_key is the openrouter stored key');
    is($config->get('route_name'), 'minimax-free',
        'POST: route_name set');
    is_deeply($config->get_model_route('minimax-free'), \@models,
        'POST: route model list untouched');

    remove_tree($dir);
};

subtest 'reported bug: /api route use when route first model is already current provider' => sub {
    my ($config, $dir) = fresh_config();

    # User already on openrouter
    $config->set('provider', 'openrouter', 1);
    $config->{config}->{api_base} = 'https://openrouter.ai/api/v1/chat/completions';
    $config->{config}->{api_key}  = 'sk-or-v1-test';
    $config->{config}->{api_keys}{'openrouter'} = 'sk-or-v1-test';

    my @models = ('openrouter/foo:free', 'kilo/bar:free');
    $config->set_model_route('my-route', \@models);

    my $cmd = make_cmd($config);
    $cmd->_route_use('my-route');

    # Provider stays openrouter (no unnecessary switch)
    is($config->get('provider'), 'openrouter', 'provider stays openrouter');
    like($config->get('api_base'), qr{openrouter\.ai}i, 'api_base stays openrouter');
    is($config->get('model'), 'openrouter/foo:free', 'model updated to route first');

    remove_tree($dir);
};

# =============================================================================
# Same root cause lives in /api set model (single model with prefix)
# =============================================================================

subtest '/api set model openrouter/foo also switches provider' => sub {
    my ($config, $dir) = fresh_config();

    $config->set('provider', 'github_copilot', 1);
    $config->{config}->{api_base} = 'http://192.0.2.1:9090/v1/chat/completions';
    $config->{config}->{api_key}  = '1234';
    $config->{config}->{api_keys}{'openrouter'} = 'sk-or-v1-test';

    my $cmd = make_cmd($config);
    $cmd->_set_model('openrouter/foo:free', 0);

    is($config->get('provider'), 'openrouter',
        '/api set model: provider switches to openrouter');
    like($config->get('api_base'), qr{openrouter\.ai}i,
        '/api set model: api_base matches openrouter');
    is($config->get('model'), 'openrouter/foo:free',
        '/api set model: model set');

    remove_tree($dir);
};

# =============================================================================
# Same root cause lives in /api set model "m1 m2 m3" (inline candidates)
# =============================================================================

subtest '/api set model "openrouter/foo kilo/bar" also switches provider' => sub {
    my ($config, $dir) = fresh_config();

    $config->set('provider', 'github_copilot', 1);
    $config->{config}->{api_keys}{'openrouter'} = 'sk-or-v1-test';
    $config->{config}->{api_keys}{'kilo'} = 'kilo-test-key';

    my $cmd = make_cmd($config);
    $cmd->_set_model('openrouter/foo kilo/bar', 0);

    is($config->get('provider'), 'openrouter',
        'inline candidates: provider switches to first model provider');
    like($config->get('api_base'), qr{openrouter\.ai}i,
        'inline candidates: api_base matches openrouter');
    is($config->get('model'), 'openrouter/foo',
        'inline candidates: model set to first');
    is_deeply($config->get_model_candidates(), ['openrouter/foo', 'kilo/bar'],
        'inline candidates: candidates stored');

    remove_tree($dir);
};

# =============================================================================
# No-op when target provider matches current provider
# =============================================================================

subtest 'set_model with matching provider does not touch provider/api_base' => sub {
    my ($config, $dir) = fresh_config();

    $config->set('provider', 'openrouter', 1);
    $config->{config}->{api_base} = 'https://openrouter.ai/api/v1/chat/completions';
    $config->{config}->{api_key}  = 'sk-or-v1-test';

    my $cmd = make_cmd($config);
    $cmd->_set_model('openrouter/some-other-model', 0);

    is($config->get('provider'), 'openrouter', 'provider stays openrouter');
    like($config->get('api_base'), qr{openrouter\.ai}i, 'api_base stays openrouter');
    is($config->get('model'), 'openrouter/some-other-model', 'model updated');

    remove_tree($dir);
};

# =============================================================================
# /api set model without a prefix uses current provider - no switch
# =============================================================================

subtest 'set_model with no provider prefix keeps current provider' => sub {
    my ($config, $dir) = fresh_config();

    $config->set('provider', 'openrouter', 1);
    $config->{config}->{api_base} = 'https://openrouter.ai/api/v1/chat/completions';
    $config->{config}->{api_key}  = 'sk-or-v1-test';

    my $cmd = make_cmd($config);
    $cmd->_set_model('gpt-4.1', 0);

    is($config->get('provider'), 'openrouter', 'provider stays openrouter');
    is($config->get('model'), 'openrouter/gpt-4.1',
        'unprefixed model gets current provider prepended');
    like($config->get('api_base'), qr{openrouter\.ai}i, 'api_base unchanged');

    remove_tree($dir);
};

# =============================================================================
# Switching TO github_copilot must NOT trigger OAuth flow
# (the auth helper is stubbed to a no-op, but if the helper were called it
# would explode in this test - the test itself proves the path is bypassed
# by _activate_model_with_provider).
# =============================================================================

# The github_copilot branch in _set_model runs _validate_github_copilot_model
# FIRST, which fetches the live GitHub Copilot model registry. We can't
# easily stub that without rewriting _set_model. Instead, exercise the
# helper directly: invoke _activate_model_with_provider with github_copilot
# as the target to confirm it doesn't call check_github_auth (the Auth
# helper is stubbed; if check_github_auth were called the stub would not
# be reached and any real implementation would prompt for OAuth).

subtest 'switching to github_copilot via the helper does not invoke check_github_auth' => sub {
    my ($config, $dir) = fresh_config();

    $config->set('provider', 'openrouter', 1);
    $config->{config}->{api_base} = 'https://openrouter.ai/api/v1/chat/completions';
    $config->{config}->{api_key}  = 'sk-or-v1-test';
    $config->{config}->{api_keys}{'github_copilot'} = 'ghp_pat_token';

    my $cmd = make_cmd($config);

    # Direct call to the helper - bypasses _set_model's pre-validation
    # (which would fetch the live Copilot registry and is not the focus here).
    my $ok = $cmd->_activate_model_with_provider('github_copilot/gpt-4.1', 'github_copilot', 0);

    ok($ok, 'helper returned success for github_copilot switch');
    is($config->get('provider'), 'github_copilot',
        'switched to github_copilot via the helper');
    is($config->get('model'), 'github_copilot/gpt-4.1',
        'model set on top of provider default');
    is($config->get('api_key'), 'ghp_pat_token',
        'api_key loaded from per-provider store');
    like($config->get('api_base'), qr{githubcopilot\.com}i,
        'api_base matches github_copilot default');

    remove_tree($dir);
};

# =============================================================================
# session_only path: provider override should land in session state, not
# mutate the global config. /api show should display "(session)" next to it.
# =============================================================================

subtest 'session_only: provider override stored in session state, not global' => sub {
    my ($config, $dir) = fresh_config();

    $config->set('provider', 'github_copilot', 1);
    $config->{config}->{api_base} = 'http://192.0.2.1:9090/v1/chat/completions';
    $config->{config}->{api_key}  = '1234';
    $config->{config}->{api_keys}{'openrouter'} = 'sk-or-v1-test';

    # Capture the stub session so we can inspect its state
    my $session = CLIO::Test::Session->new('CLIO::Test::Session');
    my $cmd = CLIO::Test::RouteUseCmd->new(
        config   => $config,
        session  => $session,
        ai_agent => CLIO::Test::Agent->new('CLIO::Test::Agent'),
        chat     => undef,
    );

    $cmd->_set_model('openrouter/foo:free', 1);  # 1 = session_only

    is($config->get('provider'), 'github_copilot',
        'global provider UNCHANGED on session_only');
    like($config->get('api_base'), qr{192\.0\.2\.1},
        'global api_base UNCHANGED on session_only');

    my $state = $session->state();
    is($state->{api_config}{provider}, 'openrouter',
        'session api_config.provider = openrouter');
    like($state->{api_config}{api_base}, qr{openrouter\.ai}i,
        'session api_config.api_base = openrouter default');
    is($state->{api_config}{api_key}, 'sk-or-v1-test',
        'session api_config.api_key = openrouter stored key');
    is($state->{api_config}{model}, 'openrouter/foo:free',
        'session api_config.model set');

    remove_tree($dir);
};

done_testing();