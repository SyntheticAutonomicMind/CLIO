#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
#
# Test: Opper provider registration, /api models URL construction and
# capability parsing.
#
# Opper serves its OpenAI-compatible API under /v3/compat/ rather than
# /v1/, so the generic $host/v1/models fallback in _fetch_provider_models
# would hit the wrong URL. Models.pm has an opper case (same shape as the
# kilo case) that uses https://api.opper.ai/v3/compat/models.
#
# Each /v3/compat/models entry carries context_length at the top level,
# and nests max_output_tokens and a capabilities array (strings such as
# "tools" and "vision") under an "opper" object. The OpenAI-compatible
# MCM fetcher reads both.

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
# _fetch_provider_models and the MCM fetcher use it.
use CLIO::Compat::HTTP;

# Mock HTTP client: capture the URL and return a fake /v3/compat/models response.
my $captured_url;
my $mock_response_body = '{"object":"list","data":['
    . '{"id":"claude-sonnet-4-6","object":"model","created":0,"owned_by":"opper","context_length":1000000,'
    . '"opper":{"kind":"pool","type":"llm","capabilities":["text","vision","structured_output","tools","pdf","reasoning"],"max_output_tokens":64000}},'
    . '{"id":"deepseek-v4-pro","object":"model","created":0,"owned_by":"opper","context_length":1000000,'
    . '"opper":{"kind":"pool","type":"llm","capabilities":["text","tools","structured_output","reasoning"],"max_output_tokens":65536}}'
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

# Keep Config (used inside the MCM fetcher) away from the real ~/.clio.
$ENV{CLIO_TEST} = 1;

use CLIO::UI::Commands::API::Models;
use CLIO::Core::ModelCapabilitiesManager;
use CLIO::Providers;

# --- Fake config that reports an Opper API key ---
package FakeConfig;
sub new { return bless { provider => 'opper', _key => 'test-key-123' }, $_[0]; }
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
my $provider_def = CLIO::Providers::get_provider('opper');
ok($provider_def, 'Opper provider is defined in Providers.pm');
is($provider_def->{name}, 'Opper', 'Display name is Opper');
is($provider_def->{api_base}, 'https://api.opper.ai/v3/compat/chat/completions',
   'Opper api_base is /v3/compat/chat/completions');
is($provider_def->{model}, 'claude-sonnet-4-6', 'Default model is claude-sonnet-4-6');
is($provider_def->{requires_auth}, 'apikey', 'Opper uses API key auth');
ok($provider_def->{supports_tools}, 'Opper supports tools');
ok($provider_def->{supports_streaming}, 'Opper supports streaming');

my $endpoint = CLIO::Providers::build_endpoint_config('opper', 'test-key-123');
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
my $models = $cmd->_fetch_provider_models('opper', $provider_def, 'test-key-123', 0);

is($captured_url, 'https://api.opper.ai/v3/compat/models',
   'Opper models URL uses the /v3/compat/models endpoint');
ok($captured_url !~ m{/v1/models$},
   'Opper URL does NOT use the generic /v1/models suffix');
ok($models && @$models, 'Opper models are returned (not empty)');
is(scalar(@$models), 2, 'Both fake Opper models are parsed');
is($models->[0]{id}, 'claude-sonnet-4-6', 'First model id is claude-sonnet-4-6');
is($models->[0]{_context_tokens}, 1000000, 'First model context tokens parsed from response');

# ============================================================================
# MCM capability parsing from the opper object
# ============================================================================
{
    local $ENV{CLIO_API_KEY} = 'test-key-123';
    my $mcm = CLIO::Core::ModelCapabilitiesManager->new();

    $captured_url = undef;
    my $caps = $mcm->_fetch_openai_compatible_capabilities(
        'opper', 'claude-sonnet-4-6', 'https://api.opper.ai/v3/compat/chat/completions');
    is($captured_url, 'https://api.opper.ai/v3/compat/models',
       'MCM fetcher derives /v3/compat/models from the api_base');
    ok($caps, 'MCM returns capabilities for claude-sonnet-4-6');
    is($caps->{context_window}, 1000000, 'context_window read from top-level context_length');
    is($caps->{max_output_tokens}, 64000, 'max_output_tokens read from opper.max_output_tokens');
    is($caps->{supports_vision}, 1, 'vision read from opper.capabilities');
    is($caps->{supports_tools}, 1, 'tools supported');

    my $ds = $mcm->_fetch_openai_compatible_capabilities(
        'opper', 'deepseek-v4-pro', 'https://api.opper.ai/v3/compat/chat/completions');
    ok($ds, 'MCM returns capabilities for deepseek-v4-pro');
    is($ds->{max_output_tokens}, 65536, 'max_output_tokens read per model');
    is($ds->{supports_vision}, 0, 'no vision when opper.capabilities omits it');
}

done_testing();
