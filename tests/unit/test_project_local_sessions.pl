#!/usr/bin/env perl
# Test: Sessions are centralized and isolated per project
#
# Runtime data (sessions, LTM, memory, vault, logs) lives under
# ~/.clio/projects/<project-uuid>/ keyed by a UUID stored in the
# project's .clio/project_uuid. Distinct projects must resolve to
# distinct UUID-keyed directories, and sessions from one project must
# not be visible from another. The per-process project-data cache must
# re-resolve when the working directory moves into a different project.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use Test::More tests => 6;
use CLIO::Session::Manager;
use CLIO::Util::PathResolver;
use File::Temp qw(tempdir);
use File::Spec;
use Cwd qw(getcwd abs_path);

print "# Test: Centralized, per-project session storage\n";

my $orig_dir = getcwd();

# Create two temporary project directories
my $project_a = tempdir(CLEANUP => 1);
my $project_b = tempdir(CLEANUP => 1);

print "# Project A: $project_a\n";
print "# Project B: $project_b\n";

# Test Project A
chdir($project_a) or die "Cannot chdir to $project_a: $!";
mkdir('.clio') or die "Cannot create .clio: $!";

my $sessions_dir_a = CLIO::Util::PathResolver::get_sessions_dir();
print "# Sessions dir A: $sessions_dir_a\n";

# Verify it uses the centralized ~/.clio/projects/<uuid>/sessions layout
ok($sessions_dir_a =~ m{/\.clio/projects/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/sessions$},
   "Session dir A is centralized under ~/.clio/projects/<uuid>/sessions");
ok($sessions_dir_a !~ /\Q$project_a\E/,
   "Session dir A is NOT inside the project tree (centralized, not project-local)");

# Create session in Project A
my $session_a = CLIO::Session::Manager->create(debug => 0);
$session_a->add_message('user', 'Message in Project A');
$session_a->save();
my $session_a_id = $session_a->{session_id};

# Verify session file exists in Project A
my $session_a_file = File::Spec->catfile($sessions_dir_a, "$session_a_id.json");
ok(-e $session_a_file, "Session A file exists in project A's data dir: $session_a_file");

# Test Project B
chdir($project_b) or die "Cannot chdir to $project_b: $!";
mkdir('.clio') or die "Cannot create .clio: $!";

my $sessions_dir_b = CLIO::Util::PathResolver::get_sessions_dir();
print "# Sessions dir B: $sessions_dir_b\n";

# Verify Project B has different session directory
ok($sessions_dir_a ne $sessions_dir_b, "Project B has different session directory than Project A");

# Verify session from Project A is NOT accessible in Project B  
my $session_b_file = File::Spec->catfile($sessions_dir_b, "$session_a_id.json");
ok(!-e $session_b_file, "Session A is NOT in Project B (session isolation works)");

# Create session in Project B
my $session_b = CLIO::Session::Manager->create(debug => 0);
$session_b->add_message('user', 'Message in Project B');
$session_b->save();
my $session_b_id = $session_b->{session_id};

# Verify session B file exists in Project B
my $session_b_file_correct = File::Spec->catfile($sessions_dir_b, "$session_b_id.json");
ok(-e $session_b_file_correct, "Session B file exists in Project B");

# Cleanup
chdir($orig_dir);

print "# Test complete: Sessions are centralized and isolated per project\n";
done_testing();
