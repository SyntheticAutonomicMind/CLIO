#!/usr/bin/perl
# Test: Theme module audit improvements
# Covers:
#   - clear_cache / disk-read cache
#   - check_style_data / check_theme_data validation
#   - _active_style / _active_theme fallback chains
#   - Char-resolution cache in render()
#   - ANSI precompiled regex cache

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');

use lib '../../lib';

BEGIN {
    no warnings 'redefine';
    require CLIO::Compat::Terminal;
    *CLIO::Compat::Terminal::GetTerminalSize = sub { return (80, 24); };
}

use CLIO::UI::Theme;
use CLIO::UI::ANSI;

my ($pass, $fail) = (0, 0);

sub ok {
    my ($got, $expected, $label) = @_;
    if (defined $got && $got eq $expected) {
        print "PASS: $label\n";
        $pass++;
    } else {
        print "FAIL: $label (got=" . (defined $got ? "'$got'" : 'undef') . ", expected='$expected')\n";
        $fail++;
    }
}

sub ok_int {
    my ($got, $expected, $label) = @_;
    if (defined $got && $got == $expected) {
        print "PASS: $label\n";
        $pass++;
    } else {
        print "FAIL: $label (got=" . (defined $got ? $got : 'undef') . ", expected=$expected)\n";
        $fail++;
    }
}

CLIO::UI::Theme->clear_cache();

# --- Disk-read cache ---
{
    my $t1 = CLIO::UI::Theme->new();
    my $t2 = CLIO::UI::Theme->new();

    if ($t1->{styles} == $t2->{styles}) {
        print "PASS: cache: two Theme instances share styles hashref\n";
        $pass++;
    } else {
        print "FAIL: cache: styles hashrefs differ between instances\n";
        $fail++;
    }

    if ($t1->{themes} == $t2->{themes}) {
        print "PASS: cache: two Theme instances share themes hashref\n";
        $pass++;
    } else {
        print "FAIL: cache: themes hashrefs differ between instances\n";
        $fail++;
    }
}

# --- clear_cache forces re-read ---
{
    CLIO::UI::Theme->clear_cache();
    my $after = CLIO::UI::Theme->new()->{styles};
    if (exists $after->{default}) {
        print "PASS: clear_cache: rebuilt cache contains default style\n";
        $pass++;
    } else {
        print "FAIL: clear_cache: rebuilt cache missing default style\n";
        $fail++;
    }
}

# --- Validation: good style passes ---
ok_int(CLIO::UI::Theme->check_style_data({ name => 's', primary => '@X@' }, 's.style'), 1,
    'check_style_data: valid style passes');

# --- Validation: missing required key fails ---
ok_int(CLIO::UI::Theme->check_style_data({ primary => '@X@' }, 'bad.style'), 0,
    'check_style_data: missing name fails');

# --- Validation: empty name fails ---
ok_int(CLIO::UI::Theme->check_style_data({ name => '', primary => '@X@' }, 'e.style'), 0,
    'check_style_data: empty name fails');

# --- Validation: empty hashref fails ---
ok_int(CLIO::UI::Theme->check_style_data({}, 'empty.style'), 0,
    'check_style_data: empty hashref fails');

# --- Validation: undef fails ---
ok_int(CLIO::UI::Theme->check_style_data(undef, 'undef.style'), 0,
    'check_style_data: undef fails');

# --- Validation: good theme passes ---
ok_int(CLIO::UI::Theme->check_theme_data({ name => 't' }, 't.theme'), 1,
    'check_theme_data: valid theme passes');

# --- _active_style: missing style falls back to default ---
{
    my $t = CLIO::UI::Theme->new(style => 'this_style_does_not_exist');
    my $active = $t->_active_style();
    ok($active->{name}, 'default', '_active_style: unknown style falls back to default');
}

# --- _active_style: known style returns that style ---
{
    my $t = CLIO::UI::Theme->new(style => 'default');
    my $active = $t->_active_style();
    ok($active->{name}, 'default', '_active_style: known style returns itself');
}

# --- _active_theme: missing theme falls back to default ---
{
    my $t = CLIO::UI::Theme->new(theme => 'this_theme_does_not_exist');
    my $active = $t->_active_theme();
    ok($active->{name}, 'default', '_active_theme: unknown theme falls back to default');
}

# --- get_color / get_template when both current and default are missing ---
{
    my $t = CLIO::UI::Theme->new();
    $t->{styles} = {};
    ok($t->get_color('user_prompt'), '', 'get_color: empty styles -> empty string');

    $t->{themes} = {};
    ok($t->get_template('user_prompt_format'), '', 'get_template: empty themes -> empty string');
}

# --- Render char-substitution cache works ---
{
    my $t = CLIO::UI::Theme->new();
    $t->{themes}->{default}->{test_divider} = '{char.horizontal}{char.horizontal}{char.horizontal}{char.horizontal}';
    my $rendered = $t->render('test_divider');
    my $expected_char = CLIO::UI::Terminal::box_char('horizontal');
    my $expected = $expected_char x 4;
    ok($rendered, $expected, 'render: repeated {char.X} resolves consistently');
}

# --- ANSI precompiled regex cache ---
{
    my $ansi1 = CLIO::UI::ANSI->new();
    my $r1 = $ansi1->_regex_cache();
    my $r2 = $ansi1->_regex_cache();

    if ($r1 == $r2) {
        print "PASS: ANSI regex cache: same hashref on repeated calls\n";
        $pass++;
    } else {
        print "FAIL: ANSI regex cache: rebuilt on each call\n";
        $fail++;
    }

    my $ansi2 = CLIO::UI::ANSI->new();
    my $r3 = $ansi2->_regex_cache();
    if ($r1 != $r3) {
        print "PASS: ANSI regex cache: separate cache per instance\n";
        $pass++;
    } else {
        print "FAIL: ANSI regex cache: instances share cache unexpectedly\n";
        $fail++;
    }

    my $out = $ansi1->parse(q{@RED@hello@RESET@});
    if ($out =~ /hello/) {
        print 'PASS: ANSI parse: basic @RED@ substitution works', "\n";
        $pass++;
    } else {
        print "FAIL: ANSI parse: lost 'hello' in output\n";
        $fail++;
    }
}

# --- Theme render integrates ANSI parse ---
{
    my $t = CLIO::UI::Theme->new();
    $t->{themes}->{default}->{simple} = q{@RED@hello@RESET@};
    my $rendered = $t->render('simple');
    if ($rendered =~ /hello/) {
        print "PASS: Theme.render: ANSI codes survive render\n";
        $pass++;
    } else {
        print "FAIL: Theme.render: ANSI codes lost\n";
        $fail++;
    }
}

print "\n$pass passed, $fail failed\n";
exit($fail > 0 ? 1 : 0);