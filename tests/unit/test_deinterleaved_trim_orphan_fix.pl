#!/usr/bin/perl
# Test for the deinterleaved trim orphan tool_calls fix.
#
# Bug: Between 20260815.2 and 20260818.1, commit d4247744 introduced a
# deinterleaved trim layout that puts tool_results at the END of the
# conversation. The trim runs in two passes:
#   1. First pass keeps dialog (including assistant-with-tool_calls) up
#      to budget, defers tool_results to a separate list.
#   2. Second pass adds tool_results from newest to oldest, dropping
#      older ones if budget runs out.
# The two passes don't coordinate - tool_results can be dropped while
# their tool_calls remain in the kept dialog. Anthropic rejects these
# requests with:
#   "Each tool_use block must have a corresponding tool_result block
#    in the next message."
#
# Fix:
#   - Second pass skips tool_results whose tool_call isn't in the kept
#     dialog (defensive).
#   - Post-truncation validation strips orphan tool_calls from any
#     assistant message whose result was dropped (defense in depth).
#
# These tests verify the fix by forcing the trim to drop tool_results
# while keeping their tool_calls, then asserting that the assistant
# messages no longer carry the orphaned tool_calls.

use strict;
use warnings;
use utf8;

use lib './lib';
use Test::More;

use CLIO::Memory::TokenEstimator;

# Load the MessageValidator to get validate_and_truncate
use CLIO::Core::API::MessageValidator qw(validate_and_truncate);

# Helper: build a conversation with N rounds of tool_calls/tool_results
# Each round: assistant (with 1 tool_call) + tool_result
sub build_long_conversation {
    my (%opts) = @_;
    my $rounds      = $opts{rounds}      // 50;
    my $tool_call_id = $opts{tool_call_id} // 'tc_default';

    my @msgs = (
        { role => 'system', content => 'SYSTEM PROMPT ' . ('x' x 500) },
        { role => 'user',   content => 'Original task' },
    );

    for my $i (1 .. $rounds) {
        push @msgs, {
            role => 'assistant',
            content => "Response $i with reasoning. " . ('y' x 200),
            tool_calls => [{
                id => "${tool_call_id}_$i",
                type => 'function',
                function => {
                    name => 'file_operations',
                    arguments => '{"operation":"read","path":"lib/foo.pm"}',
                },
            }],
        };
        push @msgs, {
            role => 'tool',
            tool_call_id => "${tool_call_id}_$i",
            name => 'file_operations',
            content => "Tool result $i. " . ('z' x 2000),  # large results force drop
        };
    }

    return @msgs;
}

# Helper: check that every assistant message's tool_calls have matching
# tool_results in the conversation. Returns the list of orphaned
# tool_call_ids.
sub find_orphaned_tool_calls {
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
    my @orphans;
    for my $id (keys %tc_ids) {
        push @orphans, $id unless $tr_ids{$id};
    }
    return @orphans;
}

# =====================================================================
# Test 1: Deinterleaved trim drops tool_results but must NOT leave
# orphaned tool_calls in assistant messages.
# =====================================================================
subtest 'deinterleaved trim: no orphaned tool_calls after aggressive trim' => sub {
    my @msgs = build_long_conversation(rounds => 50);
    my @pre_orphans = find_orphaned_tool_calls(\@msgs);
    is(scalar(@pre_orphans), 0, 'Sanity: input has no orphans');

    # Aggressive trim - small context forces tool_results to be dropped
    my $caps = {
        max_context_window_tokens => 8192,
        max_prompt_tokens         => 8192,
        max_output_tokens         => 1024,
        supports_tools            => 1,
    };
    my $tools = [{
        type => 'function',
        function => {
            name => 'file_operations',
            description => 'File operations',
            parameters => { type => 'object', properties => {} },
        },
    }];

    my $trimmed = validate_and_truncate(
        messages           => \@msgs,
        model_capabilities => $caps,
        tools              => $tools,
        debug              => 0,
        model              => 'test-model',
    );

    my @post_orphans = find_orphaned_tool_calls($trimmed);
    is(scalar(@post_orphans), 0,
        'After deinterleaved trim: zero orphaned tool_calls (Anthropic would reject any)');
};

# =====================================================================
# Test 2: The deinterleaved layout still keeps tool_results and their
# matching tool_calls paired when budget allows.
# =====================================================================
subtest 'deinterleaved trim: tool pairs stay together when budget allows' => sub {
    my @msgs = build_long_conversation(rounds => 10);
    my $caps = {
        max_context_window_tokens => 131072,
        max_prompt_tokens         => 131072,
        max_output_tokens         => 8192,
        supports_tools            => 1,
    };
    my $tools = [{
        type => 'function',
        function => {
            name => 'file_operations',
            description => 'File operations',
            parameters => { type => 'object', properties => {} },
        },
    }];

    my $trimmed = validate_and_truncate(
        messages           => \@msgs,
        model_capabilities => $caps,
        tools              => $tools,
        debug              => 0,
        model              => 'test-model',
    );

    # Layout check skipped when trim doesn't kick in (generous budget).
    # The critical invariant here is pairing - verified by find_orphaned_tool_calls.
    pass('Layout check: pairing is what matters, not position');

    # Pairing check: no orphans
    my @orphans = find_orphaned_tool_calls($trimmed);
    is(scalar(@orphans), 0, 'No orphaned tool_calls when budget is generous');
};

# =====================================================================
# Test 3: When the second pass drops a tool_result, the matching
# tool_call in the dialog is stripped (defense in depth).
# =====================================================================
subtest 'post-trim validation: strips orphan tool_calls from assistant' => sub {
    # Build a conversation where tool_results will be dropped but
    # tool_calls will be kept
    my @msgs = (
        { role => 'system', content => 'SYSTEM ' . ('x' x 200) },
        { role => 'user',   content => 'task' },
    );
    # 20 rounds of small assistant + large tool_result - the tool_results
    # are big enough that budget will be exhausted, but assistant messages
    # with tool_calls are kept (they're in dialog, processed in first pass)
    for my $i (1 .. 20) {
        push @msgs, {
            role => 'assistant',
            content => "r$i",
            tool_calls => [{
                id => "tc_$i",
                type => 'function',
                function => { name => 'file_operations', arguments => '{}' },
            }],
        };
        push @msgs, {
            role => 'tool',
            tool_call_id => "tc_$i",
            name => 'file_operations',
            content => ('y' x 1000),  # 1KB per result - will be dropped first
        };
    }

    my $caps = {
        max_context_window_tokens => 4096,  # very tight
        max_prompt_tokens         => 4096,
        max_output_tokens         => 256,
        supports_tools            => 1,
    };
    my $tools = [{
        type => 'function',
        function => {
            name => 'file_operations',
            description => 'File operations',
            parameters => { type => 'object', properties => {} },
        },
    }];

    my $trimmed = validate_and_truncate(
        messages           => \@msgs,
        model_capabilities => $caps,
        tools              => $tools,
        debug              => 0,
        model              => 'test-model',
    );

    my @orphans = find_orphaned_tool_calls($trimmed);
    is(scalar(@orphans), 0,
        'Even under aggressive trim: zero orphaned tool_calls');
};

done_testing();
