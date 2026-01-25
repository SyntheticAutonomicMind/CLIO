#!/usr/bin/env perl
# Test pagination pause timing fix

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../lib";

print "Testing pagination pause threshold fix...\n\n";

# Read Chat.pm and verify the fix
my $chat_pm = "$FindBin::Bin/../../lib/CLIO/UI/Chat.pm";
open my $fh, '<', $chat_pm or die "Cannot open $chat_pm: $!";
my $content = do { local $/; <$fh> };
close $fh;

my $test_count = 0;
my $pass_count = 0;

# Test 1: Streaming mode pagination uses threshold
$test_count++;
if ($content =~ /my \$pause_threshold = \$self->\{terminal_height\} - 2;.*?if \(\$self->\{line_count\} >= \$pause_threshold &&\s+\$self->\{pagination_enabled\}/s) {
    print "✓ Test 1 PASS: Streaming pagination uses pause_threshold (terminal_height - 2)\n";
    $pass_count++;
} else {
    print "✗ Test 1 FAIL: Streaming pagination still using >= terminal_height\n";
}

# Test 2: User collaboration pagination uses threshold
$test_count++;
my @collaboration_matches = $content =~ /(my \$pause_threshold = \$self->\{terminal_height\} - 2;)/g;
if (scalar(@collaboration_matches) >= 3) {
    print "✓ Test 2 PASS: Found " . scalar(@collaboration_matches) . " pause_threshold definitions (all locations fixed)\n";
    $pass_count++;
} else {
    print "✗ Test 2 FAIL: Expected 3 pause_threshold definitions, found " . scalar(@collaboration_matches) . "\n";
}

# Test 3: No instances of direct terminal_height comparison remain in pagination
$test_count++;
my @old_pattern = $content =~ /if \(\$self->\{line_count\} >= \$self->\{terminal_height\} &&\s+\$self->\{pagination_enabled\}/g;
if (scalar(@old_pattern) == 0) {
    print "✓ Test 3 PASS: No direct terminal_height comparisons in pagination checks\n";
    $pass_count++;
} else {
    print "✗ Test 3 FAIL: Found " . scalar(@old_pattern) . " old-style terminal_height comparisons\n";
}

# Test 4: Syntax check
$test_count++;
my $syntax_result = `perl -I$FindBin::Bin/../../lib -c $chat_pm 2>&1`;
if ($syntax_result =~ /syntax OK/) {
    print "✓ Test 4 PASS: Chat.pm syntax is valid\n";
    $pass_count++;
} else {
    print "✗ Test 4 FAIL: Syntax errors:\n$syntax_result\n";
}

print "\n";
print "=" x 60 . "\n";
print "Results: $pass_count/$test_count tests passed\n";
print "=" x 60 . "\n";

exit($pass_count == $test_count ? 0 : 1);
