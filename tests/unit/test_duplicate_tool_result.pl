#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;
use lib '../../lib';
use Test::More;

use CLIO::Core::API::MessageValidator qw(
    validate_tool_message_pairs
    preflight_validate
);

# --- preflight_validate: duplicate tool_result detection ---

# Baseline: valid single tool call -> result pair
{
    my $messages = [
        { role => 'user', content => 'Hello' },
        { role => 'assistant', content => 'Hi',
          tool_calls => [{ id => 'tc_1', type => 'function', function => { name => 'test', arguments => '{}' } }] },
        { role => 'tool', tool_call_id => 'tc_1', content => 'result' },
    ];
    my $errors = preflight_validate($messages);
    is(scalar @$errors, 0, "Valid pair: no errors");
}

# Duplicate tool_result (same tool_call_id, two result messages)
{
    my $messages = [
        { role => 'user', content => 'Hello' },
        { role => 'assistant', content => 'Hi',
          tool_calls => [{ id => 'tc_dup', type => 'function', function => { name => 'test', arguments => '{}' } }] },
        { role => 'tool', tool_call_id => 'tc_dup', content => 'first result' },
        { role => 'tool', tool_call_id => 'tc_dup', content => 'second result' },
    ];
    my $errors = preflight_validate($messages);
    ok(grep(/Duplicate tool_result_id/, @$errors), "Duplicate tool_result_id detected by preflight_validate");
}

# Duplicate tool_result with identical contents
{
    my $messages = [
        { role => 'user', content => 'Hello' },
        { role => 'assistant', content => 'Hi',
          tool_calls => [{ id => 'tc_same', type => 'function', function => { name => 'test', arguments => '{}' } }] },
        { role => 'tool', tool_call_id => 'tc_same', content => 'same' },
        { role => 'tool', tool_call_id => 'tc_same', content => 'same' },
    ];
    my $errors = preflight_validate($messages);
    ok(grep(/Duplicate tool_result_id: tc_same/, @$errors), "Duplicate tool_result with identical contents detected");
}

# Duplicate tool_result with different contents
{
    my $messages = [
        { role => 'user', content => 'Hello' },
        { role => 'assistant', content => 'Hi',
          tool_calls => [{ id => 'tc_diff', type => 'function', function => { name => 'test', arguments => '{}' } }] },
        { role => 'tool', tool_call_id => 'tc_diff', content => 'content_one' },
        { role => 'tool', tool_call_id => 'tc_diff', content => 'content_two' },
    ];
    my $errors = preflight_validate($messages);
    ok(grep(/Duplicate tool_result_id: tc_diff/, @$errors), "Duplicate tool_result with different contents detected");
}

# Two unrelated calls with distinct IDs — should be valid
{
    my $messages = [
        { role => 'user', content => 'Hello' },
        { role => 'assistant', content => 'Hi',
          tool_calls => [
              { id => 'call_a', type => 'function', function => { name => 'test', arguments => '{}' } },
              { id => 'call_b', type => 'function', function => { name => 'test', arguments => '{}' } },
          ] },
        { role => 'tool', tool_call_id => 'call_a', content => 'result_a' },
        { role => 'tool', tool_call_id => 'call_b', content => 'result_b' },
    ];
    my $errors = preflight_validate($messages);
    is(scalar @$errors, 0, "Two distinct calls with distinct results: no errors");
}

# Orphan result (no matching tool_call) + duplicate result
{
    my $messages = [
        { role => 'user', content => 'Hello' },
        { role => 'tool', tool_call_id => 'orphan_1', content => 'no call for me' },
        { role => 'tool', tool_call_id => 'orphan_1', content => 'duplicate orphan' },
    ];
    my $errors = preflight_validate($messages);
    ok(grep(/Duplicate tool_result_id: orphan_1/, @$errors), "Duplicate orphan result detected");
    ok(grep(/Orphaned tool_result: orphan_1/, @$errors), "Orphaned result also detected");
}

# --- validate_tool_message_pairs: duplicate tool_result removal ---

# Duplicate tool_result: first occurrence kept, second dropped
{
    my $messages = [
        { role => 'user', content => 'Hello' },
        { role => 'assistant', content => 'Hi',
          tool_calls => [{ id => 'tc_keep', type => 'function', function => { name => 'test', arguments => '{}' } }] },
        { role => 'tool', tool_call_id => 'tc_keep', content => 'first result' },
        { role => 'tool', tool_call_id => 'tc_keep', content => 'duplicate result' },
        { role => 'assistant', content => 'All done' },
    ];
    my $validated = validate_tool_message_pairs($messages);
    is(scalar @$validated, 4, "Duplicate tool_result: second occurrence removed (4 messages remain)");
    is($validated->[2]{content}, 'first result', "First result kept, content correct");
    is($validated->[3]{role}, 'assistant', "Assistant message after results preserved");
}

# Duplicate tool_result with identical contents: first kept, second dropped
{
    my $messages = [
        { role => 'user', content => 'Hello' },
        { role => 'assistant', content => 'Hi',
          tool_calls => [{ id => 'tc_identical', type => 'function', function => { name => 'test', arguments => '{}' } }] },
        { role => 'tool', tool_call_id => 'tc_identical', content => 'same' },
        { role => 'tool', tool_call_id => 'tc_identical', content => 'same' },
    ];
    my $validated = validate_tool_message_pairs($messages);
    is(scalar @$validated, 3, "Duplicate identical results: second removed (3 messages)");
    is($validated->[2]{content}, 'same', "First identical result kept");
}

# Duplicate tool_call + duplicate result
{
    my $messages = [
        { role => 'user', content => 'Hello' },
        { role => 'assistant', content => 'A',
          tool_calls => [{ id => 'tc_multi', type => 'function', function => { name => 'test', arguments => '{}' } },
                           { id => 'tc_multi', type => 'function', function => { name => 'test', arguments => '{}' } }] },
        { role => 'tool', tool_call_id => 'tc_multi', content => 'result1' },
        { role => 'tool', tool_call_id => 'tc_multi', content => 'result2' },
    ];
    my $validated = validate_tool_message_pairs($messages);
    is(scalar @$validated, 3, "Duplicate calls + duplicate results: deduped to 3");
    is(scalar @{$validated->[1]{tool_calls}}, 1, "Only one tool_call kept from duplicate pair");
}

# Normal valid messages are returned unchanged (same arrayref identity)
{
    my $messages = [
        { role => 'user', content => 'Hello' },
        { role => 'assistant', content => 'Hi',
          tool_calls => [{ id => 'tc_norm', type => 'function', function => { name => 'test', arguments => '{}' } }] },
        { role => 'tool', tool_call_id => 'tc_norm', content => 'result' },
    ];
    my $validated = validate_tool_message_pairs($messages);
    is(scalar @$validated, 3, "Valid messages: unchanged count");
    is($validated, $messages, "Valid messages: same arrayref returned (no rebuild)");
}

# Three tool calls — all with distinct IDs
{
    my $messages = [
        { role => 'user', content => 'Hello' },
        { role => 'assistant', content => 'Hi',
          tool_calls => [
              { id => 'tc_x', type => 'function', function => { name => 'f1', arguments => '{}' } },
              { id => 'tc_y', type => 'function', function => { name => 'f2', arguments => '{}' } },
              { id => 'tc_z', type => 'function', function => { name => 'f3', arguments => '{}' } },
          ] },
        { role => 'tool', tool_call_id => 'tc_x', content => 'rx' },
        { role => 'tool', tool_call_id => 'tc_y', content => 'ry' },
        { role => 'tool', tool_call_id => 'tc_z', content => 'rz' },
    ];
    my $errors = preflight_validate($messages);
    is(scalar @$errors, 0, "Three distinct calls: no errors");
    my $validated = validate_tool_message_pairs($messages);
    is(scalar @$validated, 5, "Three distinct calls: all 5 messages preserved");
}

# Multiple consecutive multimodal requests — should still validate correctly
{
    my $messages = [
        { role => 'user', content => [
            { type => 'text', text => 'What is in this image?' },
            { type => 'image_url', image_url => { url => 'data:image/png;base64,AAAA' } },
        ]},
        { role => 'assistant', content => 'I see something',
          tool_calls => [{ id => 'tc_img', type => 'function', function => { name => 'describe_image', arguments => '{}' } }] },
        { role => 'tool', tool_call_id => 'tc_img', content => 'It is a cat' },
        { role => 'user', content => [
            { type => 'text', text => 'What color is it?' },
            { type => 'image_url', image_url => { url => 'data:image/png;base64,BBBB' } },
        ]},
        { role => 'assistant', content => 'It is orange',
          tool_calls => [{ id => 'tc_color', type => 'function', function => { name => 'get_color', arguments => '{}' } }] },
        { role => 'tool', tool_call_id => 'tc_color', content => 'orange' },
    ];
    my $errors = preflight_validate($messages);
    is(scalar @$errors, 0, "Multiple multimodal turns: no errors");
}

# Missing result (assistant declares tool_call but no result follows)
{
    my $messages = [
        { role => 'user', content => 'Hello' },
        { role => 'assistant', content => 'Hi',
          tool_calls => [{ id => 'tc_missing', type => 'function', function => { name => 'test', arguments => '{}' } }] },
        { role => 'user', content => 'What happened?' },
    ];
    my $errors = preflight_validate($messages);
    ok(grep(/Orphaned tool_call: tc_missing/, @$errors), "Missing result detected");
}

# Orphan result (tool message without any assistant tool_calls)
{
    my $messages = [
        { role => 'user', content => 'Hello' },
        { role => 'tool', tool_call_id => 'tc_orphan', content => 'nobody called me' },
    ];
    my $errors = preflight_validate($messages);
    ok(grep(/Orphaned tool_result: tc_orphan/, @$errors), "Orphan result detected");
}

done_testing();

print "\n";
print "━" x 60 . "\n";
print "TEST SUMMARY: Duplicate Tool-Result Detection\n";
print "━" x 60 . "\n";
print "[OK] Duplicate tool_result_id detected by preflight_validate\n";
print "[OK] Duplicate results removed by validate_tool_message_pairs\n";
print "[OK] Valid pairs and distinct IDs pass unchanged\n";
print "[OK] Multimodal messages work correctly\n";
print "━" x 60 . "\n";
