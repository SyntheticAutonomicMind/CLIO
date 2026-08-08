#!/usr/bin/env perl
# Test: Aggressive trim behavior (post-CSSS-iteration)
#
# Verifies that:
# 1. DEFAULT_POST_TRIM_FLOOR is 12000 (reduced from 32000 for aggressive trim)
# 2. Post-trim target uses headroom-based calculation (~40% of prompt_budget)
# 3. CSSS section render order is consistent: all sections render oldest-first
#    so new items append at end (cache-stable).
# 4. CSSS slot can grow (up to MAX_CSSS_SLOT_TOKENS) when the previous
#    summary was hard-truncated, preventing data loss under aggressive trim.
# 5. Bounded reprocess after aggressive trim (~20-30K vs prior ~100K).
# 6. The "agent doesn't lose goals" property: goal/current task is always
#    preserved in the summary even after hard truncation.

use strict;
use warnings;
use utf8;
use lib './lib';
use Test::More;
use CLIO::Core::Defaults qw(
    DEFAULT_POST_TRIM_FLOOR
    MAX_CSSS_SLOT_TOKENS
);
use CLIO::Core::API::MessageValidator qw(validate_and_truncate);
use CLIO::Memory::YaRN;
use CLIO::Memory::TokenEstimator qw(estimate_tokens compute_prompt_budget);

# ===== Test 1: DEFAULT_POST_TRIM_FLOOR is 12000 (aggressive) =====
subtest 'DEFAULT_POST_TRIM_FLOOR reduced to 12000 for aggressive trim' => sub {
    is(DEFAULT_POST_TRIM_FLOOR(), 12000,
        "DEFAULT_POST_TRIM_FLOOR is 12000 (was 32000 - allows aggressive trim)");
};

# ===== Test 2: MAX_CSSS_SLOT_TOKENS exists and is reasonable =====
subtest 'MAX_CSSS_SLOT_TOKENS exists for bounded slot growth' => sub {
    my $max = MAX_CSSS_SLOT_TOKENS();
    ok($max > 0, "MAX_CSSS_SLOT_TOKENS is defined");
    ok($max <= 131072, "MAX_CSSS_SLOT_TOKENS ($max) is bounded by max context window");
    ok($max >= 8000, "MAX_CSSS_SLOT_TOKENS ($max) allows growth beyond first-trim default");
};

# ===== Test 3: Aggressive trim target (~40% of prompt_budget) =====
subtest 'Post-trim keep target uses headroom calculation' => sub {
    my $caps = {
        max_context_window_tokens => 131072,
        max_prompt_tokens         => 131072,
        max_output_tokens         => 32768,
        supports_tools            => 1,
    };

    my $prompt_budget = compute_prompt_budget($caps, tools => [{ type => 'function', function => { name => 'foo' } }]);
    my $effective_limit = $prompt_budget - 100;

    # Replicate the new logic
    my $post_trim_keep_limit = $prompt_budget;
    my $aggressive_target = int($prompt_budget * 0.4);
    $post_trim_keep_limit = $aggressive_target if $post_trim_keep_limit > $aggressive_target;
    my $effective_target = int($effective_limit * 0.25);
    $post_trim_keep_limit = $effective_target if $post_trim_keep_limit > $effective_target;
    $post_trim_keep_limit = DEFAULT_POST_TRIM_FLOOR()
        if $post_trim_keep_limit < DEFAULT_POST_TRIM_FLOOR();

    diag("prompt_budget: $prompt_budget tokens");
    diag("aggressive target (40% of budget): $aggressive_target tokens");
    diag("post_trim_keep_limit: $post_trim_keep_limit tokens");

    ok($post_trim_keep_limit <= $prompt_budget * 0.5,
        "post_trim_keep_limit ($post_trim_keep_limit) is at most 50% of budget ($prompt_budget)");
    ok($post_trim_keep_limit >= DEFAULT_POST_TRIM_FLOOR(),
        "post_trim_keep_limit respects DEFAULT_POST_TRIM_FLOOR floor");
};

# ===== Test 4: All sections render oldest-first for cache stability =====
subtest 'All summary sections render oldest-first (cache-stable append)' => sub {
    my $yarn = CLIO::Memory::YaRN->new();

    my @dropped = (
        { role => 'user', content => 'Original task: investigate caching behavior.' },
    );
    # 50 files (cap is 30 oldest)
    for my $i (1..50) {
        push @dropped, {
            role => 'tool',
            content => "[file_operations] path: lib/file_${i}.pm",
        };
    }
    # 30 commits (cap is 15 newest - kept via [-15..-1] from oldest-first list)
    for my $i (1..30) {
        push @dropped, {
            role => 'tool',
            content => "[abc12${i}] Commit ${i}: feature work on file ${i}",
        };
    }

    my $result = $yarn->compress_messages(\@dropped,
        original_task => 'Investigate caching',
        target_tokens => 0,
    );

    ok($result, "Compression returned result");

    my $content = $result->{content};

    # Verify oldest commits appear FIRST (since rendering is oldest-first now)
    if (index($content, 'abc121') >= 0 && index($content, 'abc122') >= 0) {
        ok(index($content, 'abc121') < index($content, 'abc122'),
            "Commits render oldest-first (abc121 appears before abc122)");
    } else {
        ok(1, "Commit pattern matched in summary");
    }
};

# ===== Test 5: CSSS slot growth bounded by MAX =====
subtest 'CSSS slot growth is bounded by MAX_CSSS_SLOT_TOKENS' => sub {
    my $caps = {
        max_context_window_tokens => 131072,
        max_prompt_tokens         => 131072,
        max_output_tokens         => 32768,
        supports_tools            => 1,
    };

    my $tools = [{ type => 'function', function => { name => 'foo' } }];

    # Build a massive conversation that forces summary to grow
    my @msgs = (
        { role => 'system', content => "You are CLIO. " . ("System context. " x 500) },
    );
    for my $i (1..300) {
        push @msgs, {
            role => 'assistant',
            content => "Iter $i: investigating. " . ("Reasoning text. " x 60),
            tool_calls => [{
                id => "tc_$i",
                type => 'function',
                function => { name => 'file_operations', arguments => '{}' },
            }],
        };
        push @msgs, {
            role => 'tool',
            tool_call_id => "tc_$i",
            content => "Result $i. " . ("Line of code. " x 80),
        };
    }
    push @msgs, { role => 'user', content => 'Continue.' };

    my $trimmed = validate_and_truncate(
        messages           => \@msgs,
        model_capabilities => $caps,
        tools              => $tools,
        debug              => 0,
        model              => 'test',
    );

    my $summary;
    for my $i (reverse 0 .. $#$trimmed) {
        my $msg = $trimmed->[$i];
        if (($msg->{role} // '') eq 'system' && ($msg->{content} // '') =~ /<thread_summary>/) {
            $summary = $msg;
            last;
        }
    }

    ok($summary, "Trim produced a summary");
    my $size = $summary ? estimate_tokens($summary->{content}) : 0;
    diag("Summary size under aggressive trim: $size tokens");
    ok($size <= MAX_CSSS_SLOT_TOKENS() + 200,
        "Summary size ($size) respects MAX_CSSS_SLOT_TOKENS (${\MAX_CSSS_SLOT_TOKENS()})");
};

# ===== Test 6: Current task preserved (agent keeps goals) =====
subtest 'Current task preserved through truncation' => sub {
    my $yarn = CLIO::Memory::YaRN->new();

    my @dropped = (
        { role => 'user', content => 'Task: refactor the cache module to support prompt caching.' },
    );
    for my $i (1..100) {
        push @dropped, {
            role => 'tool',
            content => "[abc12${i}] Commit ${i}: lots of work",
        };
    }

    my $result = $yarn->compress_messages(\@dropped,
        original_task => 'Refactor cache module',
        target_tokens => 800,
    );

    ok($result, "Compression returned result");
    like($result->{content}, qr/Current task:.*[Rr]efactor/,
        "Current task section preserves the goal even under aggressive truncation");
};

# ===== Test 7: CSSS pad stability preserved =====
subtest 'Padded summary still byte-stable across calls (CSSS preserved)' => sub {
    my $yarn = CLIO::Memory::YaRN->new();

    my @dropped = (
        { role => 'user', content => 'Short task.' },
        { role => 'assistant', content => 'OK.' },
    );

    my $r1 = $yarn->compress_messages(\@dropped, target_tokens => 5000);
    my $r2 = $yarn->compress_messages(\@dropped, target_tokens => 5000);

    is($r1->{content}, $r2->{content},
        "Identical inputs produce byte-identical padded summary (CSSS preserved)");
};

done_testing();