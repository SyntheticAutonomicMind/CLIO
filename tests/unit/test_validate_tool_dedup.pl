#!/usr/bin/perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression coverage for validate_tool_message_pairs deduplication.

use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/../../lib";

use Test::More;
use CLIO::Core::API::MessageValidator qw(validate_tool_message_pairs);

subtest 'No changes when valid' => sub {
    my $messages = [
        { role => 'user', content => 'hi' },
        { role => 'assistant', content => '',
          tool_calls => [
              { id => 'tc_a', function => { name => 'read_file', arguments => '{}' } },
          ] },
        { role => 'tool', tool_call_id => 'tc_a', content => 'result a' },
    ];
    my $out = validate_tool_message_pairs($messages);
    is(scalar(@$out), 3, 'No changes when no orphans and no duplicates');
};

subtest 'Duplicate within one assistant' => sub {
    my $messages = [
        { role => 'user', content => 'hi' },
        { role => 'assistant', content => '',
          tool_calls => [
              { id => 'tc_dup', function => { name => 'read_file', arguments => '{}' } },
              { id => 'tc_dup', function => { name => 'read_file', arguments => '{}' } },
          ] },
    ];
    my $out = validate_tool_message_pairs($messages);
    is(scalar(@$out), 2, 'Returns 2 messages');
    is(scalar(@{$out->[1]{tool_calls}}), 1, 'Assistant has 1 tool_call after dedup');
    is($out->[1]{tool_calls}[0]{id}, 'tc_dup', 'First occurrence kept');
};

subtest 'Duplicate across messages' => sub {
    my $messages = [
        { role => 'user', content => 'hi' },
        { role => 'assistant', content => '',
          tool_calls => [{ id => 'tc_x', function => { name => 'a', arguments => '{}' } }] },
        { role => 'tool', tool_call_id => 'tc_x', content => 'r1' },
        { role => 'assistant', content => '',
          tool_calls => [{ id => 'tc_x', function => { name => 'b', arguments => '{}' } }] },
    ];
    my $out = validate_tool_message_pairs($messages);
    is(scalar(@$out), 4, '4 messages after dedup');
    is($out->[1]{tool_calls}[0]{id}, 'tc_x', 'First assistant kept tc_x');
    ok(!$out->[3]{tool_calls}, 'Second assistant has no tool_calls');
};

subtest 'Orphan plus duplicate both dropped' => sub {
    my $messages = [
        { role => 'user', content => 'hi' },
        { role => 'assistant', content => '',
          tool_calls => [
              { id => 'tc_orphan', function => { name => 'a', arguments => '{}' } },
              { id => 'tc_dup', function => { name => 'b', arguments => '{}' } },
          ] },
        { role => 'tool', tool_call_id => 'tc_dup', content => 'r1' },
        { role => 'assistant', content => '',
          tool_calls => [{ id => 'tc_dup', function => { name => 'c', arguments => '{}' } }] },
    ];
    my $out = validate_tool_message_pairs($messages);
    # 4 messages: user + assistant1 (1 tool_call) + tool + assistant2 (no tool_calls).
    # tc_orphan dropped (orphan); assistant1 keeps tc_dup; assistant2's
    # tc_dup dropped (already kept by assistant1).
    is(scalar(@$out), 4, 'All 4 messages retained (tool_calls pruned in place)');
    is(scalar(@{$out->[1]{tool_calls}}), 1, 'assistant1 kept tc_dup only');
    is($out->[1]{tool_calls}[0]{id}, 'tc_dup', 'tc_dup survived in assistant1');
    ok(!$out->[3]{tool_calls}, 'assistant2 lost its dup tc_dup');
    is($out->[2]{tool_call_id}, 'tc_dup', 'tool result for tc_dup retained');
};

subtest 'Multiple dups collapse to one' => sub {
    my $messages = [
        { role => 'user', content => 'hi' },
        { role => 'assistant', content => '',
          tool_calls => [
              { id => 'tc_repeat', function => { name => 'a', arguments => '{}' } },
              { id => 'tc_repeat', function => { name => 'b', arguments => '{}' } },
              { id => 'tc_repeat', function => { name => 'c', arguments => '{}' } },
          ] },
    ];
    my $out = validate_tool_message_pairs($messages);
    is(scalar(@{$out->[1]{tool_calls}}), 1, '3 dups reduced to 1 kept');
};

subtest 'Distinct ids no dups' => sub {
    my $messages = [
        { role => 'user', content => 'hi' },
        { role => 'assistant', content => '',
          tool_calls => [
              { id => 'tc_1', function => { name => 'a', arguments => '{}' } },
              { id => 'tc_2', function => { name => 'b', arguments => '{}' } },
          ] },
        { role => 'tool', tool_call_id => 'tc_1', content => 'r1' },
        { role => 'tool', tool_call_id => 'tc_2', content => 'r2' },
    ];
    my $out = validate_tool_message_pairs($messages);
    is(scalar(@$out), 4, 'No dups or orphans: unchanged');
    is(scalar(@{$out->[1]{tool_calls}}), 2, '2 tool_calls preserved');
};

subtest 'Orphan tool_result still removed' => sub {
    my $messages = [
        { role => 'user', content => 'hi' },
        { role => 'tool', tool_call_id => 'tc_ghost', content => 'orphan' },
        { role => 'assistant', content => 'after' },
    ];
    my $out = validate_tool_message_pairs($messages);
    is(scalar(@$out), 2, 'Orphan tool_result removed');
    is($out->[1]{role}, 'assistant', 'assistant follows user');
};

done_testing();
