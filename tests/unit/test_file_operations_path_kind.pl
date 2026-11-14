#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Path-kind handling in file operations.
#
# A path has three states: absent, present as a directory, present as a
# file. Reporting "File not found" for a path that exists as a directory
# is false, and a model that believes the path is missing re-issues the
# identical call instead of correcting it. The field log showed 13
# identical file_search calls because a file path produced "Directory
# not found".
#
# Covered here:
# - file_search honors a file path (single-file mode), like grep_search
# - list_dir on a file, file ops on a directory: kind-mismatch errors
# - genuinely absent paths still report "not found"
# - ToolErrorGuidance classifies a mismatch separately from not-found

use strict;
use warnings;
use utf8;
use lib './lib';

use File::Temp qw(tempdir);
use File::Spec;
use Test::More;

use CLIO::Tools::FileOperations;
use CLIO::Core::ToolErrorGuidance;

my $dir = tempdir(CLEANUP => 1);
my $subdir = File::Spec->catdir($dir, 'nested');
mkdir $subdir or die "mkdir $subdir: $!";

my $file = File::Spec->catfile($dir, 'target.pm');
open my $fh, '>:encoding(UTF-8)', $file or die "write $file: $!";
print $fh "sub target { 1 }\n";
close $fh;

my $other = File::Spec->catfile($subdir, 'deep.pm');
open $fh, '>:encoding(UTF-8)', $other or die "write $other: $!";
print $fh "sub deep { 2 }\n";
close $fh;

my $fo = CLIO::Tools::FileOperations->new(debug => 0);

subtest 'file_search honors a file path' => sub {
    my $r = $fo->file_search({ pattern => '**/target.pm', directory => $file }, {});
    ok($r->{success}, 'searching a file path succeeds');
    is($r->{count}, 1, 'the named file is returned');

    $r = $fo->file_search({ pattern => '*.pm', directory => $file }, {});
    ok($r->{success}, 'bare glob against a file path succeeds');
    is($r->{count}, 1, 'basename matches the glob');

    $r = $fo->file_search({ pattern => '*.rb', directory => $file }, {});
    ok($r->{success}, 'non-matching pattern on a file path is not an error');
    is($r->{count}, 0, 'no matches reported for a non-matching pattern');

    # A directory argument must keep recursive behavior.
    $r = $fo->file_search({ pattern => '**/*.pm', directory => $dir }, {});
    ok($r->{success}, 'directory search still works');
    is($r->{count}, 2, 'both files found recursively');
};

subtest 'file_search reports a genuinely absent directory' => sub {
    my $missing = File::Spec->catdir($dir, 'no_such_dir');
    my $r = $fo->file_search({ pattern => '*.pm', directory => $missing }, {});
    ok(!$r->{success}, 'absent directory fails');
    like($r->{error}, qr/^Directory not found:/, 'error says the directory is missing');
};

subtest 'directory operations on a file path name the mismatch' => sub {
    my $r = $fo->list_dir({ path => $file }, {});
    ok(!$r->{success}, 'list_dir on a file fails');
    like($r->{error}, qr/^Path is a file, not a directory:/,
        'error states the path is a file');
    unlike($r->{error}, qr/not found/i,
        'error does not claim the path is missing');
    like($r->{error}, qr/read_file/, 'recovery names read_file');
    like($r->{error}, qr/grep_search/, 'recovery names grep_search');
};

subtest 'file operations on a directory path name the mismatch' => sub {
    for my $case (
        [ 'read_file'      => sub { $fo->read_file({ path => $dir }, {}) } ],
        [ 'replace_string' => sub {
            $fo->replace_string({ path => $dir, old_string => 'a', new_string => 'b' }, {}) } ],
        [ 'insert_at_line' => sub {
            $fo->insert_at_line({ path => $dir, line => 1, content => "x\n" }, {}) } ],
        [ 'get_errors'     => sub { $fo->get_errors({ path => $dir }, {}) } ],
    ) {
        my ($name, $call) = @$case;
        my $r = $call->();
        ok(!$r->{success}, "$name on a directory fails");
        like($r->{error}, qr/^Path is a directory, not a file:/,
            "$name error states the path is a directory");
        unlike($r->{error}, qr/not found/i,
            "$name error does not claim the path is missing");
        like($r->{error}, qr/list_dir/, "$name recovery names list_dir");
    }
};

subtest 'absent file paths still report not found' => sub {
    my $missing = File::Spec->catfile($dir, 'nope.pm');

    my $r = $fo->read_file({ path => $missing }, {});
    like($r->{error}, qr/^File not found:/, 'read_file reports a missing file');

    $r = $fo->replace_string(
        { path => $missing, old_string => 'a', new_string => 'b' }, {});
    like($r->{error}, qr/^File not found:/, 'replace_string reports a missing file');
};

subtest 'error guidance separates mismatch from not-found' => sub {
    my $g = CLIO::Core::ToolErrorGuidance->new();

    is($g->_categorize_error("Path is a directory, not a file: /tmp/x"),
        'path_kind_mismatch', 'directory-for-file classifies as a mismatch');
    is($g->_categorize_error("Path is a file, not a directory: /tmp/x.pm"),
        'path_kind_mismatch', 'file-for-directory classifies as a mismatch');
    is($g->_categorize_error("File not found: /tmp/x.pm"),
        'file_not_found', 'missing file still classifies as not-found');
    is($g->_categorize_error("Directory not found: /tmp/nope"),
        'directory_not_found', 'missing directory still classifies as not-found');

    my $text = $g->_get_category_guidance('path_kind_mismatch');
    like($text, qr/path is correct/i, 'mismatch guidance says the path is correct');
    like($text, qr/Do not hunt for a different path/,
        'mismatch guidance forbids a path search');
    like($text, qr/list_dir/, 'mismatch guidance names list_dir');
};

done_testing();
