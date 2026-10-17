#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
use strict;
use warnings;
use utf8;
use lib '../../lib';
use Test::More;
use CLIO::Core::ContextBuilder;

*collapse = \&CLIO::Core::ContextBuilder::collapse_repeated_tool_calls_across_turns;

# Helper: build a "pure tool turn" with optional user content override.
sub turn {
    my ($user_content, $tool_name, $tool_args, $tool_result) = @_;
    $user_content   //= 'read the file';
    $tool_name      //= 'file_operations';
    $tool_args      //= '{"operation":"read_file","path":"test.txt"}';
    $tool_result     //= 'file contents';
    return [
        { role => 'user', content => $user_content },
        { role => 'assistant', content => 'Reading file.',
          tool_calls => [{ id => 'call_x', type => 'function',
            function => { name => $tool_name, arguments => $tool_args } }],
        },
        { role => 'tool', tool_call_id => 'call_x', content => $tool_result },
    ];
}

subtest 'duplicate turn collapsed, user message preserved' => sub {
    my @turns = (
        turn('read the file', 'file_operations', '{"p":"test.txt"}', 'contents here'),
        turn('continue',      'file_operations', '{"p":"test.txt"}', 'contents here'),
    );

    my $result = collapse(\@turns);
    is(scalar(@$result), 1, 'One turn emitted (duplicate collapsed)');

    # The previous turn should now have the continuation user message appended
    my $prev_turn = $result->[0];
    # Count user messages in the preserved turn
    my $user_count = grep { $_->{role} eq 'user' } @$prev_turn;
    is($user_count, 2, 'Previous turn has 2 user messages (original + continuation)');

    # The continuation message content is preserved
    my @user_msgs = grep { $_->{role} eq 'user' } @$prev_turn;
    is($user_msgs[1]{content}, 'continue', 'Continuation user message content preserved');
};

subtest 'duplicate turn collapsed, user message content not empty' => sub {
    my @turns = (
        turn('read the file', 'file_operations', '{"path":"a.txt"}', 'aaa'),
        turn('continue',      'file_operations', '{"path":"a.txt"}', 'aaa'),
    );

    my $result = collapse(\@turns);
    is(scalar(@$result), 1, 'One turn emitted');

    my $prev_turn = $result->[0];
    my @user_msgs = grep { $_->{role} eq 'user' } @$prev_turn;
    is($user_msgs[1]{content}, 'continue', 'User said "continue" - preserved, not lost');
};

subtest 'non-duplicate turns are not collapsed' => sub {
    my @turns = (
        turn('read the file', 'file_operations', '{"path":"a.txt"}', 'aaa'),
        turn('read the file', 'file_operations', '{"path":"b.txt"}', 'bbb'),
    );

    my $result = collapse(\@turns);
    is(scalar(@$result), 2, 'Two turns emitted (different results)');
};

subtest 'non-continuation prompt prevents collapse' => sub {
    my @turns = (
        turn('read the file', 'file_operations', '{"path":"a.txt"}', 'aaa'),
        turn('what does the file say?', 'file_operations', '{"path":"a.txt"}', 'aaa'),
    );

    my $result = collapse(\@turns);
    is(scalar(@$result), 2, 'Two turns emitted (second has question, not continuation)');
};

subtest 'single turn is untouched' => sub {
    my @turns = (turn('read the file', 'file_operations', '{"path":"a.txt"}', 'aaa'));
    my $result = collapse(\@turns);
    is(scalar(@$result), 1, 'Single turn preserved');
};

subtest 'empty input returns empty' => sub {
    my $result = collapse([]);
    is(scalar(@$result), 0, 'Empty input returns empty');
};

subtest 'user message is a copy, not a shared ref' => sub {
    my @turns = (
        turn('read the file', 'file_operations', '{"path":"a.txt"}', 'aaa'),
        turn('continue',      'file_operations', '{"path":"a.txt"}', 'aaa'),
    );

    my $result = collapse(\@turns);
    # The original second turn's user message should still exist
    is($turns[1][0]{content}, 'continue', 'Source turn user msg unchanged');
};

done_testing();
