#!/usr/bin/env perl

use strict;
use warnings;
use lib 'lib';

# Disable buffering
$| = 1;

use CLIO::Core::HashtagParser;
use CLIO::Memory::TokenEstimator;

print "Token Budget Test\n";
print "==================\n\n";

# Create large content to test truncation
my $large_content = "Line 1\n" x 10000;  # 10,000 lines
my $tokens = CLIO::Memory::TokenEstimator::estimate_tokens($large_content);
print "Created test content: " . length($large_content) . " bytes, ~$tokens tokens\n\n";

# Test truncation
print "Testing truncation with 1000 token limit:\n";
my $truncated = CLIO::Memory::TokenEstimator::truncate($large_content, 1000);
my $trunc_tokens = CLIO::Memory::TokenEstimator::estimate_tokens($truncated);
print "  Original: ~$tokens tokens\n";
print "  Truncated: ~$trunc_tokens tokens\n";
print "  Length: " . length($truncated) . " bytes\n";

if ($trunc_tokens <= 1100) {  # Allow some overhead
    print "  ✓ PASS: Within budget\n";
} else {
    print "  ✗ FAIL: Exceeded budget\n";
}

print "\nDone!\n";
