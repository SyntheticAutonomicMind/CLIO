#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test: validate_tool_message_pairs must not crash on
# non-hashref elements (strings, undef, arrayrefs) that leak in from
# corrupted session snapshots or test fixtures.
#
# Bug: validate_tool_message_pairs assumed every element of $messages
# was a hashref and accessed $msg->{role} directly. If a session
# snapshot contained a plain string (or any non-hashref element), the
# function died with "Not a HASH reference at line 759", which killed
# the model's turn mid-request and surfaced as an unrecoverable
# "API exception: Not a HASH reference" error to the user.
# Observed in session 2b80d82f (minimax-m3:free/OpenRouter,
# 2026-08-29).
#
# Fix: guard every $msg->{...} and $tc->{...} access with
# ref($msg) eq 'HASH' / ref($tc) eq 'HASH', skipping non-hashref
# elements instead of crashing.

use strict;
use warnings;
use utf8;
use lib '/home/deck/repositories/CLIO/lib';
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Test::More;
use CLIO::Core::API::MessageValidator qw(validate_tool_message_pairs);

# ── Test 1: Mixed hashref/non-hashref elements don't crash ──────────
{
    my $messages = [
        { role => 'system', content => 'system' },
        'not a hash',                          # plain string
        undef,                                  # undef element
        [ 'array', 'ref' ],                     # arrayref element
        { role => 'user', content => 'continue' },
        123,                                    # number
    ];
    my $validated = CLIO::Core::API::MessageValidator::validate_tool_message_pairs($messages);
    ok($validated, 'validate_tool_message_pairs returns a result (no crash)');
    is(ref($validated), 'ARRAY', 'Result is an arrayref');
    # The function should have skipped the non-hashref elements.
    my $non_hashes = grep { ref($_) ne 'HASH' } @$validated;
    is($non_hashes, 0, 'No non-hashref elements in the output');
    is(scalar(@$validated), 2, 'Only the 2 valid hashref messages remain');
}

# ── Test 2: Malformed tool_calls entries don't crash ───────────────
{
    my $messages = [
        {
            role => 'assistant',
            content => '',
            tool_calls => [
                { id => 'tc1', 'type' => 'function', 'function' => { name => 'file_operations' } },
                'not_a_hash',   # malformed tool_call entry
                { id => 'tc2', 'type' => 'function', 'function' => { name => 'version_control' } },
            ],
        },
        {
            role => 'tool',
            tool_call_id => 'tc1',
            content => 'tool result 1',
        },
    ];
    my $validated = validate_tool_message_pairs($messages);
    ok($validated, 'validate_tool_message_pairs returns a result');
    is(ref($validated), 'ARRAY', 'Result is an arrayref');
    # Should not crash on the malformed tool_call entry
    my $non_hashes = grep { ref($_) ne 'HASH' } @$validated;
    is($non_hashes, 0, 'No non-hashref elements in output (malformed tc skipped)');
}

# ── Test 3: Pure string elements (corrupted snapshot) ──────────────
{
    my $messages = [
        'corrupted string element',
        { role => 'user', content => 'real user msg' },
        'another corrupted',
    ];
    my $validated = validate_tool_message_pairs($messages);
    is(scalar(@$validated), 1, 'Only the 1 valid hashref remains');
    is($validated->[0]{role}, 'user', 'The valid user message is preserved');
    is($validated->[0]{content}, 'real user msg', 'Valid message content is intact');
}

# ── Test 4: Empty array ─────────────────────────────────────────────
{
    my $validated = validate_tool_message_pairs([]);
    is(ref($validated), 'ARRAY', 'Empty array returns an arrayref');
    is(scalar(@$validated), 0, 'Empty array returns empty');
}

# ── Test 5: Normal case still works (no regression) ────────────────
{
    my $messages = [
        { role => 'assistant', content => '', tool_calls => [
            { id => 'tc1', type => 'function', function => { name => 'test' } },
        ] },
        { role => 'tool', tool_call_id => 'tc1', content => 'result' },
    ];
    my $validated = validate_tool_message_pairs($messages);
    is(scalar(@$validated), 2, 'Valid paired messages are preserved (no change)');
}

done_testing();
