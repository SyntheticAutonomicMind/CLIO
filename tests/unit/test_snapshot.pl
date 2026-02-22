#!/usr/bin/env perl
# Test CLIO::Session::Snapshot - file change snapshots and revert

use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Spec;
use File::Path qw(make_path);

use lib './lib';
use CLIO::Session::Snapshot;

my $tests_passed = 0;
my $tests_failed = 0;

sub ok {
    my ($condition, $name) = @_;
    if ($condition) {
        print "OK - $name\n";
        $tests_passed++;
    } else {
        print "FAIL - $name\n";
        $tests_failed++;
    }
}

# Create temp directory for testing
my $tmpdir = tempdir(CLEANUP => 1);

# Create initial test files
open my $fh, '>', File::Spec->catfile($tmpdir, 'file1.txt');
print $fh "original content 1\n";
close $fh;

open $fh, '>', File::Spec->catfile($tmpdir, 'file2.txt');
print $fh "original content 2\n";
close $fh;

my $snap = CLIO::Session::Snapshot->new(
    work_tree => $tmpdir,
    debug => 0,
);

# Test 1: Is available
print "\n=== Test: Availability ===\n";
ok($snap->is_available(), "Git is available");

# Test 2: Take snapshot
print "\n=== Test: Take Snapshot ===\n";
my $hash = $snap->take();
ok(defined $hash, "Snapshot taken");
ok(length($hash) > 10, "Hash looks valid: $hash");

# Test 3: No changes detected
print "\n=== Test: No Changes ===\n";
my $changes = $snap->changed_files($hash);
ok(defined $changes, "changed_files returns result");
ok(scalar(@{$changes->{files}}) == 0, "No changes detected");

# Test 4: Detect modifications
print "\n=== Test: Detect Modifications ===\n";
open $fh, '>', File::Spec->catfile($tmpdir, 'file1.txt');
print $fh "MODIFIED content 1\n";
close $fh;

$changes = $snap->changed_files($hash);
ok(scalar(@{$changes->{files}}) > 0, "Changes detected after modification");
ok(grep { $_ eq 'file1.txt' } @{$changes->{files}}, "file1.txt in changed list");

# Test 5: Detect new files
print "\n=== Test: Detect New Files ===\n";
open $fh, '>', File::Spec->catfile($tmpdir, 'new_file.txt');
print $fh "brand new file\n";
close $fh;

$changes = $snap->changed_files($hash);
ok(grep { $_ eq 'new_file.txt' } @{$changes->{files}}, "new_file.txt in changed list");

# Test 6: Diff
print "\n=== Test: Diff ===\n";
my $diff = $snap->diff($hash);
ok(length($diff) > 0, "Diff is not empty");
ok($diff =~ /MODIFIED/, "Diff contains modified content");

# Test 7: Revert
print "\n=== Test: Revert ===\n";
my $success = $snap->revert($hash);
ok($success, "Revert succeeded");

# Check file1.txt is restored
open $fh, '<', File::Spec->catfile($tmpdir, 'file1.txt');
my $content = do { local $/; <$fh> };
close $fh;
ok($content =~ /original content 1/, "file1.txt reverted to original");

# Check new_file.txt is removed
ok(!-f File::Spec->catfile($tmpdir, 'new_file.txt'), "new_file.txt removed after revert");

# Test 8: Revert specific files
print "\n=== Test: Revert Specific Files ===\n";
my $hash2 = $snap->take();

# Modify both files
open $fh, '>', File::Spec->catfile($tmpdir, 'file1.txt');
print $fh "modified again\n";
close $fh;
open $fh, '>', File::Spec->catfile($tmpdir, 'file2.txt');
print $fh "also modified\n";
close $fh;

# Revert only file1
my $count = $snap->revert_files($hash2, ['file1.txt']);
ok($count == 1, "1 file reverted");

# file1 should be restored
open $fh, '<', File::Spec->catfile($tmpdir, 'file1.txt');
$content = do { local $/; <$fh> };
close $fh;
ok($content =~ /original content 1/, "file1.txt reverted");

# file2 should still be modified
open $fh, '<', File::Spec->catfile($tmpdir, 'file2.txt');
$content = do { local $/; <$fh> };
close $fh;
ok($content =~ /also modified/, "file2.txt still modified (not reverted)");

# Summary
print "\n=== Results ===\n";
print "Passed: $tests_passed\n";
print "Failed: $tests_failed\n";
exit($tests_failed > 0 ? 1 : 0);
