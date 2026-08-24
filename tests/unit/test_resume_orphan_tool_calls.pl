#!/usr/bin/env perl
# Regression test: resume fast path must not return a payload containing
# orphan tool_calls (assistant's tool_use blocks without matching tool_result
# messages in the next user message).
#
# Symptom observed (2026-08-24): Anthropic API rejects with
#   "tool_use ids were found without tool_result blocks immediately after"
# This happens often on resume because:
#   1. _capture_api_payload snapshots @messages at end-of-turn.
#   2. _try_resume_from_payload reuses the cached snapshot verbatim when
#      it fits the current model's budget.
#   3. Snapshots from earlier sessions can contain an assistant-with-
#      tool_calls whose tool_result was dropped by a prior trim (the trim
#      kept the dialog and dropped the tool_result from the deferred list
#      because budget was exhausted).
#   4. validate_and_truncate does call validate_tool_message_pairs
#      internally (which strips orphans), but only when trim actually
#      fires. When the cached payload fits the budget, the trim block
#      is skipped and the orphans are returned verbatim.
#
# Fix:
#   - _capture_api_payload strips orphans from the snapshot before storing
#     (defense: stored snapshots stay clean across resume cycles).
#   - _try_resume_from_payload runs validate_tool_message_pairs on the
#     returned messages unconditionally (defense: catches orphans from old
#     snapshots saved before the capture fix).

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

mkdir "$tmpdir/sessions" or die "Cannot mkdir sessions: $!";

# Minimal stubs
package StubSession {
    sub new {
        my ($class, %args) = @_;
        return bless { state => $args{state} }, $class;
    }
    sub state { $_[0]->{state} }
}

package StubAPIManager {
    sub new {
        my ($class, %args) = @_;
        return bless { provider => $args{provider}, caps => $args{caps} }, $class;
    }
    sub get_current_provider    { $_[0]->{provider} }
    sub get_current_model       { 'm' }
    sub get_model_capabilities  { $_[0]->{caps} }
}

require CLIO::Core::WorkflowOrchestrator;
require CLIO::Core::Defaults;

# Real orchestrator to get a matching tools signature.
my $orch = CLIO::Core::WorkflowOrchestrator->new(
    debug => 0,
    api_manager => StubAPIManager->new(provider => 'anthropic', caps => { max_context_window_tokens => 200000 }),
);
my $real_tools = $orch->_build_tools_for_api(undef);
my $real_signature = $orch->_tools_signature($real_tools);

# Helper: count orphan tool_calls in a messages array (no matching result).
sub count_orphan_tool_calls {
    my ($msgs) = @_;
    my %tc_ids;
    my %tr_ids;
    for my $msg (@$msgs) {
        if ($msg->{role} eq 'assistant' && $msg->{tool_calls}) {
            for my $tc (@{$msg->{tool_calls}}) {
                $tc_ids{$tc->{id}} = 1 if $tc->{id};
            }
        }
        if (($msg->{role} eq 'tool' || $msg->{tool_call_id}) && $msg->{tool_call_id}) {
            $tr_ids{$msg->{tool_call_id}} = 1;
        }
    }
    my $orphans = 0;
    for my $id (keys %tc_ids) {
        $orphans++ unless $tr_ids{$id};
    }
    return $orphans;
}

# ============================================================================
# Part 1: _strip_orphan_tool_calls unit test
# ============================================================================

subtest '_strip_orphan_tool_calls: removes tool_calls without matching tool_result' => sub {
    my @msgs = (
        { role => 'system', content => 'sys' },
        { role => 'user',   content => 'q' },
        { role => 'assistant', content => 'a', tool_calls => [
            { id => 'orphan_tc', type => 'function', function => { name => 'x', arguments => '{}' } },
        ] },
    );

    my @cleaned = $orch->_strip_orphan_tool_calls(@msgs);
    is(scalar(@cleaned), 3, 'message count preserved');
    is($cleaned[2]{role}, 'assistant', 'assistant message preserved (became plain text)');
    is($cleaned[2]{content}, 'a', 'assistant content preserved');
    ok(!exists $cleaned[2]{tool_calls}, 'orphan tool_calls stripped from assistant');
    is(count_orphan_tool_calls(\@cleaned), 0, 'zero orphans in cleaned messages');
};

subtest '_strip_orphan_tool_calls: keeps matched tool_calls and tool_results' => sub {
    my @msgs = (
        { role => 'system', content => 'sys' },
        { role => 'user',   content => 'q' },
        { role => 'assistant', content => 'a', tool_calls => [
            { id => 'tc_1', type => 'function', function => { name => 'x', arguments => '{}' } },
        ] },
        { role => 'tool', content => 'r1', tool_call_id => 'tc_1' },
    );

    my @cleaned = $orch->_strip_orphan_tool_calls(@msgs);
    is(scalar(@cleaned), 4, 'message count preserved');
    is($cleaned[2]{tool_calls}[0]{id}, 'tc_1', 'matched tool_call preserved');
    is($cleaned[3]{tool_call_id}, 'tc_1', 'matched tool_result preserved');
    is(count_orphan_tool_calls(\@cleaned), 0, 'zero orphans');
};

subtest '_strip_orphan_tool_calls: partial orphan (one matched, one orphan)' => sub {
    my @msgs = (
        { role => 'system', content => 'sys' },
        { role => 'user',   content => 'q' },
        { role => 'assistant', content => 'a', tool_calls => [
            { id => 'tc_matched',   type => 'function', function => { name => 'x', arguments => '{}' } },
            { id => 'tc_orphan',    type => 'function', function => { name => 'x', arguments => '{}' } },
        ] },
        { role => 'tool', content => 'r', tool_call_id => 'tc_matched' },
    );

    my @cleaned = $orch->_strip_orphan_tool_calls(@msgs);
    is(scalar(@cleaned), 4, 'message count preserved');
    is(scalar(@{$cleaned[2]{tool_calls}}), 1, 'one tool_call left (only the matched one)');
    is($cleaned[2]{tool_calls}[0]{id}, 'tc_matched', 'matched tool_call retained');
    is(count_orphan_tool_calls(\@cleaned), 0, 'zero orphans');
};

subtest '_strip_orphan_tool_calls: orphan tool_result dropped (no matching call)' => sub {
    my @msgs = (
        { role => 'system', content => 'sys' },
        { role => 'user',   content => 'q' },
        { role => 'assistant', content => 'a' },
        { role => 'tool', content => 'r', tool_call_id => 'orphan_tr' },
    );

    my @cleaned = $orch->_strip_orphan_tool_calls(@msgs);
    is(scalar(@cleaned), 3, 'orphan tool_result dropped');
    is($cleaned[2]{role}, 'assistant', 'final assistant kept');
    is(count_orphan_tool_calls(\@cleaned), 0, 'zero orphans');
};

# ============================================================================
# Part 2: _try_resume_from_payload strips orphans from returned messages
# ============================================================================

subtest 'resume strips orphan tool_calls from cached payload (regression 2026-08-24)' => sub {
    # Simulate a stale snapshot saved by an older session that contains
    # an assistant-with-tool_calls but NO matching tool_result.
    my $state_h = {
        last_api_payload => [
            { role => 'system', content => 'sys' },
            { role => 'user',   content => 'q' },
            { role => 'assistant', content => 'a', tool_calls => [
                { id => 'orphan_tc', type => 'function', function => { name => 'x', arguments => '{}' } },
            ] },
            # NO tool_result message - this is the regression
            { role => 'assistant', content => 'final response' },
        ],
        last_api_metadata => {
            model => 'm', provider => 'anthropic', context_window => 200000,
            tools_signature => $real_signature, saved_at => time(),
        },
    };
    my $sess = StubSession->new(state => $state_h);

    my ($resumed, $tools) = $orch->_try_resume_from_payload(
        $sess, { max_context_window_tokens => 200000 }
    );
    ok($resumed && @$resumed, 'resume returned messages');

    # The orphan tool_call must be stripped - if it leaks through, Anthropic
    # would reject with the "tool_use ids were found without tool_result
    # blocks immediately after" error.
    is(count_orphan_tool_calls($resumed), 0,
        'resumed payload has ZERO orphan tool_calls (Anthropic would reject any)');

    # Verify the orphan was specifically stripped (not the assistant message itself)
    my @orphans = grep {
        $_->{role} eq 'assistant'
        && $_->{tool_calls}
        && scalar(@{$_->{tool_calls}}) > 0
    } @$resumed;
    is(scalar(@orphans), 0, 'no assistant message in resumed payload carries tool_calls');
};

subtest 'resume strips orphan tool_calls even when payload fits budget (no trim)' => sub {
    # Small payload that fits the budget - the bug only triggers here
    # because validate_and_truncate's internal validate_tool_message_pairs
    # call is skipped when trim doesn't fire.
    my $state_h = {
        last_api_payload => [
            { role => 'system', content => 'sys' },
            { role => 'user',   content => 'q' },
            { role => 'assistant', content => 'a', tool_calls => [
                { id => 'orphan', type => 'function', function => { name => 'x', arguments => '{}' } },
            ] },
        ],
        last_api_metadata => {
            model => 'm', provider => 'anthropic', context_window => 200000,
            tools_signature => $real_signature, saved_at => time(),
        },
    };
    my $sess = StubSession->new(state => $state_h);

    my ($resumed, $tools) = $orch->_try_resume_from_payload(
        $sess, { max_context_window_tokens => 200000, max_output_tokens => 16384 }
    );
    ok($resumed && @$resumed, 'resume returned messages');
    is(count_orphan_tool_calls($resumed), 0,
        'orphan stripped even without trim (the regression scenario)');
};

subtest 'resume preserves matched tool_calls and tool_results' => sub {
    # Sanity check: legitimate tool_calls/tool_results pairs survive.
    my $state_h = {
        last_api_payload => [
            { role => 'system', content => 'sys' },
            { role => 'user',   content => 'q' },
            { role => 'assistant', content => 'a', tool_calls => [
                { id => 'tc_ok', type => 'function', function => { name => 'x', arguments => '{}' } },
            ] },
            { role => 'tool', content => 'r', tool_call_id => 'tc_ok' },
            { role => 'assistant', content => 'final' },
        ],
        last_api_metadata => {
            model => 'm', provider => 'anthropic', context_window => 200000,
            tools_signature => $real_signature, saved_at => time(),
        },
    };
    my $sess = StubSession->new(state => $state_h);

    my ($resumed, $tools) = $orch->_try_resume_from_payload(
        $sess, { max_context_window_tokens => 200000 }
    );
    is(count_orphan_tool_calls($resumed), 0, 'no orphans');
    my $has_matched = grep {
        $_->{role} eq 'assistant' && $_->{tool_calls}
        && scalar(@{$_->{tool_calls}}) == 1
        && $_->{tool_calls}[0]{id} eq 'tc_ok'
    } @$resumed;
    ok($has_matched, 'matched tool_call preserved');
    my $has_result = grep {
        $_->{role} eq 'tool' && ($_->{tool_call_id} // '') eq 'tc_ok'
    } @$resumed;
    ok($has_result, 'matched tool_result preserved');
};

subtest 'resume partial orphan: strips only the orphan, keeps the matched pair' => sub {
    my $state_h = {
        last_api_payload => [
            { role => 'system', content => 'sys' },
            { role => 'user',   content => 'q' },
            { role => 'assistant', content => 'a', tool_calls => [
                { id => 'tc_matched', type => 'function', function => { name => 'x', arguments => '{}' } },
                { id => 'tc_orphan',  type => 'function', function => { name => 'x', arguments => '{}' } },
            ] },
            { role => 'tool', content => 'r', tool_call_id => 'tc_matched' },
        ],
        last_api_metadata => {
            model => 'm', provider => 'anthropic', context_window => 200000,
            tools_signature => $real_signature, saved_at => time(),
        },
    };
    my $sess = StubSession->new(state => $state_h);

    my ($resumed, $tools) = $orch->_try_resume_from_payload(
        $sess, { max_context_window_tokens => 200000 }
    );
    is(count_orphan_tool_calls($resumed), 0, 'zero orphans in resumed payload');

    my $asst = (grep { $_->{role} eq 'assistant' && $_->{tool_calls} } @$resumed)[0];
    ok($asst, 'assistant message with tool_calls preserved (matched pair)');
    is(scalar(@{$asst->{tool_calls}}), 1, 'only the matched tool_call kept');
    is($asst->{tool_calls}[0]{id}, 'tc_matched', 'matched tool_call ID correct');

    my $has_result = grep {
        $_->{role} eq 'tool' && ($_->{tool_call_id} // '') eq 'tc_matched'
    } @$resumed;
    ok($has_result, 'matched tool_result preserved');
};

# ============================================================================
# Part 3: _capture_api_payload sanitizes snapshots at capture time
# ============================================================================

subtest '_capture_api_payload strips orphans before storing (snapshot self-sanitizes)' => sub {
    my $state = CLIO::Session::State->new(session_id => 'capture-sanitize', debug => 0);
    my $sess = StubSession->new(state => $state);

    # Feed a messages array with an orphan tool_call. The snapshot
    # should strip it before saving so future resumes never see it.
    my $messages = [
        { role => 'system', content => 'sys' },
        { role => 'user',   content => 'q' },
        { role => 'assistant', content => 'a', tool_calls => [
            { id => 'orphan_tc', type => 'function', function => { name => 'x', arguments => '{}' } },
        ] },
        # No tool_result for orphan_tc
    ];

    $orch->_capture_api_payload($sess, $messages, $real_tools);

    my $stored = $state->last_api_payload;
    ok($stored && @$stored, 'payload stored');
    is(count_orphan_tool_calls($stored), 0,
        'stored snapshot has zero orphans (sanitized at capture)');

    # Verify the orphan was stripped (not the assistant message)
    my $asst = (grep { $_->{role} eq 'assistant' } @$stored)[0];
    ok($asst, 'assistant message preserved');
    ok(!$asst->{tool_calls} || scalar(@{$asst->{tool_calls}}) == 0,
        'orphan tool_calls stripped from stored assistant message');
    is($asst->{content}, 'a', 'assistant content preserved');
};

subtest '_capture_api_payload with mixed matched/orphan only strips orphan' => sub {
    my $state = CLIO::Session::State->new(session_id => 'capture-mixed', debug => 0);
    my $sess = StubSession->new(state => $state);

    my $messages = [
        { role => 'system', content => 'sys' },
        { role => 'user',   content => 'q' },
        { role => 'assistant', content => 'a', tool_calls => [
            { id => 'tc_ok',     type => 'function', function => { name => 'x', arguments => '{}' } },
            { id => 'tc_orphan', type => 'function', function => { name => 'x', arguments => '{}' } },
        ] },
        { role => 'tool', content => 'r', tool_call_id => 'tc_ok' },
    ];

    $orch->_capture_api_payload($sess, $messages, $real_tools);

    my $stored = $state->last_api_payload;
    is(count_orphan_tool_calls($stored), 0, 'snapshot has no orphans');
    my $asst = (grep { $_->{role} eq 'assistant' && $_->{tool_calls} } @$stored)[0];
    ok($asst, 'assistant with tool_calls preserved');
    is(scalar(@{$asst->{tool_calls}}), 1, 'only matched tool_call kept');
    is($asst->{tool_calls}[0]{id}, 'tc_ok', 'correct tool_call retained');
};

# ============================================================================
# Part 4: End-to-end - old session JSON with orphan -> resume returns clean
# ============================================================================

subtest 'old session JSON with orphan tool_calls is sanitized by resume (end-to-end)' => sub {
    # Simulate a session file saved by an older CLIO version that didn't
    # sanitize the snapshot at capture time. The file contains an orphan
    # tool_call. After session load + resume, the returned messages MUST
    # have zero orphans.
    my $sid = 'legacy-orphan-snapshot';
    mkdir "$tmpdir/sessions";
    my $payload = [
        { role => 'system', content => 'sys' },
        { role => 'user',   content => 'q' },
        { role => 'assistant', content => 'a', tool_calls => [
            { id => 'stale_orphan', type => 'function', function => { name => 'x', arguments => '{}' } },
        ] },
    ];
    my $old_json = CLIO::Util::JSON::encode_json({
        history  => [],
        stm      => [],
        yarn     => {},
        billing  => { total_tokens => 0, total_requests => 0, requests => [], total_prompt_tokens => 0, total_completion_tokens => 0, total_premium_requests => 0, model => undef, multiplier => 0 },
        max_tokens => 128000,
        created_at => time(),
        last_api_payload => $payload,
        last_api_metadata => {
            model => 'm', provider => 'anthropic', context_window => 200000,
            tools_signature => $real_signature, saved_at => time(),
        },
    });
    open my $fh, '>', "$tmpdir/sessions/$sid.json" or die "Cannot write legacy: $!";
    print $fh $old_json;
    close $fh;

    # Reload the session through CLIO::Session::State (real path)
    my $reloaded = CLIO::Session::State->load($sid, debug => 0);
    ok(defined $reloaded, 'legacy session loaded');

    # Confirm the payload has the orphan (the bug scenario)
    my $raw_payload = $reloaded->last_api_payload;
    is(count_orphan_tool_calls($raw_payload), 1,
        'sanity: legacy payload has 1 orphan tool_call (the bug scenario)');

    # Run the resume fast path on this legacy payload
    my $sess = StubSession->new(state => $reloaded);
    my ($resumed, $tools) = $orch->_try_resume_from_payload(
        $sess, { max_context_window_tokens => 200000 }
    );
    ok($resumed && @$resumed, 'resume returned messages');
    is(count_orphan_tool_calls($resumed), 0,
        'resumed messages have zero orphans (legacy snapshot sanitized)');
};

done_testing();