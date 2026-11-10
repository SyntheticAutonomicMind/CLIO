#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
#
# Test: Synap by Linkrra provider registration and /api models URL
# construction.
#
# Synap serves its OpenAI-compatible API under /v1/, so the generic
# $host/v1/models fallback in _fetch_provider_models already builds the
# right URL. No provider-specific case is needed in Models.pm.
#
# Two Synap-specific facts the registry entry has to preserve, because
# both are easy to get wrong:
#
#   1. A request with no API key answers 402 with an x402 payment
#      challenge, not 401 - the same endpoint can be paid per call in
#      USDC. A test that asserts 401 for this provider fails against the
#      live service, so nothing here asserts an unauthenticated status.
#   2. The published model ids mix bare ids (models on Linkrra's own
#      GPUs) with namespaced ids. model_id_format 'provider/model'
#      handles both: a bare id has no prefix to strip and survives
#      unchanged.

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

# Mock HTTP client: capture the URL and return a fake /v1/models response
# shaped like the live catalogue, including one bare and one namespaced id.
my $captured_url;
my $captured_headers;
my $mock_response_body = '{"object":"list","data":['
    . '{"id":"gpt-oss-20b","object":"model","created":0,"owned_by":"linkrra",'
    . '"context_length":65536,"top_provider":{"context_length":65536,"max_completion_tokens":65536}},'
    . '{"id":"qwen/qwen3-vl-30b-a3b-instruct","object":"model","created":0,"owned_by":"linkrra",'
    . '"context_length":65536,"top_provider":{"context_length":65536,"max_completion_tokens":65536}}'
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
        $captured_headers = $opts{headers};
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

# --- Fake config that reports a Synap API key ---
package FakeConfig;
sub new { return bless { provider => 'synap', _key => 'test-key-123' }, $_[0]; }
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
my $provider_def = CLIO::Providers::get_provider('synap');
ok($provider_def, 'Synap provider is defined in Providers.pm');
is($provider_def->{name}, 'Synap by Linkrra', 'Display name is Synap by Linkrra');
is($provider_def->{api_base}, 'https://synap402.com/v1/chat/completions',
   'Synap api_base is /v1/chat/completions');
is($provider_def->{model}, 'gpt-oss-20b',
   'Default model is the fixed model gpt-oss-20b, not a router id');
is($provider_def->{requires_auth}, 'apikey', 'Synap uses API key auth');
ok($provider_def->{supports_tools}, 'Synap supports tools');
ok($provider_def->{supports_streaming}, 'Synap supports streaming');

my $endpoint = CLIO::Providers::build_endpoint_config('synap', 'test-key-123');
is($endpoint->{path_suffix}, '', 'Path suffix empty (full URL in api_base)');
is($endpoint->{auth_header}, 'Authorization', 'Auth header is Authorization');
is($endpoint->{auth_value}, 'Bearer test-key-123', 'Auth value is Bearer token');
ok($endpoint->{route_timeout}, 'route_timeout propagates to endpoint config');

# ============================================================================
# URL detection - both the canonical host and the Pool alias
# ============================================================================
my $patterns = $provider_def->{url_detection_patterns};
ok($patterns && @$patterns, 'Synap declares url_detection_patterns');
ok(
    (grep { 'https://synap402.com/v1/chat/completions' =~ $_ } @$patterns) ? 1 : 0,
    'Canonical synap402.com URL is detected as Synap'
);
ok(
    (grep { 'https://pool.linkrra.com/v1/chat/completions' =~ $_ } @$patterns) ? 1 : 0,
    'The pool.linkrra.com alias is detected as Synap'
);

# ============================================================================
# Defaults match the registry (no drift between Providers.pm and the
# provider-defaults.json fallback used when the live feed is unavailable)
# ============================================================================
SKIP: {
    my $defaults_path = "$FindBin::Bin/../../lib/CLIO/Core/model-data/provider-defaults.json";
    skip 'provider-defaults.json not found', 3 unless -f $defaults_path;

    require CLIO::Util::JSON;
    my $raw = do {
        open my $fh, '<:encoding(UTF-8)', $defaults_path
            or die "Cannot read $defaults_path: $!";
        local $/;
        <$fh>;
    };
    my $data = CLIO::Util::JSON::decode_json($raw);
    my $root = $data->{providers} || $data;
    my $synap = $root->{synap};

    ok($synap, 'provider-defaults.json has a synap entry');
    is($synap && $synap->{default_model}, 'gpt-oss-20b',
       'provider-defaults default_model matches the registry default');
    is($synap && $synap->{max_context_tokens}, 65536,
       'provider-defaults context matches the published gpt-oss-20b context');
}

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
my $models = $cmd->_fetch_provider_models('synap', $provider_def, 'test-key-123', 0);

is($captured_url, 'https://synap402.com/v1/models',
   'Synap models URL uses the generic /v1/models endpoint');
ok($models && @$models, 'Synap models are returned (not empty)');
is(scalar(@$models), 2, 'Both fake Synap models are parsed');
is($models->[0]{id}, 'gpt-oss-20b', 'First model id is gpt-oss-20b');
is($models->[1]{id}, 'qwen/qwen3-vl-30b-a3b-instruct',
   'A namespaced model id is preserved verbatim');

# Public discovery must not require or invent a credential. Inference auth
# remains unchanged, and non-public providers must still require their key.
$captured_url = undef;
$models = $cmd->_fetch_provider_models('synap', $provider_def, undef, 1);
is(scalar(@$models), 2, 'Public Synap discovery works before key configuration');
is($captured_url, 'https://synap402.com/v1/models', 'Public request reaches the correct URL');
ok(!exists $captured_headers->{Authorization}, 'No empty or fabricated Authorization header');
is($provider_def->{requires_auth}, 'apikey', 'Public discovery does not disable inference authentication');
$captured_url = undef;
my $private_provider = { %$provider_def, public_models => 0 };
$models = $cmd->_fetch_provider_models('synap', $private_provider, undef, 1);
is(scalar(@$models), 0, 'Private provider still requires a credential');
ok(!defined $captured_url, 'Private provider without key makes no HTTP request');

# MCM uses a separate transport and must also be able to read public metadata.
require CLIO::Core::ModelCapabilitiesManager;
{
    no warnings 'redefine';
    no warnings 'once';
    local *CLIO::Core::ModelCapabilitiesManager::get_http = sub { bless {}, 'PublicModelsHTTP' };
    my $mcm = bless {}, 'CLIO::Core::ModelCapabilitiesManager';
    my $caps = $mcm->_fetch_openai_compatible_capabilities('synap', 'gpt-oss-20b');
    is($caps->{context_window}, 65536, 'Public MCM reads real-shaped context metadata without a key');
    ok(!exists $captured_headers->{Authorization}, 'Public MCM omits the Authorization header');
}

package PublicModelsHTTP;
sub get {
    my ($self, $url, %opts) = @_;
    $captured_url = $url;
    $captured_headers = $opts{headers};
    return { success => 1, status => 200, content => $mock_response_body };
}
package main;

done_testing();
