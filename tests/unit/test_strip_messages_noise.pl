#!/usr/bin/perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Tests for strip_messages_noise, the history noise-stripping step.
#
# History keeps reasoning fields for display and audit. They must not be
# carried into the prompt: they are the model's private thinking for calls
# that already happened, and providers bill every one of those tokens.
#
# Validates:
# 1. reasoning_content, reasoning_details, and reasoning_blocks are
#    stripped from assistant messages
# 2. the caller's history is not mutated (stripping returns copies)
# 3. message count and order are unchanged (this is not a trim)
# 4. user text and tool results are never touched
# 5. non-array input is handled

use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/../../lib";
use Test::More;
use CLIO::Core::ConversationManager qw(strip_messages_noise);

subtest 'assistant reasoning fields are stripped' => sub {
    my @messages = (
        { role => 'user', content => 'q1' },
        { role => 'assistant', content => 'a1',
          reasoning_content => 'lots of thinking here ' x 100 },
        { role => 'assistant', content => 'a2',
          reasoning_details => [ { type => 'reasoning.text', text => 'detail ' x 50 } ] },
        { role => 'assistant', content => 'a3',
          reasoning_blocks => [ { thinking => 'block ' x 50 } ] },
        { role => 'user', content => 'q2' },
    );

    my $out = strip_messages_noise(\@messages);

    is(scalar(@$out), scalar(@messages), 'no messages dropped or added');
    for my $msg (@$out) {
        next unless $msg->{role} eq 'assistant';
        ok(!exists $msg->{reasoning_content}, 'reasoning_content stripped');
        ok(!exists $msg->{reasoning_details}, 'reasoning_details stripped');
        ok(!exists $msg->{reasoning_blocks}, 'reasoning_blocks stripped');
        is($msg->{_stripped_thinking}, 1, 'stripped marker set');
    }
};

subtest 'the caller history is not mutated' => sub {
    my @messages = (
        { role => 'assistant', content => 'a',
          reasoning_content => 'keep me in history' },
    );

    my $out = strip_messages_noise(\@messages);

    is($messages[0]{reasoning_content}, 'keep me in history',
        'original message keeps its reasoning');
    is($out->[0]{content}, 'a', 'copy carries the content');
    ok($out->[0] != $messages[0], 'copy is a different hashref');
};

subtest 'user text and tool results are untouched' => sub {
    my @messages = (
        { role => 'user', content => 'question text' },
        { role => 'assistant', content => '',
          tool_calls => [ { id => 'c1', function => { name => 'read_file', arguments => '{}' } } ] },
        { role => 'tool', content => 'big file content ' x 200, tool_call_id => 'c1' },
    );

    my $out = strip_messages_noise(\@messages);

    is($out->[0]{content}, 'question text', 'user content preserved');
    is($out->[2]{content}, 'big file content ' x 200, 'tool result preserved');
    is(scalar(@{$out->[1]{tool_calls}}), 1, 'tool_calls preserved');
};

subtest 'non-array and empty input' => sub {
    is_deeply(strip_messages_noise(undef), [], 'undef -> empty array');
    is_deeply(strip_messages_noise([]), [], 'empty -> empty array');
};

done_testing();
