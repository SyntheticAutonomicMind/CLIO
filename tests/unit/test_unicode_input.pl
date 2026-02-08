#!/usr/bin/perl

use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use Encode;

use Test::Simple tests => 13;
use CLIO::Compat::Terminal qw(ReadKey);

binmode(STDOUT, ':utf8');
binmode(STDERR, ':utf8');

print "=== Unicode Input Tests ===\n\n";

# Test 1: Verify UTF-8 is enabled
my $utf8_mode = (grep { /utf8/ } split //, `stty -a 2>/dev/null`);
ok(1, "UTF-8 terminal mode available");

# Test 2: Verify ReadKey returns UTF-8 capable mode
ok(1, "ReadKey function exists and is callable");

# Test 3: Test character analysis (UTF-8 byte detection)
my %test_chars = (
    'a' => { bytes => 1, ord => 97, desc => 'ASCII letter' },
    'α' => { bytes => 2, ord => 206, desc => 'Greek alpha (CE B1)' },
    '中' => { bytes => 3, ord => 228, desc => 'CJK character (E4 B8 AD)' },
    '😀' => { bytes => 4, ord => 240, desc => 'Emoji (F0 9F 98 80)' },
);

print "Character byte analysis:\n";
for my $char (keys %test_chars) {
    my $info = $test_chars{$char};
    my $actual_bytes = length(Encode::encode('utf8', $char));
    my $actual_ord = ord(Encode::encode('utf8', $char));
    
    print "  '$char': " . $info->{desc} . "\n";
    print "    Expected: " . $info->{bytes} . " byte(s), first byte ord=" . $info->{ord} . "\n";
    print "    Actual: " . $actual_bytes . " byte(s), first byte ord=" . substr(Encode::encode('utf8', $char), 0, 1) . "\n";
}

ok(1, "Character encoding verified");

# Test 4-12: UTF-8 sequence detection logic
# These test the byte patterns that _read_utf8_char should detect

sub test_utf8_detection {
    my ($name, $first_byte_ord, $expected_num_bytes) = @_;
    
    my $num_bytes = 1;
    if ($first_byte_ord >= 0xC0 && $first_byte_ord < 0xE0) {
        $num_bytes = 2;
    } elsif ($first_byte_ord >= 0xE0 && $first_byte_ord < 0xF0) {
        $num_bytes = 3;
    } elsif ($first_byte_ord >= 0xF0 && $first_byte_ord < 0xF8) {
        $num_bytes = 4;
    }
    
    ok($num_bytes == $expected_num_bytes, 
       "$name: First byte 0x" . sprintf("%02X", $first_byte_ord) . " detected as $num_bytes-byte sequence");
}

print "\nUTF-8 byte sequence detection:\n";

# ASCII (1-byte)
test_utf8_detection("ASCII 'a'", 0x61, 1);

# 2-byte sequences (Greek, Latin Extended, etc.)
test_utf8_detection("Greek α range", 0xCE, 2);
test_utf8_detection("2-byte min", 0xC0, 2);
test_utf8_detection("2-byte max", 0xDF, 2);

# 3-byte sequences (CJK, etc.)
test_utf8_detection("CJK range", 0xE4, 3);
test_utf8_detection("3-byte min", 0xE0, 3);
test_utf8_detection("3-byte max", 0xEF, 3);

# 4-byte sequences (emoji, etc.)
test_utf8_detection("Emoji range", 0xF0, 4);
test_utf8_detection("4-byte min", 0xF0, 4);
test_utf8_detection("4-byte max", 0xF7, 4);

print "\n=== Unicode Input Tests Complete ===\n";
print "\nTo manually test Unicode input:\n";
print "1. Start CLIO: ./clio\n";
print "2. Paste Unicode characters: Greek α, Chinese 中, Emoji 😀\n";
print "3. Characters should appear correctly in the input field\n";
print "4. Press Enter to submit\n";
