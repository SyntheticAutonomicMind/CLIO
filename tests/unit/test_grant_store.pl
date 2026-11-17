#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

=head1 NAME

test_grant_store.pl - approval grants: one store, expiry, and resume

=head1 DESCRIPTION

Covers the GrantStore contract and the resume path that makes it useful:

- one table for every approval scope, with scope isolation
- expiry, so a grant restored from an old session does not answer a prompt
  the user has forgotten
- export/restore round-trip, including the rules for what is *not* restored:
  one-time path grants, expired grants, and path grants belonging to a
  different conversation
- a real session save/resume cycle: grants made before the save apply after
  the resume, and a new session starts with none

=cut

use strict;
use warnings;
use utf8;
use lib 'lib';
use Test::More;
use File::Temp qw(tempdir);

use CLIO::Security::GrantStore;
use CLIO::Session::Manager;

# Keep the whole test inside a temp HOME so session files never touch the
# developer's project data.
my $temp_dir = tempdir(CLEANUP => 1);
$ENV{HOME} = $temp_dir;
mkdir "$temp_dir/.clio" or die "Cannot create .clio dir: $!";
mkdir "$temp_dir/.clio/sessions" or die "Cannot create sessions dir: $!";

END { CLIO::Security::GrantStore::set_ttl_seconds(24 * 60 * 60) }

# ---------------------------------------------------------------------------
subtest 'grants are scoped and isolated' => sub {
    CLIO::Security::GrantStore::reset();

    ok(!CLIO::Security::GrantStore::is_granted('command', 'network_outbound'),
        'nothing is granted to begin with');

    CLIO::Security::GrantStore::grant('command', 'network_outbound');
    CLIO::Security::GrantStore::grant('web', 'fetch_url');

    ok(CLIO::Security::GrantStore::is_granted('command', 'network_outbound'),
        'command grant is readable');
    ok(CLIO::Security::GrantStore::is_granted('web', 'fetch_url'),
        'web grant is readable');
    ok(!CLIO::Security::GrantStore::is_granted('script', 'network_outbound'),
        'the same key in another scope is not granted');
    ok(!CLIO::Security::GrantStore::is_granted('command', 'credential_access'),
        'a sibling key in the same scope is not granted');

    is(CLIO::Security::GrantStore::count(), 2, 'two live grants');

    ok(CLIO::Security::GrantStore::revoke('command', 'network_outbound'),
        'revoke reports removal');
    ok(!CLIO::Security::GrantStore::revoke('command', 'network_outbound'),
        'revoking twice reports nothing removed');
    is(CLIO::Security::GrantStore::count(), 1, 'one grant left');

    is(CLIO::Security::GrantStore::reset_scope('web'), 1, 'scoped reset clears web');
    is(CLIO::Security::GrantStore::count(), 0, 'nothing left');
};

# ---------------------------------------------------------------------------
subtest 'grants expire by age' => sub {
    CLIO::Security::GrantStore::reset();
    CLIO::Security::GrantStore::set_ttl_seconds(3600);

    CLIO::Security::GrantStore::grant('command', 'fresh');
    ok(CLIO::Security::GrantStore::is_granted('command', 'fresh'), 'a new grant is live');

    CLIO::Security::GrantStore::grant('command', 'stale', granted_at => time() - 7200);
    ok(!CLIO::Security::GrantStore::is_granted('command', 'stale'),
        'a grant older than the TTL is not honoured');

    my @live = CLIO::Security::GrantStore::list_grants();
    is(scalar(@live), 1, 'only the live grant is listed');
    is($live[0]{key}, 'fresh', 'the live grant is the fresh one');

    my @all = CLIO::Security::GrantStore::list_grants(include_expired => 1);
    is(scalar(@all), 2, 'include_expired shows both');

    is(CLIO::Security::GrantStore::prune_expired(), 1, 'prune removes the stale grant');
    is(CLIO::Security::GrantStore::count(include_expired => 1), 1, 'only the fresh grant remains');

    CLIO::Security::GrantStore::set_ttl_seconds(0);
    CLIO::Security::GrantStore::grant('command', 'ancient', granted_at => time() - 90 * 86400);
    ok(CLIO::Security::GrantStore::is_granted('command', 'ancient'),
        'TTL 0 disables expiry');

    CLIO::Security::GrantStore::set_ttl_seconds(24 * 60 * 60);
    CLIO::Security::GrantStore::reset();
};

# ---------------------------------------------------------------------------
subtest 'export and restore round-trip' => sub {
    CLIO::Security::GrantStore::reset();
    CLIO::Security::GrantStore::set_ttl_seconds(86400);

    CLIO::Security::GrantStore::grant('command', 'network_outbound');
    CLIO::Security::GrantStore::grant('overwrite', 'file_overwrite', data => { note => 'kept' });

    my $exported = CLIO::Security::GrantStore::export();
    is(ref($exported), 'ARRAY', 'export returns an arrayref');
    is(scalar(@$exported), 2, 'export carries both grants');

    CLIO::Security::GrantStore::reset();
    is(CLIO::Security::GrantStore::count(), 0, 'store cleared before restore');

    my $result = CLIO::Security::GrantStore::restore($exported);
    is($result->{restored}, 2, 'both grants restored');
    ok(CLIO::Security::GrantStore::is_granted('command', 'network_outbound'),
        'restored command grant applies');
    is((CLIO::Security::GrantStore::get('overwrite', 'file_overwrite') || {})->{data}{note},
        'kept', 'scope-specific data survives the round-trip');

    CLIO::Security::GrantStore::reset();
};

# ---------------------------------------------------------------------------
subtest 'restore refuses what should not come back' => sub {
    CLIO::Security::GrantStore::reset();
    CLIO::Security::GrantStore::set_ttl_seconds(3600);

    my $entries = [
        { scope => 'command', key => 'fresh', granted_at => time() - 60 },
        { scope => 'command', key => 'expired', granted_at => time() - 7200 },
    ];
    my $result = CLIO::Security::GrantStore::restore($entries);
    is($result->{restored}, 1, 'only the unexpired grant is restored');
    is($result->{dropped_expired}, 1, 'the expired grant is counted as dropped');
    ok(!CLIO::Security::GrantStore::is_granted('command', 'expired'),
        'an expired grant is not resurrected by a resume');

    # One-time path grants are spent approvals, not standing permissions.
    CLIO::Security::GrantStore::reset();
    CLIO::Security::GrantStore::grant('path', 'conv|write_file|/etc/hosts',
        data => { conversation_id => 'conv', operation => 'write_file',
                  path => '/etc/hosts', one_time_use => 1 });
    CLIO::Security::GrantStore::grant('path', 'conv|write_file|/etc/passwd',
        data => { conversation_id => 'conv', operation => 'write_file',
                  path => '/etc/passwd', one_time_use => 0 });
    my $path_export = CLIO::Security::GrantStore::export();
    is(scalar(@$path_export), 1, 'only the session-wide path grant is exported');
    like($path_export->[0]{key}, qr{passwd}, 'the exported path grant is the session-wide one');

    # A path grant belongs to the conversation that asked.
    CLIO::Security::GrantStore::reset();
    my $mixed = [
        { scope => 'path', key => 'convA|write_file|/etc/hosts',
          granted_at => time(),
          data => { conversation_id => 'convA', operation => 'write_file',
                    path => '/etc/hosts', one_time_use => 0 } },
        { scope => 'path', key => 'convB|write_file|/etc/passwd',
          granted_at => time(),
          data => { conversation_id => 'convB', operation => 'write_file',
                    path => '/etc/passwd', one_time_use => 0 } },
    ];
    $result = CLIO::Security::GrantStore::restore($mixed, conversation_id => 'convA');
    is($result->{restored}, 1, 'only this conversation keeps its path grant');
    is($result->{dropped_other}, 1, 'the other conversation path grant is dropped');
    ok(CLIO::Security::GrantStore::is_granted('path', 'convA|write_file|/etc/hosts'),
        'grant for this conversation applies');
    ok(!CLIO::Security::GrantStore::is_granted('path', 'convB|write_file|/etc/passwd'),
        'grant for another conversation does not apply');

    # A scope this build does not know cannot come back. Older builds wrote an
    # `auto_approve` grant that bypassed every path check; restoring one would
    # hand a resumed session blanket filesystem access.
    CLIO::Security::GrantStore::reset();
    my $legacy = [
        { scope => 'auto_approve', key => 'convA', granted_at => time() },
        { scope => 'command', key => 'network_outbound', granted_at => time() },
    ];
    $result = CLIO::Security::GrantStore::restore($legacy);
    is($result->{restored}, 1, 'the known scope is restored');
    is($result->{dropped_unknown}, 1, 'the unknown scope is dropped');
    ok(!CLIO::Security::GrantStore::is_granted('auto_approve', 'convA'),
        'a legacy auto-approve grant does not come back');
    is_deeply([CLIO::Security::GrantStore::known_scopes()],
        [qw(command script overwrite web path)],
        'the known scopes are exactly the ones enforcement reads');

    CLIO::Security::GrantStore::reset();
    CLIO::Security::GrantStore::set_ttl_seconds(24 * 60 * 60);
};

# ---------------------------------------------------------------------------
subtest 'grants survive a real save and resume' => sub {
    CLIO::Security::GrantStore::reset();
    CLIO::Security::GrantStore::set_ttl_seconds(86400);

    my $session = CLIO::Session::Manager->create(debug => 0);
    ok(defined $session, 'session created');
    my $session_id = $session->{session_id};

    CLIO::Security::GrantStore::grant('command', 'network_outbound');
    CLIO::Security::GrantStore::grant('web', 'fetch_url');
    CLIO::Security::GrantStore::grant('overwrite', 'file_overwrite');

    # A one-time path grant must not be written to the session file.
    CLIO::Security::GrantStore::grant('path', "$session_id|write_file|/tmp/one-shot",
        data => { conversation_id => $session_id, operation => 'write_file',
                  path => '/tmp/one-shot', one_time_use => 1 });

    $session->save();
    ok(-e $session->{state}->{file}, 'session file written');

    $session->release_lock() if $session->can('release_lock');

    # New process-equivalent state: nothing granted, then resume.
    CLIO::Security::GrantStore::reset();
    is(CLIO::Security::GrantStore::count(), 0, 'store empty before resume');

    my $resumed = CLIO::Session::Manager->load($session_id, debug => 0);
    ok(defined $resumed, 'session resumed');

    ok(CLIO::Security::GrantStore::is_granted('command', 'network_outbound'),
        'command grant applies after resume');
    ok(CLIO::Security::GrantStore::is_granted('web', 'fetch_url'),
        'web grant applies after resume');
    ok(CLIO::Security::GrantStore::is_granted('overwrite', 'file_overwrite'),
        'overwrite grant applies after resume');
    ok(!CLIO::Security::GrantStore::is_granted('path', "$session_id|write_file|/tmp/one-shot"),
        'one-time path grant is NOT restored');

    $resumed->release_lock() if $resumed->can('release_lock');

    # A new session in the same process starts clean.
    my $fresh = CLIO::Session::Manager->create(debug => 0);
    is(CLIO::Security::GrantStore::count(), 0,
        'creating a new session clears every grant');

    my $saved_file = $fresh->{state}->{file};
    $fresh->release_lock() if $fresh->can('release_lock');
    unlink $saved_file;
    unlink $session->{state}->{file};
};

done_testing();
