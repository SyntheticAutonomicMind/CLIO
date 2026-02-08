#!/usr/bin/perl

use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../../lib";

use Test::Simple tests => 19;
use CLIO::UI::Markdown;
use CLIO::UI::Theme;
use CLIO::UI::ANSI;

# Setup
my $ansi = CLIO::UI::ANSI->new(enabled => 1);
my $theme_mgr = CLIO::UI::Theme->new(ansi => $ansi, debug => 0);
my $md = CLIO::UI::Markdown->new(theme_mgr => $theme_mgr, debug => 0);

# Test 1: Inline formula recognition
my $inline = 'E equals $E = mc^2$ in physics';
my $result = $md->render($inline);
ok($result =~ /E = mc/, 'Inline formula recognized and rendered');
ok($result =~ /\$E = mc/, 'Dollar signs and formula preserved in output');

# Test 2: Display formula recognition (block-level)
my $display = "The integral:\n\$\$\\int_0^{\\infty} e^{-x^2} dx = \\frac{\\sqrt{\\pi}}{2}\$\$\nEnd of formula";
$result = $md->render($display);
ok($result =~ /Formula/, 'Display formula creates a frame');
ok($result =~ /int/, 'Display formula contains content');

# Test 3: Greek letter conversion
my $greek = '$\\alpha + \\beta = \\gamma$';
$result = $md->render($greek);
ok($result =~ /α/, 'Alpha symbol rendered');
ok($result =~ /β/, 'Beta symbol rendered');
ok($result =~ /γ/, 'Gamma symbol rendered');

# Test 4: Math operator conversion
my $ops = '$\\sqrt{x} + \\sum_{i=1}^{n} x_i = \\infty$';
$result = $md->render($ops);
ok($result =~ /√/, 'Square root symbol rendered');
ok($result =~ /∑/, 'Sum symbol rendered');
ok($result =~ /∞/, 'Infinity symbol rendered');

# Test 5: Comparison operators
my $comp = '$a \\leq b \\neq c \\geq d$';
$result = $md->render($comp);
ok($result =~ /≤/, 'Less-than-or-equal rendered');
ok($result =~ /≠/, 'Not-equal rendered');
ok($result =~ /≥/, 'Greater-than-or-equal rendered');

# Test 6: Superscript conversion
my $super = '$x^2 + y^3 = z^n$';
$result = $md->render($super);
ok($result =~ /²/, 'Superscript 2 rendered');
ok($result =~ /³/, 'Superscript 3 rendered');
ok($result =~ /ⁿ/, 'Superscript n rendered');

# Test 7: Strip markdown removes formulas
my $text_with_formula = 'The formula $E = mc^2$ is famous';
my $stripped = $md->strip_markdown($text_with_formula);
ok($stripped =~ /E = mc/, 'Formula content preserved in stripped text');
ok($stripped !~ /\$/, 'Dollar signs removed in stripped text');

# Test 8: E=mc^2 special case
my $einstein = '$E = mc^2$';
$result = $md->render($einstein);
ok($result =~ /E = mc²/, 'Einstein formula special case works');

print "All formula tests passed!\n";
