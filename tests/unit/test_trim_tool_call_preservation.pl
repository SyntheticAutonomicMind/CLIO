#!/usr/bin/env perl
# Test: Tool call/result batch preservation in trim paths
#
# Verifies that _role_based_tail_walk and validate_and_truncate
# preserve tool_call/tool_result pairs as atomic units. When a
# tool_result can't fit in the budget alongside its assistant (or
# another tool_result from the same batch), the ENTIRE batch is
# dropped — preventing orphaned tool_calls that cause the model to
# re-issue the same calls on resume (model looping bug).
use strict;
use warnings;
use utf8;
use lib '../../lib';
use Test2::V0;

use CLIO::Core::API::MessageValidator qw(validate_and_truncate);

# ── Helper: build a messages array with a tool-call batch ──────────────
# Returns an arrayref of messages suitable for validate_and_truncate.
# The batch pattern is:
#   user -> assistant(tool_calls A, B, C) -> tool(result_A) -> tool(result_B) -> tool(result_C)
sub make_tool_batch {
    my ($user_text, $num_calls, $result_text) = @_;
    $num_calls //= 3;
    $result_text //= 'result';

    my @messages = (
        { role => 'system', content => 'You are a helpful assistant.' },
        { role => 'user', content => $user_text },
    );

    # Assistant message with N tool_calls
    my @tool_calls;
    for my $i (0 .. $num_calls - 1) {
        push @tool_calls, {
            id => "call_$i",
            type => 'function',
            function => {
                name => 'test_tool',
                arguments => '{"arg": "' . $i . '"}',
            },
        };
    }
    push @messages, {
        role => 'assistant',
        content => 'I will call the tool.',
        tool_calls => \@tool_calls,
    };

    # N tool result messages
    for my $i (0 .. $num_calls - 1) {
        push @messages, {
            role => 'tool',
            content => "$result_text $i",
            tool_call_id => "call_$i",
            name => 'test_tool',
        };
    }

    # Final assistant text
    push @messages, {
        role => 'assistant',
        content => 'All done.',
    };

    return \@messages;
}

# ── Test 1: Complete tool batch survives under tight budget ────────────
# With a tight budget, if the assistant + first tool_result fit but
# a later tool_result doesn't, the ENTIRE batch should be dropped
# (not partially kept). We use a very large system prompt and small
# cap to force the walk to hit the budget right at the batch boundary.
{
    my @messages = (
        { role => 'system', content => 'You are a helpful assistant.' },
        { role => 'user', content => 'do something with tools' },
    );

    # Add a tool batch with 3 calls
    my $batch = make_tool_batch('do something', 3, 'data');
    # Skip the system/user from batch (already have our own)
    push @messages, @$batch[2 .. $#$batch];

    my $caps = {
        max_context_window_tokens => 500,
        max_output_tokens         => 100,
        max_prompt_tokens         => 500,
    };
    my $tools = [];

    my $trimmed = validate_and_truncate(
        messages           => \@messages,
        model_capabilities => $caps,
        tools              => $tools,
        token_ratio        => 2.5,
    );

    ok(ref($trimmed) eq 'ARRAY' && @$trimmed, 'trim returned messages');

    # Check: either the full batch is present (all 3 results) or
    # the assistant was removed (no orphaned tool_calls with partial results)
    my $assistant_idx = -1;
    my @tool_result_indices;
    for my $i (0 .. $#$trimmed) {
        if ($trimmed->[$i]{role} eq 'assistant' && $trimmed->[$i]{tool_calls}) {
            $assistant_idx = $i;
        }
        if ($trimmed->[$i]{role} eq 'tool') {
            push @tool_result_indices, $i;
        }
    }

    if ($assistant_idx >= 0) {
        # If the assistant is present, ALL its tool_calls must have results
        my $num_calls = scalar @{$trimmed->[$assistant_idx]{tool_calls}};
        my $num_results = scalar @tool_result_indices;
        ok($num_calls <= $num_results,
            "assistant has $num_calls tool_calls, $num_results results present (no orphans)");
    } else {
        # If the assistant was dropped, no tool_results from this batch remain
        ok(scalar(@tool_result_indices) == 0,
            'assistant dropped with its tool batch (no orphaned results)');
    }
}

# ── Test 2: Tool results preserved with their assistant ────────────────
{
    my $messages = make_tool_batch('test query with tools', 3, 'query result data');

    my $caps = {
        max_context_window_tokens => 200000,
        max_output_tokens         => 16000,
        max_prompt_tokens         => 200000,
    };

    my $trimmed = validate_and_truncate(
        messages           => $messages,
        model_capabilities => $caps,
        tools              => [],
        token_ratio        => 2.5,
    );

    ok(ref($trimmed) eq 'ARRAY' && @$trimmed, 'trim returned messages');
    # With generous budget, everything should be preserved
    is(scalar(@$trimmed), 7, 'all 7 messages preserved with generous budget');

    # Verify pairing: find the assistant message with tool_calls
    my $assistant = undef;
    my $assistant_idx = -1;
    for my $i (0 .. $#$trimmed) {
        if ($trimmed->[$i]{role} eq 'assistant' && exists $trimmed->[$i]{tool_calls}) {
            $assistant = $trimmed->[$i];
            $assistant_idx = $i;
            last;
        }
    }
    ok($assistant, 'found assistant message with tool_calls');
    is(scalar(@{$assistant->{tool_calls}}), 3, 'assistant has 3 tool_calls');

    my @tool_results = grep { $_->{role} eq 'tool' } @$trimmed;
    is(scalar(@tool_results), 3, '3 tool results preserved');
    is($tool_results[0]{tool_call_id}, 'call_0', 'first tool result matches call_0');
    is($tool_results[1]{tool_call_id}, 'call_1', 'second tool result matches call_1');
    is($tool_results[2]{tool_call_id}, 'call_2', 'third tool result matches call_2');
}

# ── Test 3: No orphaned tool_calls after tight trim ────────────────────
# After trim, no assistant message should have tool_calls without
# matching tool results.
{
    # Build a large array: system + many history messages + one tool batch
    my @messages = (
        { role => 'system', content => 'System prompt here.' },
    );

    # Add 20 filler user/assistant turns to consume budget
    for my $i (0 .. 19) {
        push @messages, { role => 'user', content => "User turn $i: " . ('x' x 200) };
        push @messages, { role => 'assistant', content => "Assistant turn $i: " . ('y' x 200) };
    }

    # Now add the tool batch (the most recent turn)
    my $batch = make_tool_batch('final task with tools', 3, 'final result');
    push @messages, @$batch[1 .. $#$batch];  # skip batch's system, keep user + rest

    my $caps = {
        max_context_window_tokens => 3000,
        max_output_tokens         => 500,
        max_prompt_tokens         => 3000,
    };

    my $trimmed = validate_and_truncate(
        messages           => \@messages,
        model_capabilities => $caps,
        tools              => [],
        token_ratio        => 2.5,
    );

    ok(ref($trimmed) eq 'ARRAY' && @$trimmed, 'trim returned messages');

    # Verify: no assistant with tool_calls has fewer results than calls
    for my $i (0 .. $#$trimmed) {
        my $msg = $trimmed->[$i];
        next unless $msg->{role} eq 'assistant' && ref($msg->{tool_calls}) eq 'ARRAY';
        my @calls = grep { defined $_->{id} } @{$msg->{tool_calls}};
        next unless @calls;

        # Count how many of these tool_calls have results AFTER this position
        my %has_result;
        for my $j ($i + 1 .. $#$trimmed) {
            if ($trimmed->[$j]{role} eq 'tool' && $trimmed->[$j]{tool_call_id}) {
                $has_result{$trimmed->[$j]{tool_call_id}} = 1;
            }
        }

        my $orphaned = 0;
        for my $call (@calls) {
            $orphaned++ unless $has_result{$call->{id}};
        }
        ok($orphaned == 0,
            "No orphaned tool_calls in assistant at index $i ($orphaned orphans found)");
    }
}

# ── Test 4: validate_tool_message_pairs strips residual orphans ─────────
# Even if the walk somehow leaves an orphaned tool_call, validate_tool_message_pairs
# (called at the end of _role_based_tail_walk) should clean it.
{
    my @messages = (
        { role => 'system', content => 'System.' },
        { role => 'user', content => 'Test' },
        { role => 'assistant', content => 'Calling tools', tool_calls => [
            { id => 'call_a', type => 'function', function => { name => 't', arguments => '{}' } },
            { id => 'call_b', type => 'function', function => { name => 't', arguments => '{}' } },
        ]},
        { role => 'tool', content => 'result A', tool_call_id => 'call_a' },
        # call_b has NO result — orphaned
        { role => 'assistant', content => 'Final answer.' },
    );

    # Use extremely tight budget to force trimming, but the key check
    # is that validate_tool_message_pairs runs at the end.
    my $caps = {
        max_context_window_tokens => 100,
        max_output_tokens         => 50,
        max_prompt_tokens         => 100,
    };

    my $trimmed = validate_and_truncate(
        messages           => \@messages,
        model_capabilities => $caps,
        tools              => [],
        token_ratio        => 2.5,
    );

    ok(ref($trimmed) eq 'ARRAY', 'trim returned messages even under extreme tight budget');

    # Count tool_calls in any surviving assistant message with tool_calls
    my $total_calls = 0;
    my $total_results = 0;
    for my $msg (@$trimmed) {
        if ($msg->{role} eq 'assistant' && ref($msg->{tool_calls}) eq 'ARRAY') {
            $total_calls += grep { defined $_->{id} } @{$msg->{tool_calls}};
        }
        $total_results++ if $msg->{role} eq 'tool';
    }

    # If there are tool_calls, there must be >= matching results
    if ($total_calls > 0) {
        ok($total_results >= $total_calls,
            "Tool calls ($total_calls) <= tool results ($total_results) after trim");
    }
}

# ── Test 5: Batch atomicity — one tool_result can't fit ─────────────────
# When 2 of 3 tool_results fit but the 3rd can't, the ENTIRE batch
# (assistant + all 3 results) should be dropped, not just result 3.
{
    # System prompt that's big enough to consume most of the budget
    my $big_system = 'x' x 3000;
    
    my @messages = (
        { role => 'system', content => $big_system },
        { role => 'user', content => 'small' },
    );

    # Add the tool batch
    my $batch = make_tool_batch('task', 3, 'result data that is moderately long to test trimming');
    push @messages, @$batch[2 .. $#$batch];  # assistant + 3 tool results + final

    my $caps = {
        max_context_window_tokens => 2000,
        max_output_tokens         => 500,
        max_prompt_tokens         => 2000,
    };

    my $trimmed = validate_and_truncate(
        messages           => \@messages,
        model_capabilities => $caps,
        tools              => [],
        token_ratio        => 2.5,
    );

    ok(ref($trimmed) eq 'ARRAY' && @$trimmed, 'trim returned messages');

    # Check for orphaned tool_calls
    my $found_orphan = 0;
    for my $i (0 .. $#$trimmed) {
        my $msg = $trimmed->[$i];
        next unless $msg->{role} eq 'assistant' && ref($msg->{tool_calls}) eq 'ARRAY';
        my @calls = grep { defined $_->{id} } @{$msg->{tool_calls}};
        next unless @calls;

        my %has_result;
        for my $j ($i + 1 .. $#$trimmed) {
            if ($trimmed->[$j]{role} eq 'tool' && defined $trimmed->[$j]{tool_call_id}) {
                $has_result{$trimmed->[$j]{tool_call_id}} = 1;
            }
        }
        for my $call (@calls) {
            $found_orphan++ unless $has_result{$call->{id}};
        }
    }

    is($found_orphan, 0,
        'No orphaned tool_calls — entire batches dropped atomically when budget exceeded');
}

done_testing();
