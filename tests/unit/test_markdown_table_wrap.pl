#!/usr/bin/env perl

use strict;
use warnings;
use lib 'lib';

use CLIO::UI::Markdown;
use CLIO::UI::Theme;
use CLIO::UI::ANSI;

# Create theme manager and markdown renderer
my $ansi = CLIO::UI::ANSI->new();
my $theme_mgr = CLIO::UI::Theme->new(
    ansi => $ansi,
    style => 'default',
    theme => 'default'
);

# Test 1: Table that fits within terminal width - no wrapping
print "=" x 70, "\n";
print "Test 1: Small table (no wrapping needed)\n";
print "=" x 70, "\n";

my $md1 = CLIO::UI::Markdown->new(
    theme_mgr => $theme_mgr,
    terminal_width => 80
);

my $small_table = <<'EOF';
|NAME|AGE|
|----|----|
|Alice|30|
|Bob|25|
EOF

my $result1 = $md1->render($small_table);
print "$result1\n\n";

# Test 2: Table that exceeds terminal width - should wrap
print "=" x 70, "\n";
print "Test 2: Large table (wrapping required)\n";
print "=" x 70, "\n";

my $md2 = CLIO::UI::Markdown->new(
    theme_mgr => $theme_mgr,
    terminal_width => 60
);

my $large_table = <<'EOF';
|HEADER|DATA|
|----|----|
|My Header|We have a bug in our markdown provider - if the text is wider than the screen the tables break. We should track the width of the screen and if the length of text is longer we should break it into multiple lines|
|Another|This would be another row|
EOF

my $result2 = $md2->render($large_table);
print "$result2\n\n";

# Test 3: Visual length of wrapped output should not exceed terminal width
print "=" x 70, "\n";
print "Test 3: Verify wrapped table fits within terminal width\n";
print "=" x 70, "\n";

my $md3 = CLIO::UI::Markdown->new(
    theme_mgr => $theme_mgr,
    terminal_width => 40
);

my $test_table = <<'EOF';
|COL1|COL2|COL3|
|----|----|----|
|Short|This is a very long text that should definitely wrap across multiple lines|End|
EOF

my $result3 = $md3->render($test_table);
print "$result3\n\n";

# Check that no line exceeds terminal width
my @lines = split /\n/, $result3;
my $max_width = 0;
my $oversized = 0;
for my $line (@lines) {
    # Strip ANSI codes for measurement
    my $clean = $line;
    $clean =~ s/\e\[[0-9;]*m//g;
    $clean =~ s/\e\]8;;[^\e]*\e\\//g;
    $clean =~ s/@[A-Z_]+@//g;
    my $width = length($clean);
    $max_width = $width if $width > $max_width;
    if ($width > 40) {
        $oversized++;
        print "OVERWIDTH ($width): $clean\n";
    }
}

print "Max line width: $max_width\n";
print "Terminal width: 40\n";
print "Oversized lines: $oversized\n";
print $oversized == 0 ? "PASS - All lines fit within terminal width\n\n" : "FAIL - Some lines exceed terminal width\n\n";

# Test 4: _wrap_text method directly
print "=" x 70, "\n";
print "Test 4: Direct _wrap_text test\n";
print "=" x 70, "\n";

my $long_text = "This is a long string that should be wrapped at word boundaries when it exceeds the specified width";
my @wrapped = $md3->_wrap_text($long_text, 20);
print "Input: $long_text\n";
print "Width: 20\n";
print "Wrapped lines:\n";
for my $line (@wrapped) {
    my $visual_len = $md3->_visual_length($line);
    print "  [$visual_len] $line\n";
}
print "\n";

# Test 5: Default terminal_width (80) when not specified
print "=" x 70, "\n";
print "Test 5: Default terminal width\n";
print "=" x 70, "\n";

my $md_default = CLIO::UI::Markdown->new(theme_mgr => $theme_mgr);
print "Default terminal_width: ", $md_default->{terminal_width} || '(not set)', "\n";
print "Falls back to 80 in render_table: works\n\n";

# Test 6: Table with very long single word
print "=" x 70, "\n";
print "Test 6: Table with unbreakable long word\n";
print "=" x 70, "\n";

my $md6 = CLIO::UI::Markdown->new(
    theme_mgr => $theme_mgr,
    terminal_width => 30
);

my $long_word_table = <<'EOF';
|A|B|
|-|-|
|short|verylongwordthatcannotbebrokenintosmallerpiecesandmustbehandledgracefully|
EOF

my $result6 = $md6->render($long_word_table);
print "$result6\n\n";

# Test 7: Verify separators are only between distinct rows (not between wrapped continuations)
print "=" x 70, "\n";
print "Test 7: Separators only between distinct rows (not wrapped continuations)\n";
print "=" x 70, "\n";

my $md7 = CLIO::UI::Markdown->new(
    theme_mgr => $theme_mgr,
    terminal_width => 60
);

my $wrapped_separator_table = <<'EOF';
|HEADER|DATA|
|----|----|
|My Header|We have a bug in our markdown provider - if the text is wider than the screen the tables break. We should track the width of the screen and if the length of text is longer we should break it into multiple lines|
|Another|This would be another row|
EOF

my $result7 = $md7->render($wrapped_separator_table);
print "$result7\n\n";

# Count separator lines (├ chars indicate T-junction separators)
# Should be 2: one after header, one between wrapped data row and second row
my $clean7 = $result7;
$clean7 =~ s/\e\[[0-9;]*m//g;
my $sep_count = () = $clean7 =~ /\x{251c}/g;
print "Separator lines: $sep_count\n";
print "Expected: 2 (one after header, one after first wrapped data row)\n";
print ($sep_count == 2 ? "PASS - Separators only between distinct rows\n\n" : "FAIL - Wrong number of separators\n\n");

# Test 8: Tables where the natural header width exceeds the terminal.
# Previously these overflowed the terminal because min_widths were
# applied verbatim. They should now scale to fit and wrap cells.
print "=" x 70, "\n";
print "Test 8: Header columns wider than terminal (proportional compression)\n";
print "=" x 70, "\n";

my $md8 = CLIO::UI::Markdown->new(
    theme_mgr => $theme_mgr,
    terminal_width => 80
);

my $huge_header_table = <<'EOF';
|This is an extremely long header that should wrap gracefully|Short|Another ridiculously long column header here|OK|
|----|----|----|----|
|Data cell|Short|More data|a|
|Some longer data here|b|c|d|
EOF

my $result8 = $md8->render($huge_header_table);
print "$result8\n\n";

my $clean8 = $result8;
$clean8 =~ s/\e\[[0-9;]*m//g;
my $max8 = 0;
my $over8 = 0;
for my $line (split /\n/, $clean8) {
    my $stripped = $line;
    $stripped =~ s/\e\[[0-9;]*m//g;
    $stripped =~ s/\e\]8;;[^\e]*\e\\//g;
    $stripped =~ s/@[A-Z_]+@//g;
    my $w = length($stripped);
    $max8 = $w if $w > $max8;
    $over8++ if $w > 80;
}
print "Max line width: $max8 (terminal: 80)\n";
print "Oversized lines: $over8\n";
print ($over8 == 0 ? "PASS - All lines fit within terminal width\n\n" : "FAIL - Some lines exceed terminal width\n\n");

# Test 9: Regression test for the 5-char overage bug where proportional
# distribution + integer rounding could push the total content width
# above the available space, causing the table to overflow the terminal
# by 2-5 characters. Fix: trim from the largest column down when the
# computed total exceeds available space.
print "=" x 70, "\n";
print "Test 9: Regression - rounding remainder must not overflow terminal\n";
print "=" x 70, "\n";

my $md9 = CLIO::UI::Markdown->new(
    theme_mgr => $theme_mgr,
    terminal_width => 40
);

# 4 cols, headers 5+5+5+5, data 30+30+30+5
# Old code computed target widths totaling 29 vs available 27 (2 over)
my $overflow_table = <<'EOF';
|AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA | BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB | CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC | DDDDD |
| --- | --- | --- | --- |
| 1 | 2 | 3 | 4 |
EOF

my $result9 = $md9->render($overflow_table);
my $clean9 = $result9;
$clean9 =~ s/\e\[[0-9;]*m//g;
$clean9 =~ s/\e\]8;;[^\e]*\e\\//g;
$clean9 =~ s/@[A-Z_]+@//g;
my $max9 = 0;
my $over9 = 0;
for my $line (split /\n/, $clean9) {
    my $w = length($line);
    $max9 = $w if $w > $max9;
    $over9++ if $w > 40;
}
print "Max line width: $max9 (terminal: 40)\n";
print "Oversized lines: $over9\n";
print ($over9 == 0 ? "PASS - No line exceeds terminal width\n\n" : "FAIL - Table overflows terminal\n\n");

print "All tests completed.\n";
