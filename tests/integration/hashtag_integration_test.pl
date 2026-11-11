#!/usr/bin/env perl
use strict;
use warnings;
use lib 'lib';

# Requires a live API provider; see tests/lib/TestHelpers.pm for why this is
# an explicit opt-in and not a "config file exists" check.
BEGIN {
    require File::Basename;
    require File::Spec;
    unshift @INC, File::Spec->catdir(File::Basename::dirname(__FILE__), '..', 'lib');
    require TestHelpers;
    TestHelpers::skip_unless_live_api();
}

# Create a simple test file for hashtag testing
use File::Temp qw(tempfile);
my ($fh, $filename) = tempfile();
print $fh "This is a test file.\nIt has multiple lines.\nLine 3 here.\n";
close $fh;

print "Created test file: $filename\n";
print "Testing hashtag integration with CLIO...\n\n";

# Test with #file hashtag
print "=" x 60 . "\n";
print "Test: #file hashtag\n";
print "=" x 60 . "\n";

my $cmd = qq{echo "Summarize #file:$filename" | ./clio --exit 2>/dev/null};
print "Command: $cmd\n\n";
print "Output:\n";
system($cmd);

print "\n\n";

# Test with #folder hashtag
print "=" x 60 . "\n";
print "Test: #folder hashtag\n";
print "=" x 60 . "\n";

$cmd = qq{echo "What files are in #folder:lib/CLIO/Core?" | ./clio --exit 2>/dev/null};
print "Command: $cmd\n\n";
print "Output:\n";
system($cmd);

print "\n\n";

# Cleanup
unlink $filename;
print "Test complete!\n";
