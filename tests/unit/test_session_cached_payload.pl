#!/usr/bin/env perl
# Test the "reload current state" fast path for session resume.
#
# What this covers:
# - State::set_last_api_payload / last_api_payload / last_api_metadata accessors
# - State::save -> load roundtrip preserves both fields
# - State::clear_last_api_payload resets state
# - WorkflowOrchestrator::_try_resume_from_payload:
#     * No payload -> returns undef (rebuild path)
#     * Same provider, same tools, larger ctx -> uses payload verbatim
#     * Same provider, same tools, smaller ctx -> trims payload
#     * Different provider -> returns undef
#     * Different tools -> returns undef
#     * Empty payload -> returns undef

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";

use Test::More;
use CLIO::Session::State;
use CLIO::Memory::LongTerm;
use CLIO::Memory::ShortTerm;
use CLIO::Memory::YaRN;
use CLIO::Util::JSON qw(decode_json encode_json);
use File::Temp qw(tempdir);

# Redirect sessions dir to a temp dir so we don't pollute the real tree.
my $tmpdir = tempdir(CLEANUP => 1);
require CLIO::Util::PathResolver;
no warnings 'redefine';
*CLIO::Util::PathResolver::get_sessions_dir = sub { return "$tmpdir/sessions" };
*CLIO::Util::PathResolver::get_session_file = sub {
    my ($id) = @_;
    return "$tmpdir/sessions/$id.json";
};
use warnings;

# Ensure sessions dir exists.
mkdir "$tmpdir/sessions" or die "Cannot mkdir sessions: $!";

# ============================================================================
# Part 1: State::set_last_api_payload / accessors
# ============================================================================

subtest 'set_last_api_payload stores messages + metadata' => sub {
    my $state = CLIO::Session::State->new(session_id => 'test-1', debug => 0);
    my $payload = [
        { role => 'system', content => 'You are CLIO.' },
        { role => 'user',   content => 'Hello' },
        { role => 'assistant', content => 'Hi there.' },
    ];

    my $copy = $state->set_last_api_payload(
        $payload,
        model          => 'claude-sonnet-4.5',
        provider       => 'anthropic',
        context_window => 200000,
        tools_signature => 'abc123',
    );

    is(ref($copy), 'ARRAY', 'set_last_api_payload returns arrayref copy');
    is(scalar @$copy, 3, 'copy has all 3 messages');
    isnt($copy, $payload, 'copy is not the same arrayref as input');

    my $stored = $state->last_api_payload;
    is(scalar @$stored, 3, 'last_api_payload accessor returns 3 messages');
    is($stored->[0]{role}, 'system', 'first message role preserved');
    is($stored->[1]{content}, 'Hello', 'second message content preserved');

    my $meta = $state->last_api_metadata;
    is($meta->{model}, 'claude-sonnet-4.5', 'metadata model stored');
    is($meta->{provider}, 'anthropic', 'metadata provider stored');
    is($meta->{context_window}, 200000, 'metadata context_window stored');
    is($meta->{tools_signature}, 'abc123', 'metadata tools_signature stored');
    ok($meta->{saved_at} > 0, 'metadata saved_at is set');
};

subtest 'set_last_api_payload croaks on non-arrayref' => sub {
    my $state = CLIO::Session::State->new(session_id => 'test-1b', debug => 0);
    eval { $state->set_last_api_payload("not an arrayref") };
    like($@, qr/payload must be an arrayref/, 'croaks on non-arrayref');
};

subtest 'mutating input does not affect stored copy' => sub {
    my $state = CLIO::Session::State->new(session_id => 'test-1c', debug => 0);
    my $payload = [
        { role => 'user', content => 'original' },
    ];
    $state->set_last_api_payload($payload, model => 'm', provider => 'p', context_window => 1000);

    # Mutate the input after storing.
    $payload->[0]{content} = 'MUTATED';
    push @$payload, { role => 'user', content => 'extra' };

    my $stored = $state->last_api_payload;
    is($stored->[0]{content}, 'original', 'stored copy not affected by input mutation');
    is(scalar @$stored, 1, 'stored copy not extended by input mutation');
};

subtest 'clear_last_api_payload resets both fields' => sub {
    my $state = CLIO::Session::State->new(session_id => 'test-1d', debug => 0);
    $state->set_last_api_payload(
        [{ role => 'user', content => 'x' }],
        model => 'm', provider => 'p', context_window => 1000, tools_signature => 'sig',
    );
    ok(@{$state->last_api_payload} > 0, 'payload non-empty before clear');
    $state->clear_last_api_payload;
    is(scalar @{$state->last_api_payload}, 0, 'payload empty after clear');
    is($state->last_api_metadata->{model}, undef, 'model cleared');
    is($state->last_api_metadata->{provider}, undef, 'provider cleared');
    is($state->last_api_metadata->{context_window}, 0, 'context_window cleared');
    is($state->last_api_metadata->{tools_signature}, undef, 'tools_signature cleared');
};

# ============================================================================
# Part 2: State::save/load roundtrip
# ============================================================================

subtest 'save -> load roundtrip preserves payload + metadata' => sub {
    my $sid = 'test-roundtrip';
    my $state = CLIO::Session::State->new(session_id => $sid, debug => 0);
    my $payload = [
        { role => 'system',    content => 'sys' },
        { role => 'user',      content => 'q1' },
        { role => 'assistant', content => 'a1', tool_calls => [{ id => 't1', function => { name => 'x', arguments => '{}' } }] },
        { role => 'tool',      content => 'r1', tool_call_id => 't1' },
        { role => 'assistant', content => 'final' },
    ];
    $state->set_last_api_payload(
        $payload,
        model          => 'claude-sonnet-4.5',
        provider       => 'anthropic',
        context_window => 200000,
        tools_signature => 'sig-xyz',
    );

    $state->save;

    my $reloaded = CLIO::Session::State->load($sid, debug => 0);
    ok(defined $reloaded, 'reload returned a state');

    my $loaded_payload = $reloaded->last_api_payload;
    is(scalar @$loaded_payload, 5, 'payload has 5 messages after reload');
    is($loaded_payload->[0]{role}, 'system', 'first message role preserved');
    is($loaded_payload->[2]{tool_calls}[0]{id}, 't1', 'tool_calls preserved');
    is($loaded_payload->[3]{tool_call_id}, 't1', 'tool_call_id preserved');

    my $loaded_meta = $reloaded->last_api_metadata;
    is($loaded_meta->{model}, 'claude-sonnet-4.5', 'metadata.model preserved');
    is($loaded_meta->{provider}, 'anthropic', 'metadata.provider preserved');
    is($loaded_meta->{context_window}, 200000, 'metadata.context_window preserved');
    is($loaded_meta->{tools_signature}, 'sig-xyz', 'metadata.tools_signature preserved');
    ok($loaded_meta->{saved_at} > 0, 'metadata.saved_at preserved');
};

subtest 'old session JSON without payload still loads cleanly' => sub {
    # Simulate a pre-feature session file by writing JSON without the new fields.
    my $sid = 'legacy-session';
    mkdir "$tmpdir/sessions";
    my $old_json = encode_json({
        history    => [],
        stm        => [],
        yarn       => {},
        billing    => { total_tokens => 0, total_requests => 0, requests => [], total_prompt_tokens => 0, total_completion_tokens => 0, total_premium_requests => 0, model => undef, multiplier => 0 },
        max_tokens => 128000,
        created_at => time(),
    });
    open my $fh, '>', "$tmpdir/sessions/$sid.json" or die "Cannot write legacy: $!";
    print $fh $old_json;
    close $fh;

    my $state = CLIO::Session::State->load($sid, debug => 0);
    ok(defined $state, 'legacy session loads');
    is(scalar @{$state->last_api_payload}, 0, 'last_api_payload defaults to empty');
    is($state->last_api_metadata->{saved_at}, 0, 'last_api_metadata defaults saved_at=0');
};

# ============================================================================
# Part 3: WorkflowOrchestrator::_try_resume_from_payload behavior
# ============================================================================

# Minimal stub session that returns a state hash via ->state()
package StubSession {
    sub new {
        my ($class, %args) = @_;
        return bless { state => $args{state} }, $class;
    }
    sub state { $_[0]->{state} }
}

# Minimal api_manager stub
package StubAPIManager {
    sub new {
        my ($class, %args) = @_;
        return bless { provider => $args{provider}, caps => $args{caps} }, $class;
    }
    sub get_current_provider    { $_[0]->{provider} }
    sub get_current_model       { 'm' }
    sub get_model_capabilities  { $_[0]->{caps} }
}

# Minimal tool_registry stub returning empty tool list (so signature = 'no-tools').

require CLIO::Core::WorkflowOrchestrator;
require CLIO::Core::Defaults;

# Build a real WorkflowOrchestrator so we can compute the actual tools
# signature that the resume fast path will compare against. The constructor
# registers all default tools (file_ops, terminal, web, etc.) into the
# Registry, which is exactly what production sees.
my $reference_orch = CLIO::Core::WorkflowOrchestrator->new(
    debug => 0,
    api_manager => StubAPIManager->new(provider => 'anthropic', caps => { max_context_window_tokens => 200000 }),
);
my $real_tools = $reference_orch->_build_tools_for_api(undef);
my $real_signature = $reference_orch->_tools_signature($real_tools);

subtest 'resume returns undef when no payload' => sub {
    my $state_h = { last_api_payload => [], last_api_metadata => { saved_at => 0 } };
    my $sess = StubSession->new(state => $state_h);
    my @result = $reference_orch->_try_resume_from_payload($sess, { max_context_window_tokens => 200000 });
    is(scalar @result, 0, 'returns empty list when no payload');
};

subtest 'resume uses payload verbatim when ctx is equal or larger' => sub {
    my $state_h = {
        last_api_payload => [
            { role => 'system', content => 'sys' },
            { role => 'user', content => 'q1' },
            { role => 'assistant', content => 'a1' },
        ],
        last_api_metadata => {
            model => 'm', provider => 'anthropic', context_window => 200000,
            tools_signature => $real_signature, saved_at => time(),
        },
    };
    my $sess = StubSession->new(state => $state_h);
    my ($msgs, $tools) = $reference_orch->_try_resume_from_payload($sess, { max_context_window_tokens => 200000 });
    ok($msgs && @$msgs, 'got messages back');
    is(scalar @$msgs, 3, 'got 3 messages');
    is($msgs->[-1]{content}, 'a1', 'last message is the assistant response from end of last session');
    ok($tools && ref($tools) eq 'ARRAY', 'got tools arrayref back');
};

subtest 'resume returns undef when provider differs' => sub {
    my $state_h = {
        last_api_payload => [ { role => 'user', content => 'q' } ],
        last_api_metadata => {
            model => 'm', provider => 'anthropic', context_window => 200000,
            tools_signature => $real_signature, saved_at => time(),
        },
    };
    my $sess = StubSession->new(state => $state_h);
    # Use an orchestrator wired to a DIFFERENT provider.
    my $openai_orch = CLIO::Core::WorkflowOrchestrator->new(
        debug => 0,
        api_manager => StubAPIManager->new(provider => 'openai', caps => { max_context_window_tokens => 128000 }),
    );
    my @result = $openai_orch->_try_resume_from_payload($sess, { max_context_window_tokens => 128000 });
    is(scalar @result, 0, 'returns empty list when provider changed');
};

subtest 'resume trims payload when current ctx is smaller' => sub {
    # Build a large payload so trim has work to do. Each message must
    # be large enough to overflow the 8000-token budget; previous test
    # used 'filler-' x 80 which only produces ~140 tokens per message
    # and never overflowed the budget.
    my @big_history;
    for my $i (1..40) {
        push @big_history, { role => 'user',      content => ('filler-' x 4000) };      # ~7000 tokens
        push @big_history, { role => 'assistant', content => ('response-' x 4000) };    # ~7000 tokens
    }
    # Total: 40 * 2 * 7000 = 560,000 tokens of dialog. Way over any 8000-ctx budget.
    my $state_h = {
        last_api_payload => [
            { role => 'system', content => 'sys' },
            @big_history,
        ],
        last_api_metadata => {
            model => 'm', provider => 'anthropic', context_window => 200000,
            tools_signature => $real_signature, saved_at => time(),
        },
    };
    my $sess = StubSession->new(state => $state_h);
    my $small_orch = CLIO::Core::WorkflowOrchestrator->new(
        debug => 0,
        api_manager => StubAPIManager->new(provider => 'anthropic', caps => { max_context_window_tokens => 8000, max_output_tokens => 2000 }),
    );
    my ($msgs, $tools) = $small_orch->_try_resume_from_payload($sess, { max_context_window_tokens => 8000, max_output_tokens => 2000 });
    ok($msgs && @$msgs, 'got trimmed messages');
    ok(scalar @$msgs < 81, 'trimmed down from full payload (was 81 msgs, got ' . scalar(@$msgs) . ')');
};

# Regression test for the CachyLLama bug (2026-08-20): cached payload of 159743
# tokens sent to a 131072-ctx llama.cpp model caused HTTP 400 "request exceeds
# context size" with no recovery. The fast path returned the payload verbatim
# because the saved context_window equalled the current one, but the payload
# had grown past the actual prompt budget between turns (previous turn had
# tools that pushed @messages past the threshold).
#
# The fix: the fast path ALWAYS trims the cached payload against the current
# model's prompt budget (using validate_and_truncate), regardless of whether
# the saved context_window is bigger or smaller than the current one. The
# gate `current_ctx >= saved_ctx` is removed.
subtest 'resume trims oversized payload even when saved_ctx == current_ctx (regression)' => sub {
    # Simulate the CachyLLama case: saved_ctx matches current_ctx (both 131072),
    # but the cached payload has grown past the budget.
    my @huge_history;
    # 100K tokens worth of filler to overflow any reasonable budget.
    for my $i (1..200) {
        push @huge_history, { role => 'user',      content => ('filler-' x 500) };       # ~2500 tokens
        push @huge_history, { role => 'assistant', content => ('response-' x 500) };     # ~2500 tokens
    }
    # Total: 200 * 2 * 2500 = 1,000,000 tokens of dialog. Way over any budget.
    my $state_h = {
        last_api_payload => [
            { role => 'system', content => 'sys' },
            @huge_history,
        ],
        last_api_metadata => {
            model => 'm', provider => 'llama.cpp', context_window => 131072,
            tools_signature => $real_signature, saved_at => time(),
        },
    };
    my $sess = StubSession->new(state => $state_h);
    my $orch = CLIO::Core::WorkflowOrchestrator->new(
        debug => 0,
        api_manager => StubAPIManager->new(provider => 'llama.cpp', caps => { max_context_window_tokens => 131072, max_output_tokens => 32768 }),
    );
    my ($msgs, $tools) = $orch->_try_resume_from_payload(
        $sess,
        { max_context_window_tokens => 131072, max_output_tokens => 32768 }
    );
    ok($msgs && @$msgs, 'got messages back');
    # CRITICAL: payload MUST have been trimmed. With 1M tokens of filler and
    # a 131072 ctx model (90% threshold = ~117964), the result must be a small
    # fraction of the input.
    ok(scalar(@$msgs) < 401, 'payload was trimmed (got ' . scalar(@$msgs) . ' messages, was 401)');
    ok(scalar(@$msgs) >= 1, 'at least one message preserved after trimming');
};

subtest 'resume preserves payload when it fits current budget' => sub {
    # Small payload that fits the budget - should pass through verbatim
    # (only the user_context strip happens).
    my $state_h = {
        last_api_payload => [
            { role => 'system', content => 'sys' },
            { role => 'user',   content => 'q' },
            { role => 'assistant', content => 'a' },
        ],
        last_api_metadata => {
            model => 'm', provider => 'anthropic', context_window => 200000,
            tools_signature => $real_signature, saved_at => time(),
        },
    };
    my $sess = StubSession->new(state => $state_h);
    my $orch = CLIO::Core::WorkflowOrchestrator->new(
        debug => 0,
        api_manager => StubAPIManager->new(provider => 'anthropic', caps => { max_context_window_tokens => 200000, max_output_tokens => 16384 }),
    );
    my ($msgs, $tools) = $orch->_try_resume_from_payload(
        $sess,
        { max_context_window_tokens => 200000, max_output_tokens => 16384 }
    );
    ok($msgs && @$msgs, 'got messages back');
    is(scalar @$msgs, 3, 'small payload preserved verbatim (3 messages)');
};

subtest 'resume tools_signature mismatch falls back to rebuild' => sub {
    my $state_h = {
        last_api_payload => [ { role => 'user', content => 'q' } ],
        last_api_metadata => {
            model => 'm', provider => 'anthropic', context_window => 200000,
            tools_signature => 'wrong-signature-' . time(), saved_at => time(),
        },
    };
    my $sess = StubSession->new(state => $state_h);
    my @result = $reference_orch->_try_resume_from_payload($sess, { max_context_window_tokens => 200000 });
    is(scalar @result, 0, 'returns empty list on tools signature mismatch');
};

# Regression test: the resume fast path must work with the REAL CLIO::Session::State
# object (a blessed hashref), not only with bare hashrefs from StubSession. A
# previous bug used `ref($state) eq 'HASH'` which is FALSE for blessed refs
# (ref() returns the class name), so the fast path silently returned empty in
# production. This test pins the blessed-ref behaviour.
subtest 'resume fast path works with blessed CLIO::Session::State (regression)' => sub {
    my $real_state = CLIO::Session::State->new(session_id => 'regression-blessed', debug => 0);
    $real_state->set_last_api_payload(
        [
            { role => 'system',    content => 'sys' },
            { role => 'user',      content => 'q' },
            { role => 'assistant', content => 'a' },
        ],
        model           => 'm',
        provider        => 'anthropic',
        context_window  => 200000,
        tools_signature => $real_signature,
    );

    my $sess = StubSession->new(state => $real_state);
    my ($msgs, $tools) = $reference_orch->_try_resume_from_payload($sess, { max_context_window_tokens => 200000 });
    ok($msgs && @$msgs, 'got messages back from blessed State object (was the bug: returned empty)');
    is(scalar @$msgs, 3, 'got 3 messages from blessed State');
    ok($tools && ref($tools) eq 'ARRAY', 'got tools arrayref back');
};

subtest '_capture_api_payload works with blessed CLIO::Session::State (regression)' => sub {
    my $real_state = CLIO::Session::State->new(session_id => 'regression-capture', debug => 0);
    my $sess = StubSession->new(state => $real_state);
    my $messages = [
        { role => 'system',    content => 'sys' },
        { role => 'user',      content => 'q' },
        { role => 'assistant', content => 'a' },
    ];
    my $tools = [ { type => 'function', function => { name => 'noop', description => '', parameters => {} } } ];

    eval { $reference_orch->_capture_api_payload($sess, $messages, $tools) };
    is($@, '', '_capture_api_payload did not die on blessed State');

    my $stored = $real_state->last_api_payload;
    is(scalar @$stored, 3, 'payload was written to blessed State');
    my $meta = $real_state->last_api_metadata;
    is($meta->{provider}, 'anthropic', 'metadata.provider written');
    ok($meta->{saved_at} > 0, 'metadata.saved_at written');
};

# Regression test: snapshot captured AFTER tool execution must include
# tool_results. The CachyLLama bug (2026-08-18) had _capture_api_payload
# firing before tool execution, so the snapshot was missing tool_results.
# On the next turn's resume fast path, the cache returned the pre-tool
# state (no tool_results), while the rebuild path read session history
# (with tool_results) — divergent prompts that broke llama.cpp LCP.
#
# This test simulates the full flow:
#   1. Pre-tool state: [system, ..., user]
#   2. Capture snapshot (pre-fix bug: this is what would be saved)
#   3. Tool execution: append assistant + tool_results to @messages
#   4. Re-capture snapshot (post-fix correct behavior)
#   5. Resume: verify the post-fix snapshot includes the tool_results
subtest 'snapshot includes tool_results captured after tool execution (regression)' => sub {
    my $real_state = CLIO::Session::State->new(session_id => 'regression-end-of-turn', debug => 0);
    my $sess = StubSession->new(state => $real_state);
    # Use the REAL tools that _build_tools_for_api produces so the signature
    # matches what _try_resume_from_payload will compute.
    my $tools = $real_tools;

    # Simulate the in-memory @messages array at end of a tool-using turn.
    # This is what the orchestrator has AFTER _execute_tool_round completes
    # and the final assistant message has been appended. The snapshot must
    # reflect this exact state, not the pre-execution state.
    my $end_of_turn_messages = [
        { role => 'system',    content => 'sys' },
        { role => 'user',      content => 'q1' },
        { role => 'assistant', content => 'a1', tool_calls => [
            { id => 'tc_1', type => 'function', function => { name => 'file_operations', arguments => '{}' } },
        ] },
        { role => 'tool',      content => 'result_1', tool_call_id => 'tc_1' },
        { role => 'assistant', content => 'final answer' },
    ];

    $reference_orch->_capture_api_payload($sess, $end_of_turn_messages, $tools);

    my $stored = $real_state->last_api_payload;
    is(scalar @$stored, 5, 'snapshot has 5 messages (sys + user + assistant_with_tool_call + tool_result + final_assistant)');

    # Verify the snapshot includes the tool_result (the missing piece in the bug)
    my $has_tool_result = grep {
        $_->{role} eq 'tool' && ($_->{tool_call_id} // '') eq 'tc_1'
    } @$stored;
    ok($has_tool_result, 'snapshot includes the tool_result message (was missing in pre-fix bug)');

    # Verify the snapshot includes the final assistant message
    my $has_final_assistant = grep {
        $_->{role} eq 'assistant' && ($_->{content} // '') eq 'final answer'
    } @$stored;
    ok($has_final_assistant, 'snapshot includes the final assistant message');

    # Now simulate a session resume: load the state, call the resume fast path.
    # The fast path should return messages that include the tool_results and
    # the final assistant — the same conversation state we just snapshotted.
    my ($resumed_msgs, $resumed_tools) = $reference_orch->_try_resume_from_payload(
        $sess,
        { max_context_window_tokens => 200000 }
    );
    ok($resumed_msgs && @$resumed_msgs, 'resume returned messages');
    is(scalar @$resumed_msgs, 5, 'resumed payload has same 5 messages as snapshot (no divergence)');

    my $resumed_has_tool_result = grep {
        $_->{role} eq 'tool' && ($_->{tool_call_id} // '') eq 'tc_1'
    } @$resumed_msgs;
    ok($resumed_has_tool_result, 'resumed payload includes tool_results (the bug fix)');

    # Verify the snapshot's tool_call_id matches the resumed payload's
    # tool_call_id — same UUID, byte-identical. This is what makes the LCP
    # match work across resume.
    my $snapshot_tr = (grep { $_->{role} eq 'tool' } @$stored)[0];
    my $resumed_tr = (grep { $_->{role} eq 'tool' } @$resumed_msgs)[0];
    is($snapshot_tr->{tool_call_id}, $resumed_tr->{tool_call_id},
        'tool_call_id is byte-identical between snapshot and resumed payload');
    is($snapshot_tr->{content}, $resumed_tr->{content},
        'tool_result content is byte-identical between snapshot and resumed payload');
};

# Pipeline protocol: user_context is a separate role=system message at
# fixed position [-2], not prepended to user_input. This is the LCP-stable
# slot for dynamic context (date/time, dynamic context, session goals) —
# changes invalidate ONLY this message, not the dialog/tool_results before
# it.
subtest 'user_context is a separate role=system message at [-2] (pipeline protocol)' => sub {
    my $real_state = CLIO::Session::State->new(session_id => 'pipeline-protocol', debug => 0);
    my $sess = StubSession->new(state => $real_state);
    my $tools = $real_tools;

    # Build a messages array following the pipeline protocol layout:
    # [system, summary, dialog..., tool_results, user_context, user_input]
    my $messages = [
        { role => 'system',    content => 'SYSTEM PROMPT' },
        { role => 'user',      content => 'q1' },
        { role => 'assistant', content => 'a1', tool_calls => [
            { id => 'tc_1', type => 'function', function => { name => 'file_operations', arguments => '{}' } },
        ] },
        { role => 'tool',      content => 'r1', tool_call_id => 'tc_1' },
        { role => 'assistant', content => 'final' },
        { role => 'system',    content => "<userContext>\nDate: 2026-08-18\n</userContext>" },
        { role => 'user',      content => 'q2' },
    ];

    $reference_orch->_capture_api_payload($sess, $messages, $tools);

    my $stored = $real_state->last_api_payload;
    is(scalar @$stored, 7, 'snapshot has 7 messages (full pipeline protocol layout)');

    # Verify the user_context is at position [-2]
    is($stored->[-2]{role}, 'system', 'position [-2] is system (user_context)');
    like($stored->[-2]{content}, qr/userContext/, 'position [-2] contains <userContext> tag');

    # Verify user_input is at position [-1] (no user_context prefix)
    is($stored->[-1]{role}, 'user', 'position [-1] is user (raw user_input)');
    is($stored->[-1]{content}, 'q2', 'user_input is RAW input - no <userContext> prefix');

    # Verify user_input is NOT concatenated with user_context
    unlike($stored->[-1]{content}, qr/userContext/, 'user_input does NOT contain userContext prefix (the bug we just fixed)');
};

subtest 'resume strips stale trailing user_context and adds fresh (pipeline protocol)' => sub {
    my $real_state = CLIO::Session::State->new(session_id => 'pipeline-strip', debug => 0);
    my $sess = StubSession->new(state => $real_state);
    my $tools = $real_tools;

    # Snapshot from previous turn now includes the final assistant response
    # (Fix: assistant response is pushed to @messages before capture).
    # Layout: [sys, dialog..., user_context, user_input, assistant_response]
    my $snapshot = [
        { role => 'system',    content => 'SYSTEM PROMPT' },
        { role => 'user',      content => 'old_q1' },
        { role => 'assistant', content => 'old_a1' },
        { role => 'system',    content => "<userContext>\nDate: 2026-08-17 (STALE)\n</userContext>" },
        { role => 'user',      content => 'old_q2 (STALE)' },
        { role => 'assistant', content => 'old_a2 (STALE ASSISTANT RESPONSE)' },
    ];

    $reference_orch->_capture_api_payload($sess, $snapshot, $tools);

    # Simulate the resume fast path's strip-and-replace logic.
    # The new stripping scans backward for user_context + user pair and
    # removes everything from there (including trailing assistant/tool content).
    my ($resumed, $resumed_tools) = $reference_orch->_try_resume_from_payload(
        $sess,
        { max_context_window_tokens => 200000 }
    );
    ok($resumed && @$resumed, 'resume returned messages');

    # The new snapshot includes the assistant response (6 messages)
    is(scalar @$resumed, 6, 'snapshot has 6 messages including assistant response');

    # Simulate the NEW stripping logic from _build_turn_context:
    # Strip ONLY the user_context system message, keep everything else.
    my $strip_idx = undef;
    for (my $i = $#{$resumed}; $i >= 0; $i--) {
        if ($resumed->[$i]{role} eq 'system'
            && ($resumed->[$i]{content} // '') =~ /<(?:userContext|dynamicContext|sessionGoals)[\s>]/) {
            $strip_idx = $i;
            last;
        }
    }
    ok(defined $strip_idx, 'found user_context for stripping');
    splice(@$resumed, $strip_idx, 1);

    # After stripping only user_context, user_input + assistant_response remain
    is(scalar @$resumed, 5, 'after stripping only user_context, 5 messages remain');
    is($resumed->[-2]{role}, 'user', 'user_input still present after stripping');
    is($resumed->[-2]{content}, 'old_q2 (STALE)', 'user_input content preserved');
    is($resumed->[-1]{role}, 'assistant', 'assistant_response still present after stripping');
    is($resumed->[-1]{content}, 'old_a2 (STALE ASSISTANT RESPONSE)', 'assistant_response content preserved');
};

# Regression test: the OLD payload format (without assistant response at
# end) must still be handled correctly by the new stripping logic. This
# verifies backward compatibility — old session files saved before the
# fix should still strip properly.
subtest 'resume handles old payload format without assistant response (backward compat)' => sub {
    my $real_state = CLIO::Session::State->new(session_id => 'backward-compat', debug => 0);
    my $sess = StubSession->new(state => $real_state);
    my $tools = $real_tools;

    # Old format: ends with [user_context, user_input] (no assistant response)
    my $snapshot = [
        { role => 'system',    content => 'SYSTEM PROMPT' },
        { role => 'user',      content => 'old_q1' },
        { role => 'assistant', content => 'old_a1' },
        { role => 'system',    content => "<userContext>\nDate: 2026-08-17 (STALE)\n</userContext>" },
        { role => 'user',      content => 'old_q2 (STALE)' },
    ];

    $reference_orch->_capture_api_payload($sess, $snapshot, $tools);

    my ($resumed, $resumed_tools) = $reference_orch->_try_resume_from_payload(
        $sess,
        { max_context_window_tokens => 200000 }
    );
    ok($resumed && @$resumed, 'resume returned messages');
    is(scalar @$resumed, 5, 'snapshot has 5 messages (old format)');

    # Simulate the new stripping logic
    my $strip_idx = undef;
    for (my $i = $#{$resumed}; $i >= 0; $i--) {
        if ($resumed->[$i]{role} eq 'system'
            && ($resumed->[$i]{content} // '') =~ /<(?:userContext|dynamicContext|sessionGoals)[\s>]/) {
            $strip_idx = $i;
            last;
        }
    }
    ok(defined $strip_idx, 'found user_context for stripping (old format)');
    splice(@$resumed, $strip_idx, 1);

    is(scalar @$resumed, 4, 'after stripping only user_context, 4 messages remain');
    is($resumed->[-1]{role}, 'user', 'user_input still present');
    is($resumed->[-1]{content}, 'old_q2 (STALE)', 'user_input content preserved');
};

# Regression test: tool-calling turn where the payload ends with
# [user_context, user_input, assistant_tool_call, tool_results, assistant_response].
# The stripping must remove ALL of these (from user_context onwards),
# not just the last 2 messages. This is the case that caused the
# "agent ignores new user input on resume" bug — the old 2-pop code
# left stale user_input + user_context in the resumed prompt.
subtest 'resume strips tool_calling turn payload ending with assistant response' => sub {
    my $real_state = CLIO::Session::State->new(session_id => 'tool-turn-strip', debug => 0);
    my $sess = StubSession->new(state => $real_state);
    my $tools = $real_tools;

    # Payload from a tool-calling turn (after Fix 1):
    # [sys, user_q1, assistant_a1, user_context, user_q2, assistant_tc, tool_result, assistant_final]
    my $snapshot = [
        { role => 'system',    content => 'SYSTEM PROMPT' },
        { role => 'user',      content => 'q1' },
        { role => 'assistant', content => 'a1' },
        { role => 'system',    content => "<userContext>date: 2026-08-17</userContext>" },
        { role => 'user',      content => 'q2' },
        { role => 'assistant', content => 'tool call text', tool_calls => [
            { id => 'tc_1', type => 'function', function => { name => 'file_operations', arguments => '{}' } },
        ] },
        { role => 'tool',      content => 'result_1', tool_call_id => 'tc_1' },
        { role => 'assistant', content => 'final answer after tools' },
    ];

    $reference_orch->_capture_api_payload($sess, $snapshot, $tools);

    my ($resumed, $resumed_tools) = $reference_orch->_try_resume_from_payload(
        $sess,
        { max_context_window_tokens => 200000 }
    );
    ok($resumed && @$resumed, 'resume returned messages');
    is(scalar @$resumed, 8, 'snapshot has 8 messages (tool-calling turn with final response)');

    # Verify the assistant final response IS in the snapshot
    my $has_final = grep {
        $_->{role} eq 'assistant' && ($_->{content} // '') eq 'final answer after tools'
    } @$resumed;
    ok($has_final, 'snapshot includes final assistant response (Fix 1)');

    # Simulate the new stripping logic (strip only user_context)
    my $strip_idx = undef;
    for (my $i = $#{$resumed}; $i >= 0; $i--) {
        if ($resumed->[$i]{role} eq 'system'
            && ($resumed->[$i]{content} // '') =~ /<(?:userContext|dynamicContext|sessionGoals)[\s>]/) {
            $strip_idx = $i;
            last;
        }
    }
    ok(defined $strip_idx, 'found user_context for stripping in tool-call payload');
    splice(@$resumed, $strip_idx, 1);

    is(scalar @$resumed, 7, 'after stripping only user_context, 7 messages remain');
    is($resumed->[-4]{role}, 'user', 'user_input preserved');
    is($resumed->[-4]{content}, 'q2', 'user_input content preserved');
    is($resumed->[-3]{role}, 'assistant', 'assistant_tool_call preserved');
    is($resumed->[-2]{role}, 'tool', 'tool_result preserved');
    is($resumed->[-1]{role}, 'assistant', 'final assistant response preserved');
    is($resumed->[-1]{content}, 'final answer after tools', 'final assistant response content preserved');
};

# Pipeline protocol phase 5: per-section signatures stored alongside the
# payload. Each pipeline section (system_prompt, summary, context_files,
# dialog, tool_results, user_context, user_input) gets a SHA256 digest of
# its content. Future code can detect per-section drift and selectively
# rebuild only the drifted sections.
subtest 'section_signatures populated for all 7 sections (pipeline protocol phase 5)' => sub {
    my $real_state = CLIO::Session::State->new(session_id => 'phase5-signatures', debug => 0);
    my $sess = StubSession->new(state => $real_state);
    my $tools = $real_tools;

    my $messages = [
        { role => 'system',    content => 'SYSTEM PROMPT' },
        { role => 'system',    content => '<thread_summary>summary here</thread_summary>' },
        { role => 'system',    content => '[CONTEXT FILES] file contents' },
        { role => 'user',      content => 'q1' },
        { role => 'assistant', content => 'a1', tool_calls => [
            { id => 'tc_1', type => 'function', function => { name => 'file_operations', arguments => '{}' } },
        ] },
        { role => 'tool',      content => 'r1', tool_call_id => 'tc_1' },
        { role => 'assistant', content => 'final' },
        { role => 'system',    content => '<userContext>date: 2026-08-18</userContext>' },
        { role => 'user',      content => 'q2' },
    ];

    $reference_orch->_capture_api_payload($sess, $messages, $tools);

    my $sigs = $real_state->section_signatures;
    ok($sigs && ref($sigs) eq 'HASH', 'section_signatures is a hashref');

    # All 7 sections present
    my @expected = qw(system_prompt summary context_files dialog tool_results user_context user_input);
    for my $section (@expected) {
        ok(exists $sigs->{$section}, "section_signatures has $section entry");
        like($sigs->{$section}, qr/^[0-9a-f]{64}$/, "$section signature is a SHA256 hex digest");
    }

    # Each signature is unique (different content -> different digest)
    my %seen;
    for my $section (@expected) {
        my $sig = $sigs->{$section};
        ok(!$seen{$sig}, "$section signature is unique among sections (no accidental hash collision)")
            or diag("Signature collision on $section: $sig");
        $seen{$sig} = $section;
    }
};

subtest 'section_signatures: same content produces same digest (stability)' => sub {
    my $real_state = CLIO::Session::State->new(session_id => 'phase5-stable', debug => 0);
    my $sess = StubSession->new(state => $real_state);
    my $tools = $real_tools;

    my $messages = [
        { role => 'system',    content => 'SYSTEM PROMPT' },
        { role => 'user',      content => 'q1' },
        { role => 'assistant', content => 'a1' },
        { role => 'user',      content => 'q2' },
    ];

    $reference_orch->_capture_api_payload($sess, $messages, $tools);
    my $sigs1 = $real_state->section_signatures;

    # Capture again with byte-identical content
    $real_state->clear_last_api_payload;
    $reference_orch->_capture_api_payload($sess, $messages, $tools);
    my $sigs2 = $real_state->section_signatures;

    for my $section (keys %$sigs1) {
        is($sigs1->{$section}, $sigs2->{$section},
            "$section digest is stable across identical captures");
    }
};

subtest 'section_signatures: dialog change invalidates dialog but not system_prompt' => sub {
    my $real_state = CLIO::Session::State->new(session_id => 'phase5-drift', debug => 0);
    my $sess = StubSession->new(state => $real_state);
    my $tools = $real_tools;

    my $messages_v1 = [
        { role => 'system', content => 'STABLE SYSTEM' },
        { role => 'user',      content => 'q1' },
        { role => 'assistant', content => 'a1' },
        { role => 'user',      content => 'q2' },
    ];

    $reference_orch->_capture_api_payload($sess, $messages_v1, $tools);
    my $sigs_v1 = $real_state->section_signatures;

    # Add one more turn (dialog grew)
    my $messages_v2 = [
        { role => 'system', content => 'STABLE SYSTEM' },
        { role => 'user',      content => 'q1' },
        { role => 'assistant', content => 'a1' },
        { role => 'user',      content => 'q2' },
        { role => 'assistant', content => 'a2' },
    ];

    $real_state->clear_last_api_payload;
    $reference_orch->_capture_api_payload($sess, $messages_v2, $tools);
    my $sigs_v2 = $real_state->section_signatures;

    is($sigs_v1->{system_prompt}, $sigs_v2->{system_prompt},
        'system_prompt signature is unchanged when dialog grows');
    isnt($sigs_v1->{dialog}, $sigs_v2->{dialog},
        'dialog signature changed when dialog grew');
};

subtest 'section_signatures: user_context change invalidates user_context only' => sub {
    my $real_state = CLIO::Session::State->new(session_id => 'phase5-user-ctx', debug => 0);
    my $sess = StubSession->new(state => $real_state);
    my $tools = $real_tools;

    my $messages_v1 = [
        { role => 'system', content => 'STABLE' },
        { role => 'user',      content => 'q1' },
        { role => 'assistant', content => 'a1' },
        { role => 'system', content => '<userContext>date: 08:00</userContext>' },
        { role => 'user',      content => 'q2' },
    ];

    $reference_orch->_capture_api_payload($sess, $messages_v1, $tools);
    my $sigs_v1 = $real_state->section_signatures;

    # Change user_context date (simulating date tick)
    my $messages_v2 = [
        { role => 'system', content => 'STABLE' },
        { role => 'user',      content => 'q1' },
        { role => 'assistant', content => 'a1' },
        { role => 'system', content => '<userContext>date: 08:01 (CHANGED)</userContext>' },
        { role => 'user',      content => 'q2' },
    ];

    $real_state->clear_last_api_payload;
    $reference_orch->_capture_api_payload($sess, $messages_v2, $tools);
    my $sigs_v2 = $real_state->section_signatures;

    is($sigs_v1->{system_prompt}, $sigs_v2->{system_prompt},
        'system_prompt signature unchanged when only user_context drifts');
    is($sigs_v1->{dialog}, $sigs_v2->{dialog},
        'dialog signature unchanged when only user_context drifts');
    isnt($sigs_v1->{user_context}, $sigs_v2->{user_context},
        'user_context signature changed (the dynamic anchor IS dynamic)');
};

done_testing();
