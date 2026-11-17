# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Security::GrantStore;

use strict;
use warnings;
use utf8;

use CLIO::Core::Logger qw(log_debug);

=head1 NAME

CLIO::Security::GrantStore - one store for every kind of approval grant

=head1 SYNOPSIS

    use CLIO::Security::GrantStore;

    CLIO::Security::GrantStore::grant('command', 'network_outbound');
    CLIO::Security::GrantStore::is_granted('command', 'network_outbound');  # 1

    my $saved = CLIO::Security::GrantStore::export();
    CLIO::Security::GrantStore::reset();
    CLIO::Security::GrantStore::restore($saved);

=head1 DESCRIPTION

Approval grants used to live in five separate package hashes: one for command
categories in L<CLIO::Tools::TerminalOperations>, one each for script creation
and file overwrites in L<CLIO::Tools::FileOperations>, one for web fetches in
L<CLIO::Tools::WebOperations>, and one keyed by conversation in
L<CLIO::Security::PathAuthorizer>. Each had its own shape, its own reset
function, and no way to enumerate or persist the set. Anything that needed to
show or save approvals had to know all five.

This module is the single table. A grant is identified by a scope and a key
inside that scope:

    scope        key                        meaning
    ---------    -------------------------  ---------------------------------
    command      <category>                 a class of risky shell command
    script       script_creation            writing script-shaped files
    overwrite    file_overwrite             replacing an existing file
    web          fetch_url                  outbound fetches (grantable ones)
    path         <operation>|<path>         writing outside the session dir

Scopes exist so a reset can be narrow (C</security reset web>) and so a grant
can never be read under the wrong meaning by a typo.

=head2 Expiry

Every grant records when it was granted and is only honoured while it is
younger than C<$TTL_SECONDS> (default 24 hours, 0 disables expiry). Grants now
survive a session resume, so without an age limit a grant made weeks ago in an
abandoned session would silently answer a prompt the user has long forgotten.
Age is checked on read rather than stored as an expiry timestamp: the policy
applies uniformly to grants made in this process and to grants restored from
disk, and changing the policy affects grants already recorded.

=cut

# scope => { key => { granted_at => epoch, data => {...} } }
our %_grants;

# Scopes that mean something. restore() refuses anything else, so a session
# file written by an older build (or edited by hand) cannot inject a scope that
# some future reader would honour.
our @KNOWN_SCOPES = qw(command script overwrite web path);
our %_KNOWN_SCOPE  = map { $_ => 1 } @KNOWN_SCOPES;

sub known_scopes { return @KNOWN_SCOPES }

# How long a grant stays valid, in seconds. 0 means "no expiry".
our $TTL_SECONDS = 24 * 60 * 60;

=head2 set_ttl_seconds / ttl_seconds

Set or read the grant lifetime. C<0> disables expiry.

=cut

sub set_ttl_seconds {
    my ($seconds) = @_;
    return $TTL_SECONDS unless defined $seconds;
    $TTL_SECONDS = $seconds < 0 ? 0 : $seconds;
    return $TTL_SECONDS;
}

sub ttl_seconds { return $TTL_SECONDS }

=head2 grant($scope, $key, %opts)

Record a grant. Options:

=over 4

=item granted_at - epoch seconds (default: now)

=item data - hashref of scope-specific fields (path, operation, ...)

=back

Granting twice refreshes the timestamp, so a user who approves the same
category again extends the window rather than leaving an old timestamp in
place.

=cut

sub grant {
    my ($scope, $key, %opts) = @_;
    return unless defined $scope && defined $key && length $key;

    my $now = time();
    $_grants{$scope} ||= {};
    $_grants{$scope}{$key} = {
        granted_at => $opts{granted_at} // $now,
        data       => $opts{data} || {},
    };

    log_debug('GrantStore', "Granted $scope/$key");
    return 1;
}

=head2 revoke($scope, $key)

Remove one grant. Returns true if a grant was removed.

=cut

sub revoke {
    my ($scope, $key) = @_;
    return 0 unless defined $scope && defined $key;
    return 0 unless $_grants{$scope};
    my $removed = delete $_grants{$scope}{$key};
    delete $_grants{$scope} unless %{ $_grants{$scope} };
    log_debug('GrantStore', "Revoked $scope/$key") if $removed;
    return $removed ? 1 : 0;
}

=head2 get($scope, $key)

Return the stored grant, or undef. Does not apply expiry - use L</is_granted>
for decisions, this for inspection (age, scope-specific data).

=cut

sub get {
    my ($scope, $key) = @_;
    return undef unless defined $scope && defined $key;
    return $_grants{$scope} ? $_grants{$scope}{$key} : undef;
}

=head2 is_granted($scope, $key)

True when a grant exists and has not aged past L</ttl_seconds>.

=cut

sub is_granted {
    my ($scope, $key) = @_;
    my $record = get($scope, $key);
    return 0 unless $record;

    if ($TTL_SECONDS > 0) {
        my $age = time() - ($record->{granted_at} // 0);
        if ($age > $TTL_SECONDS) {
            log_debug('GrantStore', "Grant $scope/$key expired (age ${age}s)");
            return 0;
        }
    }

    return 1;
}

=head2 keys_for($scope)

Return the keys recorded in a scope, expired ones included.

=cut

sub keys_for {
    my ($scope) = @_;
    return () unless $_grants{$scope};
    return sort keys %{ $_grants{$scope} };
}

=head2 list_grants(%opts)

Return every grant as a list of hashrefs, for display and for persistence.

Options:

=over 4

=item include_expired - default false

=back

Each entry: C<{ scope, key, granted_at, expired, data }>.

=cut

sub list_grants {
    my (%opts) = @_;
    my $now = time();

    my @out;
    for my $scope (sort keys %_grants) {
        for my $key (sort keys %{ $_grants{$scope} }) {
            my $record = $_grants{$scope}{$key};
            my $age = $now - ($record->{granted_at} // 0);
            my $expired = ($TTL_SECONDS > 0 && $age > $TTL_SECONDS) ? 1 : 0;
            next if $expired && !$opts{include_expired};
            push @out, {
                scope      => $scope,
                key        => $key,
                granted_at => $record->{granted_at},
                age        => $age,
                expired    => $expired,
                data       => $record->{data} || {},
            };
        }
    }

    return @out;
}

=head2 count(%opts)

Number of live grants.

=cut

sub count {
    my (%opts) = @_;
    return scalar list_grants(%opts);
}

=head2 reset()

Clear every grant in every scope. Returns the number cleared.

=cut

sub reset {
    my $count = 0;
    for my $scope (keys %_grants) {
        $count += scalar keys %{ $_grants{$scope} };
    }
    %_grants = ();
    log_debug('GrantStore', "Reset all grants, cleared=$count");
    return $count;
}

=head2 reset_scope($scope)

Clear one scope. Returns the number cleared.

=cut

sub reset_scope {
    my ($scope) = @_;
    return 0 unless $scope && $_grants{$scope};
    my $count = scalar keys %{ $_grants{$scope} };
    delete $_grants{$scope};
    log_debug('GrantStore', "Reset scope $scope, cleared=$count");
    return $count;
}

=head2 prune_expired()

Drop expired grants so the table does not grow without bound across resumes.
Returns the number dropped.

=cut

sub prune_expired {
    my @expired = list_grants(include_expired => 1);
    my $dropped = 0;
    for my $grant (@expired) {
        next unless $grant->{expired};
        revoke($grant->{scope}, $grant->{key});
        $dropped++;
    }
    log_debug('GrantStore', "Pruned $dropped expired grant(s)") if $dropped;
    return $dropped;
}

=head2 export()

Return the grant table in a JSON-safe form for session persistence.

Only grants that should survive a resume are exported: one-time path grants
are not, because a one-time approval that has already been spent - or is about
to be spent on the next call - is not an approval the user still holds.

=cut

sub export {
    my @entries;
    for my $grant (list_grants(include_expired => 1)) {
        if ($grant->{scope} eq 'path') {
            my $data = $grant->{data} || {};
            next if $data->{one_time_use};
            next if $data->{consumed};
        }
        push @entries, {
            scope      => $grant->{scope},
            key        => $grant->{key},
            granted_at => $grant->{granted_at},
            data       => $grant->{data} || {},
        };
    }
    return \@entries;
}

=head2 restore($entries, %opts)

Load a previously exported table. Expired entries are dropped rather than
restored, so resuming an old session does not silently re-approve anything.
Entries carrying a scope that is not in L</known_scopes> are dropped too - a
grant only comes back if this build knows what the scope means.

Options:

=over 4

=item conversation_id - when given, path grants recorded for a different
conversation are dropped. A grant is a statement about the conversation that
asked the question.

=back

Returns C<{ restored => $n, dropped_expired => $n, dropped_other => $n,
dropped_unknown => $n }>.

=cut

sub restore {
    my ($entries, %opts) = @_;

    my $result = {
        restored        => 0,
        dropped_expired => 0,
        dropped_other   => 0,
        dropped_unknown => 0,
    };
    return $result unless ref($entries) eq 'ARRAY';

    my $now = time();
    for my $entry (@$entries) {
        next unless ref($entry) eq 'HASH';
        my ($scope, $key) = @$entry{qw(scope key)};
        next unless defined $scope && defined $key && length $key;

        unless ($_KNOWN_SCOPE{$scope}) {
            $result->{dropped_unknown}++;
            next;
        }

        my $granted_at = $entry->{granted_at} // $now;

        if ($TTL_SECONDS > 0 && ($now - $granted_at) > $TTL_SECONDS) {
            $result->{dropped_expired}++;
            next;
        }

        if ($scope eq 'path' && $opts{conversation_id}) {
            my $owner = ($entry->{data} || {})->{conversation_id};
            if (defined $owner && $owner ne $opts{conversation_id}) {
                $result->{dropped_other}++;
                next;
            }
        }

        $_grants{$scope} ||= {};
        $_grants{$scope}{$key} = {
            granted_at => $granted_at,
            data       => $entry->{data} || {},
        };
        $result->{restored}++;
    }

    log_debug('GrantStore', "Imported grants: restored=$result->{restored} "
        . "expired=$result->{dropped_expired} other=$result->{dropped_other} "
        . "unknown=$result->{dropped_unknown}");

    return $result;
}

1;

__END__

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

GPL-3.0-only

=cut
