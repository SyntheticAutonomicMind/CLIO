#!/usr/bin/env perl
# Test CLIO::Core::ConversationManager - conversation history management
#
# Tests all exported functions: load_conversation_history, trim_conversation_for_api,
# enforce_message_alternation, inject_context_files, generate_tool_call_id,
# repair_tool_call_json

use strict;
use warnings;
use lib './lib';
use Test::More;
use File::Temp qw(tempdir tempfile);

use CLIO::Core::ConversationManager qw(
    load_conversation_history
    trim_conversation_for_api
    enforce_message_alternation
    inject_context_files
    generate_tool_call_id
    repair_tool_call_json
);

# =============================================================================
# load_conversation_history tests
# =============================================================================

subtest 'load_conversation_history - empty/undef session' => sub {
    my $result = load_conversation_history(undef);
    is_deeply($result, [], 'undef session returns empty array');

    $result = load_conversation_history({});
    is_deeply($result, [], 'empty hash session returns empty array');
};

subtest 'load_conversation_history - hash session' => sub {
    my $session = {
        conversation_history => [
            { role => 'user', content => 'hello' },
            { role => 'assistant', content => 'hi there' },
        ]
    };

    my $result = load_conversation_history($session);
    is(scalar(@$result), 2, 'Returns 2 messages from hash session');
    is($result->[0]{role}, 'user', 'First message is user');
    is($result->[1]{role}, 'assistant', 'Second message is assistant');
};

subtest 'load_conversation_history - filters system messages' => sub {
    my $session = {
        conversation_history => [
            { role => 'system', content => 'You are helpful' },
            { role => 'user', content => 'hello' },
            { role => 'assistant', content => 'hi' },
        ]
    };

    my $result = load_conversation_history($session);
    is(scalar(@$result), 2, 'System message filtered out');
    is($result->[0]{role}, 'user', 'First message is user after filtering');
};

subtest 'load_conversation_history - tool message without tool_call_id' => sub {
    my $session = {
        conversation_history => [
            { role => 'user', content => 'run a test' },
            { role => 'assistant', content => '', tool_calls => [{ id => 'call_abc', function => { name => 'test' } }] },
            { role => 'tool', content => 'result' },  # Missing tool_call_id
        ]
    };

    my $result = load_conversation_history($session);
    # Tool message without tool_call_id should be filtered, and assistant tool_calls
    # should be stripped since orphaned
    my $tool_count = grep { $_->{role} eq 'tool' } @$result;
    is($tool_count, 0, 'Tool message without tool_call_id filtered out');
};

subtest 'load_conversation_history - preserves tool correlation' => sub {
    my $session = {
        conversation_history => [
            { role => 'user', content => 'read file' },
            { role => 'assistant', content => '', tool_calls => [{ id => 'call_123', function => { name => 'read' } }] },
            { role => 'tool', content => 'file content', tool_call_id => 'call_123' },
            { role => 'assistant', content => 'Here is the file' },
        ]
    };

    my $result = load_conversation_history($session);
    is(scalar(@$result), 4, 'All 4 messages preserved');

    # Verify tool_calls preserved on assistant message
    ok($result->[1]{tool_calls}, 'tool_calls preserved on assistant message');
    is($result->[2]{tool_call_id}, 'call_123', 'tool_call_id preserved on tool message');
};

subtest 'load_conversation_history - orphaned tool_calls removed' => sub {
    my $session = {
        conversation_history => [
            { role => 'user', content => 'do something' },
            { role => 'assistant', content => '', tool_calls => [{ id => 'call_orphan', function => { name => 'test' } }] },
            # No matching tool result follows
            { role => 'user', content => 'next message' },
        ]
    };

    my $result = load_conversation_history($session);
    # Assistant message should have tool_calls stripped (orphaned)
    my $assistant = (grep { $_->{role} eq 'assistant' } @$result)[0];
    ok(!$assistant->{tool_calls}, 'Orphaned tool_calls removed from assistant message');
};

subtest 'load_conversation_history - orphaned tool_results removed' => sub {
    my $session = {
        conversation_history => [
            { role => 'user', content => 'do something' },
            { role => 'tool', content => 'result', tool_call_id => 'call_nonexistent' },
            { role => 'assistant', content => 'done' },
        ]
    };

    my $result = load_conversation_history($session);
    my $tool_count = grep { $_->{role} eq 'tool' } @$result;
    is($tool_count, 0, 'Orphaned tool_result removed');
};

# =============================================================================
# enforce_message_alternation tests
# =============================================================================

subtest 'enforce_message_alternation - merges consecutive same-role' => sub {
    my @messages = (
        { role => 'user', content => 'First' },
        { role => 'user', content => 'Second' },
        { role => 'assistant', content => 'Response' },
    );

    my $result = enforce_message_alternation(\@messages, 'github_copilot');
    is(scalar(@$result), 2, 'Two consecutive user messages merged into one');
    like($result->[0]{content}, qr/First/, 'Merged message contains first');
    like($result->[0]{content}, qr/Second/, 'Merged message contains second');
};

subtest 'enforce_message_alternation - preserves tool messages for github' => sub {
    my @messages = (
        { role => 'user', content => 'hello' },
        { role => 'assistant', content => '', tool_calls => [{ id => 'call_1', function => { name => 'test' } }] },
        { role => 'tool', content => 'result', tool_call_id => 'call_1' },
        { role => 'assistant', content => 'done' },
    );

    my $result = enforce_message_alternation(\@messages, 'github_copilot');
    my $tool_count = grep { $_->{role} eq 'tool' } @$result;
    is($tool_count, 1, 'Tool message preserved for github_copilot provider');
};

subtest 'enforce_message_alternation - converts tool to user for non-github' => sub {
    my @messages = (
        { role => 'user', content => 'hello' },
        { role => 'assistant', content => 'calling tool', tool_calls => [{ id => 'call_1', function => { name => 'test' } }] },
        { role => 'tool', content => 'result', tool_call_id => 'call_1' },
        { role => 'assistant', content => 'done' },
    );

    my $result = enforce_message_alternation(\@messages, 'anthropic');
    my $tool_count = grep { $_->{role} eq 'tool' } @$result;
    is($tool_count, 0, 'No tool role messages for anthropic provider');

    # Assistant messages should not have tool_calls (stripped)
    for my $msg (@$result) {
        if ($msg->{role} eq 'assistant') {
            ok(!$msg->{tool_calls}, 'tool_calls stripped from assistant for anthropic');
        }
    }
};

subtest 'enforce_message_alternation - empty input' => sub {
    my $result = enforce_message_alternation([], 'github_copilot');
    is_deeply($result, [], 'Empty input returns empty');

    $result = enforce_message_alternation(undef, 'github_copilot');
    ok(!defined($result) || !@$result, 'Undef input returns empty/undef');
};

# =============================================================================
# inject_context_files tests
# =============================================================================

subtest 'inject_context_files - adds context to messages' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    my $tmpfile = "$tmpdir/test_context.txt";
    open my $fh, '>', $tmpfile or die "Cannot create temp file: $!";
    print $fh "This is context file content.";
    close $fh;

    my $session = { context_files => [$tmpfile] };
    my @messages = ();

    inject_context_files($session, \@messages);

    is(scalar(@messages), 1, 'One context message injected');
    is($messages[0]{role}, 'user', 'Context injected as user message');
    like($messages[0]{content}, qr/CONTEXT FILES/, 'Contains context header');
    like($messages[0]{content}, qr/This is context file content/, 'Contains file content');
};

subtest 'inject_context_files - no context files' => sub {
    my @messages = ();
    inject_context_files({}, \@messages);
    is(scalar(@messages), 0, 'No messages added when no context files');

    inject_context_files(undef, \@messages);
    is(scalar(@messages), 0, 'No messages added for undef session');
};

subtest 'inject_context_files - missing file handled' => sub {
    my $session = { context_files => ['/nonexistent/file.txt'] };
    my @messages = ();

    inject_context_files($session, \@messages);
    is(scalar(@messages), 0, 'Missing file does not add message');
};

# =============================================================================
# generate_tool_call_id tests
# =============================================================================

subtest 'generate_tool_call_id - format and uniqueness' => sub {
    my $id1 = generate_tool_call_id();
    my $id2 = generate_tool_call_id();

    like($id1, qr/^call_[a-f0-9]{24}$/, 'ID matches expected format');
    isnt($id1, $id2, 'Two generated IDs are different');
};

# =============================================================================
# repair_tool_call_json tests
# =============================================================================

subtest 'repair_tool_call_json - missing values' => sub {
    my $result = repair_tool_call_json('{"offset":,"length":8192}');
    ok(defined $result, 'Missing value repaired');
    like($result, qr/"offset":\s*null/, 'Missing value replaced with null');
};

subtest 'repair_tool_call_json - trailing commas' => sub {
    my $result = repair_tool_call_json('{"name":"test","value":42}');
    ok(defined $result, 'Trailing comma repaired');
};

subtest 'repair_tool_call_json - decimal without leading zero' => sub {
    my $result = repair_tool_call_json('{"progress":0.5}');
    ok(defined $result, 'Decimal without leading zero repaired');
    like($result, qr/0\.5/, 'Leading zero added');
};

subtest 'repair_tool_call_json - negative decimal without leading zero' => sub {
    my $result = repair_tool_call_json('{"value":-0.5}');
    ok(defined $result, 'Negative decimal repaired');
    like($result, qr/-0\.5/, 'Leading zero added to negative');
};

subtest 'repair_tool_call_json - valid json unchanged' => sub {
    my $input = '{"name":"test","value":42}';
    my $result = repair_tool_call_json($input);
    ok(defined $result, 'Valid JSON returns defined');
    is($result, $input, 'Valid JSON unchanged');
};

subtest 'repair_tool_call_json - undef input' => sub {
    my $result = repair_tool_call_json(undef);
    ok(!defined $result, 'Undef input returns undef');
};

subtest 'repair_tool_call_json - unrepairable json' => sub {
    my $result = repair_tool_call_json('not json at all {{{');
    ok(!defined $result, 'Unrepairable JSON returns undef');
};

done_testing();
