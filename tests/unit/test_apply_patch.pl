#!/usr/bin/env perl
# Test CLIO::Tools::ApplyPatch - patch parsing and application

use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Spec;
use File::Path qw(make_path);
use JSON::PP qw(decode_json);

use lib './lib';
use CLIO::Tools::ApplyPatch;

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

# Helper to execute and get result hashref
sub run_patch {
    my ($tool, $patch) = @_;
    my $result = $tool->execute({ operation => 'apply', patch => $patch }, {});
    # execute returns a hashref from the Tool base class
    return $result;
}

# Create temp directory for testing
my $tmpdir = tempdir(CLEANUP => 1);

# Create test files
my $test_file = File::Spec->catfile($tmpdir, 'test.txt');
open my $fh, '>', $test_file or die;
print $fh "line 1\nline 2\nline 3\nline 4\nline 5\n";
close $fh;

my $tool = CLIO::Tools::ApplyPatch->new(
    debug => 0,
    base_dir => $tmpdir,
);

# Test 1: Add File
print "\n=== Test: Add File ===\n";
my $data = run_patch($tool, '*** Begin Patch
*** Add File: new_file.txt
+Hello World
+Line 2
*** End Patch');

ok($data->{success}, "Add file succeeds");
ok(-f File::Spec->catfile($tmpdir, 'new_file.txt'), "New file created");

# Read back
open $fh, '<', File::Spec->catfile($tmpdir, 'new_file.txt');
my $content = do { local $/; <$fh> };
close $fh;
ok($content =~ /Hello World/, "File has correct content");

# Test 2: Update File
print "\n=== Test: Update File ===\n";
$data = run_patch($tool, '*** Begin Patch
*** Update File: test.txt
@@ line 2
-line 2
-line 3
+line 2 (modified)
+line 3 (modified)
+line 3.5 (inserted)
*** End Patch');

ok($data->{success}, "Update file succeeds");

open $fh, '<', $test_file;
$content = do { local $/; <$fh> };
close $fh;
ok($content =~ /line 2 \(modified\)/, "Line 2 modified correctly");
ok($content =~ /line 3 \(modified\)/, "Line 3 modified correctly");
ok($content =~ /line 3\.5 \(inserted\)/, "New line inserted");
ok($content =~ /line 4/, "Line 4 preserved");

# Test 3: Delete File
print "\n=== Test: Delete File ===\n";
$data = run_patch($tool, '*** Begin Patch
*** Delete File: new_file.txt
*** End Patch');

ok($data->{success}, "Delete file succeeds");
ok(!-f File::Spec->catfile($tmpdir, 'new_file.txt'), "File deleted");

# Test 4: Multi-file patch
print "\n=== Test: Multi-file Patch ===\n";
# Create a file for multi-file test
open $fh, '>', File::Spec->catfile($tmpdir, 'multi1.txt');
print $fh "alpha\nbeta\ngamma\n";
close $fh;

$data = run_patch($tool, '*** Begin Patch
*** Add File: multi2.txt
+created by patch
*** Update File: multi1.txt
@@ beta
-beta
+BETA
*** End Patch');

ok($data->{success}, "Multi-file patch succeeds");
# Check output JSON for counts
my $output = eval { decode_json($data->{output} || '{}') } || {};
ok(($output->{files_created} || 0) == 1, "1 file created");
ok(($output->{files_modified} || 0) == 1, "1 file modified");

# Test 5: Empty patch
print "\n=== Test: Empty Patch ===\n";
$data = run_patch($tool, '*** Begin Patch
*** End Patch');

ok(!$data->{success}, "Empty patch fails correctly");

# Test 6: Patch with subdirectory creation
print "\n=== Test: Subdirectory Creation ===\n";
$data = run_patch($tool, '*** Begin Patch
*** Add File: subdir/deep/file.txt
+deep file content
*** End Patch');

ok($data->{success}, "Subdirectory file creation succeeds");
ok(-f File::Spec->catfile($tmpdir, 'subdir', 'deep', 'file.txt'), "Deep file created");

# Summary
print "\n=== Results ===\n";
print "Passed: $tests_passed\n";
print "Failed: $tests_failed\n";
exit($tests_failed > 0 ? 1 : 0);
