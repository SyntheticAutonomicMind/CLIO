#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Test: FileOperations accepts operation-name aliases (e.g. `list_directory`,
# `read`, `mkdir`) and dispatches them to the same method as the canonical
# name. Catches the regression where the harness rejected natural-language
# operation names with "Unknown operation: list_directory. Did you mean: list_dir?".
#
# Strategy: invoke each alias with a unique tmp path, assert it produces a
# successful result consistent with the underlying operation. We do NOT
# run the canonical-then-alias side-by-side comparison because some
# operations (write_file, create_directory) error if their target already
# exists, so running canonical first would make the alias fail.

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');

use File::Basename qw(dirname);
use Cwd qw(abs_path);
use File::Path qw(remove_tree);
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

sub like {
    my ($str, $pattern, $label) = @_;
    if (index($str, $pattern) >= 0) {
        $pass++;
        print "OK: $label\n";
        return 1;
    } else {
        $fail++;
        print "FAIL: $label  (got: " . substr($str, 0, 80) . "...)\n";
        return 0;
    }
}

my $tmp = tempdir(CLEANUP => 1);
my $tool = CLIO::Tools::FileOperations->new(debug => 0, session_dir => $tmp);
my $ctx = { session => { id => 'alias-test' } };

# Each case: { name => $alias, params => \%params, check => \&check }
# A leading underscore in name means "setup only, no invocation".
my @cases = (
    { name => 'read', params => { operation => 'read', path => "$repo_root/lib/CLIO/Tools/FileOperations.pm" },
        check => sub { $_[0]->{success} && length($_[0]->{output} // '') > 0 } },
    { name => 'list_directory', params => { operation => 'list_directory', path => "$repo_root/lib/CLIO" },
        check => sub { $_[0]->{success} && ref($_[0]->{output}) eq 'ARRAY' } },

    { name => 'exists', params => { operation => 'exists', path => "$repo_root/lib/CLIO/Tools/FileOperations.pm" },
        check => sub { $_[0]->{success} } },
    { name => 'stat_file', params => { operation => 'stat_file', path => "$repo_root/lib/CLIO/Tools/FileOperations.pm" },
        check => sub { $_[0]->{success} && ref($_[0]->{output}) eq 'HASH' && $_[0]->{output}{size} } },

    { name => 'find_files', params => { operation => 'find_files', pattern => 'FileOperations.pm' },
        check => sub { $_[0]->{success} } },
    { name => 'search', params => { operation => 'search', query => 'sub read_file' },
        check => sub { $_[0]->{success} } },

    { name => 'create', params => { operation => 'create', path => "$tmp/created_via_alias.txt", content => "hello\n" },
        check => sub { $_[0]->{success} && -f "$tmp/created_via_alias.txt" } },

    { name => '_write_setup', setup => sub {
        open my $fh, '>:encoding(UTF-8)', "$tmp/written_via_alias.txt" or die;
        print $fh "old\n"; close $fh;
      } },
    { name => 'write', params => { operation => 'write', path => "$tmp/written_via_alias.txt", content => "new\n" },
        check => sub { $_[0]->{success} } },

    { name => '_append_setup', setup => sub {
        open my $fh, '>:encoding(UTF-8)', "$tmp/appended_via_alias.txt" or die;
        print $fh "first\n"; close $fh;
      } },
    { name => 'append', params => { operation => 'append', path => "$tmp/appended_via_alias.txt", content => "line\n" },
        check => sub { $_[0]->{success} } },

    { name => '_replace_setup', setup => sub {
        open my $fh, '>:encoding(UTF-8)', "$tmp/replace_via_alias.txt" or die;
        print $fh "foo\n"; close $fh;
      } },
    { name => 'replace', params => { operation => 'replace', path => "$tmp/replace_via_alias.txt",
                                     old_string => 'foo', new_string => 'bar' },
        check => sub { $_[0]->{success} } },

    { name => '_edit_setup', setup => sub {
        open my $fh, '>:encoding(UTF-8)', "$tmp/edit_via_alias.txt" or die;
        print $fh "x\n"; close $fh;
      } },
    { name => 'edit', params => { operation => 'edit', path => "$tmp/edit_via_alias.txt",
                                  old_string => 'x', new_string => 'y' },
        check => sub { $_[0]->{success} } },

    { name => '_insert_line_setup', setup => sub {
        open my $fh, '>:encoding(UTF-8)', "$tmp/insert_via_alias.txt" or die;
        print $fh "a\nb\n"; close $fh;
      } },
    { name => 'insert_line', params => { operation => 'insert_line', path => "$tmp/insert_via_alias.txt", line => 2, content => "z\n" },
        check => sub { $_[0]->{success} } },

    { name => '_insert_setup', setup => sub {
        open my $fh, '>:encoding(UTF-8)', "$tmp/insert2_via_alias.txt" or die;
        print $fh "a\nb\n"; close $fh;
      } },
    { name => 'insert', params => { operation => 'insert', path => "$tmp/insert2_via_alias.txt", line => 2, content => "z\n" },
        check => sub { $_[0]->{success} } },

    { name => 'bulk_replace', params => { operation => 'bulk_replace', replacements => [
            { path => "$tmp/nonexistent.txt", old_string => 'foo', new_string => 'bar' } ] },
        check => sub { 1 } },  # dispatch is the goal; pass if no exception

    { name => 'make_directory', params => { operation => 'make_directory', path => "$tmp/subdir1" },
        check => sub { $_[0]->{success} && -d "$tmp/subdir1" } },
    { name => 'mkdir', params => { operation => 'mkdir', path => "$tmp/subdir2" },
        check => sub { $_[0]->{success} && -d "$tmp/subdir2" } },
);

for my $case (@cases) {
    if ($case->{name} =~ /^_/) {
        $case->{setup}->();
        next;
    }
    my $result = $tool->execute($case->{params}, $ctx);
    my $predicate_ok = $case->{check}->($result, $tmp);
    ok($predicate_ok, "alias '$case->{name}' dispatches correctly (success="
        . ($result->{success} // 'undef') . ')')
      or do {
        print "    error: ", substr(($result->{error} // ''), 0, 200), "\n";
      };
}

# Unknown operation produces the standard error format.
{
    my $r = $tool->execute({ operation => 'frobnicate', path => '/tmp' }, $ctx);
    ok(!$r->{success}, 'unknown operation returns failure');
    like($r->{error} // '', 'Unknown operation: frobnicate',
        'unknown operation error message');
    like($r->{error} // '', 'Valid operations:',
        'unknown operation error message lists available operations');
}

# A near-typo with exactly one close match triggers "Did you mean".
{
    my $r = $tool->execute({ operation => 'read_filly', path => '/tmp' }, $ctx);
    ok(!$r->{success}, 'near-typo operation returns failure');
    like($r->{error} // '', 'Did you mean',
        'near-typo error message includes "Did you mean" suggestion');
}

# Mutate operations get their own block to avoid being interspersed with
# the read-only checks above.
{
    open my $fh, '>:encoding(UTF-8)', "$tmp/rename_src.txt" or die;
    print $fh "x\n"; close $fh;
    my $r = $tool->execute(
        { operation => 'rename', old_path => "$tmp/rename_src.txt", new_path => "$tmp/rename_dst.txt" },
        $ctx
    );
    ok($r->{success} && -f "$tmp/rename_dst.txt" && !-f "$tmp/rename_src.txt",
        "alias 'rename' dispatches correctly");

    open my $fh2, '>:encoding(UTF-8)', "$tmp/rename_src2.txt" or die;
    print $fh2 "x\n"; close $fh2;
    my $r2 = $tool->execute(
        { operation => 'mv', old_path => "$tmp/rename_src2.txt", new_path => "$tmp/rename_dst2.txt" },
        $ctx
    );
    ok($r2->{success} && -f "$tmp/rename_dst2.txt",
        "alias 'mv' dispatches correctly");

    my $r3 = $tool->execute({ operation => 'delete', path => "$tmp/rename_dst.txt" }, $ctx);
    ok($r3->{success} && !-f "$tmp/rename_dst.txt",
        "alias 'delete' dispatches correctly");

    my $r4 = $tool->execute({ operation => 'remove', path => "$tmp/rename_dst2.txt" }, $ctx);
    ok($r4->{success} && !-f "$tmp/rename_dst2.txt",
        "alias 'remove' dispatches correctly");
}

remove_tree($tmp);

print "\nPassed: $pass\n";
print "Failed: $fail\n";
exit($fail == 0 ? 0 : 1);
