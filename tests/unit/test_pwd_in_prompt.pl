#!/usr/bin/env perl
# Test: Working directory included in session context
#
# Asserts the working directory is included in the <sessionContext>
# block built by CLIO::Core::PromptBuilder. The PWD is the lead field
# so the model anchors to it when resolving relative paths.

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
    ok($section =~ /sessionContext/i, "Section wrapped in <sessionContext>");

    print "# Sample from section:\n";
    my @lines = split /\n/, $section;
    # grep against @lines[0..15] - some entries are undef when the section
    # has fewer than 16 lines (e.g. the 5-line sessionContext in the fixture).
    # Default to '' so the regex doesn't fire on undef under `perl -W`.
    for my $line (grep { defined $_ && /Working Directory|sessionContext|Language/ } @lines[0..15]) {
        print "#   $line\n";
    }
} else {
    fail("Could not generate section: $@");
    fail("No section content");
    fail("No PWD found");
    fail("No sessionContext found");
}

# Cleanup
chdir($orig_dir);

print "# Test complete: PWD is included in user context\n";
done_testing();
