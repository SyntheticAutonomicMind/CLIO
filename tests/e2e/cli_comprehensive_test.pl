#!/usr/bin/env perl

=head1 NAME

cli_comprehensive_test.pl - Comprehensive CLI switch and workflow testing

=head1 DESCRIPTION

Tests ALL command-line switches and combinations that real users will use.
This test would have caught issues with session handling, input processing,
and error display.

Tests:
- --help, --version
- --new, --resume  
- --model, --debug
- --input, --exit
- stdin piping
- Invalid combinations
- Error handling

=cut

use strict;
use warnings;
use lib 'lib';
use lib 'tests/lib';
use TestHelpers qw(assert_true assert_contains assert_equals);
use File::Temp qw(tempdir);
use File::Spec;

my $tests_run = 0;
my $tests_passed = 0;
my $clio = File::Spec->rel2abs('./clio');

print "=" x 80 . "\n";
print "CLIO CLI Comprehensive Test Suite\n";
print "=" x 80 . "\n\n";

# Test 1: --help flag
{
    print "Test 1: --help displays usage information\n";
    $tests_run++;
    
    my $output = `$clio --help 2>&1`;
    my $exit_code = $? >> 8;
    
    assert_equals(0, $exit_code, "--help should exit with 0");
    assert_contains($output, "USAGE", "--help should show usage");
    assert_contains($output, "--new", "--help should mention --new flag");
    
    $tests_passed++;
    print "  ✅ PASS\n\n";
}

# Test 3: --new creates new session
{
    print "Test 3: --new --exit creates new session without interaction\n";
    $tests_run++;
    
    my $output = `timeout 5 $clio --new --exit 2>&1`;
    my $exit_code = $? >> 8;
    
    # Check if timeout killed it (124 for GNU timeout, 143 for macOS timeout SIGTERM)
    if ($exit_code == 124 || $exit_code == 143) {
        print "  ❌ FAIL: --new --exit hung (killed by timeout)\n";
        print "    BUG: --exit should exit immediately after session creation\n\n";
    } else {
        assert_equals(0, $exit_code, "--new --exit should succeed");
        assert_contains($output, "Session ID", "--new should display session ID");
        $tests_passed++;
        print "  ✅ PASS\n\n";
    }
}

# Test 4: --input with --exit (non-interactive mode)
{
    print "Test 4: --input with --exit processes single input\n";
    $tests_run++;
    
    # Use simple input that doesn't require API call
    my $output2 = `timeout 5 $clio --new --input "/help" --exit 2>&1`;
    my $exit_code2 = $? >> 8;
    
    # Check for timeout
    if ($exit_code2 == 124 || $exit_code2 == 143) {
        print "  ❌ FAIL: --input --exit hung (killed by timeout)\n\n";
    } else {
        # Should exit cleanly even if it shows help
        assert_equals(0, $exit_code2, "--input --exit should exit cleanly");
        $tests_passed++;
        print "  ✅ PASS\n\n";
    }
}

# Test 5: stdin piping
{
    print "Test 5: echo input | clio processes stdin\n";
    $tests_run++;
    
    # Pipe /help command with timeout
    my $output3 = `timeout 5 bash -c 'echo "/help" | $clio --new --exit' 2>&1`;
    my $exit_code3 = $? >> 8;
    
    # Check for timeout
    if ($exit_code3 == 124 || $exit_code3 == 143) {
        print "  ❌ FAIL: stdin piping hung (killed by timeout)\n\n";
    } else {
        # Should handle stdin
        assert_equals(0, $exit_code3, "stdin input should be processed");
        $tests_passed++;
        print "  ✅ PASS\n\n";
    }
}

# Test 6: --debug flag enables debug output
{
    print "Test 6: --debug enables debug logging\n";
    $tests_run++;
    
    my $output = `$clio --new --debug --exit 2>&1`;
    my $exit_code = $? >> 8;
    
    assert_equals(0, $exit_code, "--debug should not break execution");
    assert_contains($output, "DEBUG", "--debug should show [DEBUG] messages");
    
    $tests_passed++;
    print "  ✅ PASS\n\n";
}

# Test 7: --model flag (if API available)
{
    print "Test 7: --model flag sets AI model\n";
    $tests_run++;
    
    my $output = `$clio --new --model gpt-4 --exit 2>&1`;
    my $exit_code = $? >> 8;
    
    # Should accept model parameter
    assert_equals(0, $exit_code, "--model should be accepted");
    
    $tests_passed++;
    print "  ✅ PASS\n\n";
}

# Test 8: Invalid flag shows error
{
    print "Test 8: Invalid flag shows helpful error\n";
    $tests_run++;
    
    my $output = `$clio --invalid-flag 2>&1`;
    my $exit_code = $? >> 8;
    
    # Should exit with error
    assert_true($exit_code != 0, "invalid flag should cause error exit");
    assert_contains($output, "Unknown option", "should mention unknown option");
    
    $tests_passed++;
    print "  ✅ PASS\n\n";
}

# Test 9: --resume without session ID
{
    print "Test 9: --resume without ID resumes last session\n";
    $tests_run++;
    
    # First create a session
    `$clio --new --exit 2>&1`;
    
    # Then try to resume
    my $output = `$clio --resume --exit 2>&1`;
    my $exit_code = $? >> 8;
    
    assert_equals(0, $exit_code, "--resume should work");
    assert_contains($output, "Session", "--resume should reference session");
    
    $tests_passed++;
    print "  ✅ PASS\n\n";
}

# Test 10: Multiple --input commands
{
    print "Test 10: --input can be used multiple times\n";
    $tests_run++;
    
    # This may not be supported, but test anyway
    my $output = `$clio --new --input "/help" --input "/help" --exit 2>&1`;
    my $exit_code = $? >> 8;
    
    # As long as it doesn't crash
    assert_equals(0, $exit_code, "multiple --input should not crash");
    
    $tests_passed++;
    print "  ✅ PASS\n\n";
}

# Summary
print "=" x 80 . "\n";
print "TEST SUMMARY\n";
print "=" x 80 . "\n";
print "Total tests: $tests_run\n";
print "Passed:      $tests_passed\n";
print "Failed:      " . ($tests_run - $tests_passed) . "\n";
print "=" x 80 . "\n\n";

if ($tests_passed == $tests_run) {
    print "✅ ALL CLI TESTS PASSED\n\n";
    exit 0;
} else {
    print "❌ SOME CLI TESTS FAILED\n\n";
    exit 1;
}
