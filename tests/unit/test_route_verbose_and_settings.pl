#!/usr/bin/env perl
# Test /api route verbose, /api route set delay, /api route set max_attempts.
#
# Covers the new knobs that control model-routing behavior:
#   - route_verbose (0/1) suppresses the per-cycle "rerouting to X" system message
#   - route_retry_delay (seconds) inserts a pause between model switches
#   - route_max_attempts (int) caps total routing attempts before giving up

use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use Test::More;
use File::Path qw(remove_tree);

use CLIO::Core::Config;

# =============================================================================
# Stub harness (mirrors test_route_use_provider_switch.pl)
# =============================================================================

package CLIO::Test::RouteSettingsCmd;
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
    };
    bless $self, $class;
    return $self;
}

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

sub _get_auth_helper { return bless {}, 'CLIO::Test::AuthHelper'; }

package CLIO::Test::AuthHelper;
sub reinit_api_manager { }
sub check_github_auth  { }

package CLIO::Test::Session;
sub new { bless { state => { billing => {} } }, $_[1] }
sub state { $_[0]->{state} }
sub save  { }

package CLIO::Test::Agent;
sub new { bless {}, $_[1] }

package main;

sub fresh_config {
    my $tag = shift // 'main';
    my $dir = "/tmp/clio-test-route-settings-$tag-" . int(rand(100000));
    remove_tree($dir) if -d $dir;
    my $config = CLIO::Core::Config->new(config_dir => $dir);
    return ($config, $dir);
}

sub make_cmd {
    my ($config) = @_;
    return CLIO::Test::RouteSettingsCmd->new(
        config   => $config,
        session  => CLIO::Test::Session->new('CLIO::Test::Session'),
        ai_agent => CLIO::Test::Agent->new('CLIO::Test::Agent'),
        chat     => undef,
    );
}

# =============================================================================
# /api route verbose
# =============================================================================

subtest '/api route verbose: shows current state when no argument' => sub {
    my ($cfg, $dir) = fresh_config('v-current');
    my $cmd = make_cmd($cfg);
    $cmd->handle_route('verbose');
    is(scalar @{$cmd->{_key_values}}, 1, 'one key/value row shown');
    is($cmd->{_key_values}[0][0], 'Route verbose', 'label is "Route verbose"');
    is($cmd->{_key_values}[0][1], 'on', 'default is on');
    remove_tree($dir);
};

subtest '/api route verbose on / off / quiet toggle' => sub {
    my ($cfg, $dir) = fresh_config('v-toggle');
    my $cmd = make_cmd($cfg);

    $cmd->handle_route('verbose', 'off');
    is($cfg->get_route_verbose(), 0, 'off: set to 0');

    $cmd->handle_route('verbose', 'on');
    is($cfg->get_route_verbose(), 1, 'on: set to 1');

    $cmd->handle_route('verbose', 'quiet');
    is($cfg->get_route_verbose(), 0, 'quiet: alias for off');

    $cmd->handle_route('verbose', 'bogus');
    like($cmd->{_display}[-1], qr/Usage: \/api route verbose/, 'bogus value prints usage');
    is($cfg->get_route_verbose(), 0, 'bogus value did not change state');

    remove_tree($dir);
};

subtest '/api route verbose persists across save/reload' => sub {
    my ($cfg, $dir) = fresh_config('v-persist');
    $cfg->set_route_verbose(0);
    $cfg->save();
    my $cfg2 = CLIO::Core::Config->new(config_dir => $dir);
    is($cfg2->get_route_verbose(), 0, 'route_verbose=0 survives save/reload');
    remove_tree($dir);
};

# =============================================================================
# /api route set delay
# =============================================================================

subtest '/api route set delay' => sub {
    my ($cfg, $dir) = fresh_config('d-set');
    my $cmd = make_cmd($cfg);

    $cmd->handle_route('set', 'delay', '2.5');
    is($cfg->get_route_retry_delay(), 2.5, 'delay set to 2.5');

    $cmd->handle_route('set', 'delay', '0');
    is($cfg->get_route_retry_delay(), 0, 'delay can be 0 to disable');

    $cmd->handle_route('set', 'delay', '1');
    is($cfg->get_route_retry_delay(), 1, 'integer 1 accepted');

    $cmd->handle_route('set', 'delay', 'bogus');
    like($cmd->{_display}[-1], qr/Usage: \/api route set delay/, 'bogus value prints usage');

    $cmd->handle_route('set', 'delay', '-1');
    like($cmd->{_display}[-1], qr/Usage: \/api route set delay/, 'negative value prints usage');

    remove_tree($dir);
};

subtest '/api route set delay persists' => sub {
    my ($cfg, $dir) = fresh_config('d-persist');
    $cfg->set_route_retry_delay(0.75);
    $cfg->save();
    my $cfg2 = CLIO::Core::Config->new(config_dir => $dir);
    is($cfg2->get_route_retry_delay(), 0.75, 'delay survives save/reload');
    remove_tree($dir);
};

# =============================================================================
# /api route set max_attempts
# =============================================================================

subtest '/api route set max_attempts' => sub {
    my ($cfg, $dir) = fresh_config('m-set');
    my $cmd = make_cmd($cfg);

    $cmd->handle_route('set', 'max_attempts', '20');
    is($cfg->get_route_max_attempts(), 20, 'max_attempts set to 20');

    $cmd->handle_route('set', 'max_attempts', '6');
    is($cfg->get_route_max_attempts(), 6, 'max_attempts set to 6');

    $cmd->handle_route('set', 'attempts', '9');
    is($cfg->get_route_max_attempts(), 9, 'attempts is an alias for max_attempts');

    $cmd->handle_route('set', 'max_attempts', '0');
    like($cmd->{_display}[-1], qr/Usage: \/api route set max_attempts/, '0 prints usage');

    $cmd->handle_route('set', 'max_attempts', 'abc');
    like($cmd->{_display}[-1], qr/Usage: \/api route set max_attempts/, 'non-numeric prints usage');

    $cmd->handle_route('set', 'unknown_key', '1');
    like($cmd->{_display}[-1], qr/Unknown route setting/, 'unknown key prints error');

    remove_tree($dir);
};

# =============================================================================
# /api route list shows settings footer
# =============================================================================

subtest '/api route list shows ROUTING SETTINGS footer' => sub {
    my ($cfg, $dir) = fresh_config('l-settings');
    $cfg->set_route_verbose(0);
    $cfg->set_route_retry_delay(0.5);
    $cfg->set_route_max_attempts(20);

    my $cmd = make_cmd($cfg);
    $cmd->handle_route('list');

    is(scalar @{$cmd->{_headers}}, 1, 'one header section');
    is($cmd->{_headers}[0], 'ROUTING SETTINGS', 'footer header is ROUTING SETTINGS');

    my %kv = map { $_->[0] => $_->[1] } @{$cmd->{_key_values}};
    is($kv{verbose}, 'off', 'footer shows verbose=off');
    is($kv{delay}, '0.5s', 'footer shows delay=0.5s');
    is($kv{max_attempts}, 20, 'footer shows max_attempts=20');

    remove_tree($dir);
};

subtest '/api route list with no routes still shows settings footer' => sub {
    my ($cfg, $dir) = fresh_config('l-empty');
    my $cmd = make_cmd($cfg);
    $cmd->handle_route('list');
    is(scalar @{$cmd->{_headers}}, 1, 'one header section');
    is($cmd->{_headers}[0], 'ROUTING SETTINGS', 'footer header is ROUTING SETTINGS');
    remove_tree($dir);
};

# =============================================================================
# handle_route dispatches the new actions
# =============================================================================

subtest 'handle_route dispatches verbose and set correctly' => sub {
    my ($cfg, $dir) = fresh_config('d-dispatch');
    my $cmd = make_cmd($cfg);

    $cmd->handle_route('verbose', 'off');
    is($cfg->get_route_verbose(), 0, 'handle_route -> verbose dispatches correctly');

    $cmd->handle_route('set', 'delay', '1.5');
    is($cfg->get_route_retry_delay(), 1.5, 'handle_route -> set delay dispatches correctly');

    $cmd->handle_route('set', 'max_attempts', '30');
    is($cfg->get_route_max_attempts(), 30, 'handle_route -> set max_attempts dispatches correctly');

    $cmd->handle_route('bogus');
    like($cmd->{_display}[-1], qr/Unknown route action: bogus/, 'unknown action errors out');

    remove_tree($dir);
};

done_testing();

