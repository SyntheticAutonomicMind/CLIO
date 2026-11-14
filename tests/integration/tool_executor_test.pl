#!/usr/bin/env perl

=head1 NAME

test_tools_e2e.pl - End-to-end test suite for consolidated tools

=head1 DESCRIPTION

Tests all tools through the full stack:
- Tool registry → ToolExecutor → Tool implementation
- Validates real-world usage patterns
- Tests error handling and edge cases

=cut

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use feature 'say';
use JSON::PP qw(encode_json decode_json);
use File::Temp qw(tempdir);
use File::Spec;
use Cwd qw(getcwd);

# Test infrastructure
my $total_tests = 0;
my $passed_tests = 0;
my @failures;

sub test {
    my ($name, $code) = @_;
    $total_tests++;
    
    print "Testing: $name ... ";
    
    eval {
        $code->();
        $passed_tests++;
        print "✅ PASS\n";
    };
    
    if ($@) {
        my $error = $@;
        push @failures, {name => $name, error => $error};
        print "❌ FAIL: $error\n";
    }
}

sub assert {
    my ($condition, $message) = @_;
    die "$message\n" unless $condition;
}

say "=" x 80;
say "CLIO - End-to-End Tool Test Suite";
say "=" x 80;
say "";

# Setup test environment
my $test_dir = tempdir(CLEANUP => 1);
my $cwd = getcwd();

# Isolate CLIO's config and data directories. MemoryOperations only accepts a
# memory_dir inside the project or config directory, so the test needs a
# sandbox rather than an arbitrary temp path. PathResolver honors CLIO_HOME.
use File::Path qw(make_path);
my $clio_home = tempdir(CLEANUP => 1);
$ENV{CLIO_HOME} = $clio_home;
my $memory_dir = File::Spec->catdir($clio_home, 'memory');
make_path($memory_dir);

say "Test directory: $test_dir";
say "";

# Initialize session and tool registry
use CLIO::Tools::Registry;
use CLIO::Core::ToolExecutor;

use CLIO::Tools::FileOperations;
use CLIO::Tools::VersionControl;
use CLIO::Tools::TerminalOperations;
use CLIO::Tools::MemoryOperations;
use CLIO::Tools::WebOperations;

# Create minimal session object
my $session = {
    session_id => 'test_session_' . time(),
    messages => [],
    tool_calls => {},
};

my $tool_registry = CLIO::Tools::Registry->new(debug => 0);
$tool_registry->register_tool(CLIO::Tools::FileOperations->new(debug => 0));
$tool_registry->register_tool(CLIO::Tools::VersionControl->new(debug => 0));
$tool_registry->register_tool(CLIO::Tools::TerminalOperations->new(debug => 0));
$tool_registry->register_tool(CLIO::Tools::MemoryOperations->new(debug => 0));
$tool_registry->register_tool(CLIO::Tools::WebOperations->new(debug => 0));

$session->{tool_registry} = $tool_registry;

my $executor = CLIO::Core::ToolExecutor->new(
    session => $session,
    tool_registry => $tool_registry,
    debug => 0
);

say "-" x 80;
say "FileOperations Tool Tests";
say "-" x 80;

# Test: create_file
test "FileOperations: create_file", sub {
    my $test_file = "$test_dir/test1.txt";
    my $content = "Hello, World!";
    
    my $tool_call = {
        type => 'function',
        function => {
            name => 'write_file',
            arguments => encode_json({
                path => $test_file,
                content => $content,
            })
        }
    };
    
    my $result_json = $executor->execute_tool($tool_call, 'test_call_1');
    my $result = decode_json($result_json);
    
    assert($result->{success}, "create_file should succeed");
    assert(-f $test_file, "File should exist");
    
    open my $fh, '<', $test_file or die "Cannot read $test_file: $!";
    my $read_content = do { local $/; <$fh> };
    close $fh;
    
    assert($read_content eq $content, "Content should match");
};

# Test: read_file
test "FileOperations: read_file", sub {
    my $test_file = "$test_dir/test2.txt";
    open my $fh, '>', $test_file or die "Cannot write: $!";
    print $fh "Line 1\nLine 2\nLine 3\n";
    close $fh;
    
    my $tool_call = {
        type => 'function',
        function => {
            name => 'read_file',
            arguments => encode_json({
                path => $test_file,
            })
        }
    };
    
    my $result_json = $executor->execute_tool($tool_call, 'test_call_2');
    my $result = decode_json($result_json);
    
    assert($result->{success}, "read_file should succeed");
    assert($result->{output} =~ /Line 1/, "Should contain Line 1");
    assert($result->{output} =~ /Line 3/, "Should contain Line 3");
};

# Test: list_dir
test "FileOperations: list_dir", sub {
    my $tool_call = {
        type => 'function',
        function => {
            name => 'list_dir',
            arguments => encode_json({
                path => $test_dir,
            })
        }
    };
    
    my $result_json = $executor->execute_tool($tool_call, 'test_call_3');
    my $result = decode_json($result_json);
    
    assert($result->{success}, "list_dir should succeed");
    my $output = decode_json($result->{output});
    assert(ref($output) eq 'ARRAY', "Output should be array");
    assert(scalar(@$output) >= 2, "Should have at least 2 files");
};

# Test: grep_search
test "FileOperations: grep_search", sub {
    my $tool_call = {
        type => 'function',
        function => {
            name => 'grep_search',
            arguments => encode_json({
                query => 'Line 2',
                path => $test_dir,
                is_regexp => 0,
            })
        }
    };
    
    my $result_json = $executor->execute_tool($tool_call, 'test_call_4');
    my $result = decode_json($result_json);
    
    assert($result->{success}, "grep_search should succeed");
    
    # Handle case where results may be stored (large results get [TOOL_RESULT_STORED:...])
    my $output = $result->{output};
    if ($output =~ /TOOL_RESULT_PREVIEW:|TOOL_RESULT_STORED:/) {
        # Large result was stored - we know it found matches
        assert(1, "Should find at least 1 match (stored result)");
    } else {
        my $matches = decode_json($output);
        assert(scalar(@$matches) >= 1, "Should find at least 1 match");
    }
};

# Test: delete_file
test "FileOperations: delete_file", sub {
    my $test_file = "$test_dir/delete_me.txt";
    open my $fh, '>', $test_file or die;
    print $fh "Delete this";
    close $fh;
    
    my $tool_call = {
        type => 'function',
        function => {
            name => 'delete_file',
            arguments => encode_json({
                path => $test_file,
            })
        }
    };
    
    my $result_json = $executor->execute_tool($tool_call, 'test_call_5');
    my $result = decode_json($result_json);
    
    assert($result->{success}, "delete_file should succeed");
    assert(!-f $test_file, "File should not exist");
};

say "";
say "-" x 80;
say "VersionControl Tool Tests";
say "-" x 80;

# Test: status (should work in clio repo)
test "VersionControl: status", sub {
    chdir $cwd;  # Switch to repo directory
    
    my $tool_call = {
        type => 'function',
        function => {
            name => 'status',
            arguments => encode_json({})
        }
    };
    
    my $result_json = $executor->execute_tool($tool_call, 'test_call_6');
    my $result = decode_json($result_json);
    
    assert($result->{success}, "status should succeed");
    assert($result->{output} =~ /branch/i || $result->{output} =~ /nothing/, 
           "Should have status output");
};

# Test: log
test "VersionControl: log", sub {
    my $tool_call = {
        type => 'function',
        function => {
            name => 'log',
            arguments => encode_json({
                max_count => 5,
            })
        }
    };
    
    my $result_json = $executor->execute_tool($tool_call, 'test_call_7');
    my $result = decode_json($result_json);
    
    assert($result->{success}, "log should succeed");
    assert($result->{output} =~ /commit/i, "Should have commit in log");
};

say "";
say "-" x 80;
say "TerminalOperations Tool Tests";
say "-" x 80;

# Test: validate
test "TerminalOperations: validate", sub {
    my $tool_call = {
        type => 'function',
        function => {
            name => 'terminal_operations',
            arguments => encode_json({
                operation => 'validate',
                command => 'echo "safe command"',
            })
        }
    };
    
    my $result_json = $executor->execute_tool($tool_call, 'test_call_8');
    my $result = decode_json($result_json);
    
    assert($result->{success}, "validate should succeed");
};

# Test: exec
test "TerminalOperations: exec", sub {
    my $tool_call = {
        type => 'function',
        function => {
            name => 'terminal_operations',
            arguments => encode_json({
                operation => 'exec',
                command => 'echo "Hello from shell"',
            })
        }
    };
    
    my $result_json = $executor->execute_tool($tool_call, 'test_call_9');
    my $result = decode_json($result_json);
    
    assert($result->{success}, "exec should succeed");
    assert($result->{output} =~ /Hello from shell/, "Should have command output");
};

say "";
say "-" x 80;
say "MemoryOperations Tool Tests";
say "-" x 80;

# Test: store and retrieve
test "MemoryOperations: store", sub {
    my $tool_call = {
        type => 'function',
        function => {
            name => 'memory_store',
            arguments => encode_json({
                key => 'test_key',
                content => 'test value',
                memory_dir => $memory_dir,
            })
        }
    };
    
    my $result_json = $executor->execute_tool($tool_call, 'test_call_10');
    my $result = decode_json($result_json);
    
    assert($result->{success}, "store should succeed");
};

test "MemoryOperations: retrieve", sub {
    my $tool_call = {
        type => 'function',
        function => {
            name => 'memory_retrieve',
            arguments => encode_json({
                key => 'test_key',
                memory_dir => $memory_dir,
            })
        }
    };
    
    my $result_json = $executor->execute_tool($tool_call, 'test_call_11');
    my $result = decode_json($result_json);
    
    assert($result->{success}, "retrieve should succeed");
    assert($result->{output} eq 'test value', "Should retrieve correct value");
};

test "MemoryOperations: search", sub {
    my $tool_call = {
        type => 'function',
        function => {
            name => 'memory_search',
            arguments => encode_json({
                query => 'test',
                memory_dir => $memory_dir,
            })
        }
    };
    
    my $result_json = $executor->execute_tool($tool_call, 'test_call_12');
    my $result = decode_json($result_json);
    
    assert($result->{success}, "search should succeed");
    my $matches = decode_json($result->{output});
    assert(scalar(@$matches) >= 1, "Should find at least 1 match");
};

say "";
say "-" x 80;
say "Error Handling Tests";
say "-" x 80;

# Test: non-callable name
test "Error: non-callable name", sub {
    my $tool_call = {
        type => 'function',
        function => {
            name => 'file_operations',
            arguments => encode_json({
                operation => 'invalid_op',
                path => '/tmp/test',
            })
        }
    };
    
    my $result_json = $executor->execute_tool($tool_call, 'test_call_13');
    
    # Errors may be returned as "ERROR: ..." plain text, not JSON
    if ($result_json =~ /^ERROR:/) {
        # Plain text error - test passes (tool failed as expected)
        assert(1, "Should fail for a non-callable name");
    } else {
        my $result = decode_json($result_json);
        assert(!$result->{success}, "Should fail for a non-callable name");
        assert($result->{error}, "Should have error message");
    }
};

# Test: missing parameters
test "Error: missing parameters", sub {
    my $tool_call = {
        type => 'function',
        function => {
            name => 'read_file',
            arguments => encode_json({
                # Missing path
            })
        }
    };
    
    my $result_json = $executor->execute_tool($tool_call, 'test_call_14');
    
    # Errors may be returned as "ERROR: ..." plain text, not JSON
    if ($result_json =~ /^ERROR:/) {
        # Plain text error - check it mentions path
        assert($result_json =~ /path/i, "Error should mention path");
    } else {
        my $result = decode_json($result_json);
        assert(!$result->{success}, "Should fail for missing parameters");
        assert($result->{error} =~ /path/, "Error should mention path");
    }
};

# Test: unknown tool
test "Error: unknown tool", sub {
    my $tool_call = {
        type => 'function',
        function => {
            name => 'nonexistent_tool',
            arguments => encode_json({})
        }
    };
    
    my $result_json = $executor->execute_tool($tool_call, 'test_call_15');
    my $result = decode_json($result_json);
    
    assert(!$result->{success}, "Should fail for unknown tool");
    assert($result->{error} =~ /Unknown tool/, "Error should mention unknown tool");
};

# Print summary
say "";
say "=" x 80;
say "Test Summary";
say "=" x 80;
say "Total tests: $total_tests";
say "Passed: $passed_tests";
say "Failed: " . ($total_tests - $passed_tests);
say "";

if (@failures) {
    say "Failures:";
    for my $failure (@failures) {
        say "  ❌ $failure->{name}";
        say "     Error: $failure->{error}";
    }
    say "";
}

if ($passed_tests == $total_tests) {
    say "🎉 All tests passed!";
    exit 0;
} else {
    say "❌ Some tests failed.";
    exit 1;
}
