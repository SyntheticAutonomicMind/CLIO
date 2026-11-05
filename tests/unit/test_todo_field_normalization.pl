#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

# Test: TodoList silently normalizes the todo array when the model sends
# it under the wrong field name.
#
# The model frequently confuses the three array field names (todoList,
# newTodos, todoUpdates) and sends the array under a different key than
# the operation expects - e.g. sending 'newTodos' or 'content' for a
# 'write' operation. Without normalization this produces a hard
# "Missing required parameter" failure that the model cannot learn from.
#
# This test verifies that handle_write, handle_add, and handle_update
# each accept the array under any of the known field names and route it
# to the canonical key, while still preferring a legitimately-supplied
# canonical value when both are present.

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

my $session_id = "test-field-norm-" . $$ . "-" . time();
my $ctx = { session => { session_id => $session_id, id => $session_id } };

my $tool = CLIO::Tools::TodoList->new(debug => 0);

sub cleanup {
    my $sessions_dir = CLIO::Util::PathResolver::get_sessions_dir();
    my $session_dir  = File::Spec->catdir($sessions_dir, $session_id);
    remove_tree($session_dir) if -d $session_dir;
}

# ── write: accepts newTodos ────────────────────────────────────────────
{
    my $r = $tool->execute({
        operation => 'write',
        newTodos  => [
            { title => 'Write via newTodos', description => 'desc', status => 'not-started' },
        ],
    }, $ctx);
    ok($r->{success}, "write accepts 'newTodos' as the array key");
    is($r->{error}, undef, "write via newTodos has no error");
}

# ── write: accepts content ─────────────────────────────────────────────
{
    my $r = $tool->execute({
        operation => 'write',
        content   => [
            { title => 'Write via content', description => 'desc', status => 'not-started' },
        ],
    }, $ctx);
    ok($r->{success}, "write accepts 'content' as the array key");
    is($r->{error}, undef, "write via content has no error");
}

# ── write: accepts todos ───────────────────────────────────────────────
{
    my $r = $tool->execute({
        operation => 'write',
        todos     => [
            { title => 'Write via todos', description => 'desc', status => 'not-started' },
        ],
    }, $ctx);
    ok($r->{success}, "write accepts 'todos' as the array key");
}

# ── write: canonical todoList still works ──────────────────────────────
{
    my $r = $tool->execute({
        operation => 'write',
        todoList  => [
            { title => 'Write canonical', description => 'desc', status => 'not-started' },
        ],
    }, $ctx);
    ok($r->{success}, "write still works with canonical 'todoList'");
}

# ── write: canonical wins when both present ────────────────────────────
{
    my $r = $tool->execute({
        operation => 'write',
        todoList  => [
            { title => 'Winner', description => 'canonical', status => 'not-started' },
        ],
        content   => [
            { title => 'Loser', description => 'wrong key', status => 'not-started' },
        ],
    }, $ctx);
    ok($r->{success}, "write succeeds when both canonical and wrong key present");
    # handle_write does not return the todo list in its result; read it
    # back to verify the canonical value survived (not the wrong-key one).
    my $rr = $tool->execute({ operation => 'read' }, $ctx);
    my $todos = $rr->{todos} || [];
    my $titles = join('|', map { $_->{title} } @$todos);
    like($titles, qr/Winner/, "canonical 'Winner' is in the stored list");
    unlike($titles, qr/Loser/, "wrong-key 'Loser' is NOT in the stored list (canonical won)");
}

# ── add: accepts todoList instead of newTodos ──────────────────────────
{
    my $r = $tool->execute({
        operation => 'add',
        todoList  => [
            { title => 'Add via todoList', description => 'desc' },
        ],
    }, $ctx);
    ok($r->{success}, "add accepts 'todoList' as the array key (instead of newTodos)");
}

# ── add: accepts todos ─────────────────────────────────────────────────
{
    my $r = $tool->execute({
        operation => 'add',
        todos     => [
            { title => 'Add via todos', description => 'desc' },
        ],
    }, $ctx);
    ok($r->{success}, "add accepts 'todos' as the array key");
}

# ── update: accepts todoList instead of todoUpdates ────────────────────
{
    # First write a todo so we have an id=1 to update.
    $tool->execute({
        operation => 'write',
        todoList  => [
            { title => 'Update target', description => 'desc', status => 'not-started' },
        ],
    }, $ctx);

    my $r = $tool->execute({
        operation => 'update',
        todoList  => [
            { id => 1, status => 'completed' },
        ],
    }, $ctx);
    ok($r->{success}, "update accepts 'todoList' as the array key (instead of todoUpdates)");
}

# ── update: accepts updates ────────────────────────────────────────────
{
    my $r = $tool->execute({
        operation => 'update',
        updates   => [
            { id => 1, status => 'in-progress' },
        ],
    }, $ctx);
    ok($r->{success}, "update accepts 'updates' as the array key");
}

# ── read: verify the round-trip ────────────────────────────────────────
{
    my $r = $tool->execute({ operation => 'read' }, $ctx);
    ok($r->{success}, "read succeeds after all the normalized writes/adds/updates");
    my $todos = $r->{todos} || [];
    ok(@$todos >= 1, "read returns at least 1 todo");
    # The first todo should be 'Update target' (from the write above) and
    # should now be 'in-progress' (from the update via 'updates' key).
    my ($first) = grep { $_->{id} && $_->{id} == 1 } @$todos;
    ok($first, "read returns the todo with id=1");
    is($first->{title}, 'Update target', "todo id=1 title is 'Update target'");
    is($first->{status}, 'in-progress', "todo id=1 status is 'in-progress' (updated via wrong key)");
}

cleanup();
done_testing();
