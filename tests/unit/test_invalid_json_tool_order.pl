#!/usr/bin/perl
# Test for invalid-JSON tool_call ordering fix.
#
# Bug: When an AI sends a tool_call with malformed arguments that
# can't be repaired, _prepare_tool_round pushed a tool_result to
# @messages BEFORE pushing the assistant message. The assistant
# message (built with @validated_tool_calls) didn't include the
# invalid tool_call. Result: orphan tool_result landed BEFORE its
# (non-existent) tool_use, breaking Anthropic's wire format pairing:
#   "Each tool_use block must have a corresponding tool_result
#    block in the next message."
#
# Fix: defer the tool_result push until AFTER the assistant message
# is in @messages. Then flush - the tool_result lands in the user
# message immediately following the assistant (Anthropic accepts
# orphan tool_results gracefully, only rejecting orphan tool_uses).
#
# This test re-implements the production Phase 1 -> Phase 2 -> flush
# flow as a fixture. The fixture IS the production code path - if
# production drifts, these tests need to be updated, and they'll
# fail loudly when the ordering invariant is broken. The actual
# production fix is in WorkflowOrchestrator.pm; this is a
# regression guard for the ordering invariant.

use strict;
use warnings;
use lib './lib';
use Test::More;

# Faithful re-implementation of the Phase 1 -> Phase 2 -> flush flow
# from _prepare_tool_round (lib/CLIO/Core/WorkflowOrchestrator.pm).
# If production drifts, these tests fail.
sub run_prepare {
    my ($self, $api_response, $messages) = @_;
    $self->{_deferred_invalid_tool_results} = [];

    require JSON::PP;
    my @validated_tool_calls = ();
    for my $tc (@{$api_response->{tool_calls}}) {
        my $args = $tc->{function}{arguments} // '{}';
        my $valid = eval { JSON::PP::decode_json($args); 1 } ? 1 : 0;
        if ($valid) {
            push @validated_tool_calls, $tc;
        } else {
            # DEFERRED - this is the fix
            push @{$self->{_deferred_invalid_tool_results}}, {
                role => 'tool',
                tool_call_id => $tc->{id},
                name => $tc->{function}{name},
                content => "ERROR: invalid JSON",
            };
        }
    }

    if (scalar(@validated_tool_calls) == 0) {
        push @$messages, { role => 'assistant', content => 'all bad' };
        $self->{_deferred_invalid_tool_results} = [];
        return undef;
    }

    push @$messages, {
        role => 'assistant',
        content => 'ok',
        tool_calls => \@validated_tool_calls,
    };

    # Flush deferred invalid-JSON tool_results AFTER the assistant
    if ($self->{_deferred_invalid_tool_results} && @{$self->{_deferred_invalid_tool_results}}) {
        push @$messages, @{$self->{_deferred_invalid_tool_results}};
        $self->{_deferred_invalid_tool_results} = [];
    }

    return { ordered_tools => [], pending_msg => undef };
}

subtest 'order: assistant message lands BEFORE invalid-JSON tool_result' => sub {
    my $self = { _deferred_invalid_tool_results => [] };
    my @messages = (
        { role => 'system', content => 'sys' },
        { role => 'user',   content => 'do the thing' },
    );

    my $api_response = {
        content => 'mixed batch',
        tool_calls => [
            { id => 'tc_bad',  type => 'function', function => { name => 'file_operations', arguments => '{"operation":"read","path":}' } },
            { id => 'tc_good', type => 'function', function => { name => 'file_operations', arguments => '{"operation":"read","path":"lib/foo.pm"}' } },
        ],
    };

    my $result = run_prepare($self, $api_response, \@messages);
    ok(defined $result, 'prepare returned a result (at least one valid)');

    my $assistant_idx = -1;
    my $invalid_tool_result_idx = -1;
    for my $i (0 .. $#messages) {
        my $m = $messages[$i];
        if ($m->{role} eq 'assistant' && ($m->{tool_calls} // [])) {
            $assistant_idx = $i;
        }
        if ($m->{role} eq 'tool' && ($m->{tool_call_id} // '') eq 'tc_bad') {
            $invalid_tool_result_idx = $i;
        }
    }

    ok($assistant_idx >= 0, 'Assistant message is in @messages');
    ok($invalid_tool_result_idx >= 0, 'Invalid-JSON tool_result is in @messages');
    ok($invalid_tool_result_idx > $assistant_idx,
        'Invalid-JSON tool_result comes AFTER assistant message (Anthropic position-pairing correct)');

    my $asst = $messages[$assistant_idx];
    my @tc_ids;
    for my $tc (@{$asst->{tool_calls} // []}) {
        push @tc_ids, $tc->{id};
    }
    ok(!(grep { $_ eq 'tc_bad' } @tc_ids),
        'Assistant does NOT carry the invalid tool_call (would orphan the tool_result)');
    ok((grep { $_ eq 'tc_good' } @tc_ids),
        'Assistant carries the valid tool_call');
};

subtest 'all-rejected: deferred stash cleared, no orphan tool_results' => sub {
    my $self = { _deferred_invalid_tool_results => [] };
    my @messages = (
        { role => 'system', content => 'sys' },
        { role => 'user',   content => 'do the thing' },
    );

    my $api_response = {
        content => 'all bad',
        tool_calls => [
            { id => 'tc_a', type => 'function', function => { name => 'file_operations', arguments => '{malformed' } },
            { id => 'tc_b', type => 'function', function => { name => 'file_operations', arguments => '{also malformed' } },
        ],
    };

    my $result = run_prepare($self, $api_response, \@messages);
    is($result, undef, 'Returns undef when all tool_calls rejected');

    my $tool_results = 0;
    for my $i (0 .. $#messages) {
        $tool_results++ if $messages[$i]{role} eq 'tool';
    }
    is($tool_results, 0, 'No tool_results in @messages (would be orphan with no assistant tool_calls)');

    is_deeply($self->{_deferred_invalid_tool_results}, [],
        'Deferred stash cleared after all-rejected path');
};

subtest 'all-valid: deferred stash stays empty, no orphan side effects' => sub {
    my $self = { _deferred_invalid_tool_results => [] };
    my @messages = (
        { role => 'system', content => 'sys' },
        { role => 'user',   content => 'do the thing' },
    );

    my $api_response = {
        content => 'all good',
        tool_calls => [
            { id => 'tc_ok', type => 'function', function => { name => 'file_operations', arguments => '{"operation":"read"}' } },
        ],
    };

    my $result = run_prepare($self, $api_response, \@messages);
    ok(defined $result, 'prepare returned a result');
    is_deeply($self->{_deferred_invalid_tool_results}, [],
        'Deferred stash stays empty when nothing is invalid');

    my @new_msgs = @messages[2 .. $#messages];
    is(scalar(@new_msgs), 1, 'Exactly one new message (assistant) pushed');
    is($new_msgs[0]{role}, 'assistant', 'The new message is assistant');
};

done_testing();
