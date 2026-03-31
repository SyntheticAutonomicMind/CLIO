#!/usr/bin/env perl
# Test Terminal capability detection and box_char functions

use strict;
use warnings;
use utf8;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";

use CLIO::UI::Terminal qw(
    box_char supports_unicode supports_256color supports_truecolor
    supports_ansi terminal_type color_depth detect_capabilities
);

# ─────────────────────────────────────────────────────────────
# Test 1: Functions imported
# ─────────────────────────────────────────────────────────────
can_ok('main', 'box_char');
can_ok('main', 'supports_unicode');
can_ok('main', 'supports_256color');
can_ok('main', 'supports_truecolor');
can_ok('main', 'supports_ansi');
can_ok('main', 'terminal_type');
can_ok('main', 'color_depth');
can_ok('main', 'detect_capabilities');

# ─────────────────────────────────────────────────────────────
# Test 2: box_char returns non-empty strings for all known chars
# ─────────────────────────────────────────────────────────────
my @chars = qw(horizontal vertical topleft topright bottomleft bottomright
               tdown tup tleft tright cross
               dhorizontal dvertical dtopleft dtopright dbottomleft dbottomright);

for my $name (@chars) {
    my $ch = box_char($name);
    ok(defined $ch && length($ch) > 0, "box_char('$name') returns a character");
}

# ─────────────────────────────────────────────────────────────
# Test 3: Unknown char name returns fallback
# ─────────────────────────────────────────────────────────────
my $unknown = box_char('nonexistent');
ok(defined $unknown, "box_char('nonexistent') returns defined value");

# ─────────────────────────────────────────────────────────────
# Test 4: terminal_type returns valid string
# ─────────────────────────────────────────────────────────────
my $type = terminal_type();
ok(defined $type, "terminal_type() returns defined value");
like($type, qr/^(graphical|console|serial|dumb)$/, "terminal_type() returns valid type: $type");

# ─────────────────────────────────────────────────────────────
# Test 5: color_depth returns valid value
# ─────────────────────────────────────────────────────────────
my $depth = color_depth();
ok(defined $depth, "color_depth() defined");
like($depth, qr/^(truecolor|256|16|mono)$/, "color_depth() returns valid depth: $depth");

# ─────────────────────────────────────────────────────────────
# Test 6: detect_capabilities returns hashref with expected keys
# ─────────────────────────────────────────────────────────────
my $caps = detect_capabilities();
ok(ref($caps) eq 'HASH', "detect_capabilities returns hashref");
ok(exists $caps->{unicode}, "capabilities has 'unicode' key");
ok(exists $caps->{color_256}, "capabilities has 'color_256' key");
ok(exists $caps->{truecolor}, "capabilities has 'truecolor' key");
ok(exists $caps->{term_type}, "capabilities has 'term_type' key");

# ─────────────────────────────────────────────────────────────
# Test 7: Force ASCII mode and verify fallback chars
# ─────────────────────────────────────────────────────────────
{
    CLIO::UI::Terminal::set_unicode_support(0);
    
    is(box_char('horizontal'), '-', "ASCII mode: horizontal is '-'");
    is(box_char('vertical'), '|', "ASCII mode: vertical is '|'");
    is(box_char('topleft'), '+', "ASCII mode: topleft is '+'");
    is(box_char('cross'), '+', "ASCII mode: cross is '+'");
    is(box_char('dhorizontal'), '=', "ASCII mode: dhorizontal is '='");
}

# ─────────────────────────────────────────────────────────────
# Test 8: Force Unicode mode and verify proper chars
# ─────────────────────────────────────────────────────────────
{
    CLIO::UI::Terminal::set_unicode_support(1);
    
    is(box_char('horizontal'), "\x{2500}", "Unicode mode: horizontal is U+2500");
    is(box_char('vertical'), "\x{2502}", "Unicode mode: vertical is U+2502");
    is(box_char('topleft'), "\x{250C}", "Unicode mode: topleft is U+250C");
    is(box_char('cross'), "\x{253C}", "Unicode mode: cross is U+253C");
    is(box_char('dhorizontal'), "\x{2550}", "Unicode mode: dhorizontal is U+2550");
}

# ─────────────────────────────────────────────────────────────
# Test 9: Restore auto-detection
# ─────────────────────────────────────────────────────────────
CLIO::UI::Terminal::_detect_capabilities();
ok(1, "Auto-detection restored without error");

# ─────────────────────────────────────────────────────────────
# Test 10: Boolean accessors return 0 or 1
# ─────────────────────────────────────────────────────────────
for my $fn (qw(supports_unicode supports_truecolor supports_256color supports_ansi)) {
    no strict 'refs';
    my $val = $fn->();
    ok($val == 0 || $val == 1, "$fn() returns boolean: $val");
}


# Test 11: ui_char function imports and works
use CLIO::UI::Terminal qw(ui_char supports_cp437);
can_ok('main', 'ui_char');
can_ok('main', 'supports_cp437');

# Test 12: ui_char returns non-empty for all known names
my @ui_names = qw(bullet separator footer_sep ellipsis arrow_right
                   arrow_left check cross_mark dot dash pipe);
for my $name (@ui_names) {
    my $ch = ui_char($name);
    ok(defined $ch && length($ch) > 0, "ui_char('$name') returns a character");
}

# Test 13: ui_char unknown name returns fallback
is(ui_char('nonexistent'), '?', "ui_char('nonexistent') returns '?'");

# Test 14: Force ASCII mode - ui_char returns ASCII
{
    CLIO::UI::Terminal::set_unicode_support(0);
    CLIO::UI::Terminal::set_cp437_support(0);
    is(ui_char('bullet'), '*', "ASCII: bullet is '*'");
    is(ui_char('separator'), '>', "ASCII: separator is '>'");
    is(ui_char('footer_sep'), '_', "ASCII: footer_sep is '_'");
    is(ui_char('ellipsis'), '...', "ASCII: ellipsis");
    is(ui_char('arrow_right'), '->', "ASCII: arrow_right");
    is(ui_char('check'), '+', "ASCII: check");
    is(ui_char('pipe'), '|', "ASCII: pipe");
}

# Test 15: Force CP437 mode
{
    CLIO::UI::Terminal::set_unicode_support(0);
    CLIO::UI::Terminal::set_cp437_support(1);
    is(ui_char('bullet'), "\x{2219}", "CP437: bullet");
    is(ui_char('separator'), "\x{2192}", "CP437: separator");
    is(ui_char('ellipsis'), '...', "CP437: ellipsis stays ASCII");
    is(ui_char('check'), "\x{221A}", "CP437: check is sqrt");
}

# Test 16: Force Unicode mode
{
    CLIO::UI::Terminal::set_unicode_support(1);
    is(ui_char('bullet'), "\x{2219}", "Unicode: bullet");
    is(ui_char('separator'), "\x{2192}", "Unicode: separator");
    is(ui_char('ellipsis'), "\x{2026}", "Unicode: ellipsis");
    is(ui_char('arrow_right'), "\x{2192}", "Unicode: arrow_right");
    is(ui_char('check'), "\x{2713}", "Unicode: check");
    is(ui_char('cross_mark'), "\x{2717}", "Unicode: cross_mark");
}

# Test 17: supports_cp437 returns boolean
CLIO::UI::Terminal::_detect_capabilities();
{
    my $val = supports_cp437();
    ok($val == 0 || $val == 1, "supports_cp437() returns boolean: $val");
}

# Test 18: detect_capabilities includes cp437 key
{
    my $caps2 = detect_capabilities();
    ok(exists $caps2->{cp437}, "capabilities has 'cp437' key");
}

done_testing();
