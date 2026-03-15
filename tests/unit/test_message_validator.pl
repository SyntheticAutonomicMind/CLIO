#!/usr/bin/env perl
# Test CLIO::Core::API::MessageValidator

use strict;
use warnings;
use utf8;
use lib '../../lib';
use Test::More;

use_ok('CLIO::Core::API::MessageValidator');

# Test preflight_validate
{
    my $messages = [
        { role => 'user', content => 'Hello' },
        { role => 'assistant', content => 'Hi there',
          tool_calls => [{ id => 'tc_1', type => 'function', function => { name => 'test', arguments => '{}' } }] },
        { role => 'tool', tool_call_id => 'tc_1', content => 'result' },
    ];
    
    my $errors = CLIO::Core::API::MessageValidator::preflight_validate($messages);
    is(scalar @$errors, 0, "No errors for valid tool pairs");
}

# Test preflight_validate with orphaned tool_call
{
    my $messages = [
        { role => 'user', content => 'Hello' },
        { role => 'assistant', content => 'Hi',
          tool_calls => [{ id => 'tc_orphan', type => 'function', function => { name => 'test', arguments => '{}' } }] },
        # No matching tool result
    ];
    
    my $errors = CLIO::Core::API::MessageValidator::preflight_validate($messages);
    ok(scalar @$errors > 0, "Detects orphaned tool_call");
    like($errors->[0], qr/orphan/i, "Error mentions orphan");
}

# Test preflight_validate with orphaned tool_result
{
    my $messages = [
        { role => 'user', content => 'Hello' },
        { role => 'tool', tool_call_id => 'tc_ghost', content => 'result' },
    ];
    
    my $errors = CLIO::Core::API::MessageValidator::preflight_validate($messages);
    ok(scalar @$errors > 0, "Detects orphaned tool_result");
}

# Test validate_tool_message_pairs - valid
{
    my $messages = [
        { role => 'user', content => 'Hello' },
        { role => 'assistant', content => 'I will help',
          tool_calls => [{ id => 'tc_1', type => 'function', function => { name => 'test' } }] },
        { role => 'tool', tool_call_id => 'tc_1', content => 'done' },
        { role => 'assistant', content => 'All done' },
    ];
    
    my $validated = CLIO::Core::API::MessageValidator::validate_tool_message_pairs($messages);
    is(scalar @$validated, 4, "Valid messages preserved");
}

# Test validate_tool_message_pairs - removes orphaned result
{
    my $messages = [
        { role => 'user', content => 'Hello' },
        { role => 'tool', tool_call_id => 'tc_nonexistent', content => 'orphan result' },
        { role => 'assistant', content => 'Response' },
    ];
    
    my $validated = CLIO::Core::API::MessageValidator::validate_tool_message_pairs($messages);
    is(scalar @$validated, 2, "Orphaned tool_result removed");
}

# Test validate_tool_message_pairs - strips orphaned tool_calls
{
    my $messages = [
        { role => 'user', content => 'Hello' },
        { role => 'assistant', content => 'I will help',
          tool_calls => [{ id => 'tc_orphan', type => 'function', function => { name => 'test' } }] },
        # No matching tool result
        { role => 'user', content => 'What happened?' },
    ];
    
    my $validated = CLIO::Core::API::MessageValidator::validate_tool_message_pairs($messages);
    is(scalar @$validated, 3, "Messages preserved with stripped tool_calls");
    ok(!$validated->[1]{tool_calls}, "tool_calls stripped from orphaned assistant message");
}

# Test validate_tool_message_pairs - selective stripping (mixed matched/orphaned)
{
    my $messages = [
        { role => 'user', content => 'Hello' },
        { role => 'assistant', content => 'I will help',
          tool_calls => [
              { id => 'tc_matched', type => 'function', function => { name => 'test1', arguments => '{}' } },
              { id => 'tc_orphan', type => 'function', function => { name => 'test2', arguments => '{}' } },
          ] },
        { role => 'tool', tool_call_id => 'tc_matched', content => 'result1' },
        # tc_orphan has no matching result
        { role => 'user', content => 'Next' },
    ];
    
    my $validated = CLIO::Core::API::MessageValidator::validate_tool_message_pairs($messages);
    is(scalar @$validated, 4, "Selective strip: message count preserved");
    ok($validated->[1]{tool_calls}, "Selective strip: tool_calls still present");
    is(scalar @{$validated->[1]{tool_calls}}, 1, "Selective strip: only matched tool_call kept");
    is($validated->[1]{tool_calls}[0]{id}, 'tc_matched', "Selective strip: correct tool_call retained");
}

# Test validate_and_truncate - within limits
{
    my $messages = [
        { role => 'system', content => 'You are helpful' },
        { role => 'user', content => 'Hello' },
        { role => 'assistant', content => 'Hi!' },
    ];
    
    my $result = CLIO::Core::API::MessageValidator::validate_and_truncate(
        messages           => $messages,
        model_capabilities => { max_prompt_tokens => 128000 },
        token_ratio        => 2.5,
    );
    
    is(scalar @$result, 3, "Messages within limit preserved");
}

# Test empty messages
{
    my $empty = CLIO::Core::API::MessageValidator::validate_tool_message_pairs([]);
    is(scalar @$empty, 0, "Empty messages returns empty");
    
    my $errors = CLIO::Core::API::MessageValidator::preflight_validate([]);
    is(scalar @$errors, 0, "Empty preflight returns no errors");
}

# Test: user message injection after trim drops user message in autonomous tool loop
# This tests the fix for the hallucination bug where the model saw no user message
# after a proactive trim during a long autonomous tool loop, causing it to think
# it was a new session.
{
    # Build a message array simulating a long autonomous tool loop:
    # system prompt + user message + many (assistant+tool) pairs
    # Set max_prompt_tokens low enough that the budget walk drops the user message
    my @messages;
    push @messages, { role => 'system', content => 'You are a helpful assistant.' };
    push @messages, { role => 'user', content => 'Please investigate the Usurper source code thoroughly.' };
    
    # Add 40 assistant+tool pairs (simulating autonomous tool loop)
    for my $i (1..40) {
        my $tc_id = "tc_$i";
        push @messages, {
            role => 'assistant',
            content => "Reading file $i...",
            tool_calls => [{ id => $tc_id, type => 'function', function => { name => 'file_operations', arguments => '{"operation":"read_file","path":"file'.$i.'.txt"}' } }],
        };
        push @messages, {
            role => 'tool',
            tool_call_id => $tc_id,
            content => ('x' x 500),  # Each tool result is ~200 tokens
        };
    }
    
    # Set max_prompt_tokens very low so the budget walk only keeps the most recent messages
    my $result = CLIO::Core::API::MessageValidator::validate_and_truncate(
        messages           => \@messages,
        model_capabilities => { max_prompt_tokens => 8000 },
        token_ratio        => 2.5,
    );
    
    # Verify: the result should contain at least one user message
    my @user_msgs = grep { $_->{role} && $_->{role} eq 'user' } @$result;
    ok(scalar(@user_msgs) > 0, "User message preserved after trim in autonomous tool loop");
    
    # The user message content should match the original request
    if (@user_msgs) {
        like($user_msgs[0]{content}, qr/Usurper/, "Preserved user message contains original task");
    }
}

# Test: user message NOT injected when conversation already has a user message
{
    my @messages;
    push @messages, { role => 'system', content => 'You are a helpful assistant.' };
    push @messages, { role => 'user', content => 'Hello world' };
    push @messages, { role => 'assistant', content => 'Hi there!' };
    push @messages, { role => 'user', content => 'Now do something else' };
    push @messages, { role => 'assistant', content => 'OK doing it' };
    
    my $result = CLIO::Core::API::MessageValidator::validate_and_truncate(
        messages           => \@messages,
        model_capabilities => { max_prompt_tokens => 128000 },
        token_ratio        => 2.5,
    );
    
    # Count user messages - should be exactly 2 (not 3)
    my @user_msgs = grep { $_->{role} && $_->{role} eq 'user' } @$result;
    is(scalar(@user_msgs), 2, "No extra user message injected when conversation has user messages");
}

done_testing();
