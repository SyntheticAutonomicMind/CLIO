#!/usr/bin/perl

use strict;
use warnings;
use lib './lib';

# Integration test for streaming + pagination compatibility

use CLIO::UI::Chat;

print "Integration Test: Streaming + Pagination Compatibility\n";
print "=" x 60 . "\n\n";

# Create mock chat object
my $chat = CLIO::UI::Chat->new(
    theme => 'default',
    config => undef,
    session => undef,
    debug => 0
);

$chat->{terminal_height} = 24;  # Standard terminal
my $threshold = $chat->_get_pagination_threshold();
print "Terminal Height: $chat->{terminal_height}\n";
print "Pagination Threshold: $threshold\n\n";

# Scenario 1: Streaming output accumulation
print "Scenario 1: Streaming chunk accumulation\n";
print "-" x 40 . "\n";

my $chunk1 = "First response chunk\nSecond line";
my $chunk2 = "Third line\nFourth line\nFifth line";

my $count1 = $chat->_count_visual_lines($chunk1);
my $count2 = $chat->_count_visual_lines($chunk2);

print "Chunk 1 lines: $count1\n";
print "Chunk 2 lines: $count2\n";
print "Total lines so far: " . ($count1 + $count2) . "\n";

$chat->{line_count} = 0;
$chat->{pagination_enabled} = 1;
$chat->{_tools_invoked_this_request} = 0;

$chat->{line_count} += $count1;
print "After chunk 1, line_count: $chat->{line_count}\n";
print "Should trigger pagination: " . ($chat->_should_pagination_trigger() ? "YES" : "NO") . "\n";

$chat->{line_count} += $count2;
print "After chunk 2, line_count: $chat->{line_count}\n";
print "Should trigger pagination: " . ($chat->_should_pagination_trigger() ? "YES" : "NO") . "\n";

print "\n";

# Scenario 2: Tool execution disables pagination
print "Scenario 2: Tool execution pagination handling\n";
print "-" x 40 . "\n";

$chat->{line_count} = $threshold + 5;  # Well over threshold
$chat->{pagination_enabled} = 1;
$chat->{_tools_invoked_this_request} = 0;

print "Line count: $chat->{line_count} (over threshold $threshold)\n";
print "Pagination enabled: YES\n";
print "Tools invoked: NO\n";
print "Should trigger: " . ($chat->_should_pagination_trigger() ? "YES" : "NO") . "\n";

$chat->{_tools_invoked_this_request} = 1;
print "\nAfter tool invocation:\n";
print "Tools invoked: YES\n";
print "Should trigger: " . ($chat->_should_pagination_trigger() ? "YES" : "NO") . "\n";

print "\n";

# Scenario 3: Long content with multiple pagination points
print "Scenario 3: Multiple pagination points\n";
print "-" x 40 . "\n";

my $long_text = join("\n", map { "Line $_" } (1..30));
my $line_count = $chat->_count_visual_lines($long_text);
print "Generated 30 lines of text\n";
print "Counted lines: $line_count\n";
print "Expected: 30\n";
print "Result: " . ($line_count == 30 ? "PASS" : "FAIL") . "\n\n";

my @pagination_points = ();
my $lines_so_far = 0;
$chat->{pagination_enabled} = 1;
$chat->{_tools_invoked_this_request} = 0;

for my $i (1..30) {
    $lines_so_far++;
    $chat->{line_count} = $lines_so_far;
    
    if ($chat->_should_pagination_trigger()) {
        push @pagination_points, $i;
        print "Pagination would trigger at line $i\n";
        $lines_so_far = 0;  # Reset for next page
        $chat->{line_count} = 0;
    }
}

print "Total pagination points: " . scalar(@pagination_points) . "\n";
print "Expected: 1 (threshold is $threshold, so 30 lines exceeds it once)\n";

print "\n" . "=" x 60 . "\n";
print "Integration test completed!\n";

