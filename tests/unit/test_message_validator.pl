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

done_testing();
