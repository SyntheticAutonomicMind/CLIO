#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use CLIO::UI::ANSI;

my $ansi = CLIO::UI::ANSI->new();

print "\n=== CLIO @-Code System Test ===\n\n";

print $ansi->parse('@BOLD@@CYAN@CLIO@RESET@ - @DIM@Command Line Intelligent Operator@RESET@' . "\n\n");

print $ansi->parse('@BOLD@Text Attributes:@RESET@' . "\n");
print $ansi->parse('  @BOLD@Bold text@RESET@' . "\n");
print $ansi->parse('  @DIM@Dim text@RESET@' . "\n");
print $ansi->parse('  @ITALIC@Italic text@RESET@' . "\n");
print $ansi->parse('  @UNDERLINE@Underlined text@RESET@' . "\n");
print "\n";

print $ansi->parse('@BOLD@Colors:@RESET@' . "\n");
print $ansi->parse('  @RED@Red@RESET@ @GREEN@Green@RESET@ @BLUE@Blue@RESET@ @YELLOW@Yellow@RESET@' . "\n");
print $ansi->parse('  @BRIGHT_RED@Bright Red@RESET@ @BRIGHT_GREEN@Bright Green@RESET@ @BRIGHT_BLUE@Bright Blue@RESET@' . "\n");
print "\n";

print $ansi->parse('@BOLD@Cursor & Line Operations:@RESET@' . "\n");
print "Line 1\n";
print "Line 2\n";
print $ansi->parse('@CURSOR_UP@@CLL@Updated Line 2@CR@' . "\n");
print "\n";

print $ansi->parse('@BOLD@Combined Formatting:@RESET@' . "\n");
print $ansi->parse('  @BOLD@@GREEN@✓@RESET@ Success message' . "\n");
print $ansi->parse('  @BOLD@@RED@✗@RESET@ Error message' . "\n");
print $ansi->parse('  @BOLD@@YELLOW@⚠@RESET@ Warning message' . "\n");
print "\n";

# Test strip function
my $with_codes = '@BOLD@@RED@Hello@RESET@ @BLUE@World@RESET@';
print "With codes: $with_codes\n";
print "Stripped: " . $ansi->strip($with_codes) . "\n";
print "\n";
