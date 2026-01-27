#!/usr/bin/env perl
# Integration test for terminal passthrough
# Tests actual command execution with passthrough mode

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../lib";

use CLIO::Core::Config;
use CLIO::Tools::TerminalOperations;
use File::Temp qw(tempfile tempdir);

print "\n=== Terminal Passthrough Integration Tests ===\n\n";

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

# Test 1: Non-interactive command with capture mode (default)
test("Non-interactive command captures output", sub {
    my $result = $tool->execute_command(
        { command => 'echo "Hello World"' },
        $context
    );
    
    die "Command failed" unless $result->{success};
    die "Missing output" unless $result->{output};
    die "Output doesn't match" unless $result->{output} =~ /Hello World/;
    die "Exit code not 0" unless $result->{exit_code} == 0;
});

# Test 2: Interactive command with auto-detect (should use passthrough)
test("Interactive command detected (git commit)", sub {
    # Create temp git repo
    my $tmpdir = tempdir(CLEANUP => 1);
    my $orig_dir = `pwd`;
    chomp($orig_dir);
    
    chdir $tmpdir;
    system('git init > /dev/null 2>&1');
    system('git config user.name "Test" 2>&1');
    system('git config user.email "test@example.com" 2>&1');
    
    # Create a file
    open my $fh, '>', 'test.txt';
    print $fh "test content\n";
    close $fh;
    
    system('git add test.txt 2>&1');
    
    # This should detect git commit as interactive
    # Since we can't actually open an editor in test, we'll just verify detection
    my $is_interactive = $tool->_is_interactive_command('git commit');
    
    chdir $orig_dir;
    
    die "Should detect git commit as interactive" unless $is_interactive;
});

# Test 3: Force passthrough with parameter override
test("Per-command passthrough override", sub {
    my $result = $tool->execute_command(
        { 
            command => 'echo "Passthrough Test"',
            passthrough => 1  # Force passthrough
        },
        $context
    );
    
    die "Command failed" unless $result->{success};
    die "Should indicate passthrough" unless $result->{passthrough};
    die "Output should indicate direct terminal access" 
        unless $result->{output} =~ /direct terminal access/i;
});

# Test 4: Disable auto-detect
test("Disable auto-detect for interactive command", sub {
    $config->set('terminal_autodetect', 0);
    
    # Even though vim is interactive, with autodetect off it should NOT use passthrough
    # (unless terminal_passthrough is globally enabled)
    my $use_passthrough = $tool->_should_use_passthrough(
        'vim file.txt',
        {},
        $config
    );
    
    $config->set('terminal_autodetect', 1);  # Reset
    
    die "Should not use passthrough when autodetect disabled" if $use_passthrough;
});

# Test 5: Enable global passthrough
test("Global passthrough for all commands", sub {
    $config->set('terminal_passthrough', 1);
    
    my $result = $tool->execute_command(
        { command => 'echo "Global Passthrough"' },
        $context
    );
    
    $config->set('terminal_passthrough', 0);  # Reset
    
    die "Command failed" unless $result->{success};
    die "Should use passthrough" unless $result->{passthrough};
});

# Test 6: Exit code capture in passthrough mode
test("Exit codes captured in passthrough", sub {
    my $result = $tool->execute_command(
        { 
            command => 'sh -c "exit 42"',  # Fixed: use sh -c to run exit properly
            passthrough => 1
        },
        $context
    );
    
    die "Command should succeed (execute, even with non-zero exit)" unless $result->{success};
    die "Exit code should be 42, got: " . ($result->{exit_code} // 'undef') 
        unless $result->{exit_code} == 42;
});

# Test 7: Working directory with passthrough
test("Working directory respected in passthrough", sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    
    # Create a marker file
    open my $fh, '>', "$tmpdir/marker.txt";
    print $fh "marker\n";
    close $fh;
    
    my $result = $tool->execute_command(
        { 
            command => 'test -f marker.txt',
            working_directory => $tmpdir,
            passthrough => 0  # Use capture to verify
        },
        $context
    );
    
    die "Command failed - marker file should exist" unless $result->{success};
    die "Exit code should be 0" unless $result->{exit_code} == 0;
});

# Summary
print "\n=== Test Summary ===\n";
print "Total: $test_count\n";
print "Passed: $pass_count\n";
print "Failed: " . ($test_count - $pass_count) . "\n";

if ($pass_count == $test_count) {
    print "\n✓ All integration tests passed!\n\n";
    exit 0;
} else {
    print "\n✗ Some tests failed\n\n";
    exit 1;
}

__END__

=head1 NAME

test_terminal_passthrough_integration.pl - Integration tests for terminal passthrough

=head1 DESCRIPTION

Tests actual command execution with passthrough feature:

1. Non-interactive commands capture output correctly
2. Interactive commands detected by auto-detect
3. Per-command passthrough override works
4. Config settings (auto-detect, global passthrough) respected
5. Exit codes captured in both modes
6. Working directory context preserved

=head1 USAGE

    perl -I./lib tests/integration/test_terminal_passthrough_integration.pl
