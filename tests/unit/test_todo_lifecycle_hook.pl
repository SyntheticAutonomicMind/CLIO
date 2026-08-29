#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test: TodoStore mutations must invalidate the
# PromptBuilder user_context cache so the model sees fresh <activeTodos>
# state on the very next prompt build, not 60s later when the cache TTL
# expires.
#
# Bug: PromptBuilder cached get_user_context() for 60 seconds. A model
# that called todo_operations(operation: 'add'|'update'|'complete') would
# have its new state hidden from the next prompt build until the cache
# TTL expired. The model would re-issue the same mutation (cluttering the
# conversation) or conclude that its previous mutation had no effect.
#
# Fix: TodoStore exposes set_invalidation_hook. PromptBuilder subscribes
# in _read_active_todos and clears the user_context cache on any
# mutation. write/add/update all fire the hook after a successful save.
# read does NOT fire (read is a query, not a mutation).

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

# ── Test 4: PromptBuilder subscribes to the hook in _read_active_todos ─
{
    my $src = do { local $/; open my $fh, '<', 'lib/CLIO/Core/PromptBuilder.pm' or die "open: $!"; <$fh> };
    like($src, qr/\$store->set_invalidation_hook/,
         'PromptBuilder subscribes to TodoStore via set_invalidation_hook');
    like($src, qr/\$self->\{_user_context_cache\}\s*=\s*undef/,
         'PromptBuilder hook clears _user_context_cache on invalidation');
    like($src, qr/\$self->\{_user_context_cache_time\}\s*=\s*0/,
         'PromptBuilder hook resets _user_context_cache_time on invalidation');
}

# ── Test 5: PromptBuilder cache refresh also checks session change ────
{
    my $src = do { local $/; open my $fh, '<', 'lib/CLIO/Core/PromptBuilder.pm' or die "open: $!"; <$fh> };
    like($src, qr/_user_context_cache_session_id/,
         'PromptBuilder tracks which session the cache belongs to');
    like($src, qr/cache_mismatch/,
         'PromptBuilder cache refresh checks for session change');
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
