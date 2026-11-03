#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Unit tests for the agent iteration limit.
#
# The limit resolves in this order:
#   1. Caller-imposed cap passed to the constructor (0 = unlimited)
#   2. Session-only override (/api set max_iterations --session)
#   3. Persisted user setting (/api set max_iterations), 0 = unlimited
#   4. DEFAULT_MAX_ITERATIONS for non-interactive, 0 (unlimited) interactive
#
# The regression this guards: an explicit max_iterations of 0 used to be
# overwritten back to the safety default in non-interactive mode, because
# the check tested truthiness and 0 is falsy in Perl. 0 has to mean
# "unlimited" consistently, in every mode and at every precedence level.

use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../lib";

use Test::More;
use CLIO::Core::Config;

# Keep every Config instance in a throwaway tempdir so the test can never
# touch the real ~/.clio/config.json.
$ENV{CLIO_TEST} = 1;

# ── Fake chat that captures output for assertions ──
package FakeChat;
sub new { bless { output => [] }, shift }
sub display_system_message  { my ($s, $t) = @_; push @{$s->{output}}, "SYS:$t" }
sub display_success_message { my ($s, $t) = @_; push @{$s->{output}}, "OK:$t" }
sub display_error_message   { my ($s, $t) = @_; push @{$s->{output}}, "ERR:$t" }
sub writeline               { push @{$_[0]->{output}}, "WL:" . ($_[1] // '') }
sub colorize                { my ($s, $t, $c) = @_; return $t }

# ── Fake session exposing the api_config session override namespace ──
package FakeSession;
sub new { bless { state_data => { api_config => {} } }, shift }
sub state { return $_[0]->{state_data} }
sub save { return 1 }
sub session_id { return 'test-session' }

package main;

# =============================================================================
# Helpers
# =============================================================================

# A Config with an optional explicitly-set max_iterations.
sub make_config {
    my %opts = @_;
    my $config = CLIO::Core::Config->new();
    $config->set('max_iterations', $opts{max_iterations})
        if exists $opts{max_iterations};
    return $config;
}

# Build an orchestrator with just enough wiring to resolve the limit.
sub make_orchestrator {
    my (%opts) = @_;
    require CLIO::Core::WorkflowOrchestrator;

    my %args = (
        api_manager     => undef,
        session         => $opts{session} // FakeSession->new(),
        config          => $opts{config},
        debug           => 0,
        non_interactive => $opts{non_interactive} // 0,
    );
    $args{max_iterations} = $opts{max_iterations} if exists $opts{max_iterations};

    return CLIO::Core::WorkflowOrchestrator->new(%args);
}

# =============================================================================
# Test: Config::is_user_set
# =============================================================================
{
    my $config = make_config();
    is($config->is_user_set('max_iterations'), 0,
        'is_user_set: false for an unset key');

    $config->set('max_iterations', 0);
    is($config->is_user_set('max_iterations'), 1,
        'is_user_set: true after an explicit set of 0');
    is($config->get('max_iterations'), 0,
        'is_user_set: explicit 0 is stored, not replaced by a default');

    is($config->is_user_set('no_such_key'), 0,
        'is_user_set: false for an unknown key');
    is($config->is_user_set(undef), 0,
        'is_user_set: false for an undefined key');
}

# =============================================================================
# Test: default resolution by run mode
# =============================================================================
{
    my $interactive = make_orchestrator(
        config => make_config(),
        non_interactive => 0,
    );
    is($interactive->{max_iterations}, 0,
        'Interactive mode with no configured limit is unlimited');

    my $non_interactive = make_orchestrator(
        config => make_config(),
        non_interactive => 1,
    );
    is($non_interactive->{max_iterations}, 200,
        'Non-interactive mode with no configured limit uses the safety default');
}

# =============================================================================
# Test: an explicit 0 disables the cap in every mode
#
# This is the regression. Before the fix, a configured 0 was overwritten
# back to 200 in non-interactive mode.
# =============================================================================
{
    my $non_interactive = make_orchestrator(
        config => make_config(max_iterations => 0),
        non_interactive => 1,
    );
    is($non_interactive->{max_iterations}, 0,
        'Non-interactive mode with an explicit 0 is unlimited');

    my $interactive = make_orchestrator(
        config => make_config(max_iterations => 0),
        non_interactive => 0,
    );
    is($interactive->{max_iterations}, 0,
        'Interactive mode with an explicit 0 is unlimited');
}

# =============================================================================
# Test: an explicit non-zero limit applies in every mode
# =============================================================================
{
    my $non_interactive = make_orchestrator(
        config => make_config(max_iterations => 50),
        non_interactive => 1,
    );
    is($non_interactive->{max_iterations}, 50,
        'Non-interactive mode honours an explicit limit of 50');

    my $interactive = make_orchestrator(
        config => make_config(max_iterations => 50),
        non_interactive => 0,
    );
    is($interactive->{max_iterations}, 50,
        'Interactive mode honours an explicit limit of 50');
}

# =============================================================================
# Test: precedence
# =============================================================================
{
    # Caller-imposed cap beats the configured value.
    my $orch = make_orchestrator(
        config => make_config(max_iterations => 50),
        non_interactive => 1,
        max_iterations => 42,
    );
    is($orch->{max_iterations}, 42,
        'A caller-imposed cap wins over the configured value');

    # A caller-imposed 0 means unlimited, even with a configured limit.
    $orch = make_orchestrator(
        config => make_config(max_iterations => 50),
        non_interactive => 1,
        max_iterations => 0,
    );
    is($orch->{max_iterations}, 0,
        'A caller-imposed 0 wins over the configured value and means unlimited');

    # Session override beats the configured value.
    my $session = FakeSession->new();
    $session->state->{api_config}{max_iterations} = 7;
    $orch = make_orchestrator(
        config => make_config(max_iterations => 50),
        non_interactive => 1,
        session => $session,
    );
    is($orch->{max_iterations}, 7,
        'A session override wins over the configured value');

    # A session override of 0 means unlimited. The generic session override
    # helper treats 0 as "clear the override", so this needs its own path.
    $session = FakeSession->new();
    $session->state->{api_config}{max_iterations} = 0;
    $orch = make_orchestrator(
        config => make_config(max_iterations => 50),
        non_interactive => 1,
        session => $session,
    );
    is($orch->{max_iterations}, 0,
        'A session override of 0 means unlimited');

    # A caller-imposed cap beats a session override.
    $session = FakeSession->new();
    $session->state->{api_config}{max_iterations} = 7;
    $orch = make_orchestrator(
        config => make_config(max_iterations => 50),
        non_interactive => 1,
        session => $session,
        max_iterations => 42,
    );
    is($orch->{max_iterations}, 42,
        'A caller-imposed cap wins over a session override');
}

# =============================================================================
# Test: /api set max_iterations
# =============================================================================
{
    require CLIO::UI::Commands::API::Config;

    my $config = make_config();
    my $chat = FakeChat->new();
    my $cmd = CLIO::UI::Commands::API::Config->new(
        chat => $chat,
        config => $config,
        session => undef,
        ai_agent => undef,
        debug => 0,
    );

    # A valid value is accepted and persisted.
    $cmd->handle_set('max_iterations', '300', 0);
    is($config->get('max_iterations'), 300,
        '/api set max_iterations stores the value');
    is($config->is_user_set('max_iterations'), 1,
        '/api set max_iterations marks the key user-set');

    # 0 is a valid value meaning unlimited, and must not be rejected.
    $cmd->handle_set('max_iterations', '0', 0);
    is($config->get('max_iterations'), 0,
        '/api set max_iterations 0 stores unlimited');
    is($config->is_user_set('max_iterations'), 1,
        '/api set max_iterations 0 still marks the key user-set');

    # An invalid value is rejected without changing the stored value.
    $cmd->handle_set('max_iterations', 'abc', 0);
    is($config->get('max_iterations'), 0,
        '/api set max_iterations rejects a non-numeric value');

    $cmd->handle_set('max_iterations', '-5', 0);
    is($config->get('max_iterations'), 0,
        '/api set max_iterations rejects a negative value');

    # The setting now resolves as unlimited for a non-interactive run.
    my $orch = make_orchestrator(
        config => $config,
        non_interactive => 1,
    );
    is($orch->{max_iterations}, 0,
        'A limit configured through /api set disables the non-interactive cap');
}

# =============================================================================
# Test: /api set max_iterations --session
# =============================================================================
{
    require CLIO::UI::Commands::API::Config;

    my $config = make_config();
    my $chat = FakeChat->new();
    my $session = FakeSession->new();
    my $cmd = CLIO::UI::Commands::API::Config->new(
        chat => $chat,
        config => $config,
        session => $session,
        ai_agent => undef,
        debug => 0,
    );

    $cmd->handle_set('max_iterations', '0', 1);
    is($session->state->{api_config}{max_iterations}, 0,
        '/api set max_iterations --session stores the override');
    is($config->is_user_set('max_iterations'), 0,
        '/api set max_iterations --session leaves the global config untouched');
}

# =============================================================================
# Test: persistence round-trip
#
# A limit set through /api set has to survive a save and a reload, and it
# has to come back as an explicit value rather than the built-in default.
# Otherwise the setting silently reverts on the next launch.
# =============================================================================
{
    require CLIO::UI::Commands::API::Config;

    my $dir = "/tmp/clio_maxiter_rt_" . int(rand(1e9));
    mkdir $dir;

    my $config = CLIO::Core::Config->new(config_dir => $dir);
    my $cmd = CLIO::UI::Commands::API::Config->new(
        chat => FakeChat->new(),
        config => $config,
        session => undef,
        ai_agent => undef,
        debug => 0,
    );

    $cmd->handle_set('max_iterations', '0', 0);
    ok(-f "$dir/config.json", 'The limit is written to config.json');

    # Reload from disk into a fresh Config.
    my $reloaded = CLIO::Core::Config->new(config_dir => $dir);
    is($reloaded->get('max_iterations'), 0,
        'The reloaded limit is still 0');
    is($reloaded->is_user_set('max_iterations'), 1,
        'The reloaded limit is still marked user-set, so it is not the default');

    # And it resolves as unlimited for a non-interactive run.
    my $orch = make_orchestrator(
        config => $reloaded,
        non_interactive => 1,
    );
    is($orch->{max_iterations}, 0,
        'A limit reloaded from disk disables the non-interactive cap');

    unlink "$dir/config.json";
    rmdir $dir;
}

# =============================================================================
# Test: sub-agents inherit the configured limit
#
# SubAgent.pm hardcodes non_interactive => 1, so every sub-agent used to get
# the safety default no matter what was configured. Sub-agents build their
# own Config from the same file, so a persisted limit now reaches them.
# =============================================================================
{
    require CLIO::Core::SimpleAIAgent;

    my $dir = "/tmp/clio_maxiter_sub_" . int(rand(1e9));
    mkdir $dir;

    my $config = CLIO::Core::Config->new(config_dir => $dir);
    $config->set('max_iterations', 800);

    # Mirror SubAgent.pm: a fresh Config, and a SimpleAIAgent built from it
    # with non_interactive => 1. The API manager is stubbed - the
    # orchestrator only needs its config at construction time.
    my $stub_api = bless { config => $config }, 'StubAPIManager';
    my $agent = CLIO::Core::SimpleAIAgent->new(
        api => $stub_api,
        session => undef,
        debug => 0,
        non_interactive => 1,
    );

    is($agent->{orchestrator}{max_iterations}, 800,
        'A sub-agent inherits the configured iteration limit');

    unlink "$dir/config.json";
    rmdir $dir;
}

done_testing();
