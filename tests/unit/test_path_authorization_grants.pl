#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test: a write outside the session directory must be approvable.
#
# The guard used to report requires_authorization for every such write and tell
# the caller to obtain approval through a mechanism that never granted paths.
# grantAuthorization/revoke*/setAutoApprove had no production call sites, so the
# denial was permanent for file_operations and apply_patch, and the denial text
# invited the model to use a capability that did not exist.
#
# These tests exercise authorize_or_prompt, which is the approval path those
# tools now use.

use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::RealBin/../../lib";

use Test::More;
use CLIO::Security::PathAuthorizer;
use File::Temp qw(tempdir);

my $workdir = tempdir(CLEANUP => 1);
my $outside = tempdir(CLEANUP => 1);

# Everything starts clean.
CLIO::Security::PathAuthorizer::reset_path_grants();

sub authorizer {
    return CLIO::Security::PathAuthorizer->new(debug => 0);
}

# ── A path inside the session needs no approval ──────────────────────────────
{
    my $pa = authorizer();
    my $prompted = 0;
    my $result = $pa->authorize_or_prompt(
        path              => "$workdir/inside.txt",
        working_directory => $workdir,
        conversation_id   => 'conv',
        operation         => 'file_operations.write_file',
        prompt            => sub { $prompted++; return 'once' },
    );

    is($result->{status}, 'allowed', 'write inside the session is allowed');
    is($prompted, 0, 'no prompt for a path inside the session');
}

# ── Outside the session the user is actually asked ───────────────────────────
{
    my $pa = authorizer();
    my $target = "$outside/new_file.txt";
    my $prompted = 0;
    my $seen_path;

    my $result = $pa->authorize_or_prompt(
        path              => $target,
        working_directory => $workdir,
        conversation_id   => 'conv',
        operation         => 'file_operations.write_file',
        prompt            => sub {
            my %d = @_;
            $prompted++;
            $seen_path = $d{path};
            return 'once';
        },
    );

    is($result->{status}, 'allowed', 'approved write outside the session is allowed');
    is($result->{granted}, 'once', 'grant recorded as one-time');
    is($prompted, 1, 'the user was prompted exactly once');
    is($seen_path, $target, 'the prompt was given the resolved path');

    # The one-time grant is consumed by the next check.
    my $second = $pa->checkPathAuthorization(
        path              => $target,
        working_directory => $workdir,
        conversation_id   => 'conv',
        operation         => 'file_operations.write_file',
    );
    is($second->{status}, 'requires_authorization',
        'a one-time grant does not survive a second write');
}

# ── A one-time grant covers only the path it was granted for ────────────────
{
    CLIO::Security::PathAuthorizer::reset_path_grants();
    my $pa = authorizer();

    $pa->authorize_or_prompt(
        path              => "$outside/first.txt",
        working_directory => $workdir,
        conversation_id   => 'conv',
        operation         => 'file_operations.write_file',
        prompt            => sub { return 'once' },
    );

    my $other = $pa->checkPathAuthorization(
        path              => "$outside/second.txt",
        working_directory => $workdir,
        conversation_id   => 'conv',
        operation         => 'file_operations.write_file',
    );
    is($other->{status}, 'requires_authorization',
        'approving one path does not unlock a different path');
}

# ── A session grant covers later paths without prompting again ──────────────
{
    CLIO::Security::PathAuthorizer::reset_path_grants();
    my $pa = authorizer();
    my $prompted = 0;

    my $first = $pa->authorize_or_prompt(
        path              => "$outside/a.txt",
        working_directory => $workdir,
        conversation_id   => 'conv',
        operation         => 'file_operations.write_file',
        prompt            => sub { $prompted++; return 'session' },
    );
    is($first->{status}, 'allowed', 'session approval allows the write');
    is($first->{granted}, 'session', 'grant recorded as session-wide');

    my $second = $pa->authorize_or_prompt(
        path              => "$outside/b.txt",
        working_directory => $workdir,
        conversation_id   => 'conv',
        operation         => 'file_operations.write_file',
        prompt            => sub { $prompted++; return 'deny' },
    );
    is($second->{status}, 'allowed', 'session grant covers a later path');
    is($prompted, 1, 'the later write did not prompt again');
}

# ── Denial is honoured and is not a grant ───────────────────────────────────
{
    CLIO::Security::PathAuthorizer::reset_path_grants();
    my $pa = authorizer();

    my $result = $pa->authorize_or_prompt(
        path              => "$outside/denied.txt",
        working_directory => $workdir,
        conversation_id   => 'conv',
        operation         => 'file_operations.write_file',
        prompt            => sub { return 'deny' },
    );
    is($result->{status}, 'denied', 'a denied prompt produces a denial');

    my $again = $pa->checkPathAuthorization(
        path              => "$outside/denied.txt",
        working_directory => $workdir,
        conversation_id   => 'conv',
        operation         => 'file_operations.write_file',
    );
    is($again->{status}, 'requires_authorization',
        'a denial does not leave a grant behind');
}

# ── With no prompt available the caller gets the plain check result ────────
{
    CLIO::Security::PathAuthorizer::reset_path_grants();
    my $pa = authorizer();

    my $result = $pa->authorize_or_prompt(
        path              => "$outside/no_channel.txt",
        working_directory => $workdir,
        conversation_id   => 'conv',
        operation         => 'file_operations.write_file',
    );
    is($result->{status}, 'requires_authorization',
        'without a prompt the result is still requires_authorization');
    is($result->{granted}, undef, 'no grant is recorded without approval');
}

# ── Grants are shared between tool instances ────────────────────────────────
# file_operations and apply_patch build separate authorizers; a session grant
# approved through one has to be visible to the other.
{
    CLIO::Security::PathAuthorizer::reset_path_grants();
    my $one = authorizer();
    my $two = authorizer();

    $one->authorize_or_prompt(
        path              => "$outside/shared.txt",
        working_directory => $workdir,
        conversation_id   => 'conv',
        operation         => 'file_operations.write_file',
        prompt            => sub { return 'session' },
    );

    my $from_other = $two->checkPathAuthorization(
        path              => "$outside/shared.txt",
        working_directory => $workdir,
        conversation_id   => 'conv',
        operation         => 'file_operations.write_file',
    );
    is($from_other->{status}, 'allowed',
        'a session grant is visible to a second authorizer instance');
}

# ── /security reset clears path grants ─────────────────────────────────────
{
    CLIO::Security::PathAuthorizer::reset_path_grants();
    my $pa = authorizer();

    $pa->grantAuthorization('conv', 'file_operations.write_file', 0, undef);
    my $listed = CLIO::Security::PathAuthorizer::list_path_grants();
    is(scalar(@$listed), 1, 'an active grant is listed');

    my $cleared = CLIO::Security::PathAuthorizer::reset_path_grants();
    is($cleared, 1, 'reset reports the number of grants cleared');
    is(scalar(@{ CLIO::Security::PathAuthorizer::list_path_grants() }), 0,
        'reset removes every path grant');
}

# ── Traversal cannot smuggle a write back inside the session ───────────────
# "<session>/missing/../../outside.txt" resolves outside the session, so the
# containment test must reject it despite the literal session prefix.
{
    CLIO::Security::PathAuthorizer::reset_path_grants();
    my $pa = authorizer();
    my $prompted = 0;

    my $result = $pa->authorize_or_prompt(
        path              => "$workdir/missing/../../escaped.txt",
        working_directory => $workdir,
        conversation_id   => 'conv',
        operation         => 'file_operations.write_file',
        prompt            => sub { $prompted++; return 'deny' },
    );

    is($prompted, 1, 'a traversal path escaping the session is treated as outside');
    is($result->{status}, 'denied', 'the escaped path is not silently allowed');
}

CLIO::Security::PathAuthorizer::reset_path_grants();

done_testing();
