#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test: TodoStore must not emit "Argument isn't numeric in
# numeric gt" warnings when a stored todo has a non-numeric id (e.g.
# the model assigned "5b" by mistake). It also must not crash and
# must continue to assign fresh numeric ids to the bad record.
#
# Bug discovered 2026-09-02 during this session: I created a todo
# via todo_operations(operation: "write", todoList: [{... id: 8, ...}])
# and TodoStore::write line 180 emitted
#   Argument "5b" isn't numeric in numeric gt (>) at ...TodoStore.pm line 180
# even though my todo id was an integer (the "5b" came from the
# todo_operations tool reassigning my id to a temporary slot during
# the write call). The root cause: the call sites at TodoStore.pm
# 180, 277, 350 compare $todo->{id} > $max_id (or == $todo_id)
# without verifying id is a positive integer. A corrupt or out-of-shape
# stored id triggers Perl's numeric compare warning on every read.
#
# Fix: a small _is_valid_id helper guards all three sites. A corrupt
# id is treated as if the todo had no id at all and gets re-assigned
# a fresh sequential one on the next write.

use strict;
use warnings;
use utf8;
use lib './lib';

use Test::More;
use File::Temp qw(tempdir);
use CLIO::Session::TodoStore;

# Capture warnings so the test fails on any numeric-compare warning.
my @warnings;
local $SIG{__WARN__} = sub {
    push @warnings, $_[0];
};

subtest 'write/read cycle with corrupt id does not warn or crash' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    my $store = CLIO::Session::TodoStore->new(
        session_id => 'corrupt-id-test',
        sessions_dir => $tmp,
    );

    # Plant a corrupt id in a fresh store. Simulates the situation
    # that produced the original warning: stored data has a non-numeric
    # id (e.g. "5b") that the scanner tries to compare numerically.
    my @todos = (
        { id => 1,    title => 't1', description => 'd1', status => 'completed' },
        { id => '5b', title => 't2', description => 'd2', status => 'not-started' },
        { id => 3,    title => 't3', description => 'd3', status => 'completed' },
    );

    my @pre_warnings = @warnings;
    my ($ok, $err) = $store->write(\@todos);
    ok($ok, 'write succeeded with corrupt id in input') or diag("err: $err");

    my $loaded = $store->read();
    is(scalar(@$loaded), 3, 'read returned all 3 todos');

    # The bad id should have been re-assigned a fresh numeric id.
    my ($corrupt) = grep { $_->{title} eq 't2' } @$loaded;
    ok(defined $corrupt, 'corrupt-id todo still present after re-assign');
    ok(defined $corrupt->{id} && $corrupt->{id} =~ /^\d+$/,
        'corrupt id was re-assigned a positive integer')
        or diag("got id=" . ($corrupt->{id} // 'undef'));

    # The good ids should be preserved.
    my ($t1) = grep { $_->{title} eq 't1' } @$loaded;
    my ($t3) = grep { $_->{title} eq 't3' } @$loaded;
    is($t1->{id}, 1, 'first valid id preserved');
    is($t3->{id}, 3, 'third valid id preserved');

    # No new "isn't numeric" warnings from lib/CLIO/ code.
    # Filter: Test::Builder under perl -W emits its own "isn't
    # numeric" warnings (Test/Builder.pm:687 does numeric addition
    # on the test description strings). Those are framework noise
    # and not from the code under test. The same filter pattern is
    # used in test_token_ratio_clamp.pl.
    my @new_warnings = @warnings[@pre_warnings .. $#warnings];
    my $numeric_warnings = grep {
        /isn'?t numeric/i
            && !/Test\/Builder\.pm/
            && !/Test2\//
    } @new_warnings;
    is($numeric_warnings, 0, 'no "isn\'t numeric" warnings from CLIO code on write')
        or diag("warnings from our code: " . join("\n", grep { /isn'?t numeric/i && !/Test\// && !/Test2\// } @new_warnings));
};

subtest 'read of an already-corrupt on-disk file does not warn' => sub {
    # Plant a corrupt file on disk directly (bypassing write() so we
    # test the read path independently). This mirrors a file that was
    # written by a buggy older version of TodoStore and now lives on
    # disk. The read path must not warn on every call.
    my $tmp = tempdir(CLEANUP => 1);
    my $session_id = 'corrupt-on-disk-' . int(rand(1_000_000));
    my $store = CLIO::Session::TodoStore->new(
        session_id => $session_id,
        sessions_dir => $tmp,
    );

    # Manually plant a corrupt todos file (bypassing write() so we
    # test the read path independently). This mirrors a file that
    # was written by a buggy older version of TodoStore and now lives
    # on disk. The read path must not warn on every call.
    # (TodoStore::new already created the session dir, so we just
    # write the file directly.)
    my $session_dir = $store->_session_dir();
    require CLIO::Util::JSON;
    my $corrupt_data = {
        session_id => $session_id,
        todos => [
            { id => 1,    title => 'good',    description => 'd', status => 'completed' },
            { id => '5b', title => 'corrupt', description => 'd', status => 'not-started' },
        ],
        updatedAt => 1234567890,
    };
    my $json = CLIO::Util::JSON::encode_json_pretty($corrupt_data);
    open my $fh, '>:encoding(UTF-8)', "$session_dir/todos.json" or die "open: $!";
    print $fh $json;
    close $fh;

    my @pre_warnings = @warnings;
    my $loaded = $store->read();
    is(scalar(@$loaded), 2, 'read returned both todos from corrupt file');

    # Same Test::Builder noise filter as above - see comment there.
    my @new_warnings = @warnings[@pre_warnings .. $#warnings];
    my $numeric_warnings = grep {
        /isn'?t numeric/i
            && !/Test\/Builder\.pm/
            && !/Test2\//
    } @new_warnings;
    is($numeric_warnings, 0, 'no "isn\'t numeric" warnings from CLIO code on read')
        or diag("warnings from our code: " . join("\n", grep { /isn'?t numeric/i && !/Test\// && !/Test2\// } @new_warnings));
};

done_testing();
