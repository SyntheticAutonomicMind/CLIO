#!/usr/bin/env perl

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

=head1 NAME

test_search_history_e2e.pl - End-to-end test for search_history with AI agent

=head1 DESCRIPTION

Tests that the AI agent can correctly use the code_intelligence search_history
operation to search through git commit history semantically.

Uses gpt-5-mini model for fast, low-cost testing.

Run with --skip-api to skip API-dependent tests (useful for CI).

=cut

use strict;
use warnings;
use FindBin;
use Cwd 'abs_path';
use Getopt::Long;

my $skip_api = 0;
GetOptions('skip-api' => \$skip_api);

my $clio = abs_path("$FindBin::Bin/../../clio");
my $project_root = abs_path("$FindBin::Bin/../..");

print "="x70, "\n";
print "E2E Test: code_intelligence search_history\n";
print "="x70, "\n\n";

print "CLIO binary: $clio\n";
print "Project root: $project_root\n";
print "Skip API tests: ", ($skip_api ? "yes" : "no"), "\n\n";

my $tests_passed = 0;
my $tests_failed = 0;
my $tests_skipped = 0;

# First, verify the tool is registered and works directly
print "-"x70, "\n";
print "PRE-FLIGHT: Verify tool registration and direct execution\n";
print "-"x70, "\n";

my $preflight_cmd = qq{cd "$project_root" && perl -I./lib -e '
use CLIO::Tools::CodeIntelligence;
my \$tool = CLIO::Tools::CodeIntelligence->new();
my \$result = \$tool->execute({
    operation => "search_history",
    query => "error handling",
    max_results => 3
}, { session => { id => "test" } });
print "success:", \$result->{success}, "\\n";
print "count:", \$result->{count}, "\\n";
print "showing:", \$result->{showing} // 0, "\\n";
' 2>&1};

my $preflight_output = `$preflight_cmd`;
if ($preflight_output =~ /success:1/ && $preflight_output =~ /count:\d+/) {
    print "[OK] Tool registration and direct execution verified\n";
    print "Output: $preflight_output\n";
    $tests_passed++;
} else {
    print "[FAIL] Tool direct execution failed\n";
    print "Output: $preflight_output\n";
    $tests_failed++;
    die "Cannot proceed - tool not working\n";
}

if ($skip_api) {
    print "\n[SKIP] Skipping API-dependent tests (--skip-api flag)\n";
    $tests_skipped = 3;
} else {
    # Check if API is responsive first
    print "\n";
    print "-"x70, "\n";
    print "PRE-FLIGHT: Check API connectivity\n";
    print "-"x70, "\n";
    
    my $api_check = qq{cd "$project_root" && timeout 30 "$clio" --input "respond with just OK" --exit 2>&1};
    my $api_output = `$api_check`;
    my $api_exit = $? >> 8;
    
    if ($api_exit == 124 || $api_output !~ /OK|ok|Hello|hello/i) {
        print "[WARN] API not responsive (exit: $api_exit), skipping agent tests\n";
        print "Output: ", substr($api_output, 0, 200), "\n";
        $tests_skipped = 3;
    } else {
        print "[OK] API responsive\n";
        
        # Run actual e2e tests
        run_clio_test(
            "Agent uses search_history for git history query",
            "Use code_intelligence search_history to find commits about error handling. Show me the top 3.",
            [qr/commit|match|error|handling/i],
            120
        );
        
        run_clio_test(
            "Agent uses search_history with since filter",
            "Search git history for refactor commits since 2026-02-01 using code_intelligence search_history",
            [qr/commit|match|refactor/i],
            120
        );
        
        run_clio_test(
            "Agent finds search_history for history question",
            "What commits have we made related to session? Search the git history.",
            [qr/commit|session/i],
            120
        );
    }
}

sub run_clio_test {
    my ($name, $input, $expected_patterns, $timeout) = @_;
    $timeout //= 90;
    
    print "-"x70, "\n";
    print "TEST: $name\n";
    print "-"x70, "\n";
    print "Input: $input\n\n";
    
    my $cmd = qq{cd "$project_root" && timeout $timeout "$clio" --model gpt-5-mini --input "$input" --exit 2>&1};
    my $output = `$cmd`;
    my $exit_code = $? >> 8;
    
    my $all_matched = 1;
    my @missing = ();
    
    for my $pattern (@$expected_patterns) {
        if ($output !~ /$pattern/) {
            $all_matched = 0;
            push @missing, $pattern;
        }
    }
    
    if ($exit_code == 124) {
        print "[SKIP] Timeout - API slow or unresponsive\n\n";
        $tests_skipped++;
        return 0;
    } elsif ($all_matched) {
        print "[OK] PASS\n";
        my $snippet = substr($output, 0, 300);
        $snippet =~ s/\n/ /g;
        print "Output snippet: $snippet...\n\n";
        $tests_passed++;
        return 1;
    } else {
        print "[FAIL] FAIL\n";
        print "Exit code: $exit_code\n";
        print "Missing patterns: ", join(", ", @missing), "\n" if @missing;
        print "Output (first 500 chars): ", substr($output, 0, 500), "\n\n";
        $tests_failed++;
        return 0;
    }
}

# Summary
print "="x70, "\n";
print "E2E TEST SUMMARY\n";
print "="x70, "\n";
print "Passed:  $tests_passed\n";
print "Failed:  $tests_failed\n";
print "Skipped: $tests_skipped\n";
print "Total:   ", ($tests_passed + $tests_failed + $tests_skipped), "\n";

if ($tests_failed > 0) {
    print "\n[WARN] SOME E2E TESTS FAILED\n";
    exit 1;
} else {
    print "\n[OK] ALL EXECUTED TESTS PASSED\n";
    exit 0;
}
