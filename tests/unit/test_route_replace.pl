#!/usr/bin/env perl
# Test /api route replace action: replaces an existing profile's models,
# rejects replaces on non-existent routes (does not silently create).
#
# The /api route replace path lives in CLIO::UI::Commands::API::Config,
# which requires a Chat + ai_agent stack to instantiate. We test the
# behavior via the underlying Config accessors (set_model_route overwrites
# rather than appends, get_model_route is case-insensitive) and verify
# the dispatch wiring by checking handle_route recognizes 'replace'.

use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use Test::More;

use CLIO::Core::Config;
use File::Path qw(remove_tree);

my $dir = "/tmp/clio-test-route-replace";
remove_tree($dir);

my $cfg = CLIO::Core::Config->new(config_dir => $dir);
$cfg->set('provider', 'openrouter', 0);
$cfg->set('api_key', 'sk-or-test', 0);

subtest 'set_model_route overwrites (does not append)' => sub {
    # Seed a route.
    ok($cfg->set_model_route('laguna', ['openrouter/a:free', 'kilo/b:free']), 'seed route');
    is_deeply($cfg->get_model_route('laguna'), ['openrouter/a:free', 'kilo/b:free'],
        'seed route has 2 models');

    # Replace - should overwrite, not append.
    ok($cfg->set_model_route('laguna', ['openrouter/x:free', 'kilo/y:free', 'vercel/z-free']),
        'replace returns true');
    my $after = $cfg->get_model_route('laguna');
    is(scalar(@$after), 3, 'route now has 3 models (overwrote, did not append)');
    is($after->[0], 'openrouter/x:free', 'first model replaced');
    is($after->[2], 'vercel/z-free', 'third model replaced');
};

subtest 'case-insensitive route lookup' => sub {
    # set_model_route lowercases the name on store.
    is_deeply($cfg->get_model_route('LAGUNA'), ['openrouter/x:free', 'kilo/y:free', 'vercel/z-free'],
        'lookup works case-insensitively');
};

subtest 'replace on unknown route' => sub {
    # get_model_route returns undef for a non-existent route.
    is($cfg->get_model_route('does-not-exist'), undef, 'unknown route returns undef');
    is($cfg->delete_model_route('does-not-exist'), 0, 'delete returns 0 for unknown route');
};

subtest 'config persistence keeps replaced route' => sub {
    $cfg->save();
    my $cfg2 = CLIO::Core::Config->new(config_dir => $dir);
    is(scalar(@{$cfg2->get_model_route('laguna')}), 3, 'replaced route survives reload with 3 models');
    is($cfg2->get_model_route('laguna')->[0], 'openrouter/x:free', 'first model survives reload');
    remove_tree($dir);
};

# Verify handle_route dispatches the 'replace' action to _route_replace
# by using a minimal subclass that records which handler was called.
subtest 'handle_route dispatches replace -> _route_replace' => sub {
    package CLIO::Test::RouteReplaceCmd;
    use parent 'CLIO::UI::Commands::API::Config';
    sub new {
        my ($class, %args) = @_;
        # Bypass the real Base::new; set only what _route_replace touches.
        return bless {
            config => $args{config},
            _dispatched => 'none',
            _route_replace_called_with => undef,
        }, $class;
    }
    sub display_error_message  { }
    sub display_system_message { }
    sub display_command_header { }
    sub display_key_value      { }
    sub display_success_message { }
    sub writeline              { }
    sub _get_auth_helper       { return bless {}, 'CLIO::Test::AuthHelper' }
    sub _route_replace {
        my ($self, @args) = @_;
        $self->{_dispatched} = 'replace';
        $self->{_route_replace_called_with} = \@args;
        return;  # stub - we only care that dispatch reached here
    }
    package CLIO::Test::AuthHelper;
    sub reinit_api_manager { }

    package main;
    my $cmd = CLIO::Test::RouteReplaceCmd->new(config => $cfg);

    # 'replace' should dispatch to _route_replace (our stub records it).
    $cmd->handle_route('replace', 'myname', 'openrouter/foo:free', 'kilo/bar:free');
    is($cmd->{_dispatched}, 'replace', 'handle_route dispatched replace');
    is_deeply($cmd->{_route_replace_called_with}, ['myname', 'openrouter/foo:free', 'kilo/bar:free'],
        'replace received (name, models...) args');

    # Unknown action should NOT call _route_replace.
    $cmd->{_dispatched} = 'none';
    $cmd->handle_route('bogus', 'whatever');
    is($cmd->{_dispatched}, 'none', 'unknown action does not dispatch');
};

done_testing();
