#!/usr/bin/perl
use strict;
use warnings;
use utf8;
use Test::More;

use CLIO::Core::API::MessageValidator qw(_validate_or_passthrough);

# Test 1: Clean messages (no tool_calls or tool_results) should pass through unchanged.
subtest 'clean messages pass through (byte stable)' => sub {
    my @clean = (
        { role => 'user',      content => 'hello' },
        { role => 'assistant', content => 'hi there' },
        { role => 'user',      content => 'bye' },
    );
    my $result = _validate_or_passthrough(\@clean);
    # Must be the EXACT same reference — no re-serialization.
    ok($result == \@clean, 'returns same arrayref for clean messages');
};

# Test 2: Valid tool pairs should also pass through unchanged.
subtest 'valid tool pairs pass through (byte stable)' => sub {
    my @valid = (
        { role => 'user',      content => 'do something' },
        { role => 'assistant', content => 'ok', tool_calls => [
            { id => 'call_1', type => 'function', function => { name => 'test', arguments => '{}' } },
        ]},
        { role => 'tool',      content => 'result1', tool_call_id => 'call_1' },
    );
    my $result = _validate_or_passthrough(\@valid);
    ok($result == \@valid, 'returns same arrayref for valid tool pairs');
};

# Test 3: Orphaned tool_call (no matching tool result) triggers re-serialization.
subtest 'orphaned tool_call triggers re-serialization' => sub {
    my @orphaned = (
        { role => 'user',      content => 'do something' },
        { role => 'assistant', content => 'ok', tool_calls => [
            { id => 'call_1', type => 'function', function => { name => 'test', arguments => '{}' } },
        ]},
        # No tool result for call_1 — orphaned
    );
    my $original_ref = \@orphaned;
    my $result = _validate_or_passthrough($original_ref);
    ok($result != $original_ref, 'orphaned tool_call causes re-serialization (different ref)');
};

# Test 4: Orphaned tool_result (no matching tool call) triggers re-serialization.
subtest 'orphaned tool_result triggers re-serialization' => sub {
    my @orphan_result = (
        { role => 'user',  content => 'hello' },
        { role => 'tool',  content => 'result', tool_call_id => 'nonexistent' },
    );
    my $original_ref = \@orphan_result;
    my $result = _validate_or_passthrough($original_ref);
    ok($result != $original_ref, 'orphaned tool_result causes re-serialization');
    # The orphaned tool result should have been removed entirely.
    is(scalar(@$result), 1, 'orphaned tool_result was removed (1 msg left)');
    is($result->[0]{role}, 'user', 'user message preserved');
};

# Test 5: Duplicate tool_call_ids trigger re-serialization.
subtest 'duplicate tool_call_ids trigger re-serialization' => sub {
    my @dupes = (
        { role => 'user',      content => 'do something' },
        { role => 'assistant', content => 'ok', tool_calls => [
            { id => 'call_1', type => 'function', function => { name => 'test', arguments => '{}' } },
        ]},
        { role => 'tool',      content => 'result1', tool_call_id => 'call_1' },
        { role => 'assistant', content => 'ok2', tool_calls => [
            { id => 'call_1', type => 'function', function => { name => 'test2', arguments => '{}' } },
        ]},
        { role => 'tool',      content => 'result2', tool_call_id => 'call_1' },
    );
    my $original_ref = \@dupes;
    my $result = _validate_or_passthrough($original_ref);
    ok($result != $original_ref, 'duplicate IDs cause re-serialization');
    # The second assistant has a duplicate call_1 id. validate_tool_message_pairs
    # keeps the first occurrence of each id and strips the duplicate.
    # Result: user, assistant(call_1), tool(call_1), assistant(stripped to plain), tool(result2)
    # The second assistant's tool_call is stripped (duplicate id), its content stays.
    is(scalar(@$result), 5, '5 messages after dedup (second assistant stripped, not removed)');
    is($result->[1]{role}, 'assistant', 'first assistant preserved');
    is($result->[3]{role}, 'assistant', 'second assistant preserved as plain (dup tool_call stripped)');
};

# Test 6: Empty messages array returns as-is.
subtest 'empty messages returns as-is' => sub {
    my @empty = ();
    my $result = _validate_or_passthrough(\@empty);
    ok($result == \@empty, 'empty array returns same ref');
};

# Test 7: undef messages returns as-is.
subtest 'undef messages returns as-is' => sub {
    my $result = _validate_or_passthrough(undef);
    ok(!defined $result || $result eq '', 'undef returns undef/empty');
};

# Test 8: Messages with tool_calls that have no id field should pass through.
subtest 'tool_calls without id field pass through' => sub {
    my @no_id = (
        { role => 'user',      content => 'hello' },
        { role => 'assistant', content => 'ok', tool_calls => [
            { type => 'function', function => { name => 'test', arguments => '{}' } },
            # No id field — not tracked as orphan/dupe
        ]},
    );
    my $result = _validate_or_passthrough(\@no_id);
    ok($result == \@no_id, 'messages with idless tool_calls pass through (byte stable)');
};

done_testing();
