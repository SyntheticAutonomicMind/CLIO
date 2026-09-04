#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test: _collect_unresolved_state must accept and use a
# $session argument so blocked todos surface as unresolved state.
#
# Bug: the previous version read $self->{_session}, which is never
# set anywhere in WorkflowOrchestrator. The TodoStore load always ran
# with session_id => undef and silently returned an empty array. The
# blocked-todo surfacing path was completely dead.
#
# Fix: signature changed to _collect_unresolved_state($self, $history,
# $session). Call sites pass $session explicitly. This test exercises
# the fix end-to-end through the public method.

use strict;
use warnings;
use utf8;
use lib './lib';

use Test::More;
use File::Temp qw(tempdir);
use CLIO::Session::TodoStore;

# Set up a fake .clio directory with sessions subdir (puppeteer-child
# layout). Without this the TodoStore constructor reads from <cwd>/
# sessions/<id>/todos.json which is empty for tests/.
my $tmp = tempdir(CLEANUP => 1);
my $fake_clio = "$tmp/.clio";
mkdir $fake_clio or die "Cannot create $fake_clio: $!";
my $sessions_dir = "$fake_clio/sessions";
mkdir $sessions_dir or die "Cannot create $sessions_dir: $!";

my $session_id = 'test-unresolved-blocked';
my $store = CLIO::Session::TodoStore->new(
    sessions_dir => $sessions_dir,
    session_id   => $session_id,
);

# Write a mix of todos: blocked, in-progress, completed. Only the
# blocked one should surface as unresolved state.
$store->write([
    {
        title         => 'Investigate trim bug',
        description   => 'The model keeps losing context after aggressive trims.',
        status        => 'blocked',
        blockedReason => 'Cannot reproduce without a long session fixture.',
    },
    {
        title       => 'Add projection tests',
        description => 'Cover the resume fast path and pin behavior.',
        status      => 'in-progress',
    },
    {
        title       => 'Set up harness',
        description => 'Already done.',
        status      => 'completed',
    },
]);

# Build a minimal session object that WorkflowOrchestrator accepts.
package FakeSession;
sub new { my ($cls, $id) = @_; bless { id => $id }, $cls; }
sub id { $_[0]->{id} }
sub can {
    my ($self, $method) = @_;
    return 1 if $method eq 'id';
    return 0;
}

package main;
my $session = FakeSession->new($session_id);

# Instantiate WorkflowOrchestrator's method without the heavyweight
# constructor.
require CLIO::Core::WorkflowOrchestrator;
my $wf = bless {}, 'CLIO::Core::WorkflowOrchestrator';

# Override PathResolver::find_clio_dir to return our fake clio dir.
require CLIO::Util::PathResolver;
{
    no warnings 'redefine';
    *CLIO::Util::PathResolver::find_clio_dir = sub { $fake_clio };
}

# Empty history - we only care about the blocked-todo path.
my @history;
my $unresolved = $wf->_collect_unresolved_state(\@history, $session);

ok(ref($unresolved) eq 'ARRAY', '_collect_unresolved_state returns arrayref');
ok(scalar(@$unresolved) >= 1, '_collect_unresolved_state finds the blocked todo (regression guard for BUG #1)');

# Find the blocked todo line specifically.
my ($blocked_line) = grep { defined && /blocked todo:.*Investigate trim bug/ } @$unresolved;
ok(defined $blocked_line, "blocked todo surface contains 'Investigate trim bug' title");
like($blocked_line, qr/Investigate trim bug/, "blocked todo surface includes title");
like($blocked_line, qr/model keeps losing context/, "blocked todo surface includes description");
like($blocked_line, qr/Cannot reproduce/, "blocked todo surface includes blockedReason");

# Defense: in-progress and completed todos should NOT appear.
my $has_in_progress = grep { defined && /Add projection tests/ } @$unresolved;
is($has_in_progress, 0, 'in-progress todo NOT surfaced as unresolved');
my $has_completed = grep { defined && /Set up harness/ } @$unresolved;
is($has_completed, 0, 'completed todo NOT surfaced as unresolved');

# Also: when no session is passed (legacy callers or tests), method
# should not crash. The blocked-todo branch is skipped (TodoStore load
# still happens but with session_id=undef, no blocked todos surface).
my $unresolved_no_session = $wf->_collect_unresolved_state(\@history, undef);
ok(ref($unresolved_no_session) eq 'ARRAY', 'No session arg still returns arrayref (no crash)');

done_testing();