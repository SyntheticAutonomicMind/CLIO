#!/usr/bin/env perl
# Regression test: resume fast path + proactive trim must not return a deinterleaved
# message array (tool_results parked at the END separated from their tool_calls).
#
# Symptom observed (2026-08-24): Anthropic API rejects with
#   "tool_use ids were found without tool_result blocks immediately after"
# when the assistant message carries a tool_use block whose matching
# tool_result was not in the immediately following user message.
#
# Root cause: the cache-stable internal layout deinterleaves tool_results to
# the END of the message array (Prompt Pipeline Protocol, section [4]).
# This layout is ideal for trimming and LCP cache stability but NO provider
# accepts it on the wire — every provider requires a tool_result to be the
# message immediately following the assistant that contains the matching
# tool_call.  The previous fix (strip orphan tool_calls) only removed
# MISSING pairs; it did not reorder EXISTING-but-deinterleaved ones.
#
# Fix: reinterleave_tool_results() restores in-order adjacency by walking
# non-tool messages and inserting each tool_result right after its tool_call.
# It is called from enforce_message_alternation (every API call) and from
# _capture_api_payload / _try_resume_from_payload (snapshot hygiene).

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";

use Test::More;
use CLIO::Session::State;
use CLIO::Providers::Anthropic;
use CLIO::Core::ConversationManager qw(reinterleave_tool_results enforce_message_alternation);
use CLIO::Memory::TokenEstimator qw(estimate_tokens);
use CLIO::Util::JSON qw(encode_json);
use File::Temp qw(tempdir);

#---------------------------------------------------------------------------
# Helpers
#---------------------------------------------------------------------------

# Count how many tool_result messages are NOT in the contiguous block
# immediately following their tool_calling assistant message.  Returns
# the count of "misplaced" results.
sub count_misplaced_tool_results {
    my ($msgs) = @_;
    my $misplaced = 0;
    for my $i (0 .. $#{$msgs}) {
        my $m = $msgs->[$i];
        if (($m->{role} // '') eq 'assistant' && $m->{tool_calls} && ref($m->{tool_calls}) eq 'ARRAY') {
            my @tc_ids = grep { defined } map { $_->{id} } @{$m->{tool_calls}};
            next unless @tc_ids;
            # Collect tool messages in the contiguous block starting at i+1
            my %seen_results;
            my $j = $i + 1;
            while ($j <= $#{$msgs} && ($msgs->[$j]{role} // '') eq 'tool') {
                my $tid = $msgs->[$j]{tool_call_id} // '';
                $seen_results{$tid} = 1;
                $j++;
            }
            # Each tool_call id without a matching adjacent tool result is misplaced
            for my $tid (@tc_ids) {
                $misplaced++ unless $seen_results{$tid};
            }
        }
    }
    return $misplaced;
}

# Run the Anthropic convert_messages adjacency check: every tool_use block
# must have its tool_result in the immediately following message.
sub anthropic_adjacency_errors {
    my ($msgs) = @_;
    my $anthropic = CLIO::Providers::Anthropic->new(debug => 0);
    my $converted = $anthropic->convert_messages($msgs);
    my @errors;
    for my $i (0 .. $#{$converted} - 1) {
        my $m = $converted->[$i];
        next unless $m->{role} eq 'assistant' && $m->{content} && ref($m->{content}) eq 'ARRAY';
        my @tc_ids = map { $_->{id} } grep { $_->{type} eq 'tool_use' } @{$m->{content}};
        next unless @tc_ids;
        my $next = $converted->[$i + 1];
        my @tr_ids;
        if ($next->{content} && ref($next->{content}) eq 'ARRAY') {
            @tr_ids = map { $_->{tool_use_id} } grep { $_->{type} eq 'tool_result' } @{$next->{content}};
        }
        for my $tc_id (@tc_ids) {
            my $found = grep { $_ eq $tc_id } @tr_ids;
            push @errors, "tool_use[$tc_id] not adjacent to its tool_result" unless $found;
        }
    }
    return @errors;
}

#---------------------------------------------------------------------------
# Part 1: reinterleave_tool_results unit tests
#---------------------------------------------------------------------------

subtest 'reinterleave: deinterleaved -> interleaved' => sub {
    # Simulate a deinterleaved snapshot: tool_results parked at the END,
    # separated from their assistant tool_calls by other dialog.
    my $msgs = [
        { role => 'system',    content => 'sys' },
        { role => 'user',      content => 'q1' },
        { role => 'assistant', content => 'a1', tool_calls => [
            { id => 'call_1', type => 'function', function => { name => 'x', arguments => '{}' } },
        ] },
        { role => 'user',      content => 'q2' },
        { role => 'assistant', content => 'a2', tool_calls => [
            { id => 'call_2', type => 'function', function => { name => 'x', arguments => '{}' } },
        ] },
        # deinterleaved tool_results at END:
        { role => 'tool', content => 'r1', tool_call_id => 'call_1' },
        { role => 'tool', content => 'r2', tool_call_id => 'call_2' },
    ];

    my $result = reinterleave_tool_results($msgs);

    is(scalar(@$result), 7, 'message count unchanged');
    # Verify: each tool_result is immediately after its tool_calling assistant
    is(count_misplaced_tool_results($result), 0, 'all tool_results adjacent to their tool_calls');
    
    # Check the order: assistant(call_1) -> tool(call_1) -> user(q2) -> assistant(call_2) -> tool(call_2)
    is($result->[2]{role}, 'assistant', 'assistant with call_1 at index 2');
    is(scalar(@{$result->[2]{tool_calls}}), 1, 'call_1 has 1 tool_call');
    is($result->[2]{tool_calls}[0]{id}, 'call_1', 'tool_call id is call_1');
    is($result->[3]{role}, 'tool', 'tool_result for call_1 at index 3 (adjacent)');
    is($result->[3]{tool_call_id}, 'call_1', 'tool_result id is call_1');
    is($result->[4]{role}, 'user', 'user q2 at index 4');
    is($result->[5]{role}, 'assistant', 'assistant with call_2 at index 5');
    is($result->[6]{role}, 'tool', 'tool_result for call_2 at index 6 (adjacent)');
    is($result->[6]{tool_call_id}, 'call_2', 'tool_result id is call_2');
};

subtest 'reinterleave: already-interleaved is a no-op' => sub {
    my $msgs = [
        { role => 'system',    content => 'sys' },
        { role => 'user',      content => 'q1' },
        { role => 'assistant', content => 'a1', tool_calls => [
            { id => 'call_1', type => 'function', function => { name => 'x', arguments => '{}' } },
        ] },
        { role => 'tool',      content => 'r1', tool_call_id => 'call_1' },
        { role => 'user',      content => 'q2' },
        { role => 'assistant', content => 'a2', tool_calls => [
            { id => 'call_2', type => 'function', function => { name => 'x', arguments => '{}' } },
        ] },
        { role => 'tool',      content => 'r2', tool_call_id => 'call_2' },
    ];

    my $result = reinterleave_tool_results($msgs);

    is(scalar(@$result), scalar(@$msgs), 'message count unchanged');
    is(count_misplaced_tool_results($result), 0, 'all adjacent (already correct)');
    # Verify order preserved
    for my $i (0 .. $#{$msgs}) {
        is($result->[$i]{role}, $msgs->[$i]{role}, "role preserved at index $i");
        is(($result->[$i]{tool_call_id} // ''), ($msgs->[$i]{tool_call_id} // ''),
            "tool_call_id preserved at index $i");
    }
};

subtest 'reinterleave: no tool messages is a no-op' => sub {
    my $msgs = [
        { role => 'system', content => 'sys' },
        { role => 'user',   content => 'q1' },
        { role => 'assistant', content => 'a1' },
        { role => 'user',   content => 'q2' },
    ];
    my $result = reinterleave_tool_results($msgs);
    is(scalar(@$result), scalar(@$msgs), 'message count unchanged (no tool msgs)');
    is($result->[0]{content}, 'sys', 'content unchanged');
};

subtest 'reinterleave: multiple tool_calls in one assistant' => sub {
    my $msgs = [
        { role => 'system',    content => 'sys' },
        { role => 'user',      content => 'q' },
        { role => 'assistant', content => 'a', tool_calls => [
            { id => 'call_a', type => 'function', function => { name => 'x', arguments => '{}' } },
            { id => 'call_b', type => 'function', function => { name => 'y', arguments => '{}' } },
        ] },
        # deinterleaved results at END (call_b result before call_a result):
        { role => 'tool', content => 'result_b', tool_call_id => 'call_b' },
        { role => 'tool', content => 'result_a', tool_call_id => 'call_a' },
    ];

    my $result = reinterleave_tool_results($msgs);

    is(scalar(@$result), 5, 'message count unchanged');
    is(count_misplaced_tool_results($result), 0, 'all adjacent');
    # Results should be in tool_call order (call_a first, call_b second)
    is($result->[3]{role}, 'tool', 'first tool_result at index 3');
    is($result->[3]{tool_call_id}, 'call_a', 'call_a result first (tool_call order)');
    is($result->[4]{role}, 'tool', 'second tool_result at index 4');
    is($result->[4]{tool_call_id}, 'call_b', 'call_b result second');
};

subtest 'reinterleave: orphan tool_result (no matching call) appended at end' => sub {
    my $msgs = [
        { role => 'system', content => 'sys' },
        { role => 'user', content => 'q' },
        { role => 'tool', content => 'orphan_result', tool_call_id => 'no_matching_call' },
    ];
    my $result = reinterleave_tool_results($msgs);
    is(scalar(@$result), 3, 'orphan result not dropped (appended at end)');
    is($result->[2]{tool_call_id}, 'no_matching_call', 'orphan preserved at end');
};

subtest 'reinterleave: preserves arrayref/multimodal content' => sub {
    my $msgs = [
        { role => 'system', content => 'sys' },
        { role => 'user', content => [
            { type => 'text', text => 'q' },
            { type => 'image_url', image_url => { url => 'data:...' } },
        ] },
        { role => 'assistant', content => 'a', tool_calls => [
            { id => 'call_1', type => 'function', function => { name => 'x', arguments => '{}' } },
        ] },
        { role => 'tool', content => 'r1', tool_call_id => 'call_1' },
    ];
    my $result = reinterleave_tool_results($msgs);
    is(scalar(@$result), 4, 'count unchanged');
    is(count_misplaced_tool_results($result), 0, 'adjacent');
    # The already-interleaved input should be a no-op
    is($result->[3]{tool_call_id}, 'call_1', 'tool_result preserved');
};

#---------------------------------------------------------------------------
# Part 2: enforce_message_alternation re-interleaves before merging
#---------------------------------------------------------------------------

subtest 'enforce_message_alternation: deinterleaved -> Anthropic-safe' => sub {
    my $msgs = [
        { role => 'system',    content => 'sys' },
        { role => 'user',      content => 'q1' },
        { role => 'assistant', content => 'a1', tool_calls => [
            { id => 'call_1', type => 'function', function => { name => 'x', arguments => '{}' } },
        ] },
        { role => 'user',      content => 'q2' },
        { role => 'assistant', content => 'a2', tool_calls => [
            { id => 'call_2', type => 'function', function => { name => 'x', arguments => '{}' } },
        ] },
        # deinterleaved results at END:
        { role => 'tool', content => 'r1', tool_call_id => 'call_1' },
        { role => 'tool', content => 'r2', tool_call_id => 'call_2' },
    ];

    my $result = enforce_message_alternation($msgs, 'anthropic', debug => 0);
    is(count_misplaced_tool_results($result), 0,
        'after alternation: all tool_results adjacent to their tool_calls');
    
    # And Anthropic convert_messages should produce zero adjacency errors
    my @errors = anthropic_adjacency_errors($result);
    is(scalar(@errors), 0, 'Anthropic convert_messages: zero adjacency errors');
};

subtest 'enforce_message_alternation: already-interleaved stays correct' => sub {
    my $msgs = [
        { role => 'system', content => 'sys' },
        { role => 'user', content => 'q1', },
        { role => 'assistant', content => 'a1', tool_calls => [
            { id => 'call_1', type => 'function', function => { name => 'x', arguments => '{}' } },
        ] },
        { role => 'tool', content => 'r1', tool_call_id => 'call_1' },
        { role => 'user', content => 'q2' },
        { role => 'assistant', content => 'a2', tool_calls => [
            { id => 'call_2', type => 'function', function => { name => 'x', arguments => '{}' } },
        ] },
        { role => 'tool', content => 'r2', tool_call_id => 'call_2' },
    ];
    my $result = enforce_message_alternation($msgs, 'github_copilot', debug => 0);
    is(count_misplaced_tool_results($result), 0, 'already-interleaved stays correct');
    my @errors = anthropic_adjacency_errors($result);
    is(scalar(@errors), 0, 'zero Anthropic adjacency errors');
};

#---------------------------------------------------------------------------
# Part 3: Anthropic convert_messages directly tests the adjacency fix
#---------------------------------------------------------------------------

subtest 'Anthropic convert_messages: deinterleaved input produces adjacency errors' => sub {
    # This documents the bug: WITHOUT reinterleave, Anthropic's convert_messages
    # produces messages where tool_use is NOT immediately followed by its tool_result.
    # The input has TWO assistants with tool_calls, and the tool_results are all
    # at the END (deinterleaved), separated from BOTH tool_calls by other dialog.
    my $msgs = [
        { role => 'user', content => 'q1' },
        { role => 'assistant', content => 'a1', tool_calls => [
            { id => 'call_1', type => 'function', function => { name => 'x', arguments => '{}' } },
        ] },
        { role => 'user', content => 'q2' },
        { role => 'assistant', content => 'a2', tool_calls => [
            { id => 'call_2', type => 'function', function => { name => 'x', arguments => '{}' } },
        ] },
        # DEINTERLEAVED: both tool_results at the END, after all dialog
        { role => 'tool', content => 'r1', tool_call_id => 'call_1' },
        { role => 'tool', content => 'r2', tool_call_id => 'call_2' },
    ];
    my @errors = anthropic_adjacency_errors($msgs);
    # WITHOUT reinterleave: call_1's tool_result is at the end, not immediately
    # after the assistant that tool_use[d call_1.  call_2's tool_result is also
    # at the end but happens to be in the message immediately after call_2's
    # assistant (because both tool_results get merged into one user message).
    # So we expect exactly 1 adjacency error (call_1).
    is(scalar(@errors), 1, 'un-reinterleaved deinterleaved input has 1 adjacency error (documents the bug)');
    like($errors[0], qr/tool_use\[call_1\]/, 'error mentions the right tool_use id');
};

subtest 'Anthropic convert_messages: re-interleaved input has zero errors' => sub {
    my $msgs = [
        { role => 'user', content => 'q1' },
        { role => 'assistant', content => 'a1', tool_calls => [
            { id => 'call_1', type => 'function', function => { name => 'x', arguments => '{}' } },
        ] },
        { role => 'user', content => 'q2' },
        { role => 'tool', content => 'r1', tool_call_id => 'call_1' },
    ];
    my $interleaved = reinterleave_tool_results($msgs);
    my @errors = anthropic_adjacency_errors($interleaved);
    is(scalar(@errors), 0, 're-interleaved input: zero Anthropic adjacency errors');
};

#---------------------------------------------------------------------------
# Part 4: End-to-end resume with deinterleaved snapshot (regression scenario)
#---------------------------------------------------------------------------

# Minimal stubs for orchestrator-based tests
package StubSession4 {
    sub new { my ($class, %args) = @_; bless { state => $args{state} }, $class; }
    sub state { $_[0]->{state} }
}
package StubAPIManager4 {
    sub new { my ($class, %args) = @_; bless { provider => $args{provider}, caps => $args{caps} }, $class; }
    sub get_current_provider    { $_[0]->{provider} }
    sub get_current_model       { 'm' }
    sub get_model_capabilities  { $_[0]->{caps} }
}

# Re-import in the test package
package main;

use CLIO::Core::WorkflowOrchestrator;
use CLIO::Core::Defaults;

my $tmpdir2 = tempdir(CLEANUP => 1);
*CLIO::Util::PathResolver::get_sessions_dir = sub { return "$tmpdir2/sessions" };
*CLIO::Util::PathResolver::get_session_file = sub {
    my ($id) = @_;
    return "$tmpdir2/sessions/$id.json";
};
mkdir "$tmpdir2/sessions" or die "Cannot mkdir sessions: $!";

# Build a real tools signature for the stubs
my $orch = CLIO::Core::WorkflowOrchestrator->new(
    debug => 0,
    api_manager => StubAPIManager4->new(
        provider => 'anthropic',
        caps     => { max_context_window_tokens => 200000, max_output_tokens => 16384 },
    ),
);
my $real_tools = $orch->_build_tools_for_api(undef);
my $real_signature = $orch->_tools_signature($real_tools);

subtest '_try_resume_from_payload: deinterleaved snapshot -> re-interleaved output' => sub {
    # This is the EXACT regression scenario: a snapshot saved with the
    # cache-stable deinterleaved layout (tool_results at END).
    my $state_h = {
        last_api_payload => [
            { role => 'system', content => 'You are a coding assistant.' },
            { role => 'user',   content => 'Read lib/foo.pm' },
            { role => 'assistant', content => 'I will read it.', tool_calls => [
                { id => 'call_1', type => 'function', function => { name => 'file_operations', arguments => '{}' } },
            ] },
            { role => 'user',   content => 'What did you find?' },
            { role => 'assistant', content => 'Based on the file...', tool_calls => [
                { id => 'call_2', type => 'function', function => { name => 'file_operations', arguments => '{}' } },
            ] },
            # DEINTERLEAVED tool_results at end (the bug):
            { role => 'tool', content => 'file contents here', tool_call_id => 'call_1' },
            { role => 'tool', content => 'more file contents', tool_call_id => 'call_2' },
        ],
        last_api_metadata => {
            model => 'm', provider => 'anthropic', context_window => 200000,
            tools_signature => $real_signature, saved_at => time(),
        },
    };
    my $sess = StubSession4->new(state => $state_h);

    my ($resumed, $tools) = $orch->_try_resume_from_payload(
        $sess, { max_context_window_tokens => 200000 }
    );
    ok($resumed && @$resumed, 'resume returned messages');
    
    # The KEY assertion: after resume, every tool_result must be immediately
    # after its tool_calling assistant message.  Without the fix, the
    # deinterleaved tool_results stay at the end and Anthropic rejects.
    is(count_misplaced_tool_results($resumed), 0,
        'resumed payload: all tool_results adjacent to their tool_calls');
    
    # And the Anthropic adjacency check must pass
    my @errors = anthropic_adjacency_errors($resumed);
    is(scalar(@errors), 0,
        'resumed payload: zero Anthropic adjacency errors (would not be rejected)');
};

subtest '_try_resume_from_payload: already-interleaved snapshot stays correct' => sub {
    my $state_h = {
        last_api_payload => [
            { role => 'system', content => 'sys' },
            { role => 'user',   content => 'q1' },
            { role => 'assistant', content => 'a1', tool_calls => [
                { id => 'call_1', type => 'function', function => { name => 'x', arguments => '{}' } },
            ] },
            { role => 'tool', content => 'r1', tool_call_id => 'call_1' },
            { role => 'user',   content => 'q2' },
            { role => 'assistant', content => 'a2', tool_calls => [
                { id => 'call_2', type => 'function', function => { name => 'x', arguments => '{}' } },
            ] },
            { role => 'tool', content => 'r2', tool_call_id => 'call_2' },
        ],
        last_api_metadata => {
            model => 'm', provider => 'anthropic', context_window => 200000,
            tools_signature => $real_signature, saved_at => time(),
        },
    };
    my $sess = StubSession4->new(state => $state_h);
    my ($resumed, $tools) = $orch->_try_resume_from_payload(
        $sess, { max_context_window_tokens => 200000 }
    );
    ok($resumed && @$resumed, 'resume returned messages');
    is(count_misplaced_tool_results($resumed), 0, 'already-interleaved stays correct');
    my @errors = anthropic_adjacency_errors($resumed);
    is(scalar(@errors), 0, 'zero Anthropic adjacency errors');
};

subtest '_try_resume_from_payload: snapshot captured AFTER fix is interleaved' => sub {
    # Verify _capture_api_payload stores an interleaved snapshot even
    # when the input @messages was deinterleaved (from a prior trim).
    my $state = CLIO::Session::State->new(session_id => 'capture-reinterleave', debug => 0);
    my $sess = StubSession4->new(state => $state);

    # Simulate @messages as they would look AFTER a proactive trim deinterleave:
    # tool_results at the END, separated from their tool_calls.
    my $messages = [
        { role => 'system', content => 'sys' },
        { role => 'user',   content => 'q1' },
        { role => 'assistant', content => 'a1', tool_calls => [
            { id => 'call_1', type => 'function', function => { name => 'x', arguments => '{}' } },
        ] },
        { role => 'user',   content => 'q2' },
        { role => 'assistant', content => 'a2', tool_calls => [
            { id => 'call_2', type => 'function', function => { name => 'x', arguments => '{}' } },
        ] },
        { role => 'tool', content => 'r1', tool_call_id => 'call_1' },
        { role => 'tool', content => 'r2', tool_call_id => 'call_2' },
    ];

    $orch->_capture_api_payload($sess, $messages, $real_tools);

    my $stored = $state->last_api_payload;
    ok($stored && @$stored, 'snapshot stored');
    is(count_misplaced_tool_results($stored), 0,
        'stored snapshot has all tool_results adjacent (captured interleaved)');
};

done_testing();
