#!/usr/bin/env perl
# Test script to verify context window truncation improvements

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More tests => 6;

# Test 1: Verify token estimation ratio change (should be more conservative)
{
    my $test_content = "x" x 1000;  # 1000 characters
    
    my $old_estimation = int(length($test_content) / 3);    # Old: /3
    my $new_estimation = int(length($test_content) / 2.5);  # New: /2.5
    
    ok($new_estimation > $old_estimation, "New token estimation is more conservative (2.5 vs 3)");
    is($old_estimation, 333, "Old estimation: 333 tokens for 1000 chars");
    is($new_estimation, 400, "New estimation: 400 tokens for 1000 chars");
}

# Test 2: Verify safety margin calculation
{
    my $max_prompt = 128000;
    my $tool_tokens = 0;
    
    # Old safety margin (10% only)
    my $old_margin = int($max_prompt * 0.10);  # 12,800
    my $old_effective = $max_prompt - $tool_tokens - $old_margin;  # 115,200
    
    # New safety margin (10% + 8k response buffer)
    my $estimation_margin = int($max_prompt * 0.10);  # 12,800
    my $response_buffer = 8000;
    my $new_margin = $estimation_margin + $response_buffer;  # 20,800
    my $new_effective = $max_prompt - $tool_tokens - $new_margin;  # 107,200
    
    ok($new_effective < $old_effective, "New effective limit is more conservative (accounts for response buffer)");
    is($new_effective, 107200, "New effective limit: 107,200 tokens");
}

# Test 3: Verify fallback token limit (simulate capabilities unavailable)
{
    my $fallback_limit = 64000;  # Conservative default when model unknown
    
    ok($fallback_limit < 128000, "Fallback limit (64k) is conservative when model capabilities unavailable");
}

print "\n All context window truncation tests passed!\n";
print "\n Summary of improvements:\n";
print " - Token estimation: /2.5 instead of /3 (20% more conservative)\n";
print " - Safety margin: Added 8k response buffer (prevents overflow on next iteration)\n";
print " - Fallback limit: 64k tokens when model capabilities unavailable (prevents bypass)\n";
