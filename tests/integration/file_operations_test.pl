#!/usr/bin/env perl

use strict;
use warnings;
use lib 'lib';
use CLIO::Tools::FileOperations;
use File::Temp qw(tempdir);
use File::Spec;

print "="x60, "\n";
print "FileOperations Tool Test Suite\n";
print "="x60, "\n\n";

# Create temporary directory for testing
my $test_dir = tempdir(CLEANUP => 1);
print "Test directory: $test_dir\n\n";

# Initialize tool
my $tool = CLIO::Tools::FileOperations->new(
    debug => 1,
    session_dir => $test_dir
);

my $tests_passed = 0;
my $tests_failed = 0;

sub run_test {
    my ($name, $operation, $params, $expected_success, $check_output) = @_;
    
    print "-"x60, "\n";
    print "TEST: $name\n";
    print "-"x60, "\n";
    
    my $result = $tool->execute($params, { session => { id => 'test' } });
    
    if ($result->{success} == $expected_success) {
        if (!$check_output || $check_output->($result)) {
            print "✅ PASS\n\n";
            $tests_passed++;
            return 1;
        } else {
            print "❌ FAIL: Output validation failed\n";
            print "Error: ", $result->{error} || 'N/A', "\n";
            print "Output: ", ref($result->{output}) ? _dump($result->{output}) : $result->{output}, "\n\n";
            $tests_failed++;
            return 0;
        }
    } else {
        print "❌ FAIL: Expected success=$expected_success, got $result->{success}\n";
        print "Error: ", $result->{error} || 'N/A', "\n";
        print "Output: ", ref($result->{output}) ? _dump($result->{output}) : $result->{output}, "\n\n";
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
    return Data::Dumper::Dumper($data);
}

# Test 1: Create file
my $test_file = File::Spec->catfile($test_dir, 'test.txt');
run_test(
    "create_file - Create new file",
    'create_file',
    { operation => 'create_file', path => $test_file, content => "Hello, World!\nLine 2\nLine 3\n" },
    1,  # Should succeed
    sub { -f $test_file }
);

# Test 2: Read file
run_test(
    "read_file - Read entire file",
    'read_file',
    { operation => 'read_file', path => $test_file },
    1,
    sub { $_[0]->{output} =~ /Hello, World!/ }
);

# Test 3: Read file with line range
run_test(
    "read_file - Read specific line range",
    'read_file',
    { operation => 'read_file', path => $test_file, start_line => 2, end_line => 2 },
    1,
    sub { $_[0]->{output} eq "Line 2\n" && $_[0]->{lines_read} == 1 }
);

# Test 4: File exists (existing file)
run_test(
    "file_exists - Check existing file",
    'file_exists',
    { operation => 'file_exists', path => $test_file },
    1,
    sub { $_[0]->{output} == 1 && $_[0]->{type} eq 'file' }
);

# Test 5: File exists (non-existing file)
run_test(
    "file_exists - Check non-existing file",
    'file_exists',
    { operation => 'file_exists', path => '/nonexistent/file.txt' },
    1,
    sub { $_[0]->{output} == 0 }
);

# Test 6: Get file info
run_test(
    "get_file_info - Get metadata",
    'get_file_info',
    { operation => 'get_file_info', path => $test_file },
    1,
    sub { 
        my $info = $_[0]->{output};
        return $info->{type} eq 'file' && $info->{size} > 0;
    }
);

# Test 7: Append to file
run_test(
    "append_file - Append content",
    'append_file',
    { operation => 'append_file', path => $test_file, content => "Line 4\n" },
    1,
    sub { 1 }
);

# Verify append worked
my $read_result = $tool->execute(
    { operation => 'read_file', path => $test_file },
    { session => { id => 'test' } }
);
if ($read_result->{output} =~ /Line 4/) {
    print "✅ VERIFY: Append successful\n\n";
} else {
    print "❌ VERIFY: Append failed\n\n";
    $tests_failed++;
}

# Test 8: Replace string
run_test(
    "replace_string - Find and replace",
    'replace_string',
    { operation => 'replace_string', path => $test_file, old_string => 'World', new_string => 'Perl' },
    1,
    sub { $_[0]->{replacements} == 1 }
);

# Verify replacement worked
$read_result = $tool->execute(
    { operation => 'read_file', path => $test_file },
    { session => { id => 'test' } }
);
if ($read_result->{output} =~ /Hello, Perl!/) {
    print "✅ VERIFY: Replace successful\n\n";
} else {
    print "❌ VERIFY: Replace failed\n\n";
    $tests_failed++;
}

# Test 9: Create directory
my $test_subdir = File::Spec->catdir($test_dir, 'subdir', 'nested');
run_test(
    "create_directory - Create nested directory",
    'create_directory',
    { operation => 'create_directory', path => $test_subdir },
    1,
    sub { -d $test_subdir }
);

# Test 10: List directory (non-recursive)
run_test(
    "list_dir - List directory non-recursive",
    'list_dir',
    { operation => 'list_dir', path => $test_dir, recursive => 0 },
    1,
    sub { 
        my $entries = $_[0]->{output};
        return ref($entries) eq 'ARRAY' && @$entries > 0;
    }
);

# Test 11: List directory (recursive)
run_test(
    "list_dir - List directory recursive",
    'list_dir',
    { operation => 'list_dir', path => $test_dir, recursive => 1 },
    1,
    sub {
        my $entries = $_[0]->{output};
        return ref($entries) eq 'ARRAY' && @$entries > 0;
    }
);

# Test 12: Create file in subdirectory
my $test_file2 = File::Spec->catfile($test_subdir, 'nested.txt');
run_test(
    "create_file - Create in nested directory",
    'create_file',
    { operation => 'create_file', path => $test_file2, content => "Nested file content\n" },
    1,
    sub { -f $test_file2 }
);

# Test 13: File search
run_test(
    "file_search - Find files by pattern",
    'file_search',
    { operation => 'file_search', pattern => '*.txt', directory => $test_dir },
    1,
    sub {
        my $matches = $_[0]->{output};
        return ref($matches) eq 'ARRAY' && @$matches >= 2;  # Should find both test files
    }
);

# Test 14: Grep search
run_test(
    "grep_search - Search file contents",
    'grep_search',
    { operation => 'grep_search', query => 'Perl', pattern => '**/*.txt' },
    1,
    sub {
        my $matches = $_[0]->{output};
        return ref($matches) eq 'ARRAY' && @$matches >= 1;  # Should find "Perl" in test.txt
    }
);

# Test 15: Rename file
my $renamed_file = File::Spec->catfile($test_dir, 'renamed.txt');
run_test(
    "rename_file - Rename file",
    'rename_file',
    { operation => 'rename_file', old_path => $test_file, new_path => $renamed_file },
    1,
    sub { -f $renamed_file && !-f $test_file }
);

# Test 16: Delete file
run_test(
    "delete_file - Delete file",
    'delete_file',
    { operation => 'delete_file', path => $renamed_file },
    1,
    sub { !-f $renamed_file }
);

# Test 17: Delete directory (recursive)
run_test(
    "delete_file - Delete directory recursively",
    'delete_file',
    { operation => 'delete_file', path => $test_subdir, recursive => 1 },
    1,
    sub { !-d $test_subdir }
);

# Test 18: Error handling - Missing parameter
run_test(
    "ERROR: Missing path parameter",
    'read_file',
    { operation => 'read_file' },  # Missing 'path'
    0,  # Should fail
    sub { $_[0]->{error} =~ /Missing 'path'/ }
);

# Test 19: Error handling - Invalid operation
run_test(
    "ERROR: Invalid operation",
    'invalid_op',
    { operation => 'invalid_operation', path => '/tmp/test' },
    0,  # Should fail
    sub { $_[0]->{error} =~ /Unknown operation/ }
);

# Test 20: Error handling - File not found
run_test(
    "ERROR: File not found",
    'read_file',
    { operation => 'read_file', path => '/nonexistent/file.txt' },
    0,  # Should fail
    sub { $_[0]->{error} =~ /not found/ }
);

# Summary
print "="x60, "\n";
print "TEST SUMMARY\n";
print "="x60, "\n";
print "✅ Passed: $tests_passed\n";
print "❌ Failed: $tests_failed\n";
print "Total: ", $tests_passed + $tests_failed, "\n";

if ($tests_failed == 0) {
    print "\n🎉 ALL TESTS PASSED!\n\n";
    exit 0;
} else {
    print "\n⚠️  SOME TESTS FAILED\n\n";
    exit 1;
}
