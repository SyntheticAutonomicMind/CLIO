#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Test: CLIO's prompt-cache contract
#
# Tests the three-layer cache architecture:
#   1. Workflow Identity  — stable CLIO session UUID -> OpenRouter session_id
#   2. Stable Prefix      — system prompt (cached, no LTM/mutable state)
#   3. Dynamic Projection  — ContextBuilder output (LTM, todos, history)
#
# Regression coverage for the cache-affinity-loss bug where cached_tokens
# collapsed from ~192,768 to ~2,272 between request 1 and request 2 of the
# same workflow, because OpenRouter was not receiving a stable session_id
# and fell back to hashing the first system + non-system message (which
# changed between turns).

use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../../lib";

use Test::More;
use JSON::PP qw(encode_json);
use Digest::SHA qw(sha256_hex);
use Encode qw(encode_utf8);
use File::Temp qw(tempdir);

use CLIO::Core::APIManager;
use CLIO::Core::API::MessageValidator qw(validate_and_truncate);
use CLIO::Core::PromptBuilder;

# =============================================================================
# Test mock infrastructure
# =============================================================================

# A minimal session stand-in that satisfies APIManager's session access
# patterns ($self->{session}{session_id}, ->can('state'), ->state())
{
    package CLIO::Test::MockSession;

    sub new {
        my ($class, $id) = @_;
        return bless { session_id => $id }, $class;
    }
    sub can {
        my ($self, $method) = @_;
        return 1 if $method eq 'state' || $method eq 'session_id';
        return $self->SUPER::can($method);
    }
    sub state {
        my ($self) = @_;
        return $self;
    }
    sub session_id {
        my ($self) = @_;
        return $self->{session_id};
    }
    sub save { }
}

# A minimal Config shim
{
    package CLIO::Test::MockConfig;
    sub new { bless { cfg => {} }, shift }
    sub get  {
        my ($self, $key) = @_;
        return $self->{cfg}{$key};
    }
    sub set  {
        my ($self, $key, $val) = @_;
        $self->{cfg}{$key} = $val;
        return 1;
    }
}

# A minimal ToolRegistry shim
{
    package CLIO::Test::MockToolRegistry;
    sub new           { bless { tools => [] }, shift }
    sub get_all_tools { $_[0]->{tools} }
    sub has_tool      { 0 }
}

# A minimal ResponseHandler shim
{
    package CLIO::Test::MockResponseHandler;
    sub new              { bless {}, shift }
    sub set_session      { }
    sub should_log       { 0 }
    sub set_apimanager   { }
    sub get_stateful_marker_for_model { undef }
}

# Subclass APIManager to bypass network-heavy initialization.
{
    package CLIO::Test::MockAPIManager;
    our @ISA = ('CLIO::Core::APIManager');

    sub new {
        my ($class, %args) = @_;
        my $self = {
            api_base               => 'https://openrouter.ai/api/v1/chat/completions',
            request_state          => 0,
            error                  => undef,
            start_time             => 0,
            api_key                => 'sk-test',
            config                 => $args{config},
            debug                  => $args{debug} // 0,
            config_dir             => '/tmp',
            rate_limit_until       => 0,
            session                => $args{session},
            broker_client          => undef,
            performance_monitor    => undef,
            learned_token_ratio    => 2.5,
            rate_limiter           => CLIO::Core::RateLimiter->get_instance(),
            response_handler       => $args{response_handler} // {},
            _request_seq           => 0,
            _pending_cache_diag    => undef,
            _last_system_hash      => undef,
            _last_first_nonsys_hash => undef,
            _last_nonsys_is_first  => 1,
            _last_retry_reason     => undef,
            _copilot_session_id    => 'mock-copilot-sid',
            _copilot_machine_id    => 'mock-machine-id',
        };
        return bless $self, $class;
    }

    sub _compute_budget_aware_max_output_tokens { return 4096 }
    sub get_current_model                    { 'openrouter:meta-llama/llama-3.1-405b-instruct' }
    sub model_supports_tools                 { 1 }
    sub get_model_capabilities               { undef }

    sub adapt_request_for_endpoint {
        my ($self, $payload, $endpoint_config) = @_;
        if (!$endpoint_config->{requires_copilot_headers}) {
            delete $payload->{copilot_thread_id}     if exists $payload->{copilot_thread_id};
            delete $payload->{previous_response_id}  if exists $payload->{previous_response_id};
        }
        return $payload;
    }
}

sub make_api_manager {
    my ($session_id, %extra) = @_;
    $session_id //= '12345678-1234-1234-1234-123456789012';

    my $config = CLIO::Test::MockConfig->new();
    $config->set('api_base', 'https://openrouter.ai/api/v1/chat/completions');
    $config->set('provider', 'openrouter');
    $config->set('model',    'meta-llama/llama-3.1-405b-instruct');
    $config->set('api_key',  'sk-test-key');

    my $session = CLIO::Test::MockSession->new($session_id);

    return CLIO::Test::MockAPIManager->new(
        debug => $ENV{CLIO_DEBUG} ? 1 : 0,
        session => $session,
        config => $config,
        response_handler => CLIO::Test::MockResponseHandler->new(),
    );
}

sub openrouter_ec {
    return {
        name                    => 'OpenRouter',
        openrouter              => 1,
        supports_tools          => 1,
        supports_streaming      => 1,
        supports_cache_control  => 1,
        requires_copilot_headers => 0,
        auth_header             => 'Authorization',
        auth_value              => 'Bearer sk-test',
        temperature_range       => [0.0, 2.0],
    };
}

sub openai_ec {
    return {
        name                    => 'OpenAI',
        openrouter              => 0,
        supports_tools          => 1,
        supports_streaming      => 1,
        requires_copilot_headers => 0,
        auth_header             => 'Authorization',
        auth_value              => 'Bearer sk-test',
        temperature_range       => [0.0, 2.0],
    };
}

sub sample_messages {
    return [
        { role => 'system',  content => 'You are a helpful coding assistant.' },
        { role => 'user',    content => 'What is 2 + 2?' },
    ];
}

# =============================================================================
# Test 1: _get_workflow_session_id extracts the CLIO session UUID
# =============================================================================
{
    my $api = make_api_manager('abcdef12-3456-7890-abcd-ef1234567890');
    my $sid = $api->_get_workflow_session_id();
    is($sid, 'clio:abcdef12-3456-7890-abcd-ef1234567890',
        'session_id returns clio-prefixed UUID');
    like($sid, qr/^clio:/, 'session_id has clio: prefix');
    ok(length($sid) <= 256, 'session_id is within OpenRouter 256-char limit');
}

# =============================================================================
# Test 2: session_id appears in OpenRouter payloads
# =============================================================================
{
    my $api = make_api_manager();
    my $payload = $api->_build_payload(sample_messages(), 'openrouter:meta-llama/llama-3.1-405b', openrouter_ec());
    ok(exists $payload->{session_id},
        'OpenRouter payload contains session_id');
    like($payload->{session_id}, qr/^clio:/,
        'OpenRouter session_id has clio: prefix');
}

# =============================================================================
# Test 3: session_id does NOT appear in non-OpenRouter payloads
# =============================================================================
{
    my $api = make_api_manager();
    my $payload = $api->_build_payload(sample_messages(), 'gpt-4.1', openai_ec());
    ok(!exists $payload->{session_id},
        'Non-OpenRouter payload does NOT contain session_id');
}

# =============================================================================
# Test 4: Same session produces identical session_id across multiple requests
# (proves no per-request regeneration)
# =============================================================================
{
    my $api = make_api_manager('test-same-session-uuid');
    my $ec = openrouter_ec();

    my $p1 = $api->_build_payload(sample_messages(), 'openrouter:model', $ec);
    my $p2 = $api->_build_payload(sample_messages(), 'openrouter:model', $ec);
    my $p3 = $api->_build_payload(sample_messages(), 'openrouter:model', $ec);

    is($p1->{session_id}, $p2->{session_id},
        'session_id identical across 3 requests in same workflow');
    is($p2->{session_id}, $p3->{session_id},
        'session_id identical on 3rd request');
    is($api->{_request_seq}, 3, 'request sequence counter incremented to 3');
}

# =============================================================================
# Test 5: Different sessions produce different session_ids
# =============================================================================
{
    my $api_a = make_api_manager('aaaaaaaa-bbbb-cccc-dddd-111111111111');
    my $api_b = make_api_manager('bbbbbbbb-cccc-dddd-eeee-222222222222');

    my $sid_a = $api_a->_get_workflow_session_id();
    my $sid_b = $api_b->_get_workflow_session_id();

    ok($sid_a ne $sid_b,
        'Different CLIO sessions produce different OpenRouter session_ids');
    is($sid_a, 'clio:aaaaaaaa-bbbb-cccc-dddd-111111111111', 'session A identity correct');
    is($sid_b, 'clio:bbbbbbbb-cccc-dddd-eeee-222222222222', 'session B identity correct');
}

# =============================================================================
# Test 6: No session => no session_id in payload (graceful fallback)
# =============================================================================
{
    my $api = make_api_manager();
    $api->{session} = undef;
    my $ec = openrouter_ec();
    my $payload = $api->_build_payload(sample_messages(), 'openrouter:model', $ec);
    ok(!exists $payload->{session_id},
        'No session => no session_id (graceful fallback to message prefix hashing)');
}

# =============================================================================
# Test 7: set_session resets cache-diagnostics state
# =============================================================================
{
    my $api = make_api_manager('sid-1');
    $api->{_request_seq} = 5;
    $api->{_last_system_hash} = 'abc123';
    $api->set_session(CLIO::Test::MockSession->new('sid-2'));
    is($api->{_request_seq}, 0, 'request_seq reset by set_session');
    ok(!defined $api->{_last_system_hash}, 'system_hash cleared by set_session');
}

# =============================================================================
# Test 8: System prompt byte-identical across PromptBuilder instances
# (no LTM injection — LTM goes through dynamic UC only)
# =============================================================================
{
    my $tool_registry = CLIO::Test::MockToolRegistry->new();
    my $pb1 = CLIO::Core::PromptBuilder->new(debug => 0, tool_registry => $tool_registry);
    my $pb2 = CLIO::Core::PromptBuilder->new(debug => 0, tool_registry => $tool_registry);

    my $sp1 = $pb1->build_system_prompt();
    my $sp2 = $pb2->build_system_prompt();

    is(sha256_hex(encode_utf8($sp1)), sha256_hex(encode_utf8($sp2)),
        'System prompt byte-identical across separate PromptBuilder instances');

    my $sp1_cached = $pb1->build_system_prompt();
    is(sha256_hex(encode_utf8($sp1)), sha256_hex(encode_utf8($sp1_cached)),
        'Cached system prompt byte-identical on second call');
}

# =============================================================================
# Test 9: MessageValidator preserves byte identity when no truncation needed
# =============================================================================
{
    my @messages = (
        { role => 'system', content => 'Stable system prompt' },
        { role => 'user',   content => 'First user message (anchor)' },
        { role => 'assistant', content => 'Working...', tool_calls => [
            { id => 'tc_1', type => 'function',
              function => { name => 'file_operations', arguments => '{"operation":"grep_search"}' } }
        ]},
        { role => 'tool', tool_call_id => 'tc_1', content => 'Tool result' },
        { role => 'user', content => 'Follow-up' },
    );

    my $json_before = encode_json(\@messages);

    my $trimmed = validate_and_truncate(
        messages           => \@messages,
        model_capabilities => { max_prompt_tokens => 128000 },
        token_ratio        => 2.5,
    );

    my $json_after = encode_json($trimmed);

    is($json_before, $json_after,
        'MessageValidator returns byte-identical messages when no truncation needed');
}

# =============================================================================
# Test 10: Tool serialization determinism (canonical JSON)
# =============================================================================
{
    my @tools = (
        { type => 'function', function => { name => 'file_operations', description => 'A', parameters => { type => 'object' } } },
        { type => 'function', function => { name => 'web_operations',  description => 'B', parameters => { type => 'object' } } },
    );

    my $json1 = JSON::PP->new->canonical->encode(\@tools);
    my $json2 = JSON::PP->new->canonical->encode(\@tools);
    is($json1, $json2,
        'Identical tool arrays produce byte-identical JSON with canonical ordering');

    my $base = { type => 'function', function => { name => 'test', parameters => { type => 'object', properties => {} } } };
    my $reordered = { function => { parameters => { properties => {}, type => 'object' }, name => 'test' }, type => 'function' };
    my $json_a = JSON::PP->new->canonical->encode($base);
    my $json_b = JSON::PP->new->canonical->encode($reordered);
    is($json_a, $json_b,
        'Hash key reordering does not affect canonical JSON serialization');
}

# =============================================================================
# Test 11: session_id survives context trimming
# =============================================================================
{
    my $api = make_api_manager('trim-test-uuid');
    my $ec = openrouter_ec();

    my @before = (
        { role => 'system', content => 'System prompt' },
        { role => 'user', content => 'Original task' },
        { role => 'assistant', content => 'Working...' },
        { role => 'tool', tool_call_id => 'tc1', content => 'result' },
        { role => 'user', content => 'Next step' },
    );
    my @after = (
        { role => 'system', content => 'System prompt' },
        { role => 'user', content => 'Compressed: Original task + Working...' },
        { role => 'user', content => 'Next step' },
    );

    my $p1 = $api->_build_payload(\@before, 'openrouter:model', $ec);
    my $p2 = $api->_build_payload(\@after, 'openrouter:model', $ec);

    is($p1->{session_id}, $p2->{session_id},
        'session_id survives context trimming (same workflow)');
    is($p1->{messages}[0]{content}, $p2->{messages}[0]{content},
        'System prompt content unchanged after trimming');
}

# =============================================================================
# Test 12: SessionManager generates stable session_id for resume
# =============================================================================
{
    use CLIO::Session::Manager;
    use CLIO::Util::PathResolver;

    my $tmpdir = tempdir(CLEANUP => 1);
    CLIO::Util::PathResolver::init(base_dir => $tmpdir);

    my $mgr = CLIO::Session::Manager->create(working_directory => $tmpdir, debug => 0);
    my $sid = $mgr->id();
    ok($sid, 'SessionManager generated a session_id');

    like($sid, qr/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i,
        'Session ID is a valid UUID');

    $mgr->{state}->save();
    my $mgr2 = CLIO::Session::Manager->load($sid, debug => 0);
    is($mgr2->id(), $sid,
        'Session ID is preserved across save/load (resume)');
}

# =============================================================================
# Test 13: MockSession with session_id() method works correctly
# =============================================================================
{
    my $session = CLIO::Test::MockSession->new('method-uuid');
    my $api = make_api_manager();
    $api->{session} = $session;
    my $sid = $api->_get_workflow_session_id();
    is($sid, 'clio:method-uuid',
        'session_id() method-based session objects are handled correctly');
}

# =============================================================================
# Test 14: session_id length is within 256-char limit
# =============================================================================
{
    my $api = make_api_manager();
    my $sid = $api->_get_workflow_session_id();
    ok(length($sid) < 256,
        'session_id (clio: + UUID) = ' . length($sid) . ' chars, well under 256 limit');
}

# =============================================================================
# Test 15: PromptBuilder cache invalidation produces identical output
# when no config changed
# =============================================================================
{
    my $tool_registry = CLIO::Test::MockToolRegistry->new();
    my $pb = CLIO::Core::PromptBuilder->new(debug => 0, tool_registry => $tool_registry);
    my $sp1 = $pb->build_system_prompt();
    ok(defined $sp1 && length($sp1) > 0, 'Build 1: system prompt is non-empty');

    $pb->clear_prompt_cache();
    my $sp2 = $pb->build_system_prompt();

    is(sha256_hex(encode_utf8($sp1)), sha256_hex(encode_utf8($sp2)),
        'System prompt byte-identical after cache invalidation (no config change)');
}

done_testing();
