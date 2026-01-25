#!/usr/bin/env perl
# Test: Working directory included in system prompt
# Bug: Agents hallucinated paths like /Users/andy/ because they didn't know PWD
# Fix: Added current working directory to system prompt

use strict;
use warnings;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use Test::More tests => 4;
use File::Temp qw(tempdir);
use Cwd qw(getcwd abs_path);

print "# Test: Working directory in system prompt\n";

# Save original directory
my $orig_dir = getcwd();

# Create test directory
my $test_dir = tempdir(CLEANUP => 1);
chdir($test_dir) or die "Cannot chdir: $!";
mkdir('.clio') or warn "mkdir .clio: $!";

my $current_pwd = getcwd();
print "# Test directory: $current_pwd\n";

# Load required modules
require CLIO::Core::WorkflowOrchestrator;

# Create minimal object just for testing the method
my $minimal = bless {debug => 0}, 'CLIO::Core::WorkflowOrchestrator';
my $section = eval { $minimal->_generate_datetime_section() };

ok(defined $section, "Generated datetime section");

if ($section) {
    ok($section =~ /Working Directory/i, "Section includes 'Working Directory' heading");
    ok($section =~ /\Q$current_pwd\E/, "Section includes actual PWD: $current_pwd");
    ok($section =~ /CRITICAL PATH RULES/i, "Section includes path usage rules");
    
    print "# Sample from section:\n";
    my @lines = split /\n/, $section;
    for my $line (grep { /Working Directory|CRITICAL|pwd/ } @lines[0..15]) {
        print "#   $line\n";
    }
} else {
    fail("Could not generate section: $@");
    fail("No section content");
    fail("No PWD found");
    fail("No path rules found");
}

# Cleanup
chdir($orig_dir);

print "# Test complete: PWD is included in system prompt\n";
done_testing();
