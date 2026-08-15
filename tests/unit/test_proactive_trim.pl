#!/usr/bin/env perl
# Test: Proactive trim in WorkflowOrchestrator prevents massive reactive trims
#
# This test simulates the scenario that caused "Trimmed 434 messages":
# - Build a large @messages array simulating many tool call iterations
# - Verify that validate_and_truncate trims it proportionally
# - Verify the trimmed result preserves tool_call/tool_result pairs

use strict;
use warnings;
use utf8;
use lib './lib';
use Test::More;
use CLIO::Core::API::MessageValidator qw(validate_and_truncate);

# Simulate model capabilities (128K context like gpt-4.1)
my $caps = {
    max_prompt_tokens => 128000,
    max_output_tokens => 16384,
    max_context_window_tokens => 128000,
};

# Build a large message array simulating 50 iterations of tool calls
# This is what @messages looks like in a long session
my @messages;

# System prompt (~5K tokens worth)
push @messages, {
    role => 'system',
    content => "You are CLIO, an AI coding assistant. " . ("Context and instructions. " x 500),
};

# First user message
push @messages, {
    role => 'user',
    content => "Help me refactor this module and fix the font rendering bugs in the bigtext system.",
};

# Simulate 50 iterations of: assistant (with tool_calls) -> tool results
# Each iteration has ~3 tool calls, each returning ~2K of content
for my $iter (1..50) {
    my @tool_calls;
    for my $tc_num (1..3) {
        my $tc_id = "tc_iter${iter}_${tc_num}";
        push @tool_calls, {
            id => $tc_id,
            type => 'function',
            function => {
                name => 'file_operations',
                arguments => '{"operation":"read_file","path":"modules/pb-bigtext","start_line":' . ($iter * 20) . ',"end_line":' . ($iter * 20 + 40) . '}',
            },
        };
    }
    
    # Assistant message with tool calls
    push @messages, {
        role => 'assistant',
        content => "Let me check the font rendering in iteration $iter. " . ("Analysis text. " x 20),
        tool_calls => \@tool_calls,
    };
    
    # Tool results for each call
    for my $tc (@tool_calls) {
        push @messages, {
            role => 'tool',
            tool_call_id => $tc->{id},
            name => 'file_operations',
            content => "File content from iteration result. " . ("Line of code output with various details about the module and its functions. " x 200),
        };
    }
}

# Add one more user message at the end (current turn)
push @messages, {
    role => 'user',
    content => "Now check the B glyph width consistency.",
};

my $total_messages = scalar(@messages);
diag("Built $total_messages messages simulating 50 tool-call iterations");

# Test 1: Without trim, this would be way over the 128K limit
ok($total_messages > 200, "Message array is large enough to trigger trimming ($total_messages messages)");

# Test 2: validate_and_truncate should trim proportionally
my $trimmed = validate_and_truncate(
    messages           => \@messages,
    model_capabilities => $caps,
    tools              => [],
    token_ratio        => 2.5,
    debug              => 0,
    model              => 'gpt-4.1',
);

my $trimmed_count = scalar(@$trimmed);
diag("After proactive trim: $total_messages -> $trimmed_count messages");

ok($trimmed_count < $total_messages, "Messages were trimmed ($trimmed_count < $total_messages)");
ok($trimmed_count > 10, "Trim kept a reasonable number of messages ($trimmed_count > 10)");

# Test 3: First message should be system
is($trimmed->[0]{role}, 'system', "System prompt preserved as first message");

# Test 4: Check that tool_call/tool_result pairs are intact
my %tool_call_ids;
my %tool_result_ids;
for my $msg (@$trimmed) {
    if ($msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY') {
        for my $tc (@{$msg->{tool_calls}}) {
            $tool_call_ids{$tc->{id}} = 1;
        }
    }
    if ($msg->{role} && $msg->{role} eq 'tool' && $msg->{tool_call_id}) {
        $tool_result_ids{$msg->{tool_call_id}} = 1;
    }
}

# Every tool_result should have a matching tool_call
my $orphaned_results = 0;
for my $result_id (keys %tool_result_ids) {
    $orphaned_results++ unless $tool_call_ids{$result_id};
}
is($orphaned_results, 0, "No orphaned tool results after trimming");

# Test 5: Simulate what used to happen - the reactive trim path
# With the old code, @messages would have ALL 200+ messages when token_limit_exceeded fires
# With new code, @messages is already trimmed, so reactive trim drops very few
my $reactive_would_drop = $total_messages - $trimmed_count;
diag("Old reactive path would have dropped: $reactive_would_drop messages from $total_messages");
diag("New proactive path: already trimmed to $trimmed_count messages");
diag("If reactive still fires (estimation error), it only drops a handful");

# Test 6: Verify the trim didn't produce too few messages (sanity check)
# With 128K context and ~50% post-trim target, we should keep quite a few
ok($trimmed_count >= 10, "Kept at least 10 messages ($trimmed_count)");

# Test 7: Verify last user message is preserved (most recent context)
my $last_user = undef;
for my $msg (reverse @$trimmed) {
    if ($msg->{role} eq 'user') {
        $last_user = $msg;
        last;
    }
}
ok($last_user, "A user message is preserved in trimmed output");
like($last_user->{content}, qr/B glyph/, "Most recent user message preserved");

# Test 8: Test with smaller context (32K, like local models)
my $small_caps = {
    max_prompt_tokens => 32000,
    max_output_tokens => 4096,
};
my $small_trimmed = validate_and_truncate(
    messages           => \@messages,
    model_capabilities => $small_caps,
    tools              => [],
    token_ratio        => 2.5,
    debug              => 0,
    model              => 'local-model',
);
my $small_count = scalar(@$small_trimmed);
diag("32K context trim: $total_messages -> $small_count messages");
ok($small_count < $trimmed_count, "Smaller context = more aggressive trimming ($small_count < $trimmed_count)");
ok($small_count > 5, "Still keeps minimum messages ($small_count > 5)");

done_testing();
