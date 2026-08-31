#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Test: /api models URL construction for the Kilo provider.
#
# Regression: The /api models command did not list Kilo provider models
# (or any models for Kilo, despite the provider being configured with an
# API key). Root cause: _fetch_provider_models in Models.pm had no
# provider-specific URL case for Kilo, so it fell through to the generic
# OAI-compatible branch which constructs $host/v1/models. For Kilo's
# api_base (https://api.kilo.ai/api/gateway/chat/completions) this
# produced the wrong URL https://api.kilo.ai/v1/models. The correct
# endpoint -- matching APIManager.pm's _detect_api_type_and_url -- is
# https://api.kilo.ai/api/gateway/models.
#
# Fix: Added a kilo-specific case in the else branch of
# _fetch_provider_models, mirroring the existing OpenRouter special case.

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
# _fetch_provider_models does `require CLIO::Compat::HTTP`.
use CLIO::Compat::HTTP;

# Mock HTTP client: capture the URL and return a fake OpenAI-style response.
my $captured_url;
my $mock_response_body = '{"data":[{"id":"kilo-auto/free","name":"Auto Free","context_length":128000,"max_completion_tokens":16384},{"id":"kilo-auto/pro","name":"Auto Pro","context_length":200000,"max_completion_tokens":16384}]}';

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

$ENV{CLIO_NO_CONFIG_LOAD} = 1;

use CLIO::UI::Commands::API::Models;
use CLIO::Providers;

# --- Fake config that reports a Kilo API key ---
package FakeConfig;
sub new { return bless { provider => 'kilo', _key => 'test-key-123' }, $_[0]; }
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

my $cfg = FakeConfig->new();
my $cmd = CLIO::UI::Commands::API::Models->new(
    config   => $cfg,
    session  => undef,
    ai_agent => undef,
    chat     => FakeChat->new(),
    debug    => 0,
);

my $provider_def = CLIO::Providers::get_provider('kilo');
ok($provider_def, 'Kilo provider is defined in Providers.pm');
is($provider_def->{api_base}, 'https://api.kilo.ai/api/gateway/chat/completions',
   'Kilo api_base is /api/gateway/chat/completions');

# Fetch models for the Kilo provider
$captured_url = undef;
my $models = $cmd->_fetch_provider_models('kilo', $provider_def, 'test-key-123', 0);

# --- Assertions ---

is($captured_url, 'https://api.kilo.ai/api/gateway/models',
   'Kilo models URL uses the correct /api/gateway/models endpoint');

ok($captured_url !~ m{/v1/models$},
   'Kilo URL does NOT use the wrong /v1/models suffix (the bug)');

ok($models && @$models, 'Kilo models are returned (not empty)');

is($models->[0]{id}, 'kilo-auto/free', 'First model id is kilo-auto/free');
is($models->[0]{_context_tokens}, 128000, 'First model context tokens parsed from response');
is($models->[0]{_output_tokens}, 16384, 'First model output tokens parsed from response');

is(scalar(@$models), 2, 'Both fake Kilo models are parsed');

done_testing();
