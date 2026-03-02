#!/usr/bin/perl
# Test: Wide character display width in ReadLine
# Covers fix for issue #13 - Chinese/wide character deletion broken

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');

use lib '../../lib';
use CLIO::Core::ReadLine;

my ($pass, $fail) = (0, 0);

sub ok {
    my ($got, $expected, $label) = @_;
    if ($got == $expected) {
        print "PASS: $label\n";
        $pass++;
    } else {
        print "FAIL: $label (expected $expected, got $got)\n";
        $fail++;
    }
}

# --- _display_width tests ---

ok(CLIO::Core::ReadLine::_display_width("hello"),                              5, "ASCII string");
ok(CLIO::Core::ReadLine::_display_width(""),                                   0, "empty string");
ok(CLIO::Core::ReadLine::_display_width("a"),                                  1, "single ASCII");
ok(CLIO::Core::ReadLine::_display_width("\x{4F60}"),                           2, "single CJK: 你 (U+4F60)");
ok(CLIO::Core::ReadLine::_display_width("\x{597D}"),                           2, "single CJK: 好 (U+597D)");
ok(CLIO::Core::ReadLine::_display_width("\x{4F60}\x{597D}"),                   4, "two CJK chars: 你好");
ok(CLIO::Core::ReadLine::_display_width("\x{4F60}\x{597D}\x{4E16}\x{754C}"),  8, "four CJK: 你好世界");
ok(CLIO::Core::ReadLine::_display_width("abc\x{4F60}de"),                      7, "mixed ASCII+CJK");
ok(CLIO::Core::ReadLine::_display_width("\x{3042}"),                           2, "Hiragana: あ");
ok(CLIO::Core::ReadLine::_display_width("\x{30A2}"),                           2, "Katakana: ア");
ok(CLIO::Core::ReadLine::_display_width("\x{AC00}"),                           2, "Hangul: 가");
ok(CLIO::Core::ReadLine::_display_width("\x{1F600}"),                          2, "emoji: 😀");
ok(CLIO::Core::ReadLine::_display_width("\x{FF21}"),                           2, "fullwidth A: Ａ");
ok(CLIO::Core::ReadLine::_display_width("abc"),                                3, "three ASCII");
ok(CLIO::Core::ReadLine::_display_width("  "),                                 2, "two spaces");

# Verify that the ReadLine object can be created (basic smoke test)
my $rl = CLIO::Core::ReadLine->new(prompt => '> ');
if (ref($rl) eq 'CLIO::Core::ReadLine') {
    print "PASS: ReadLine object created\n";
    $pass++;
} else {
    print "FAIL: Could not create ReadLine object\n";
    $fail++;
}

print "\n$pass passed, $fail failed\n";
exit($fail > 0 ? 1 : 0);
