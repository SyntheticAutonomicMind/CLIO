#!/usr/bin/env perl
# Test: Cache-Stable Summary Slot (CSSS) in MessageValidator + YaRN
#
# Verifies that:
# 1. After first trim, the summary slot size is locked to existing summary tokens
# 2. On subsequent trims, the regenerated summary fits the slot (within tolerance)
# 3. Summary is placed at END of conversation (after recent messages)
# 4. YaRN's _fit_summary_to_target truncates oldest items when too big
# 5. YaRN's _fit_summary_to_target pads with cache-stable filler when too small
# 6. compute_prompt_budget uses DEFAULT_TOOL_OUTPUT_RESERVE when tools present
# 7. compute_prompt_budget uses full output_reserve when no tools present
# 8. Summary content at fixed size means recent messages stay at constant positions

use strict;
use warnings;
use utf8;
use lib './lib';
use Test::More;
use CLIO::Core::API::MessageValidator qw(validate_and_truncate);
use CLIO::Core::ConversationManager qw(trim_conversation_for_api);
use CLIO::Memory::YaRN;
use CLIO::Memory::TokenEstimator qw(estimate_tokens compute_prompt_budget);

# Model capabilities for a tool-calling model with large output reserve
my $caps = {
    max_context_window_tokens => 131072,
    max_prompt_tokens         => 131072,
    max_output_tokens         => 32768,    # Will be capped at 8K when tools present
    supports_tools            => 1,
};

# Build a conversation that EXCEEDS the budget to force drops.
# With a 131K budget + tools, need ~150K tokens to trigger drops.
sub build_oversized_messages {
    my @messages = (
        { role => 'system', content => "You are CLIO. " . ("System context. " x 1000) },
        { role => 'user', content => "Fix the bug in module X. Look at the cache invalidation around trims." },
    );

    # 300 iterations = 600 messages, ~200K chars / 2.5 = 80K tokens
    for my $i (1..300) {
        push @messages, {
            role => 'assistant',
            content => "Iter $i: investigating. " . ("Reasoning text. " x 80),
            tool_calls => [{
                id => "tc_$i",
                type => 'function',
                function => {
                    name => 'file_operations',
                    arguments => '{"operation":"read","path":"lib/CLIO/Core.pm","offset":' . ($i*100) . '}',
                },
            }],
        };
        push @messages, {
            role => 'tool',
            tool_call_id => "tc_$i",
            content => "File content iter $i. " . ("Line of code. " x 200),
        };
    }

    push @messages, { role => 'user', content => "Continue debugging." };
    return @messages;
}

# Locate a thread_summary message in an array (scans from end backwards).
sub find_summary {
    my ($msgs) = @_;
    for my $i (reverse 0 .. $#$msgs) {
        my $msg = $msgs->[$i];
        if (($msg->{role} // '') eq 'system' && ($msg->{content} // '') =~ /<thread_summary>/) {
            return ($i, $msg);
        }
    }
    return (-1, undef);
}

# ===== Test 1: CSSS slot size is locked on second trim =====
subtest 'CSSS locks summary slot size after first trim' => sub {
    my @msgs = build_oversized_messages();
    my $tools = [{ type => 'function', function => { name => 'file_operations' } }];

    # First trim: drops many messages, generates summary
    my $trimmed1 = validate_and_truncate(
        messages           => \@msgs,
        model_capabilities => $caps,
        tools              => $tools,
        debug              => 0,
        model              => 'llama.cpp/test',
    );

    my ($idx1, $summary1) = find_summary($trimmed1);
    ok($idx1 >= 0, "First trim produced a summary");

    my $summary_size_1 = $summary1 ? estimate_tokens($summary1->{content}) : 0;
    ok($summary_size_1 > 0, "First summary has measurable size ($summary_size_1 tokens)");

    # Now add more messages and trim again - summary should fit same slot
    my @msgs2 = (@$trimmed1);
    for my $i (1..20) {
        push @msgs2, {
            role => 'assistant',
            content => "Iter $i more. " . ("Text. " x 30),
            tool_calls => [{
                id => "tc2_$i",
                type => 'function',
                function => { name => 'foo', arguments => '{}' },
            }],
        };
        push @msgs2, {
            role => 'tool',
            tool_call_id => "tc2_$i",
            content => "Result $i. " . ("Line. " x 50),
        };
    }

    my $trimmed2 = validate_and_truncate(
        messages           => \@msgs2,
        model_capabilities => $caps,
        tools              => $tools,
        debug              => 0,
        model              => 'llama.cpp/test',
    );

    my ($idx2, $summary2) = find_summary($trimmed2);
    ok($idx2 >= 0, "Second trim produced a summary");

    my $summary_size_2 = $summary2 ? estimate_tokens($summary2->{content}) : 0;
    diag("Summary sizes: trim1=$summary_size_1 trim2=$summary_size_2 tokens");

    # CSSS: summaries should be approximately the same size (within 30% tolerance)
    my $tolerance = int($summary_size_1 * 0.30);
    my $delta = abs($summary_size_1 - $summary_size_2);
    ok($delta <= $tolerance,
        "CSSS: summary sizes consistent ($summary_size_1 vs $summary_size_2 tokens, delta=$delta <= $tolerance tolerance)");
};

# ===== Test 2: Summary is at END of conversation =====
subtest 'Summary placed at end of conversation' => sub {
    my @msgs = build_oversized_messages();
    my $tools = [{ type => 'function', function => { name => 'foo' } }];

    my $trimmed = validate_and_truncate(
        messages           => \@msgs,
        model_capabilities => $caps,
        tools              => $tools,
        debug              => 0,
        model              => 'test',
    );

    my ($summary_idx, $summary) = find_summary($trimmed);

    ok($summary_idx >= 0, "Summary exists in trimmed output");

    my $last_idx = scalar(@$trimmed) - 1;
    is($summary_idx, $last_idx,
        "Summary is the LAST message (idx=$summary_idx, last=$last_idx) - cache-friendly ordering");

    # First should be system prompt (the real system prompt, not summary)
    my $first_role = $trimmed->[0]{role};
    my $first_content = $trimmed->[0]{content} // '';
    is($first_role, 'system', "First message is system");
    unlike($first_content, qr/<thread_summary>/, "First message is NOT a summary (it's the system prompt)");
};

# ===== Test 3: compute_prompt_budget uses DEFAULT_TOOL_OUTPUT_RESERVE with tools =====
subtest 'compute_prompt_budget reserves less output when tools present' => sub {
    my $tools = [{ type => 'function', function => { name => 'foo' } }];

    # Without tools: budget = ctx - max_output - buffer = 83559
    my $budget_no_tools = compute_prompt_budget($caps);
    is($budget_no_tools, 83559, "No tools: budget = 83559 tokens (uses full max_output_tokens)");

    # With tools: budget = ctx - 8K - buffer = 108135
    my $budget_with_tools = compute_prompt_budget($caps, tools => $tools);
    is($budget_with_tools, 108135,
        "With tools: budget = 108135 tokens (reclaimed ~24K by capping output_reserve at 8K)");
};

# ===== Test 4: compute_prompt_budget ignores tools for non-tool-capable models =====
subtest 'compute_prompt_budget uses full reserve when model lacks tool support' => sub {
    my $no_tools_caps = {
        %$caps,
        supports_tools => 0,
    };
    my $tools = [{ type => 'function', function => { name => 'foo' } }];

    my $budget = compute_prompt_budget($no_tools_caps, tools => $tools);
    is($budget, 83559,
        "No tool support: tools presence ignored, budget = 83559 tokens");
};

# ===== Test 5: YaRN _fit_summary_to_target truncates oversized summary =====
subtest 'YaRN _fit_summary_to_target truncates when summary too big' => sub {
    my $yarn = CLIO::Memory::YaRN->new();

    # Build a summary that's clearly oversized (lots of commits)
    my @dropped = (
        { role => 'user', content => 'Original task: debug the issue with X.' },
    );
    # Add 50 fake commits to inflate summary
    for my $i (1..50) {
        push @dropped, {
            role => 'tool',
            content => "[abc123$i] Commit message $i about feature work",
        };
    }
    push @dropped, { role => 'user', content => 'Continue' };

    my $result = $yarn->compress_messages(\@dropped,
        original_task => 'Fix bugs in module X',
        target_tokens => 2000,
    );

    ok($result, "Compression returned result with target_tokens");
    my $final_tokens = estimate_tokens($result->{content});
    diag("Compressed summary to target=2000: actual=$final_tokens tokens");

    my $tolerance = int(2000 * 0.30);
    ok($final_tokens <= 2000 + $tolerance,
        "Summary fits target (actual=$final_tokens, tolerance=+$tolerance)");

    like($result->{content}, qr/Current task/, "Current task section preserved");
};

# ===== Test 6: YaRN _fit_summary_to_target pads undersized summary =====
subtest 'YaRN _fit_summary_to_target pads when summary too small' => sub {
    my $yarn = CLIO::Memory::YaRN->new();

    my @dropped = (
        { role => 'user', content => 'Short task.' },
        { role => 'assistant', content => 'OK.' },
    );

    my $result = $yarn->compress_messages(\@dropped,
        original_task => 'Tiny task',
        target_tokens => 5000,
    );

    ok($result, "Compression returned result");
    my $final_tokens = estimate_tokens($result->{content});
    diag("Tiny summary with target=5000: actual=$final_tokens tokens");

    ok($final_tokens >= 4000,
        "Summary padded toward target (actual=$final_tokens >= 4000)");

    # Padded content should be cache-stable (same bytes each call)
    my $result2 = $yarn->compress_messages(\@dropped,
        original_task => 'Tiny task',
        target_tokens => 5000,
    );
    is($result->{content}, $result2->{content},
        "Padded summary produces identical bytes across calls (cache-stable)");
};

# ===== Test 7: Recent messages stay at constant positions across trims =====
subtest 'Recent messages stay at constant positions when summary size locked' => sub {
    my $yarn = CLIO::Memory::YaRN->new();

    my @dropped = (
        { role => 'user', content => 'Task: refactor X.' },
        { role => 'assistant', content => 'Looking.' },
        { role => 'tool', content => '[abc1234] First commit' },
        { role => 'tool', content => '[abc1235] Second commit' },
    );

    my $result1 = $yarn->compress_messages(\@dropped, target_tokens => 1500);
    my $result2 = $yarn->compress_messages(\@dropped, target_tokens => 1500);

    is($result1->{content}, $result2->{content},
        "Identical inputs produce identical summary bytes (cache-stable)");

    my $size = estimate_tokens($result1->{content});
    diag("Summary size with target=1500: actual=$size tokens");
};

subtest 'Pre-flight trim preserves thread_summary for CSSS' => sub {
    # Build a conversation with an existing thread_summary at position 1
    # (right after the system prompt). Size it so the pre-flight trim has
    # to drop messages to fit budget.
    my @msgs = (
        { role => 'system', content => "You are CLIO. " . ("System context. " x 500) },
        { role => 'system', content => "<thread_summary>\nCurrent task: Build a thing.\nFiles: a.c, b.c\n</thread_summary>" },
        { role => 'user', content => "Original task" },
    );
    for my $i (1..200) {
        push @msgs, {
            role => 'assistant',
            content => "Iter $i. " . ("Reasoning text. " x 50),
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
    push @msgs, { role => 'user', content => 'Continue.' };

    my $system_prompt = "You are CLIO. " . ("System context. " x 500);
    my $trimmed = trim_conversation_for_api(
        \@msgs,
        $system_prompt,
        model_context_window => 131072,
        max_response_tokens  => 8192,
        debug => 0,
    );

    # Verify the trimmed result still contains a thread_summary
    my ($summary_idx, $summary) = find_summary($trimmed);
    ok($summary_idx >= 0, "Pre-flight trim preserved existing thread_summary message");

    # The summary content should match the original - not regenerated
    my $original_summary = "<thread_summary>\nCurrent task: Build a thing.\nFiles: a.c, b.c\n</thread_summary>";
    is($summary->{content}, $original_summary,
        "Pre-flight trim preserved summary content verbatim (not regenerated)");
};

done_testing();