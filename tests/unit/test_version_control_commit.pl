#!/usr/bin/env perl

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

=head1 NAME

test_version_control_commit.pl - Tests for commit operation's auto_stage behavior

=head1 DESCRIPTION

Verifies that the commit operation:
- Reports the staged file list in the result so callers can see what landed.
- Reports which untracked files were auto-staged (so callers can spot stray files).
- Honors auto_stage=0 by committing only pre-staged files.
- Returns a clear error when there is nothing to commit.

=cut

use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

BEGIN { use_ok('CLIO::Tools::VersionControl') or BAIL_OUT("Cannot load VersionControl"); }

print "\n=== VersionControl Commit Auto-Stage Tests ===\n\n";

my $vc = CLIO::Tools::VersionControl->new(debug => 0);
ok($vc, 'VersionControl object created');

sub init_repo {
    my $dir = shift;
    mkdir $dir unless -d $dir;
    chdir $dir;
    system("git init -q -b main . 2>&1");
    system("git config user.email 'test\@test.com' 2>&1");
    system("git config user.name 'Test User' 2>&1");
    system("git config commit.gpgsign false 2>&1");
    system("git config tag.gpgsign false 2>&1");
}

sub write_file {
    my ($name, $content) = @_;
    open my $f, ">", $name or die "Cannot create $name: $!";
    print $f $content;
    close $f;
}

# ─── Test 1: auto_stage=1 picks up untracked files ─────────────────────────
{
    my $dir = tempdir(CLEANUP => 1) . "/test1";
    init_repo($dir);

    write_file("tracked.txt", "initial\n");
    system("git add tracked.txt 2>&1");
    system("git commit -q -m 'initial' 2>&1");

    # Create untracked files
    write_file("stray.txt", "shouldn't be here\n");
    write_file("intended.txt", "should be here\n");

    my $r = $vc->commit({ message => 'auto stage test' });
    ok($r->{success}, 'commit succeeds with auto_stage default')
        or diag("error: $r->{error}");
    is_deeply([sort @{$r->{staged_files} // []}],
        ['intended.txt', 'stray.txt'],
        'staged_files includes untracked files');
    is_deeply([sort @{$r->{auto_staged_untracked} // []}],
        ['intended.txt', 'stray.txt'],
        'auto_staged_untracked lists previously-untracked files');
}

# ─── Test 2: auto_stage=0 commits only what is already staged ─────────────
{
    my $dir = tempdir(CLEANUP => 1) . "/test2";
    init_repo($dir);

    write_file("wanted.txt", "wanted\n");
    write_file("unwanted.txt", "should not be committed\n");

    system("git add wanted.txt 2>&1");

    my $r = $vc->commit({
        message => 'manual stage test',
        auto_stage => 0,
    });
    ok($r->{success}, 'commit succeeds with auto_stage=0')
        or diag("error: $r->{error}");
    is_deeply($r->{staged_files}, ['wanted.txt'],
        'auto_stage=0 commits only the pre-staged file');
    ok(!exists $r->{auto_staged_untracked},
        'auto_staged_untracked key absent when auto_stage=0');
}

# ─── Test 3: Nothing to commit returns clean error ────────────────────────
{
    my $dir = tempdir(CLEANUP => 1) . "/test3";
    init_repo($dir);

    my $r = $vc->commit({ message => 'nothing to commit' });
    ok(!$r->{success}, 'commit fails on clean tree');
    like($r->{error}, qr/Nothing to commit/,
        'error message explains clean tree');
}

# ─── Test 4: Pre-existing staged change is captured ───────────────────────
{
    my $dir = tempdir(CLEANUP => 1) . "/test4";
    init_repo($dir);

    # Stage a change to a file, no auto_stage needed
    write_file("a.txt", "hello\n");
    system("git add a.txt 2>&1");

    my $r = $vc->commit({
        message => 'pre-staged file',
        auto_stage => 0,
    });
    ok($r->{success}, 'commit succeeds with pre-staged file')
        or diag("error: $r->{error}");
    is_deeply($r->{staged_files}, ['a.txt'],
        'staged_files shows the pre-staged file with status prefix stripped');
}

print "\n=== Test Summary ===\n";
done_testing();

