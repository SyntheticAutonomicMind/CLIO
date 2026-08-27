#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Test: Silent operation inference in Tool.pm::execute()
#
# When a model forgets the 'operation' parameter and instead uses the
# operation name as a parameter key (e.g., {"read_file": true, "path": "..."}
# instead of {"operation": "read_file", "path": "..."}), the Tool base class
# should silently infer the operation from the single matching parameter key.
#
# This test verifies:
#   1. Single key match is inferred and the key is removed from params
#   2. No match falls through to the existing "Missing 'operation' parameter" error
#   3. Multiple matches (ambiguous) falls through to the error
#   4. Normal calls with operation present are unaffected
#   5. Works with operation_aliases (short aliases like "read")
#   6. Works across multiple tool types (not just file_operations)

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use File::Temp qw(tempdir);
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use Test::More;

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

my $repo_root = abs_path(dirname(dirname(dirname($0))));
$repo_root = abs_path('.') unless -d "$repo_root/lib";
unshift @INC, "$repo_root/lib";

require CLIO::Tools::FileOperations;
require CLIO::Tools::TerminalOperations;
require CLIO::Tools::VersionControl;
require CLIO::Tools::MemoryOperations;

plan(tests => 24);

my $tmp = tempdir(CLEANUP => 1);
my $ctx = { session => { id => 'op-inference-test' } };

# ================================================================
# _infer_operation_from_params helper: returns the right operation
# ================================================================

my $fo = CLIO::Tools::FileOperations->new(debug => 0, session_dir => $tmp);

# Single key match: infers the operation name
{
    my $params = { read_file => 1, path => 'foo' };
    my $inferred = $fo->_infer_operation_from_params($params);
    is($inferred, 'read_file', "inferred operation is 'read_file'");
}

# No matching keys: returns undef
{
    my $params = { path => 'foo', content => 'bar' };
    my $inferred = $fo->_infer_operation_from_params($params);
    ok(!defined $inferred, "no matching key returns undef");
}

# Multiple matching keys: returns undef (ambiguous)
{
    my $params = { read_file => 1, list_dir => 1 };
    my $inferred = $fo->_infer_operation_from_params($params);
    ok(!defined $inferred, "multiple matching keys returns undef (ambiguous)");
}

# Alias match: infers the alias
{
    my $params = { read => 1, path => 'foo' };
    my $inferred = $fo->_infer_operation_from_params($params);
    is($inferred, 'read', "inferred operation from alias key 'read' is 'read'");
}

# Empty/non-hash params: returns undef
{
    my $inferred = $fo->_infer_operation_from_params(undef);
    ok(!defined $inferred, "undef params returns undef");
}

# ================================================================
# Full execute() flow: single key match is inferred + key deleted
# ================================================================

# Model sends {"read_file": true, "path": "..."}
{
    my $test_file = "$tmp/test1.txt";
    open my $fh, '>:encoding(UTF-8)', $test_file or die $!;
    print $fh "hello world\n";
    close $fh;

    my $r = $fo->execute({ read_file => 1, path => $test_file }, $ctx);
    ok($r->{success}, "execute: single-key match 'read_file' is inferred and succeeds");
}

# Verify the operation key was deleted from params (internal detail,
# tested via execute side-effect: if the key weren't deleted, handlers
# that iterate over params might behave differently)
{
    my $test_file = "$tmp/test_alias.txt";
    open my $fh, '>:encoding(UTF-8)', $test_file or die $!;
    print $fh "alias content\n";
    close $fh;

    my $r = $fo->execute({ read => 1, path => $test_file }, $ctx);
    ok($r->{success}, "execute: alias key 'read' is inferred and succeeds");
}

# {"write_file": true, "path": "...", "content": "..."}
{
    my $test_file = "$tmp/test2.txt";
    my $r = $fo->execute({
        write_file => 1,
        path => $test_file,
        content => "test content\n",
    }, $ctx);
    ok($r->{success}, "execute: single-key match 'write_file' is inferred and succeeds");
}

# {"list_dir": true, "path": "..."}
{
    my $r = $fo->execute({ list_dir => 1, path => $tmp }, $ctx);
    ok($r->{success}, "execute: single-key match 'list_dir' is inferred and succeeds");
}

# ================================================================
# No match: falls through to existing error
# ================================================================

{
    my $r = $fo->execute({ path => '/some/file.txt' }, $ctx);
    ok(!$r->{success}, "execute: no matching key returns failure");
    like($r->{error}, qr/Missing 'operation' parameter/, "execute: no-match error mentions missing operation");
}

{
    my $r = $fo->execute({ foo => 1, bar => 2 }, $ctx);
    ok(!$r->{success}, "execute: unrelated params return failure");
    like($r->{error}, qr/Missing 'operation' parameter/, "execute: unrelated params error mentions missing operation");
}

# ================================================================
# Multiple matches: falls through to error (ambiguous)
# ================================================================

{
    my $r = $fo->execute({
        read_file => 1,
        list_dir => 1,
        path => $tmp,
    }, $ctx);
    ok(!$r->{success}, "execute: multiple matching keys returns failure");
    like($r->{error}, qr/Missing 'operation' parameter/, "execute: ambiguous match error mentions missing operation");
}

# ================================================================
# Normal calls (operation present) unaffected
# ================================================================

{
    my $test_file = "$tmp/test_normal.txt";
    open my $fh, '>:encoding(UTF-8)', $test_file or die $!;
    print $fh "normal content\n";
    close $fh;

    my $r = $fo->execute({ operation => 'read_file', path => $test_file }, $ctx);
    ok($r->{success}, "execute: normal read_file with explicit operation succeeds");
}

# operation='read' (alias as explicit value) still works
{
    my $r = $fo->execute({ operation => 'read', path => "$repo_root/lib/CLIO/Tools/FileOperations.pm" }, $ctx);
    ok($r->{success}, "execute: operation='read' (alias) still works normally");
}

# Explicit operation takes priority over matching key in params
{
    my $test_file = "$tmp/test_prio.txt";
    open my $fh, '>:encoding(UTF-8)', $test_file or die $!;
    print $fh "priority content\n";
    close $fh;

    my $r = $fo->execute({
        operation => 'read_file',
        read_file => 1,
        path => $test_file,
    }, $ctx);
    ok($r->{success}, "execute: explicit operation takes priority over matching param key");
}

# ================================================================
# Empty/undef operation with matching key: remediation kicks in
# ================================================================

{
    my $r = $fo->execute({
        operation => '',
        read_file => 1,
        path => "$repo_root/lib/CLIO/Tools/FileOperations.pm",
    }, $ctx);
    ok($r->{success}, "execute: empty-string operation overridden by matching key inference");
}

{
    my $r = $fo->execute({
        operation => undef,
        list_dir => 1,
        path => $tmp,
    }, $ctx);
    ok($r->{success}, "execute: undef operation overridden by matching key inference");
}

# ================================================================
# Cross-tool inference
# ================================================================

my $to = CLIO::Tools::TerminalOperations->new(debug => 0);
{
    my $r = $to->execute({ exec => 1, command => 'echo cross_tool_test' }, $ctx);
    ok($r->{success}, "TerminalOperations: key 'exec' inferred and succeeds");
}

my $vc = CLIO::Tools::VersionControl->new(debug => 0);
{
    my $r = $vc->execute({ status => 1, repository_path => '.' }, $ctx);
    ok($r->{success}, "VersionControl: key 'status' inferred and succeeds");
}

# ================================================================
# Inferred operation without required params: handler-level error
# (not "Missing 'operation' parameter")
# ================================================================

{
    my $r = $fo->execute({ read_file => 1 }, $ctx);
    ok(!$r->{success}, "execute: inferred operation without required params gets handler-level error");
    unlike($r->{error}, qr/Missing 'operation' parameter/,
        "execute: error is NOT about missing operation (it was inferred)");
}

1;
