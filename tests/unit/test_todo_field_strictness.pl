#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Tests for todo field-name strictness.
#
# Regression for a session that ended early: a model sent
# {"blockedReason': '...'}] if False else [{":""} - Python syntax inside a
# JSON argument. The stray quote started a runaway string that swallowed the
# rest of the payload, so the value became a KEY NAME and blockedReason never
# arrived. That parses as valid JSON, so nothing between the model and the tool
# reported it; the store then said "blocked but has no blockedReason", the
# model invented blockedReasonReason and blockedReasonReason2 trying to fix a
# spelling it could not see, and the error loop ended the turn.
#
# Two guarantees are pinned here:
#   1. A field name the schema does not define is rejected, and rejected
#      before anything is written.
#   2. The rejection names what arrived, so a mangled payload is visible.

use strict;
use warnings;
use utf8;
use lib './lib';

use Test::More;
use File::Temp qw(tempdir);
use CLIO::Session::TodoStore;
use CLIO::Tools::TodoList;

sub fresh_store {
    my $dir = tempdir(CLEANUP => 1);
    my $store = CLIO::Session::TodoStore->new(
        session_id   => 'field-test',
        sessions_dir => $dir,
        debug        => 0,
    );
    $store->write([
        { title => 'First',  description => 'one', status => 'not-started' },
        { title => 'Second', description => 'two', status => 'not-started' },
    ]);
    return $store;
}

subtest 'invented field names are rejected' => sub {
    my $store = fresh_store();

    my ($ok, $error) = $store->update([
        { id => 1, status => 'blocked', blockedReasonReason => 'because' },
    ]);

    ok(!$ok, 'update with an invented field is rejected');
    like($error, qr/unrecognized field/i, 'error says the field is unrecognized');
    like($error, qr/blockedReasonReason/, 'error names the invented field');
    like($error, qr/Allowed fields:/, 'error lists the fields that are accepted');
    like($error, qr/blockedReason\b/, 'the accepted list includes the real field name');

    my ($todo) = grep { $_->{id} == 1 } @{ $store->read() };
    is($todo->{status}, 'not-started', 'the rejected update did not change the todo');
    ok(!exists $todo->{blockedReasonReason}, 'the invented field was not persisted');
};

subtest 'a field name with stray characters is reported as malformed JSON' => sub {
    my $store = fresh_store();

    # What a stray quote in the arguments actually produces: one absurd key.
    my $mangled = "blockedReason': 'Architectural change'}] if False else [{\":\"";
    my ($ok, $error) = $store->update([
        { id => 1, status => 'blocked', $mangled => '' },
    ]);

    ok(!$ok, 'mangled field name is rejected');
    like($error, qr/not valid identifiers/i, 'error identifies it as a bad identifier');
    like($error, qr/arguments JSON was malformed/i, 'error names the real cause');
    like($error, qr/value was parsed as a key/i, 'error explains how it happened');

    my ($todo) = grep { $_->{id} == 1 } @{ $store->read() };
    ok(!exists $todo->{$mangled}, 'the mangled key was not persisted');
};

subtest 'a trailing space in a field name is caught' => sub {
    my $store = fresh_store();

    my ($ok, $error) = $store->update([
        { id => 1, status => 'blocked', 'blockedReason ' => 'because' },
    ]);

    ok(!$ok, 'trailing space is not accepted as blockedReason');
    like($error, qr/unrecognized field/i, 'error says the field is unrecognized');
    like($error, qr/not valid identifiers/i, 'error flags the stray character');
};

subtest 'a correct blocked update still works' => sub {
    my $store = fresh_store();

    my ($ok, $result) = $store->update([
        { id => 1, status => 'blocked', blockedReason => 'waiting on a decision' },
    ]);

    ok($ok, 'a well-formed update is accepted');
    my ($todo) = grep { $_->{id} == 1 } @{ $store->read() };
    is($todo->{status}, 'blocked', 'status applied');
    is($todo->{blockedReason}, 'waiting on a decision', 'reason stored');
};

subtest 'a rejected update changes nothing at all' => sub {
    my $store = fresh_store();

    # The first item is valid, the second is not. A partial application would
    # leave the list in a state the caller never asked for.
    my ($ok) = $store->update([
        { id => 1, status => 'completed' },
        { id => 2, status => 'blocked', bogusField => 1 },
    ]);

    ok(!$ok, 'the batch is rejected');
    my @todos = @{ $store->read() };
    my ($first) = grep { $_->{id} == 1 } @todos;
    is($first->{status}, 'not-started', 'the valid item was not applied either');
};

subtest 'write and add reject unknown fields' => sub {
    my $store = fresh_store();

    my ($wok, $werror) = $store->write([
        { title => 'Third', description => 'three', status => 'not-started', bogusField => 1 },
    ]);
    ok(!$wok, 'write rejects an unknown field');
    like($werror, qr/unrecognized field/i, 'write error names the problem');
    is(scalar @{ $store->read() }, 2, 'the rejected write left the list intact');

    my ($aok, $aerror) = $store->add([
        { title => 'Fourth', description => 'four', bogusField => 1 },
    ]);
    ok(!$aok, 'add rejects an unknown field');
    like($aerror, qr/unrecognized field/i, 'add error names the problem');
    is(scalar @{ $store->read() }, 2, 'the rejected add left the list intact');
};

subtest 'blocked without a reason echoes the fields that did arrive' => sub {
    my $store = fresh_store();

    # The mangled-payload symptom: blocked arrives, blockedReason does not.
    my ($ok, $error) = $store->update([
        { id => 1, status => 'blocked' },
    ]);

    ok(!$ok, 'blocked without a reason is rejected');
    like($error, qr/no blockedReason/, 'error names the missing field');
    like($error, qr/received fields:/i, 'error echoes what did arrive');
    like($error, qr/status/, 'the echo lists the fields the parser saw');
};

subtest 'the tool surface advertises the rejected-field rule' => sub {
    my $tool = CLIO::Tools::TodoList->new(debug => 0);
    my $defs = $tool->get_operation_tool_definitions();

    my $update_items = $defs->{update}{properties}{todoUpdates}{items};
    ok(exists $update_items->{additionalProperties},
        'todoUpdates items declare additionalProperties');
    ok(!$update_items->{additionalProperties},
        'unknown properties are disallowed in the schema');

    my $reason = $update_items->{properties}{blockedReason}{description};
    like($reason, qr/REQUIRED when status=blocked/,
        'blockedReason says it is required when the todo is blocked');
    unlike($reason, qr/^\[OPTIONAL\]/,
        'blockedReason is not advertised as merely optional');

    for my $op (qw(write add)) {
        my ($key) = grep { $defs->{$op}{properties}{$_} } @{ [ keys %{ $defs->{$op}{properties} } ] };
        my $items = $defs->{$op}{properties}{$key}{items};
        ok(exists $items->{additionalProperties},
            "$op items declare additionalProperties");
    }
};

done_testing();
