#!/usr/bin/env perl

# SPDX-License-Identifier: GPL-3.0-only  
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

=head1 NAME

test_tools_e2e_natural.pl - End-to-end test for CLIO tool calling via natural language

=head1 DESCRIPTION

This script tests CLIO's ability to use tools through natural language requests.
Instead of explicitly saying "use file_operations tool", we ask CLIO to perform
tasks naturally and verify it chooses and executes the correct tools.

Tests focus on:
- Natural language → tool selection
- Tool execution success
- Result accuracy
- Multi-tool workflows
- Error handling

=head1 USAGE

    ./test_tools_e2e_natural.pl              # Run all tests
    ./test_tools_e2e_natural.pl --verbose    # Show detailed output

=cut

use strict;
use warnings;
use feature 'say';
use FindBin qw($RealBin);
use lib "$RealBin/lib";
use File::Temp qw(tempdir tempfile);
use File::Spec;
use Cwd 'abs_path';
use Getopt::Long;

# Command line options
my $verbose = 0;
GetOptions('verbose' => \$verbose);

# Test configuration
my $clio = abs_path("$RealBin/clio");
my $test_dir = tempdir(CLEANUP => 1);

# Color codes
my $C_RESET = "\e[0m";
my $C_GREEN = "\e[32m";
my $C_RED = "\e[31m";
my $C_YELLOW = "\e[33m";
my $C_CYAN = "\e[36m";
my $C_BOLD = "\e[1m";

# Test tracking
my $total = 0;
my $passed = 0;
my $failed = 0;
my @failures = ();

print "${C_BOLD}=" x 80 . "${C_RESET}\n";
print "${C_BOLD}CLIO END-TO-END NATURAL LANGUAGE TOOL CALLING TEST${C_RESET}\n";
print "${C_BOLD}=" x 80 . "${C_RESET}\n";
print "CLIO: $clio\n";
print "Test dir: $test_dir\n\n";

# Test runner
sub test_natural {
    my ($name, $request, $verify_sub, %opts) = @_;
    
    $total++;
    print "\n${C_CYAN}[TEST $total]${C_RESET} $name\n";
    print "  ${C_YELLOW}Request:${C_RESET} \"$request\"\n";
    
    my $cmd = qq{$clio --new --input "$request" --exit 2>&1};
    print "  ${C_YELLOW}Command:${C_RESET} $cmd\n" if $verbose;
    
    my $output = `$cmd`;
    my $exit_code = $? >> 8;
    
    if ($verbose) {
        print "  ${C_YELLOW}Output (first 500 chars):${C_RESET}\n";
        print "  " . substr($output, 0, 500) . "...\n";
    }
    
    my $error = '';
    eval {
        # Check exit code
        die "Command failed with exit code $exit_code" unless $exit_code == 0;
        
        # Check for critical errors (but allow normal log messages)
        die "Output contains 400 Bad Request error" if $output =~ /400 Bad Request/i;
        die "Output contains 'No response received'" if $output =~ /No response received/i;
        die "Tool execution failed" if $output =~ /\[ERROR\]\[Tools\]/i;
        
        # Run custom verification
        if ($verify_sub) {
            $verify_sub->($output, $test_dir);
        }
    };
    
    if ($@) {
        $failed++;
        $error = $@;
        chomp($error);
        push @failures, { name => $name, error => $error, output => $output };
        print "  ${C_RED}❌ FAIL${C_RESET}\n";
        print "  ${C_RED}Error:${C_RESET} $error\n";
    } else {
        $passed++;
        print "  ${C_GREEN}✅ PASS${C_RESET}\n";
    }
}

print "\n${C_BOLD}SECTION 1: BASIC FILE OPERATIONS${C_RESET}\n";
print "${C_BOLD}" . "-" x 80 . "${C_RESET}\n";

my $test_file = File::Spec->catfile($test_dir, "example.txt");

test_natural(
    "Create a file naturally",
    "Create a file at $test_file with the content 'Hello, CLIO!'",
    sub {
        my ($output, $dir) = @_;
        die "File wasn't created at $test_file" unless -f $test_file;
        open my $fh, '<', $test_file or die "Can't read file: $!";
        my $content = do { local $/; <$fh> };
        close $fh;
        die "File content is wrong, got: '$content'" unless $content =~ /Hello, CLIO!/;
    }
);

test_natural(
    "Read a file naturally",
    "What's in the file $test_file?",
    sub {
        my ($output, $dir) = @_;
        die "Response doesn't mention file content" unless $output =~ /Hello, CLIO!/;
    }
);

test_natural(
    "List files in directory",
    "What files are in $test_dir?",
    sub {
        my ($output, $dir) = @_;
        die "Response doesn't mention example.txt" unless $output =~ /example\.txt/;
    }
);

my $test_file2 = File::Spec->catfile($test_dir, "data.json");

test_natural(
    "Create JSON file",
    "Create a JSON file at $test_file2 with: {\"name\": \"test\", \"value\": 123}",
    sub {
        my ($output, $dir) = @_;
        die "JSON file not created" unless -f $test_file2;
        open my $fh, '<', $test_file2 or die "Can't read: $!";
        my $content = do { local $/; <$fh> };
        close $fh;
        die "JSON missing 'name' field" unless $content =~ /"name"/;
        die "JSON missing 'value' field" unless $content =~ /"value"/;
    }
);

print "\n${C_BOLD}SECTION 2: MULTI-TOOL WORKFLOWS${C_RESET}\n";
print "${C_BOLD}" . "-" x 80 . "${C_RESET}\n";

test_natural(
    "Create and verify multiple files",
    "Create 3 files in $test_dir: alpha.txt with 'A', beta.txt with 'B', gamma.txt with 'C'. Then list all files.",
    sub {
        my ($output, $dir) = @_;
        die "alpha.txt not created" unless -f File::Spec->catfile($dir, "alpha.txt");
        die "beta.txt not created" unless -f File::Spec->catfile($dir, "beta.txt");
        die "gamma.txt not created" unless -f File::Spec->catfile($dir, "gamma.txt");
        die "Response doesn't list files" unless $output =~ /alpha/ && $output =~ /beta/ && $output =~ /gamma/;
    }
);

test_natural(
    "Search and read pattern",
    "Find files in lib/CLIO/Tools containing 'sub execute' and tell me what FileOperations.pm does",
    sub {
        my ($output, $dir) = @_;
        die "Didn't search for pattern" unless $output =~ /(file|files|operations|tool)/i;
    }
);

print "\n${C_BOLD}SECTION 3: ERROR HANDLING${C_RESET}\n";
print "${C_BOLD}" . "-" x 80 . "${C_RESET}\n";

test_natural(
    "Handle nonexistent file gracefully",
    "Read the file /this/path/does/not/exist.txt",
    sub {
        my ($output, $dir) = @_;
        # Should mention that file doesn't exist or similar error
        die "Didn't handle missing file error" unless $output =~ /(not found|doesn't exist|cannot|error|failed)/i;
    }
);

test_natural(
    "Handle invalid operation gracefully",
    "Delete the entire universe",
    sub {
        my ($output, $dir) = @_;
        # Should either refuse or explain it can't do that
        die "Should have indicated this is impossible" unless $output =~ /(cannot|can't|unable|not possible|don't have|invalid)/i;
    }
);

print "\n${C_BOLD}SECTION 4: CODE INTELLIGENCE${C_RESET}\n";
print "${C_BOLD}" . "-" x 80 . "${C_RESET}\n";

test_natural(
    "Find symbol usages naturally",
    "Where is the render_markdown function used?",
    sub {
        my ($output, $dir) = @_;
        die "Didn't search for function" unless length($output) > 200;
    }
);

test_natural(
    "List directory contents naturally",
    "Show me what's in the lib/CLIO/UI directory",
    sub {
        my ($output, $dir) = @_;
        die "Response doesn't mention UI modules" unless $output =~ /(Chat|ANSI|Markdown|file|pm)/i;
    }
);

# Print summary
print "\n${C_BOLD}" . "=" x 80 . "${C_RESET}\n";
print "${C_BOLD}TEST SUMMARY${C_RESET}\n";
print "${C_BOLD}" . "=" x 80 . "${C_RESET}\n\n";

my $pass_rate = $total > 0 ? sprintf("%.1f%%", ($passed / $total) * 100) : "0%";

print "${C_CYAN}Total tests:${C_RESET}  $total\n";
print "${C_GREEN}✅ Passed:${C_RESET}    $passed\n";
print "${C_RED}❌ Failed:${C_RESET}    $failed\n";
print "${C_CYAN}Pass rate:${C_RESET}   $pass_rate\n\n";

if (@failures) {
    print "${C_RED}${C_BOLD}DETAILED FAILURES:${C_RESET}\n";
    print "${C_RED}" . "-" x 80 . "${C_RESET}\n";
    foreach my $failure (@failures) {
        print "\n${C_RED}❌ $failure->{name}${C_RESET}\n";
        print "   ${C_YELLOW}Error:${C_RESET} $failure->{error}\n";
        if ($verbose && $failure->{output}) {
            print "   ${C_YELLOW}Output:${C_RESET}\n";
            my $output = substr($failure->{output}, 0, 500);
            $output =~ s/^/   | /gm;
            print "$output\n";
        }
    }
    print "\n${C_RED}" . "-" x 80 . "${C_RESET}\n\n";
}

if ($failed == 0) {
    print "${C_GREEN}${C_BOLD}🎉 ALL TESTS PASSED!${C_RESET}\n";
    print "${C_GREEN}CLIO successfully handled natural language tool requests.${C_RESET}\n";
} else {
    print "${C_RED}${C_BOLD}⚠️  $failed TEST(S) FAILED${C_RESET}\n";
    print "${C_YELLOW}Run with --verbose for detailed output.${C_RESET}\n";
}
print "${C_BOLD}" . "=" x 80 . "${C_RESET}\n";

exit($failed > 0 ? 1 : 0);
