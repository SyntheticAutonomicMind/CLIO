#!/usr/bin/env perl
# Test: State::trim_context preserves tool_call/tool_result batch atomicity
#
# Verifies that when Session::State::trim_context slices conversation
# history to fit the token budget, it does not split tool_call/tool_result
# batches across the kept/dropped boundary. A tool_result whose assistant
# was trimmed must be kept (or both dropped); an assistant with tool_calls
# whose results were trimmed must be dropped (or all results kept).
use strict;
use warnings;
use utf8;
use lib '../../lib';
use Test2::V0;

use CLIO::Session::State;

# Simple test logging helper
sub log_debug_test {
    my ($msg) = @_;
    # In test mode, just print to stderr for debugging
    print STDERR "  [test] $msg\n" if $ENV{CLIO_DEBUG} || $ENV{TEST_DEBUG};
}

# ── Helper: build a state with a large history containing tool batches ─
sub make_state_with_tool_batches {
    my ($total_turns, $tools_per_turn) = @_;
    $total_turns //= 20;
    $tools_per_turn //= 3;

    my $state = CLIO::Session::State->new(
        session_id => 'trim_test_' . time(),
        max_tokens => 128000,  # default
    );

    # System message
    $state->add_message('system', 'You are a helpful assistant.');

    # Add filler turns to push past the 15-message trim threshold
    for my $t (0 .. $total_turns - 1) {
        $state->add_message('user', "Turn $t: " . ('x' x 100));
        $state->add_message('assistant', "Turn $t response: " . ('y' x 100));

        # Add a tool batch on some turns
        if ($t % 3 == 0 && $t < $total_turns - 2) {
            my @tool_calls;
            for my $i (0 .. $tools_per_turn - 1) {
                push @tool_calls, {
                    id => "call_t${t}_${i}",
                    type => 'function',
                    function => { name => 'test_tool', arguments => '{}' },
                };
            }
            $state->add_message('assistant', "Calling tools for turn $t",
                { tool_calls => \@tool_calls });
            for my $i (0 .. $tools_per_turn - 1) {
                $state->add_message('tool', "Result for call_t${t}_${i}",
                    { tool_call_id => "call_t${t}_${i}" });
            }
            $state->add_message('assistant', "Turn $t done after tools");
        }
    }

    return $state;
}

# ── Test 1: trim_context doesn't orphan tool_calls ──────────────────────
# After trimming, no assistant with tool_calls should have fewer results
# than tool_calls in the kept history.
{
    my $state = make_state_with_tool_batches(20, 3);
    # Force a small max_tokens to trigger aggressive trimming
    $state->{max_tokens} = 128000;  # This gives keep_recent = 10

    # Manually trigger trim (it runs automatically in add_message when
    # history > 15 messages and current_size > trim_threshold, but
    # we call it directly to test the method)
    $state->trim_context();

    my $history = $state->get_history();
    ok(ref($history) eq 'ARRAY' && @$history, 'history non-empty after trim');

    # Verify no orphaned tool_calls in the trimmed history
    my $found_orphan = 0;
    for my $i (0 .. $#$history) {
        my $msg = $history->[$i];
        next unless $msg->{role} eq 'assistant' && ref($msg->{tool_calls}) eq 'ARRAY';
        my @calls = grep { defined $_->{id} } @{$msg->{tool_calls}};
        next unless @calls;

        # Check all results exist in the history AFTER this assistant
        my %has_result;
        for my $j ($i + 1 .. $#$history) {
            if ($history->[$j]{role} eq 'tool' && $history->[$j]{tool_call_id}) {
                $has_result{$history->[$j]{tool_call_id}} = 1;
            }
        }

        for my $call (@calls) {
            unless ($has_result{$call->{id}}) {
                $found_orphan++;
                log_debug_test("Orphaned call: $call->{id}");
            }
        }
    }
    is($found_orphan, 0, 'No orphaned tool_calls after trim_context');
}

# ── Test 2: trim_context doesn't keep tool_results without assistant ───
# After trimming, no tool message should reference a tool_call_id whose
# assistant was trimmed out.
{
    my $state = make_state_with_tool_batches(25, 2);
    $state->{max_tokens} = 128000;

    $state->trim_context();

    my $history = $state->get_history();
    ok(ref($history) eq 'ARRAY' && @$history, 'history non-empty after trim');

    # Collect all tool_call_ids that have assistants
    my %assistant_call_ids;
    for my $msg (@$history) {
        if ($msg->{role} eq 'assistant' && ref($msg->{tool_calls}) eq 'ARRAY') {
            for my $tc (@{$msg->{tool_calls}}) {
                $assistant_call_ids{$tc->{id}} = 1 if defined $tc->{id};
            }
        }
    }

    # Check no tool message references a dropped assistant's call_id
    my $orphan_results = 0;
    for my $msg (@$history) {
        if ($msg->{role} eq 'tool' && $msg->{tool_call_id}) {
            unless ($assistant_call_ids{$msg->{tool_call_id}}) {
                $orphan_results++;
            }
        }
    }
    is($orphan_results, 0, 'No orphaned tool_results after trim_context');
}

# ── Test 3: tool batch kept together at boundary ────────────────────────
# Verify that a tool batch is NOT split: if results are kept, the
# assistant is also kept, and vice versa.
{
    my $state = make_state_with_tool_batches(30, 3);
    $state->{max_tokens} = 128000;

    # Record the full history before trim
    my $before = $state->get_history();

    # Find all tool batches before trim
    my @tool_batches_before;
    for my $i (0 .. $#$before) {
        if ($before->[$i]{role} eq 'assistant' && ref($before->[$i]{tool_calls}) eq 'ARRAY'
            && @{$before->[$i]{tool_calls}}) {
            push @tool_batches_before, {
                assistant_idx => $i,
                tool_ids => [map { $_->{id} } grep { defined $_->{id} } @{$before->[$i]{tool_calls}}],
            };
        }
    }

    ok(@tool_batches_before, 'Found tool batches before trim');
    my $before_count = scalar @tool_batches_before;

    $state->trim_context();
    my $after = $state->get_history();

    # Count tool batches after trim
    my @tool_batches_after;
    for my $i (0 .. $#$after) {
        if ($after->[$i]{role} eq 'assistant' && ref($after->[$i]{tool_calls}) eq 'ARRAY'
            && @{$after->[$i]{tool_calls}}) {
            push @tool_batches_after, {
                assistant_idx => $i,
                tool_ids => [map { $_->{id} } grep { defined $_->{id} } @{$after->[$i]{tool_calls}}],
            };
        }
    }

    # Every assistant-with-tool_calls in the trimmed history must have
    # ALL its tool_call_ids present as results
    my $all_complete = 1;
    for my $batch (@tool_batches_after) {
        my $assistant = $after->[$batch->{assistant_idx}];
        my @call_ids = @{$batch->{tool_ids}};
        for my $id (@call_ids) {
            my $found = 0;
            for my $j ($batch->{assistant_idx} + 1 .. $#$after) {
                if ($after->[$j]{role} eq 'tool' && $after->[$j]{tool_call_id} eq $id) {
                    $found = 1;
                    last;
                }
            }
            unless ($found) {
                $all_complete = 0;
                log_debug_test("Batch at assistant_idx=" . $batch->{assistant_idx} . " missing result for $id");
            }
        }
    }
    ok($all_complete, 'All tool_call/tool_result batches are complete (no splits at boundary)');
}

# ── Test 4: trim_context respects the 15-message threshold ─────────────
{
    my $state = make_state_with_tool_batches(5, 2);
    # With only 5 turns, history should be < 15 messages total
    $state->trim_context();
    my $history = $state->get_history();
    # History should be unchanged (no trim triggered)
    # The 5 turns produce: system + 5*(user+assistant) + some tool batches
    # which is > 15, so trim may trigger. Let's verify trim is safe regardless.
    ok(ref($history) eq 'ARRAY' && @$history, 'history preserved after trim attempt');

    # Verify no orphans regardless
    my $found_orphan = 0;
    for my $i (0 .. $#$history) {
        my $msg = $history->[$i];
        next unless $msg->{role} eq 'assistant' && ref($msg->{tool_calls}) eq 'ARRAY';
        my @calls = grep { defined $_->{id} } @{$msg->{tool_calls}};
        next unless @calls;
        my %has_result;
        for my $j ($i + 1 .. $#$history) {
            if ($history->[$j]{role} eq 'tool'
                && $history->[$j]{tool_call_id}) {
                $has_result{$history->[$j]{tool_call_id}} = 1;
            }
        }
        for my $call (@calls) {
            $found_orphan++ unless $has_result{$call->{id}};
        }
    }
    is($found_orphan, 0, 'No orphaned tool_calls (short history edge case)');
}

# ── Test 5: trim_context with very large max_tokens (no trim) ──────────
# With a huge context window, trim shouldn't even trigger (messages < 15
# threshold check), and the batch structure should be intact.
{
    my $state = make_state_with_tool_batches(3, 2);
    $state->trim_context();
    my $history = $state->get_history();

    # Should have tool batches intact
    my $batch_count = 0;
    for my $i (0 .. $#$history) {
        if ($history->[$i]{role} eq 'assistant'
            && ref($history->[$i]{tool_calls}) eq 'ARRAY'
            && @{$history->[$i]{tool_calls}}) {
            $batch_count++;
            # Every call should have a result
            my @ids = map { $_->{id} } grep { defined $_->{id} } @{$history->[$i]{tool_calls}};
            for my $id (@ids) {
                my $found = 0;
                for my $j ($i + 1 .. $#$history) {
                    if ($history->[$j]{role} eq 'tool' && $history->[$j]{tool_call_id} eq $id) {
                        $found = 1;
                        last;
                    }
                }
                ok($found, "Tool call $id has matching result in untrimmed history");
            }
        }
    }
    ok($batch_count >= 1, 'Tool batches preserved in untrimmed history');
}

done_testing();
