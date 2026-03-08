#!/usr/bin/env perl
# Integration test for terminal operations
# Tests actual command execution with passthrough mode

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../lib";

use CLIO::Core::Config;
use CLIO::Tools::TerminalOperations;
use File::Temp qw(tempfile tempdir);

print "\n=== Terminal Operations Integration Tests ===\n\n";

my $test_count = 0;
my $pass_count = 0;

sub test {
    my ($name, $coderef) = @_;
    $test_count++;
    print "Test $test_count: $name... ";
    eval {
        $coderef->();
        $pass_count++;
        print "PASS\n";
    };
    if ($@) {
        print "FAIL\n";
        print "  Error: $@\n";
    }
}

# Setup
my $config = CLIO::Core::Config->new();
my $tool = CLIO::Tools::TerminalOperations->new();
my $context = { config => $config };

# Test 1: Simple command captures output
test("Simple command captures output", sub {
    my $result = $tool->execute_command(
        { command => 'echo "Hello World"' },
        $context
    );
    
    die "Command failed" unless $result->{success};
    die "Missing output" unless $result->{output};
    die "Output doesn't match" unless $result->{output} =~ /Hello World/;
    die "Exit code not 0" unless $result->{exit_code} == 0;
});

# Test 2: All commands use passthrough mode
test("All commands use passthrough mode", sub {
    my $result = $tool->execute_command(
        { command => 'echo "passthrough check"' },
        $context
    );
    
    die "Command failed" unless $result->{success};
    die "Should indicate passthrough" unless $result->{passthrough};
});

# Test 3: Pre-action description populated
test("Pre-action description is set", sub {
    my $result = $tool->execute_command(
        { command => 'echo "pre-action check"' },
        $context
    );
    
    die "Command failed" unless $result->{success};
    die "Missing pre_action_description" unless $result->{pre_action_description};
    die "pre_action_description should contain command" 
        unless $result->{pre_action_description} =~ /echo/;
});

# Test 4: Exit code capture
test("Non-zero exit codes captured", sub {
    my $result = $tool->execute_command(
        { command => 'sh -c "exit 42"' },
        $context
    );
    
    die "Command should succeed (execute, even with non-zero exit)" unless $result->{success};
    die "Exit code should be 42, got: " . ($result->{exit_code} // 'undef') 
        unless $result->{exit_code} == 42;
});

# Test 5: Working directory respected
test("Working directory respected", sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    
    # Create a marker file
    open my $fh, '>', "$tmpdir/marker.txt";
    print $fh "marker\n";
    close $fh;
    
    my $result = $tool->execute_command(
        { 
            command => 'test -f marker.txt && echo "found"',
            working_directory => $tmpdir,
        },
        $context
    );
    
    die "Command failed" unless $result->{success};
    die "Exit code should be 0" unless $result->{exit_code} == 0;
    die "Should find marker file" unless $result->{output} =~ /found/;
});

# Test 6: Multi-line output captured
test("Multi-line output captured correctly", sub {
    my $result = $tool->execute_command(
        { command => 'echo "line1"; echo "line2"; echo "line3"' },
        $context
    );
    
    die "Command failed" unless $result->{success};
    die "Missing line1" unless $result->{output} =~ /line1/;
    die "Missing line2" unless $result->{output} =~ /line2/;
    die "Missing line3" unless $result->{output} =~ /line3/;
});

# Test 7: Action description format
test("Action description shows result status", sub {
    my $result = $tool->execute_command(
        { command => 'echo "test"' },
        $context
    );
    
    die "Command failed" unless $result->{success};
    die "action_description should indicate success" 
        unless $result->{action_description} =~ /success/;
});

# Test 8: Multiplexer detection (should be available or not - either is fine)
test("Multiplexer detection doesn't crash", sub {
    my $mux = $tool->_get_multiplexer($context);
    # mux can be undef or an object - both are fine
    # Just verify it doesn't crash
    1;
});

# Summary
print "\n=== Test Summary ===\n";
print "Total: $test_count\n";
print "Passed: $pass_count\n";
print "Failed: " . ($test_count - $pass_count) . "\n";

if ($pass_count == $test_count) {
    print "\n All integration tests passed!\n\n";
    exit 0;
} else {
    print "\n Some tests failed\n\n";
    exit 1;
}

__END__

=head1 NAME

test_terminal_passthrough_integration.pl - Integration tests for terminal operations

=head1 DESCRIPTION

Tests actual command execution:

1. Output capture works
2. All commands use passthrough mode
3. Pre-action description populated
4. Exit codes captured
5. Working directory respected
6. Multi-line output captured
7. Action description format correct
8. Multiplexer detection doesn't crash

=head1 USAGE

    perl -I./lib tests/integration/test_terminal_passthrough_integration.pl

=cut
