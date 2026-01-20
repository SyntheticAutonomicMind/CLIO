package TestData;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

=head1 NAME

TestData - Test data generation for character encoding tests

=head1 SYNOPSIS

    use lib 'tests/lib';
    use TestData;
    
    my $ascii = TestData::ascii_string();
    my $unicode = TestData::unicode_string();
    my $emoji = TestData::emoji_string();
    my $cjk = TestData::wide_char_string();

=head1 DESCRIPTION

Generates test data for various character encodings to ensure CLIO handles
all character types correctly. This is critical for finding and preventing
"Wide character in subroutine entry" errors.

=cut

use strict;
use warnings;
use utf8;
use Exporter 'import';

our @EXPORT_OK = qw(
    ascii_string
    extended_ascii_string
    unicode_string
    emoji_string
    wide_char_string
    ansi_string
    edge_case_string
    special_chars_string
    mixed_encoding_string
    random_binary_data
    all_encoding_samples
);

=head2 ascii_string

Returns basic ASCII text (7-bit ASCII, characters 0-127).

=cut

sub ascii_string {
    return "Hello, World! This is basic ASCII text with numbers 123 and symbols !@#\$%";
}

=head2 extended_ascii_string

Returns extended ASCII text (8-bit ASCII, characters 128-255).
Includes Latin-1 supplement characters.

=cut

sub extended_ascii_string {
    return "Extended ASCII: café, naïve, résumé, Ω, ±, ¿, ©, ®, £, €, ¥";
}

=head2 unicode_string

Returns UTF-8 encoded text with various Unicode characters.

=cut

sub unicode_string {
    return "Unicode test: Hello 世界 Привет мир مرحبا بالعالم שלום עולם こんにちは世界";
}

=head2 emoji_string

Returns text with emoji characters - the most common cause of wide character errors.

=cut

sub emoji_string {
    return "Emoji test: 🎉 ✅ ❌ 🚀 🔥 💡 ⚠️ 📋 🐛 🎯 ✨ 🌍 🎨 🔧 📊";
}

=head2 wide_char_string

Returns text with wide characters (CJK, Arabic, Hebrew, etc.).

=cut

sub wide_char_string {
    return <<'EOF';
CJK Characters:
中文测试 - Chinese
日本語テスト - Japanese
한국어 테스트 - Korean

RTL Languages:
اختبار العربية - Arabic
בדיקה עברית - Hebrew

Other:
Тест кириллица - Cyrillic
Δοκιμή ελληνικά - Greek
EOF
}

=head2 ansi_string

Returns text with ANSI escape sequences and @-codes.

=cut

sub ansi_string {
    return '@BOLD@Bold text@RESET@ and @RED@red text@RESET@ with @BRIGHT_GREEN@bright green@RESET@';
}

=head2 edge_case_string

Returns text with edge cases: quotes, backslashes, special characters.

=cut

sub edge_case_string {
    return q{Edge cases: "quotes", 'single', `backticks`, \backslash, $dollar, @at, #hash, %percent, &ampersand, *asterisk};
}

=head2 special_chars_string

Returns text with special characters that might break JSON/shell/parsing.

=cut

sub special_chars_string {
    return <<'EOF';
Special characters:
Newline: line1
line2
Tab:	indented
Quote: "double" and 'single'
Backslash: C:\path\to\file
Null: (null character after this)
EOF
}

=head2 mixed_encoding_string

Returns text mixing multiple encoding types - comprehensive test.

=cut

sub mixed_encoding_string {
    return <<'EOF';
Mixed encoding test:
ASCII: Hello World
Extended: café résumé
Unicode: 世界 مرحبا
Emoji: 🎉 ✅ 🚀
ANSI: @BOLD@bold@RESET@
Special: "quotes" \backslash $variables
Numbers: 123 0.456 -789
EOF
}

=head2 random_binary_data

Returns random binary data for binary file testing.

Arguments:
- $size: Number of bytes (default: 1024)

=cut

sub random_binary_data {
    my ($size) = @_;
    $size ||= 1024;
    
    my $data = '';
    for (1..$size) {
        $data .= chr(int(rand(256)));
    }
    return $data;
}

=head2 all_encoding_samples

Returns a hash of all encoding test samples for comprehensive testing.

    my $samples = TestData::all_encoding_samples();
    for my $name (keys %$samples) {
        test_with_encoding($name, $samples->{$name});
    }

=cut

sub all_encoding_samples {
    return {
        ascii               => ascii_string(),
        extended_ascii      => extended_ascii_string(),
        unicode             => unicode_string(),
        emoji               => emoji_string(),
        wide_char           => wide_char_string(),
        ansi                => ansi_string(),
        edge_case           => edge_case_string(),
        special_chars       => special_chars_string(),
        mixed_encoding      => mixed_encoding_string(),
    };
}

=head2 get_sample

Get a specific encoding sample by name.

    my $emoji = TestData::get_sample('emoji');

=cut

sub get_sample {
    my ($name) = @_;
    my $samples = all_encoding_samples();
    return $samples->{$name} || die "Unknown sample: $name";
}

=head2 sample_names

Returns list of all available sample names.

=cut

sub sample_names {
    return sort keys %{all_encoding_samples()};
}

1;

__END__

=head1 USAGE EXAMPLES

    # Test a function with all encoding types
    use TestData;
    
    for my $name (TestData::sample_names()) {
        my $data = TestData::get_sample($name);
        test_function_with_encoding($name, $data);
    }
    
    # Test specific encoding
    my $emoji = TestData::emoji_string();
    my $result = create_file('/tmp/test.txt', $emoji);

=head1 CHARACTER ENCODING REFERENCE

ASCII (7-bit):
- Characters 0-127
- Basic English text, numbers, punctuation

Extended ASCII (8-bit):
- Characters 128-255
- Latin-1 supplement (café, résumé, etc.)

UTF-8 Unicode:
- Multi-byte encoding
- Supports all languages
- Variable length: 1-4 bytes per character

Wide Characters:
- CJK (Chinese, Japanese, Korean): 3 bytes each in UTF-8
- Arabic, Hebrew: 2 bytes each in UTF-8
- Require special handling in Perl (use utf8)

Emoji:
- Most are 4 bytes in UTF-8
- Some are sequences (multiple characters)
- Common cause of "Wide character" errors

ANSI Escape Sequences:
- Terminal formatting codes
- CLIO uses @-codes: @BOLD@, @RED@, @RESET@
- Converted to ANSI by CLIO::UI::ANSI

=head1 WHY THIS MATTERS

The "Wide character in subroutine entry" error occurs when:
1. Perl string is flagged as UTF-8 (utf8::is_utf8() returns true)
2. String is passed to encode_json() or similar functions
3. Function expects bytes, not characters

Solution:
- Use utf8::encode() before JSON encoding
- Or use :utf8 layer for file I/O
- Or ensure consistent handling throughout stack

These test data samples will expose any encoding issues in:
- File operations (read, write, create)
- JSON encoding/decoding
- API requests/responses
- Session persistence
- Terminal output
- Tool arguments

=cut
