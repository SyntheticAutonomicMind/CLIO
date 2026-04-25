#!/usr/bin/env perl
# Unit tests for CLIO::Util::ImageDisplay

use strict;
use warnings;
use utf8;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(remove_tree);

use lib './lib';

# Mock CLIO::UI::Terminal before loading the module
BEGIN {
    package CLIO::UI::Terminal;
    use strict;
    use warnings;
    use Exporter qw(import);
    our @EXPORT_OK = qw(supports_inline_images terminal_image_protocol);
    sub supports_inline_images { 1 }
    sub terminal_image_protocol { 'none' }
    $INC{'CLIO/UI/Terminal.pm'} = 1;
}

# Mock CLIO::Core::Logger
BEGIN {
    package CLIO::Core::Logger;
    use strict;
    use warnings;
    use Exporter qw(import);
    our @EXPORT_OK = qw(log_debug log_info log_warning log_error);
    sub log_debug { }
    sub log_info { }
    sub log_warning { }
    sub log_error { }
    $INC{'CLIO/Core/Logger.pm'} = 1;
}

use CLIO::Util::ImageDisplay;

# Create temp directory for tests
my $temp_dir = tempdir(CLEANUP => 1);

# Helper: Create a minimal PNG file with specified dimensions
# Uses pre-computed CRC values to avoid needing Digest::CRC
sub create_minimal_png {
    my ($width, $height) = @_;
    
    # PNG signature
    my $png = "\x89PNG\r\n\x1a\n";
    
    # IHDR chunk: 13 bytes of data
    # Width(4) + Height(4) + BitDepth(1) + ColorType(1) + Compression(1) + Filter(1) + Interlace(1)
    my $ihdr_data = pack('N', $width) . pack('N', $height) . "\x08\x02\x00\x00\x00";
    
    # Compute CRC32 for IHDR chunk (type + data)
    my $ihdr_crc = _crc32("IHDR" . $ihdr_data);
    my $ihdr = pack('N', 13) . "IHDR" . $ihdr_data . pack('N', $ihdr_crc);
    
    # IEND chunk (empty data)
    my $iend_crc = _crc32("IEND");
    my $iend = pack('N', 0) . "IEND" . pack('N', $iend_crc);
    
    return $png . $ihdr . $iend;
}

# Helper: Create a minimal GIF file with specified dimensions
sub create_minimal_gif {
    my ($width, $height) = @_;
    
    # GIF89a header
    my $gif = "GIF89a";
    
    # Logical screen descriptor (little-endian)
    $gif .= pack('v', $width);   # width
    $gif .= pack('v', $height);  # height
    $gif .= "\xF7\x00\x00";     # packed byte: global color table, 256 colors
    
    # Global color table (3 bytes * 256 colors = 768 bytes)
    $gif .= "\x00\x00\x00" x 256;
    
    # Image descriptor
    $gif .= "\x2C";              # image separator
    $gif .= pack('v', 0);        # left
    $gif .= pack('v', 0);        # top
    $gif .= pack('v', $width);   # width
    $gif .= pack('v', $height);  # height
    $gif .= "\x00";              # packed byte
    
    # LZW minimum code size
    $gif .= "\x08";
    
    # Block terminator
    $gif .= "\x00";
    
    # Trailer
    $gif .= "\x3B";
    
    return $gif;
}

# Pure Perl CRC-32 implementation (standard PNG polynomial)
sub _crc32 {
    my ($data) = @_;
    my $crc = 0xFFFFFFFF;
    for my $byte (unpack('C*', $data)) {
        $crc ^= $byte;
        for (0..7) {
            if ($crc & 1) {
                $crc = ($crc >> 1) ^ 0xEDB88320;
            } else {
                $crc >>= 1;
            }
        }
    }
    return $crc ^ 0xFFFFFFFF;
}

# ─────────────────────────────────────────────────────────────
# Tests
# ─────────────────────────────────────────────────────────────

# Test: new() constructor
subtest 'new() constructor' => sub {
    my $display = CLIO::Util::ImageDisplay->new(output_dir => $temp_dir);
    ok($display, 'constructor returns object');
    is($display->{output_dir}, $temp_dir, 'output_dir set correctly');
    is($display->{max_width}, 800, 'max_width defaults to 800');
    is($display->{max_height}, 600, 'max_height defaults to 600');
    is($display->{displayed_count}, 0, 'displayed_count starts at 0');
    
    # Custom options
    my $custom = CLIO::Util::ImageDisplay->new(
        output_dir => $temp_dir,
        max_width => 1024,
        max_height => 768
    );
    is($custom->{max_width}, 1024, 'custom max_width');
    is($custom->{max_height}, 768, 'custom max_height');
};

# Test: _default_output_dir() uses HOME env var
subtest '_default_output_dir() uses HOME env var' => sub {
    local $ENV{HOME} = '/tmp/test_home_dir';
    local $ENV{USERPROFILE};
    delete $ENV{USERPROFILE};
    
    my $dir = CLIO::Util::ImageDisplay::_default_output_dir();
    is($dir, '/tmp/test_home_dir/.clio/images', 'uses HOME env var');
};

# Test: _get_image_dimensions() - PNG dimensions
subtest '_get_image_dimensions() PNG' => sub {
    my $png_100x200 = create_minimal_png(100, 200);
    my ($w, $h) = CLIO::Util::ImageDisplay::_get_image_dimensions($png_100x200, 'image/png');
    is($w, 100, 'PNG width extracted correctly');
    is($h, 200, 'PNG height extracted correctly');
    
    my $png_800x600 = create_minimal_png(800, 600);
    ($w, $h) = CLIO::Util::ImageDisplay::_get_image_dimensions($png_800x600, 'image/png');
    is($w, 800, 'PNG width 800');
    is($h, 600, 'PNG height 600');
};

# Test: _get_image_dimensions() - GIF dimensions
subtest '_get_image_dimensions() GIF' => sub {
    my $gif_320x240 = create_minimal_gif(320, 240);
    my ($w, $h) = CLIO::Util::ImageDisplay::_get_image_dimensions($gif_320x240, 'image/gif');
    is($w, 320, 'GIF width extracted correctly');
    is($h, 240, 'GIF height extracted correctly');
};

# Test: _get_image_dimensions() - JPEG returns undef
subtest '_get_image_dimensions() JPEG returns undef' => sub {
    my $jpeg_data = "\xFF\xD8\xFF\xE0" . ("x" x 100);
    my ($w, $h) = CLIO::Util::ImageDisplay::_get_image_dimensions($jpeg_data, 'image/jpeg');
    is($w, undef, 'JPEG width is undef');
    is($h, undef, 'JPEG height is undef');
};

# Test: _get_image_dimensions() - too-short data
subtest '_get_image_dimensions() edge cases' => sub {
    my $short_data = "\x89PNG\r\n\x1a\n" . ("x" x 5);  # Only 13 bytes
    my ($w, $h) = CLIO::Util::ImageDisplay::_get_image_dimensions($short_data, 'image/png');
    is($w, undef, 'short data: width undef');
    is($h, undef, 'short data: height undef');
    
    # Undefined data
    ($w, $h) = CLIO::Util::ImageDisplay::_get_image_dimensions(undef, 'image/png');
    is($w, undef, 'undef data: width undef');
    is($h, undef, 'undef data: height undef');
    
    # Empty data
    ($w, $h) = CLIO::Util::ImageDisplay::_get_image_dimensions('', 'image/png');
    is($w, undef, 'empty data: width undef');
    is($h, undef, 'empty data: height undef');
};

# Test: _decode_base64() - valid base64
subtest '_decode_base64() valid base64' => sub {
    my $decoded = CLIO::Util::ImageDisplay::_decode_base64("SGVsbG8=");
    is($decoded, 'Hello', 'decodes "SGVsbG8=" to "Hello"');
    
    $decoded = CLIO::Util::ImageDisplay::_decode_base64("V29ybGQ=");
    is($decoded, 'World', 'decodes "V29ybGQ=" to "World"');
    
    $decoded = CLIO::Util::ImageDisplay::_decode_base64("");
    is($decoded, '', 'decodes empty string to empty');
};

# Test: show_image() - with is_base64 option
subtest 'show_image() with is_base64 option' => sub {
    my $display = CLIO::Util::ImageDisplay->new(output_dir => $temp_dir);
    $display->{protocol} = 'none';  # Force file save (no inline display)
    
    # Create a small PNG and base64 encode it
    my $png_data = create_minimal_png(10, 10);
    require MIME::Base64;
    my $b64 = MIME::Base64::encode_base64($png_data, '');
    
    # Test with is_base64 => 1 (explicit)
    my ($ok, $info) = $display->show_image($b64, 'image/png', is_base64 => 1, filename => 'test_b64.png');
    ok($ok, 'show_image with is_base64=1 succeeds');
    ok($info->{path}, 'returns path');
    like($info->{path}, qr/\.png$/, 'path has .png extension');
    ok(-f $info->{path}, 'file exists on disk');
    
    # Test with raw binary data (is_base64 => 0)
    ($ok, $info) = $display->show_image($png_data, 'image/png', is_base64 => 0, filename => 'test_raw.png');
    ok($ok, 'show_image with is_base64=0 succeeds');
    ok($info->{path}, 'returns path');
    ok(-f $info->{path}, 'raw file exists on disk');
};

# Test: show_image() - empty data
subtest 'show_image() empty data' => sub {
    my $display = CLIO::Util::ImageDisplay->new(output_dir => $temp_dir);
    
    my ($ok, $info) = $display->show_image('', 'image/png');
    ok(!$ok, 'empty data returns failure');
    ok($info->{error}, 'error message provided');
    
    ($ok, $info) = $display->show_image(undef, 'image/png');
    ok(!$ok, 'undef data returns failure');
};

# Test: show_image_file() - with valid file
subtest 'show_image_file() with valid file' => sub {
    my $display = CLIO::Util::ImageDisplay->new(output_dir => $temp_dir);
    $display->{protocol} = 'none';  # Force file save
    
    # Create a temp PNG file
    my $png_data = create_minimal_png(50, 50);
    my $tmp_file = "$temp_dir/test_input.png";
    open my $fh, '>:raw', $tmp_file or die "Cannot write: $!";
    print $fh $png_data;
    close $fh;
    
    my ($ok, $info) = $display->show_image_file($tmp_file);
    ok($ok, 'show_image_file succeeds');
    ok($info->{path}, 'returns path');
    ok(-f $info->{path}, 'saved file exists');
    
    # Clean up
    unlink $tmp_file;
};

# Test: show_image_file() - nonexistent file
subtest 'show_image_file() nonexistent file' => sub {
    my $display = CLIO::Util::ImageDisplay->new(output_dir => $temp_dir);
    
    my ($ok, $info) = $display->show_image_file('/nonexistent/path/image.png');
    ok(!$ok, 'nonexistent file returns failure');
    ok($info->{error}, 'error message provided');
};

# Test: _save_to_file() - MIME type to extension mapping
subtest '_save_to_file() MIME type to extension' => sub {
    my $display = CLIO::Util::ImageDisplay->new(output_dir => $temp_dir);
    
    my $data = "fake image data";
    
    # PNG
    my ($ok, $info) = $display->_save_to_file($data, 'image/png');
    ok($ok, 'PNG save succeeds');
    like($info->{path}, qr/\.png$/, 'PNG path has .png extension');
    
    # JPEG
    ($ok, $info) = $display->_save_to_file($data, 'image/jpeg');
    ok($ok, 'JPEG save succeeds');
    like($info->{path}, qr/\.jpg$/, 'JPEG path has .jpg extension');
    
    # GIF
    ($ok, $info) = $display->_save_to_file($data, 'image/gif');
    ok($ok, 'GIF save succeeds');
    like($info->{path}, qr/\.gif$/, 'GIF path has .gif extension');
    
    # WebP
    ($ok, $info) = $display->_save_to_file($data, 'image/webp');
    ok($ok, 'WebP save succeeds');
    like($info->{path}, qr/\.webp$/, 'WebP path has .webp extension');
};

# Test: _save_to_file() - unique filename generation
subtest '_save_to_file() unique filename generation' => sub {
    my $display = CLIO::Util::ImageDisplay->new(output_dir => $temp_dir);
    
    my $data = "fake image data";
    
    # Save with same filename twice - should get unique names
    my ($ok1, $info1) = $display->_save_to_file($data, 'image/png', filename => 'dup.png');
    my ($ok2, $info2) = $display->_save_to_file($data, 'image/png', filename => 'dup.png');
    
    ok($ok1, 'first save succeeds');
    ok($ok2, 'second save succeeds');
    isnt($info1->{path}, $info2->{path}, 'different paths for same filename');
};

# Test: Base64 detection heuristic
subtest 'base64 detection heuristic' => sub {
    my $display = CLIO::Util::ImageDisplay->new(output_dir => $temp_dir);
    $display->{protocol} = 'none';  # Force file save
    
    # Short data should be treated as raw binary (not base64)
    my $short_data = "hello";
    my ($ok, $info) = $display->show_image($short_data, 'image/png');
    # Short data is treated as raw binary, saved as-is
    
    # Long ASCII-safe data should be treated as base64
    my $long_b64 = "SGVsbG8gV29ybGQh" x 20;  # ~280 chars, all base64-safe
    ($ok, $info) = $display->show_image($long_b64, 'image/png');
    # This will try to decode as base64 (heuristic), then save
    
    # Data with high-bit chars should be treated as raw binary
    my $binary_data = "\x89PNG\r\n\x1a\n" . "\x00" x 100;
    ($ok, $info) = $display->show_image($binary_data, 'image/png', is_base64 => 0);
    ok($ok, 'binary data with is_base64=0 saved successfully');
};

# Test: _find_command() helper
subtest '_find_command() helper' => sub {
    # ls should always be available
    my $ls = CLIO::Util::ImageDisplay::_find_command('ls');
    ok($ls, 'finds ls command');
    like($ls, qr/ls$/, 'ls path ends with ls');
    
    # Nonexistent command
    my $fake = CLIO::Util::ImageDisplay::_find_command('nonexistent_command_xyz_12345');
    is($fake, undef, 'returns undef for nonexistent command');
};

# Test: _mime_to_ext() helper
subtest '_mime_to_ext() helper' => sub {
    is(CLIO::Util::ImageDisplay::_mime_to_ext('image/png'), '.png', 'PNG extension');
    is(CLIO::Util::ImageDisplay::_mime_to_ext('image/jpeg'), '.jpg', 'JPEG extension');
    is(CLIO::Util::ImageDisplay::_mime_to_ext('image/gif'), '.gif', 'GIF extension');
    is(CLIO::Util::ImageDisplay::_mime_to_ext('image/webp'), '.webp', 'WebP extension');
    is(CLIO::Util::ImageDisplay::_mime_to_ext('image/unknown'), '.png', 'unknown defaults to .png');
};

done_testing();