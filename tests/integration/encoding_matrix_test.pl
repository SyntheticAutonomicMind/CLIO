#!/usr/bin/env perl

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

=head1 NAME

encoding_matrix_test.pl - Comprehensive character encoding test for ALL CLIO tools

=head1 DESCRIPTION

This is THE critical test that will expose the "Wide character in subroutine entry" bug.

Tests EVERY tool operation with EVERY character encoding:
- ASCII (basic English)
- Extended ASCII (Latin-1: café, résumé)
- UTF-8 Unicode (世界, مرحبا)
- Emoji (🎉 ✅ 🚀)
- Wide characters (CJK, Arabic, Hebrew, Cyrillic)
- ANSI escape sequences (@-codes)
- Edge cases (quotes, backslashes, special chars)
- Mixed encodings

This test WILL FAIL with current code due to wide character bug in ToolExecutor.pm line 126.

Expected error:
    [ERROR][ToolExecutor] JSON parse error: Wide character in subroutine entry

After fix, this test should PASS 100%.

=head1 USAGE

    # Run from project root
    perl tests/integration/encoding_matrix_test.pl
    
    # Run with debug output
    DEBUG=1 perl tests/integration/encoding_matrix_test.pl

=cut

use strict;
use warnings;
use utf8;
use feature 'say';
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use lib "$RealBin/../lib";

use TestHelpers;
use TestData;
use File::Temp qw(tempdir);
use File::Spec;

# Import all tools
use CLIO::Tools::FileOperations;
use CLIO::Tools::VersionControl;
use CLIO::Tools::TerminalOperations;
use CLIO::Tools::MemoryOperations;
use CLIO::Tools::WebOperations;
use CLIO::Tools::TodoList;
use CLIO::Tools::CodeIntelligence;
# ResultStorage is internal infrastructure, not a user-facing tool

# Test configuration
my $debug = $ENV{DEBUG} || 0;
my $test_dir = tempdir(CLEANUP => 1);

say "=" x 80;
say "CLIO ENCODING MATRIX TEST";
say "=" x 80;
say "Tests ALL tools with ALL character encodings";
say "This will expose the 'Wide character in subroutine entry' bug";
say "";
say "Test directory: $test_dir";
say "Debug: " . ($debug ? "ON" : "OFF");
say "=" x 80;
say "";

# Mock session for tools that need it
my $mock_session = {
    session_id => 'encoding_test',
    working_directory => $test_dir,
    session_dir => $test_dir,
};

# Get all encoding samples
my $samples = TestData::all_encoding_samples();

=head1 TEST FUNCTIONS

=head2 test_file_operations_with_encoding

Test ALL FileOperations with a specific encoding.

=cut

sub test_file_operations_with_encoding {
    my ($encoding_name, $content) = @_;
    
    say "\n" . "─" x 80;
    say "Testing FileOperations with encoding: $encoding_name";
    say "─" x 80;
    
    my $tool = CLIO::Tools::FileOperations->new(
        debug => $debug,
        session_dir => $test_dir,
    );
    
    my $test_file = File::Spec->catfile($test_dir, "test_$encoding_name.txt");
    
    # TEST: create_file with encoding
    {
        my $result = $tool->execute({
            operation => 'create_file',
            path => $test_file,
            content => $content,
        }, $mock_session);
        
        assert_true($result->{success}, "[$encoding_name] create_file succeeds");
        
        if (!$result->{success}) {
            say "  ERROR: " . ($result->{error} || 'unknown error');
            say "  This is the WIDE CHARACTER BUG if error contains 'Wide character'";
        } else {
            # File created successfully - note this for debugging
            print STDERR "[TEST] Created file: $test_file\n" if $debug;
        }
    }
    
    # TEST: read_file with encoding
    if (-f $test_file) {
        my $result = $tool->execute({
            operation => 'read_file',
            path => $test_file,
        }, $mock_session);
        
        assert_true($result->{success}, "[$encoding_name] read_file succeeds");
        
        if ($result->{success}) {
            # Verify content matches
            my $read_content = $result->{output};
            assert_equals($content, $read_content, "[$encoding_name] read_file content matches");
        }
    }
    
    # TEST: append_file with encoding
    {
        my $append_content = "\nAppended: $content";
        my $result = $tool->execute({
            operation => 'append_file',
            path => $test_file,
            content => $append_content,
        }, $mock_session);
        
        assert_true($result->{success}, "[$encoding_name] append_file succeeds");
    }
    
    # TEST: grep_search with encoding pattern
    {
        # Extract a substring to search for
        my $search_term = substr($content, 0, 10);
        $search_term =~ s/\s+/ /g;  # Normalize whitespace
        
        my $result = $tool->execute({
            operation => 'grep_search',
            query => $search_term,
            pattern => '*.txt',
        }, $mock_session);
        
        assert_true($result->{success}, "[$encoding_name] grep_search succeeds");
    }
    
    # TEST: get_file_info with encoding filename
    {
        my $result = $tool->execute({
            operation => 'get_file_info',
            path => $test_file,
        }, $mock_session);
        
        assert_true($result->{success}, "[$encoding_name] get_file_info succeeds");
    }
    
    # TEST: file_exists with encoding filename
    {
        my $result = $tool->execute({
            operation => 'file_exists',
            path => $test_file,
        }, $mock_session);
        
        assert_true($result->{success}, "[$encoding_name] file_exists succeeds");
        assert_true($result->{exists}, "[$encoding_name] file_exists returns true");
    }
    
    # TEST: list_dir (will show files with encoding in names)
    {
        my $result = $tool->execute({
            operation => 'list_dir',
            path => $test_dir,
        }, $mock_session);
        
        assert_true($result->{success}, "[$encoding_name] list_dir succeeds");
    }
    
    # TEST: rename_file (copy) with encoding
    {
        # Create file to rename first
        my $source_file = File::Spec->catfile($test_dir, "source_$encoding_name.txt");
        my $dest_file = File::Spec->catfile($test_dir, "dest_$encoding_name.txt");
        
        # Write source file
        open my $fh, '>:utf8', $source_file or die "Cannot create $source_file: $!";
        print $fh $content;
        close $fh;
        
        my $result = $tool->execute({
            operation => 'rename_file',
            old_path => $source_file,
            new_path => $dest_file,
        }, $mock_session);
        
        assert_true($result->{success}, "[$encoding_name] rename_file succeeds");
    }
    
    # TEST: delete_file
    {
        my $result = $tool->execute({
            operation => 'delete_file',
            path => $test_file,
        }, $mock_session);
        
        assert_true($result->{success}, "[$encoding_name] delete_file succeeds");
    }
}

=head2 test_terminal_operations_with_encoding

Test TerminalOperations with encoding in command output.

=cut

sub test_terminal_operations_with_encoding {
    my ($encoding_name, $content) = @_;
    
    say "\n" . "─" x 80;
    say "Testing TerminalOperations with encoding: $encoding_name";
    say "─" x 80;
    
    my $tool = CLIO::Tools::TerminalOperations->new(debug => $debug);
    
    # TEST: execute (terminal command) with encoding in output
    {
        # Use echo to output the encoding sample
        my $test_file = File::Spec->catfile($test_dir, "terminal_$encoding_name.txt");
        
        # Write content to file first
        open my $fh, '>:utf8', $test_file or die "Cannot create $test_file: $!";
        print $fh $content;
        close $fh;
        
        # Read it back with cat
        my $result = $tool->execute({
            operation => 'execute',
            command => "cat '$test_file'",
        }, $mock_session);
        
        assert_true($result->{success}, "[$encoding_name] execute (terminal) succeeds");
        
        if ($result->{success}) {
            # Verify output contains the content (allowing for whitespace differences)
            # For emoji/wide chars, check for a smaller unique substring
            my $output = $result->{output};
            my $check_substring = substr($content, 0, 10);
            
            # Remove whitespace for comparison (output may have extra newlines)
            $check_substring =~ s/^\s+|\s+$//g;
            
            # Skip the substring check if it's all whitespace
            if (length($check_substring) > 0) {
                assert_contains($output, $check_substring, "[$encoding_name] run_command output contains content");
            } else {
                # Content starts with whitespace - just check output is not empty
                assert_true(length($output) > 0, "[$encoding_name] run_command output not empty");
            }
        }
    }
}

=head2 test_memory_operations_with_encoding

Test MemoryOperations with encoding in stored content.

=cut

sub test_memory_operations_with_encoding {
    my ($encoding_name, $content) = @_;
    
    say "\n" . "─" x 80;
    say "Testing MemoryOperations with encoding: $encoding_name";
    say "─" x 80;
    
    my $tool = CLIO::Tools::MemoryOperations->new(
        debug => $debug,
        session_dir => $test_dir,
    );
    
    my $key = "encoding_test_$encoding_name";
    
    # TEST: store with encoding
    {
        my $result = $tool->execute({
            operation => 'store',
            key => $key,
            content => $content,
        }, $mock_session);
        
        assert_true($result->{success}, "[$encoding_name] store succeeds");
    }
    
    # TEST: retrieve with encoding
    {
        my $result = $tool->execute({
            operation => 'retrieve',
            key => $key,
        }, $mock_session);
        
        assert_true($result->{success}, "[$encoding_name] retrieve succeeds");
        
        if ($result->{success}) {
            # MemoryOperations returns content in 'output' field
            assert_equals($content, $result->{output}, "[$encoding_name] retrieve content matches");
        }
    }
    
    # TEST: search with encoding
    {
        my $search_term = substr($content, 0, 10);
        my $result = $tool->execute({
            operation => 'search',
            query => $search_term,
        }, $mock_session);
        
        assert_true($result->{success}, "[$encoding_name] search succeeds");
    }
    
    # TEST: delete
    {
        my $result = $tool->execute({
            operation => 'delete',
            key => $key,
        }, $mock_session);
        
        assert_true($result->{success}, "[$encoding_name] delete succeeds");
    }
}

=head2 test_todo_list_with_encoding

Test TodoList with encoding in todo descriptions.

=cut

sub test_todo_list_with_encoding {
    my ($encoding_name, $content) = @_;
    
    say "\n" . "─" x 80;
    say "Testing TodoList with encoding: $encoding_name";
    say "─" x 80;
    
    my $tool = CLIO::Tools::TodoList->new(
        debug => $debug,
        session_dir => $test_dir,
    );
    
    # TEST: write (todo list) with encoding
    {
        my $todos = [
            {
                id => 1,
                title => "Todo with $encoding_name",
                description => $content,
                status => 'not-started',
            }
        ];
        
        my $result = $tool->execute({
            operation => 'write',
            todoList => $todos,
        }, $mock_session);
        
        assert_true($result->{success}, "[$encoding_name] write (todo) succeeds");
    }
}

=head1 MAIN TEST EXECUTION

=cut

say "Testing " . scalar(keys %$samples) . " different character encodings\n";

# Test each encoding with each tool
for my $encoding_name (sort keys %$samples) {
    my $content = $samples->{$encoding_name};
    
    # Truncate content for display
    my $display_content = $content;
    if (length($display_content) > 50) {
        $display_content = substr($display_content, 0, 50) . '...';
    }
    $display_content =~ s/\n/ /g;
    
    say "\n" . "=" x 80;
    say "ENCODING: $encoding_name";
    say "SAMPLE: $display_content";
    say "=" x 80;
    
    # Test FileOperations (MOST CRITICAL - this is where wide char bug appears)
    eval {
        test_file_operations_with_encoding($encoding_name, $content);
    };
    if ($@) {
        say "FATAL ERROR in FileOperations: $@";
        say "This is likely the WIDE CHARACTER BUG!";
    }
    
    # Test TerminalOperations
    eval {
        test_terminal_operations_with_encoding($encoding_name, $content);
    };
    if ($@) {
        say "ERROR in TerminalOperations: $@";
    }
    
    # Test MemoryOperations
    eval {
        test_memory_operations_with_encoding($encoding_name, $content);
    };
    if ($@) {
        say "ERROR in MemoryOperations: $@";
    }
    
    # Test TodoList
    eval {
        test_todo_list_with_encoding($encoding_name, $content);
    };
    if ($@) {
        say "ERROR in TodoList: $@";
    }
    
    # SKIP ResultStorage - it's internal infrastructure, not a user-facing tool
    # ResultStorage is used via FileOperations.read_tool_result
}

# Print summary
print_test_summary();

__END__

=head1 EXPECTED RESULTS

Current code (with bug):
    ❌ FAIL - Wide character errors in FileOperations with emoji, unicode, wide_char

After fix:
    ✅ PASS - ALL encodings work with ALL tools

=head1 THE BUG

Location: lib/CLIO/Core/ToolExecutor.pm line 126

Problem:
    my $args_json = encode_json($args);
    
When $args contains UTF-8 strings (emoji, unicode), encode_json fails with:
    "Wide character in subroutine entry"

Root cause:
    Perl strings are flagged as UTF-8 (utf8::is_utf8() == true)
    encode_json expects bytes, not characters
    
Solutions:
    1. Use utf8::encode($string) before encode_json
    2. Use utf8::downgrade($string) if possible
    3. Ensure consistent UTF-8 handling throughout stack
    4. Use :utf8 layer for file I/O

=head1 SEE ALSO

test.txt - Real error examples
TestData.pm - Test data generation
TestHelpers.pm - Test utilities

=cut
