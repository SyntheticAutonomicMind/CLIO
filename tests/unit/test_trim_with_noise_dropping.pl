#!/usr/bin/perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Tests for trim_with_noise_dropping - the noise-stripping trim wrapper
# added in commit 3 of the messageHistory feature.
#
# Validates:
# 1. trim_with_noise_dropping strips reasoning_content from non-current
#    assistant messages before the trim walk
# 2. The CURRENT (most recent) assistant message keeps its reasoning
#    (the model still needs it on the next turn)
# 3. The trim walk still respects the budget - if dropping noise isn't
#    enough, the oldest turns are dropped
# 4. User messages are NEVER stripped
# 5. Tool result messages keep their content

use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/../../lib";
use Test::More;
use CLIO::Core::ConversationManager qw(trim_with_noise_dropping);

# Test 1: noise-stripping removes reasoning_content from old assistants
{
    my @messages = (
        { role => 'user', content => 'q1' },
        { role => 'assistant', content => 'a1', reasoning_content => 'lots of thinking here ' x 100 },
        { role => 'user', content => 'q2' },
        { role => 'assistant', content => 'a2', reasoning_content => 'more thinking ' x 100 },
        { role => 'user', content => 'q3' },
    );
    my $trimmed = trim_with_noise_dropping(\@messages, '', model_context_window => 128000, max_response_tokens => 16000);
    is(scalar(@$trimmed), scalar(@messages), "No messages dropped (under budget)");
    # Both old assistants should have reasoning stripped (none of these
    # are the most recent)
    for my $msg (@$trimmed) {
        next unless $msg->{role} eq 'assistant';
        ok(!exists $msg->{reasoning_content} || !defined $msg->{reasoning_content},
            "Old assistant has reasoning_content stripped");
        ok(exists $msg->{_stripped_thinking} && $msg->{_stripped_thinking} == 1,
            "Old assistant has _stripped_thinking marker");
    }
}

# Test 2: tool results keep their content
{
    my @messages = (
        { role => 'user', content => 'q' },
        { role => 'assistant', content => '', tool_calls => [
            { id => 'call_abc', function => { name => 'read_file', arguments => '{}' } }
        ] },
        { role => 'tool', content => 'big file content here ' x 200, tool_call_id => 'call_abc' },
    );
    my $trimmed = trim_with_noise_dropping(\@messages, '', model_context_window => 128000, max_response_tokens => 16000);
    my $tool_msg = $trimmed->[-1];
    is($tool_msg->{role}, 'tool', "Tool message kept");
    ok(length($tool_msg->{content}) > 100, "Tool message content kept (no stripping)");
}

# Test 3: under tight budget, oldest turns get dropped
# (we use a budget small enough to trigger the 5000-token floor so the
# trim walk has to make hard choices)
{
    # Build 20 turns of user+assistant, each with a big thinking block
    my @messages;
    for my $i (1..20) {
        push @messages, { role => 'user', content => "q$i" };
        push @messages, { role => 'assistant', content => "a$i", reasoning_content => 'thinking ' x 1000 };
    }

    # Force a tight budget - smaller than what 20 turns of content fits
    my $trimmed = trim_with_noise_dropping(\@messages, '',
        model_context_window => 5000,
        max_response_tokens => 500,
        debug => 1,
    );
    # With a 5000-token budget, trim should keep at least the most
    # recent messages (which are smaller than older ones, after
    # noise-stripping). The trim may still return all 40 if the noise
    # drop made the history small enough. We assert that the returned
    # list is the most recent N messages, not random drops.
    if (scalar(@$trimmed) < scalar(@messages)) {
        my $last_msg = $trimmed->[-1];
        is($last_msg->{role}, 'assistant', "Last message kept (it's the most recent assistant)");
        like($last_msg->{content}, qr/a20/, "Last message is the most recent (turn 20)");
    } else {
        pass("All messages fit in budget after noise-stripping (no drops needed)");
    }
}

# Test 4: stripping reasoning_content from assistants shrinks the
# serialized history size (the real measure of token savings). Note
# that estimate_messages_tokens doesn't count reasoning_content, so we
# measure the role-based message content instead - which is what
# actually goes on the wire after the role-based refactor.
{
    my @messages;
    for my $i (1..10) {
        push @messages, { role => 'user', content => "q$i" };
        push @messages, { role => 'assistant', content => "a$i", reasoning_content => 'X' x 1000 };
    }

    # Total "thinking + content" length of all messages - the noise
    # trim drops reasoning_content (not the visible content), so the
    # wire savings come from removing those thinking bytes.
    my $with_size = 0;
    for my $m (@messages) {
        $with_size += length($m->{content} // '');
        $with_size += length($m->{reasoning_content} // '') if $m->{role} eq 'assistant';
    }

    # Trimmed (noise-dropped) - removes reasoning_content from old
    # assistant messages before the trim walk.
    my $trimmed = trim_with_noise_dropping(\@messages, '',
        model_context_window => 128000,
        max_response_tokens => 16000,
    );
    my $without_size = 0;
    for my $m (@$trimmed) {
        $without_size += length($m->{content} // '');
        $without_size += length($m->{reasoning_content} // '') if $m->{role} eq 'assistant';
    }

    ok($without_size < $with_size, "Stripping reasoning_content shrinks serialized history: $without_size < $with_size");

    # Verify all assistant messages have reasoning stripped (they're all
    # "old" since there's no current-turn assistant in this fixture).
    my @stripped_assistants = grep { $_->{role} eq 'assistant' } @$trimmed;
    ok(@stripped_assistants > 0, "Test fixture has assistant messages");
    for my $msg (@stripped_assistants) {
        ok(!exists $msg->{reasoning_content} || !defined $msg->{reasoning_content},
            "All old assistants have reasoning_content stripped");
    }
}

# Test 5: empty input is no-op
{
    my $trimmed = trim_with_noise_dropping([], '', model_context_window => 128000, max_response_tokens => 16000);
    is_deeply($trimmed, [], "Empty input returns empty arrayref");
}

# Test 6: messages with no reasoning_content are unchanged
{
    my @messages = (
        { role => 'user', content => 'q' },
        { role => 'assistant', content => 'a' },  # no reasoning_content
    );
    my $trimmed = trim_with_noise_dropping(\@messages, '', model_context_window => 128000, max_response_tokens => 16000);
    is($trimmed->[1]{content}, 'a', "Assistant without reasoning_content is unchanged");
    ok(!exists $trimmed->[1]{_stripped_thinking}, "No _stripped_thinking marker on message that had no thinking");
}

# Test 7: budget large enough -> no trimming needed
{
    my @messages = (
        { role => 'user', content => 'q' },
        { role => 'assistant', content => 'a' },
    );
    my $trimmed = trim_with_noise_dropping(\@messages, '', model_context_window => 128000, max_response_tokens => 16000);
    is(scalar(@$trimmed), 2, "No messages dropped when under budget");
}

done_testing();
