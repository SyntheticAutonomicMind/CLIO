#!/usr/bin/env perl
# test_file_security.pl - Test atomic writes and permissions

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

# Test 1: create_file with default permissions (0644 for regular files)
print "\n--- Test 1: create_file with default permissions ---\n";
my $test_file = "$test_dir/test1.txt";
my $result = $fo->execute(
    { operation => 'create_file', path => $test_file, content => "Test content 1\n" },
    $context
);
if ($result->{success}) {
    my $perms = (stat($test_file))[2] & 07777;
    my $octal = sprintf("%04o", $perms);
    print "File created: $test_file, permissions: $octal\n";
    if ($perms == 0644) {
        print "PASS: Regular file has correct permissions (0644)\n";
        $passed++;
    } else {
        print "FAIL: File has incorrect permissions (expected 0644, got $octal)\n";
        $failed++;
    }
} else {
    print "FAIL: create_file failed: $result->{error}\n";
    $failed++;
}

# Test 2: write_file preserves existing permissions
print "\n--- Test 2: write_file preserves existing permissions ---\n";
$test_file = "$test_dir/test2.txt";
system("touch $test_file && chmod 0755 $test_file");
$result = $fo->execute(
    { operation => 'write_file', path => $test_file, content => "Test content 2\n" },
    $context
);
if ($result->{success}) {
    my $perms = (stat($test_file))[2] & 07777;
    my $octal = sprintf("%04o", $perms);
    print "File written: $test_file, permissions: $octal\n";
    if ($perms == 0755) {
        print "PASS: Existing file permissions preserved (0755)\n";
        $passed++;
    } else {
        print "FAIL: File permissions not preserved (expected 0755, got $octal)\n";
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

# Test 5: Script files get executable permissions
print "\n--- Test 5: Script files get executable permissions ---\n";
$test_file = "$test_dir/test5.sh";
$result = $fo->execute(
    { operation => 'create_file', path => $test_file, content => "#!/bin/bash\necho hello\n" },
    $context
);
if ($result->{success}) {
    my $perms = (stat($test_file))[2] & 07777;
    my $octal = sprintf("%04o", $perms);
    print "Script created: $test_file, permissions: $octal\n";
    if ($perms == 0755) {
        print "PASS: Script file has executable permissions (0755)\n";
        $passed++;
    } else {
        print "FAIL: Script has incorrect permissions (expected 0755, got $octal)\n";
        $failed++;
    }
} else {
    print "FAIL: create_file failed: $result->{error}\n";
    $failed++;
}

# Summary
print "\n=== Results: $passed/${\($passed+$failed)} passed ===\n";
exit($failed > 0 ? 1 : 0);
