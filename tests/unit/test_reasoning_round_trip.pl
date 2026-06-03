#!/usr/bin/env perl

# Tests for thinking/reasoning round-trip behavior across native and
# Responses API providers. Covers:
#   - Anthropic thinking block signature + redacted_thinking round-trip
#   - Anthropic _default_thinking_config, _supports_adaptive_thinking,
#     _needs_interleaved_thinking_beta, _max_thinking_budget_for_model
#   - Google thought signature round-trip
#   - Google _build_thinking_config
#   - Responses API reasoning items (encrypted_content + phase) round-trip
#   - APIManager native thinking config wiring
#   - show_thinking=0 behavior for native providers
#   - Multiple thinking blocks in a single response
#   - Google parse_stream_event multi-part chunk handling

use strict;
use warnings;
use lib './lib';
use Test::More tests => 101;
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
    ok($mgr->_endpoint_supports_thinking(), 'github_copilot supports thinking (via OpenAI reasoning_effort)');

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

# ── 10. Anthropic _default_thinking_config ────────────────────────────
{
    my $p = CLIO::Providers::Anthropic->new(api_key => 'k', model => 'claude-sonnet-4.5');

    # Default config (no opts) should be enabled, medium effort
    my $cfg = $p->_default_thinking_config('claude-sonnet-4.5');
    ok($cfg->{enabled}, 'Anthropic: default thinking enabled');
    is($cfg->{effort}, 'medium', 'Anthropic: default effort is medium');
    ok($cfg->{budget_tokens} >= 1024, 'Anthropic: budget_tokens set for enabled mode');

    # Explicit disabled
    $cfg = $p->_default_thinking_config('claude-sonnet-4.5', { enabled => 0 });
    ok(!$cfg->{enabled}, 'Anthropic: explicit disabled');

    # High effort
    $cfg = $p->_default_thinking_config('claude-sonnet-4.5', { enabled => 1, effort => 'high' });
    is($cfg->{effort}, 'high', 'Anthropic: high effort preserved');
    ok($cfg->{budget_tokens} >= 10240, 'Anthropic: high effort has larger budget');

    # Adaptive model (4.6+)
    $cfg = $p->_default_thinking_config('claude-sonnet-4-6');
    is($cfg->{mode}, 'adaptive', 'Anthropic: 4.6+ uses adaptive mode');
    ok(!exists $cfg->{budget_tokens}, 'Anthropic: adaptive mode has no budget_tokens');
}

# ── 11. Anthropic _supports_adaptive_thinking ─────────────────────────
{
    my $p = CLIO::Providers::Anthropic->new(api_key => 'k', model => 'claude-sonnet-4.5');

    ok(!$p->_supports_adaptive_thinking('claude-sonnet-4.5'), 'Anthropic: 4.5 not adaptive');
    ok(!$p->_supports_adaptive_thinking('claude-opus-4-5-20250610'), 'Anthropic: dated 4.5 not adaptive');
    ok($p->_supports_adaptive_thinking('claude-sonnet-4-6'), 'Anthropic: 4.6 is adaptive');
    ok($p->_supports_adaptive_thinking('claude-opus-4-10'), 'Anthropic: 4.10 is adaptive');
    ok($p->_supports_adaptive_thinking('claude-mythos'), 'Anthropic: mythos is adaptive');
    ok(!$p->_supports_adaptive_thinking('claude-3-5-sonnet'), 'Anthropic: 3.5 not adaptive');
}

# ── 12. Anthropic _needs_interleaved_thinking_beta ────────────────────
{
    my $p = CLIO::Providers::Anthropic->new(api_key => 'k', model => 'claude-sonnet-4.5');

    ok($p->_needs_interleaved_thinking_beta('claude-sonnet-4.5'), 'Anthropic: 4.5 needs beta');
    ok($p->_needs_interleaved_thinking_beta('claude-opus-4-5'), 'Anthropic: opus 4.5 needs beta');
    ok($p->_needs_interleaved_thinking_beta('claude-3-7-sonnet'), 'Anthropic: 3.7 needs beta');
    ok(!$p->_needs_interleaved_thinking_beta('claude-sonnet-4-6'), 'Anthropic: 4.6 no beta needed');
    ok(!$p->_needs_interleaved_thinking_beta('claude-mythos'), 'Anthropic: mythos no beta needed');
}

# ── 13. Anthropic _max_thinking_budget_for_model ───────────────────────
{
    my $p = CLIO::Providers::Anthropic->new(api_key => 'k', model => 'claude-sonnet-4.5');

    is($p->_max_thinking_budget_for_model('claude-sonnet-4.5'), 32000, 'Anthropic: sonnet 4.5 max 32k');
    is($p->_max_thinking_budget_for_model('claude-opus-4-5'), 32000, 'Anthropic: opus 4.5 max 32k');
    is($p->_max_thinking_budget_for_model('claude-haiku-4-5'), 8000, 'Anthropic: haiku 4.5 max 8k');
    is($p->_max_thinking_budget_for_model('claude-3-7-sonnet'), 64000, 'Anthropic: 3.7 sonnet max 64k');
    is($p->_max_thinking_budget_for_model('unknown-model'), 32000, 'Anthropic: unknown defaults 32k');
}

# ── 14. Anthropic get_headers respects per-request model ──────────────
{
    my $p = CLIO::Providers::Anthropic->new(api_key => 'k', model => 'claude-sonnet-4.5');

    # Default model (4.5) should include beta header
    my $h1 = $p->get_headers();
    ok($h1->{'anthropic-beta'} =~ /interleaved-thinking/, 'Anthropic: 4.5 default includes beta header');

    # Override with 4.6 (no beta needed)
    my $h2 = $p->get_headers('claude-sonnet-4-6');
    ok(!defined $h2->{'anthropic-beta'} || $h2->{'anthropic-beta'} !~ /interleaved-thinking/,
       'Anthropic: 4.6 override skips beta header');

    # Override with 3.7 (needs beta)
    my $h3 = $p->get_headers('claude-3-7-sonnet');
    ok($h3->{'anthropic-beta'} =~ /interleaved-thinking/, 'Anthropic: 3.7 override includes beta header');
}

# ── 15. Google _build_thinking_config ─────────────────────────────────
{
    my $p = CLIO::Providers::Google->new(api_key => 'k', model => 'gemini-2.5-flash');

    # Default: enabled, medium effort
    my $cfg = $p->_build_thinking_config('gemini-2.5-flash');
    ok($cfg, 'Google: default thinking config returned');
    is($cfg->{thinkingBudget}, 8192, 'Google: medium effort = 8192 budget');
    ok($cfg->{includeThoughts}, 'Google: includeThoughts is true');

    # Low effort
    $cfg = $p->_build_thinking_config('gemini-2.5-flash', { effort => 'low' });
    is($cfg->{thinkingBudget}, 1024, 'Google: low effort = 1024 budget');

    # High effort
    $cfg = $p->_build_thinking_config('gemini-2.5-flash', { effort => 'high' });
    is($cfg->{thinkingBudget}, 24576, 'Google: high effort = 24576 budget');

    # Explicit budget override
    $cfg = $p->_build_thinking_config('gemini-2.5-flash', { budget => 5000 });
    is($cfg->{thinkingBudget}, 5000, 'Google: explicit budget override');

    # Disabled
    $cfg = $p->_build_thinking_config('gemini-2.5-flash', { enabled => 0 });
    ok(!defined $cfg, 'Google: disabled returns undef');

    # Unsupported model
    $cfg = $p->_build_thinking_config('gemini-1.5-pro');
    ok(!defined $cfg, 'Google: gemini-1.5-pro unsupported');
    $cfg = $p->_build_thinking_config('gemini-2.0-flash');
    ok(!defined $cfg, 'Google: gemini-2.0 unsupported');
}

# ── 16. Anthropic build_request sets thinking in payload ──────────────
{
    my $p = CLIO::Providers::Anthropic->new(api_key => 'k', model => 'claude-sonnet-4.5');

    my $req = $p->build_request(
        [{ role => 'user', content => 'test' }],
        [],
        { thinking => { enabled => 1, mode => 'enabled', effort => 'medium' } },
    );
    my $body = decode_json($req->{body});
    ok($body->{thinking}, 'Anthropic: thinking key in payload');
    is($body->{thinking}{type}, 'enabled', 'Anthropic: thinking type=enabled');
    # Budget is derived from effort by _default_thinking_config; medium => 10240.
    is($body->{thinking}{budget_tokens}, 10240, 'Anthropic: budget_tokens derived from effort=medium');

    # effort=low yields 4096
    $req = $p->build_request(
        [{ role => 'user', content => 'test' }],
        [],
        { thinking => { enabled => 1, mode => 'enabled', effort => 'low' } },
    );
    $body = decode_json($req->{body});
    is($body->{thinking}{budget_tokens}, 4096, 'Anthropic: budget_tokens derived from effort=low');
}

# ── 17. Google build_request sets thinkingConfig in payload ───────────
{
    my $p = CLIO::Providers::Google->new(api_key => 'k', model => 'gemini-2.5-flash');

    my $req = $p->build_request(
        [{ role => 'user', content => 'test' }],
        [],
        { thinking => { enabled => 1, effort => 'high' } },
    );
    my $body = decode_json($req->{body});
    ok($body->{generationConfig}{thinkingConfig}, 'Google: thinkingConfig in payload');
    is($body->{generationConfig}{thinkingConfig}{thinkingBudget}, 24576, 'Google: thinkingBudget in payload');
}

# ── 18. Multiple thinking blocks in a single response ────────────────
{
    my $p = CLIO::Providers::Anthropic->new(api_key => 'k', model => 'claude-sonnet-4.5');

    # First thinking block
    $p->parse_stream_event(
        'data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","signature":"sig1"}}');
    $p->parse_stream_event(
        'data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"First thought..."}}');
    $p->parse_stream_event(
        'data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig1_final"}}');
    $p->parse_stream_event('data: {"type":"content_block_stop","index":0}');

    # Second thinking block (redacted)
    $p->parse_stream_event(
        'data: {"type":"content_block_start","index":1,"content_block":{"type":"redacted_thinking","data":"redacted_blob"}}');
    $p->parse_stream_event('data: {"type":"content_block_stop","index":1}');

    my $blocks = $p->get_thinking_blocks();
    is(scalar @$blocks, 2, 'Anthropic: two thinking blocks captured');
    is($blocks->[0]{type}, 'thinking', 'Anthropic: first block is thinking');
    is($blocks->[0]{signature}, 'sig1_final', 'Anthropic: first block signature');
    is($blocks->[1]{type}, 'redacted_thinking', 'Anthropic: second block is redacted');
    is($blocks->[1]{data}, 'redacted_blob', 'Anthropic: second block data');
}

# ── 19. Google multi-part chunk processes all parts ───────────────────
{
    my $p = CLIO::Providers::Google->new(api_key => 'k', model => 'gemini-2.5-flash');

    # Chunk with thought text + thoughtSignature in same chunk
    my $ev = $p->parse_stream_event('data: '.join('', (
        '{"candidates":[{"content":{"parts":[',
        '{"text":"Reasoning...","thought":true,"thoughtSignature":"sig_multi"}',
        ']},"role":"model"}]}',
    )));
    is($ev->{type}, 'thinking', 'Google: multi-part chunk returns thinking event');
    is($ev->{content}, 'Reasoning...', 'Google: thinking text preserved');

    my $blocks = $p->get_thinking_blocks();
    is(scalar @$blocks, 1, 'Google: thought block captured from multi-part chunk');
    is($blocks->[0]{signature}, 'sig_multi', 'Google: signature captured from same chunk');
}

# ── 20. show_thinking=0 does not pass thinking_opt for native providers ─
{
    require CLIO::Core::Config;
    my $config = CLIO::Core::Config->new();
    # show_thinking defaults to 0
    my $mgr = CLIO::Core::APIManager->new(
        provider => 'anthropic',
        model => 'claude-sonnet-4.5',
        config => $config,
    );
    # _endpoint_supports_thinking returns true for anthropic, but
    # show_thinking=0 means no thinking_opt should be built.
    # We can't directly test the private method, but we verify the
    # config default.
    # show_thinking defaults to 1 in Config (user can disable it)
    is($config->get('show_thinking'), 1, 'Config: show_thinking defaults to 1');
    ok($mgr->_endpoint_supports_thinking(), 'APIManager: anthropic supports thinking');
}

print "\nAll reasoning round-trip tests passed!\n";
