#!/usr/bin/env perl
# Test: theme system expansion - layout keys + new themes
# Covers:
#   - separator_repeat theme key controls hrule length in ToolOutputFormatter
#   - indent_width theme key controls indent width
#   - dense and spacious themes are loadable
#   - dense has tighter separator/indent than spacious

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');

use FindBin qw($RealBin);
use Cwd qw(abs_path);
use lib '../../lib';

BEGIN {
    no warnings 'redefine';
    require CLIO::Compat::Terminal;
    *CLIO::Compat::Terminal::GetTerminalSize = sub { return (80, 24); };
}

use CLIO::UI::Theme;

my ($pass, $fail) = (0, 0);

sub ok_str {
    my ($got, $expected, $label) = @_;
    if (defined $got && $got eq $expected) {
        print "PASS: $label\n";
        $pass++;
    } else {
        print "FAIL: $label (got='$got', expected='$expected')\n";
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
my $repo = abs_path("$RealBin/../..");
my $t = CLIO::UI::Theme->new(debug => 0, base_dir => $repo);

# --- Both new themes exist ---
{
    my @themes = $t->list_themes();
    my %set = map { $_ => 1 } @themes;
    ok_int(($set{dense} ? 1 : 0), 1, 'dense theme is listed');
    ok_int(($set{spacious} ? 1 : 0), 1, 'spacious theme is listed');
}

# --- Theme files parse and have expected layout keys ---
{
    for my $name (qw(default compact verbose dense spacious)) {
        my $theme = $t->{themes}->{$name};
        unless ($theme) {
            print "FAIL: theme '$name' not loaded\n";
            $fail++;
            next;
        }
        unless (exists $theme->{separator_repeat}) {
            print "FAIL: theme '$name' missing separator_repeat\n";
            $fail++;
        }
        unless (exists $theme->{indent_width}) {
            print "FAIL: theme '$name' missing indent_width\n";
            $fail++;
        }
        unless (exists $theme->{show_timestamps}) {
            print "FAIL: theme '$name' missing show_timestamps\n";
            $fail++;
        }
    }
    if ($fail == 0) {
        print "PASS: all themes have separator_repeat/indent_width/show_timestamps\n";
        $pass++;
    }
}

# --- Layout key values match per-theme intent ---
{
    # compact: tighter than default
    ok_int($t->{themes}->{compact}->{separator_repeat} + 0, 20, 'compact separator_repeat=20');
    ok_int($t->{themes}->{compact}->{indent_width} + 0, 2, 'compact indent_width=2');

    # default: middle values
    ok_int($t->{themes}->{default}->{separator_repeat} + 0, 35, 'default separator_repeat=35');
    ok_int($t->{themes}->{default}->{indent_width} + 0, 4, 'default indent_width=4');

    # verbose: longest
    ok_int($t->{themes}->{verbose}->{separator_repeat} + 0, 60, 'verbose separator_repeat=60');

    # dense: tightest
    ok_int($t->{themes}->{dense}->{separator_repeat} + 0, 15, 'dense separator_repeat=15');
    ok_int($t->{themes}->{dense}->{indent_width} + 0, 2, 'dense indent_width=2');

    # spacious: widest
    ok_int($t->{themes}->{spacious}->{separator_repeat} + 0, 70, 'spacious separator_repeat=70');
}

# --- get_template returns the layout values ---
{
    $t->set_theme('compact');
    ok_str($t->get_template('separator_repeat'), '20', 'get_template separator_repeat (compact)');
    ok_str($t->get_template('indent_width'), '2', 'get_template indent_width (compact)');

    $t->set_theme('spacious');
    ok_str($t->get_template('separator_repeat'), '70', 'get_template separator_repeat (spacious)');
    ok_str($t->get_template('indent_width'), '4', 'get_template indent_width (spacious)');
}

# --- ToolOutputFormatter honors separator_repeat ---
{
    require CLIO::UI::ToolOutputFormatter;
    require Encode;
    package FakeChat;
    sub new {
        my ($cls, $tm) = @_;
        return bless { theme_mgr => $tm, use_color => 1, no_color => 1 }, $cls;
    }
    sub colorize { my ($s, $t, $r) = @_; return $t; }
    sub add_to_buffer {}
    package main;

    my $chat = FakeChat->new($t);
    my $tof = CLIO::UI::ToolOutputFormatter->new(ui => $chat);

    # Capture STDOUT since display_hrule uses `print` directly.
    sub capture_stdout {
        my ($code) = @_;
        my $captured = '';
        open my $out, '>', \$captured or die $!;
        my $saved = select($out);
        local $| = 1;
        $code->();
        select($saved);
        close $out;
        return Encode::decode('UTF-8', $captured);
    }

    # compact: separator_repeat=20, indent_width=2
    $t->set_theme('compact');
    my $output = capture_stdout(sub { $tof->display_hrule(); });
    my ($leading_ws) = $output =~ /^(\s*)/;
    ok_int(length($leading_ws // ''), 2, 'compact hrule uses 2-space indent');
    my ($rule_part) = $output =~ /^\s*([\x{2500}\-]+)/;
    my $rule_len = length($rule_part // '');
    ok_int($rule_len, 20, 'compact hrule has 20 chars');

    # spacious: separator_repeat=70, indent_width=4
    $t->set_theme('spacious');
    $output = capture_stdout(sub { $tof->display_hrule(); });
    ($leading_ws) = $output =~ /^(\s*)/;
    ok_int(length($leading_ws // ''), 4, 'spacious hrule uses 4-space indent');
    ($rule_part) = $output =~ /^\s*([\x{2500}\-]+)/;
    $rule_len = length($rule_part // '');
    ok_int($rule_len, 70, 'spacious hrule has 70 chars');
}

# Cleanup
$t->set_theme('default');
CLIO::UI::Theme->clear_cache();

print "\n$pass passed, $fail failed\n";
exit($fail > 0 ? 1 : 0);