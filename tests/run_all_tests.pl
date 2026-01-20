#!/usr/bin/env perl

=head1 NAME

run_all_tests.pl - Test runner for CLIO test suite

=head1 SYNOPSIS

    # Run all tests
    perl tests/run_all_tests.pl --all
    
    # Run specific categories
    perl tests/run_all_tests.pl --unit
    perl tests/run_all_tests.pl --integration
    perl tests/run_all_tests.pl --e2e
    
    # Run multiple categories
    perl tests/run_all_tests.pl --unit --integration
    
    # Verbose output
    perl tests/run_all_tests.pl --all --verbose
    
    # Stop on first failure
    perl tests/run_all_tests.pl --all --stop-on-failure

=head1 DESCRIPTION

Comprehensive test runner for CLIO's organized test suite.

Runs tests from:
- tests/unit/       - Unit tests (individual modules)
- tests/integration - Integration tests (multi-module workflows)
- tests/e2e/        - End-to-end tests (full CLIO execution)

=cut

use strict;
use warnings;
use feature 'say';
use File::Find;
use File::Spec;
use Getopt::Long;
use Time::HiRes qw(time);

# Parse command line options
my %opts = (
    unit => 0,
    integration => 0,
    e2e => 0,
    all => 0,
    verbose => 0,
    stop_on_failure => 0,
);

GetOptions(
    'unit' => \$opts{unit},
    'integration' => \$opts{integration},
    'e2e' => \$opts{e2e},
    'all' => \$opts{all},
    'verbose' => \$opts{verbose},
    'stop-on-failure' => \$opts{stop_on_failure},
    'help' => sub { usage(); exit 0; },
) or usage_and_exit();

# If --all, enable all categories
if ($opts{all}) {
    $opts{unit} = $opts{integration} = $opts{e2e} = 1;
}

# If no category specified, default to --all
unless ($opts{unit} || $opts{integration} || $opts{e2e}) {
    $opts{unit} = $opts{integration} = $opts{e2e} = 1;
}

# Test categories and their directories
my %categories = (
    unit => 'tests/unit',
    integration => 'tests/integration',
    e2e => 'tests/e2e',
);

# Results tracking
my %results = (
    total => 0,
    passed => 0,
    failed => 0,
    skipped => 0,
    errors => [],
);

# Start time
my $start_time = time();

# Print header
say "";
say "=" x 80;
say "CLIO Test Suite Runner";
say "=" x 80;
say "";

# Run tests for each enabled category
for my $category (qw(unit integration e2e)) {
    next unless $opts{$category};
    
    say "\n" . "─" x 80;
    say "Running $category tests";
    say "─" x 80;
    
    run_category_tests($category, $categories{$category});
    
    # Stop if we had failures and --stop-on-failure is set
    if ($opts{stop_on_failure} && $results{failed} > 0) {
        say "\n⚠️  Stopping due to test failures (--stop-on-failure)";
        last;
    }
}

# Print summary
print_summary();

# Exit with failure code if any tests failed
exit($results{failed} > 0 ? 1 : 0);

#=============================================================================
# Subroutines
#=============================================================================

sub run_category_tests {
    my ($category, $dir) = @_;
    
    unless (-d $dir) {
        say "  ⚠️  Directory not found: $dir";
        return;
    }
    
    # Find all test files (*.pl and *.sh)
    my @test_files;
    find(sub {
        return unless -f $_;
        return unless /\.(pl|sh)$/;
        push @test_files, $File::Find::name;
    }, $dir);
    
    @test_files = sort @test_files;
    
    unless (@test_files) {
        say "  ⚠️  No test files found in $dir";
        return;
    }
    
    say "  Found " . scalar(@test_files) . " test file(s)";
    say "";
    
    # Run each test file
    for my $test_file (@test_files) {
        run_test_file($test_file);
    }
}

sub run_test_file {
    my ($test_file) = @_;
    
    my $test_name = File::Spec->abs2rel($test_file, 'tests');
    
    $results{total}++;
    
    say "  🧪 Running: $test_name";
    
    # Determine how to run the test
    my $command;
    if ($test_file =~ /\.pl$/) {
        $command = "perl -Ilib -Itests/lib $test_file 2>&1";
    } elsif ($test_file =~ /\.sh$/) {
        $command = "bash $test_file 2>&1";
    } else {
        say "    ⚠️  Unknown test file type: $test_file";
        $results{skipped}++;
        return;
    }
    
    # Run the test
    my $test_start = time();
    my $output = `$command`;
    my $exit_code = $? >> 8;
    my $test_duration = time() - $test_start;
    
    # Check result
    if ($exit_code == 0) {
        $results{passed}++;
        say sprintf("    ✅ PASSED (%.2fs)", $test_duration);
        
        # Show output if verbose
        if ($opts{verbose} && $output) {
            say "    Output:";
            for my $line (split /\n/, $output) {
                say "      $line";
            }
        }
    } else {
        $results{failed}++;
        say sprintf("    ❌ FAILED (exit code: $exit_code, %.2fs)", $test_duration);
        
        # Always show failed test output
        if ($output) {
            say "    Output:";
            for my $line (split /\n/, $output) {
                say "      $line";
            }
        }
        
        # Track the failure
        push @{$results{errors}}, {
            file => $test_name,
            exit_code => $exit_code,
            output => $output,
        };
    }
    
    say "";
}

sub print_summary {
    my $duration = time() - $start_time;
    
    say "\n";
    say "=" x 80;
    say "TEST SUMMARY";
    say "=" x 80;
    say sprintf("Total tests:    %d", $results{total});
    say sprintf("Passed:         %d (%.1f%%)", 
        $results{passed}, 
        $results{total} > 0 ? ($results{passed} / $results{total} * 100) : 0
    );
    say sprintf("Failed:         %d", $results{failed});
    say sprintf("Skipped:        %d", $results{skipped});
    say sprintf("Duration:       %.2fs", $duration);
    say "=" x 80;
    
    if ($results{failed} > 0) {
        say "\n❌ FAILURES:";
        for my $error (@{$results{errors}}) {
            say "  - $error->{file} (exit code: $error->{exit_code})";
        }
        say "";
    } elsif ($results{passed} > 0) {
        say "\n✅ ALL TESTS PASSED!";
        say "";
    }
}

sub usage {
    say "Usage: $0 [OPTIONS]";
    say "";
    say "Options:";
    say "  --unit              Run unit tests only";
    say "  --integration       Run integration tests only";
    say "  --e2e               Run end-to-end tests only";
    say "  --all               Run all tests (default)";
    say "  --verbose           Show test output even for passing tests";
    say "  --stop-on-failure   Stop at first failure";
    say "  --help              Show this help message";
    say "";
    say "Examples:";
    say "  $0 --all                      # Run all tests";
    say "  $0 --unit                     # Run unit tests only";
    say "  $0 --unit --integration       # Run unit and integration tests";
    say "  $0 --all --verbose            # Run all tests with verbose output";
    say "";
}

sub usage_and_exit {
    usage();
    exit 1;
}
