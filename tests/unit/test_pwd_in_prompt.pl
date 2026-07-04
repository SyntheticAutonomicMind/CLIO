#!/usr/bin/env perl
# Test: Working directory included in system prompt
# Bug: Agents hallucinated paths like /Users/andy/ because they didn't know PWD
# Fix: Added current working directory to system prompt

use strict;
use warnings;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use Test::More;
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
require CLIO::Core::PromptBuilder;

# Create PromptBuilder for testing the datetime section
my $builder = CLIO::Core::PromptBuilder->new(debug => 0);
my $section = eval { $builder->get_user_context() };

ok(defined $section, "Generated user context section");

if ($section) {
    ok($section =~ /Working Directory/i, "Section includes 'Working Directory' heading");
    ok($section =~ /\Q$current_pwd\E/, "Section includes actual PWD: $current_pwd");
    ok($section =~ /userContext/i, "Section includes userContext block");

    print "# Sample from section:\n";
    my @lines = split /\n/, $section;
    for my $line (grep { /Working Directory|userContext|Language/ } @lines[0..15]) {
        print "#   $line\n";
    }
} else {
    fail("Could not generate section: $@");
    fail("No section content");
    fail("No PWD found");
    fail("No userContext found");
}

# Cleanup
chdir($orig_dir);

print "# Test complete: PWD is included in user context\n";
done_testing();
