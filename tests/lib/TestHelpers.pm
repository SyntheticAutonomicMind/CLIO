package TestHelpers;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

=head1 NAME

TestHelpers - Test helper utilities for CLIO test suite

=head1 SYNOPSIS

    use lib 'tests/lib';
    use TestHelpers;
    
    assert_equals($expected, $actual, "Description");
    assert_file_exists("/tmp/test.txt");
    
    my $temp_file = create_temp_file("content");
    my $output = run_clio("--new --input 'test' --exit");

=head1 DESCRIPTION

Provides common test utilities for assertions, file management, CLIO execution,
and test result tracking.

=cut

use strict;
use warnings;
use utf8;
use Exporter 'import';
use File::Temp qw(tempfile tempdir);
use File::Spec;
use Cwd qw(getcwd abs_path);

our @EXPORT = qw(
    assert_equals
    assert_not_equals
    assert_true
    assert_false
    assert_matches
    assert_not_matches
    assert_contains
    assert_not_contains
    assert_file_exists
    assert_file_not_exists
    assert_file_contains
    assert_dir_exists
    create_temp_file
    create_temp_dir
    run_clio
    run_clio_with_session
    get_clio_path
    test_passed
    test_failed
    get_test_results
    reset_test_results
    print_test_summary
);

# Test result tracking
our $TESTS_PASSED = 0;
our $TESTS_FAILED = 0;
our @FAILURES = ();

=head1 ASSERTION FUNCTIONS

=head2 assert_equals

Assert that two values are equal.

    assert_equals($expected, $actual, $description);

=cut

sub assert_equals {
    my ($expected, $actual, $description) = @_;
    $description ||= "Values should be equal";
    
    if (!defined $expected && !defined $actual) {
        test_passed($description);
        return 1;
    }
    
    if (!defined $expected || !defined $actual) {
        test_failed($description, "One value is undefined", {
            expected => $expected // 'undef',
            actual => $actual // 'undef'
        });
        return 0;
    }
    
    if ($expected eq $actual) {
        test_passed($description);
        return 1;
    } else {
        test_failed($description, "Values not equal", {
            expected => $expected,
            actual => $actual
        });
        return 0;
    }
}

=head2 assert_not_equals

Assert that two values are NOT equal.

=cut

sub assert_not_equals {
    my ($expected, $actual, $description) = @_;
    $description ||= "Values should NOT be equal";
    
    if (defined $expected && defined $actual && $expected eq $actual) {
        test_failed($description, "Values are equal when they shouldn't be", {
            unexpected => $expected
        });
        return 0;
    } else {
        test_passed($description);
        return 1;
    }
}

=head2 assert_true

Assert that a value is true.

=cut

sub assert_true {
    my ($value, $description) = @_;
    $description ||= "Value should be true";
    
    if ($value) {
        test_passed($description);
        return 1;
    } else {
        test_failed($description, "Value is false", { value => $value });
        return 0;
    }
}

=head2 assert_false

Assert that a value is false.

=cut

sub assert_false {
    my ($value, $description) = @_;
    $description ||= "Value should be false";
    
    if (!$value) {
        test_passed($description);
        return 1;
    } else {
        test_failed($description, "Value is true", { value => $value });
        return 0;
    }
}

=head2 assert_matches

Assert that a string matches a regex pattern.

    assert_matches(qr/pattern/, $string, $description);

=cut

sub assert_matches {
    my ($pattern, $string, $description) = @_;
    $description ||= "String should match pattern";
    
    if ($string =~ $pattern) {
        test_passed($description);
        return 1;
    } else {
        test_failed($description, "String does not match pattern", {
            pattern => $pattern,
            string => $string
        });
        return 0;
    }
}

=head2 assert_not_matches

Assert that a string does NOT match a regex pattern.

=cut

sub assert_not_matches {
    my ($pattern, $string, $description) = @_;
    $description ||= "String should NOT match pattern";
    
    if ($string !~ $pattern) {
        test_passed($description);
        return 1;
    } else {
        test_failed($description, "String matches pattern when it shouldn't", {
            pattern => $pattern,
            string => $string
        });
        return 0;
    }
}

=head2 assert_contains

Assert that a string contains a substring.

=cut

sub assert_contains {
    my ($haystack, $needle, $description) = @_;
    $description ||= "String should contain substring";
    
    if (index($haystack, $needle) >= 0) {
        test_passed($description);
        return 1;
    } else {
        test_failed($description, "String does not contain substring", {
            haystack => substr($haystack, 0, 200) . (length($haystack) > 200 ? '...' : ''),
            needle => $needle
        });
        return 0;
    }
}

=head2 assert_not_contains

Assert that a string does NOT contain a substring.

=cut

sub assert_not_contains {
    my ($haystack, $needle, $description) = @_;
    $description ||= "String should NOT contain substring";
    
    if (index($haystack, $needle) < 0) {
        test_passed($description);
        return 1;
    } else {
        test_failed($description, "String contains substring when it shouldn't", {
            haystack => substr($haystack, 0, 200) . (length($haystack) > 200 ? '...' : ''),
            needle => $needle
        });
        return 0;
    }
}

=head2 assert_file_exists

Assert that a file or directory exists.

=cut

sub assert_file_exists {
    my ($path, $description) = @_;
    $description ||= "File should exist: $path";
    
    if (-e $path) {
        test_passed($description);
        return 1;
    } else {
        test_failed($description, "File does not exist", { path => $path });
        return 0;
    }
}

=head2 assert_file_not_exists

Assert that a file or directory does NOT exist.

=cut

sub assert_file_not_exists {
    my ($path, $description) = @_;
    $description ||= "File should NOT exist: $path";
    
    if (!-e $path) {
        test_passed($description);
        return 1;
    } else {
        test_failed($description, "File exists when it shouldn't", { path => $path });
        return 0;
    }
}

=head2 assert_file_contains

Assert that a file contains specific text.

=cut

sub assert_file_contains {
    my ($path, $pattern, $description) = @_;
    $description ||= "File should contain pattern: $path";
    
    if (!-f $path) {
        test_failed($description, "File does not exist", { path => $path });
        return 0;
    }
    
    open my $fh, '<:utf8', $path or do {
        test_failed($description, "Cannot read file: $!", { path => $path });
        return 0;
    };
    
    my $content = do { local $/; <$fh> };
    close $fh;
    
    if ($content =~ $pattern) {
        test_passed($description);
        return 1;
    } else {
        test_failed($description, "File does not contain pattern", {
            path => $path,
            pattern => $pattern
        });
        return 0;
    }
}

=head2 assert_dir_exists

Assert that a directory exists.

=cut

sub assert_dir_exists {
    my ($path, $description) = @_;
    $description ||= "Directory should exist: $path";
    
    if (-d $path) {
        test_passed($description);
        return 1;
    } else {
        test_failed($description, "Directory does not exist", { path => $path });
        return 0;
    }
}

=head1 FILE MANAGEMENT FUNCTIONS

=head2 create_temp_file

Create a temporary file with given content. File is automatically deleted when program exits.

    my $path = create_temp_file("content");
    my $path = create_temp_file("content", suffix => '.txt');

Returns: Absolute path to created file

=cut

sub create_temp_file {
    my ($content, %opts) = @_;
    
    my $suffix = $opts{suffix} || '';
    my $dir = $opts{dir} || undef;
    
    my ($fh, $filename) = tempfile(
        SUFFIX => $suffix,
        UNLINK => 1,
        ($dir ? (DIR => $dir) : ())
    );
    
    binmode($fh, ':utf8');
    print $fh $content;
    close $fh;
    
    return abs_path($filename);
}

=head2 create_temp_dir

Create a temporary directory. Directory is automatically deleted when program exits.

    my $path = create_temp_dir();

Returns: Absolute path to created directory

=cut

sub create_temp_dir {
    my %opts = @_;
    
    my $dir = tempdir(
        CLEANUP => 1,
        %opts
    );
    
    return abs_path($dir);
}

=head1 CLIO EXECUTION FUNCTIONS

=head2 get_clio_path

Get absolute path to clio executable.

=cut

sub get_clio_path {
    my $cwd = getcwd();
    
    # Try current directory
    my $clio = File::Spec->catfile($cwd, 'clio');
    return $clio if -x $clio;
    
    # Try parent directory (if we're in tests/)
    if ($cwd =~ /tests\/?$/) {
        my $parent = File::Spec->updir();
        $clio = File::Spec->catfile($parent, 'clio');
        return abs_path($clio) if -x $clio;
    }
    
    # Try project root (assume we're in tests/ subdirectory)
    $clio = File::Spec->catfile('..', 'clio');
    return abs_path($clio) if -x $clio;
    
    die "Cannot find clio executable. Run tests from project root or tests/ directory.\n";
}

=head2 run_clio

Execute CLIO with given arguments and return output.

    my $output = run_clio("--new --input 'test' --exit");
    my $output = run_clio("--help");

Arguments can be a string or array ref.

Returns: Combined STDOUT and STDERR output

=cut

sub run_clio {
    my (@args) = @_;
    
    my $clio = get_clio_path();
    
    # Handle array ref or list of args
    my $args_str;
    if (ref $args[0] eq 'ARRAY') {
        $args_str = join(' ', @{$args[0]});
    } else {
        $args_str = join(' ', @args);
    }
    
    my $cmd = "$clio $args_str 2>&1";
    my $output = `$cmd`;
    
    return $output;
}

=head2 run_clio_with_session

Execute CLIO with a session, handling session creation if needed.

    my ($output, $session_id) = run_clio_with_session("test input");
    my ($output, $session_id) = run_clio_with_session("next input", $session_id);

Returns: ($output, $session_id)

=cut

sub run_clio_with_session {
    my ($input, $session_id) = @_;
    
    my $args;
    if ($session_id) {
        $args = "--resume $session_id --input '$input' --exit";
    } else {
        $args = "--new --input '$input' --exit";
    }
    
    my $output = run_clio($args);
    
    # Extract session ID if this was a new session
    if (!$session_id && $output =~ /Session(?:\s+ID)?:\s*([a-f0-9-]+)/i) {
        $session_id = $1;
    }
    
    return ($output, $session_id);
}

=head1 TEST RESULT TRACKING

=head2 test_passed

Record a test as passed.

=cut

sub test_passed {
    my ($description) = @_;
    $TESTS_PASSED++;
    print "  ✅ PASS: $description\n";
}

=head2 test_failed

Record a test as failed.

=cut

sub test_failed {
    my ($description, $reason, $details) = @_;
    $TESTS_FAILED++;
    
    push @FAILURES, {
        description => $description,
        reason => $reason,
        details => $details
    };
    
    print "  ❌ FAIL: $description\n";
    print "    Reason: $reason\n" if $reason;
    
    if ($details && ref $details eq 'HASH') {
        for my $key (sort keys %$details) {
            my $value = $details->{$key};
            # Truncate long values
            if (length($value) > 200) {
                $value = substr($value, 0, 200) . '...';
            }
            print "    $key: $value\n";
        }
    }
}

=head2 get_test_results

Get current test results.

    my ($passed, $failed, $failures) = get_test_results();

Returns: ($passed_count, $failed_count, \@failures)

=cut

sub get_test_results {
    return ($TESTS_PASSED, $TESTS_FAILED, \@FAILURES);
}

=head2 reset_test_results

Reset test result counters (for new test run).

=cut

sub reset_test_results {
    $TESTS_PASSED = 0;
    $TESTS_FAILED = 0;
    @FAILURES = ();
}

=head2 print_test_summary

Print test summary and exit with appropriate code.

    print_test_summary();  # Exits with 0 if all passed, 1 if any failed

=cut

sub print_test_summary {
    my $total = $TESTS_PASSED + $TESTS_FAILED;
    
    print "\n";
    print "=" x 80 . "\n";
    print "TEST SUMMARY\n";
    print "=" x 80 . "\n";
    print "Total tests: $total\n";
    print "Passed:      $TESTS_PASSED\n";
    print "Failed:      $TESTS_FAILED\n";
    
    if ($TESTS_FAILED > 0) {
        print "\nFAILURES:\n";
        for my $i (0..$#FAILURES) {
            my $failure = $FAILURES[$i];
            print "\n" . ($i+1) . ". $failure->{description}\n";
            print "   Reason: $failure->{reason}\n" if $failure->{reason};
        }
        print "\n❌ TESTS FAILED\n";
        exit 1;
    } else {
        print "\n✅ ALL TESTS PASSED\n";
        exit 0;
    }
}

1;

__END__

=head1 USAGE EXAMPLES

    use lib 'tests/lib';
    use TestHelpers;
    use TestData;
    
    # Test file operations with Unicode
    my $emoji = TestData::emoji_string();
    my $file = create_temp_file($emoji);
    
    assert_file_exists($file, "Temp file created");
    assert_file_contains($file, qr/🎉/, "File contains emoji");
    
    # Test CLIO execution
    my $output = run_clio("--new --input 'hello' --exit");
    assert_contains($output, "CLIO", "Output contains CLIO");
    
    # Print summary and exit
    print_test_summary();

=head1 SEE ALSO

L<TestData> - Test data generation

=cut
