#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Test: grep_search accepts a file path (not just a directory) and searches
# only that file. Models naturally pass file paths to grep_search (Unix grep
# semantics), but the tool previously only accepted directories and failed
# with "Directory not found". This test verifies the file-vs-directory
# detection in grep_search:
#   - File path via 'directory' parameter
#   - File path via 'path' parameter (alias)
#   - File path with is_regex=true
#   - File path with literal query
#   - Non-existent path returns a clear error
#   - Directory mode still works (regression)
#   - relative_path is populated for single-file results

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');

use File::Basename qw(dirname);
use Cwd qw(abs_path);
use File::Temp qw(tempdir);

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

sub ok_eq {
    my ($got, $want, $label) = @_;
    if ($got eq $want) { $pass++; print "OK: $label\n"; }
    else {
        $fail++;
        print "FAIL: $label\n";
        print "  expected: $want\n";
        print "  got:      $got\n";
    }
}

# Create a temp directory with sample files.
my $tmp = tempdir(CLEANUP => 1);

# File 1: a Perl module with multiple matches
my $pm_path = "$tmp/MyModule.pm";
open my $fh, '>:encoding(UTF-8)', $pm_path or die "Cannot create $pm_path: $!";
print $fh <<'END';
package MyModule;
use strict;
use warnings;

sub hello {
    print "hello world\n";
}

sub goodbye {
    print "goodbye world\n";
}

my $skill = { type => 'freeform' };
# hash-deref pattern for regex test
my $x = $skill->{type} eq 'freeform';
1;
END
close $fh;

# File 2: a text file
my $txt_path = "$tmp/data.txt";
open $fh, '>:encoding(UTF-8)', $txt_path or die "Cannot create $txt_path: $!";
print $fh "The quick brown fox\n";
print $fh "jumps over the lazy dog\n";
print $fh "the end\n";
close $fh;

# A subdirectory with its own file
my $sub_dir = "$tmp/sub";
mkdir $sub_dir;
my $sub_file = "$sub_dir/nested.txt";
open $fh, '>:encoding(UTF-8)', $sub_file or die "Cannot create $sub_file: $!";
print $fh "nested content with hello\n";
close $fh;

my $tool = CLIO::Tools::FileOperations->new(
    debug      => 0,
    session_dir => $tmp,
);

# Minimal context for sandbox checks
my $context = {
    session => { session_id => 'test_grep_file_mode' },
    config  => undef,   # sandbox disabled -> allowed
};

# ---- Test 1: Single file via 'directory' parameter (file path) ----
my $result = $tool->grep_search({
    operation => 'grep_search',
    query     => 'hello',
    directory => $pm_path,
}, $context);
ok($result->{success}, 'grep_search on a file via directory= succeeds');
ok(scalar(@{$result->{output}}) == 2,
   'grep_search on file finds 2 matches (got ' . scalar(@{$result->{output}}) . ')');

# ---- Test 2: Single file via 'path' parameter (alias) ----
$result = $tool->grep_search({
    operation => 'grep_search',
    query     => 'hello',
    path      => $pm_path,
}, $context);
ok($result->{success}, 'grep_search on a file via path= succeeds');
ok(scalar(@{$result->{output}}) >= 1,
   'grep_search on file via path finds matches');

# ---- Test 3: Single file with is_regex=true ----
$result = $tool->grep_search({
    operation  => 'grep_search',
    query      => '\bprint\b',
    directory  => $pm_path,
    is_regex   => 1,
}, $context);
ok($result->{success}, 'grep_search on a file with regex succeeds');
ok(scalar(@{$result->{output}}) >= 1,
   'grep_search on file with regex finds matches (got ' . scalar(@{$result->{output}}) . ')');

# ---- Test 4: Auto-detect regex (metacharacters in query without is_regex) ----
$result = $tool->grep_search({
    operation => 'grep_search',
    query     => 'hello|goodbye',
    directory => $pm_path,
}, $context);
ok($result->{success}, 'grep_search on a file with auto-detected regex succeeds');
ok(scalar(@{$result->{output}}) >= 2,
   'grep_search auto-regex finds both hello and goodbye (got ' . scalar(@{$result->{output}}) . ')');

# ---- Test 5: Literal search (no metacharacters) ----
$result = $tool->grep_search({
    operation => 'grep_search',
    query     => 'freeform',
    directory => $pm_path,
}, $context);
ok($result->{success}, 'grep_search on a file with literal query succeeds');
ok(scalar(@{$result->{output}}) >= 1,
   'grep_search literal finds matches (got ' . scalar(@{$result->{output}}) . ')');

# ---- Test 6: relative_path populated in results ----
ok(defined $result->{output}[0]->{relative_path},
   'grep_search single-file result has relative_path');
ok($result->{output}[0]->{relative_path} eq $pm_path,
   'grep_search single-file relative_path equals the file path');

# ---- Test 7: Non-existent path returns error ----
$result = $tool->grep_search({
    operation => 'grep_search',
    query     => 'anything',
    directory => "$tmp/does_not_exist.pl",
}, $context);
ok(!$result->{success}, 'grep_search on non-existent file fails gracefully');
ok(index($result->{error} // '', 'not found') >= 0 || index($result->{error} // '', 'Path') >= 0,
   'grep_search non-existent file returns clear error message');

# ---- Test 8: Directory mode still works (regression) ----
$result = $tool->grep_search({
    operation => 'grep_search',
    query     => 'hello',
    directory => $tmp,
}, $context);
ok($result->{success}, 'grep_search on a directory still works');
ok(scalar(@{$result->{output}}) >= 2,
   'grep_search on directory finds matches across multiple files (got ' . scalar(@{$result->{output}}) . ')');

# ---- Test 9: Directory mode with pattern filter ----
$result = $tool->grep_search({
    operation => 'grep_search',
    query     => 'hello',
    directory => $tmp,
    pattern   => '*.pm',
}, $context);
ok($result->{success}, 'grep_search on directory with pattern filter succeeds');
ok(scalar(@{$result->{output}}) >= 1,
   'grep_search directory+pattern finds matches (got ' . scalar(@{$result->{output}}) . ')');

# ---- Test 10: path takes precedence note — if both path and directory
# are given for a file, directory wins (grep_search delegates to file_search
# for directories). We test that passing 'path' as alias to a directory
# also works.
$result = $tool->grep_search({
    operation => 'grep_search',
    query     => 'hello',
    path      => $tmp,
}, $context);
ok($result->{success}, 'grep_search on directory via path= alias succeeds');
ok(scalar(@{$result->{output}}) >= 2,
   'grep_search directory via path= finds matches (got ' . scalar(@{$result->{output}}) . ')');

print "\n";
print "Pass: $pass\n";
print "Fail: $fail\n";
exit($fail ? 1 : 0);
