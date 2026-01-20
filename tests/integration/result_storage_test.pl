#!/usr/bin/env perl

use strict;
use warnings;
use feature 'say';
use FindBin;
use lib "$FindBin::Bin/lib";

use CLIO::Session::ToolResultStore;
use File::Path qw(remove_tree);
use File::Temp qw(tempdir);

# Test ToolResultStore
say "=== Testing CLIO::Session::ToolResultStore ===\n";

# Create temp directory for testing
my $temp_dir = tempdir(CLEANUP => 1);
my $sessions_dir = "$temp_dir/sessions";

my $store = CLIO::Session::ToolResultStore->new(
    sessions_dir => $sessions_dir,
    debug => 1,
);

my $session_id = 'test_session_' . time();
my $toolCallId = 'call_test_' . time();

my $tests_passed = 0;
my $tests_total = 0;

# Test 1: Small result (< 8KB) - should return inline
$tests_total++;
say "Test 1: Small result returns inline";
my $small_content = "This is a small result\n" x 100;  # ~2.5KB
my $result = $store->processToolResult($toolCallId . '_small', $small_content, $session_id);
if ($result eq $small_content) {
    say "✅ PASS: Small result returned inline";
    $tests_passed++;
} else {
    say "❌ FAIL: Small result was modified";
    say "   Expected: $small_content";
    say "   Got: $result";
}
say "";

# Test 2: Large result (> 8KB) - should persist and return marker
$tests_total++;
say "Test 2: Large result persists with marker";
my $large_content = "This is a large result that exceeds 8KB\n" x 500;  # ~20KB
$result = $store->processToolResult($toolCallId . '_large', $large_content, $session_id);
if ($result =~ /\[TOOL_RESULT_STORED/ && $result =~ /toolCallId=$toolCallId\_large/) {
    say "✅ PASS: Large result persisted with marker";
    $tests_passed++;
} else {
    say "❌ FAIL: Large result marker not found";
    say "   Got: " . substr($result, 0, 200) . "...";
}
say "";

# Test 3: resultExists check
$tests_total++;
say "Test 3: resultExists check";
if ($store->resultExists($toolCallId . '_large', $session_id)) {
    say "✅ PASS: resultExists returns true for persisted result";
    $tests_passed++;
} else {
    say "❌ FAIL: resultExists returns false for persisted result";
}
say "";

# Test 4: retrieveChunk - first chunk
$tests_total++;
say "Test 4: Retrieve first chunk";
eval {
    my $chunk = $store->retrieveChunk($toolCallId . '_large', $session_id, 0, 8192);
    if ($chunk->{toolCallId} eq $toolCallId . '_large' &&
        $chunk->{offset} == 0 &&
        length($chunk->{content}) == 8192 &&
        $chunk->{hasMore}) {
        say "✅ PASS: First chunk retrieved correctly";
        say "   Offset: $chunk->{offset}";
        say "   Length: $chunk->{length}";
        say "   Total: $chunk->{totalLength}";
        say "   Has more: " . ($chunk->{hasMore} ? 'yes' : 'no');
        $tests_passed++;
    } else {
        say "❌ FAIL: First chunk has incorrect metadata";
        say "   toolCallId: $chunk->{toolCallId}";
        say "   offset: $chunk->{offset}";
        say "   length: $chunk->{length}";
        say "   hasMore: $chunk->{hasMore}";
    }
};
if ($@) {
    say "❌ FAIL: Exception during retrieve: $@";
}
say "";

# Test 5: retrieveChunk - next chunk
$tests_total++;
say "Test 5: Retrieve next chunk";
eval {
    my $chunk = $store->retrieveChunk($toolCallId . '_large', $session_id, 8192, 8192);
    if ($chunk->{toolCallId} eq $toolCallId . '_large' &&
        $chunk->{offset} == 8192 &&
        length($chunk->{content}) > 0) {
        say "✅ PASS: Next chunk retrieved correctly";
        say "   Offset: $chunk->{offset}";
        say "   Length: $chunk->{length}";
        say "   Has more: " . ($chunk->{hasMore} ? 'yes' : 'no');
        $tests_passed++;
    } else {
        say "❌ FAIL: Next chunk has incorrect metadata";
    }
};
if ($@) {
    say "❌ FAIL: Exception during retrieve: $@";
}
say "";

# Test 6: listResults
$tests_total++;
say "Test 6: List results";
my @results = $store->listResults($session_id);
if (grep { $_ eq $toolCallId . '_large' } @results) {
    say "✅ PASS: listResults includes persisted result";
    say "   Found: " . join(', ', @results);
    $tests_passed++;
} else {
    say "❌ FAIL: listResults missing persisted result";
    say "   Found: " . join(', ', @results);
}
say "";

# Test 7: deleteResult
$tests_total++;
say "Test 7: Delete result";
eval {
    $store->deleteResult($toolCallId . '_large', $session_id);
    if (!$store->resultExists($toolCallId . '_large', $session_id)) {
        say "✅ PASS: Result deleted successfully";
        $tests_passed++;
    } else {
        say "❌ FAIL: Result still exists after delete";
    }
};
if ($@) {
    say "❌ FAIL: Exception during delete: $@";
}
say "";

# Summary
say "=" x 60;
say "SUMMARY: $tests_passed/$tests_total tests passed";
if ($tests_passed == $tests_total) {
    say "✅ ALL TESTS PASSED";
    exit 0;
} else {
    say "❌ SOME TESTS FAILED";
    exit 1;
}
