#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Test: grep_search no longer truncates results due to a hardcoded 200-file
# limit. Before the fix, file_search returned at most 200 files (default
# max_results=200) and grep_search further capped at 200 files. File::Find
# traverses directories alphabetically, so a large build/vendored directory
# (e.g. .build/, external/) could consume the entire 200-file budget before
# the directory containing the actual matches was reached.
#
# This test creates a directory with 250+ small files where the search term
# only appears in the file beyond the old 200-file boundary, then verifies
# that grep_search finds it. Also verifies that file_search with
# max_results=0 returns all matching files (no limit).

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');

use File::Basename qw(dirname);
use Cwd qw(abs_path);
use File::Temp qw(tempdir);
use File::Path qw(make_path);

my $repo_root = abs_path(dirname(dirname(dirname($0))));
$repo_root = abs_path('.') unless -d "$repo_root/lib";
unshift @INC, "$repo_root/lib";

require CLIO::Tools::FileOperations;

my ($pass, $fail) = (0, 0);

sub ok {
    my ($cond, $label) = @_;
    if ($cond) { $pass++; print "OK: $label\n"; }
    else       { $fail++; print "FAIL: $label\n"; }
}

# Create a temp directory simulating a large codebase:
# - 250 small files that do NOT contain the search term (filling the old
#   200-file budget)
# - 1 file at the end that DOES contain the search term
my $tmp = tempdir(CLEANUP => 1);

my $search_target = 'UNIQUE_MARKER_TOKEN_42';
my $file_count = 250;

# Create filler files (000.pl through 249.pl) that do NOT match
for my $i (0..$file_count - 1) {
    my $path = sprintf("%s/filler_%03d.pl", $tmp, $i);
    open my $fh, '>:encoding(UTF-8)', $path or die "Cannot create $path: $!";
    print $fh "# This is filler file number $i\n";
    print $fh "sub do_nothing { return 1; }\n";
    close $fh;
}

# Create one file that DOES contain the search term, placed AFTER the
# old 200-file limit. With the old code, file_search would return only
# 200 files, and since File::Find traverses alphabetically, "filler_*"
# files come before "target_*" files, so the target would never be found.
my $target_path = "$tmp/target_file.pl";
open my $fh, '>:encoding(UTF-8)', $target_path or die "Cannot create $target_path: $!";
print $fh "# This file contains the search target\n";
print $fh "my \$marker = '$search_target';\n";
print $fh "print \"Found it\n\";\n";
close $fh;

my $tool = CLIO::Tools::FileOperations->new(
    debug      => 0,
    session_dir => $tmp,
);

my $context = {
    session => { session_id => 'test_no_file_limit' },
    config  => undef,    # sandbox disabled
};

# ---- Test 1: grep_search finds the match beyond old 200-file limit ----
my $result = $tool->grep_search({
    query     => $search_target,
    directory => $tmp,
}, $context);

ok($result->{success}, 'grep_search succeeds on large directory');
my $match_count = scalar @{$result->{output} // []};
ok($match_count >= 1, "grep_search finds match beyond old 200-file limit (got $match_count matches)");
ok($result->{files_searched} >= $file_count,
   "grep_search searched all files (got " . $result->{files_searched} . " searched)");

# Verify the match is in the target file, not a filler
if ($match_count >= 1) {
    my $found_target = 0;
    for my $m (@{$result->{output}}) {
        if ($m->{relative_path} eq 'target_file.pl') {
            $found_target = 1;
            last;
        }
    }
    ok($found_target, 'grep_search found the match in the correct file (target_file.pl)');
}

# ---- Test 2: max_files parameter caps file search ----
# When max_files is set to a small number, the search should be truncated.
$result = $tool->grep_search({
    query     => $search_target,
    directory => $tmp,
    max_files => 10,
}, $context);

ok($result->{success}, 'grep_search with max_files=10 succeeds');
ok($result->{truncated} // 0, 'grep_search with max_files=10 reports truncated');
# With only 10 files searched (the first 10 alphabetically, which are fillers),
# the target_file.pl should NOT be found.
my $capped_matches = scalar @{$result->{output} // []};
ok($capped_matches == 0, "grep_search with max_files=10 finds 0 matches (target is beyond 10 files) (got $capped_matches)");

# ---- Test 3: file_search with max_results=0 returns ALL files ----
my $fs_result = $tool->file_search({
    pattern    => '**/*',
    directory  => $tmp,
    max_results => 0,
}, $context);

ok($fs_result->{success}, 'file_search with max_results=0 succeeds');
my $fs_count = scalar @{$fs_result->{output} // []};
ok($fs_count >= $file_count + 1,
   "file_search with max_results=0 returns all files (got $fs_count, expected >= $file_count + 1)");

# ---- Test 4: file_search default (max_results=200) still caps at 200 ----
# This verifies backwards compatibility: the default limit of 200 is preserved
# for direct file_search callers.
$fs_result = $tool->file_search({
    pattern    => '**/*',
    directory  => $tmp,
    # max_results not specified -> default 200
}, $context);

ok($fs_result->{success}, 'file_search with default max_results succeeds');
my $fs_default_count = scalar @{$fs_result->{output} // []};
ok($fs_default_count == 200,
   "file_search default max_results caps at 200 (got $fs_default_count)");

# ---- Test 5: max_results=0 in file_search with a smaller directory still works ----
my $small_tmp = tempdir(CLEANUP => 1);
for my $i (0..9) {
    my $path = "$small_tmp/file_$i.txt";
    open my $fh2, '>:encoding(UTF-8)', $path or die;
    print $fh2 "line $i\n";
    close $fh2;
}
$fs_result = $tool->file_search({
    pattern    => '**/*',
    directory  => $small_tmp,
    max_results => 0,
}, $context);
ok($fs_result->{success}, 'file_search with max_results=0 on small dir succeeds');
my $small_count = scalar @{$fs_result->{output} // []};
ok($small_count == 10, "file_search with max_results=0 returns all 10 files on small dir (got $small_count)");

print "\n";
print "Pass: $pass\n";
print "Fail: $fail\n";
exit($fail ? 1 : 0);
