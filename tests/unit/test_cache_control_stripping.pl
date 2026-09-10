#!/usr/bin/perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Test: APIManager's adapt_request_for_endpoint strips cache_control from
# messages and tool definitions for providers that don't support
# explicit cache_control. For providers that DO support it, cache_control
# is preserved.
#
# This is a defensive guard — CLIO currently only sets cache_control in
# the Anthropic native provider module (top-level). The OpenAI-compatible
# path uses automatic caching with no explicit markers. But if any future
# code adds cache_control to messages, the stripping ensures it doesn't
# reach providers that would reject it.

use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use Test::More;
use CLIO::Providers qw(build_endpoint_config);
require CLIO::Core::APIManager;

# We test adapt_request_for_endpoint directly with mock payloads.
# Create a minimal mock that has just enough to call the method.
# adapt_request_for_endpoint operates on the payload directly (no
# Config, API key, or network needed) — it only mutates $payload
# in-place based on $endpoint_config flags.
my $api = bless {
    debug => 0,
    config => undef,
    _no_previous_response_id => 0,
}, 'CLIO::Core::APIManager';

# Stub out methods that adapt_request_for_endpoint may call but
# we don't need for these tests (reasoning injection, sampling).
$api->isa('CLIO::Core::APIManager');  # ensure package is loaded

# ── Test 1: cache_control stripped for providers that DON'T support it ─
{
    my $endpoint_config = build_endpoint_config('sam', 'test-key');

    my $payload = {
        model => 'test',
        messages => [
            { role => 'system', content => 'instr', cache_control => { type => 'ephemeral' } },
            { role => 'user', content => 'hi', cache_control => { type => 'ephemeral' } },
        ],
        tools => [
            { type => 'function', function => { name => 'tool1' } },
            { type => 'function', function => { name => 'tool2' }, cache_control => { type => 'ephemeral' } },
        ],
    };

    $api->adapt_request_for_endpoint($payload, $endpoint_config);

    # System message cache_control should be stripped
    ok(!$payload->{messages}[0]{cache_control},
        'SAM: cache_control stripped from system message');
    ok(!$payload->{messages}[1]{cache_control},
        'SAM: cache_control stripped from user message');

    # Tool cache_control should be stripped
    ok(!$payload->{tools}[1]{cache_control},
        'SAM: cache_control stripped from last tool');
}

# ── Test 2: cache_control stripped from content blocks (array format) ─
{
    my $endpoint_config = build_endpoint_config('sam', 'test-key');

    my $payload = {
        model => 'test',
        messages => [
            { role => 'user', content => [
                { type => 'text', text => 'Hello', cache_control => { type => 'ephemeral' } },
                { type => 'text', text => 'World', cache_control => { type => 'ephemeral' } },
            ]},
        ],
    };

    $api->adapt_request_for_endpoint($payload, $endpoint_config);

    for my $block (@{$payload->{messages}[0]{content}}) {
        ok(!$block->{cache_control},
            "SAM: cache_control stripped from content block (block type=$block->{type})");
    }
}

# ── Test 3: cache_control preserved for providers that DO support it ──
{
    my $endpoint_config = build_endpoint_config('openai', 'test-key');

    my $payload = {
        model => 'test',
        messages => [
            { role => 'system', content => 'instr', cache_control => { type => 'ephemeral' } },
            { role => 'user', content => 'hi', cache_control => { type => 'ephemeral' } },
        ],
        tools => [
            { type => 'function', function => { name => 'tool1' } },
            { type => 'function', function => { name => 'tool2' }, cache_control => { type => 'ephemeral' } },
        ],
    };

    $api->adapt_request_for_endpoint($payload, $endpoint_config);

    # cache_control should be preserved for OpenAI (supports_cache_control=1)
    ok($payload->{messages}[0]{cache_control},
        'OpenAI: cache_control preserved on system message');
    ok($payload->{messages}[1]{cache_control},
        'OpenAI: cache_control preserved on user message');
    ok($payload->{tools}[1]{cache_control},
        'OpenAI: cache_control preserved on last tool');
}

# ── Test 4: cache_control preserved for Anthropic endpoint config ──────
{
    my $endpoint_config = build_endpoint_config('anthropic', 'test-key');

    my $payload = {
        model => 'test',
        messages => [
            { role => 'user', content => 'hi', cache_control => { type => 'ephemeral' } },
        ],
    };

    $api->adapt_request_for_endpoint($payload, $endpoint_config);

    ok($payload->{messages}[0]{cache_control},
        'Anthropic: cache_control preserved on user message');
}

# ── Test 5: cache_control preserved for OpenRouter ─────────────────────
# OpenRouter translates cache_control between provider formats.
{
    my $endpoint_config = build_endpoint_config('openrouter', 'test-key');

    my $payload = {
        model => 'test',
        messages => [
            { role => 'system', content => 'instr', cache_control => { type => 'ephemeral' } },
        ],
    };

    $api->adapt_request_for_endpoint($payload, $endpoint_config);

    ok($payload->{messages}[0]{cache_control},
        'OpenRouter: cache_control preserved on system message');
}

# ── Test 6: No messages -> no crash ────────────────────────────────────
{
    my $endpoint_config = build_endpoint_config('sam', 'test-key');
    my $payload = { model => 'test', messages => [] };

    my $ok = eval { $api->adapt_request_for_endpoint($payload, $endpoint_config); 1 };
    ok($ok, 'SAM: empty messages array does not crash');
}

# ── Test 7: Undefined messages -> no crash ─────────────────────────────
{
    my $endpoint_config = build_endpoint_config('sam', 'test-key');
    my $payload = { model => 'test' };

    my $ok = eval { $api->adapt_request_for_endpoint($payload, $endpoint_config); 1 };
    ok($ok, 'SAM: no messages key does not crash');
}

done_testing();
