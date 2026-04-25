#!/usr/bin/env perl
# Unit tests for multimodal content handling in CLIO::Memory::TokenEstimator

use strict;
use warnings;
use utf8;
use Test::More;

use lib '../../lib';

use CLIO::Memory::TokenEstimator qw(estimate_tokens);

# Reset learned ratio before tests to ensure consistent behavior
CLIO::Memory::TokenEstimator::set_learned_ratio(4.0) if CLIO::Memory::TokenEstimator::has_learned_ratio();

# Test 1: estimate_tokens with string content (regression test)
subtest 'string content regression' => sub {
    # Basic string
    is(estimate_tokens('hello world'), 3, 'simple string: 11 chars / 4.0 = 3 tokens');

    # Empty string
    is(estimate_tokens(''), 0, 'empty string returns 0');

    # Undefined
    is(estimate_tokens(undef), 0, 'undef returns 0');

    # Longer string
    my $long_text = 'a' x 80;  # 80 chars
    is(estimate_tokens($long_text), 20, '80 chars / 4.0 = 20 tokens');
};

# Test 2: Array with text part only
subtest 'arrayref: text part only' => sub {
    my $content = [
        { type => 'text', text => 'Hello, world!' }
    ];

    # 13 chars / 4.0 = 3.25 -> ceil = 4
    is(estimate_tokens($content), 4, 'text only: 13 chars / 4.0 = 4 tokens');

    # Multiple text parts
    my $content_multi = [
        { type => 'text', text => 'First part' },     # 11 chars -> ceil(11/4) = 3
        { type => 'text', text => 'Second part' }     # 11 chars -> ceil(11/4) = 3
    ];
    is(estimate_tokens($content_multi), 6, 'multiple text parts: sum of each');
};

# Test 3: Array with image_url part only
subtest 'arrayref: image_url part only' => sub {
    my $content = [
        { type => 'image_url', image_url => { url => 'data:image/png;base64,abc123' } }
    ];

    is(estimate_tokens($content), 85, 'image_url only: 85 tokens per image');

    # Multiple images
    my $content_multi = [
        { type => 'image_url', image_url => { url => 'data:image/png;base64,abc' } },
        { type => 'image_url', image_url => { url => 'data:image/jpeg;base64,xyz' } }
    ];
    is(estimate_tokens($content_multi), 170, 'multiple images: 85 * 2 = 170 tokens');
};

# Test 4: Array with both text and image_url parts
subtest 'arrayref: mixed text and image_url' => sub {
    # "Look at this image:" = 19 chars -> ceil(19/4) = 5 tokens + 85 = 90
    my $content = [
        { type => 'text', text => 'Look at this image:' },
        { type => 'image_url', image_url => { url => 'data:image/png;base64,abc' } }
    ];

    is(estimate_tokens($content), 90, 'mixed content: text tokens + image tokens');

    # "Before" = 6 chars -> ceil(6/4) = 2
    # "After" = 5 chars -> ceil(5/4) = 2
    # Total text = 4 + 85 image = 89
    my $content_multi = [
        { type => 'text', text => 'Before' },
        { type => 'image_url', image_url => { url => 'data:image/png;base64,abc' } },
        { type => 'text', text => 'After' }
    ];
    is(estimate_tokens($content_multi), 89, 'text-image-text: 2 + 85 + 2 = 89 tokens');
};

# Test 5: Empty array
subtest 'arrayref: empty array' => sub {
    is(estimate_tokens([]), 0, 'empty array returns 0');
};

# Test 6: Array with unknown part types
subtest 'arrayref: unknown part types' => sub {
    my $content = [
        { type => 'unknown', data => 'test' },
        { type => 'image_url', image_url => { url => 'data:image/png;base64,abc' } },
        { type => 'video', data => 'video_data' }
    ];

    is(estimate_tokens($content), 85, 'unknown types skipped, only image counted');
};

# Test 7: Array with missing or undefined fields
subtest 'arrayref: missing or undefined fields' => sub {
    # Part with missing type
    my $content_no_type = [
        { text => 'Hello' }
    ];
    is(estimate_tokens($content_no_type), 0, 'part without type returns 0');

    # Part with undefined text
    my $content_undef_text = [
        { type => 'text', text => undef }
    ];
    is(estimate_tokens($content_undef_text), 0, 'text part with undef text returns 0');

    # Part with empty text
    my $content_empty_text = [
        { type => 'text', text => '' }
    ];
    is(estimate_tokens($content_empty_text), 0, 'text part with empty text returns 0');
};

# Test 8: estimate_messages_tokens with Google Gemini format (parts array)
subtest 'estimate_messages_tokens: Gemini format with parts' => sub {
    my $messages = [
        {
            role => 'user',
            parts => [
                { text => 'Hello' }
            ]
        }
    ];

    # TOKENS_PER_COMPLETION (3) + TOKENS_PER_MESSAGE (3) + content tokens
    # 'Hello' = 5 chars / 4.0 = 2 tokens (ceiled)
    is(CLIO::Memory::TokenEstimator::estimate_messages_tokens($messages), 8, 'Gemini message with text part');
};

# Test 9: Message with parts containing inlineData (image)
subtest 'estimate_messages_tokens: Gemini with inlineData' => sub {
    my $messages = [
        {
            role => 'user',
            parts => [
                { inlineData => { mimeType => 'image/png', data => 'abc123' } }
            ]
        }
    ];

    # TOKENS_PER_COMPLETION (3) + TOKENS_PER_MESSAGE (3) + 85 (image) = 91
    is(CLIO::Memory::TokenEstimator::estimate_messages_tokens($messages), 91, 'Gemini message with inlineData image');
};

# Test 10: Message with both text and inlineData parts
subtest 'estimate_messages_tokens: Gemini with mixed parts' => sub {
    my $messages = [
        {
            role => 'user',
            parts => [
                { text => 'Look at this: ' },   # 14 chars -> ceil(14/4) = 4
                { inlineData => { mimeType => 'image/png', data => 'abc123' } },
                { text => ' Done' }              # 5 chars -> ceil(5/4) = 2
            ]
        }
    ];

    # TOKENS_PER_COMPLETION (3) + TOKENS_PER_MESSAGE (3) + text (4+2=6) + 85 image
    # Total: 3 + 3 + 6 + 85 = 97
    is(CLIO::Memory::TokenEstimator::estimate_messages_tokens($messages), 97, 'Gemini message with mixed parts');
};

# Test 11: Multiple Gemini messages
subtest 'estimate_messages_tokens: multiple Gemini messages' => sub {
    my $messages = [
        {
            role => 'user',
            parts => [
                { text => 'Hello' },            # 5 chars -> 2 tokens
                { inlineData => { mimeType => 'image/png', data => 'abc' } }
            ]
        },
        {
            role => 'model',
            parts => [
                { text => 'Hi there!' }         # 9 chars -> ceil(9/4) = 3 tokens
            ]
        }
    ];

    # Message 1: 3 (completion) + 3 (message) + 2 (text) + 85 (image) = 93
    # Message 2: 3 (message) + 3 (text) = 6
    # Total: 99
    is(CLIO::Memory::TokenEstimator::estimate_messages_tokens($messages), 99, 'multiple Gemini messages');
};

# Test 12: Regular message format (content string) still works
subtest 'estimate_messages_tokens: regular content string' => sub {
    my $messages = [
        {
            role => 'user',
            content => 'Hello, world!'
        }
    ];

    # TOKENS_PER_COMPLETION (3) + TOKENS_PER_MESSAGE (3) + content tokens
    # 'Hello, world!' = 13 chars / 4.0 = 4 tokens (ceiled)
    is(CLIO::Memory::TokenEstimator::estimate_messages_tokens($messages), 10, 'regular message with string content');
};

# Test 13: Learned ratio affects array content
subtest 'learned ratio affects multimodal estimation' => sub {
    # Set a different ratio
    CLIO::Memory::TokenEstimator::set_learned_ratio(2.0);

    my $content = [
        { type => 'text', text => 'Hello' }  # 5 chars / 2.0 = 3 tokens
    ];

    is(estimate_tokens($content), 3, 'text with learned ratio 2.0');

    # Reset to default
    CLIO::Memory::TokenEstimator::set_learned_ratio(4.0);
};

# Test 14: Array with non-HASH refs
subtest 'arrayref: non-HASH refs ignored' => sub {
    my $content = [
        'not a hash',
        { type => 'text', text => 'Hello' },  # 5 chars -> 2 tokens
        undef,
        { type => 'image_url', image_url => { url => 'data:image/png;base64,abc' } }
    ];

    is(estimate_tokens($content), 87, 'non-HASH refs skipped: 2 + 85 = 87');
};

done_testing();
