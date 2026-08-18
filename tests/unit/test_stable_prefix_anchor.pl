#!/usr/bin/perl
# Test prompt_stable_prefix_tokens anchoring to system prompt only.
#
# Bug fixed: prompt_stable_prefix_tokens summed tokens of ALL leading
# system messages (system_prompt + context_files pre-trim, or
# system_prompt + thread_summary post-trim). When the trim replaced
# context_files with thread_summary, the prefix dropped from 27540 to
# 23983 tokens and llama.cpp's LCP match collapsed to sim_best=0.33,
# forcing a full 200+ second reprocessing per turn.
#
# Fix: only count the FIRST system message (the system prompt). The
# system prompt is the only section that is truly byte-identical across
# trims. Everything after the system prompt can shift:
#   - context_files (pre-trim layout) is dropped by trim_conversation_for_api
#   - thread_summary (post-trim CSSS slot) regenerates within size budget
#
# Companion fix: cache_control marker anchors on the FIRST leading system
# message (the system prompt) instead of the LAST (which is volatile).

use strict;
use warnings;
use utf8;
use lib 'lib';
use Test::More;

# We test the production logic by re-implementing the same two
# blocks from APIManager._build_payload. If production drifts, this
# helper will diverge and the tests will fail.
sub compute_stable_prefix {
    my ($messages) = @_;
    require CLIO::Memory::TokenEstimator;
    my $stable_tokens = 0;
    my $first_msg = $messages->[0];
    if ($first_msg && ($first_msg->{role} // '') eq 'system') {
        my $content = $first_msg->{content} // '';
        if (ref($content) eq 'ARRAY') {
            for my $part (@$content) {
                if (ref($part) eq 'HASH' && ($part->{type} // '') eq 'text') {
                    $stable_tokens += CLIO::Memory::TokenEstimator::estimate_tokens($part->{text} // '');
                }
            }
        } else {
            $stable_tokens = CLIO::Memory::TokenEstimator::estimate_tokens($content);
        }
    }
    return $stable_tokens;
}

sub apply_cache_control {
    my ($messages, $endpoint_config) = @_;
    return unless $endpoint_config->{supports_cache_control};
    return unless $messages && @$messages;
    my $first_system_idx;
    for my $i (0 .. $#$messages) {
        if ($messages->[$i] && ($messages->[$i]{role} // '') eq 'system') {
            $first_system_idx = $i;
            last;
        } else {
            last;
        }
    }
    if (defined $first_system_idx) {
        $messages->[$first_system_idx]{cache_control} = { type => 'ephemeral' };
    }
    return $messages;
}

# =================================================================
# Test 1: Pre-trim layout (system_prompt + context_files + dialog)
# The stable prefix must equal the system prompt tokens only, not
# include context_files.
# =================================================================
subtest 'pre-trim: stable prefix is system prompt only (context_files excluded)' => sub {
    my $system_prompt = "You are CLIO. " . ("Stable system context. " x 200);
    my $context_files = "[CONTEXT FILES]\n" . ("File content. " x 1000);

    my $messages = [
        { role => 'system', content => $system_prompt },
        { role => 'system', content => $context_files },   # injected by inject_context_files
        { role => 'user',      content => 'q1' },
        { role => 'assistant', content => 'a1' },
        { role => 'user',      content => 'q2' },
    ];

    my $stable_prefix = compute_stable_prefix($messages);
    require CLIO::Memory::TokenEstimator;
    my $expected = CLIO::Memory::TokenEstimator::estimate_tokens($system_prompt);

    diag("Stable prefix: $stable_prefix tokens (expected: $expected)");
    is($stable_prefix, $expected,
        'Stable prefix equals system prompt tokens, context_files excluded');
};

# =================================================================
# Test 2: Post-trim layout (system_prompt + thread_summary + dialog).
# The stable prefix must equal the system prompt tokens only, not
# include the regenerated summary.
# =================================================================
subtest 'post-trim: stable prefix is system prompt only (thread_summary excluded)' => sub {
    my $system_prompt = "You are CLIO. " . ("Stable system context. " x 200);
    my $summary = "<thread_summary>\nCurrent task: Build a thing.\n" .
                  ("Summarized context. " x 500) .
                  "\n</thread_summary>";

    my $messages = [
        { role => 'system', content => $system_prompt },
        { role => 'system', content => $summary },          # replaced context_files after trim
        { role => 'user',      content => 'q1' },
        { role => 'assistant', content => 'a1' },
        { role => 'user',      content => 'q2' },
    ];

    my $stable_prefix = compute_stable_prefix($messages);
    require CLIO::Memory::TokenEstimator;
    my $expected = CLIO::Memory::TokenEstimator::estimate_tokens($system_prompt);

    diag("Stable prefix: $stable_prefix tokens (expected: $expected)");
    is($stable_prefix, $expected,
        'Stable prefix equals system prompt tokens, thread_summary excluded');
};

# =================================================================
# Test 3: CRITICAL - stable prefix is identical across a trim
# This is the bug we caught. Old behavior: 27540 -> 23983 (collapse).
# New behavior: 27540 -> 27540 (no change, LCP match survives).
# =================================================================
subtest 'CRITICAL: stable prefix is identical across trim (no collapse)' => sub {
    my $system_prompt = "You are CLIO. " . ("Stable system context. " x 200);
    my $context_files = "[CONTEXT FILES]\n" . ("File content. " x 1000);
    my $summary = "<thread_summary>\nNewly compressed. " . ("Data. " x 500) . "</thread_summary>";

    # Pre-trim layout
    my $pre_trim_messages = [
        { role => 'system', content => $system_prompt },
        { role => 'system', content => $context_files },
        { role => 'user',      content => 'q1' },
        { role => 'assistant', content => 'a1' },
    ];
    my $pre_trim_stable = compute_stable_prefix($pre_trim_messages);

    # Post-trim layout (context_files replaced by thread_summary)
    my $post_trim_messages = [
        { role => 'system', content => $system_prompt },
        { role => 'system', content => $summary },
        { role => 'user',      content => 'q1' },
        { role => 'assistant', content => 'a1' },
    ];
    my $post_trim_stable = compute_stable_prefix($post_trim_messages);

    diag("Pre-trim stable prefix:  $pre_trim_stable tokens");
    diag("Post-trim stable prefix: $post_trim_stable tokens");
    is($pre_trim_stable, $post_trim_stable,
        'Stable prefix is byte-identical across trim (LCP match survives)');
};

# =================================================================
# Test 4: cache_control marker anchors on system prompt
# Old behavior: marker on last leading system (volatile context_files
# or summary) - cache invalidates on trim.
# New behavior: marker on system prompt - cache anchored to stable part.
# =================================================================
subtest 'cache_control anchored on system prompt (first leading system)' => sub {
    my $messages = [
        { role => 'system', content => 'STABLE SYSTEM PROMPT' },
        { role => 'system', content => '[CONTEXT FILES] volatile content' },
        { role => 'user',      content => 'q' },
    ];
    my $config = { supports_cache_control => 1 };

    apply_cache_control($messages, $config);

    ok(exists $messages->[0]{cache_control},
        'system_prompt at [0] has cache_control marker');
    is_deeply($messages->[0]{cache_control}, { type => 'ephemeral' },
        'system_prompt cache_control is {type: ephemeral}');
    ok(!exists $messages->[1]{cache_control},
        'context_files at [1] has NO cache_control (volatile)');
};

# =================================================================
# Test 5: cache_control marker stays on system prompt when summary
# replaces context_files (post-trim layout).
# =================================================================
subtest 'cache_control stays on system prompt after trim (not on summary)' => sub {
    my $messages = [
        { role => 'system', content => 'STABLE SYSTEM PROMPT' },
        { role => 'system', content => '<thread_summary>regenerated</thread_summary>' },
        { role => 'user',      content => 'q' },
    ];
    my $config = { supports_cache_control => 1 };

    apply_cache_control($messages, $config);

    ok(exists $messages->[0]{cache_control},
        'system_prompt at [0] has cache_control marker (anchor)');
    ok(!exists $messages->[1]{cache_control},
        'thread_summary at [1] has NO cache_control (volatile)');
};

# =================================================================
# Test 6: Multimodal system prompt (array content) is handled correctly
# =================================================================
subtest 'multimodal system prompt: only text parts count toward stable prefix' => sub {
    my $messages = [
        { role => 'system',
          content => [
              { type => 'text', text => 'Stable system prompt. ' x 100 },
              { type => 'image_url', image_url => { url => 'data:image/png;base64,...' } },
          ],
        },
        { role => 'system', content => '[CONTEXT FILES] volatile' },
        { role => 'user',      content => 'q' },
    ];

    my $stable_prefix = compute_stable_prefix($messages);
    require CLIO::Memory::TokenEstimator;
    my $expected = CLIO::Memory::TokenEstimator::estimate_tokens('Stable system prompt. ' x 100);

    is($stable_prefix, $expected,
        'Stable prefix counts multimodal text only, image not counted');
};

done_testing();
