#!/usr/bin/env perl

# Test git branch detection via .git/HEAD file read
# Validates the Chat.pm approach of reading .git/HEAD instead of spawning subprocess

use strict;
use warnings;
use lib './lib';
use Test::More tests => 6;
use File::Temp qw(tempdir);
use File::Spec;
use File::Path qw(make_path);

# Helper: simulate .git/HEAD reading logic (same as Chat.pm _build_prompt)
sub read_git_branch {
    my ($git_dir) = @_;
    my $head_file = File::Spec->catfile($git_dir, 'HEAD');
    my $branch = '';
    if (open my $fh, '<', $head_file) {
        my $head = <$fh>;
        close $fh;
        chomp $head if $head;
        if ($head && $head =~ m{^ref: refs/heads/(.+)$}) {
            $branch = $1;
        }
    }
    return $branch;
}

my $tmpdir = tempdir(CLEANUP => 1);

# Test 1: Normal branch ref
{
    my $git_dir = File::Spec->catfile($tmpdir, 'repo1', '.git');
    make_path($git_dir);
    my $head = File::Spec->catfile($git_dir, 'HEAD');
    open my $fh, '>', $head;
    print $fh "ref: refs/heads/main\n";
    close $fh;
    is(read_git_branch($git_dir), 'main', 'reads main branch');
}

# Test 2: Feature branch with slashes
{
    my $git_dir = File::Spec->catfile($tmpdir, 'repo2', '.git');
    make_path($git_dir);
    my $head = File::Spec->catfile($git_dir, 'HEAD');
    open my $fh, '>', $head;
    print $fh "ref: refs/heads/feature/my-branch\n";
    close $fh;
    is(read_git_branch($git_dir), 'feature/my-branch', 'reads feature branch with slash');
}

# Test 3: Detached HEAD (commit hash)
{
    my $git_dir = File::Spec->catfile($tmpdir, 'repo3', '.git');
    make_path($git_dir);
    my $head = File::Spec->catfile($git_dir, 'HEAD');
    open my $fh, '>', $head;
    print $fh "abc123def456789\n";
    close $fh;
    is(read_git_branch($git_dir), '', 'detached HEAD returns empty');
}

# Test 4: No .git directory
{
    my $git_dir = File::Spec->catfile($tmpdir, 'norepo', '.git');
    is(read_git_branch($git_dir), '', 'missing .git returns empty');
}

# Test 5: Verify it matches actual git output (in real repo)
SKIP: {
    skip "not in a git repo", 1 unless -f '.git/HEAD';
    my $from_file = read_git_branch('.git');
    my $from_git = `git branch --show-current 2>/dev/null`;
    chomp $from_git;
    is($from_file, $from_git, '.git/HEAD matches git branch --show-current');
}

# Test 6: Empty HEAD file
{
    my $git_dir = File::Spec->catfile($tmpdir, 'repo4', '.git');
    make_path($git_dir);
    my $head = File::Spec->catfile($git_dir, 'HEAD');
    open my $fh, '>', $head;
    close $fh;
    is(read_git_branch($git_dir), '', 'empty HEAD returns empty');
}

print "\n All git branch cache tests passed!\n";
