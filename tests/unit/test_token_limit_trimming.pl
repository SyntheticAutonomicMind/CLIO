#!/usr/bin/env perl
# Test token limit trimming preserves most recent messages (tail)
#
# This test verifies that when conversation history exceeds token limits,
# the trimming logic preserves the MOST RECENT messages (tail), not old
# completed tasks from the beginning of the session.
#
# Background: Previously the first user message was given _importance=10.0
# making it immortal across trims. In multi-task sessions this caused the
# agent to lose track of the current task after context trims, because old
# completed work persisted while current work was dropped.

use strict;
use warnings;
use lib './lib';
use Test::More;
use CLIO::Core::ConversationManager qw(trim_conversation_for_api);
use CLIO::Memory::TokenEstimator;

# Test 1: Most recent messages preserved when budget is tight
subtest 'Most recent messages preserved in tight budget' => sub {
    my @history = (
        { role => 'user', content => 'Old task from start of session' },
        { role => 'assistant', content => 'Working on old task...' },
    );
    
    # Add many large messages (simulate long conversation)
    for my $i (1..30) {
        push @history, { role => 'user', content => "Follow up message $i " . ("x" x 2000) };
        push @history, { role => 'assistant', content => "Response $i " . ("y" x 2000) };
    }
    
    my $system_prompt = "You are a helpful assistant. " x 100;  # ~1000 tokens
    
    my $trimmed = trim_conversation_for_api(
        \@history,
        $system_prompt,
        model_context_window => 20000,
        max_response_tokens => 4000,
    );
    
    ok(defined $trimmed && @$trimmed > 0, 'Trimmed result is not empty');
    ok(scalar(@$trimmed) < scalar(@history), 'History was trimmed');
    
    # Last message in trimmed should be the last message from original
    is($trimmed->[-1]{content}, $history[-1]{content}, 'Last message preserved (tail kept)');
    
    # First message (old task) should NOT be in the trimmed result
    # (it was old and got dropped)
    my $old_task_found = grep { $_->{content} eq 'Old task from start of session' } @$trimmed;
    is($old_task_found, 0, 'Old first user message was dropped (not immortal)');
    
    diag("Original: " . scalar(@history) . " messages, Trimmed: " . scalar(@$trimmed) . " messages");
};

# Test 2: Short history not trimmed
subtest 'Short history not trimmed' => sub {
    my @history = (
        { role => 'user', content => 'Short conversation start' },
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
    
    is(scalar(@$trimmed), scalar(@history), 'Short history not trimmed');
};

# Test 3: Target tokens floor prevents negative budget
subtest 'Minimum token floor prevents negative budget' => sub {
    my @history = (
        { role => 'user', content => 'Task' },
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
    
    ok(defined $trimmed, 'Returns defined result even with huge system prompt');
};

# Test 4: Multi-task session preserves current task, drops old
subtest 'Multi-task session keeps current work' => sub {
    # Simulate: Task A (completed), then Task B (current)
    my @history = ();
    
    # Task A messages (old, completed)
    push @history, { role => 'user', content => 'Task A: fix the color codes' };
    push @history, { role => 'assistant', content => 'Investigating color codes...' };
    push @history, { role => 'user', content => 'Task A confirmed working' };
    push @history, { role => 'assistant', content => 'Task A complete.' };
    
    # Lots of intermediate work
    for my $i (1..20) {
        push @history, { role => 'user', content => "Intermediate $i " . ("z" x 2000) };
        push @history, { role => 'assistant', content => "Work $i " . ("w" x 2000) };
    }
    
    # Task B messages (current)
    push @history, { role => 'user', content => 'Task B: audit all changes since da7d725' };
    push @history, { role => 'assistant', content => 'Starting the audit of changes...' };
    push @history, { role => 'user', content => 'Check the Jewel Thief game too' };
    push @history, { role => 'assistant', content => 'Auditing Jewel Thief now...' };
    
    my $system_prompt = "You are a helpful assistant. " x 100;
    
    my $trimmed = trim_conversation_for_api(
        \@history,
        $system_prompt,
        model_context_window => 20000,
        max_response_tokens => 4000,
    );
    
    ok(defined $trimmed && @$trimmed > 0, 'Trimmed result is not empty');
    
    # Task B (current) should be preserved
    my $task_b_found = grep { $_->{content} =~ /audit all changes/ } @$trimmed;
    ok($task_b_found, 'Current task (Task B) preserved in trimmed history');
    
    # Task A (old) should be dropped
    my $task_a_found = grep { $_->{content} =~ /fix the color codes/ } @$trimmed;
    is($task_a_found, 0, 'Old completed task (Task A) was dropped');
    
    # Most recent messages should be at the end
    is($trimmed->[-1]{content}, 'Auditing Jewel Thief now...', 'Most recent message is last');
};

done_testing();
