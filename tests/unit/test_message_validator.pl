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

# Test: role-based history within budget is returned unchanged
# After the role-based history refactor, history is pushed as
# individual messages rather than bundled into a single
# messageHistory XML block. validate_and_truncate must preserve the
# message array structure when within budget.
{
    # Build a 5-turn role-based history (no XML wrapping)
    my @history;
    push @history, { role => 'user', content => 'Investigate the Usurper source.' };
    for my $i (1..5) {
        push @history, { role => 'assistant', content => "Iter $i analysis.",
                         tool_calls => [{ id => "tc_$i", type => 'function', function => { name => 'test', arguments => '{}' } }] };
        push @history, { role => 'tool',     tool_call_id => "tc_$i", content => "Result $i" };
    }

    my @messages = (
        { role => 'system', content => 'You are a helpful assistant.' },
        @history,
        { role => 'user',   content => 'Continue' },
    );

    my $result = CLIO::Core::API::MessageValidator::validate_and_truncate(
        messages           => \@messages,
        model_capabilities => { max_prompt_tokens => 128000 },
        token_ratio        => 2.5,
    );

    is(scalar(@$result), scalar(@messages), "Within budget: messages returned unchanged in count");
    is($result->[0]{role}, 'system', 'system prompt preserved');
    is($result->[-1]{content}, 'Continue', 'current user input preserved');
}

# Test: role-based trim drops oldest messages when over budget
{
    # Build a 30-turn role-based history (each turn has substantial content)
    my @history;
    for my $i (1..30) {
        push @history, { role => 'user', content => "Question $i " . ('x' x 200) };
        push @history, { role => 'assistant', content => "Answer $i " . ('y' x 200) };
    }

    my @messages = (
        { role => 'system', content => 'sys' },
        @history,
        { role => 'user',   content => 'current' },
    );

    my $result = CLIO::Core::API::MessageValidator::validate_and_truncate(
        messages           => \@messages,
        model_capabilities => { max_prompt_tokens => 1000, max_output_tokens => 256 },
        token_ratio        => 2.5,
    );

    # Result should be smaller than input - oldest turns got dropped
    ok(scalar(@$result) < scalar(@messages), "Over budget: messages dropped (was " . scalar(@messages) . ", now " . scalar(@$result) . ")");
    is($result->[-1]{content}, 'current', 'current user input always preserved');
    # First user message in remaining array should be Question N (some N > 1) - oldest got dropped
    my $first_user = (grep { $_->{role} eq 'user' } @$result)[0];
    ok(defined $first_user, 'at least one user message preserved');
    like($first_user->{content}, qr/Question (\d+)/, 'first user message preserved with Question N prefix');
}

done_testing();
