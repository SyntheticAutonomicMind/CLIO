#!/usr/bin/env perl
# Test pagination threshold behavior

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../lib";

print "Testing pagination threshold...\n\n";

# Read Chat.pm and verify the implementation
my $chat_pm = "$FindBin::Bin/../../lib/CLIO/UI/Chat.pm";
open my $fh, '<', $chat_pm or die "Cannot open $chat_pm: $!";
my $content = do { local $/; <$fh> };
close $fh;

my $test_count = 0;
my $pass_count = 0;

# Test 1: Centralized _get_pagination_threshold method exists and uses terminal_height - 2
$test_count++;
if ($content =~ /sub _get_pagination_threshold\b.*?return.*?terminal_height.*?-\s*2/s) {
    print " Test 1 PASS: _get_pagination_threshold uses terminal_height - 2\n";
    $pass_count++;
} else {
    print " Test 1 FAIL: _get_pagination_threshold not found or wrong formula\n";
}

# Test 2: All pagination sites use the centralized helper
$test_count++;
my @threshold_calls = $content =~ /(\$self->_get_pagination_threshold\(\))/g;
if (scalar(@threshold_calls) >= 3) {
    print " Test 2 PASS: Found " . scalar(@threshold_calls) . " calls to _get_pagination_threshold()\n";
    $pass_count++;
} else {
    print " Test 2 FAIL: Expected 3+ calls to _get_pagination_threshold(), found " . scalar(@threshold_calls) . "\n";
}

# Test 3: No old-style direct terminal_height comparisons remain in pagination checks
$test_count++;
my @old_pattern = $content =~ /if \(\$self->\{line_count\} >= \$self->\{terminal_height\} &&\s+\$self->\{pagination_enabled\}/g;
if (scalar(@old_pattern) == 0) {
    print " Test 3 PASS: No direct terminal_height comparisons in pagination checks\n";
    $pass_count++;
} else {
    print " Test 3 FAIL: Found " . scalar(@old_pattern) . " old-style terminal_height comparisons\n";
}

# Test 4: Syntax check
$test_count++;
my $syntax_result = `perl -I$FindBin::Bin/../../lib -c $chat_pm 2>&1`;
if ($syntax_result =~ /syntax OK/) {
    print " Test 4 PASS: Chat.pm syntax is valid\n";
    $pass_count++;
} else {
    print " Test 4 FAIL: Syntax errors:\n$syntax_result\n";
}

print "\n";
print "=" x 60 . "\n";
print "Results: $pass_count/$test_count tests passed\n";
print "=" x 60 . "\n";

exit($pass_count == $test_count ? 0 : 1);
