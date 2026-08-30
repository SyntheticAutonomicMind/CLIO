#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

# Test: Layer 3 of trim-loss fix - preserve most recent user message in full.
#
# When a long autonomous tool loop hits a trim cycle, the budget walk
# goes newest-to-oldest and the original user prompt at the bottom of
# the conversation is dropped along with the oldest dialog. Without a
# user message in the trimmed conversation, the model sees only
# assistant+tool pairs and may hallucinate that there's no active task.
#
# The existing fallback (validate_and_truncate post-validation) injects
# the most recent user message ONLY if no user message survived the
# budget walk. This test verifies that the injected message contains
# the original task text even when the budget walk drops it.
#
# Layer 3 enhancement: we also ensure the user message survives the
# budget walk itself (not just as an injected fallback) by making the
# budget walk prioritize the most recent user-role message. This is a
# tighter guarantee: the user message is part of the surviving
# conversation, not a synthetic injection.

use strict;
use warnings;
use utf8;
use lib './lib';
use Test::More;
use CLIO::Core::API::MessageValidator qw(validate_and_truncate);

my $passed = 0;
my $failed = 0;
my $total = 0;

sub ok_test {
    my ($cond, $desc) = @_;
    $desc //= '';
    $total++;
    if ($cond) { $passed++; print "ok $total - $desc\n"; }
    else       { $failed++; print "not ok $total - $desc\n"; }
}

# Test 1: User message preserved across aggressive trim
{
    my @messages;
    push @messages, { role => 'system', content => 'You are CLIO. ' x 100 };
    push @messages, { role => 'user', content => 'Original task: investigate the trim bug we discussed. Be thorough.' };

    # Add 100 iterations of assistant+tool pairs
    for my $i (1..100) {
        push @messages, {
            role => 'assistant',
            content => "Working on item $i. " x 50,
            tool_calls => [{ id => "tc$i", type => 'function', function => { name => 'file_operations', arguments => '{"path":"file.c"}' } }],
        };
        push @messages, {
            role => 'tool',
            tool_call_id => "tc$i",
            content => 'x' x 1000,
        };
    }

    my $result = validate_and_truncate(
        messages           => \@messages,
        model_capabilities => { max_prompt_tokens => 8000 },
        token_ratio        => 2.5,
    );

    my @user_msgs = grep { $_->{role} eq 'user' } @$result;
    ok_test(scalar(@user_msgs) > 0, 'user message preserved under aggressive trim (100 iterations)');
    ok_test($user_msgs[0]{content} =~ /investigate the trim bug/, 'preserved user message has original task');
    ok_test(length($user_msgs[0]{content}) == length('Original task: investigate the trim bug we discussed. Be thorough.'),
        'preserved user message is full content (not truncated)');
}

# Test 2: User message survives when budget is tight enough to drop it
# without Layer 3. With Layer 3, the user message should still appear
# (either via the budget walk preserving it, or via the injection
# fallback).
{
    my @messages;
    push @messages, { role => 'system', content => 'You are CLIO. ' x 1000 };
    push @messages, { role => 'user', content => 'Original task: do thing 1 then thing 2 then thing 3.' };

    for my $i (1..200) {
        push @messages, {
            role => 'assistant',
            content => "Working on iteration $i. " x 100,
            tool_calls => [{ id => "tc$i", type => 'function', function => { name => 'file_operations', arguments => '{}' } }],
        };
        push @messages, {
            role => 'tool',
            tool_call_id => "tc$i",
            content => 'content ' x 200,
        };
    }

    my $result = validate_and_truncate(
        messages           => \@messages,
        model_capabilities => { max_prompt_tokens => 8000 },
        token_ratio        => 2.5,
    );

    my @user_msgs = grep { $_->{role} eq 'user' } @$result;
    ok_test(scalar(@user_msgs) > 0, 'user message survives 200-iteration loop');
    ok_test($user_msgs[0]{content} =~ /do thing 1 then thing 2 then thing 3/, '200-iter: original task preserved');
}

# Test 3: User message NOT duplicated when conversation already has one
{
    my @messages;
    push @messages, { role => 'system', content => 'You are CLIO.' };
    push @messages, { role => 'user', content => 'Original task' };
    push @messages, { role => 'assistant', content => 'Hi!' };
    push @messages, { role => 'user', content => 'Now do something else' };
    push @messages, { role => 'assistant', content => 'OK doing it' };

    my $result = validate_and_truncate(
        messages           => \@messages,
        model_capabilities => { max_prompt_tokens => 128000 },
        token_ratio        => 2.5,
    );

    my @user_msgs = grep { $_->{role} eq 'user' } @$result;
    ok_test(scalar(@user_msgs) == 2, 'no duplicate user message when conversation already has user messages');
}

# Test 4: Edge case - no user message exists at all, only summary
{
    my @messages;
    push @messages, { role => 'system', content => 'You are CLIO.' };
    push @messages, { role => 'system', content => '<threadSummary>Current task: do something</threadSummary>' };
    push @messages, {
        role => 'assistant',
        content => 'Working autonomously.',
        tool_calls => [{ id => 'tc1', type => 'function', function => { name => 'file_operations', arguments => '{}' } }],
    };
    push @messages, { role => 'tool', tool_call_id => 'tc1', content => 'x' x 10000 };

    my $result = validate_and_truncate(
        messages           => \@messages,
        model_capabilities => { max_prompt_tokens => 8000 },
        token_ratio        => 2.5,
    );

    # Either we have a synthetic user message injected (existing fallback)
    # OR the budget walk kept at least one. Either is acceptable.
    my @user_msgs = grep { $_->{role} eq 'user' } @$result;
    ok_test(scalar(@user_msgs) >= 1, 'no user message scenario: synthetic injection or budget keep');
}

# Test 5: Long user message preserved verbatim (no truncation)
{
    my $long_user = 'Detailed instructions: ' . ('x' x 2000) . '. End of instructions.';
    my @messages;
    push @messages, { role => 'system', content => 'You are CLIO.' };
    push @messages, { role => 'user', content => $long_user };

    for my $i (1..50) {
        push @messages, {
            role => 'assistant',
            content => 'Working.',
            tool_calls => [{ id => "tc$i", type => 'function', function => { name => 'file_operations', arguments => '{}' } }],
        };
        push @messages, { role => 'tool', tool_call_id => "tc$i", content => 'content ' x 100 };
    }

    my $result = validate_and_truncate(
        messages           => \@messages,
        model_capabilities => { max_prompt_tokens => 8000 },
        token_ratio        => 2.5,
    );

    my @user_msgs = grep { $_->{role} eq 'user' } @$result;
    ok_test(scalar(@user_msgs) > 0, 'long user message: preserved');
    ok_test(defined $user_msgs[0] && length($user_msgs[0]{content}) == length($long_user),
        'long user message: full length preserved (not truncated)');
}

# Test 6: User message in the middle of dialog survives
{
    # Simulate a user message that's not at the very start but the
    # most recent one. The budget walk goes newest-to-oldest, so a
    # middle user message might not be preserved if budget is tight.
    my @messages;
    push @messages, { role => 'system', content => 'You are CLIO.' };
    push @messages, { role => 'user', content => 'First user message' };
    push @messages, { role => 'assistant', content => 'OK' };
    # Now 80 iterations
    for my $i (1..80) {
        push @messages, {
            role => 'assistant',
            content => 'Working ' x 100,
            tool_calls => [{ id => "tc$i", type => 'function', function => { name => 'file_operations', arguments => '{}' } }],
        };
        push @messages, { role => 'tool', tool_call_id => "tc$i", content => 'content ' x 200 };
    }
    push @messages, { role => 'user', content => 'Latest user message after 80 iterations' };
    push @messages, { role => 'assistant', content => 'OK proceeding' };

    my $result = validate_and_truncate(
        messages           => \@messages,
        model_capabilities => { max_prompt_tokens => 8000 },
        token_ratio        => 2.5,
    );

    my @user_msgs = grep { $_->{role} eq 'user' } @$result;
    ok_test(scalar(@user_msgs) > 0, 'middle user message: preserved');
    # The latest user message should be the one preserved (it's newest)
    ok_test($user_msgs[-1]{content} =~ /Latest user message after 80 iterations/,
        'middle user message: latest one (newest) preserved');
}

print "\n$passed passed, $failed failed\n";
exit($failed > 0 ? 1 : 0);
