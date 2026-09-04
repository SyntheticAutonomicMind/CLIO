#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test: _read_active_todos_for_projection must use the
# correct TodoStore field names AND the correct sessions_dir.
#
# Bugs B2 and B3:
#   - B2: the function read $todo->{content}, but TodoStore writes
#     title/description. Result: every todo's content was empty.
#   - B3: the function passed clio_dir to TodoStore, which silently
#     dropped it (TodoStore uses sessions_dir). Result: the store
#     read from <cwd>/sessions/<id>/todos.json regardless of where
#     the project actually stored todos.

use strict;
use warnings;
use utf8;
use lib './lib';

use Test::More;
use File::Temp qw(tempdir);
use CLIO::Session::TodoStore;

# Set up a fake .clio directory with a sessions subdir to simulate
# the puppeteer child project layout.
my $tmp = tempdir(CLEANUP => 1);
my $fake_clio = "$tmp/.clio";
mkdir $fake_clio or die "Cannot create $fake_clio: $!";
my $sessions_dir = "$fake_clio/sessions";
mkdir $sessions_dir or die "Cannot create $sessions_dir: $!";

my $session_id = 'test-b2-b3-session';
my $store = CLIO::Session::TodoStore->new(
    sessions_dir => $sessions_dir,
    session_id   => $session_id,
);

# Write a todo using TodoStore's documented schema (title + description)
$store->write([
    {
        title       => 'Fix the bug',
        description => 'Stop the messageHistory XML from leaking framework narration.',
        status      => 'in-progress',
    },
    {
        title       => 'Add tests',
        description => 'Coverage for tail walk, dedup, resume.',
        status      => 'pending',
    },
    {
        title       => 'Completed work',
        description => 'Already done.',
        status      => 'completed',
    },
]);

# Now invoke WorkflowOrchestrator's reader. We have to instantiate
# the method directly because WorkflowOrchestrator has heavyweight
# dependencies we don't want to spin up.
require CLIO::Core::WorkflowOrchestrator;
my $self = bless {}, 'CLIO::Core::WorkflowOrchestrator';

# Override PathResolver::find_clio_dir to return our fake clio dir
# so the function reads from $fake_clio/sessions, not the real CLIO cwd.
require CLIO::Util::PathResolver;
my $orig = \&CLIO::Util::PathResolver::find_clio_dir;
{
    no warnings 'redefine';
    *CLIO::Util::PathResolver::find_clio_dir = sub { $fake_clio };
}

# Mock the session object
package MockSession;
sub new { bless { id => $session_id }, shift }
sub id { $_[0]->{id} }

package main;
my $session = MockSession->new();

my $todos = $self->_read_active_todos_for_projection($session);

# Restore original
{
    no warnings 'redefine';
    *CLIO::Util::PathResolver::find_clio_dir = $orig;
}

# Bug B2: 3 todos were written; completed is excluded.
is(scalar(@$todos), 2,
    'Found 2 active todos (in-progress + pending), not 0 (B3 fix: correct sessions_dir)')
    or diag("Got: " . scalar(@$todos) . " todos");

# Bug B2 fix: content must NOT be empty. It should be the title (+ description).
my @by_status;
for my $t (@$todos) {
    push @by_status, $t->{status};
    like($t->{content}, qr/Fix the bug|Add tests/,
        "todo '$t->{status}' has title in content (B2 fix) - got: '$t->{content}'");
}

ok(grep { $_ eq 'in-progress' } @by_status, 'in-progress todo present');
ok((grep { $_ eq 'pending' || $_ eq 'not-started' } @by_status),
    'pending todo present (TodoStore normalizes pending -> not-started)');
ok(!grep { $_ eq 'completed' } @by_status, 'completed todo correctly filtered out');

# Backwards compat: if a record has 'content' (legacy) instead of title,
# the reader should still pick it up. TodoStore requires both title and
# description though, so we work around via direct file write.
$store->write([
    {
        title       => 'Legacy',
        description => 'Uses title',
        status      => 'in-progress',
    },
]);
# Manually patch the on-disk JSON to use `content` (legacy shape)
require File::Slurp;
my $json_file = "$sessions_dir/$session_id/todos.json";
my $data = {
    session_id => $session_id,
    todos      => [
        { content => 'Legacy todo with content field only', status => 'in-progress' },
    ],
};
require CLIO::Util::JSON;
my $json_text = CLIO::Util::JSON::encode_json_pretty($data);
open my $fh, '>', $json_file or die;
print $fh $json_text;
close $fh;

# Re-install override since the previous block restored $orig.
{
    no warnings 'redefine';
    *CLIO::Util::PathResolver::find_clio_dir = sub { $fake_clio };
}

my $todos2 = $self->_read_active_todos_for_projection($session);
{
    no warnings 'redefine';
    *CLIO::Util::PathResolver::find_clio_dir = $orig;
}
ok(@$todos2, 'Legacy todo with content field still readable')
    or diag("Got: " . scalar(@$todos2) . " todos");
is($todos2->[0]{content}, 'Legacy todo with content field only',
    'Legacy content field is honored as fallback')
    or diag("Got content: " . ($todos2->[0]{content} // 'undef'));

# Verify sessions_dir is actually used (B3 fix). If sessions_dir was
# wrong, we'd find zero todos even though TodoStore has them.
{
    no warnings 'redefine';
    *CLIO::Util::PathResolver::find_clio_dir = sub { $fake_clio };
}
$store = CLIO::Session::TodoStore->new(
    sessions_dir => $sessions_dir,
    session_id   => $session_id,
);
$store->write([
    {
        title       => 'In correct dir',
        description => 'Reachable',
        status      => 'in-progress',
    },
]);
my $todos3 = $self->_read_active_todos_for_projection($session);
is(scalar(@$todos3), 1,
    'TodoStore in puppeteer-child sessions_dir is reachable (B3 fix)');
is($todos3->[0]{content}, 'In correct dir: Reachable',
    'title from puppeteer-child sessions_dir is read correctly');

{
    no warnings 'redefine';
    *CLIO::Util::PathResolver::find_clio_dir = $orig;
}

done_testing();