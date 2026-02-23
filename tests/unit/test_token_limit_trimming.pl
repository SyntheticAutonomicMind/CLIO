#!/usr/bin/env perl
# Test token limit trimming preserves first user message
#
# This test verifies that when conversation history exceeds token limits,
# the trimming logic always preserves the first user message (original task).

use strict;
use warnings;
use lib './lib';
use Test::More;
use CLIO::Core::ConversationManager qw(trim_conversation_for_api);
use CLIO::Memory::TokenEstimator;

# Test 1: First user message should be preserved even when budget is tight
subtest 'First user message preserved in tight budget' => sub {
    # Create a history with first user message having high importance
    my @history = (
        { role => 'user', content => 'Please fix the bug in module X', _importance => 10.0 },
        { role => 'assistant', content => 'I will investigate the bug...' },
        { role => 'user', content => 'Also check the tests' },
        { role => 'assistant', content => 'Running tests now...' },
    );
    
    # Add many large messages to exceed budget (simulate long conversation)
    # Each message ~1000 tokens (2500 characters)
    for my $i (1..30) {
        push @history, { role => 'user', content => "Follow up message $i " . ("x" x 2000) };
        push @history, { role => 'assistant', content => "Response $i " . ("y" x 2000) };
    }
    
    my $system_prompt = "You are a helpful assistant. " x 100;  # ~1000 tokens
    
    # Call the trimming function with small model context
    my $trimmed = trim_conversation_for_api(
        \@history,
        $system_prompt,
        model_context_window => 20000,  # Small context to force trimming
        max_response_tokens => 4000,
    );
    
    # Verify first user message is preserved
    ok(defined $trimmed && @$trimmed > 0, 'Trimmed result is not empty');
    
    my $first_user_found = 0;
    for my $msg (@$trimmed) {
        if ($msg->{role} eq 'user' && ($msg->{_importance} // 0) >= 10.0) {
            $first_user_found = 1;
            is($msg->{content}, 'Please fix the bug in module X', 'First user message content preserved');
            last;
        }
    }
    ok($first_user_found, 'First user message (importance=10.0) was preserved');
    
    # Verify trimming occurred (64 original messages should be reduced significantly)
    ok(scalar(@$trimmed) < scalar(@history), 'History was trimmed');
    
    diag("Original: " . scalar(@history) . " messages, Trimmed: " . scalar(@$trimmed) . " messages");
};

# Test 2: First user message at position 0 should be preserved
subtest 'First user message at start preserved' => sub {
    my @history = (
        { role => 'user', content => 'Original task request', _importance => 10.0 },
    );
    
    # Add lots of messages
    for my $i (1..50) {
        push @history, { role => 'assistant', content => "Response $i " x 20 };
        push @history, { role => 'user', content => "Query $i" };
    }
    
    my $system_prompt = "System prompt " x 100;
    
    my $trimmed = trim_conversation_for_api(
        \@history,
        $system_prompt,
        model_context_window => 30000,
        max_response_tokens => 4000,
    );
    
    # First message should be the original task
    ok(@$trimmed > 0, 'Result not empty');
    is($trimmed->[0]{content}, 'Original task request', 'First message is original task');
    is($trimmed->[0]{_importance}, 10.0, 'First message has correct importance');
};

# Test 3: When first user message is in recent window, don't duplicate
subtest 'No duplication when first user message is recent' => sub {
    my @history = (
        { role => 'user', content => 'Short conversation start', _importance => 10.0 },
        { role => 'assistant', content => 'Response' },
        { role => 'user', content => 'Follow up' },
    );
    
    my $system_prompt = "Short system prompt";
    
    my $trimmed = trim_conversation_for_api(
        \@history,
        $system_prompt,
        model_context_window => 128000,
        max_response_tokens => 4000,
    );
    
    # Should return original (no trimming needed)
    is(scalar(@$trimmed), scalar(@history), 'Short history not trimmed');
    
    # Count first user messages
    my $count = grep { ($_->{_importance} // 0) >= 10.0 } @$trimmed;
    is($count, 1, 'First user message appears exactly once');
};

# Test 4: Target tokens floor prevents negative budget
subtest 'Minimum token floor prevents negative budget' => sub {
    my @history = (
        { role => 'user', content => 'Task', _importance => 10.0 },
        { role => 'assistant', content => 'Response' },
    );
    
    # Very large system prompt that would exceed safe threshold
    my $system_prompt = "A" x 100000;
    
    my $trimmed = trim_conversation_for_api(
        \@history,
        $system_prompt,
        model_context_window => 50000,
        max_response_tokens => 4000,
    );
    
    # Should still return something (minimum floor)
    ok(defined $trimmed, 'Returns defined result even with huge system prompt');
};

done_testing();
