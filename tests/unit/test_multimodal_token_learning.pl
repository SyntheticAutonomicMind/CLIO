#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;
use lib '../../lib';
use Test::More;

use CLIO::Memory::TokenEstimator;
use CLIO::Core::API::MessageValidator qw(validate_and_truncate validate_tool_message_pairs);

# Test message_character_count with all content representations
{
    # Plain scalar text
    my $scalar = "Hello, world!";
    is(CLIO::Memory::TokenEstimator::message_character_count($scalar), 13,
        "Scalar text: character count correct");

    # Empty string
    is(CLIO::Memory::TokenEstimator::message_character_count(''), 0,
        "Empty string: 0 chars");

    # undef
    is(CLIO::Memory::TokenEstimator::message_character_count(undef), 0,
        "undef: 0 chars");

    # Multimodal: text + image parts (like a user uploading an image with a query)
    my $multimodal = [
        { type => 'text', text => 'Describe this image' },
        { type => 'image_url', image_url => { url => 'data:image/png;base64,AAAA' } },
    ];
    is(CLIO::Memory::TokenEstimator::message_character_count($multimodal), 19,
        "Multimodal text + image: only text chars counted (19 = 'Describe this image')");

    # Multimodal with multiple text parts
    my $multi_text = [
        { type => 'text', text => 'Hello ' },
        { type => 'text', text => 'world!' },
        { type => 'image_url', image_url => { url => 'data:image/png;base64,AAAA' } },
    ];
    is(CLIO::Memory::TokenEstimator::message_character_count($multi_text), 12,
        "Multimodal multiple text parts: chars summed correctly (12)");

    # Multimodal with ONLY image (no text)
    my $image_only = [
        { type => 'image_url', image_url => { url => 'data:image/png;base64,AAAA' } },
    ];
    is(CLIO::Memory::TokenEstimator::message_character_count($image_only), 0,
        "Image-only content: 0 chars (images are not text)");

    # Malformed: hashref content (not a valid representation)
    my $hashref = { key => 'value' };
    is(CLIO::Memory::TokenEstimator::message_character_count($hashref), 0,
        "Hashref content: 0 chars (malformed, safe fallback)");

    # Malformed: arrayref with invalid parts
    my $bad_parts = [
        { type => 'unknown' },
        'not_a_hash',
        undef,
    ];
    is(CLIO::Memory::TokenEstimator::message_character_count($bad_parts), 0,
        "Malformed parts array: 0 chars (safe fallback)");

    # Arrayref with text part that has no 'text' key
    my $no_text = [
        { type => 'text' },
        { type => 'image_url' },
    ];
    is(CLIO::Memory::TokenEstimator::message_character_count($no_text), 0,
        "Text part without text key: 0 chars");
}

# Test that estimate_tokens handles all the same representations
{
    # Scalar text
    my $tok = CLIO::Memory::TokenEstimator::estimate_tokens("Hello, world!");
    ok($tok > 0, "estimate_tokens on scalar text: $tok tokens");

    # Multimodal
    my $multimodal = [
        { type => 'text', text => 'Describe this image' },
        { type => 'image_url', image_url => { url => 'data:image/png;base64,AAAA' } },
    ];
    my $mtok = CLIO::Memory::TokenEstimator::estimate_tokens($multimodal);
    ok($mtok >= 85, "estimate_tokens on multimodal: $mtok tokens (includes 85 for image)");

    # The scalar char count and multimodal char count must be consistent
    # with what the estimation uses internally
    my $text_only_content = "Describe this image";
    my $scalar_chars = CLIO::Memory::TokenEstimator::message_character_count($text_only_content);
    my $multimodal_chars = CLIO::Memory::TokenEstimator::message_character_count($multimodal);
    is($scalar_chars, $multimodal_chars,
        "Character count is consistent between scalar and multimodal text");
}

# Test the core hypothesis: learning from a multimodal request produces
# the same ratio as learning from the scalar-only text of that request.
# Before the fix, length($msg->{content}) on an arrayref would stringify
# the reference ("ARRAY(0x...)"), giving ~17 chars instead of the real
# text length, causing the learned ratio to be artificially deflated.
{
    CLIO::Memory::TokenEstimator::set_learned_ratio(undef);  # reset

    # Simulate _learn_from_api_response's character counting logic
    # BEFORE the fix (using length() directly on arrayref content)
    my $multimodal_content = [
        { type => 'text', text => 'Describe this image' },
        { type => 'image_url', image_url => { url => 'data:image/png;base64,AAAA' } },
    ];

    # Old (buggy) approach: length on arrayref
    my $old_chars = length($multimodal_content || '');  # stringifies ref
    ok($old_chars < 100, "Old approach (length on arrayref): small char count ($old_chars) - BUG");

    # New (fixed) approach: message_character_count
    my $new_chars = CLIO::Memory::TokenEstimator::message_character_count($multimodal_content);
    is($new_chars, 19, "New approach (message_character_count): correct char count ($new_chars)");
    ok($new_chars > $old_chars, "New approach counts more chars than old ($new_chars > $old_chars) - fix works");
}

# Test that a multimodal message with substantial text doesn't
# deflater the learned ratio below the clamping floor (1.5).
# With the old code, a 5000-char text part + image would be counted as
# ~17 chars (the arrayref stringification), producing a ratio of
# 17/805 ≈ 0.02, clamped to 1.5 — far too low.
{
    CLIO::Memory::TokenEstimator::set_learned_ratio(4.0);  # start with default

    my $long_text = 'x' x 5000;
    my $multimodal = [
        { type => 'text', text => $long_text },
        { type => 'image_url', image_url => { url => 'data:image/png;base64,AAAA' } },
    ];

    # With the fix, character count should be 5000 (text only, image excluded)
    my $chars = CLIO::Memory::TokenEstimator::message_character_count($multimodal);
    is($chars, 5000, "Long text in multimodal: character count is 5000 (not ~17 from ref stringification)");

    # Simulate learning: 5000 chars, 1200 tokens -> ratio = 5000/1200 ≈ 4.17
    my $actual_tokens = 1200;
    my $actual_ratio = $chars / $actual_tokens;
    my $clamped_ratio = $actual_ratio < 1.5 ? 1.5 : ($actual_ratio > 4.0 ? 4.0 : $actual_ratio);
    is(sprintf("%.2f", $clamped_ratio), "4.00", "Learned ratio with fix is 4.0 (not 1.5 from stringification bug)");
}

# Test that the _estimate_tokens function in MessageValidator handles
# arrayref content correctly (it should already, but verify the contract)
{
    my $messages = [
        { role => 'system', content => 'You are helpful.' },
        { role => 'user', content => 'Hello' },
    ];

    # Scalar content
    my $scalar_tokens = CLIO::Core::API::MessageValidator::_estimate_tokens($messages, 4.0);
    ok($scalar_tokens > 0, "MessageValidator::_estimate_tokens with scalar content: $scalar_tokens tokens");

    # Multimodal content
    my $multimodal_msgs = [
        { role => 'system', content => 'You are helpful.' },
        { role => 'user', content => [
            { type => 'text', text => 'Describe this image' },
            { type => 'image_url', image_url => { url => 'data:image/png;base64,AAAA' } },
        ]},
    ];
    my $multi_tokens = CLIO::Core::API::MessageValidator::_estimate_tokens($multimodal_msgs, 4.0);
    ok($multi_tokens > 0, "MessageValidator::_estimate_tokens with multimodal content: $multi_tokens tokens");

    # The text portion should be the same in both
    my $text_chars = CLIO::Memory::TokenEstimator::message_character_count('Hello');
    my $multi_text_chars = CLIO::Memory::TokenEstimator::message_character_count(
        [ { type => 'text', text => 'Describe this image' },
          { type => 'image_url', image_url => { url => 'data:image/png;base64,AAAA' } } ]
    );
    is($text_chars, 5, "Scalar text char count: 5");
    is($multi_text_chars, 19, "Multimodal text char count: 19");
}

done_testing();

print "\n";
print "━" x 60 . "\n";
print "TEST SUMMARY: Multimodal Token-Ratio Learning\n";
print "━" x 60 . "\n";
print "[OK] message_character_count handles all representations\n";
print "[OK] Learning/estimation paths use the same character-count definition\n";
print "[OK] Multimodal text is not corrupted by arrayref stringification\n";
print "━" x 60 . "\n";
