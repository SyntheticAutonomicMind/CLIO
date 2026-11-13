#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use lib './lib';
use Test::More tests => 4;
use CLIO::Tools::TerminalOperations;

# terminal_operations has two operations, so a call without 'operation' is
# ambiguous. It must return a precise error instead of silently running exec.

my $tool = CLIO::Tools::TerminalOperations->new(debug => 0);

my $missing = $tool->execute({ command => 'echo hello' }, {});
ok(!$missing->{success}, 'missing operation is rejected');
like($missing->{error}, qr/Missing 'operation' parameter/,
    'error names the missing operation');

my $exec = $tool->execute({ operation => 'exec', command => 'echo world' }, {});
ok($exec->{success}, 'explicit exec succeeds');
like($exec->{output}, qr/^world\s*$/m, 'explicit exec returns command output');

done_testing();
