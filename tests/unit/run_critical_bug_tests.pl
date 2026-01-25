#!/usr/bin/env perl
# Test Suite: Critical Bug Fixes from 2026-01-25
# Runs all tests for the four major bugs fixed today

use strict;
use warnings;
use FindBin qw($RealBin);

my @tests = (
    'test_session_history_truncation.pl',
    'test_project_local_sessions.pl',
    'test_pwd_in_prompt.pl',
    'test_retry_malformed_json.pl',
);

print "=" x 60 . "\n";
print "Running Critical Bug Fix Test Suite\n";
print "=" x 60 . "\n\n";

my $total_passed = 0;
my $total_failed = 0;

for my $test (@tests) {
    my $test_path = "$RealBin/$test";
    
    print "\nRunning: $test\n";
    print "-" x 60 . "\n";
    
    my $result = system("perl $test_path");
    
    if ($result == 0) {
        print "\n[OK] $test PASSED\n";
        $total_passed++;
    } else {
        print "\n[FAIL] $test FAILED (exit code: $result)\n";
        $total_failed++;
    }
}

print "\n" . "=" x 60 . "\n";
print "Test Suite Results\n";
print "=" x 60 . "\n";
print "Total Tests: " . scalar(@tests) . "\n";
print "Passed: $total_passed\n";
print "Failed: $total_failed\n";
print "=" x 60 . "\n";

exit($total_failed > 0 ? 1 : 0);
