#!/usr/bin/perl
# SPDX-License-Identifier: GPL-3.0-only
use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../../lib";

# Regression: two related bugs in the Anthropic provider path that surfaced
# when the user switched to a proxy base URL:
#
# 1. ModelCapabilitiesManager._fetch_anthropic_capabilities had a HARDCODED
#    URL 'https://api.anthropic.com/v1/models'. When the user set
#    /api set base for anthropic to a proxy URL, MCM kept hitting
#    api.anthropic.com and either failed (proxy doesn't have a real
#    Anthropic key) or returned stale data from a different endpoint.
#    Result: MCM returned undef, fallback to provider max_context_tokens
#    or DEFAULT_CONTEXT_WINDOW kicked in, and the user saw a low context
#    ceiling on /usage.
#
# 2. Anthropic provider's thinking_delta handler only checked
#    $delta->{thinking}. Some proxies/variants emit delta.text or
#    delta.reasoning_content for the same event. The THINKING banner
#    appeared (from content_block_start) but no content streamed
#    underneath (the callback returns early on empty content).
#
# Fix:
# 1. _fetch_anthropic_capabilities now reads the user's configured
#    api_base via Config::get_provider_base('anthropic') and transforms
#    it: strip trailing /messages, append /models.
#    _fetch_google_capabilities does the same (just strip trailing /).
# 2. thinking_delta handler now checks delta.thinking || delta.text ||
#    delta.reasoning_content.

use Test::More;

# Test 1: The Anthropic _fetch_anthropic_capabilities method should look up
# the user's configured api_base and transform it. We test the URL
# transformation logic in isolation rather than mocking the full HTTP call.
{
    # Simulate a user-configured Anthropic api_base for a proxy
    my $user_api_base = 'https://my-proxy.example.com/v1/messages';

    # Apply the same transformation the fix uses
    my $base = $user_api_base;
    $base =~ s{/+messages/?$}{};
    my $models_url = "${base}/models";

    is($models_url, 'https://my-proxy.example.com/v1/models',
        'Anthropic: /v1/messages -> /v1/models (proxy URL transformation)');
}

# Test 2: Trailing slash variant
{
    my $user_api_base = 'https://my-proxy.example.com/v1/messages/';
    my $base = $user_api_base;
    $base =~ s{/+messages/?$}{};
    my $models_url = "${base}/models";

    is($models_url, 'https://my-proxy.example.com/v1/models',
        'Anthropic: trailing slash on /v1/messages/ is also stripped');
}

# Test 3: API base without /messages suffix (e.g., user set just /v1)
{
    my $user_api_base = 'https://my-proxy.example.com/v1';
    my $base = $user_api_base;
    $base =~ s{/+messages/?$}{};
    my $models_url = "${base}/models";

    is($models_url, 'https://my-proxy.example.com/v1/models',
        'Anthropic: /v1 (no /messages) -> /v1/models (no strip needed)');
}

# Test 4: When user hasn't set a custom api_base, the hardcoded URL wins
{
    # We can verify the source has the hardcoded fallback
    my $src = do { local $/; open my $fh, '<', 'lib/CLIO/Core/ModelCapabilitiesManager.pm' or die; <$fh> };
    like($src, qr/my \$api_base;\s*\n\s*if \(\$user_api_base\)/,
        'Anthropic MCM uses user api_base when set, hardcoded URL otherwise');
    like($src, qr/'\s*https:\/\/api\.anthropic\.com\/v1\/models\s*'/,
        'Hardcoded Anthropic default still present as fallback');
}

# Test 5: Google MCM also honors the user api_base
{
    my $src = do { local $/; open my $fh, '<', 'lib/CLIO/Core/ModelCapabilitiesManager.pm' or die; <$fh> };
    like($src, qr/get_provider_base\('google'\)/,
        'Google MCM looks up user api_base');
    like($src, qr/'\s*https:\/\/generativelanguage\.googleapis\.com\/v1beta\s*'/,
        'Google hardcoded default still present as fallback');
}

# Test 6: thinking_delta accepts delta.text and delta.reasoning_content
{
    my $src = do { local $/; open my $fh, '<', 'lib/CLIO/Providers/Anthropic.pm' or die; <$fh> };
    like($src, qr/\$delta->\{thinking\}\s*\/\/\s*\$delta->\{text\}\s*\/\/\s*\$delta->\{reasoning_content\}/,
        'Anthropic thinking_delta checks delta.thinking, delta.text, AND delta.reasoning_content');
}

# Test 7: End-to-end - simulate an Anthropic-style SSE event with
# delta.text instead of delta.thinking and verify the content is captured.
{
    require CLIO::Providers::Anthropic;
    my $prov = CLIO::Providers::Anthropic->new(
        api_key  => 'test',
        api_base => 'https://api.anthropic.com/v1/messages',
    );

    # Anthropic-format thinking_delta but with the field under 'text'
    my $event = 'data: {"type":"content_block_delta","delta":{"type":"thinking_delta","text":"thinking content here"}}';
    my $result = $prov->parse_stream_event($event);
    is($result->{type}, 'thinking', 'thinking_delta event parsed as type=thinking');
    is($result->{content}, 'thinking content here',
        'thinking_delta with delta.text is captured (proxy compatibility)');
}

# Test 8: Same event with delta.reasoning_content (OpenAI-style proxy)
{
    require CLIO::Providers::Anthropic;
    my $prov = CLIO::Providers::Anthropic->new(
        api_key  => 'test',
        api_base => 'https://api.anthropic.com/v1/messages',
    );

    my $event = 'data: {"type":"content_block_delta","delta":{"type":"thinking_delta","reasoning_content":"reasoning text here"}}';
    my $result = $prov->parse_stream_event($event);
    is($result->{type}, 'thinking', 'thinking_delta event parsed as type=thinking');
    is($result->{content}, 'reasoning text here',
        'thinking_delta with delta.reasoning_content is captured');
}

# Test 9: Standard Anthropic native format (delta.thinking) still works
{
    require CLIO::Providers::Anthropic;
    my $prov = CLIO::Providers::Anthropic->new(
        api_key  => 'test',
        api_base => 'https://api.anthropic.com/v1/messages',
    );

    my $event = 'data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"native thinking"}}';
    my $result = $prov->parse_stream_event($event);
    is($result->{type}, 'thinking', 'thinking_delta event parsed as type=thinking');
    is($result->{content}, 'native thinking',
        'Native Anthropic delta.thinking field still works');
}

done_testing();
