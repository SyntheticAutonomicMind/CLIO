#!/usr/bin/env perl
# Test script for ReadLine wrapping behavior

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

use CLIO::Core::ReadLine;
use CLIO::Compat::Terminal qw(GetTerminalSize);

my ($width, $height) = GetTerminalSize();
print "Terminal size: ${width}x${height}\n";
print "Testing ReadLine wrapping...\n";
print "Try typing more than $width characters to test wrapping.\n";
print "Try backspace, arrow keys, Ctrl-A, Ctrl-E.\n";
print "Press Ctrl-D to exit.\n\n";

my $readline = CLIO::Core::ReadLine->new(
    prompt => 'Test> ',
    debug => 1,
);

while (1) {
    my $line = $readline->readline();
    last unless defined $line;
    
    print "You entered: $line\n";
    print "Length: " . length($line) . " characters\n\n";
}

print "Goodbye!\n";
