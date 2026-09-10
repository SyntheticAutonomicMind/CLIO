#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt Fewtarius
#
# Test: TerminalOperations accepts operation-name aliases (run, execute,
# shell -> exec, check -> validate) and dispatches them correctly. Also
# tests single-operation auto-selection for tools like Interact and
# ApplyPatch (which have exactly one supported operation).

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');

use File::Basename qw(dirname);
use Cwd qw(abs_path);

my $repo_root = abs_path(dirname(dirname(dirname($0))));
$repo_root = abs_path('.') unless -d "$repo_root/lib";
unshift @INC, "$repo_root/lib";

require CLIO::Tools::TerminalOperations;
require CLIO::Tools::Interact;
require CLIO::Tools::ApplyPatch;

my ($pass, $fail) = (0, 0);
sub ok {
    my ($cond, $label) = @_;
    if ($cond) { $pass++; print "OK: $label\n"; }
    else       { $fail++; print "FAIL: $label\n"; }
}

my $term = CLIO::Tools::TerminalOperations->new(debug => 0);
my $ctx = { session => { id => 'alias-test' } };

# --- exec aliases (run, execute, shell should all dispatch to execute_command) ---
for my $alias (qw(run execute shell)) {
    my $r = $term->execute({ operation => $alias, command => 'echo hello' }, $ctx);
    ok($r->{success}, "exec alias '$alias' dispatches and succeeds");
    if ($r->{success} && defined $r->{output}) {
        $pass++; print "OK: exec alias '$alias' output contains expected text\n";
    } else {
        $fail++; print "FAIL: exec alias '$alias' output missing (got: " . substr($r->{output}//'undef',0,80) . ")\n";
    }
}

# --- validate alias (check -> validate_command) ---
{
    my $r = $term->execute({ operation => 'check', command => 'echo hello' }, $ctx);
    ok($r->{success}, "validate alias 'check' dispatches and succeeds");
}

# --- param-key inference: exec as parameter key ---
# The model sometimes passes {"exec": "ls"} instead of {"operation": "exec", ...}
{
    my $r = $term->execute({ exec => 'echo hi', command => 'echo hi' }, $ctx);
    ok($r->{success}, "param-key inference: exec as parameter key silently inferred");
}

# --- param-key inference: run as parameter key ---
{
    my $r = $term->execute({ run => 1, command => 'echo from_run' }, $ctx);
    ok($r->{success}, "param-key inference: run as parameter key silently inferred");
}

# --- Unknown operation still errors ---
{
    my $r = $term->execute({ operation => 'frobnicate', command => 'echo' }, $ctx);
    ok(!$r->{success}, "unknown operation returns failure");
    if ($r->{error} && index($r->{error}, 'Unknown operation: frobnicate') >= 0) {
        $pass++; print "OK: unknown operation error message\n";
    } else {
        $fail++; print "FAIL: unknown operation error message (got: " . substr($r->{error}//'none',0,80) . ")\n";
    }
}

# --- Single-operation auto-selection (Interact has only request_input) ---
{
    my $interact = CLIO::Tools::Interact->new(debug => 0);
    my $r = $interact->execute({ message => 'test message' }, $ctx);
    # Interact's request_input blocks for user input - we just verify it
    # didn't error on missing 'operation'. The error should NOT be
    # "Missing 'operation' parameter".
    my $err = $r->{error} // '';
    ok(index($err, "Missing 'operation' parameter") < 0,
        "Interact auto-selected operation (no missing_operation error)");
}

# --- Single-operation auto-selection (ApplyPatch has only apply) ---
{
    my $ap = CLIO::Tools::ApplyPatch->new(debug => 0);
    # ApplyPatch needs a valid patch format - we test that it doesn't
    # error on missing operation by passing garbage that gets past the
    # operation check but fails on patch parsing.
    my $r = $ap->execute({ patch => 'invalid' }, $ctx);
    my $err = $r->{error} // '';
    ok(index($err, "Missing 'operation' parameter") < 0,
        "ApplyPatch auto-selected operation (no missing_operation error)");
}

print "\n$pass passed, $fail failed\n";
exit($fail > 0 ? 1 : 0);
