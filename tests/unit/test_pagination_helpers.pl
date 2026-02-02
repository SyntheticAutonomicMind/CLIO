#!/usr/bin/perl

use strict;
use warnings;
use lib './lib';

# Test the new helper methods

use CLIO::UI::Chat;

# Create a minimal mock chat object for testing
my $chat = CLIO::UI::Chat->new(
    theme => 'default',
    config => undef,
    session => undef,
    debug => 0
);

print "Testing pagination helper methods...\n\n";

# Test 1: _get_pagination_threshold
print "Test 1: _get_pagination_threshold\n";
$chat->{terminal_height} = 24;
my $threshold = $chat->_get_pagination_threshold();
print "  Terminal height: 24\n";
print "  Threshold: $threshold\n";
print "  Expected: 22 (24 - 2)\n";
print "  Result: " . ($threshold == 22 ? "PASS" : "FAIL") . "\n\n";

# Test 2: _count_visual_lines with various inputs
print "Test 2: _count_visual_lines\n";

my @test_cases = (
    { text => "single line", expected => 1, desc => "Single line" },
    { text => "line1\nline2", expected => 2, desc => "Two lines" },
    { text => "line1\nline2\nline3", expected => 3, desc => "Three lines" },
    { text => "line1\n", expected => 1, desc => "Line with trailing newline" },
    { text => "line1\nline2\n", expected => 2, desc => "Two lines with trailing newline" },
    { text => "\n", expected => 1, desc => "Just newline" },
    { text => "", expected => 0, desc => "Empty string" },
    { text => undef, expected => 0, desc => "Undef" },
);

foreach my $test (@test_cases) {
    my $count = $chat->_count_visual_lines($test->{text});
    my $result = $count == $test->{expected} ? "PASS" : "FAIL";
    my $text_repr = defined $test->{text} ? "\"$test->{text}\"" : "undef";
    print "  $test->{desc}: $text_repr\n";
    print "    Count: $count, Expected: $test->{expected} - $result\n";
}

print "\n";

# Test 3: _should_pagination_trigger
print "Test 3: _should_pagination_trigger\n";
$chat->{line_count} = 0;
$chat->{pagination_enabled} = 0;
my $result = $chat->_should_pagination_trigger();
print "  With pagination disabled: " . ($result ? "FAIL (triggered)" : "PASS (not triggered)") . "\n";

$chat->{pagination_enabled} = 1;
$chat->{_tools_invoked_this_request} = 1;
$result = $chat->_should_pagination_trigger();
print "  With tools invoked: " . ($result ? "FAIL (triggered)" : "PASS (not triggered)") . "\n";

$chat->{_tools_invoked_this_request} = 0;
$chat->{line_count} = 20;  # Below threshold
$result = $chat->_should_pagination_trigger();
print "  With line_count=20, threshold=22: " . ($result ? "FAIL (triggered)" : "PASS (not triggered)") . "\n";

$chat->{line_count} = 22;  # At threshold
$result = $chat->_should_pagination_trigger();
print "  With line_count=22, threshold=22: " . ($result ? "PASS (triggered)" : "FAIL (not triggered)") . "\n";

print "\nAll basic tests completed!\n";

