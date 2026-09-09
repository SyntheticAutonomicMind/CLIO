#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test: TodoStore exposes a set_invalidation_hook and fires it
# on write/add/update (not read). The live prompt path now refreshes the
# dynamic userContext per-iteration via the ContextBuilder projection
# (MessageHistory::messages_to_prose_dynamic), so it no longer depends on
# this hook - but TodoStore keeps the mechanism as general-purpose
# infrastructure for any subscriber.
#
# Tests 1-3 + Test 6 verify the hook still exists and fires correctly.
# Tests 4-5 (unlike) guard against the old PromptBuilder _user_context_cache
# machinery - which cached get_user_context() for 60s and subscribed to
# this hook - being re-introduced. That cache was removed in the
# role-based history refactor: the model now sees fresh todo state every
# iteration without a 60s stale-cache window.

use strict;
use warnings;
use utf8;
use lib '/home/deck/repositories/CLIO/lib';
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Test::More;
use File::Temp qw(tempdir);

# ── Test 1: TodoStore exposes set_invalidation_hook ───────────────────
{
    my $src = do { local $/; open my $fh, '<', 'lib/CLIO/Session/TodoStore.pm' or die "open: $!"; <$fh> };
    like($src, qr/sub set_invalidation_hook/,
         'TodoStore exposes set_invalidation_hook');
    like($src, qr/sub _fire_invalidation/,
         'TodoStore has _fire_invalidation helper');
    like($src, qr/\$self->\{_on_invalidate\}/,
         'TodoStore stores the invalidation callback in _on_invalidate');
}

# ── Test 2: write/add/update all fire the hook after successful save ──
{
    my $src = do { local $/; open my $fh, '<', 'lib/CLIO/Session/TodoStore.pm' or die "open: $!"; <$fh> };
    # Count occurrences of _fire_invalidation() in TodoStore.pm
    my $count = () = $src =~ /_fire_invalidation\(\)/g;
    cmp_ok($count, '>=', 3,
           'write, add, and update all fire _fire_invalidation after a successful save (>=3 call sites, found ' . $count . ')');
}

# ── Test 3: read does NOT fire the hook (read is a query, not mutation) ─
{
    my $src = do { local $/; open my $fh, '<', 'lib/CLIO/Session/TodoStore.pm' or die "open: $!"; <$fh> };
    # sub read { ... } should NOT contain _fire_invalidation.
    # Extract sub read block: from "sub read {" up to the matching "}".
    # We use a simple non-greedy match against the next "sub " boundary
    # which is sufficient for this assertion.
    if ($src =~ /(sub read \{[^{}]*\{[^{}]*\}[^{}]*?\n\})/s) {
        my $read_block = $1;
        unlike($read_block, qr/_fire_invalidation/,
               'sub read does NOT fire the invalidation hook (read is a query)');
    } else {
        # Fallback: any _fire_invalidation in the file is fine, just
        # confirm that within the first 50 lines of source (which is
        # where sub read lives) there is no _fire_invalidation.
        my @first_50 = split /\n/, $src, 51;
        pop @first_50;  # discard trailing portion
        my $first_chunk = join("\n", @first_50);
        unlike($first_chunk, qr/_fire_invalidation/,
               'sub read (early in file) does NOT fire the invalidation hook');
    }
}

# ── Test 4: PromptBuilder no longer carries the user_context cache ────
# The role-based pipeline renders the dynamic userContext via
# ContextBuilder::build_projection + MessageHistory::messages_to_prose_dynamic
# per turn, so the old PromptBuilder user_context cache (and its TodoStore
# invalidation subscription in _read_active_todos) are gone. These unlike
# assertions guard against the dead cache machinery being re-introduced.
{
    my $src = do { local $/; open my $fh, '<', 'lib/CLIO/Core/PromptBuilder.pm' or die "open: $!"; <$fh> };
    # Note: _user_context_cache (per-minute TTL cache for CWD/Date/Lang)
    # is INTENTIONALLY kept — it provides byte stability by preventing
    # the date/time from changing between API calls within the same
    # minute. The invalidation hook (set_invalidation_hook) was removed,
    # but the cache itself remains.
    unlike($src, qr/set_invalidation_hook/,
         'PromptBuilder no longer subscribes to TodoStore invalidation');
}

# ── Test 5: session-scoped cache tracking is gone ─────────────────────
{
    my $src = do { local $/; open my $fh, '<', 'lib/CLIO/Core/PromptBuilder.pm' or die "open: $!"; <$fh> };
    unlike($src, qr/_user_context_cache_session_id/,
         'PromptBuilder no longer tracks _user_context_cache_session_id');
    unlike($src, qr/cache_mismatch/,
         'PromptBuilder no longer has cache_mismatch logic');
}

# ── Test 6: Functional - end-to-end invalidation through real TodoStore ─
{
    use CLIO::Session::TodoStore;

    my $tmpdir = tempdir(CLEANUP => 1);
    my $session_id = "test-session-" . $$ . "-" . time();
    my $store = CLIO::Session::TodoStore->new(
        session_id => $session_id,
        sessions_dir => $tmpdir,
    );

    my $invalidations = 0;
    my $last_callback_self;
    $store->set_invalidation_hook(sub {
        my ($self) = @_;
        $invalidations++;
        $last_callback_self = $self;
    });

    # write fires the hook
    my ($ok) = $store->write([
        { title => "Task 1", description => "first", status => "in-progress" },
    ]);
    ok($ok, 'write succeeded');
    is($invalidations, 1, 'write fires the hook (1 invalidation)');
    is($last_callback_self, $store, 'hook receives $self');

    # add fires the hook
    ($ok) = $store->add([
        { title => "Task 2", description => "second", status => "not-started" },
    ]);
    ok($ok, 'add succeeded');
    is($invalidations, 2, 'add fires the hook (2 invalidations)');

    # update fires the hook
    ($ok, my $result) = $store->update([
        { id => 1, status => "completed" },
    ]);
    ok($ok, 'update succeeded');
    is($invalidations, 3, 'update fires the hook (3 invalidations)');

    # read does NOT fire the hook
    my $todos = $store->read();
    is(scalar @$todos, 2, 'read returns 2 todos');
    is($invalidations, 3, 'read does NOT fire the hook (still 3)');

    # Setting hook to undef disables it
    $store->set_invalidation_hook(undef);
    ($ok) = $store->write([
        { title => "Task 3", description => "third", status => "in-progress" },
    ]);
    ok($ok, 'write after clearing hook succeeded');
    is($invalidations, 3, 'No more invalidations after clearing hook');
}

done_testing();
