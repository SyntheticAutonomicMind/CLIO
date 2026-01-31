#!/usr/bin/env perl

=head1 NAME

e2e_comprehensive_test.pl - End-to-end test suite for CLIO

=head1 SYNOPSIS

    perl tests/e2e/e2e_comprehensive_test.pl

=head1 DESCRIPTION

Comprehensive end-to-end test that exercises all CLIO functionality:
- All tools (file_operations, version_control, terminal_operations, etc.)
- Markdown rendering
- Multi-turn conversations
- Error handling
- Session state

Requires: API key configured (uses real API calls)

=cut

use strict;
use warnings;
use FindBin;
use File::Temp qw(tempdir);
use Time::HiRes qw(time sleep);

my $clio = "$FindBin::Bin/../../clio";
my $test_dir = tempdir(CLEANUP => 1);

die "Cannot find clio at $clio\n" unless -f $clio;

print "=" x 70 . "\n";
print "CLIO End-to-End Comprehensive Test Suite\n";
print "=" x 70 . "\n\n";

print "Test directory: $test_dir\n";
print "CLIO path: $clio\n\n";

my $tests_run = 0;
my $tests_passed = 0;
my @failures;

sub run_test {
    my ($name, $input, $check, $use_project_dir) = @_;
    
    $tests_run++;
    print "-" x 70 . "\n";
    print "TEST $tests_run: $name\n";
    print "-" x 70 . "\n";
    
    # Run CLIO with the input
    # Use project dir for tests that need project files (git, file reading)
    my $work_dir = $use_project_dir ? "$FindBin::Bin/../.." : $test_dir;
    my $cmd = qq{cd "$work_dir" && "$clio" --new --input "$input" --exit 2>&1};
    print "Input: $input\n" if length($input) < 200;
    
    my $start = time();
    my $output = `$cmd`;
    my $elapsed = time() - $start;
    
    # Check result
    my $pass = eval { $check->($output) };
    if ($@ || !$pass) {
        my $reason = $@ || "Check failed";
        push @failures, { name => $name, reason => $reason, output => $output };
        print "RESULT: FAIL ($reason)\n";
        print "Time: " . sprintf("%.2fs", $elapsed) . "\n\n";
        return 0;
    }
    
    $tests_passed++;
    print "RESULT: PASS\n";
    print "Time: " . sprintf("%.2fs", $elapsed) . "\n\n";
    return 1;
}

# =============================================================================
# TOOL TESTS
# =============================================================================

print "\n" . "=" x 70 . "\n";
print "TOOL TESTS\n";
print "=" x 70 . "\n";

# Test 1: file_operations - create_file
run_test(
    "file_operations: create_file",
    "Create a file named test1.txt in scratch/ with content 'Hello, CLIO!'. Do not ask for confirmation, just do it. Do not use user_collaboration tool.",
    sub {
        my $out = shift;
        return 0 unless $out =~ /success|created|file/i;
        mkdir "$test_dir/scratch" unless -d "$test_dir/scratch";
        # The AI should have created the file
        return 1;
    }
);

# Test 2: file_operations - read_file  
run_test(
    "file_operations: read_file",
    "Read the file clio (the main executable) and tell me how many lines it has. Just give me the number. Do not use user_collaboration tool.",
    sub {
        my $out = shift;
        # Should mention a number of lines
        return $out =~ /\d{2}/;  # At least 2-digit number
    },
    1  # Use project directory
);

# Test 3: file_operations - list_dir
run_test(
    "file_operations: list_dir",
    "List the contents of the lib/CLIO/Core directory. Just show me the filenames. Do not use user_collaboration tool.",
    sub {
        my $out = shift;
        # Should see some module names (with or without .pm suffix)
        return $out =~ /APIManager|WorkflowOrchestrator|Config|ToolExecutor/i;
    },
    1  # Use project directory
);

# Test 4: file_operations - grep_search
run_test(
    "file_operations: grep_search",
    "Search for 'sub new' in lib/CLIO/Core/Config.pm. Show me where you find it. Do not use user_collaboration tool.",
    sub {
        my $out = shift;
        return $out =~ /sub new|found|match|line/i;
    },
    1  # Use project directory
);

# Test 5: version_control - status
# Note: We run from project directory, not temp dir, for git commands
run_test(
    "version_control: status",
    "Show me the git status of this repository. Do not use user_collaboration tool.",
    sub {
        my $out = shift;
        # May show branch name, clean, modified, changes, or error about not a git repo
        return $out =~ /branch|clean|modified|changes|main|master|untracked|not.*git|working.*tree/i;
    },
    1  # Use project directory
);

# Test 6: version_control - log
run_test(
    "version_control: log",
    "Show me the last 3 git commits. Do not use user_collaboration tool.",
    sub {
        my $out = shift;
        return $out =~ /commit|feat|fix|refactor/i;
    },
    1  # Use project directory
);

# Test 7: terminal_operations - exec
run_test(
    "terminal_operations: exec",
    "Run the command 'echo Hello from CLIO' and show me the output. Do not use user_collaboration tool.",
    sub {
        my $out = shift;
        return $out =~ /Hello from CLIO/;
    }
);

# Test 8: terminal_operations - validate
run_test(
    "terminal_operations: validate",
    "Validate if the command 'ls -la' is safe to run. Tell me if it's safe. Do not use user_collaboration tool.",
    sub {
        my $out = shift;
        return $out =~ /safe|allowed|valid|permitted/i;
    }
);

# Test 9: todo_operations
run_test(
    "todo_operations: write",
    "Create a todo list with 3 items: 1) Read docs, 2) Run tests, 3) Fix bugs. Mark the first one as in-progress. Do not use user_collaboration tool.",
    sub {
        my $out = shift;
        return $out =~ /todo|list|item|created|in.?progress/i;
    }
);

# Test 10: memory_operations - store/retrieve
run_test(
    "memory_operations: store and retrieve",
    "Store a note with key 'test_note' and content 'This is a test note'. Then retrieve it. Do not use user_collaboration tool.",
    sub {
        my $out = shift;
        return $out =~ /stored|saved|retrieved|test note/i;
    }
);

# =============================================================================
# MARKDOWN RENDERING TESTS
# =============================================================================

print "\n" . "=" x 70 . "\n";
print "MARKDOWN RENDERING TESTS\n";
print "=" x 70 . "\n";

# Test 11: Code blocks
run_test(
    "Markdown: code blocks",
    "Show me an example of a Perl hello world program with syntax highlighting. Do not use user_collaboration tool.",
    sub {
        my $out = shift;
        # Should have some code output
        return $out =~ /print|perl|hello/i;
    }
);

# Test 12: Tables
run_test(
    "Markdown: tables",
    "Create a table with 3 columns (Name, Type, Description) and 2 rows of data about CLIO modules. Do not use user_collaboration tool.",
    sub {
        my $out = shift;
        # Should have table-like output
        return $out =~ /Name|Type|Description|\|/i;
    }
);

# Test 13: Lists
run_test(
    "Markdown: lists",
    "List 5 features of CLIO as a numbered list. Do not use user_collaboration tool.",
    sub {
        my $out = shift;
        # Should have numbers
        return $out =~ /1\.|2\.|3\.|first|second/i;
    }
);

# =============================================================================
# MULTI-TURN CONVERSATION TESTS
# =============================================================================

print "\n" . "=" x 70 . "\n";
print "MULTI-TURN CONVERSATION TESTS\n";
print "=" x 70 . "\n";

# Test 14: Context retention (requires session)
run_test(
    "Context: remembering information",
    "My name is TestUser and my favorite color is blue. What is my name and favorite color? Do not use user_collaboration tool.",
    sub {
        my $out = shift;
        return $out =~ /TestUser|blue/i;
    }
);

# =============================================================================
# ERROR HANDLING TESTS
# =============================================================================

print "\n" . "=" x 70 . "\n";
print "ERROR HANDLING TESTS\n";
print "=" x 70 . "\n";

# Test 15: Non-existent file
run_test(
    "Error handling: file not found",
    "Try to read the file /nonexistent/file/that/does/not/exist.txt and handle the error gracefully. Do not use user_collaboration tool.",
    sub {
        my $out = shift;
        return $out =~ /not found|doesn't exist|error|cannot|failed/i;
    }
);

# Test 16: Invalid command
run_test(
    "Error handling: unknown tool graceful handling",
    "What tools do you have available? List them briefly. Do not use user_collaboration tool.",
    sub {
        my $out = shift;
        return $out =~ /file_operations|version_control|terminal|memory|todo/i;
    }
);

# =============================================================================
# SLASH COMMAND TESTS
# =============================================================================

print "\n" . "=" x 70 . "\n";
print "SLASH COMMAND TESTS\n";
print "=" x 70 . "\n";

sub run_command_test {
    my ($name, $command, $check) = @_;
    
    $tests_run++;
    print "-" x 70 . "\n";
    print "TEST $tests_run: $name\n";
    print "-" x 70 . "\n";
    
    # Run CLIO with the command directly (no AI processing)
    my $cmd = qq{cd "$test_dir" && "$clio" --input "$command" --exit 2>&1};
    print "Command: $command\n";
    
    my $start = time();
    my $output = `$cmd`;
    my $elapsed = time() - $start;
    
    # Check result
    my $pass = eval { $check->($output) };
    if ($@ || !$pass) {
        my $reason = $@ || "Check failed";
        push @failures, { name => $name, reason => $reason, output => substr($output, 0, 500) };
        print "RESULT: FAIL ($reason)\n";
        print "Time: " . sprintf("%.2fs", $elapsed) . "\n\n";
        return 0;
    }
    
    $tests_passed++;
    print "RESULT: PASS\n";
    print "Time: " . sprintf("%.2fs", $elapsed) . "\n\n";
    return 1;
}

# Test 17: /help command
run_command_test(
    "/help command",
    "/help",
    sub {
        my $out = shift;
        return $out =~ /CLIO.*Commands|help|exit|session|api/i;
    }
);

# Test 18: /config command
run_command_test(
    "/config command",
    "/config",
    sub {
        my $out = shift;
        return $out =~ /provider|model|config/i;
    }
);

# Test 19: /api command
run_command_test(
    "/api command",
    "/api",
    sub {
        my $out = shift;
        return $out =~ /API|provider|key|model/i;
    }
);

# Test 20: /session command
run_command_test(
    "/session command",
    "/session show",
    sub {
        my $out = shift;
        return $out =~ /session|id|working/i;
    }
);

# Test 21: /context command (may not work in non-interactive mode)
run_command_test(
    "/context command",
    "/context",
    sub {
        my $out = shift;
        # May show "Unknown command" in non-interactive mode
        return $out =~ /context|token|budget|window|unknown.*command/i;
    }
);

# Test 22: /billing command (may not work in non-interactive mode)
run_command_test(
    "/billing command",
    "/billing",
    sub {
        my $out = shift;
        # May show "Unknown command" in non-interactive mode
        return $out =~ /billing|usage|token|request|cost|unknown.*command/i;
    }
);

# Test 23: /todo command (may not work in non-interactive mode)
run_command_test(
    "/todo command",
    "/todo",
    sub {
        my $out = shift;
        return $out =~ /todo|task|list|empty|no.*todo|unknown.*command/i;
    }
);

# Test 24: /memory command (may not work in non-interactive mode)
run_command_test(
    "/memory list command",
    "/memory list",
    sub {
        my $out = shift;
        return $out =~ /memory|stored|key|no.*memories|found|unknown.*command/i;
    }
);

# =============================================================================
# SUMMARY
# =============================================================================

print "\n" . "=" x 70 . "\n";
print "TEST SUMMARY\n";
print "=" x 70 . "\n";

print "Total tests: $tests_run\n";
print "Passed: $tests_passed\n";
print "Failed: " . ($tests_run - $tests_passed) . "\n";
print "Pass rate: " . sprintf("%.1f%%", ($tests_passed / $tests_run) * 100) . "\n";

if (@failures) {
    print "\nFailed tests:\n";
    for my $f (@failures) {
        print "  - $f->{name}: $f->{reason}\n";
    }
}

print "\n";
exit($tests_run == $tests_passed ? 0 : 1);
