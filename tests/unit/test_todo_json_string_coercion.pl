#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

# Test: TodoList silently coerces JSON-encoded array strings into arrays.
#
# Local models (llama.cpp, ollama, etc.) sometimes serialize array
# parameters as escaped JSON strings instead of native JSON arrays, e.g.:
#   "todoList": "[{\"title\":\"...\",...}]"
# instead of:
#   "todoList": [{"title":"...",...}]
#
# Without coercion this produces "'todoList' must be an array" which the
# model cannot learn from -- it just retries the same string form. This
# test verifies that handle_write, handle_add, and handle_update each
# accept JSON-encoded array strings and decode them transparently, for
# both the canonical key and wrong-key scenarios.

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

my $session_id = "test-json-coerce-" . $$ . "-" . time();
my $ctx = { session => { session_id => $session_id, id => $session_id } };

my $tool = CLIO::Tools::TodoList->new(debug => 0);

sub cleanup {
    my $sessions_dir = CLIO::Util::PathResolver::get_sessions_dir();
    my $session_dir  = File::Spec->catdir($sessions_dir, $session_id);
    remove_tree($session_dir) if -d $session_dir;
}

# ── write: JSON string in canonical todoList ───────────────────────────
{
    my $json_str = q([{"title":"Write via JSON string","description":"desc","status":"not-started"}]);
    my $r = $tool->execute({
        operation => 'write',
        todoList  => $json_str,
    }, $ctx);
    ok($r->{success}, "write accepts JSON-encoded string in 'todoList'");
    is($r->{error}, undef, "write via JSON string has no error");
}

# ── write: JSON string in wrong key (newTodos) ─────────────────────────
{
    my $json_str = q([{"title":"Wrong key JSON string","description":"desc","status":"not-started"}]);
    my $r = $tool->execute({
        operation => 'write',
        newTodos  => $json_str,
    }, $ctx);
    ok($r->{success}, "write accepts JSON-encoded string in 'newTodos' (wrong key)");
}

# ── write: JSON string in wrong key (content) ──────────────────────────
{
    my $json_str = q([{"title":"Content JSON string","description":"desc","status":"not-started"}]);
    my $r = $tool->execute({
        operation => 'write',
        content   => $json_str,
    }, $ctx);
    ok($r->{success}, "write accepts JSON-encoded string in 'content' (wrong key)");
}

# ── write: JSON string with multiple items ─────────────────────────────
{
    my $json_str = q([{"title":"Multi 1","description":"d1","status":"not-started"},{"title":"Multi 2","description":"d2","status":"not-started"}]);
    my $r = $tool->execute({
        operation => 'write',
        todoList  => $json_str,
    }, $ctx);
    ok($r->{success}, "write accepts JSON-encoded string with multiple items");
    my $rr = $tool->execute({ operation => 'read' }, $ctx);
    my $todos = $rr->{todos} || [];
    is(scalar @$todos, 2, "write via JSON string stored 2 items");
}

# ── add: JSON string in canonical newTodos ─────────────────────────────
{
    my $json_str = q([{"title":"Add via JSON string","description":"desc"}]);
    my $r = $tool->execute({
        operation => 'add',
        newTodos  => $json_str,
    }, $ctx);
    ok($r->{success}, "add accepts JSON-encoded string in 'newTodos'");
}

# ── add: JSON string in wrong key (todoList) ───────────────────────────
{
    my $json_str = q([{"title":"Add via wrong key JSON","description":"desc"}]);
    my $r = $tool->execute({
        operation => 'add',
        todoList  => $json_str,
    }, $ctx);
    ok($r->{success}, "add accepts JSON-encoded string in 'todoList' (wrong key)");
}

# ── update: JSON string in canonical todoUpdates ───────────────────────
{
    # First write a todo so we have an id=1 to update.
    $tool->execute({
        operation => 'write',
        todoList  => [
            { title => 'Update target', description => 'desc', status => 'not-started' },
        ],
    }, $ctx);

    my $json_str = q([{"id":1,"status":"completed"}]);
    my $r = $tool->execute({
        operation => 'update',
        todoUpdates => $json_str,
    }, $ctx);
    ok($r->{success}, "update accepts JSON-encoded string in 'todoUpdates'");
}

# ── update: JSON string in wrong key (todoList) ────────────────────────
{
    my $json_str = q([{"id":1,"status":"in-progress"}]);
    my $r = $tool->execute({
        operation => 'update',
        todoList  => $json_str,
    }, $ctx);
    ok($r->{success}, "update accepts JSON-encoded string in 'todoList' (wrong key)");
}

# ── write: non-JSON string still produces proper error ─────────────────
{
    my $r = $tool->execute({
        operation => 'write',
        todoList  => 'this is not json',
    }, $ctx);
    ok(!$r->{success}, "write with non-JSON string fails (as expected)");
    like($r->{error}, qr/must be an array|Missing required/, "non-JSON string produces proper error");
}

# ── write: empty string still produces proper error ────────────────────
{
    my $r = $tool->execute({
        operation => 'write',
        todoList  => '',
    }, $ctx);
    ok(!$r->{success}, "write with empty string fails (as expected)");
}

# ── write: JSON object string (not array) is NOT coerced ───────────────
{
    my $json_str = q({"title":"Single object","description":"desc","status":"not-started"});
    my $r = $tool->execute({
        operation => 'write',
        todoList  => $json_str,
    }, $ctx);
    ok(!$r->{success}, "write with JSON object string (not array) fails (as expected)");
    like($r->{error}, qr/must be an array|Missing required/, "JSON object string produces proper error");
}

# ── read: verify the round-trip ────────────────────────────────────────
{
    my $r = $tool->execute({ operation => 'read' }, $ctx);
    ok($r->{success}, "read succeeds after all the JSON-string writes/adds/updates");
    my $todos = $r->{todos} || [];
    ok(@$todos >= 1, "read returns at least 1 todo");
    my ($first) = grep { $_->{id} && $_->{id} == 1 } @$todos;
    ok($first, "read returns the todo with id=1");
    is($first->{status}, 'in-progress', "todo id=1 status is 'in-progress' (updated via JSON string)");
}

cleanup();
done_testing();