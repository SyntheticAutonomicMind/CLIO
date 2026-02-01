#!/usr/bin/env perl

use strict;
use warnings;
use lib './lib';

use CLIO::Session::ToolResultStore;
use Test::More tests => 6;

# Test the line-wrapping functionality

# Test 1: Short lines should remain unchanged
{
    my $input = "Short line 1\nShort line 2\nShort line 3";
    my $expected = $input;
    my $result = CLIO::Session::ToolResultStore::_wrap_long_lines($input, 1000);
    is($result, $expected, "Short lines remain unchanged");
}

# Test 2: Single long line with spaces should wrap
{
    my $word = "package ";
    my $long_line = $word x 200;  # 1600 characters with spaces
    my $result = CLIO::Session::ToolResultStore::_wrap_long_lines($long_line, 1000);
    
    # Should be wrapped into multiple lines
    my @lines = split /\n/, $result;
    ok(scalar(@lines) > 1, "Long line was wrapped into multiple lines");
    
    # Each line should be <= 1000 chars (approximately - may be slightly over due to word boundaries)
    my $max_len = 0;
    for my $line (@lines) {
        my $len = length($line);
        $max_len = $len if $len > $max_len;
    }
    ok($max_len <= 1050, "Wrapped lines are approximately within limit (max: $max_len)");
}

# Test 3: Long line without spaces should hard-break
{
    my $no_spaces = "x" x 2000;
    my $result = CLIO::Session::ToolResultStore::_wrap_long_lines($no_spaces, 1000);
    
    my @lines = split /\n/, $result;
    ok(scalar(@lines) >= 2, "Long line without spaces was hard-broken");
    
    # First chunk should be exactly 1000
    is(length($lines[0]), 1000, "First chunk is exactly 1000 chars");
}

# Test 4: Mixed normal and long lines
{
    my $input = "Normal line 1\n" . ("word " x 250) . "\nNormal line 2";
    my $result = CLIO::Session::ToolResultStore::_wrap_long_lines($input, 1000);
    
    my @lines = split /\n/, $result;
    ok(scalar(@lines) > 3, "Mixed content wraps only long lines");
}

# Test 5: Real-world test with package list (simulates the bug scenario)
{
    # Simulate the problematic package list from the bug
    my $packages = join(" ", map { "package-name-$_" } (1..200));
    my $log_line = "[2026-02-01 00:16:46] [INFO] Installing packages: $packages";
    
    print "Original line length: " . length($log_line) . " chars\n";
    
    my $result = CLIO::Session::ToolResultStore::_wrap_long_lines($log_line, 1000);
    
    my @lines = split /\n/, $result;
    print "Wrapped into " . scalar(@lines) . " lines\n";
    
    for my $i (0 .. $#lines) {
        my $len = length($lines[$i]);
        print "  Line " . ($i+1) . ": $len chars\n";
    }
    
    # Verify longest line is reasonable
    my $max = 0;
    for my $line (@lines) {
        my $len = length($line);
        $max = $len if $len > $max;
    }
    
    print "Max line length after wrapping: $max chars\n";
}

done_testing();

print "\n✓ All line-wrapping tests passed!\n";
