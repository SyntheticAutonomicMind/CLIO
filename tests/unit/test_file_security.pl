#!/usr/bin/env perl
# test_file_security.pl - Test atomic writes and secure permissions

use strict;
use warnings;
use utf8;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);

# Add lib path
use lib dirname(__FILE__) . '/../..';

use CLIO::Tools::FileOperations;

my $test_dir = tempdir(CLEANUP => 1);
print "Test directory: $test_dir\n";

# Create FileOperations instance
my $fo = CLIO::Tools::FileOperations->new(
    session_dir => $test_dir,
);

my $context = {
    config => undef,  # No config, will use defaults
    session => { id => 'test_session' },
};

my $passed = 0;
my $failed = 0;

# Test 1: create_file with secure permissions
print "\n--- Test 1: create_file with secure permissions ---\n";
my $test_file = "$test_dir/test1.txt";
my $result = $fo->execute(
    { operation => 'create_file', path => $test_file, content => "Test content 1\n" },
    $context
);
if ($result->{success}) {
    my $perms = (stat($test_file))[2] & 07777;
    my $octal = sprintf("%04o", $perms);
    print "File created: $test_file, permissions: $octal\n";
    if ($perms == 0600) {
        print "PASS: File has correct permissions (0600)\n";
        $passed++;
    } else {
        print "FAIL: File has incorrect permissions (expected 0600, got $octal)\n";
        $failed++;
    }
} else {
    print "FAIL: create_file failed: $result->{error}\n";
    $failed++;
}

# Test 2: write_file preserves secure permissions
print "\n--- Test 2: write_file atomic write ---\n";
$test_file = "$test_dir/test2.txt";
# Create file first
system("touch $test_file && chmod 0644 $test_file");  # Start with bad perms
$result = $fo->execute(
    { operation => 'write_file', path => $test_file, content => "Test content 2\n" },
    $context
);
if ($result->{success}) {
    my $perms = (stat($test_file))[2] & 07777;
    my $octal = sprintf("%04o", $perms);
    print "File written: $test_file, permissions: $octal\n";
    if ($perms == 0600) {
        print "PASS: File has correct permissions after write (0600)\n";
        $passed++;
    } else {
        print "FAIL: File has incorrect permissions (expected 0600, got $octal)\n";
        $failed++;
    }
} else {
    print "FAIL: write_file failed: $result->{error}\n";
    $failed++;
}

# Test 3: create_directory with secure permissions
print "\n--- Test 3: create_directory with secure permissions ---\n";
my $test_dir_path = "$test_dir/test_subdir";
$result = $fo->execute(
    { operation => 'create_directory', path => $test_dir_path },
    $context
);
if ($result->{success}) {
    my $perms = (stat($test_dir_path))[2] & 07777;
    my $octal = sprintf("%04o", $perms);
    print "Directory created: $test_dir_path, permissions: $octal\n";
    if ($perms == 0700) {
        print "PASS: Directory has correct permissions (0700)\n";
        $passed++;
    } else {
        print "FAIL: Directory has incorrect permissions (expected 0700, got $octal)\n";
        $failed++;
    }
} else {
    print "FAIL: create_directory failed: $result->{error}\n";
    $failed++;
}

# Test 4: Atomic write pattern (temp file should not remain)
print "\n--- Test 4: Atomic write (no temp files left) ---\n";
$test_file = "$test_dir/test4.txt";
$result = $fo->execute(
    { operation => 'create_file', path => $test_file, content => "Atomic write test\n" },
    $context
);
if ($result->{success}) {
    my @temp_files = glob("$test_file.tmp.*");
    if (scalar(@temp_files) == 0) {
        print "PASS: No temp files left behind\n";
        $passed++;
    } else {
        print "FAIL: Temp files remain: @temp_files\n";
        $failed++;
    }
} else {
    print "FAIL: create_file failed: $result->{error}\n";
    $failed++;
}

# Test 5: replace_string with atomic write
print "\n--- Test 5: replace_string atomic write ---\n";
$test_file = "$test_dir/test5.txt";
system("echo 'original content' > $test_file");
chmod(0644, $test_file);  # Start with bad perms
$result = $fo->execute(
    { operation => 'replace_string', path => $test_file, old_string => 'original', new_string => 'modified' },
    $context
);
if ($result->{success}) {
    my $perms = (stat($test_file))[2] & 07777;
    my $octal = sprintf("%04o", $perms);
    print "File modified: $test_file, permissions: $octal\n";
    if ($perms == 0600) {
        print "PASS: File has correct permissions after replace (0600)\n";
        $passed++;
    } else {
        print "FAIL: File has incorrect permissions (expected 0600, got $octal)\n";
        $failed++;
    }
} else {
    print "FAIL: replace_string failed: $result->{error}\n";
    $failed++;
}

# Summary
print "\n=== Results: $passed/${\($passed+$failed)} passed ===\n";
exit($failed > 0 ? 1 : 0);
