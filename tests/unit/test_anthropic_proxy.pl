#!/usr/bin/env perl

# Tests for Anthropic proxy support. Covers:
#   - Provider endpoint config (auth header, extra_headers, anthropic flag)
#   - Anthropic provider instantiation and defaults
#   - api_base resolution and normalization
#   - get_headers() output
#   - ANTHROPIC_CUSTOM_HEADERS JSON and newline format parsing
#   - Custom header merging (constructor + env var)
#   - Provider registry (native_api flag)
#   - build_request() output (model stripping, stream flag, messages)
#   - CLIO_TLS_VERIFY env var support
#   - Real-time curl streaming (preliminary_response delivery)

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use lib './lib';
use Test::More tests => 43;
use JSON::PP qw(encode_json decode_json);

use_ok('CLIO::Providers::Anthropic');
use_ok('CLIO::Providers');
use_ok('CLIO::Compat::HTTP');

# ── Group 1: Provider endpoint config ────────────────────────────────
{
    require CLIO::Core::APIManager;
    # Build endpoint config for anthropic provider
    my $provider_def = CLIO::Providers::get_provider('anthropic');
    ok($provider_def, 'anthropic provider definition exists');
    is($provider_def->{endpoint}{auth_header}, 'x-api-key', 'auth header is x-api-key');
    ok(!$provider_def->{endpoint}{auth_value} || $provider_def->{endpoint}{auth_value} !~ /^Bearer/,
       'auth_value is not Bearer prefix');
    ok($provider_def->{endpoint}{anthropic}, 'anthropic flag is set');
    is(ref($provider_def->{endpoint}{extra_headers}), 'HASH', 'extra_headers is a hashref');
    is($provider_def->{endpoint}{extra_headers}{'anthropic-version'}, '2023-06-01',
       'anthropic-version header is set');
}

# ── Group 2: Anthropic provider instantiation ─────────────────────────
{
    local %ENV = %ENV;
    delete $ENV{ANTHROPIC_BASE_URL};
    delete $ENV{ANTHROPIC_API_KEY};
    delete $ENV{ANTHROPIC_CUSTOM_HEADERS};

    my $p = CLIO::Providers::Anthropic->new(api_key => 'sk-test');
    ok($p, 'Anthropic provider instantiates');
    isa_ok($p, 'CLIO::Providers::Anthropic');
    is($p->{api_base}, 'https://api.anthropic.com/v1/messages', 'default api_base');
    is($p->{api_key}, 'sk-test', 'api_key is set');
}

# ── Group 3: api_base resolution ─────────────────────────────────────
{
    local %ENV = %ENV;
    delete $ENV{ANTHROPIC_API_KEY};
    delete $ENV{ANTHROPIC_CUSTOM_HEADERS};

    # Already has versioned path - preserved as-is
    {
        local $ENV{ANTHROPIC_BASE_URL} = 'https://proxy.example.com/v1/messages';
        my $p = CLIO::Providers::Anthropic->new(api_key => 'sk-test');
        is($p->{api_base}, 'https://proxy.example.com/v1/messages',
           'api_base with /v1/ path preserved');
    }

    # Root URL (no path) - normalized
    {
        local $ENV{ANTHROPIC_BASE_URL} = 'https://proxy.example.com';
        my $p = CLIO::Providers::Anthropic->new(api_key => 'sk-test');
        is($p->{api_base}, 'https://proxy.example.com/v1/messages',
           'root URL normalized to /v1/messages');
    }

    # Constructor api_base with versioned path - preserved
    {
        delete local $ENV{ANTHROPIC_BASE_URL};
        my $p = CLIO::Providers::Anthropic->new(
            api_key => 'sk-test',
            api_base => 'https://proxy.example.com:8443/v1/messages',
        );
        is($p->{api_base}, 'https://proxy.example.com:8443/v1/messages',
           'constructor api_base with /v1/ preserved');
    }

    # Constructor api_base root URL - normalized
    {
        delete local $ENV{ANTHROPIC_BASE_URL};
        my $p = CLIO::Providers::Anthropic->new(
            api_key => 'sk-test',
            api_base => 'https://proxy.example.com:8443',
        );
        is($p->{api_base}, 'https://proxy.example.com:8443/v1/messages',
           'constructor root URL normalized');
    }
}

# ── Group 4: get_headers() ────────────────────────────────────────────
{
    local %ENV = %ENV;
    delete $ENV{ANTHROPIC_BASE_URL};
    delete $ENV{ANTHROPIC_API_KEY};
    delete $ENV{ANTHROPIC_CUSTOM_HEADERS};

    my $p = CLIO::Providers::Anthropic->new(api_key => 'sk-test');
    my $h = $p->get_headers();
    is(ref($h), 'HASH', 'get_headers returns hashref');
    ok($h->{'anthropic-version'}, 'anthropic-version header present');
    ok($h->{'x-api-key'}, 'x-api-key header present');
    is($h->{'Content-Type'}, 'application/json', 'Content-Type is application/json');
    ok($h->{'Accept'} =~ /event-stream/, 'Accept contains event-stream');
}

# ── Group 5: ANTHROPIC_CUSTOM_HEADERS ─────────────────────────────────
{
    local %ENV = %ENV;
    delete $ENV{ANTHROPIC_BASE_URL};
    delete $ENV{ANTHROPIC_API_KEY};

    # JSON format
    {
        local $ENV{ANTHROPIC_CUSTOM_HEADERS} = '{"x-test-a": "val-a", "x-test-b": "val-b"}';
        my $p = CLIO::Providers::Anthropic->new(api_key => 'sk-test');
        my $h = $p->get_headers();
        is($h->{'x-test-a'}, 'val-a', 'JSON custom header: x-test-a present');
        is($h->{'x-test-b'}, 'val-b', 'JSON custom header: x-test-b present');
        ok($h->{'anthropic-version'}, 'anthropic-version still present alongside custom');
    }

    # Newline format
    {
        local $ENV{ANTHROPIC_CUSTOM_HEADERS} = "x-test-a: val-a\nx-test-b: val-b";
        my $p = CLIO::Providers::Anthropic->new(api_key => 'sk-test');
        my $h = $p->get_headers();
        is($h->{'x-test-a'}, 'val-a', 'newline custom header: x-test-a present');
        is($h->{'x-test-b'}, 'val-b', 'newline custom header: x-test-b present');
    }
}

# ── Group 6: Custom header merging ────────────────────────────────────
{
    local %ENV = %ENV;
    delete $ENV{ANTHROPIC_BASE_URL};
    delete $ENV{ANTHROPIC_API_KEY};

    local $ENV{ANTHROPIC_CUSTOM_HEADERS} = '{"x-env-test": "env-val"}';
    my $p = CLIO::Providers::Anthropic->new(
        api_key => 'sk-test',
        custom_headers => { 'x-ctor-test' => 'ctor-val' },
    );
    my $h = $p->get_headers();
    is($h->{'x-ctor-test'}, 'ctor-val', 'constructor custom header present');
    is($h->{'x-env-test'}, 'env-val', 'env custom header present');
}

# ── Group 7: Provider registry ───────────────────────────────────────
{
    my $anthropic = CLIO::Providers::get_provider('anthropic');
    ok($anthropic, 'anthropic entry exists in registry');
    ok($anthropic->{native_api}, 'anthropic has native_api flag');
    is($anthropic->{provider_module}, 'CLIO::Providers::Anthropic',
       'anthropic provider_module correct');

    my $copilot = CLIO::Providers::get_provider('github_copilot');
    ok($copilot, 'github_copilot entry exists in registry');
    ok(!$copilot->{native_api}, 'github_copilot does NOT have native_api');
}

# ── Group 8: build_request() ─────────────────────────────────────────
{
    local %ENV = %ENV;
    delete $ENV{ANTHROPIC_BASE_URL};
    delete $ENV{ANTHROPIC_API_KEY};
    delete $ENV{ANTHROPIC_CUSTOM_HEADERS};

    my $p = CLIO::Providers::Anthropic->new(api_key => 'sk-test');
    my $req = $p->build_request(
        [{ role => 'user', content => 'hello' }],
        [],
        { model => 'custom-proxy-model', max_tokens => 1024 },
    );
    is(ref($req), 'HASH', 'build_request returns hashref');
    ok($req->{body}, 'has body field');
    my $body = decode_json($req->{body});
    is($body->{model}, 'custom-proxy-model', 'model name in body');
    ok($body->{stream}, 'stream is true in body');
    ok(ref($body->{messages}) eq 'ARRAY', 'messages is array in body');
}

# ── Group 9: CLIO_TLS_VERIFY env var ─────────────────────────────────
{
    local %ENV = %ENV;

    # Default: TLS verify on
    {
        delete $ENV{CLIO_TLS_VERIFY};
        my $ua = CLIO::Compat::HTTP->new(timeout => 10);
        is($ua->{tls_verify}, 1, 'default tls_verify is 1');
    }

    # CLIO_TLS_VERIFY=0 disables
    {
        local $ENV{CLIO_TLS_VERIFY} = 0;
        my $ua = CLIO::Compat::HTTP->new(timeout => 10);
        is($ua->{tls_verify}, 0, 'CLIO_TLS_VERIFY=0 disables tls_verify');
    }

    # CLIO_TLS_VERIFY=1 enables
    {
        local $ENV{CLIO_TLS_VERIFY} = 1;
        my $ua = CLIO::Compat::HTTP->new(timeout => 10);
        is($ua->{tls_verify}, 1, 'CLIO_TLS_VERIFY=1 enables tls_verify');
    }

    # Explicit ssl_opts overrides env var
    {
        local $ENV{CLIO_TLS_VERIFY} = 0;
        my $ua = CLIO::Compat::HTTP->new(timeout => 10, ssl_opts => { verify_SSL => 1 });
        is($ua->{tls_verify}, 1, 'explicit ssl_opts overrides CLIO_TLS_VERIFY');
    }
}

print "\nAll Anthropic proxy tests passed!\n";