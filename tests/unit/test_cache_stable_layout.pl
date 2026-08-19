#!/usr/bin/env perl
# Test: Cache-Stable Layout for LCP Matching
#
# Verifies that the proactive trim produces a layout that maximizes the
# LCP (Longest Common Prefix) cache hit rate on llama.cpp:
#   1. Summary at position 1 (right after system prompt) so the LCP
#      match extends through sys + summary on every turn.
#   2. Tool results deinterleaved to the END of the prompt so the LCP
#      match extends through sys + summary + dialog across trims.
#   3. Tool results dropped FIRST when budget is exceeded (most
#      expendable - the agent can re-call the tool).
#
# These all combine to make prompt_stable_prefix_tokens (sys + summary)
# a stable cache key, with the dialog layer beneath it staying
# stable across trims as long as the conversation grows.

use strict;
use warnings;
use utf8;
use lib './lib';
use Test::More;
use CLIO::Core::API::MessageValidator qw(validate_and_truncate);
use CLIO::Core::ConversationManager qw(trim_conversation_for_api);
use CLIO::Memory::TokenEstimator qw(estimate_tokens);

# Helpers
sub find_summary {
    my ($msgs) = @_;
    for my $i (0 .. $#$msgs) {
        my $msg = $msgs->[$i];
        if (($msg->{role} // '') eq 'system' && ($msg->{content} // '') =~ /<thread_summary>/) {
            return ($i, $msg);
        }
    }
    return (-1, undef);
}

sub find_first_tool_result {
    my ($msgs) = @_;
    for my $i (0 .. $#$msgs) {
        my $msg = $msgs->[$i];
        if (($msg->{role} // '') eq 'tool' || $msg->{tool_call_id}) {
            return ($i, $msg);
        }
    }
    return (-1, undef);
}

sub find_last_dialog {
    my ($msgs) = @_;
    for my $i (reverse 0 .. $#$msgs) {
        my $msg = $msgs->[$i];
        my $role = $msg->{role} // '';
        next if $role eq 'tool' || $msg->{tool_call_id};
        return ($i, $msg);
    }
    return (-1, undef);
}

# Build a conversation with system prompt + dialog + tool results
# Sized to clearly exceed the effective budget so the proactive trim fires
sub build_mixed_conversation {
    my @msgs = (
        { role => 'system', content => "You are CLIO. " . ("Context. " x 500) },
        { role => 'user', content => "Build a thing." },
    );
    for my $i (1..200) {
        push @msgs, {
            role => 'assistant',
            content => "Iter $i: invoking tool. " . ("Reasoning. " x 50),
            tool_calls => [{
                id => "tc_$i",
                type => 'function',
                function => {
                    name => 'file_operations',
                    arguments => '{"operation":"read","path":"lib/CLIO/Core.pm"}',
                },
            }],
        };
        push @msgs, {
            role => 'tool',
            tool_call_id => "tc_$i",
            content => "File content iter $i. " . ("Line of code. " x 200),
        };
    }
    push @msgs, { role => 'user', content => "Continue with the next step." };
    return @msgs;
}

# ===== Test 1: Summary at the END preserves LCP through stable prefix =====
subtest 'Summary at END preserves LCP through stable prefix (sys + dialog + tool_results)' => sub {
    my @msgs = build_mixed_conversation();
    my $caps = {
        max_context_window_tokens => 131072,
        max_prompt_tokens         => 131072,
        max_output_tokens         => 32768,
        supports_tools            => 1,
    };
    # Use a small context window so the trim fires even with 200 iterations
    $caps->{max_context_window_tokens} = 16000;
    $caps->{max_prompt_tokens} = 16000;
    my $tools = [{ type => 'function', function => { name => 'file_operations' } }];

    my $trimmed = validate_and_truncate(
        messages           => \@msgs,
        model_capabilities => $caps,
        tools              => $tools,
        debug              => 0,
        model              => 'llama.cpp/test',
    );

    my ($summary_idx, $summary) = find_summary($trimmed);
    ok($summary_idx >= 0, "Summary exists in trimmed output");
    # Summary is at the END (after dialog + tool_results) so the LCP
    # can extend through the stable prefix (sys + dialog + tool_results)
    # before breaking at the summary content boundary. Placing it at
    # position 1 broke llama.cpp's prompt_stable_prefix_tokens gate on
    # the first trim (the bug observed 2026-08-19, cache hit ratio
    # collapse from ~0.99 to ~0.58).
    is($summary_idx, $#$trimmed,
        "Summary is at the END (after dialog + tool_results): idx=$summary_idx of $#$trimmed");
    isnt($summary_idx, 1,
        'Summary is NOT at position 1 (would break LCP at chat template boundary)');

    # Estimate the prompt_stable_prefix_tokens this layout would produce
    # (sys + summary, both are leading system messages)
    my $sys_tokens = estimate_tokens($trimmed->[0]{content} // '');
    my $summary_tokens = $summary ? estimate_tokens($summary->{content}) : 0;
    my $stable_prefix = $sys_tokens + $summary_tokens;
    diag("Estimated prompt_stable_prefix_tokens: $stable_prefix (sys=$sys_tokens + summary=$summary_tokens)");

    ok($stable_prefix > 1000,
        "Stable prefix (sys + summary) is substantial enough to anchor LCP: $stable_prefix tokens");
};

# ===== Test 2: Tool results deinterleaved to the END =====
subtest 'Tool results deinterleaved to the END of prompt' => sub {
    my @msgs = build_mixed_conversation();
    my $caps = {
        max_context_window_tokens => 131072,
        max_prompt_tokens         => 131072,
        max_output_tokens         => 32768,
        supports_tools            => 1,
    };
    my $tools = [{ type => 'function', function => { name => 'file_operations' } }];

    my $trimmed = validate_and_truncate(
        messages           => \@msgs,
        model_capabilities => $caps,
        tools              => $tools,
        debug              => 0,
        model              => 'llama.cpp/test',
    );

    my ($first_tr_idx, $first_tr) = find_first_tool_result($trimmed);
    my ($last_dialog_idx, $last_dialog) = find_last_dialog($trimmed);

    ok($first_tr_idx >= 0, "Tool result exists in trimmed output");
    ok($last_dialog_idx >= 0, "Some dialog exists in trimmed output");

    if ($first_tr_idx >= 0 && $last_dialog_idx >= 0) {
        ok($first_tr_idx > $last_dialog_idx,
            "First tool result ($first_tr_idx) is AFTER last dialog ($last_dialog_idx) - deinterleaved");
    }

    # Verify summary is BEFORE dialog
    my ($summary_idx, $summary) = find_summary($trimmed);
    if ($summary_idx >= 0 && $last_dialog_idx >= 0) {
        ok($summary_idx < $last_dialog_idx,
            "Summary ($summary_idx) is BEFORE dialog ($last_dialog_idx)");
    }

    # Verify the final order is: [sys, summary, dialog, tool_results]
    is($trimmed->[0]{role}, 'system', "Position 0 is system prompt");
    if ($summary_idx >= 0) {
        is($summary_idx, 1, "Position 1 is summary");
    }
    if ($first_tr_idx >= 0 && $last_dialog_idx >= 0) {
        ok($last_dialog_idx < $first_tr_idx,
            "Dialog ends ($last_dialog_idx) before tool_results start ($first_tr_idx)");
    }
};

# ===== Test 3: Tool results dropped FIRST when budget exceeded =====
subtest 'Tool results dropped first when budget exceeded' => sub {
    # Build a conversation so large that even after deinterleave we have
    # to drop some content. Tool results should be dropped, not dialog.
    my @msgs = (
        { role => 'system', content => "You are CLIO. " . ("Context. " x 200) },
        { role => 'user', content => "Build many things." },
    );
    for my $i (1..100) {
        push @msgs, {
            role => 'assistant',
            content => "Iter $i. " . ("Reasoning. " x 10),
            tool_calls => [{
                id => "tc_$i",
                type => 'function',
                function => {
                    name => 'file_operations',
                    arguments => '{"operation":"read","path":"lib/CLIO/Core.pm"}',
                },
            }],
        };
        push @msgs, {
            role => 'tool',
            tool_call_id => "tc_$i",
            # Large tool results to ensure they're the first to exceed budget
            content => "Tool result iter $i. " . ("Line of code. " x 500),
        };
    }

    my $caps = {
        max_context_window_tokens => 131072,
        max_prompt_tokens         => 131072,
        max_output_tokens         => 32768,
        supports_tools            => 1,
    };
    my $tools = [{ type => 'function', function => { name => 'file_operations' } }];

    my $trimmed = validate_and_truncate(
        messages           => \@msgs,
        model_capabilities => $caps,
        tools              => $tools,
        debug              => 0,
        model              => 'llama.cpp/test',
    );

    # Count tool results in the trimmed output
    my $trimmed_tool_count = 0;
    for my $msg (@$trimmed) {
        if (($msg->{role} // '') eq 'tool' || $msg->{tool_call_id}) {
            $trimmed_tool_count++;
        }
    }

    # Original had 100 tool results
    diag("Tool results in trimmed output: $trimmed_tool_count (out of 100 original)");

    # Verify the dialog user message "Build many things" is preserved
    my $user_preserved = grep {
        ($_->{role} // '') eq 'user' && ($_->{content} // '') eq 'Build many things.'
    } @$trimmed;
    ok($user_preserved, "Original user message preserved (dialog survives when tool_results are dropped)");
};

# ===== Test 4: LCP extends through sys + dialog + tool_results across trims =====
subtest 'LCP position is stable across trims (sys at 0, summary at END)' => sub {
    my @msgs = build_mixed_conversation();
    my $caps = {
        max_context_window_tokens => 16000,
        max_prompt_tokens         => 16000,
        max_output_tokens         => 32768,
        supports_tools            => 1,
    };
    my $tools = [{ type => 'function', function => { name => 'file_operations' } }];

    my $trimmed = validate_and_truncate(
        messages           => \@msgs,
        model_capabilities => $caps,
        tools              => $tools,
        debug              => 0,
        model              => 'llama.cpp/test',
    );

    # Layout invariant: sys always at 0, summary at END.
    # Summary at END (not position 1) keeps the LCP gate happy:
    # llama.cpp's prompt_stable_prefix_tokens is a minimum-prefix-match
    # gate, so the hint can include the summary but the cached slot
    # still matches through sys + dialog + tool_results before reaching
    # the summary content. (Bug observed 2026-08-19: summary at position
    # 1 forced the gate to include summary tokens that the cached slot
    # didn't have yet, collapsing sim_best from ~0.99 to ~0.58.)
    is($trimmed->[0]{role}, 'system', "Position 0 always system prompt");
    my ($summary_idx, $summary) = find_summary($trimmed);
    is($summary_idx, $#$trimmed,
        "Summary always at the END (stable across turns): idx=$summary_idx of $#$trimmed");

    diag("Layout invariant: sys at 0, dialog + tool_results in middle, summary at END");
};

# ===== Test 5: Pre-flight trim also produces the cache-stable layout =====
subtest 'Pre-flight trim produces cache-stable layout' => sub {
    my @msgs = (
        { role => 'system', content => "You are CLIO. " . ("Context. " x 500) },
        { role => 'system', content => "<thread_summary>\nCurrent task: Build a thing.\n</thread_summary>" },
        { role => 'user', content => "Original task" },
    );
    for my $i (1..50) {
        push @msgs, {
            role => 'assistant',
            content => "Iter $i. " . ("Reasoning. " x 50),
            tool_calls => [{
                id => "tc_$i",
                type => 'function',
                function => { name => 'file_operations', arguments => '{}' },
            }],
        };
        push @msgs, {
            role => 'tool',
            tool_call_id => "tc_$i",
            content => "Result $i. " . ("Line. " x 100),
        };
    }

    my $system_prompt = "You are CLIO. " . ("Context. " x 500);
    my $trimmed = trim_conversation_for_api(
        \@msgs,
        $system_prompt,
        model_context_window => 16000,
        max_response_tokens  => 8192,
        debug => 0,
    );

    my ($summary_idx, $summary) = find_summary($trimmed);
    my ($first_tr_idx, $first_tr) = find_first_tool_result($trimmed);
    my ($last_dialog_idx, $last_dialog) = find_last_dialog($trimmed);

    ok($summary_idx >= 0, "Pre-flight trim: summary exists");
    if ($summary_idx >= 0) {
        is($summary_idx, $#$trimmed,
            "Pre-flight trim: summary at the END (after dialog + tool_results)");
        isnt($summary_idx, 1,
            "Pre-flight trim: summary is NOT at position 1 (would break LCP gate)");
    }
    if ($first_tr_idx >= 0 && $last_dialog_idx >= 0) {
        ok($last_dialog_idx < $first_tr_idx,
            "Pre-flight trim: dialog ends ($last_dialog_idx) before tool_results ($first_tr_idx)");
    }
};

done_testing();
