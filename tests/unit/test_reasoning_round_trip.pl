#!/usr/bin/env perl

# Tests for thinking/reasoning round-trip behavior across native and
# Responses API providers. Covers:
#   - Anthropic thinking block signature + redacted_thinking round-trip
#   - Google thought signature round-trip
#   - Responses API reasoning items (encrypted_content + phase) round-trip
#   - APIManager native thinking config wiring

use strict;
use warnings;
use lib './lib';
use Test::More tests => 48;
use JSON::PP qw(encode_json decode_json);

use_ok('CLIO::Providers::Anthropic');
use_ok('CLIO::Providers::Google');
use_ok('CLIO::Core::APIManager');

# ── 1. Anthropic thinking block parser ────────────────────────────────
{
    my $p = CLIO::Providers::Anthropic->new(api_key => 'k', model => 'claude-sonnet-4.5');

    # content_block_start with thinking + signature (SSE format: data: {...})
    my $ev1 = $p->parse_stream_event(
        'data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","signature":"abc123"}}');
    is($ev1->{type}, 'thinking_start', 'Anthropic: thinking start event');

    # thinking_delta
    my $ev2 = $p->parse_stream_event(
        'data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Let me think..."}}');
    is($ev2->{type}, 'thinking', 'Anthropic: thinking delta type');
    is($ev2->{content}, 'Let me think...', 'Anthropic: thinking content');

    # signature_delta
    my $ev3 = $p->parse_stream_event(
        'data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig_xyz"}}');
    is($ev3, undef, 'Anthropic: signature_delta returns undef (bookkeeping only)');

    # content_block_stop closes the thinking block
    my $ev4 = $p->parse_stream_event('data: {"type":"content_block_stop","index":0}');
    is($ev4->{type}, 'thinking_end', 'Anthropic: thinking end event');

    # get_thinking_blocks should now contain the captured thinking
    my $blocks = $p->get_thinking_blocks();
    is(ref($blocks), 'ARRAY', 'Anthropic: get_thinking_blocks returns arrayref');
    is(scalar @$blocks, 1, 'Anthropic: one thinking block captured');
    is($blocks->[0]{type}, 'thinking', 'Anthropic: block type is thinking');
    is($blocks->[0]{signature}, 'sig_xyz', 'Anthropic: signature preserved');

    # clear_thinking_blocks resets state
    $p->clear_thinking_blocks();
    is(scalar @{$p->get_thinking_blocks()}, 0, 'Anthropic: clear_thinking_blocks empties state');
}

# ── 2. Anthropic redacted_thinking block ──────────────────────────────
{
    my $p = CLIO::Providers::Anthropic->new(api_key => 'k', model => 'claude-sonnet-4.5');

    # content_block_start with redacted_thinking (safety filter trip)
    my $ev1 = $p->parse_stream_event(
        'data: {"type":"content_block_start","index":0,"content_block":{"type":"redacted_thinking","data":"enc_blob_456"}}');
    is($ev1->{type}, 'thinking_redacted', 'Anthropic: redacted_thinking event type');
    is($ev1->{data}, 'enc_blob_456', 'Anthropic: redacted_thinking data preserved');

    my $blocks = $p->get_thinking_blocks();
    is($blocks->[0]{type}, 'redacted_thinking', 'Anthropic: redacted block type');
    is($blocks->[0]{data}, 'enc_blob_456', 'Anthropic: redacted block data preserved');
}

# ── 3. Google thought signature round-trip ────────────────────────────
{
    my $p = CLIO::Providers::Google->new(api_key => 'k', model => 'gemini-2.5-flash');

    # Parse a content event that carries a thought part
    my $ev1 = $p->parse_stream_event('data: '.join('', (
        '{"candidates":[{"content":{"parts":[',
        '{"text":"Hello!","thought":false},',
        '{"text":"Let me reason about this...","thought":true,"thoughtSignature":"sig_789"}]',
        '},"role":"model"}],"finishReason":"STOP"}',
    )));
    is($ev1->{type}, 'text', 'Google: text event for visible text');
    is($ev1->{content}, 'Hello!', 'Google: visible text extracted');

    # Google stream events with only thought parts (no visible text)
    my $p2 = CLIO::Providers::Google->new(api_key => 'k', model => 'gemini-2.5-flash');
    my $ev2 = $p2->parse_stream_event('data: '.join('', (
        '{"candidates":[{"content":{"parts":[',
        '{"text":"Reasoning...","thought":true,"thoughtSignature":"sig_abc"}]',
        '},"role":"model"}]}',
    )));

    # The visible part should be empty, the thought should be captured
    is($ev2->{type}, 'thinking', 'Google: thought part parsed as type=thinking')
        or diag("got type=" . ($ev2->{type} // 'undef'));
    is($ev2->{content}, 'Reasoning...', 'Google: thought text preserved');

    my $blocks = $p2->get_thinking_blocks();
    is(scalar @$blocks, 1, 'Google: one thought block captured');
    is($blocks->[0]{type}, 'thought', 'Google: thought block type');
    is($blocks->[0]{signature}, 'sig_abc', 'Google: thought block signature preserved');
}

# ── 4. Google convert_messages round-trips thought blocks ─────────────
{
    my $p = CLIO::Providers::Google->new(api_key => 'k', model => 'gemini-2.5-flash');

    # Assistant message with prior turn's reasoning_blocks
    my $messages = [
        { role => 'user', content => 'What is 2+2?' },
        { role => 'assistant', content => '4', reasoning_blocks => [
            { type => 'thought', text => 'Simple arithmetic', signature => 'sig_001' },
        ] },
    ];

    my $converted = $p->convert_messages($messages);
    is(scalar @$converted, 2, 'Google: both messages converted');

    my $assistant = $converted->[1];
    is($assistant->{role}, 'model', 'Google: assistant -> model role');
    # Google requires thought parts BEFORE text content on round-trip so the
    # model can verify the prior reasoning signature.
    is($assistant->{parts}[0]{thought}, JSON::PP::true, 'Google: thought part marked thought=true');
    is($assistant->{parts}[0]{thoughtSignature}, 'sig_001', 'Google: thoughtSignature round-tripped');
    is($assistant->{parts}[0]{text}, 'Simple arithmetic', 'Google: thought text round-tripped');
    is($assistant->{parts}[1]{text}, '4', 'Google: visible text in parts');
}

# ── 5. Anthropic convert_messages round-trips thinking blocks ─────────
{
    my $p = CLIO::Providers::Anthropic->new(api_key => 'k', model => 'claude-sonnet-4.5');

    my $messages = [
        { role => 'user', content => 'Hi' },
        { role => 'assistant', content => 'Hello!', reasoning_blocks => [
            { type => 'thinking', text => 'Greeting response', signature => 'sig_anthropic' },
            { type => 'redacted_thinking', data => 'enc_blob_anthropic' },
        ] },
    ];

    my $converted = $p->convert_messages($messages);
    my $assistant = $converted->[1];
    is($assistant->{role}, 'assistant', 'Anthropic: assistant role preserved');
    # Should have: thinking part, redacted_thinking part, text part
    ok((grep { $_->{type} eq 'thinking' && $_->{signature} eq 'sig_anthropic' } @{$assistant->{content}}), 'Anthropic: thinking part round-tripped with signature');
    ok((grep { $_->{type} eq 'redacted_thinking' && $_->{data} eq 'enc_blob_anthropic' } @{$assistant->{content}}), 'Anthropic: redacted_thinking part round-tripped');
}

# ── 6. APIManager _endpoint_supports_thinking() ───────────────────────
{
    require CLIO::Core::Config;
    my $config = CLIO::Core::Config->new();
    my $mgr = CLIO::Core::APIManager->new(
        provider => 'anthropic',
        model => 'claude-sonnet-4.5',
        config => $config,
    );
    ok($mgr->_endpoint_supports_thinking(), 'Anthropic supports thinking');

    $mgr = CLIO::Core::APIManager->new(
        provider => 'github_copilot',
        model => 'gpt-4o',
        config => $config,
    );
    ok(!$mgr->_endpoint_supports_thinking(), 'github_copilot does not support native thinking');

    $mgr = CLIO::Core::APIManager->new(
        provider => 'google',
        model => 'gemini-2.5-flash',
        config => $config,
    );
    ok($mgr->_endpoint_supports_thinking(), 'Google supports thinking');
}

# ── 7. APIManager _extract_response_content returns 4 values ───────────
{
    my $config = CLIO::Core::Config->new();
    my $mgr = CLIO::Core::APIManager->new(
        provider => 'github_copilot',
        model => 'gpt-5',
        config => $config,
    );

    # Non-streaming Responses API response with reasoning item
    my $data = {
        id => 'resp_test',
        output => [
            { type => 'reasoning', id => 'rs_1', encrypted_content => 'blob_xyz', phase => 'commentary' },
            { type => 'message', content => [
                { type => 'output_text', text => 'Hello' },
            ] },
        ],
    };

    my @r = $mgr->_extract_response_content($data, 1, {});
    is(scalar @r, 4, 'APIManager: _extract_response_content returns 4 values');
    is($r[0], 'Hello', 'APIManager: content extracted');
    is($r[2], undef, 'APIManager: no reasoning_details for Responses API');
    ok(ref $r[3] eq 'ARRAY' && @{$r[3]} == 1, 'APIManager: responses_reasoning_items extracted');
    is($r[3][0]{type}, 'reasoning', 'APIManager: reasoning item type');
    is($r[3][0]{encrypted_content}, 'blob_xyz', 'APIManager: encrypted_content preserved');
    is($r[3][0]{phase}, 'commentary', 'APIManager: phase preserved');
}

# ── 8. APIManager _build_responses_api_payload replays reasoning items ─
{
    my $config = CLIO::Core::Config->new();
    my $mgr = CLIO::Core::APIManager->new(
        provider => 'github_copilot',
        model => 'gpt-5',
        config => $config,
    );
    $mgr->{response_handler} = bless {}, 'CLIO::Core::API::ResponseHandler';

    my $messages = [
        { role => 'user', content => 'What is 2+2?' },
        { role => 'assistant', content => '4', responses_reasoning_items => [
            { type => 'reasoning', id => 'rs_1', encrypted_content => 'blob_xyz', phase => 'commentary' },
        ] },
    ];

    my $payload = $mgr->_build_responses_api_payload($messages, 'gpt-5', {});
    my $reasoning_input = [grep { ($_->{type} // '') eq 'reasoning' } @{$payload->{input}}];
    is(scalar @$reasoning_input, 1, 'APIManager: reasoning item replayed as input');
    is($reasoning_input->[0]{encrypted_content}, 'blob_xyz', 'APIManager: encrypted_content round-tripped in payload');
    is($reasoning_input->[0]{phase}, 'commentary', 'APIManager: phase round-tripped in payload');
}

# ── 9. APIManager MiniMax M2.x thinking enabled ───────────────────────
{
    # Check that the minimax endpoint config has supports_reasoning + minimax flag
    require CLIO::Providers;
    my $minimax = CLIO::Providers::get_provider('minimax');
    ok($minimax && $minimax->{supports_reasoning}, 'MiniMax provider has supports_reasoning');
    ok($minimax && $minimax->{endpoint}{minimax}, 'MiniMax endpoint has minimax flag');
}

print "\nAll reasoning round-trip tests passed!\n";
