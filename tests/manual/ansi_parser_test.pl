#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use CLIO::UI::ANSI;

my $ansi = CLIO::UI::ANSI->new(enabled => 1);

# Use single quotes to avoid array interpolation!
my $input = 'Test @BOLD@bold@RESET@ text';
my $result = $ansi->parse($input);

print "Input:  [$input]\n";
print "Output: [$result]\n";
print "Hex:    ", unpack("H*", $result), "\n";
