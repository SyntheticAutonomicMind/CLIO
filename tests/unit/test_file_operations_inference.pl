#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use lib './lib';
use Test::More tests => 8;
use File::Temp qw(tempdir);
use CLIO::Tools::FileOperations;

# The old silent-inference contract guessed an operation from the shape of
# the parameters, so {path} became read_file and {content} became write_file.
# That made a wrong call look successful. The contract now: a multi-operation
# tool must be told which operation to run.

my $dir = tempdir(CLEANUP => 1);
my $file = "$dir/sample.txt";
open my $fh, '>:encoding(UTF-8)', $file or die $!;
print $fh "alpha\nbeta\n";
close $fh;

my $tool = CLIO::Tools::FileOperations->new(debug => 0, session_dir => $dir);

ok(!$tool->can('_infer_operation_from_params'),
    'parameter-shape inference method is gone');
ok(!defined $tool->{default_operation},
    'no default_operation fallback');

my $r1 = $tool->execute({ path => $file }, {});
ok(!$r1->{success}, 'path-only call is an error, not a silent read');
like($r1->{error}, qr/Missing 'operation' parameter/,
    'error names the missing operation');

my $r2 = $tool->execute({ path => $file }, {});
ok(!$r2->{success}, 'repeated path-only call stays an error');

my $r3 = $tool->execute({ operation => 'read_file', path => $file }, {});
ok($r3->{success}, 'explicit read_file succeeds');
like($r3->{output}, qr/alpha/, 'explicit read_file returns content');

my $r4 = $tool->execute({ operation => 'grep_search', path => $dir }, {});
ok(!$r4->{success}, 'grep_search without query is an error');

done_testing();
