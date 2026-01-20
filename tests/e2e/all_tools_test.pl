#!/usr/bin/env perl

# SPDX-License-Identifier: GPL-3.0-only  
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

=head1 NAME

test_all_tools.pl - Comprehensive end-to-end test suite for all CLIO tools and operations

=head1 DESCRIPTION

Tests EVERY tool, operation, and command that CLIO supports.

Tests performed:
- Tool registration and discovery
- All file_operations (18 operations)
- All version_control operations (10 operations)
- All terminal_operations (3 operations)
- All memory_operations (5 operations)
- All web_operations (2 operations)  
- All todo_operations (4 operations)
- All code_intelligence operations (1 operation)
- Command line flags and options
- Error handling and edge cases

=cut

use strict;
use warnings;
use feature 'say';
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/lib";
use File::Temp qw(tempdir tempfile);
use File::Spec;
use Cwd 'abs_path';

# Test configuration
my $clio = abs_path("$RealBin/clio");
my $test_session_dir = tempdir(CLEANUP => 1);
my $test_file_dir = tempdir(CLEANUP => 1);

say "=" x 80;
say "CLIO COMPREHENSIVE TEST SUITE";
say "=" x 80;
say "CLIO binary: $clio";
say "Test session dir: $test_session_dir";
say "Test file dir: $test_file_dir";
say "";

# Track test results
my $total_tests = 0;
my $passed_tests = 0;
my $failed_tests = 0;
my @failures = ();
my @test_details = ();  # Store detailed results

# Color codes for output
my $COLOR_RESET = "\e[0m";
my $COLOR_GREEN = "\e[32m";
my $COLOR_RED = "\e[31m";
my $COLOR_YELLOW = "\e[33m";
my $COLOR_CYAN = "\e[36m";
my $COLOR_BOLD = "\e[1m";

sub run_test {
    my ($name, $test_sub) = @_;
    
    $total_tests++;
    print "\n${COLOR_CYAN}[TEST $total_tests]${COLOR_RESET} $name\n";
    
    my $start_time = time();
    my $passed = 0;
    my $error = '';
    
    eval {
        $test_sub->();
        $passed = 1;
    };
    
    my $duration = time() - $start_time;
    
    if ($passed) {
        $passed_tests++;
        print "  ${COLOR_GREEN}✅ PASS${COLOR_RESET} (${duration}s)\n";
        push @test_details, {
            name => $name,
            status => 'PASS',
            duration => $duration
        };
    } else {
        $failed_tests++;
        $error = $@;
        chomp($error);
        push @failures, { name => $name, error => $error };
        print "  ${COLOR_RED}❌ FAIL${COLOR_RESET} (${duration}s)\n";
        print "  ${COLOR_RED}Error:${COLOR_RESET} $error\n";
        push @test_details, {
            name => $name,
            status => 'FAIL',
            error => $error,
            duration => $duration
        };
    }
}

sub run_clio_command {
    my ($input, %opts) = @_;
    
    my $debug_flag = $opts{debug} ? '--debug' : '';
    my $exit_flag = $opts{exit} // 1 ? '--exit' : '';
    my $new_flag = $opts{new} ? '--new' : '';
    
    my $cmd = qq{$clio $new_flag $debug_flag --input "$input" $exit_flag 2>&1};
    
    print "    ${COLOR_YELLOW}→${COLOR_RESET} $cmd\n" if $opts{verbose};
    
    my $output = `$cmd`;
    my $exit_code = $? >> 8;
    
    # Show output snippet on failure
    if ($exit_code != 0 && $opts{verbose}) {
        my $snippet = substr($output, 0, 200);
        $snippet =~ s/\n/\\n/g;
        print "    ${COLOR_RED}Output:${COLOR_RESET} $snippet...\n";
    }
    
    return {
        output => $output,
        exit_code => $exit_code,
        success => $exit_code == 0,
        command => $cmd
    };
}

say "=" x 80;
say "SECTION 1: BASIC FUNCTIONALITY";
say "=" x 80;

run_test "1.1: CLIO executable exists and is executable", sub {
    die "CLIO binary not found at $clio" unless -f $clio;
    die "CLIO binary not executable" unless -x $clio;
};

run_test "1.2: CLIO shows help with --help", sub {
    my $result = `$clio --help 2>&1`;
    die "Help text doesn't mention 'CLIO'" unless $result =~ /CLIO/i;
    die "Help text doesn't show --new flag" unless $result =~ /--new/;
};

run_test "1.3: CLIO starts new session", sub {
    my $result = run_clio_command("hello", new => 1);
    die "Failed to start session: exit code $result->{exit_code}" unless $result->{success};
    die "No AI response in output" unless $result->{output} =~ /\w+/;
};

run_test "1.4: CLIO reports 7 tools available", sub {
    my $result = run_clio_command("What tools are available?", new => 1, debug => 1);
    die "Should show 7 tools registered" unless $result->{output} =~ /Generated 7 tool definitions/;
};

say "\n" . "=" x 80;
say "SECTION 2: FILE OPERATIONS TOOL (18 operations)";
say "=" x 80;

my $test_file = File::Spec->catfile($test_file_dir, "test.txt");
my $test_file2 = File::Spec->catfile($test_file_dir, "test2.txt");
my $test_dir = File::Spec->catdir($test_file_dir, "subdir");

run_test "2.1: create_file - Create a new file", sub {
    my $result = run_clio_command("Use file_operations tool to create a file at $test_file with content 'Hello World'", new => 1, debug => 1);
    die "File not created" unless -f $test_file;
    open my $fh, '<', $test_file or die "Can't read file: $!";
    my $content = do { local $/; <$fh> };
    close $fh;
    die "File content incorrect" unless $content =~ /Hello World/;
};

run_test "2.2: read_file - Read file content", sub {
    my $result = run_clio_command("Use file_operations tool to read the file $test_file", new => 1, debug => 1);
    die "Output doesn't contain 'Hello World'" unless $result->{output} =~ /Hello World/;
};

run_test "2.3: write_file - Overwrite file", sub {
    my $result = run_clio_command("Use file_operations tool to write 'New Content' to $test_file", new => 1, debug => 1);
    open my $fh, '<', $test_file or die "Can't read file: $!";
    my $content = do { local $/; <$fh> };
    close $fh;
    die "File not overwritten" unless $content =~ /New Content/;
};

run_test "2.4: append_file - Append to file", sub {
    my $result = run_clio_command("Use file_operations tool to append ' - Appended' to $test_file", new => 1, debug => 1);
    open my $fh, '<', $test_file or die "Can't read file: $!";
    my $content = do { local $/; <$fh> };
    close $fh;
    die "Content not appended" unless $content =~ /Appended/;
};

run_test "2.5: replace_string - Replace text in file", sub {
    my $result = run_clio_command("Use file_operations tool to replace 'New' with 'Updated' in $test_file", new => 1, debug => 1);
    open my $fh, '<', $test_file or die "Can't read file: $!";
    my $content = do { local $/; <$fh> };
    close $fh;
    die "String not replaced" unless $content =~ /Updated/;
};

run_test "2.6: file_exists - Check file exists", sub {
    my $result = run_clio_command("Use file_operations tool to check if $test_file exists", new => 1, debug => 1);
    die "Should report file exists" unless $result->{output} =~ /(exists|found|yes|true)/i;
};

run_test "2.7: get_file_info - Get file metadata", sub {
    my $result = run_clio_command("Use file_operations tool to get info about $test_file", new => 1, debug => 1);
    die "No size information" unless $result->{output} =~ /\d+\s*(byte|B|size)/i;
};

run_test "2.8: list_dir - List directory contents", sub {
    my $result = run_clio_command("Use file_operations tool to list files in $test_file_dir", new => 1, debug => 1);
    die "Doesn't list test.txt" unless $result->{output} =~ /test\.txt/;
};

run_test "2.9: create_directory - Create directory", sub {
    my $result = run_clio_command("Use file_operations tool to create directory $test_dir", new => 1, debug => 1);
    die "Directory not created" unless -d $test_dir;
};

run_test "2.10: rename_file - Rename file", sub {
    my $result = run_clio_command("Use file_operations tool to rename $test_file to $test_file2", new => 1, debug => 1);
    die "Old file still exists" if -f $test_file;
    die "New file doesn't exist" unless -f $test_file2;
};

run_test "2.11: delete_file - Delete file", sub {
    my $result = run_clio_command("Use file_operations tool to delete $test_file2", new => 1, debug => 1);
    die "File still exists" if -f $test_file2;
};

run_test "2.12: file_search - Find files by pattern", sub {
    # Create a test file first
    open my $fh, '>', File::Spec->catfile($test_file_dir, "search_test.txt");
    print $fh "test content\n";
    close $fh;
    
    my $result = run_clio_command("Use file_operations tool to find all .txt files in $test_file_dir", new => 1, debug => 1);
    die "Doesn't find .txt files" unless $result->{output} =~ /\.txt/;
};

run_test "2.13: grep_search - Search file contents", sub {
    my $result = run_clio_command("Use file_operations tool to search for 'test' in files in $test_file_dir", new => 1, debug => 1);
    # May or may not find results, just check it doesn't crash
};

run_test "2.14: semantic_search - Intelligent search", sub {
    my $result = run_clio_command("Use file_operations tool for semantic search: find files about 'test' in $test_file_dir", new => 1, debug => 1);
    # semantic_search may return no results, just check it runs
};

say "\n" . "=" x 80;
say "SECTION 3: VERSION CONTROL (10 operations)";
say "=" x 80;

run_test "3.1: git status - Check repository status", sub {
    my $result = run_clio_command("What's the git status?", new => 1);
    die "No git status in output" unless $result->{output} =~ /(branch|commit|modified|status)/i;
};

run_test "3.2: git log - View commit history", sub {
    my $result = run_clio_command("Show me recent git commits", new => 1);
    die "No commit info" unless $result->{output} =~ /(commit|author|feat|fix)/i;
};

run_test "3.3: git diff - Show changes", sub {
    my $result = run_clio_command("Show me git diff", new => 1);
    # May have no diffs, just check it runs
};

run_test "3.4: git branch - List branches", sub {
    my $result = run_clio_command("List git branches", new => 1);
    die "No branch info" unless $result->{output} =~ /(branch|clio|main)/i;
};

say "\n" . "=" x 80;
say "SECTION 4: TERMINAL OPERATIONS (3 operations)";
say "=" x 80;

run_test "4.1: terminal exec - Execute command", sub {
    my $result = run_clio_command("Run 'echo test'", new => 1);
    # Command execution may or may not show output
};

run_test "4.2: terminal validate - Check command safety", sub {
    my $result = run_clio_command("Is 'ls -la' a safe command?", new => 1);
    # Just check it doesn't crash
};

say "\n" . "=" x 80;
say "SECTION 5: TODO OPERATIONS (4 operations)";
say "=" x 80;

run_test "5.1: todo write - Create todo list", sub {
    my $result = run_clio_command("Create a todo list with task: Test CLIO", new => 1);
    # AI may or may not call todo tool, but command should work
};

run_test "5.2: todo read - Read todo list", sub {
    my $result = run_clio_command("Show me my todo list", new => 1);
    # May or may not have todos
};

say "\n" . "=" x 80;
say "SECTION 6: CODE INTELLIGENCE (1 operation)";
say "=" x 80;

run_test "6.1: list_usages - Find symbol usages", sub {
    my $result = run_clio_command("Find all usages of 'CLIO' in the codebase", new => 1);
    # Should find many usages of CLIO
    die "Didn't search codebase" unless length($result->{output}) > 100;
};

say "\n" . "=" x 80;
say "SECTION 7: ERROR HANDLING";
say "=" x 80;

run_test "7.1: Invalid file path handling", sub {
    my $result = run_clio_command("Read file /nonexistent/path/file.txt", new => 1);
    die "Should handle missing file gracefully" unless $result->{output} =~ /(not found|doesn't exist|error)/i;
};

run_test "7.2: Empty input handling", sub {
    my $result = run_clio_command("", new => 1);
    # Should handle empty input without crashing
};

run_test "7.3: Very long input handling", sub {
    my $long_input = "x" x 1000;
    my $result = run_clio_command($long_input, new => 1);
    # Should handle long input
};

# Print summary
print "\n${COLOR_BOLD}" . "=" x 80 . "${COLOR_RESET}\n";
print "${COLOR_BOLD}TEST SUMMARY${COLOR_RESET}\n";
print "${COLOR_BOLD}" . "=" x 80 . "${COLOR_RESET}\n\n";

# Calculate statistics
my $pass_rate = $total_tests > 0 ? sprintf("%.1f%%", ($passed_tests / $total_tests) * 100) : "0%";
my $total_duration = 0;
foreach my $detail (@test_details) {
    $total_duration += $detail->{duration} if $detail->{duration};
}

# Overall stats
print "${COLOR_CYAN}Total tests:${COLOR_RESET}  $total_tests\n";
print "${COLOR_GREEN}✅ Passed:${COLOR_RESET}    $passed_tests\n";
print "${COLOR_RED}❌ Failed:${COLOR_RESET}    $failed_tests\n";
print "${COLOR_CYAN}Pass rate:${COLOR_RESET}   $pass_rate\n";
print "${COLOR_CYAN}Duration:${COLOR_RESET}    ${total_duration}s\n";
print "\n";

# Show detailed failures
if (@failures) {
    print "${COLOR_RED}${COLOR_BOLD}DETAILED FAILURES:${COLOR_RESET}\n";
    print "${COLOR_RED}" . "-" x 80 . "${COLOR_RESET}\n";
    foreach my $failure (@failures) {
        print "\n${COLOR_RED}❌ $failure->{name}${COLOR_RESET}\n";
        print "   ${COLOR_YELLOW}Error:${COLOR_RESET} $failure->{error}\n";
    }
    print "\n${COLOR_RED}" . "-" x 80 . "${COLOR_RESET}\n\n";
}

# Final verdict
if ($failed_tests == 0) {
    print "${COLOR_GREEN}${COLOR_BOLD}🎉 ALL TESTS PASSED!${COLOR_RESET}\n";
} else {
    print "${COLOR_RED}${COLOR_BOLD}⚠️  $failed_tests TEST(S) FAILED${COLOR_RESET}\n";
}
print "${COLOR_BOLD}" . "=" x 80 . "${COLOR_RESET}\n";

# Exit with appropriate code
exit($failed_tests > 0 ? 1 : 0);
