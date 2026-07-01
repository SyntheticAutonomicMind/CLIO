#!/usr/bin/env perl

# Regression tests for sampling parameter defaulting.
#
# Background: _build_payload used to inject temperature => 0.2 and
# top_p => 0.95 into every request, which leaked into providers that
# reject these defaults (e.g. OpenAI o-series rejects temperature
# combined with reasoning_effort, Anthropic rejects temperature=0.2
# when thinking is enabled, etc.). The fix removes the defaults and
# lets providers/callers fill in what they want.

use strict;
use warnings;
use lib './lib';
use Test::More;
use JSON::PP qw(encode_json);

use_ok('CLIO::Providers');
use_ok('CLIO::Core::APIManager');
use_ok('CLIO::Core::Config');

# Build an APIManager without requiring an API key.
sub _make_mgr {
    my (%args) = @_;
    # Use a hermetic config dir so test results don't depend on the
    # user's saved config.json (which may have sampling_* set).
    my $dir;
    unless ($args{config}) {
        require File::Temp;
        $dir = File::Temp::tempdir(CLEANUP => 1);
    }
    my $config = $args{config} || CLIO::Core::Config->new(config_dir => $dir);
    unless ($args{config}) {
        $config->set('api_base', $args{api_base} // 'https://api.example.com/v1');
        $config->set('api_key',  $args{api_key}  // 'sk-test');
    }
    my $mgr = CLIO::Core::APIManager->new(
        provider => $args{provider} // 'openai',
        model    => $args{model}    // 'gpt-4.1',
        config   => $config,
    );
    return $mgr;
}

sub _ec {
    my (%args) = @_;
    return CLIO::Providers::build_endpoint_config(
        $args{provider} // 'openai',
        $args{api_key}  // 'sk-test',
    );
}

# ── Group 1: _build_payload never injects sampling defaults ──────────

# 1. No temperature/top_p passed -> neither key in payload.
{
    my $mgr = _make_mgr();
    my $ec  = _ec(provider => 'openai');
    my $payload = $mgr->_build_payload(
        [{ role => 'user', content => 'hi' }],
        'gpt-4.1',
        $ec,
    );
    ok(!exists $payload->{temperature}, 'no default temperature injected');
    ok(!exists $payload->{top_p},       'no default top_p injected');
}

# 2. Explicit temperature is passed through unchanged.
{
    my $mgr = _make_mgr();
    my $ec  = _ec(provider => 'openai');
    my $payload = $mgr->_build_payload(
        [{ role => 'user', content => 'hi' }],
        'gpt-4.1',
        $ec,
        temperature => 0.7,
    );
    is($payload->{temperature}, 0.7, 'explicit temperature=0.7 preserved');
    ok(!exists $payload->{top_p}, 'top_p still not injected');
}

# 3. Explicit top_p is passed through unchanged.
{
    my $mgr = _make_mgr();
    my $ec  = _ec(provider => 'openai');
    my $payload = $mgr->_build_payload(
        [{ role => 'user', content => 'hi' }],
        'gpt-4.1',
        $ec,
        top_p => 0.9,
    );
    is($payload->{top_p}, 0.9, 'explicit top_p=0.9 preserved');
    ok(!exists $payload->{temperature}, 'temperature still not injected');
}

# ── Group 2: adapt_request_for_endpoint applies provider defaults ────

# 4. No caller value -> provider sampling_defaults fill in.
{
    my $mgr = _make_mgr(provider => 'llama.cpp');
    my $ec  = _ec(provider => 'llama.cpp');
    my $payload = { model => 'local-model', messages => [] };
    my $result = $mgr->adapt_request_for_endpoint($payload, $ec);

    is($result->{temperature}, 1.0, 'llama.cpp default temperature applied');
    is($result->{top_p},       0.95, 'llama.cpp default top_p applied');
    is($result->{top_k},       20,   'llama.cpp default top_k applied');
}

# 5. Caller-supplied temperature is NOT overwritten by provider default.
{
    my $mgr = _make_mgr(provider => 'llama.cpp');
    my $ec  = _ec(provider => 'llama.cpp');
    my $payload = {
        model => 'local-model',
        messages => [],
        temperature => 0.4,
        top_p => 0.8,
    };
    my $result = $mgr->adapt_request_for_endpoint($payload, $ec);

    is($result->{temperature}, 0.4, 'caller temperature preserved against provider default');
    is($result->{top_p},       0.8, 'caller top_p preserved against provider default');
}

# 6. Z.AI sampling_defaults are applied through the general block.
{
    my $mgr = _make_mgr(provider => 'zai');
    my $ec  = _ec(provider => 'zai');
    my $payload = { model => 'glm-4.6', messages => [] };
    my $result = $mgr->adapt_request_for_endpoint($payload, $ec);

    is($result->{temperature}, 1.0, 'Z.AI default temperature applied');
    is($result->{top_p},       0.95, 'Z.AI default top_p applied');
}

# ── Group 3: no implicit 0.2 reappears anywhere ──────────────────────

# 7. After full pass through adapt_request_for_endpoint, a payload built
#    by _build_payload without opts never carries the old 0.2 default.
{
    my $mgr = _make_mgr();
    my $ec  = _ec(provider => 'openai');
    my $payload = $mgr->_build_payload(
        [{ role => 'user', content => 'hi' }],
        'gpt-4.1',
        $ec,
    );
    my $adapted = $mgr->adapt_request_for_endpoint($payload, $ec);
    ok(!exists $adapted->{temperature}, 'openai (no sampling_defaults) leaves temperature unset');
}

# 8. Config sampling_temperature override is still honored.
{
    my $config = CLIO::Core::Config->new();
    $config->set('sampling_temperature', '0.55');
    my $mgr = _make_mgr(config => $config);
    my $ec  = _ec(provider => 'openai');
    my $payload = $mgr->_build_payload(
        [{ role => 'user', content => 'hi' }],
        'gpt-4.1',
        $ec,
    );
    my $adapted = $mgr->adapt_request_for_endpoint($payload, $ec);
    is($adapted->{temperature}, 0.55, 'user sampling_temperature config applied');
}

done_testing();