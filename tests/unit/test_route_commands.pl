#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# Integration tests for /api route role-aware subcommands:
# strategy, role, default-role, fallback, explain, history.
#
# Uses a stub command class that captures display output and mocks
# provider-dependent methods so we can test the command logic without
# real API credentials.

use strict;
use warnings;
use utf8;
use FindBin;
use Test::More;
use File::Path qw(remove_tree);

use lib "$FindBin::Bin/../../lib";
use CLIO::Core::Config;
use CLIO::Core::RouteManager;

#---------------------------------------------------------------------------
# Stub harness
#---------------------------------------------------------------------------

package CLIO::Test::RoleCmd;
use parent 'CLIO::UI::Commands::API::Config';

sub new {
    my ($class, %args) = @_;
    my $self = {
        %args,
        config      => $args{config},
        session     => $args{session},
        ai_agent    => $args{ai_agent},
        chat        => $args{chat},
        debug       => $args{debug} // 0,
        _display    => [],
        _headers    => [],
        _key_values => [],
        _scopes     => [],
    };
    bless $self, $class;
    return $self;
}

# Display captures
sub display_error_message   { my $self = shift; push @{$self->{_display}}, "ERROR: $_[0]"; }
sub display_system_message  { my $self = shift; push @{$self->{_display}}, "SYSTEM: $_[0]"; }
sub display_success_message { my $self = shift; push @{$self->{_display}}, "OK: $_[0]"; }
sub display_command_header  { my $self = shift; push @{$self->{_headers}}, $_[0]; }
sub display_key_value       { my $self = shift; push @{$self->{_key_values}}, [@_]; }
sub display_command_row     { }
sub writeline               { }
sub colorize                { $_[1] // '' }
sub render_markdown         { $_[1] // '' }
sub refresh_terminal_size   { }
sub _scope_tag              { return ''; }
sub _get_auth_helper        { return bless {}, 'CLIO::Test::AuthHelper'; }

# Mock methods that need provider/network access
sub _update_billing_state   { }
sub _post_set_model_validation { }
sub _check_provider_auth { return (1, ''); }

sub _activate_model_with_provider {
    my ($self, $full_model, $target_provider, $session_only) = @_;
    $self->{config}->set('model', $full_model, $session_only // 0);
    $self->{config}->set_provider($target_provider) if $target_provider;
    return 1;
}

package CLIO::Test::AuthHelper;
sub reinit_api_manager { }

package CLIO::Test::Session;
sub new {
    my ($class, $initial) = @_;
    $initial //= {};
    return bless { state => { billing => {}, routing_decisions => $initial->{routing_decisions} || [] } }, $class;
}
sub state { $_[0]->{state} }
sub save  { }

package CLIO::Test::Agent;
sub new { bless {}, $_[1] }

#---------------------------------------------------------------------------
# Helper functions
#---------------------------------------------------------------------------
package main;

sub fresh_config {
    my $tag = shift // 'main';
    my $dir = "/tmp/clio-test-routes-cmd-$tag-" . int(rand(100000));
    remove_tree($dir) if -d $dir;
    my $config = CLIO::Core::Config->new(config_dir => $dir);
    return ($config, $dir);
}

sub make_cmd {
    my ($config) = @_;
    return CLIO::Test::RoleCmd->new(
        config   => $config,
        session  => CLIO::Test::Session->new(),
        ai_agent => CLIO::Test::Agent->new('CLIO::Test::Agent'),
        chat     => undef,
    );
}

sub make_cmd_with_session {
    my ($config, $session) = @_;
    return CLIO::Test::RoleCmd->new(
        config   => $config,
        session  => $session,
        ai_agent => CLIO::Test::Agent->new('CLIO::Test::Agent'),
        chat     => undef,
    );
}

sub cmd_session {
    return CLIO::Test::Session->new();
}

sub cmd_session_with_decisions {
    return CLIO::Test::Session->new({
        routing_decisions => [
            {
                timestamp    => time() - 300,
                decision     => 'cycle',
                error_type   => 'rate_limit',
                error_label  => 'rate_limit (429)',
                role         => 'coding',
                from_model   => 'openrouter/foo',
                to_model     => 'kilo/bar',
                attempts     => 1,
                max_attempts => 15,
            },
        ],
    });
}

# Helper: extract key-value pairs from display output
sub kv_hash {
    my ($cmd) = @_;
    return map { $_->[0] => $_->[1] } @{$cmd->{_key_values}};
}

#---------------------------------------------------------------------------
# Tests
#---------------------------------------------------------------------------

# /api route strategy
subtest '/api route strategy: set role-aware on existing sequential route' => sub {
    my ($cfg, $dir) = fresh_config('strat1');
    $cfg->set_model_route('myroute', ['openrouter/foo', 'kilo/bar']);
    $cfg->save();

    my $cmd = make_cmd($cfg);
    $cmd->handle_route('strategy', 'myroute', 'role-aware');

    like($cmd->{_display}[-1], qr/strategy set to 'role-aware'/, 'success message');
    is($cfg->get_route_strategy('myroute'), 'role-aware', 'strategy persisted as role-aware');

    my $route_cfg = $cfg->get_model_route_config('myroute');
    ok(ref($route_cfg) eq 'HASH', 'route is now a hashref');
    is($route_cfg->{strategy}, 'role-aware', 'strategy in hashref');
    is(scalar(@{$route_cfg->{models}}), 2, 'models preserved during conversion');

    remove_tree($dir);
};

subtest '/api route strategy: invalid strategy rejected' => sub {
    my ($cfg, $dir) = fresh_config('strat2');
    $cfg->set_model_route_config('myroute', {
        strategy => 'role-aware', models => [], roles => { coding => { model => 'foo' } },
    });
    $cfg->save();

    my $cmd = make_cmd($cfg);
    $cmd->handle_route('strategy', 'myroute', 'bogus');

    like($cmd->{_display}[-1], qr/Invalid strategy/, 'invalid strategy rejected');
    is($cfg->get_route_strategy('myroute'), 'role-aware', 'strategy unchanged after rejection');
    remove_tree($dir);
};

subtest '/api route strategy: no args shows current' => sub {
    my ($cfg, $dir) = fresh_config('strat3');
    $cfg->set_model_route('myroute', ['openrouter/foo']);
    $cfg->set('model', 'openrouter/foo');
    $cfg->save();

    my $cmd = make_cmd($cfg);
    $cmd->handle_route('use', 'myroute');
    $cmd->handle_route('strategy');

    my %kv = kv_hash($cmd);
    is($kv{'Active route'}, 'myroute', 'shows active route name');
    is($kv{'Strategy'}, 'sequential', 'shows sequential strategy');
    remove_tree($dir);
};

# /api route role
subtest '/api route role: assign model to role on role-aware route' => sub {
    my ($cfg, $dir) = fresh_config('role1');
    $cfg->set_model_route_config('dev', {
        strategy => 'role-aware',
        models => [],
        roles => { reasoning => { model => 'kilo/deepseek' } },
        default_role => 'reasoning',
    });
    $cfg->save();

    my $cmd = make_cmd($cfg);
    $cmd->handle_route('role', 'dev', 'coding', 'openrouter/deepseek');

    like($cmd->{_display}[-1], qr/role 'coding' -> openrouter\/deepseek/, 'role assignment confirmed');
    my $route_cfg = $cfg->get_model_route_config('dev');
    is($route_cfg->{roles}{coding}{model}, 'openrouter/deepseek', 'role model stored correctly');

    remove_tree($dir);
};

subtest '/api route role: assigning to sequential route promotes to role-aware' => sub {
    my ($cfg, $dir) = fresh_config('role2');
    $cfg->set_model_route('dev', ['openrouter/foo']);
    $cfg->save();

    my $cmd = make_cmd($cfg);
    $cmd->handle_route('role', 'dev', 'coding', 'openrouter/foo');

    my $route_cfg = $cfg->get_model_route_config('dev');
    is($route_cfg->{strategy}, 'role-aware', 'sequential route promoted to role-aware');
    is($route_cfg->{roles}{coding}{model}, 'openrouter/foo', 'role assigned');
    # default_role should be set to the assigned role
    is($route_cfg->{default_role}, 'coding', 'default_role set to assigned role');
    remove_tree($dir);
};

subtest '/api route role list' => sub {
    my ($cfg, $dir) = fresh_config('role3');
    $cfg->set_model_route_config('dev', {
        strategy => 'role-aware',
        models => [],
        roles => {
            coding    => { model => 'openrouter/deepseek' },
            reasoning => { model => 'kilo/deepseek' },
        },
        default_role => 'reasoning',
    });
    $cfg->save();

    my $cmd = make_cmd($cfg);
    $cmd->handle_route('role', 'dev', 'list');

    ok(grep { /ROLES: dev/ } @{$cmd->{_headers}}, 'ROLES header shown');
    my %kv = kv_hash($cmd);
    ok(exists $kv{coding}, 'coding role in key-values');
    ok(exists $kv{reasoning}, 'reasoning role in key-values');
    like($kv{coding}, qr/openrouter\/deepseek/, 'coding role model displayed');
    remove_tree($dir);
};

subtest '/api route role remove' => sub {
    my ($cfg, $dir) = fresh_config('role4');
    $cfg->set_model_route_config('dev', {
        strategy => 'role-aware',
        models => [],
        roles => {
            coding    => { model => 'openrouter/deepseek' },
            reasoning => { model => 'kilo/deepseek' },
        },
        default_role => 'reasoning',
    });
    $cfg->save();

    my $cmd = make_cmd($cfg);
    $cmd->handle_route('role', 'dev', 'remove', 'coding');

    like($cmd->{_display}[-1], qr/Role 'coding' removed/, 'removal confirmed');
    my $route_cfg = $cfg->get_model_route_config('dev');
    ok(!exists $route_cfg->{roles}{coding}, 'coding role removed');
    ok(exists $route_cfg->{roles}{reasoning}, 'reasoning role still present');

    remove_tree($dir);
};

# /api route default-role
subtest '/api route default-role' => sub {
    my ($cfg, $dir) = fresh_config('dr1');
    $cfg->set_model_route_config('dev', {
        strategy => 'role-aware',
        models => [],
        roles => {
            coding    => { model => 'openrouter/deepseek' },
            reasoning => { model => 'kilo/deepseek' },
        },
        default_role => 'reasoning',
    });
    $cfg->save();

    my $cmd = make_cmd($cfg);
    $cmd->handle_route('default-role', 'dev', 'coding');

    like($cmd->{_display}[-1], qr/default role set to 'coding'/, 'default role set confirmed');
    my $route_cfg = $cfg->get_model_route_config('dev');
    is($route_cfg->{default_role}, 'coding', 'default_role persisted as coding');

    # Setting to a non-existent role should fail
    $cmd->handle_route('default-role', 'dev', 'documentation');
    like($cmd->{_display}[-1], qr/not defined/, 'non-existent role rejected');

    remove_tree($dir);
};

# /api route fallback
subtest '/api route fallback: per-role fallbacks' => sub {
    my ($cfg, $dir) = fresh_config('fb1');
    $cfg->set_model_route_config('dev', {
        strategy => 'role-aware',
        models => [],
        roles => { coding => { model => 'openrouter/deepseek' } },
        default_role => 'coding',
    });
    $cfg->save();

    my $cmd = make_cmd($cfg);
    $cmd->handle_route('fallback', 'dev', 'coding', 'kilo/deepseek', 'openrouter/deepseek-v3');

    like($cmd->{_display}[-1], qr/fallback for role 'coding'/, 'fallback set confirmed');
    my $route_cfg = $cfg->get_model_route_config('dev');
    is($route_cfg->{fallbacks}{coding}[0], 'kilo/deepseek', 'first fallback stored');
    is($route_cfg->{fallbacks}{coding}[1], 'openrouter/deepseek-v3', 'second fallback stored');

    # Fallback for a non-existent role should fail
    $cmd->handle_route('fallback', 'dev', 'design', 'openrouter/x');
    like($cmd->{_display}[-1], qr/not assigned/, 'non-existent role fallback rejected');

    remove_tree($dir);
};

# /api route explain
subtest '/api route explain: role-aware route' => sub {
    my ($cfg, $dir) = fresh_config('ex1');
    $cfg->set_model_route_config('dev', {
        strategy => 'role-aware',
        models => [],
        roles => {
            coding    => { model => 'openrouter/deepseek' },
            reasoning => { model => 'kilo/deepseek' },
        },
        default_role => 'reasoning',
        fallbacks => { coding => ['kilo/deepseek-v3'] },
    });
    $cfg->save();

    my $cmd = make_cmd($cfg);
    $cmd->handle_route('use', 'dev');
    $cmd->handle_route('explain');

    ok(grep { /ROUTING EXPLAIN/ } @{$cmd->{_headers}}, 'explain header shown');
    my %kv = kv_hash($cmd);
    is($kv{Strategy}, 'role-aware', 'strategy shown as role-aware');
    ok(exists $kv{'Work role'}, 'work role shown');
    is($kv{'Default role'}, 'reasoning', 'default role shown');
    ok(exists $kv{coding}, 'coding role shown');
    ok(exists $kv{reasoning}, 'reasoning role shown');

    remove_tree($dir);
};

subtest '/api route explain: sequential route' => sub {
    my ($cfg, $dir) = fresh_config('ex2');
    $cfg->set_model_route('seq', ['openrouter/foo', 'kilo/bar']);
    $cfg->set('model', 'openrouter/foo');
    $cfg->save();

    my $cmd = make_cmd($cfg);
    $cmd->handle_route('use', 'seq');
    $cmd->handle_route('explain');

    ok(grep { /ROUTING EXPLAIN/ } @{$cmd->{_headers}}, 'explain header shown');
    my %kv = kv_hash($cmd);
    is($kv{Strategy}, 'sequential', 'sequential strategy shown');

    remove_tree($dir);
};

# /api route history
subtest '/api route history: no decisions yet' => sub {
    my ($cfg, $dir) = fresh_config('hi1');
    $cfg->set_model_route('seq', ['openrouter/foo', 'kilo/bar']);
    $cfg->save();

    my $cmd = make_cmd($cfg);
    $cmd->handle_route('history');

    like($cmd->{_display}[-1], qr/No routing decisions|No decisions recorded|Decisions are recorded/, 'empty history message');
    remove_tree($dir);
};

subtest '/api route history: with decisions' => sub {
    my ($cfg, $dir) = fresh_config('hi2');
    $cfg->set_model_route('seq', ['openrouter/foo', 'kilo/bar']);
    $cfg->save();

    my $session = cmd_session_with_decisions();
    my $cmd = make_cmd_with_session($cfg, $session);

    $cmd->handle_route('history', 10);

    ok(grep { /ROUTING HISTORY/ } @{$cmd->{_headers}}, 'history header shown');
    # Check key-values for decision content (display_key_value)
    my %kv = kv_hash($cmd);
    is($kv{decision}, 'cycle', 'decision type shown in key-values');
    is($kv{error}, 'rate_limit (429)', 'error label shown in key-values');

    remove_tree($dir);
};

# /api route explain with routing decisions
subtest '/api route explain: shows recent decisions' => sub {
    my ($cfg, $dir) = fresh_config('ex3');

    my $session = cmd_session_with_decisions();
    my $cmd = make_cmd_with_session($cfg, $session);

    $cmd->handle_route('explain');

    ok(grep { /RECENT DECISIONS/ } @{$cmd->{_headers}}, 'recent decisions header shown');
    ok(
        grep { /cycle/ } @{$cmd->{_display}},
        'decision content shown in explain'
    );

    remove_tree($dir);
};

done_testing();
