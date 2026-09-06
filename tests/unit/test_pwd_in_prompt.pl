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

# Use the live prose renderer (ContextBuilder projection +
# MessageHistory::messages_to_prose_dynamic) - the same path
# WorkflowOrchestrator uses in production. get_user_context (the old
# <sessionContext> XML builder) was removed in the role-based history
# refactor; the environment block is now rendered as natural prose.
require CLIO::Core::ContextBuilder;
require CLIO::Core::MessageHistory;

my $projection = CLIO::Core::ContextBuilder::build_projection(
    history             => [],
    user_input          => 'verify cwd',
    active_task         => 'verify cwd',
    active_todos        => [],
    ltm                 => [],
    unresolved          => [],
    context_files_block => '',
);
my $section = eval { CLIO::Core::MessageHistory::messages_to_prose_dynamic($projection) };

ok(defined $section && length($section), "Generated user context section");

if ($section) {
    ok($section =~ /Working directory:/, "Section includes 'Working directory:'");
    ok($section =~ /\Q$current_pwd\E/, "Section includes actual PWD: $current_pwd");
    unlike($section, qr/sessionContext/, "No <sessionContext> XML tag (prose format)");

    print "# Sample from section:\n";
    for my $line (grep { defined $_ && /Working directory|Language|Date/ } (split /\n/, $section)[0..5]) {
        print "#   $line\n";
    }
} else {
    fail("Could not generate section: $@");
    fail("No section content");
    fail("No PWD found");
}

# Cleanup
chdir($orig_dir);

print "# Test complete: PWD is included in user context\n";
done_testing();
