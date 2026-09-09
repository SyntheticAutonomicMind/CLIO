#!/usr/bin/env perl
# Test: Working directory included in session context
#
# Asserts the working directory is included in the user context string
# built by CLIO::Core::PromptBuilder::get_user_context(). The PWD is
# the lead field so the model anchors to it when resolving relative
# paths.

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

# Use the live PromptBuilder::get_user_context() path — the production
# source for environment info (CWD, Date, Lang). Environment rendering
# was consolidated here from ContextBuilder::_build_environment_hash
# and MessageHistory::messages_to_prose_dynamic.
require CLIO::Core::PromptBuilder;

my $pb = CLIO::Core::PromptBuilder->new();
my $section = $pb->get_user_context();

ok(defined $section && length($section), "Generated user context section");

if ($section) {
    ok($section =~ /CWD:/, "Section includes 'CWD:'");
    ok($section =~ /\Q$current_pwd\E/, "Section includes actual PWD: $current_pwd");
    ok($section =~ /Date:/, "Section includes Date:");
    ok($section =~ /Lang:/, "Section includes language");
    unlike($section, qr/sessionContext/, "No <sessionContext> XML tag (prose format)");

    print "# Sample from section:\n";
    for my $line (grep { defined $_ && /CWD|Date|Lang/ } (split /\n/, $section)[0..5]) {
        print "#   $line\n";
    }
} else {
    fail("No section content");
    fail("No PWD found");
}

# Cleanup
chdir($orig_dir);

print "# Test complete: PWD is included in user context\n";
done_testing();
