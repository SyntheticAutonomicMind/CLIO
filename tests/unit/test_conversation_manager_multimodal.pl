#!/usr/bin/env perl
# Unit tests for multimodal content handling in CLIO::Core::ConversationManager

use strict;
use warnings;
use utf8;
use Test::More;

use lib '../../lib';

use CLIO::Core::ConversationManager qw(
    enforce_message_alternation
    trim_conversation_for_api
    load_conversation_history
);

# Helper to create a message
sub make_msg {
    my ($role, $content, %extra) = @_;
    return {
        role => $role,
        content => $content,
        %extra
    };
}

# ===========================================
# Tests for enforce_message_alternation
# ===========================================

subtest 'enforce_message_alternation with arrayref content' => sub {
    # Two consecutive user messages where one has arrayref content
    # should NOT be merged textually - arrayref gets its own message
    my $messages = [
        make_msg('user', 'Hello'),
        make_msg('user', [
            { type => 'text', text => 'Some text content' },
        ]),
        make_msg('assistant', 'Hi there'),
    ];

    my $result = enforce_message_alternation($messages, 'test_provider');

    # Should have 3 messages (arrayref not merged with previous user)
    is(scalar(@$result), 3, 'arrayref message not merged with previous user message');

    # Second user message should retain arrayref content
    is(ref($result->[1]{content}), 'ARRAY', 'arrayref content preserved');
    is($result->[1]{content}[0]{text}, 'Some text content', 'arrayref text content correct');
};

subtest 'enforce_message_alternation with image content' => sub {
    # User message with image (arrayref with image_url part)
    my $messages = [
        make_msg('user', 'Look at this'),
        make_msg('user', [
            { type => 'text', text => 'Analyze the attached image' },
            { type => 'image_url', image_url => { url => 'data:image/png;base64,abc123' } }
        ]),
        make_msg('assistant', 'I see the image'),
    ];

    my $result = enforce_message_alternation($messages, 'test_provider');

    is(scalar(@$result), 3, 'image message not merged');
    is(ref($result->[1]{content}), 'ARRAY', 'image arrayref preserved');
    is(scalar(@{$result->[1]{content}}), 2, 'both parts preserved');
    is($result->[1]{content}[0]{type}, 'text', 'first part is text');
    is($result->[1]{content}[1]{type}, 'image_url', 'second part is image_url');
};

subtest 'enforce_message_alternation with string content (regression)' => sub {
    # Regular string content should still merge normally
    my $messages = [
        make_msg('user', 'First part'),
        make_msg('user', 'Second part'),
        make_msg('assistant', 'Response'),
    ];

    my $result = enforce_message_alternation($messages, 'test_provider');

    # Should have 2 messages (consecutive users merged)
    is(scalar(@$result), 2, 'string messages merged');
    is($result->[0]{content}, "First part\n\nSecond part", 'merged content correct');
    is($result->[0]{role}, 'user', 'merged role correct');
};

subtest 'enforce_message_alternation with empty arrayref' => sub {
    # Empty arrayref should not cause issues
    my $messages = [
        make_msg('user', 'Hello'),
        make_msg('user', []),
        make_msg('assistant', 'Hi'),
    ];

    my $result = enforce_message_alternation($messages, 'test_provider');

    # Empty arrayref is still treated as a separate message
    ok(scalar(@$result) >= 2, 'empty arrayref handled without crash');
};

subtest 'enforce_message_alternation tool messages not merged' => sub {
    # Tool messages should NOT be merged (each has unique tool_call_id)
    my $messages = [
        make_msg('user', 'Run a command'),
        make_msg('assistant', 'Running...', tool_calls => [
            { id => 'call_1', function => { name => 'run' } },
            { id => 'call_2', function => { name => 'run' } },
        ]),
        make_msg('tool', 'result 1', tool_call_id => 'call_1'),
        make_msg('tool', 'result 2', tool_call_id => 'call_2'),
    ];

    my $result = enforce_message_alternation($messages, 'test_provider');

    # Should have 4 messages (tool messages not merged)
    is(scalar(@$result), 4, 'tool messages not merged');
};

subtest 'enforce_message_alternation mixed roles' => sub {
    # Mixed arrayref and string content in consecutive messages
    my $messages = [
        make_msg('user', 'Initial'),
        make_msg('user', 'Continued text'),
        make_msg('assistant', [
            { type => 'text', text => 'Array content' },
        ]),
        make_msg('user', 'More text'),
    ];

    my $result = enforce_message_alternation($messages, 'test_provider');

    # user messages 1+2 should merge, assistant stays separate
    is(scalar(@$result), 3, 'mixed content handled correctly');
    is($result->[0]{content}, "Initial\n\nContinued text", 'string merge correct');
    is(ref($result->[1]{content}), 'ARRAY', 'arrayref not merged');
};

subtest 'enforce_message_alternation consecutive arrayref messages' => sub {
    # Two consecutive user messages both with arrayref content
    # Each should be its own message (not merged)
    my $messages = [
        make_msg('user', [
            { type => 'text', text => 'First image' },
            { type => 'image_url', image_url => { url => 'data:image/png;base64,aaa' } }
        ]),
        make_msg('user', [
            { type => 'text', text => 'Second image' },
            { type => 'image_url', image_url => { url => 'data:image/png;base64,bbb' } }
        ]),
        make_msg('assistant', 'I see both images'),
    ];

    my $result = enforce_message_alternation($messages, 'test_provider');

    # Each arrayref message should be separate
    is(scalar(@$result), 3, 'consecutive arrayref messages kept separate');
    is(ref($result->[0]{content}), 'ARRAY', 'first arrayref preserved');
    is(ref($result->[1]{content}), 'ARRAY', 'second arrayref preserved');
};

# ===========================================
# Tests for trim_conversation_for_api
# ===========================================

subtest 'trim_conversation_for_api preserves arrayref content' => sub {
    # Trimming should preserve arrayref content structure
    my $history = [
        make_msg('user', 'First message'),
        make_msg('assistant', 'Response 1'),
        make_msg('user', [
            { type => 'text', text => 'Second message with image' },
            { type => 'image_url', image_url => { url => 'data:image/png;base64,xyz' } }
        ]),
        make_msg('assistant', 'Response 2'),
    ];

    my $system_prompt = 'You are a helpful assistant';

    # Use large context so no trimming occurs
    my $result = trim_conversation_for_api($history, $system_prompt,
        model_context_window => 128000,
        max_response_tokens => 16000,
        debug => 0
    );

    # All messages should be kept with large context
    is(scalar(@$result), scalar(@$history), 'all messages kept with large context');

    # Arrayref content should be preserved
    is(ref($result->[2]{content}), 'ARRAY', 'arrayref content preserved after trim');
};

subtest 'trim_conversation_for_api handles trimming with arrayref' => sub {
    # When trimming is needed, arrayref content should still be handled
    my $history = [
        make_msg('user', 'First user message with some content'),
        make_msg('assistant', 'First assistant response'),
        make_msg('user', [
            { type => 'text', text => 'Second user with array content' },
            { type => 'image_url', image_url => { url => 'data:image/png;base64,xyz' } }
        ]),
        make_msg('assistant', 'Response to array content'),
    ];

    my $system_prompt = 'You are a helpful assistant';

    # Use small context to force trimming
    my $result = trim_conversation_for_api($history, $system_prompt,
        model_context_window => 1000,
        max_response_tokens => 100,
        debug => 0
    );

    ok($result, 'trim returns result');
    ok(scalar(@$result) >= 1, 'at least one message kept');

    # Check that any remaining arrayref content is preserved
    for my $msg (@$result) {
        if (ref($msg->{content}) eq 'ARRAY') {
            ok(scalar(@{$msg->{content}}) > 0, 'arrayref not empty after trim');
        }
    }
};

subtest 'trim_conversation_for_api empty history' => sub {
    my $result = trim_conversation_for_api([], 'System prompt');
    is_deeply($result, [], 'empty history returns empty array');
};

subtest 'trim_conversation_for_api undef history' => sub {
    my $result = trim_conversation_for_api(undef, 'System prompt');
    ok(!defined $result || ref($result) eq 'ARRAY', 'undef history handled');
};

# ===========================================
# Tests for load_conversation_history
# ===========================================

subtest 'load_conversation_history preserves arrayref content' => sub {
    my $session = {
        conversation_history => [
            { role => 'user', content => 'Hello' },
            { role => 'user', content => [
                { type => 'text', text => 'Array message' },
                { type => 'image_url', image_url => { url => 'data:image/png;base64,test' } }
            ]},
            { role => 'assistant', content => 'Hi' },
        ]
    };

    my $result = load_conversation_history($session, debug => 0);

    is(scalar(@$result), 3, 'all non-system messages loaded');
    is(ref($result->[1]{content}), 'ARRAY', 'arrayref content preserved');
    is(scalar(@{$result->[1]{content}}), 2, 'arrayref has both parts');
};

subtest 'load_conversation_history skips system messages' => sub {
    my $session = {
        conversation_history => [
            { role => 'system', content => 'System prompt' },
            { role => 'user', content => 'Hello' },
        ]
    };

    my $result = load_conversation_history($session, debug => 0);

    is(scalar(@$result), 1, 'system message skipped');
    is($result->[0]{role}, 'user', 'only user message remains');
};

subtest 'load_conversation_history handles object-based session' => sub {
    my $mock_session = MockSession->new([
        { role => 'user', content => 'Object session message' },
    ]);

    my $result = load_conversation_history($mock_session, debug => 0);

    is(scalar(@$result), 1, 'object session history loaded');
    is($result->[0]{content}, 'Object session message', 'content correct');
};

subtest 'load_conversation_history undef session' => sub {
    my $result = load_conversation_history(undef, debug => 0);
    is_deeply($result, [], 'undef session returns empty array');
};

# ===========================================
# Edge cases
# ===========================================

subtest 'enforce_message_alternation empty messages' => sub {
    my $result = enforce_message_alternation([], 'test');
    is_deeply($result, [], 'empty array handled');
};

subtest 'enforce_message_alternation single message' => sub {
    my $messages = [ make_msg('user', 'Single') ];
    my $result = enforce_message_alternation($messages, 'test');
    is(scalar(@$result), 1, 'single message preserved');
    is($result->[0]{content}, 'Single', 'content correct');
};

subtest 'arrayref content with multiple images' => sub {
    # Multiple images in one message
    my $messages = [
        make_msg('user', [
            { type => 'image_url', image_url => { url => 'data:image/png;base64,img1' } },
            { type => 'image_url', image_url => { url => 'data:image/jpeg;base64,img2' } },
            { type => 'image_url', image_url => { url => 'data:image/gif;base64,img3' } },
        ]),
        make_msg('assistant', 'I see all three images'),
    ];

    my $result = enforce_message_alternation($messages, 'test');

    is(scalar(@$result), 2, 'messages not merged');
    is(ref($result->[0]{content}), 'ARRAY', 'arrayref preserved');
    is(scalar(@{$result->[0]{content}}), 3, 'all three images preserved');
};

# ===========================================
# Pipeline protocol: system messages represent distinct sections
# (system_prompt, summary, context_files, user_context) and must NOT be
# merged by enforce_message_alternation. Merging them concatenates content
# and couples cache lifetimes — any section's regeneration invalidates the
# whole merged prompt for LCP purposes.
# ===========================================

subtest 'enforce_message_alternation does NOT merge consecutive system messages' => sub {
    my $messages = [
        make_msg('system', 'SYSTEM PROMPT: you are CLIO'),
        make_msg('system', '<thread_summary>...</thread_summary>'),
        make_msg('system', '[CONTEXT FILES] file contents...'),
        make_msg('user', 'question'),
        make_msg('assistant', 'answer'),
        make_msg('system', '<userContext>date: 2026-08-18</userContext>'),
        make_msg('user', 'next question'),
    ];

    my $result = enforce_message_alternation($messages, 'test');

    # Should have 7 messages - all system messages stay separate
    is(scalar(@$result), 7, 'all 7 messages preserved (no system merging)');

    # Verify each system message survived separately
    is($result->[0]{content}, 'SYSTEM PROMPT: you are CLIO', 'system_prompt section preserved');
    is($result->[1]{content}, '<thread_summary>...</thread_summary>', 'summary section preserved');
    is($result->[2]{content}, '[CONTEXT FILES] file contents...', 'context_files section preserved');
    is($result->[5]{content}, '<userContext>date: 2026-08-18</userContext>', 'user_context section preserved');

    # Roles should be intact
    is($result->[0]{role}, 'system', 'position 0 is system');
    is($result->[1]{role}, 'system', 'position 1 is system');
    is($result->[2]{role}, 'system', 'position 2 is system');
    is($result->[3]{role}, 'user', 'position 3 is user');
    is($result->[4]{role}, 'assistant', 'position 4 is assistant');
    is($result->[5]{role}, 'system', 'position 5 is system (user_context at fixed position)');
    is($result->[6]{role}, 'user', 'position 6 is user (current user_input)');
};

subtest 'user messages DO still merge (regression guard)' => sub {
    my $messages = [
        make_msg('system', 'sys'),
        make_msg('user', 'first'),
        make_msg('user', 'second'),
        make_msg('assistant', 'a'),
    ];

    my $result = enforce_message_alternation($messages, 'test');

    is(scalar(@$result), 3, 'system separate, users merged into one');
    is($result->[0]{role}, 'system', 'position 0 is system');
    is($result->[1]{role}, 'user', 'position 1 is user (merged)');
    like($result->[1]{content}, qr/first.*second/s, 'user messages merged');
    is($result->[2]{role}, 'assistant', 'position 2 is assistant');
};

subtest 'assistant messages DO still merge (regression guard)' => sub {
    my $messages = [
        make_msg('system', 'sys'),
        make_msg('user', 'q'),
        make_msg('assistant', 'first'),
        make_msg('assistant', 'second'),
    ];

    my $result = enforce_message_alternation($messages, 'test');

    is(scalar(@$result), 3, 'system + user + merged assistant');
    is($result->[2]{role}, 'assistant', 'position 2 is assistant (merged)');
    like($result->[2]{content}, qr/first.*second/s, 'assistant messages merged');
};

# ===========================================
# Mock session class for testing
# ===========================================

package MockSession;

sub new {
    my ($class, $history) = @_;
    return bless { _history => $history }, $class;
}

sub get_conversation_history {
    my ($self) = @_;
    return $self->{_history};
}

# Return to main package for done_testing
package main;

done_testing();