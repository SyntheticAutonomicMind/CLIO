#!/usr/bin/env perl

# Markdown table borders and row content must occupy the same number of
# terminal columns. Emoji with East Asian Width = Wide (status checkmarks
# and crosses) used to be counted as one column, so every row containing
# one rendered a column wider than its border.

use strict;
use warnings;
use utf8;
use lib 'lib';

use Test::More;
use CLIO::UI::Markdown;
use CLIO::Util::DisplayWidth qw(display_width);

sub strip_ansi {
    my ($text) = @_;
    $text =~ s/\e\[[0-9;]*m//g;      # SGR
    $text =~ s/\e\]8;;[^\e]*\e\\//g; # OSC 8 hyperlink wrappers
    $text =~ s/\e\][^\e\x07]*(\e\\|\x07)//g;
    return $text;
}

# Width of a line exactly as the terminal would draw it: markdown @-codes
# removed, ANSI removed, emoji counted at their real column count.
sub line_width {
    my ($line) = @_;
    my $plain = $line;
    $plain =~ s/\@[A-Z_]+\@//g;
    $plain = strip_ansi($plain);
    return display_width($plain);
}

sub assert_aligned {
    my ($label, $rendered) = @_;
    my @lines = grep { length } split /\n/, $rendered;
    return unless @lines;

    my $border = line_width($lines[0]);
    for my $i (0 .. $#lines) {
        is(line_width($lines[$i]), $border,
            "$label: line " . ($i + 1) . " is $border columns");
    }
}

my $md = CLIO::UI::Markdown->new(terminal_width => 120);

my $emoji_table = "| Tool | Status | Notes |\n"
                . "|------|--------|-------|\n"
                . "| skill_list | \x{2705} | Returns all installed skills |\n"
                . "| skill_load | \x{274C} | Fails when the name is wrong |\n"
                . "| skill_create | \x{2705} | Writes a new skill file |\n";

assert_aligned('emoji table', $md->render($emoji_table));

# Mixed scripts in one cell: CJK, VS16 emoji presentation, combining marks.
my $mixed_table = "| Label | Value |\n"
                . "|-------|-------|\n"
                . "| \x{4E2D}\x{6587} | \x{26A0}\x{FE0F} warning |\n"
                . "| cafe\x{0301} | plain |\n";

assert_aligned('mixed script table', $md->render($mixed_table));

# The wrapping path recomputes column widths, so it has to agree too.
my $narrow = CLIO::UI::Markdown->new(terminal_width => 44);
my $wrapped_table = "| Item | Result | Detail |\n"
                  . "|------|--------|--------|\n"
                  . "| build | \x{2705} | Compiles cleanly with no warnings at all |\n"
                  . "| tests | \x{274C} | Three failures in the protocol suite |\n";

my $wrapped = $narrow->render($wrapped_table);
assert_aligned('wrapped emoji table', $wrapped);

# The emoji must survive rendering intact; sanitizing them out of display
# output is not this renderer's job.
like($md->render($emoji_table), qr/\x{2705}/, 'emoji preserved in output');

done_testing();
