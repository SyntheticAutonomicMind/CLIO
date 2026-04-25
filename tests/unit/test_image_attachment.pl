#!/usr/bin/env perl
# Unit tests for CLIO::Util::ImageAttachment

use strict;
use warnings;
use utf8;
use Test::More;

use lib './lib';

use CLIO::Util::ImageAttachment;

# Test parse_attachments_from_text
subtest 'parse_attachments_from_text' => sub {
    # Simple attachment
    my ($text, @paths) = CLIO::Util::ImageAttachment::parse_attachments_from_text('Look at @image.png');
    is($text, 'Look at', 'simple: text stripped');
    is_deeply(\@paths, ['image.png'], 'simple: path extracted');
    
    # Quoted attachment with spaces
    ($text, @paths) = CLIO::Util::ImageAttachment::parse_attachments_from_text('Analyze @"/path/to/my image.png" now');
    is($text, 'Analyze now', 'quoted: text stripped');
    is_deeply(\@paths, ['/path/to/my image.png'], 'quoted: path with spaces extracted');
    
    # Multiple attachments
    ($text, @paths) = CLIO::Util::ImageAttachment::parse_attachments_from_text('Compare @a.png and @b.jpg');
    is($text, 'Compare and', 'multiple: text stripped');
    is_deeply(\@paths, ['a.png', 'b.jpg'], 'multiple: paths extracted');
    
    # No attachments
    ($text, @paths) = CLIO::Util::ImageAttachment::parse_attachments_from_text('Just text');
    is($text, 'Just text', 'none: text unchanged');
    is_deeply(\@paths, [], 'none: empty paths');
    
    # Attachment at end
    ($text, @paths) = CLIO::Util::ImageAttachment::parse_attachments_from_text('See this @file.gif');
    is($text, 'See this', 'end: text stripped');
    is_deeply(\@paths, ['file.gif'], 'end: path extracted');
};

# Test MIME type detection
subtest 'MIME type detection' => sub {
    # Create a fake PNG file (just the header)
    my $tmpfile = '/tmp/test_image_attachment.png';
    open my $fh, '>:raw', $tmpfile or die $!;
    print $fh "\x89PNG\r\n\x1a\n";
    close $fh;
    
    my $att = CLIO::Util::ImageAttachment->new($tmpfile);
    ok($att, 'attachment created');
    is($att->mime_type, 'image/png', 'PNG detected by magic bytes');
    
    # Test extension-based fallback
    my $tmpfile2 = '/tmp/test_image_attachment.jpg';
    open $fh, '>:raw', $tmpfile2 or die $!;
    print $fh "not really a jpeg";
    close $fh;
    
    my $att2 = CLIO::Util::ImageAttachment->new($tmpfile2);
    ok($att2, 'attachment2 created');
    is($att2->mime_type, 'image/jpeg', 'JPEG detected by extension fallback');
    
    unlink $tmpfile;
    unlink $tmpfile2;
};

# Test OpenAI part generation
subtest 'OpenAI part generation' => sub {
    my $tmpfile = '/tmp/test_image_attachment2.png';
    open my $fh, '>:raw', $tmpfile or die $!;
    print $fh "\x89PNG\r\n\x1a\nfake_data";
    close $fh;
    
    my $att = CLIO::Util::ImageAttachment->new($tmpfile);
    my $part = $att->to_openai_part();
    
    ok($part, 'OpenAI part generated');
    is($part->{type}, 'image_url', 'part type is image_url');
    like($part->{image_url}{url}, qr{^data:image/png;base64,}, 'data URL prefix correct');
    
    unlink $tmpfile;
};

# Test Google part generation
subtest 'Google part generation' => sub {
    my $tmpfile = '/tmp/test_image_attachment3.png';
    open my $fh, '>:raw', $tmpfile or die $!;
    print $fh "\x89PNG\r\n\x1a\nfake_data";
    close $fh;
    
    my $att = CLIO::Util::ImageAttachment->new($tmpfile);
    my $part = $att->to_google_part();
    
    ok($part, 'Google part generated');
    ok($part->{inlineData}, 'has inlineData');
    is($part->{inlineData}{mimeType}, 'image/png', 'mimeType correct');
    ok(length($part->{inlineData}{data}) > 0, 'base64 data present');
    
    unlink $tmpfile;
};

# Test text description
subtest 'text description' => sub {
    my $tmpfile = '/tmp/test_image_attachment4.png';
    open my $fh, '>:raw', $tmpfile or die $!;
    print $fh "\x89PNG\r\n\x1a\n";
    close $fh;
    
    my $att = CLIO::Util::ImageAttachment->new($tmpfile);
    my $desc = $att->to_text_description();
    
    like($desc, qr/\[Image:.*test_image_attachment4\.png.*\]/, 'description contains filename');
    like($desc, qr/image\/png/, 'description contains MIME type');
    
    unlink $tmpfile;
};

done_testing();
