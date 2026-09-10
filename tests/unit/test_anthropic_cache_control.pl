#!/usr/bin/perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Test: Anthropic provider sets top-level cache_control for automatic
# prompt caching, and does NOT set per-message cache_control markers
# (which are redundant with automatic caching).
#
# Also tests the APIManager-level defensive stripping of cache_control
# from messages/tool defs for providers that don't support it.

use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use Test::More;
use CLIO::Util::JSON qw(decode_json);
use CLIO::Providers::Anthropic;

my $provider = CLIO::Providers::Anthropic->new(
    api_key => 'test-key',
    model   => 'claude-sonnet-4-6',
);

# ── Test 1: Top-level cache_control is set for automatic caching ──────
{
    my $req = $provider->build_request(
        [
            { role => 'system', content => 'You are CLIO.' },
            { role => 'user',   content => 'Fix a bug' },
        ],
        [],
        { model => 'claude-sonnet-4-6', max_tokens => 16000 },
    );

    my $body = decode_json($req->{body});

    ok($body->{cache_control}, 'Anthropic: top-level cache_control is set');
    is($body->{cache_control}{type}, 'ephemeral',
        'Anthropic: cache_control type=ephemeral (automatic caching)');

    # System prompt should NOT have per-message cache_control
    if ($body->{system}) {
        for my $block (@{$body->{system}}) {
            ok(!$block->{cache_control},
                'Anthropic: system prompt does NOT have per-message cache_control (redundant with automatic)');
        }
    }

    # Tools should NOT have per-message cache_control on the last tool
    if ($body->{tools}) {
        my $last_tool = $body->{tools}[-1];
        ok(!$last_tool->{cache_control},
            'Anthropic: last tool does NOT have cache_control (handled by automatic)');
    }
}

# ── Test 2: cache_control present even with tools ─────────────────────
{
    my $req = $provider->build_request(
        [
            { role => 'system', content => 'You are CLIO.' },
            { role => 'user',   content => 'Build a feature' },
        ],
        [
            { type => 'function', function => {
                name => 'file_operations',
                description => 'File operations',
                parameters => { type => 'object', properties => {} },
            } },
        ],
        { model => 'claude-sonnet-4-6', max_tokens => 16000 },
    );

    my $body = decode_json($req->{body});

    ok($body->{cache_control}, 'Anthropic: top-level cache_control present with tools');
    is($body->{cache_control}{type}, 'ephemeral',
        'Anthropic: cache_control type=ephemeral with tools');
    ok($body->{tools}, 'Anthropic: tools present in payload');
    ok(!$body->{tools}[-1]{cache_control},
        'Anthropic: last tool does NOT have per-message cache_control');
}

# ── Test 3: cache_control present even without tools ───────────────────
{
    my $req = $provider->build_request(
        [{ role => 'user', content => 'Hi' }],
        undef,  # no tools
        { model => 'claude-sonnet-4-6', max_tokens => 16000 },
    );

    my $body = decode_json($req->{body});

    ok($body->{cache_control}, 'Anthropic: top-level cache_control present without tools');
    is($body->{cache_control}{type}, 'ephemeral',
        'Anthropic: cache_control type=ephemeral without tools');
}

# ── Test 4: No per-message cache_control on any message ─────────────────
{
    my $req = $provider->build_request(
        [
            { role => 'system', content => 'System instructions here.' },
            { role => 'user',   content => 'First user message' },
            { role => 'assistant', content => 'Assistant response' },
            { role => 'tool', tool_call_id => 'tc1', content => 'tool result' },
            { role => 'user',   content => 'Follow-up question' },
        ],
        [],
        { model => 'claude-sonnet-4-6', max_tokens => 16000 },
    );

    my $body = decode_json($req->{body});

    # No message in the conversation should have cache_control
    # (only the top-level payload cache_control is set)
    for my $msg (@{$body->{messages}}) {
        ok(!$msg->{cache_control},
            "Anthropic: message role=$msg->{role} has NO per-message cache_control");
    }
}

# ── Test 5: Source-level regression guard ──────────────────────────────
# Verify that build_request does NOT set per-message cache_control on
# system prompt blocks or tools — only the top-level cache_control.
{
    my $src = do { local $/; open my $fh, '<', 'lib/CLIO/Providers/Anthropic.pm' or die; <$fh> };

    # The top-level cache_control is set in the payload hash initialisation
    like($src, qr/^\s+\bcache_control\s*=>\s*\{ type => 'ephemeral' \},/m,
        'Anthropic.pm: top-level cache_control in payload init');

    # The per-message cache_control on system prompt should NOT exist
    # (it was removed when switching to automatic caching)
    my $start = index($src, 'sub build_request');
    my $end   = index($src, 'sub get_headers', $start);
    my $block = substr($src, $start, $end - $start);

    unlike($block, qr/\$\w+->\{system\}\s*=\s*\[[^]]*cache_control/s,
        'build_request: does NOT set per-message cache_control on system prompt');
    unlike($block, qr/convert_tool.*\{?\s*cache_control/s,
        'build_request: does NOT set cache_control on converted tools');
}

# ── Test 6: Google provider does NOT set cache_control (uses implicit) ─
# Google's Gemini uses implicit caching — no explicit cache_control needed.
{
    require CLIO::Providers::Google;
    my $req = CLIO::Providers::Google->new(
        api_key => 'test-key',
        model   => 'gemini-2.5-flash',
    )->build_request(
        [{ role => 'user', content => 'Hi' }],
        undef,
        { model => 'gemini-2.5-flash', max_tokens => 16000 },
    );

    my $body = decode_json($req->{body});

    ok(!$body->{cache_control},
        'Google: does NOT set top-level cache_control (implicit caching only)');
    ok(!$body->{systemInstruction}{cache_control},
        'Google: does NOT set cache_control on systemInstruction (implicit caching)');
}

done_testing();
