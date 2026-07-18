#!/usr/bin/env perl
# Integration test for provider-switch setting preservation using actual
# API command handlers (not just Config.pm directly). This catches bugs
# in the user-visible flow that may not show up in unit tests of Config.

use strict;
use warnings;
use lib './lib';
use Test::More;
use File::Temp qw(tempdir);

require CLIO::Core::Config;
use CLIO::Core::Config;
require CLIO::UI::Commands::API::Config;
use CLIO::UI::Commands::API::Config;
use CLIO::Util::JSON qw(decode_json);

# Mock session for API::Config handlers
package MockSession {
    sub new { bless { state => {}, saved => 0 }, shift }
    sub state { my $s = $_[0]->{state}; $_[1] ? ($_[0]->{state} = $_[1], return) : $s }
    sub save { $_[0]->{saved}++ }
}

sub read_disk {
    my ($path) = @_;
    open my $fh, '<', $path or die "Cannot read $path: $!";
    my $raw = do { local $/; <$fh> };
    close $fh;
    return decode_json($raw);
}

# Minimal mock objects that provide what API::Config handlers need
package MockChat {
    sub new { bless {}, shift }
    sub display_system_message { my ($s, $msg) = @_; print STDERR "[MSG] $msg\n"; }
    sub display_error_message { my ($s, $msg) = @_; print STDERR "[ERR] $msg\n"; }
    sub writeline { my ($s, $msg, %opts) = @_; print STDERR "[LINE] $msg\n"; }
}

package MockAuthHelper {
    sub new { bless {}, shift }
    sub reinit_api_manager { return 1 }
    sub check_github_auth { return 1 }
}

subtest 'integration: /api set provider minimax -> thinking on -> provider nvidia -> provider minimax' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);

    my $config = CLIO::Core::Config->new(config_dir => $tmpdir);
    my $session = MockSession->new();
    my $chat = MockChat->new();
    my $api = CLIO::UI::Commands::API::Config->new(
        chat => $chat,
        config => $config,
        session => $session,
        ai_agent => undef,
        debug => 0,
    );
    # Replace auth helper with mock
    no strict 'refs';
    *{$api . '::_get_auth_helper'} = sub { MockAuthHelper->new() };

    # /api set provider minimax
    $api->handle_set('provider', 'minimax', 0);
    is($config->{config}->{provider}, 'minimax', 'after /api set provider minimax');
    is($config->{config}->{model}, 'minimax/MiniMax-M3',
        'in-memory model is minimax/MiniMax-M3');

    # /api set thinking on
    $api->handle_set('thinking', 'on', 0);
    is($config->{config}->{show_thinking}, 1,
        'after /api set thinking on: show_thinking=1');

    my $disk1 = read_disk("$tmpdir/config.json");
    is($disk1->{model_configs}{'minimax/MiniMax-M3'}{show_thinking}, 1,
        'disk: model_configs->{minimax}->{show_thinking}=1');

    # /api set provider nvidia
    $api->handle_set('provider', 'nvidia', 0);

    # /api set provider minimax (back)
    $api->handle_set('provider', 'minimax', 0);

    is($config->{config}->{show_thinking}, 1,
        'after full round-trip via UI handlers: show_thinking=1');

    my $disk2 = read_disk("$tmpdir/config.json");
    is($disk2->{model_configs}{'minimax/MiniMax-M3'}{show_thinking}, 1,
        'disk: minimax entry has show_thinking=1');
    is($disk2->{model_configs}{'minimax/MiniMax-M3'}{show_thinking}, 1,
        'disk: model_configs minimax intact after UI-level round-trip');
};

done_testing();
