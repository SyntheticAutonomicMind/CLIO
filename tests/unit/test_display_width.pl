#!/usr/bin/env perl

# Terminal column widths must agree with what the terminal actually draws.
# A table padded with the wrong width shows a misaligned right border.

use strict;
use warnings;
use utf8;
use lib 'lib';

use Test::More;
use CLIO::Util::DisplayWidth qw(
    display_width
    is_wide
    is_zero_width
    is_regional_indicator
);

is(display_width(undef), 0, 'undef is zero columns');
is(display_width(''), 0, 'empty string is zero columns');
is(display_width('abc'), 3, 'ASCII is one column per character');
is(display_width('a b-c_1'), 7, 'printable ASCII fast path');

# Emoji that terminals draw two columns wide. U+2705 and U+274C are East
# Asian Wide; the markdown table renderer used to count them as one, which
# pushed the closing border one column right.
is(display_width("\x{2705}"), 2, 'U+2705 white heavy check mark is two columns');
is(display_width("\x{274C}"), 2, 'U+274C cross mark is two columns');
is(display_width("\x{1F41B}"), 2, 'U+1F41B bug is two columns');
is(display_width("\x{1F680}"), 2, 'U+1F680 rocket is two columns');

# Text-presentation symbol on its own stays narrow; with VS16 it is an
# emoji presentation sequence and renders two columns.
is(display_width("\x{26A0}"), 1, 'U+26A0 alone is one column');
is(display_width("\x{26A0}\x{FE0F}"), 2, 'U+26A0 + VS16 is two columns');
is(display_width("\x{2764}\x{FE0F}"), 2, 'U+2764 + VS16 is two columns');

# CJK and fullwidth forms.
is(display_width("\x{4E2D}\x{6587}"), 4, 'two CJK ideographs are four columns');
is(display_width("\x{FF21}\x{FF22}"), 4, 'fullwidth latin is two columns each');

# Zero-width and combining sequences.
is(display_width("e\x{0301}"), 1, 'combining acute adds no width');
is(display_width("a\x{200D}b"), 2, 'ZWJ contributes no width');
is(display_width("\x{200B}"), 0, 'zero width space is zero columns');

# Flags: a regional indicator pair is one two-column glyph.
is(display_width("\x{1F1FA}\x{1F1F8}"), 2, 'US flag is two columns');

# Mixed content: status cell with an emoji plus padding.
is(display_width(" \x{2705}     "), 8, 'emoji cell with padding is eight columns');

# Predicates
ok(is_wide(0x2705), 'U+2705 is wide');
ok(!is_wide(ord('a')), 'ASCII letter is not wide');
ok(is_zero_width(0x0301), 'combining acute is zero width');
ok(is_zero_width(0xFE0F), 'variation selector is zero width');
ok(!is_zero_width(ord('a')), 'ASCII letter is not zero width');
ok(is_regional_indicator(0x1F1FA), 'U+1F1FA is a regional indicator');
ok(!is_regional_indicator(ord('A')), 'ASCII A is not a regional indicator');

done_testing();
