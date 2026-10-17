#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

# Test: TodoList tool accepts 'list' as a silent operation alias for 'read'.
#
# The model naturally emits operation="list" (the universal verb for
# "enumerate a collection") when it wants to see the current todo list.
# CLIO's convention (matching FileOperations, TerminalOperations) is to keep
# canonical names in the schema enum but silently accept common natural-language
# aliases at dispatch via operation_aliases + the dispatch table. This test
# verifies that 'list' is wired through that same mechanism and behaves
# identically to 'read'.

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use File::Basename qw(dirname);
use File::Spec;
use File::Path qw(remove_tree);
use Cwd qw(abs_path);

my $repo_root = abs_path(dirname(dirname(dirname($0))));
$repo_root = abs_path('.') unless -d "$repo_root/lib";
unshift @INC, "$repo_root/lib";

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Test::More;
use CLIO::Tools::TodoList;
use CLIO::Util::PathResolver;

# Use a unique session id so we never collide with real sessions, and
# so we can clean up the session dir the tool creates.
my $session_id = "test-list-alias-" . $$ . "-" . time();
my $ctx = { session => { session_id => $session_id, id => $session_id } };

my $tool = CLIO::Tools::TodoList->new(debug => 0);

# ── 1. 'list' is a recognized operation (passes validate_operation) ─────
ok($tool->validate_operation('list'),
   "validate_operation('list') returns true - alias is accepted at dispatch");

# ── 2. 'list' routes to the same dispatcher as 'read' ──────────────────
my $table = $tool->dispatch_table();
is($table->{list}, $table->{read},
   "dispatch_table('list') is the same handler as 'read' (_dispatch_read)");

# ── 3. 'list' in the operation_aliases list ─────────────────────────────
my $aliases = $tool->{operation_aliases} || [];
ok(grep { $_ eq 'list' } @$aliases,
   "'list' is present in operation_aliases");

# 'list' should NOT be in the schema enum (canonical names only — same
# convention as FileOperations, so the model is nudged toward 'read').
my $def = $tool->get_tool_definition();
my @enum = @{$def->{parameters}{properties}{operation}{enum}};
ok(!grep { $_ eq 'list' } @enum,
   "'list' is NOT in the schema enum (canonical names only)");
ok(grep { $_ eq 'read' } @enum,
   "'read' remains in the schema enum");

# ── 4. Full execute(): operation='list' succeeds ───────────────────────
# A fresh session has no todos, so handle_read returns a success result
# with the "No todos yet" message. If 'list' were NOT routed correctly,
# we'd get an error instead.
{
    my $r = $tool->execute({ operation => 'list' }, $ctx);
    ok($r->{success}, "execute: operation='list' succeeds (routed to handle_read)");
    like($r->{output}, qr/todo list|No todos/i,
         "execute: operation='list' returns todo-list output, not an error");
}

# ── 5. Full execute(): operation='read' still works (regression) ────────
{
    my $r = $tool->execute({ operation => 'read' }, $ctx);
    ok($r->{success}, "execute: operation='read' still succeeds (regression guard)");
}

# ── 6. 'list' and 'read' are interchangeable ───────────────────────────
{
    my $r_list  = $tool->execute({ operation => 'list' },  $ctx);
    my $r_read  = $tool->execute({ operation => 'read' },  $ctx);
    is($r_list->{action_description}, $r_read->{action_description},
       "execute: 'list' and 'read' produce the same action_description");
}

# ── 7. Unknown operation still errors ────────────────────────────────────
{
    my $r = $tool->execute({ operation => 'frobnicate' }, $ctx);
    ok(!$r->{success}, "execute: unknown operation 'frobnicate' fails");
    like($r->{error}, qr/unknown operation|Unknown operation/i,
         "execute: unknown operation error surfaces clearly");
}

# ── 8. 'read' is still the default for the write-with-todoList path ─────
# Confirm we haven't broken the primary operations: write still creates a
# list, then 'list' reads it back. This is the round-trip the model
# actually benefits from.
{
    my $r = $tool->execute({
        operation => 'write',
        todoList  => [
            { title => 'Alias test task', description => 'created via write', status => 'not-started' },
        ],
    }, $ctx);
    ok($r->{success}, "write creates a todo (round-trip setup)");
}

{
    my $r = $tool->execute({ operation => 'list' }, $ctx);
    ok($r->{success}, "execute: 'list' reads back a written todo");
    like($r->{output}, qr/Alias test task/,
         "execute: 'list' returns the todo written by 'write'");
    my $todos = $r->{todos} || [];
    is(scalar @$todos, 1, "execute: 'list' returns 1 todo (matches what write created)");
    is($todos->[0]{title}, 'Alias test task', "execute: 'list' todo title matches");
}

# ── Cleanup: remove the session dir we created ──────────────────────────
my $sessions_dir = CLIO::Util::PathResolver::get_sessions_dir();
my $session_dir  = File::Spec->catdir($sessions_dir, $session_id);
if (-d $session_dir) {
    remove_tree($session_dir);
}

done_testing();
