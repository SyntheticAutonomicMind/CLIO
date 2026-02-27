#!/usr/bin/env perl
# Test CLIO::Session::FileVault - targeted file backup and undo

use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Spec;
use File::Path qw(make_path remove_tree);

use lib './lib';
use CLIO::Session::FileVault;

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

my $vault = CLIO::Session::FileVault->new(
    work_tree => $tmpdir,
    debug => 0,
);

# Test 1: Is always available
print "\n=== Test: Availability ===\n";
ok($vault->is_available(), "FileVault is always available");

# Test 2: Start a turn
print "\n=== Test: Start Turn ===\n";
my $turn_id = $vault->start_turn("test prompt");
ok(defined $turn_id, "Turn started: $turn_id");
ok($turn_id =~ /^turn_\d+$/, "Turn ID format is correct");

# Test 3: Capture before modification
print "\n=== Test: Capture Before Modify ===\n";
my $file1 = File::Spec->catfile($tmpdir, 'file1.txt');
my $captured = $vault->capture_before($file1, $turn_id);
ok($captured, "Captured file1.txt before modification");

# Now modify the file
open $fh, '>', $file1;
print $fh "MODIFIED content 1\n";
close $fh;

# Test 4: Duplicate capture is a no-op
print "\n=== Test: Duplicate Capture No-Op ===\n";
my $dup = $vault->capture_before($file1, $turn_id);
ok(!$dup, "Second capture of same file is no-op (preserves original)");

# Test 5: Changed files
print "\n=== Test: Changed Files ===\n";
my $changes = $vault->changed_files($turn_id);
ok(defined $changes, "changed_files returns result");
ok(scalar(@{$changes->{files}}) == 1, "One file changed");
ok($changes->{files}[0] eq 'file1.txt', "file1.txt in changed list");

# Test 6: Diff
print "\n=== Test: Diff ===\n";
my $diff = $vault->diff($turn_id);
ok(length($diff) > 0, "Diff is not empty");
ok($diff =~ /MODIFIED/, "Diff contains modified content");
ok($diff =~ /original/, "Diff contains original content");

# Test 7: Undo turn (modify)
print "\n=== Test: Undo Modify ===\n";
my $result = $vault->undo_turn($turn_id);
ok($result->{success}, "Undo succeeded");
ok($result->{reverted} == 1, "1 file reverted");

open $fh, '<', $file1;
my $content = do { local $/; <$fh> };
close $fh;
ok($content =~ /original content 1/, "file1.txt reverted to original");

# Test 8: Record creation + undo (delete)
print "\n=== Test: Record Creation + Undo ===\n";
my $turn2 = $vault->start_turn("create test");
my $new_file = File::Spec->catfile($tmpdir, 'new_file.txt');

$vault->record_creation($new_file, $turn2);

# Create the file
open $fh, '>', $new_file;
print $fh "brand new file\n";
close $fh;
ok(-f $new_file, "New file created");

$result = $vault->undo_turn($turn2);
ok($result->{success}, "Undo creation succeeded");
ok(!-f $new_file, "New file removed after undo");

# Test 9: Record deletion + undo (restore)
print "\n=== Test: Record Deletion + Undo ===\n";
my $turn3 = $vault->start_turn("delete test");
my $file2 = File::Spec->catfile($tmpdir, 'file2.txt');

$vault->record_deletion($file2, $turn3);
unlink $file2;
ok(!-f $file2, "file2.txt deleted");

$result = $vault->undo_turn($turn3);
ok($result->{success}, "Undo deletion succeeded");
ok(-f $file2, "file2.txt restored after undo");

open $fh, '<', $file2;
$content = do { local $/; <$fh> };
close $fh;
ok($content =~ /original content 2/, "file2.txt content restored");

# Test 10: Record rename + undo
print "\n=== Test: Record Rename + Undo ===\n";
my $turn4 = $vault->start_turn("rename test");
my $renamed_file = File::Spec->catfile($tmpdir, 'file1_renamed.txt');

$vault->record_rename($file1, $renamed_file, $turn4);
rename $file1, $renamed_file;
ok(-f $renamed_file, "File renamed");
ok(!-f $file1, "Original path gone");

$result = $vault->undo_turn($turn4);
ok($result->{success}, "Undo rename succeeded");
ok(-f $file1, "Original file restored");
ok(!-f $renamed_file, "Renamed file removed");

# Test 11: Multiple modifications in same turn (only first backup kept)
print "\n=== Test: Multiple Mods Same Turn ===\n";
my $turn5 = $vault->start_turn("multi-mod test");

# Read original content
open $fh, '<', $file1;
my $original = do { local $/; <$fh> };
close $fh;

# First modification
$vault->capture_before($file1, $turn5);
open $fh, '>', $file1;
print $fh "first modification\n";
close $fh;

# Second modification (capture should be no-op)
$vault->capture_before($file1, $turn5);
open $fh, '>', $file1;
print $fh "second modification\n";
close $fh;

# Third modification
$vault->capture_before($file1, $turn5);
open $fh, '>', $file1;
print $fh "third modification\n";
close $fh;

# Undo should restore to ORIGINAL, not "first modification"
$result = $vault->undo_turn($turn5);
ok($result->{success}, "Undo multi-mod succeeded");

open $fh, '<', $file1;
$content = do { local $/; <$fh> };
close $fh;
ok($content eq $original, "File restored to pre-turn state (not intermediate)");

# Test 12: Turn history
print "\n=== Test: Turn History ===\n";
my $history = $vault->get_turn_history();
ok(ref($history) eq 'ARRAY', "History is an array");
ok(scalar(@$history) > 0, "History has entries");

# Test 13: has_turn
print "\n=== Test: Has Turn ===\n";
my $turn6 = $vault->start_turn("exists test");
ok($vault->has_turn($turn6), "Turn exists in vault");
ok(!$vault->has_turn("turn_9999"), "Non-existent turn returns false");

# Test 14: remove_turn
print "\n=== Test: Remove Turn ===\n";
ok($vault->remove_turn($turn6), "Turn removed");
ok(!$vault->has_turn($turn6), "Removed turn no longer exists");

# Test 15: Subdirectory files
print "\n=== Test: Subdirectory Files ===\n";
my $subdir = File::Spec->catdir($tmpdir, 'subdir');
make_path($subdir);
my $subfile = File::Spec->catfile($subdir, 'deep.txt');
open $fh, '>', $subfile;
print $fh "deep content\n";
close $fh;

my $turn7 = $vault->start_turn("subdir test");
$vault->capture_before($subfile, $turn7);

open $fh, '>', $subfile;
print $fh "modified deep\n";
close $fh;

$result = $vault->undo_turn($turn7);
ok($result->{success}, "Undo subdirectory file succeeded");

open $fh, '<', $subfile;
$content = do { local $/; <$fh> };
close $fh;
ok($content =~ /deep content/, "Subdirectory file restored");

# Summary
print "\n=== Results ===\n";
print "Passed: $tests_passed\n";
print "Failed: $tests_failed\n";
exit($tests_failed > 0 ? 1 : 0);
