#!/usr/bin/env perl
# Test: Role-based history trim in MessageValidator prevents oversized requests
#
# This test simulates the scenario that caused "Trimmed 434 messages"
# using the role-based history path (the only path in production
# after the messageHistory XML feature was removed):
# - Build a large history array simulating many tool call iterations
# - Wrap it in a [system_prompt, ...history..., user_input] @messages
# - Verify that validate_and_truncate trims oldest messages
# - Verify the trimmed result preserves the most recent turns and tool pairs
#
# After the role-based history refactor, history is pushed as
# individual messages rather than bundled into a single XML block.
# Trim is the role-based tail walk in MessageValidator::_role_based_tail_walk.
# It drops oldest messages until the array fits the budget while
# preserving the first user message (the original task anchor) and
# keeping tool_call/tool_result pairs together.

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

# Build a large history array simulating 50 iterations of tool calls.
my @history;

# First user message
push @history, {
    role => 'user',
    content => "Help me refactor this module and fix the font rendering bugs in the bigtext system.",
};

# Simulate 50 iterations of: assistant (with tool_calls) -> tool results
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
    push @history, {
        role => 'assistant',
        content => "Let me check the font rendering in iteration $iter. " . ("Analysis text. " x 20),
        tool_calls => \@tool_calls,
    };

    # Tool results for each call
    for my $tc (@tool_calls) {
        push @history, {
            role => 'tool',
            tool_call_id => $tc->{id},
            name => 'file_operations',
            content => "File content from iteration result. " . ("Line of code output with various details about the module and its functions. " x 200),
        };
    }
}

# Add one more user message at the end (current turn input)
push @history, {
    role => 'user',
    content => "Now check the B glyph width consistency.",
};

my $total_messages = scalar(@history);
diag("Built $total_messages messages simulating 50 tool-call iterations");

# Test 1: Without trim, this would be way over the 128K limit
ok($total_messages > 200, "Message array is large enough to trigger trimming ($total_messages messages)");

# Build the @messages array the way WorkflowOrchestrator would after
# the role-based history refactor: [system_prompt, ...history, user_input].
my $system_prompt = {
    role => 'system',
    content => "You are CLIO, an AI coding assistant. " . ("Context and instructions. " x 500),
};

# The current user input is the last user message; everything before
# it is the role-based history portion.
my @history_only = @history[0 .. $#history - 1];
my $current_user_input = $history[-1];

my @messages = (
    $system_prompt,
    @history_only,
    { role => 'user',   content => $current_user_input->{content} },
);

# Test 2: validate_and_truncate should trim oldest history messages
my $trimmed = validate_and_truncate(
    messages           => \@messages,
    model_capabilities => $caps,
    tools              => [],
    token_ratio        => 2.5,
    debug              => 0,
    model              => 'gpt-4.1',
);

my $trimmed_count = scalar(@$trimmed);
diag("After proactive trim: $trimmed_count messages (was $total_messages)");

# Test 3: Total messages dropped
ok($trimmed_count < $total_messages,
    "Total messages dropped ($trimmed_count < $total_messages)");

# Test 4: First user message (the original task anchor) survives the trim
my $first_user = (grep { $_->{role} eq 'user' } @$trimmed)[0];
ok(defined $first_user, "At least one user message preserved");
like($first_user->{content}, qr/Help me refactor/,
    "First user message (original task anchor) preserved");

# Test 5: Most recent tool_call/tool_result pairs survive intact
my $last_tool_result_idx = -1;
for (my $i = $#$trimmed; $i >= 0; $i--) {
    if ($trimmed->[$i]{role} eq 'tool') {
        $last_tool_result_idx = $i;
        last;
    }
}
ok($last_tool_result_idx > 0, "Tool results preserved in trimmed array");
if ($last_tool_result_idx > 0) {
    # Walk backward from the last tool result; the next assistant message
    # with matching tool_calls should appear somewhere before it (could
    # be anywhere in the array since we trim from oldest).
    my $tool_call_id = $trimmed->[$last_tool_result_idx]{tool_call_id};
    my $has_pair = 0;
    for (my $j = 0; $j < $last_tool_result_idx; $j++) {
        my $m = $trimmed->[$j];
        next unless $m->{role} eq 'assistant' && ref($m->{tool_calls}) eq 'ARRAY';
        for my $tc (@{$m->{tool_calls}}) {
            if (($tc->{id} // '') eq $tool_call_id) {
                $has_pair = 1;
                last;
            }
        }
        last if $has_pair;
    }
    ok($has_pair, "Tool result has matching assistant tool_call (pair intact)");

    # Test 6b (regression guard): no duplicate messages in the trimmed
    # array. Before the tail-walk fix, assistant tool_call messages were
    # added twice (once via the tool_pair pre-push, once via the normal
    # reverse walk) - the test above passed only because the duplicate
    # assistants happened to land after the tool result the test was
    # scanning for. Counting by (role, tool_call_ids) catches the
    # underlying bug without false-positives on tool results whose
    # bodies were identical in the fixture (all 50 iterations use the
    # same template).
    my %seen;
    my @dup_keys;
    for my $i (0 .. $#$trimmed) {
        my $m = $trimmed->[$i];
        next unless ref($m) eq 'HASH';
        my $tc_ids;
        if ($m->{tool_calls}) {
            $tc_ids = join(',', sort map { $_->{id} // '' } @{$m->{tool_calls}});
        } elsif ($m->{tool_call_id}) {
            $tc_ids = $m->{tool_call_id};
        } else {
            $tc_ids = substr($m->{content} // '', 0, 60);
        }
        my $key = "$m->{role}|$tc_ids";
        if ($seen{$key}++) {
            push @dup_keys, "[$i] $key";
        }
    }
    ok(!@dup_keys, "No duplicate assistant tool_calls or tool_call_ids in trimmed array (regression guard)")
        or diag("Duplicates:\n" . join("\n", @dup_keys));
}

# Test 7: Smaller context window produces more aggressive trim
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
my $small_trimmed_count = scalar(@$small_trimmed);
diag("32K context: $small_trimmed_count messages (was $total_messages)");
ok($small_trimmed_count <= $trimmed_count,
    "32K context trim is at least as aggressive as 128K ($small_trimmed_count <= $trimmed_count)");

done_testing();