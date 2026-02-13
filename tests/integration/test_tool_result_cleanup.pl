#!/usr/bin/env perl

# Test for tool result cleanup mechanism
# Verifies that old tool results are automatically deleted

use strict;
use warnings;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use File::Spec;
use File::Path qw(make_path rmtree);
use CLIO::Session::ToolResultStore;
use Test::Simple tests => 6;

print "Testing tool result cleanup mechanism...\n";

# Create test directory
my $test_sessions_dir = File::Spec->catdir($RealBin, 'test_tool_cleanup');
rmtree($test_sessions_dir) if -d $test_sessions_dir;
make_path($test_sessions_dir);

my $test_session_id = 'test-cleanup-session';
my $session_dir = File::Spec->catdir($test_sessions_dir, $test_session_id);
my $tool_results_dir = File::Spec->catdir($session_dir, 'tool_results');
make_path($tool_results_dir);

# Create ToolResultStore instance
my $store = CLIO::Session::ToolResultStore->new(
    sessions_dir => $test_sessions_dir,
    debug => 1
);

# Test 1: Create some tool results
print "\nTest 1: Creating test tool results...\n";
my $result1 = File::Spec->catfile($tool_results_dir, 'toolu_test_001.txt');
my $result2 = File::Spec->catfile($tool_results_dir, 'toolu_test_002.txt');
my $result3 = File::Spec->catfile($tool_results_dir, 'toolu_test_003.txt');

open my $fh1, '>', $result1 or die $!;
print $fh1 "Test result 1\n";
close $fh1;

open my $fh2, '>', $result2 or die $!;
print $fh2 "Test result 2\n";
close $fh2;

open my $fh3, '>', $result3 or die $!;
print $fh3 "Test result 3\n";
close $fh3;

ok(-f $result1 && -f $result2 && -f $result3, "Created 3 test tool results");

# Test 2: Make result1 and result2 "old" by setting their mtime to 25 hours ago
print "\nTest 2: Making results 1 and 2 old (25 hours ago)...\n";
my $old_time = time() - (25 * 3600);  # 25 hours ago
utime($old_time, $old_time, $result1) or die "Failed to set mtime on result1: $!";
utime($old_time, $old_time, $result2) or die "Failed to set mtime on result2: $!";

my $result1_mtime = (stat($result1))[9];
my $result2_mtime = (stat($result2))[9];
my $age1 = time() - $result1_mtime;
my $age2 = time() - $result2_mtime;

ok($age1 > 24*3600 && $age2 > 24*3600, "Results 1 and 2 are older than 24 hours");

# Test 3: Verify result3 is still "new"
print "\nTest 3: Verifying result 3 is still new...\n";
my $result3_mtime = (stat($result3))[9];
my $age3 = time() - $result3_mtime;
ok($age3 < 24*3600, "Result 3 is newer than 24 hours");

# Test 4: Run cleanup with 24-hour threshold
print "\nTest 4: Running cleanup (24-hour threshold)...\n";
my $cleanup_result = $store->cleanupOldResults($test_session_id, 24);

print "Cleanup result: deleted=$cleanup_result->{deleted_count}, reclaimed=$cleanup_result->{reclaimed_bytes} bytes\n";
ok($cleanup_result->{deleted_count} == 2, "Cleanup deleted 2 old results");

# Test 5: Verify old results are deleted
print "\nTest 5: Verifying old results deleted...\n";
ok(!-f $result1 && !-f $result2, "Results 1 and 2 were deleted");

# Test 6: Verify new result still exists
print "\nTest 6: Verifying new result still exists...\n";
ok(-f $result3, "Result 3 still exists (not deleted)");

# Cleanup
rmtree($test_sessions_dir);

print "\n";
print "All tool result cleanup tests passed!\n";
print "\n";
print "SUMMARY:\n";
print "- Old tool results (>24h) are automatically deleted\n";
print "- Recent tool results (<24h) are preserved\n";
print "- Cleanup works correctly without errors\n";
print "\n";
