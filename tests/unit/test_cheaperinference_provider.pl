#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
#
# Test: Cheaper Inference provider registration and /api models URL
# construction.
#
# Cheaper Inference serves its OpenAI-compatible API under /v1/, so the
# generic $host/v1/models fallback in _fetch_provider_models already
# builds the right URL. No provider-specific case is needed in Models.pm.

use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../../lib";

use Test::More;

BEGIN {
    no warnings 'redefine';
    eval { require CLIO::Compat::Terminal; };
    *CLIO::Compat::Terminal::GetTerminalSize = sub { return (80, 24); };
    *CLIO::Compat::Terminal::ReadMode     = sub { };
    *CLIO::Compat::Terminal::ReadKey      = sub { undef };
}

# Pre-load CLIO::Compat::HTTP so we can monkey-patch it before
# _fetch_provider_models uses it.
use CLIO::Compat::HTTP;

# Mock HTTP client: capture the URL and return a fake /v1/models response.
my $captured_url;
my $mock_response_body = '{"object":"list","data":['
    . '{"id":"gpt-5.4-mini","object":"model","created":0,"owned_by":"openai"},'
    . '{"id":"claude-sonnet-5","object":"model","created":0,"owned_by":"anthropic"}'
    . ']}';

{
    no warnings 'redefine';
    *CLIO::Compat::HTTP::new = sub {
        my ($class, %opts) = @_;
        return bless { timeout => $opts{timeout} }, $class;
    };
    *CLIO::Compat::HTTP::get = sub {
        my ($self, $url, %opts) = @_;
        $captured_url = $url;
        return bless {
            success         => 1,
            status          => 200,
            reason          => 'OK',
            content         => $mock_response_body,
            headers         => {},
        }, 'CLIO::Compat::HTTP::Response';
    };
}

# Keep Config away from the real ~/.clio.
$ENV{CLIO_TEST} = 1;

use CLIO::UI::Commands::API::Models;
use CLIO::Providers;

# --- Fake config that reports a Cheaper Inference API key ---
package FakeConfig;
sub new { return bless { provider => 'cheaperinference', _key => 'test-key-123' }, $_[0]; }
sub get {
    my ($s, $k) = @_;
    return $s->{$k} if exists $s->{$k};
    return undef;
}
sub get_provider_key { return $_[0]->{_key}; }
sub get_provider_base { return undef; }
sub save { return 1; }

# --- Fake chat object (Base.pm only needs writeline + colorize) ---
package FakeChat;
sub new { return bless {}, $_[0]; }
sub writeline                { return 1; }
sub colorize                 { return $_[1] // ''; }
sub display_system_message   { return 1; }
sub display_error_message    { return 1; }
sub display_success_message  { return 1; }

package main;

# ============================================================================
# Registry entry
# ============================================================================
my $provider_def = CLIO::Providers::get_provider('cheaperinference');
ok($provider_def, 'Cheaper Inference provider is defined in Providers.pm');
is($provider_def->{name}, 'Cheaper Inference', 'Display name is Cheaper Inference');
is($provider_def->{api_base}, 'https://api.cheaperinference.com/v1/chat/completions',
   'Cheaper Inference api_base is /v1/chat/completions');
is($provider_def->{model}, 'gpt-5.4-mini', 'Default model is gpt-5.4-mini');
is($provider_def->{requires_auth}, 'apikey', 'Cheaper Inference uses API key auth');
ok($provider_def->{supports_tools}, 'Cheaper Inference supports tools');
ok($provider_def->{supports_streaming}, 'Cheaper Inference supports streaming');

my $endpoint = CLIO::Providers::build_endpoint_config('cheaperinference', 'test-key-123');
is($endpoint->{path_suffix}, '', 'Path suffix empty (full URL in api_base)');
is($endpoint->{auth_header}, 'Authorization', 'Auth header is Authorization');
is($endpoint->{auth_value}, 'Bearer test-key-123', 'Auth value is Bearer token');
ok($endpoint->{route_timeout}, 'route_timeout propagates to endpoint config');

# ============================================================================
# /api models URL
# ============================================================================
my $cfg = FakeConfig->new();
my $cmd = CLIO::UI::Commands::API::Models->new(
    config   => $cfg,
    session  => undef,
    ai_agent => undef,
    chat     => FakeChat->new(),
    debug    => 0,
);

$captured_url = undef;
my $models = $cmd->_fetch_provider_models('cheaperinference', $provider_def, 'test-key-123', 0);

is($captured_url, 'https://api.cheaperinference.com/v1/models',
   'Cheaper Inference models URL uses the generic /v1/models endpoint');
ok($models && @$models, 'Cheaper Inference models are returned (not empty)');
is(scalar(@$models), 2, 'Both fake Cheaper Inference models are parsed');
is($models->[0]{id}, 'gpt-5.4-mini', 'First model id is gpt-5.4-mini');

done_testing();
