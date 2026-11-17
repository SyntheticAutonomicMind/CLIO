#!/usr/bin/perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

=head1 NAME

test_security_command_status.pl - /security reports what enforcement sees

The status view used to read four package-scoped grant hashes directly. Every
one of those was a separate shape, and a `my`/`our` mistake once made the view
read an always-empty copy of one of them. Now the view and enforcement both go
through CLIO::Security::GrantStore, and these tests pin the shared behaviour:
grants granted through the store are visible, reset clears them, a scoped reset
leaves other scopes alone, and an unknown scope changes nothing.

=cut

use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/../../lib";

use Test::More;

use CLIO::Tools::TerminalOperations;
use CLIO::Tools::FileOperations;
use CLIO::Tools::WebOperations;
use CLIO::Security::PathAuthorizer;
use CLIO::Security::GrantStore;
use CLIO::UI::Commands::System;

{
    package FakeChat;

    sub new { return bless { lines => [] }, shift }

    sub writeline {
        my ($self, $text, %opts) = @_;
        push @{$self->{lines}}, defined $text ? $text : '';
        return;
    }

    sub colorize {
        my ($self, $text) = @_;
        return defined $text ? $text : '';
    }

    sub _record { my ($self, $text) = @_; push @{$self->{lines}}, defined $text ? $text : ''; return }

    sub display_system_message  { shift->_record(@_) }
    sub display_error_message   { shift->_record(@_) }
    sub display_success_message { shift->_record(@_) }
    sub display_warning_message { shift->_record(@_) }
    sub display_info_message    { shift->_record(@_) }
    sub display_command_header  { shift->_record(@_) }
    sub display_section_header  { shift->_record(@_) }
    sub display_key_value       { my ($self, $k, $v) = @_; $self->_record("$k: $v") }
    sub display_command_row     { shift->_record(@_) }
    sub display_list_item       { shift->_record(@_) }
    sub display_tip             { shift->_record(@_) }

    sub lines { return @{ $_[0]{lines} } }
}

sub rendered_security_status {
    my $chat = FakeChat->new();
    my $cmd = CLIO::UI::Commands::System->new(chat => $chat);
    my $ok = eval { $cmd->handle_security_command(); 1 };
    return ($ok ? 1 : 0, join("\n", $chat->lines()), $@);
}

sub clear_grants {
    CLIO::Security::GrantStore::reset();
}

subtest 'no grants renders the empty state' => sub {
    clear_grants();
    my ($survived, $out, $err) = rendered_security_status();
    ok($survived, 'status survives with no grants') or diag($err);
    like($out, qr/No active approval grants/, 'reports no grants');
};

subtest 'active grants are listed, one line per grant' => sub {
    clear_grants();

    CLIO::Security::GrantStore::grant('command', 'network_outbound');
    CLIO::Security::GrantStore::grant('script', 'script_creation');
    CLIO::Security::GrantStore::grant('overwrite', 'file_overwrite');
    CLIO::Security::GrantStore::grant('web', 'fetch_url');

    my ($survived, $out, $err) = rendered_security_status();
    ok($survived, 'status survives with every scope populated') or diag($err);

    like($out, qr/4 grant/, 'counts all four grants');
    like($out, qr/command: network_outbound/, 'lists the command grant');
    like($out, qr/script: script_creation/,    'lists the script grant');
    like($out, qr/overwrite: file_overwrite/,  'lists the overwrite grant');
    like($out, qr/web: fetch_url/,             'lists the web grant');
    unlike($out, qr/No active approval grants/, 'does not claim the empty state');
};

subtest 'reset clears every table' => sub {
    my $chat = FakeChat->new();
    my $cmd = CLIO::UI::Commands::System->new(chat => $chat);
    my $ok = eval { $cmd->handle_security_command('reset'); 1 };
    ok($ok, 'reset survives') or diag($@);

    is(CLIO::Security::GrantStore::count(), 0, 'every grant cleared');
};

subtest 'reset of one scope leaves the others alone' => sub {
    clear_grants();
    CLIO::Security::GrantStore::grant('command', 'network_outbound');
    CLIO::Security::GrantStore::grant('web', 'fetch_url');

    my $chat = FakeChat->new();
    my $cmd = CLIO::UI::Commands::System->new(chat => $chat);
    my $ok = eval { $cmd->handle_security_command('reset', 'web'); 1 };
    ok($ok, 'scoped reset survives') or diag($@);

    ok(!CLIO::Security::GrantStore::is_granted('web', 'fetch_url'), 'web scope cleared');
    ok(CLIO::Security::GrantStore::is_granted('command', 'network_outbound'),
        'command scope untouched');
};

subtest 'unknown scope is rejected without clearing anything' => sub {
    clear_grants();
    CLIO::Security::GrantStore::grant('command', 'network_outbound');

    my $chat = FakeChat->new();
    my $cmd = CLIO::UI::Commands::System->new(chat => $chat);
    my $ok = eval { $cmd->handle_security_command('reset', 'bogus'); 1 };
    ok($ok, 'unknown scope does not die') or diag($@);
    ok(CLIO::Security::GrantStore::is_granted('command', 'network_outbound'),
        'grants survive a rejected reset');
};

subtest 'path grants show their real scope' => sub {
    clear_grants();

    my $authorizer = CLIO::Security::PathAuthorizer->new(debug => 0);
    $authorizer->grantAuthorization('conv', 'file_operations.write_file', 0,
        '/tmp/approved', prefix => 1);
    $authorizer->grantAuthorization('conv', 'file_operations.write_file', 0, undef);

    my ($survived, $out, $err) = rendered_security_status();
    ok($survived, 'status survives path grants') or diag($err);

    like($out, qr{file_operations\.write_file -> /tmp/approved/ \(session\)},
        'a directory grant is shown as a directory');
    like($out, qr{file_operations\.write_file -> any path \(session\)},
        'a wildcard grant is shown as any path');
};

# ---------------------------------------------------------------------------
# F10: the status view is only half the job. A grant you can see but cannot
# drop leaves the user choosing between "live with it" and "reset everything".
sub run_security {
    my (@args) = @_;
    my $chat = FakeChat->new();
    my $cmd  = CLIO::UI::Commands::System->new(chat => $chat);
    my $ok   = eval { $cmd->handle_security_command(@args); 1 };
    return ($ok, join("\n", $chat->lines()), $@);
}

subtest 'grants are numbered for revocation' => sub {
    clear_grants();
    CLIO::Security::GrantStore::grant('command', 'network_outbound');
    CLIO::Security::GrantStore::grant('web', 'fetch_url');

    my (undef, $out) = rendered_security_status();
    like($out, qr/^\s*1\. command: network_outbound/m, 'first grant is numbered 1');
    like($out, qr/^\s*2\. web: fetch_url/m, 'second grant is numbered 2');
    like($out, qr{/security revoke <number>}, 'the tip names the revoke form');
};

subtest 'revoke by number removes exactly that grant' => sub {
    clear_grants();
    CLIO::Security::GrantStore::grant('command', 'network_outbound');
    CLIO::Security::GrantStore::grant('web', 'fetch_url');

    my ($ok, $out, $err) = run_security('revoke', '1');
    ok($ok, 'revoke survives') or diag($err);

    ok(!CLIO::Security::GrantStore::is_granted('command', 'network_outbound'),
        'the numbered grant is gone');
    ok(CLIO::Security::GrantStore::is_granted('web', 'fetch_url'),
        'the other grant is untouched');
    like($out, qr/Revoked command: network_outbound/, 'says what it revoked');
};

subtest 'a number out of range revokes nothing' => sub {
    clear_grants();
    CLIO::Security::GrantStore::grant('command', 'network_outbound');

    my ($ok, $out, $err) = run_security('revoke', '7');
    ok($ok, 'out-of-range revoke does not die') or diag($err);
    is(CLIO::Security::GrantStore::count(), 1, 'nothing was removed');
    like($out, qr/No grant numbered 7/, 'explains the miss');
};

subtest 'revoke by scope and key' => sub {
    clear_grants();
    CLIO::Security::GrantStore::grant('script', 'script_creation');
    CLIO::Security::GrantStore::grant('overwrite', 'file_overwrite');

    my ($ok, undef, $err) = run_security('revoke', 'script', 'script_creation');
    ok($ok, 'scope+key revoke survives') or diag($err);

    ok(!CLIO::Security::GrantStore::is_granted('script', 'script_creation'), 'script grant gone');
    ok(CLIO::Security::GrantStore::is_granted('overwrite', 'file_overwrite'), 'overwrite grant kept');
};

subtest 'revoke of a path grant accepts the form the listing shows' => sub {
    clear_grants();
    my $authorizer = CLIO::Security::PathAuthorizer->new(debug => 0);
    $authorizer->grantAuthorization('conv', 'file_operations.write_file', 0,
        '/tmp/approved', prefix => 1);

    # The stored key carries the conversation id; the listing does not show it.
    my ($grant) = CLIO::Security::GrantStore::list_grants();
    like($grant->{key}, qr/^conv\|/, 'the stored key is conversation-qualified');

    my ($ok, undef, $err) = run_security('revoke', 'path', 'file_operations.write_file|/tmp/approved');
    ok($ok, 'path revoke by the printed tail survives') or diag($err);
    is(CLIO::Security::GrantStore::count(), 0, 'the path grant is gone');
};

subtest 'revoke of a path grant still accepts the whole key' => sub {
    clear_grants();
    my $authorizer = CLIO::Security::PathAuthorizer->new(debug => 0);
    $authorizer->grantAuthorization('conv', 'file_operations.write_file', 0,
        '/tmp/approved', prefix => 1);

    my ($grant) = CLIO::Security::GrantStore::list_grants();
    my ($ok, undef, $err) = run_security('revoke', 'path', $grant->{key});
    ok($ok, 'path revoke by full key survives') or diag($err);
    is(CLIO::Security::GrantStore::count(), 0, 'the path grant is gone');
};

subtest 'revoke rejects an unknown scope without touching anything' => sub {
    clear_grants();
    CLIO::Security::GrantStore::grant('command', 'network_outbound');

    my ($ok, $out, $err) = run_security('revoke', 'bogus', 'x');
    ok($ok, 'unknown scope does not die') or diag($err);
    is(CLIO::Security::GrantStore::count(), 1, 'nothing was removed');
    like($out, qr/Unknown scope 'bogus'/, 'names the bad scope');
};

subtest 'revoke of a missing key lists what is there' => sub {
    clear_grants();
    CLIO::Security::GrantStore::grant('web', 'fetch_url');

    my ($ok, $out, $err) = run_security('revoke', 'web', 'nope');
    ok($ok, 'missing key does not die') or diag($err);
    is(CLIO::Security::GrantStore::count(), 1, 'nothing was removed');
    like($out, qr/Grants in that scope: fetch_url/, 'shows the keys that exist');
};

subtest 'revoke with no target asks for one' => sub {
    clear_grants();
    CLIO::Security::GrantStore::grant('command', 'network_outbound');

    my ($ok, $out, $err) = run_security('revoke');
    ok($ok, 'bare revoke does not die') or diag($err);
    is(CLIO::Security::GrantStore::count(), 1, 'nothing was removed');
    like($out, qr/Say which grant to revoke/, 'asks which grant');
};

subtest 'a resumed grant is marked as resumed' => sub {
    clear_grants();
    CLIO::Security::GrantStore::grant('command', 'network_outbound');
    my $saved = CLIO::Security::GrantStore::export();

    clear_grants();
    CLIO::Security::GrantStore::restore($saved);

    my (undef, $out) = rendered_security_status();
    like($out, qr/command: network_outbound .*resumed from session/,
        'a grant that came back from disk says so');
};

subtest 'a grant made in this process is not marked resumed' => sub {
    clear_grants();
    CLIO::Security::GrantStore::grant('web', 'fetch_url');

    my (undef, $out) = rendered_security_status();
    unlike($out, qr/fetch_url.*resumed from session/,
        'a fresh grant is not labelled resumed');
};

done_testing();
