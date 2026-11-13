#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Test: missing operation handling.
#
# The base class no longer infers an operation from parameter keys or from
# the shape of the parameters. A multi-operation tool must be told which
# operation to run; a single-operation tool declares its operation and may
# omit the field because its emitted schema has no operation property.

use strict;
use warnings;
use utf8;
use lib './lib';
use File::Temp qw(tempdir);
use Test::More;

use CLIO::Tools::FileOperations;
use CLIO::Tools::TerminalOperations;
use CLIO::Tools::VersionControl;
use CLIO::Tools::MemoryOperations;
use CLIO::Tools::ApplyPatch;

my $tmp = tempdir(CLEANUP => 1);
my $file = "$tmp/sample.txt";
open my $fh, '>:encoding(UTF-8)', $file or die $!;
print $fh "hello\n";
close $fh;

my $ctx = {};

# Multi-operation tools: missing operation is an error, never a guess.
for my $case (
    [ 'file_operations',     CLIO::Tools::FileOperations->new(debug => 0, session_dir => $tmp), { path => $file } ],
    [ 'terminal_operations', CLIO::Tools::TerminalOperations->new(debug => 0),                    { command => 'echo hi' } ],
    [ 'version_control',     CLIO::Tools::VersionControl->new(debug => 0),                        { limit => 5 } ],
    [ 'memory_operations',   CLIO::Tools::MemoryOperations->new(debug => 0),                      { key => 'k' } ],
) {
    my ($name, $tool, $params) = @$case;
    my $r = $tool->execute($params, $ctx);
    ok(!$r->{success}, "$name: missing operation is an error");
    like($r->{error}, qr/Missing 'operation' parameter/, "$name: error names the missing operation");
}

# Operation-name-as-parameter-key is not inferred.
my $fo = CLIO::Tools::FileOperations->new(debug => 0, session_dir => $tmp);
my $r = $fo->execute({ read_file => 1, path => $file }, $ctx);
ok(!$r->{success}, 'operation sent as a parameter key is rejected');

# Explicit operation still works.
my $ok = $fo->execute({ operation => 'read_file', path => $file }, $ctx);
ok($ok->{success}, 'explicit operation succeeds');
like($ok->{output}, qr/hello/, 'explicit operation returns content');

# Single-operation tool: declared operation, no operation field required.
my $patch = CLIO::Tools::ApplyPatch->new(debug => 0);
my $patch_text = "*** Begin Patch\n*** Add File: $tmp/added.txt\n+one\n*** End Patch\n";
my $pr = $patch->execute({ patch => $patch_text }, $ctx);
ok($pr->{success}, 'single_operation tool runs without an operation field');
ok(-e "$tmp/added.txt", 'single_operation tool performed its work');

# Unknown operation on a multi-operation tool is rejected.
my $bad2 = $fo->execute({ operation => 'frobnicate', path => $file }, $ctx);
ok(!$bad2->{success}, 'unknown operation is rejected');
like($bad2->{error}, qr/Unknown operation/, 'unknown operation error is explicit');

done_testing();
