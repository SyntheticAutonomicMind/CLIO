#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# Test APIManager::_process_think_tags - provider-agnostic inline <think> tag
# extraction. Drives the function directly with mock $ss state and
# captures the (filtered_content, on_thinking_callback_calls).

use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use Test::More;
use CLIO::Core::APIManager;

# ---------------------------------------------------------------------------
# Mock $ss that captures reasoning callbacks. Mirrors the real streaming
# state hash used by APIManager, but stripped to the fields _process_think_tags
# touches: think_buffer, in_think_tag, accum_reasoning, on_thinking.
# ---------------------------------------------------------------------------
package MockSS;
sub new {
    my ($class, %opts) = @_;
    my $self = bless {
        think_buffer    => '',
        in_think_tag    => 0,
        accum_reasoning => '',
        reasoning_calls => [],   # captured on_thinking($content) calls
        end_signals     => 0,    # captured on_thinking(undef, 'end') calls
    }, $class;
    my $default_cb = sub {
        my ($content, $signal) = @_;
        push @{$self->{reasoning_calls}}, $content if defined $content;
        $self->{end_signals}++ if defined $signal && $signal eq 'end';
    };
    $self->{on_thinking} = $opts{on_thinking} || $default_cb;
    return $self;
}

# ---------------------------------------------------------------------------
# Mock APIManager. Aliases _process_think_tags into this package so we can
# call it as $mock->_process_think_tags($content_delta, $ss).
# ---------------------------------------------------------------------------
package MockAPIManager;
sub new {
    my ($class) = @_;
    my $self = bless {}, $class;
    no strict 'refs';
    no warnings 'redefine';
    *{__PACKAGE__ . "::_process_think_tags"} =
        \&CLIO::Core::APIManager::_process_think_tags;
    return $self;
}

package main;

my $mock = MockAPIManager->new;

# Helper: run a single delta through _process_think_tags, return
# ($filtered_content, $ss).
sub run_delta {
    my ($ss, $content_delta) = @_;
    my $out = $mock->_process_think_tags($content_delta, $ss);
    return $out;
}

# =========================================================================
# Test 1: Basic inline <think>...</think> extraction. The llama.cpp + Qwen3
# scenario - thinking and answer stream in the same delta.content.
# =========================================================================
subtest 'inline think tags extract reasoning and pass content' => sub {
    my $ss = MockSS->new;
    my $out = run_delta($ss, "<think>The user is asking about myself.</think>I'm CLIO.");

    is($out, "I'm CLIO.", 'Content after </think> is preserved');
    is($ss->{in_think_tag}, 0, 'in_think_tag reset after close');
    is(scalar @{$ss->{reasoning_calls}}, 1, 'on_thinking called once with reasoning');
    is($ss->{reasoning_calls}[0], 'The user is asking about myself.',
        'Reasoning text extracted verbatim');
    is($ss->{accum_reasoning}, 'The user is asking about myself.',
        'accum_reasoning populated');
};

# =========================================================================
# Test 2: No think tags - passthrough unchanged. OpenAI / DeepSeek API
# scenario where thinking is in a separate reasoning_content field.
# =========================================================================
subtest 'no tags - passthrough unchanged' => sub {
    my $ss = MockSS->new;
    my $out = run_delta($ss, "Just plain content, no tags here.");

    is($out, "Just plain content, no tags here.", 'Content unchanged');
    is($ss->{in_think_tag}, 0, 'in_think_tag stays false');
    is(scalar @{$ss->{reasoning_calls}}, 0, 'on_thinking not called');
    is($ss->{accum_reasoning}, '', 'accum_reasoning stays empty');
};

# =========================================================================
# Test 3: Multi-line reasoning block. Verifies newlines inside the
# think-tag block are preserved as part of the reasoning text.
# =========================================================================
subtest 'multi-line reasoning inside think tags' => sub {
    my $ss = MockSS->new;
    my $delta = "<think>Line 1 of reasoning.\nLine 2 of reasoning.\nLine 3.</think>The answer.";
    my $out = run_delta($ss, $delta);

    is($out, "The answer.", 'Content after multi-line reasoning preserved');
    is($ss->{reasoning_calls}[0], "Line 1 of reasoning.\nLine 2 of reasoning.\nLine 3.",
        'Multi-line reasoning preserved verbatim');
};

# =========================================================================
# Test 4: Partial open tag across chunks. Streaming scenario where the
# <think> tag itself is split across two deltas.
# =========================================================================
subtest 'partial open tag buffered across chunks' => sub {
    my $ss = MockSS->new;

    # First chunk: "hello <th" - this is a partial <think> suffix, must
    # be buffered in think_buffer, NOT emitted as content.
    my $out1 = run_delta($ss, "hello <th");
    is($out1, "hello ", 'Content before partial tag is emitted');
    is($ss->{in_think_tag}, 0, 'Not yet inside think tag');
    is($ss->{think_buffer}, "<th", 'Partial <th buffered for next chunk');

    # Second chunk completes the tag: "ink>now inside</think>answer"
    my $out2 = run_delta($ss, "ink>now inside</think>answer");
    is($out2, "answer", 'Content after close tag emitted');
    is($ss->{reasoning_calls}[0], 'now inside', 'Reasoning from across-chunk tag captured');
    is($ss->{think_buffer}, '', 'think_buffer cleared after close');
};

# =========================================================================
# Test 5: Partial close tag across chunks. Reasoning text gets split
# across two deltas by the close tag boundary.
# =========================================================================
subtest 'partial close tag buffered across chunks' => sub {
    my $ss = MockSS->new;

    # First chunk opens and starts reasoning, ends with partial </think> suffix.
    my $out1 = run_delta($ss, "<think>reasoning so far</");
    is($out1, '', 'Nothing emitted - still inside think tag');
    is($ss->{in_think_tag}, 1, 'In think tag');
    is($ss->{think_buffer}, '</', 'Partial </ buffered');

    # Second chunk completes the close tag and provides the answer.
    my $out2 = run_delta($ss, "think>the answer.");
    is($out2, "the answer.", 'Content after completed close tag emitted');
    is($ss->{reasoning_calls}[0], 'reasoning so far',
        'Pre-close reasoning captured from first chunk');
};

# =========================================================================
# Test 6: Malformed/unclosed think tag. Stream ends inside a think block
# with no </think> ever arriving. The reasoning accumulates and the
# cleanup path should flush it.
# =========================================================================
subtest 'unclosed think tag - reasoning accumulates' => sub {
    my $ss = MockSS->new;

    # Single chunk that opens <think> but never closes.
    my $out = run_delta($ss, "<think>thinking that never closes");
    is($out, '', 'No content emitted while in unclosed think tag');
    is($ss->{in_think_tag}, 1, 'Still in think tag at end of input');
    is($ss->{reasoning_calls}[0], 'thinking that never closes',
        'Reasoning accumulated even without close tag');
};

# =========================================================================
# Test 7: Stale close tag without matching open. If a model emits a
# bare </think> with no preceding <think>, the cleanup should strip it
# from content rather than treating it as reasoning.
# =========================================================================
subtest 'stale close tag without open - stripped from content' => sub {
    my $ss = MockSS->new;

    my $out = run_delta($ss, "hello </think> world");
    is($out, "hello  world", 'Stale </think> stripped from content');
    is($ss->{in_think_tag}, 0, 'Not in think tag');
    is(scalar @{$ss->{reasoning_calls}}, 0, 'No reasoning extracted from stale tag');
};
# =========================================================================
# Test 9: Multiple think blocks in a single response. Some chat templates
# emit reasoning, then a tool-call decision, then more reasoning, then
# the final answer - each tag pair clears the buffer in between.
# =========================================================================
subtest 'multiple think blocks in one stream' => sub {
    my $ss = MockSS->new;

    my $out1 = run_delta($ss, "<think>first reasoning</think>");
    is($out1, '', 'First think block emits no content');
    is($ss->{reasoning_calls}[0], 'first reasoning', 'First reasoning captured');

    my $out2 = run_delta($ss, "<think>second reasoning</think>the answer");
    is($out2, 'the answer', 'Second think block followed by content');
    is($ss->{reasoning_calls}[1], 'second reasoning', 'Second reasoning captured');

    is(scalar @{$ss->{reasoning_calls}}, 2, 'Two reasoning chunks recorded');
};


# =========================================================================
# Test 10: Empty content delta with state preserved. _process_think_tags
# can be called with empty string; should not corrupt state.
# =========================================================================
subtest 'empty content delta preserves state' => sub {
    my $ss = MockSS->new;
    my $out = run_delta($ss, "");
    is($out, "", 'Empty input -> empty output');
    is($ss->{in_think_tag}, 0, 'State unchanged after empty delta');
    is(scalar @{$ss->{reasoning_calls}}, 0, 'No callbacks fired');
};

# =========================================================================
# Test 11: Direct verification - simulating the llama.cpp / Qwen3 scenario
# where the entire response arrives as a sequence of streamed deltas. The
# final reconstructed content should have no think tags and reasoning should
# be in the callback stream.
# =========================================================================
subtest 'streaming simulation - Qwen3 / llama.cpp end-to-end' => sub {
    my $ss = MockSS->new;

    # Simulate llama.cpp / Qwen3 streaming behavior: the model emits
    # short text chunks (typically 1-8 characters each) that the server
    # streams as SSE delta.content events. The think tags themselves
    # get split across chunks at arbitrary positions.
    my $response = "<think>The user is asking a conversational question about why I respond quickly. Let me think about the architecture.\n\n1. CLIO runs locally in the terminal on their machine.\n</think>Good question. Here's why I'm quick.";
    my @deltas;
    # Split into chunks of 3-5 chars to mimic realistic token chunking.
    for (my $i = 0; $i < length($response); $i += 4) {
        push @deltas, substr($response, $i, 4);
    }

    my $content = '';
    for my $delta (@deltas) {
        my $filtered = run_delta($ss, $delta);
        $content .= $filtered if defined $filtered;
    }

    is($content, "Good question. Here's why I'm quick.",
        'Reconstructed content has no think tags and only the answer');
    # With 4-char chunking, the reasoning arrives as multiple on_thinking
    # calls. Concatenating all of them must reconstruct the original
    # reasoning text exactly (this is the contract the THINKING-box
    # renderer relies on).
    my $joined = join('', @{$ss->{reasoning_calls}});
    like($joined, qr/The user is asking a conversational question/,
        'Reconstructed reasoning starts with the model meta-thought');
    like($joined, qr/CLIO runs locally in the terminal/,
        'Reconstructed reasoning includes the architecture list');
    is($ss->{in_think_tag}, 0, 'in_think_tag reset to 0 after close');
};

# =========================================================================
# Test 12: Qwen3.6 / llama.cpp close-tag variants. The model
# inconsistently emits </thinking> (with i) or [/thinking] (square
# brackets) instead of the canonical </think>. All three must close the
# thinking block so the real response reaches content and does not get
# swallowed into the thinking channel.
# =========================================================================
subtest 'Qwen3.6 close tag variants </thinking> and [/thinking]' => sub {
    my $ss = MockSS->new;
    my $out = run_delta($ss,
        "<think>User is just chatting.</thinking>\n\nNice. How's the install going?");
    is($out, "Nice. How's the install going?", 'Content after </thinking> preserved');
    is($ss->{in_think_tag}, 0, 'in_think_tag reset after </thinking>');
    is($ss->{reasoning_calls}[0], 'User is just chatting.',
        'Reasoning captured from </thinking> variant');

    $ss = MockSS->new;
    $out = run_delta($ss,
        "<think>User is just chatting.[/thinking]\n\nNice. How's the install going?");
    is($out, "Nice. How's the install going?", 'Content after [/thinking] preserved');
    is($ss->{in_think_tag}, 0, 'in_think_tag reset after [/thinking]');
    is($ss->{reasoning_calls}[0], 'User is just chatting.',
        'Reasoning captured from [/thinking] variant');
};

# =========================================================================
# Test 13: Open tag variants <thinking> and [thinking]. Some Qwen3.x
# templates open with the longer or bracket forms; the state machine
# must enter thinking mode for all of them.
# =========================================================================
subtest 'open tag variants <thinking> and [thinking]' => sub {
    my $ss = MockSS->new;
    my $out = run_delta($ss,
        "<thinking>Deep reasoning here</thinking>Answer");
    is($out, 'Answer', 'Content after <thinking>...</thinking> preserved');
    is($ss->{in_think_tag}, 0, 'in_think_tag reset');
    is($ss->{reasoning_calls}[0], 'Deep reasoning here',
        'Reasoning captured from <thinking> variant');

    $ss = MockSS->new;
    $out = run_delta($ss,
        "[thinking]Deep reasoning here[/thinking]Answer");
    is($out, 'Answer', 'Content after [thinking]...[/thinking] preserved');
    is($ss->{in_think_tag}, 0, 'in_think_tag reset for bracket form');
    is($ss->{reasoning_calls}[0], 'Deep reasoning here',
        'Reasoning captured from [thinking] variant');
};

# =========================================================================
# Test 14: Chunked </thinking> close across deltas. The model's response
# is streamed in small chunks, so </thinking> can be split as
# "</think" + "ing>". The partial-close buffer must handle the i-variant
# partials (</think, </thinki, </thinkin, </thinking) and the bracket
# partials ([/think, [/thinki, [/thinkin, [/thinking).
# =========================================================================
subtest 'chunked close variants across deltas' => sub {
    my $ss = MockSS->new;
    my $out1 = run_delta($ss, "<think>reasoning so far</think");
    is($out1, '', 'Nothing emitted while inside think tag');
    is($ss->{in_think_tag}, 1, 'Still in think tag');
    is($ss->{think_buffer}, '</think', 'Partial </think buffered');

    my $out2 = run_delta($ss, "ing>the answer.");
    is($out2, "the answer.", 'Content after chunked </thinking> emitted');
    is($ss->{reasoning_calls}[0], 'reasoning so far',
        'Pre-close reasoning captured');

    # Bracket close split: "[/think" + "ing]"
    $ss = MockSS->new;
    $out1 = run_delta($ss, "<think>reasoning so far[/think");
    is($ss->{think_buffer}, '[/think', 'Partial [/think buffered');
    $out2 = run_delta($ss, "ing]the answer.");
    is($out2, "the answer.", 'Content after chunked [/thinking] emitted');
    is($ss->{reasoning_calls}[0], 'reasoning so far',
        'Pre-close reasoning captured for bracket variant');
};

# =========================================================================
# Test 15: Stale close tag variants without matching open. Bare
# </thinking> or [/thinking] with no preceding open tag must be stripped
# from content, not emitted.
# =========================================================================
subtest 'stale close variants stripped from content' => sub {
    my $ss = MockSS->new;
    my $out = run_delta($ss, "hello </thinking> world");
    is($out, "hello  world", 'Stale </thinking> stripped');
    is(scalar @{$ss->{reasoning_calls}}, 0, 'No reasoning extracted');

    $ss = MockSS->new;
    $out = run_delta($ss, "hello [/thinking] world");
    is($out, "hello  world", 'Stale [/thinking] stripped');
    is(scalar @{$ss->{reasoning_calls}}, 0, 'No reasoning extracted');
};

done_testing();
