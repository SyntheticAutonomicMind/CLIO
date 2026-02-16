#!/usr/bin/env perl

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

=head1 NAME

test_code_intelligence.pl - Unit tests for CodeIntelligence tool

=head1 DESCRIPTION

Tests all code_intelligence operations:
- list_usages: Find symbol references in codebase
- search_history: Semantic search through git commit history

=cut

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use CLIO::Tools::CodeIntelligence;
use File::Temp qw(tempdir);
use Cwd 'abs_path';

print "="x60, "\n";
print "CodeIntelligence Tool Test Suite\n";
print "="x60, "\n\n";

# Change to project root for git operations
my $project_root = abs_path("$FindBin::Bin/../..");
chdir($project_root) or die "Cannot change to project root: $!";
print "Working directory: $project_root\n\n";

# Initialize tool
my $tool = CLIO::Tools::CodeIntelligence->new(debug => 0);

my $tests_passed = 0;
my $tests_failed = 0;

sub run_test {
    my ($name, $params, $expected_success, $check_output) = @_;
    
    print "-"x60, "\n";
    print "TEST: $name\n";
    print "-"x60, "\n";
    
    my $result = $tool->execute($params, { session => { id => 'test' } });
    
    my $success = $result->{success} ? 1 : 0;
    
    if ($success == $expected_success) {
        if (!$check_output || $check_output->($result)) {
            print "[OK] PASS\n\n";
            $tests_passed++;
            return 1;
        } else {
            print "[FAIL] FAIL: Output validation failed\n";
            print "Result: ", _dump($result), "\n\n";
            $tests_failed++;
            return 0;
        }
    } else {
        print "[FAIL] FAIL: Expected success=$expected_success, got $success\n";
        print "Error: ", $result->{error} || 'N/A', "\n";
        print "Message: ", $result->{message} || 'N/A', "\n\n";
        $tests_failed++;
        return 0;
    }
}

sub _dump {
    my ($data) = @_;
    require Data::Dumper;
    local $Data::Dumper::Indent = 1;
    local $Data::Dumper::Sortkeys = 1;
    local $Data::Dumper::Terse = 1;
    local $Data::Dumper::Maxdepth = 3;
    return Data::Dumper::Dumper($data);
}

print "\n### list_usages Tests ###\n";

# Test 1: list_usages - missing parameter
run_test(
    "list_usages - Missing symbol_name",
    { operation => 'list_usages' },
    0,  # Should fail
);

# Test 2: list_usages - find a common symbol
run_test(
    "list_usages - Find 'use strict' references",
    { operation => 'list_usages', symbol_name => 'use strict', file_paths => ['lib/CLIO/Tools'] },
    1,  # Should succeed
    sub {
        my $result = shift;
        # Should find multiple usages
        return $result->{count} > 0 && ref($result->{usages}) eq 'ARRAY';
    }
);

# Test 3: list_usages - find specific symbol
run_test(
    "list_usages - Find 'CodeIntelligence' symbol",
    { operation => 'list_usages', symbol_name => 'CodeIntelligence' },
    1,
    sub {
        my $result = shift;
        return $result->{count} > 0;
    }
);

# Test 4: list_usages - non-existent symbol
run_test(
    "list_usages - Non-existent symbol returns empty",
    { operation => 'list_usages', symbol_name => 'XyZzY_NonExistent_12345' },
    1,  # Should succeed but with 0 results
    sub {
        my $result = shift;
        return $result->{count} == 0;
    }
);

print "\n### search_history Tests ###\n";

# Test 5: search_history - missing query
run_test(
    "search_history - Missing query parameter",
    { operation => 'search_history' },
    0,  # Should fail
);

# Test 6: search_history - basic query
run_test(
    "search_history - Basic query 'fix bug'",
    { operation => 'search_history', query => 'fix bug', max_results => 5 },
    1,  # Should succeed
    sub {
        my $result = shift;
        # Should return array of commits (may be 0 if no matches)
        return ref($result->{commits}) eq 'ARRAY' &&
               ref($result->{keywords}) eq 'ARRAY';
    }
);

# Test 7: search_history - query with multiple keywords
run_test(
    "search_history - Multi-keyword query 'error handling'",
    { operation => 'search_history', query => 'error handling', max_results => 10 },
    1,
    sub {
        my $result = shift;
        # Check keywords were extracted
        return scalar(@{$result->{keywords}}) >= 2 &&
               ref($result->{commits}) eq 'ARRAY';
    }
);

# Test 8: search_history - with date filter
run_test(
    "search_history - With 'since' date filter",
    { operation => 'search_history', query => 'refactor', since => '2026-01-01', max_results => 5 },
    1,
    sub {
        my $result = shift;
        return ref($result->{commits}) eq 'ARRAY';
    }
);

# Test 9: search_history - verify commit structure
run_test(
    "search_history - Verify commit structure",
    { operation => 'search_history', query => 'add feature', max_results => 3 },
    1,
    sub {
        my $result = shift;
        return 1 if $result->{count} == 0;  # No matches is OK
        
        # Check first commit has required fields
        my $commit = $result->{commits}[0];
        return $commit->{hash} &&
               $commit->{date} &&
               $commit->{author} &&
               $commit->{subject} &&
               defined($commit->{score});
    }
);

# Test 10: search_history - empty keywords (query too short)
run_test(
    "search_history - Query with only short words",
    { operation => 'search_history', query => 'a b c' },  # All words <= 2 chars
    0,  # Should fail
);

# Test 11: search_history - files_changed populated for results
run_test(
    "search_history - Files changed populated",
    { operation => 'search_history', query => 'implement', max_results => 2 },
    1,
    sub {
        my $result = shift;
        return 1 if $result->{count} == 0;  # No matches is OK
        
        # Files changed should be an array (may be empty)
        my $commit = $result->{commits}[0];
        return ref($commit->{files_changed}) eq 'ARRAY';
    }
);

print "\n### Invalid Operation Test ###\n";

# Test 12: Invalid operation
run_test(
    "Invalid operation returns error",
    { operation => 'nonexistent_operation' },
    0,  # Should fail
);

# Summary
print "="x60, "\n";
print "TEST SUMMARY\n";
print "="x60, "\n";
print "Passed: $tests_passed\n";
print "Failed: $tests_failed\n";
print "Total:  ", ($tests_passed + $tests_failed), "\n";

if ($tests_failed > 0) {
    print "\n[FAIL] SOME TESTS FAILED\n";
    exit 1;
} else {
    print "\n[OK] ALL TESTS PASSED\n";
    exit 0;
}
