#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More tests => 3;
use CLIO::Tools::TerminalOperations;

# Regression test for the "missing operation parameter" error-loop bug.
# When a model calls terminal_operations with 'command' but omits
# 'operation', CLIO should silently default to 'exec' instead of
# returning a TOOL ERROR. This prevents error-loop deaths where the
# model keeps repeating the same mistake 3 times and gets the session
# broken to the user.

my $tool = CLIO::Tools::TerminalOperations->new(debug => 0);

# Test 1: command present, operation absent -> defaults to exec
my $result = $tool->execute({ command => "echo hello" }, {});
ok($result->{success},
   "terminal_operations auto-defaults to exec when operation is missing");
like($result->{output}, qr/^hello\s*$/m,
   "terminal_operations exec output is correct (echo hello)");

# Test 2: explicit operation still works (no regression)
my $result2 = $tool->execute({ operation => "exec", command => "echo world" }, {});
ok($result2->{success} && $result2->{output} =~ /^world\s*$/m,
   "terminal_operations explicit operation still works");

done_testing();
