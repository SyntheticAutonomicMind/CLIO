#!/usr/bin/perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

=head1 NAME

test_security_command_status.pl - /security status reads the live grant tables

The status view reads the grant tables through their package variables. When
those tables were declared with `my`, the view read a different, always-empty
hash - and the expression used to copy them (`%{$Package::hash}`) dereferenced
a scalar and died as soon as anything was granted. These tests pin both.

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
    CLIO::Tools::TerminalOperations::reset_session_grants();
    CLIO::Tools::FileOperations::reset_script_session_grants();
    CLIO::Tools::FileOperations::reset_overwrite_session_grants();
    CLIO::Tools::WebOperations::reset_url_session_grants();
    CLIO::Security::PathAuthorizer::reset_path_grants();
}

subtest 'no grants renders the empty state' => sub {
    clear_grants();
    my ($survived, $out, $err) = rendered_security_status();
    ok($survived, 'status survives with no grants') or diag($err);
    like($out, qr/No active session-level security grants/, 'reports no grants');
};

subtest 'active grants are listed, one line per grant' => sub {
    clear_grants();

    $CLIO::Tools::TerminalOperations::_session_grants{network_outbound} = 1;
    $CLIO::Tools::FileOperations::_script_write_grants{script_creation} = 1;
    $CLIO::Tools::FileOperations::_overwrite_session_grants{file_overwrite} = 1;
    $CLIO::Tools::WebOperations::_url_session_grants{fetch_url} = 1;

    my ($survived, $out, $err) = rendered_security_status();
    ok($survived, 'status survives with every grant table populated') or diag($err);

    like($out, qr/4 session grant/, 'counts all four grants');
    like($out, qr/command: network_outbound/, 'lists the command grant');
    like($out, qr/script: script_creation/,    'lists the script grant');
    like($out, qr/overwrite: file_overwrite/,  'lists the overwrite grant');
    like($out, qr/web: fetch_url/,             'lists the web grant');
    unlike($out, qr/No active session-level security grants/, 'does not claim the empty state');
};

subtest 'reset clears every table' => sub {
    my $chat = FakeChat->new();
    my $cmd = CLIO::UI::Commands::System->new(chat => $chat);
    my $ok = eval { $cmd->handle_security_command('reset'); 1 };
    ok($ok, 'reset survives') or diag($@);

    is(scalar(keys %CLIO::Tools::TerminalOperations::_session_grants), 0,
        'command grants cleared');
    is(scalar(keys %CLIO::Tools::FileOperations::_script_write_grants), 0,
        'script grants cleared');
    is(scalar(keys %CLIO::Tools::FileOperations::_overwrite_session_grants), 0,
        'overwrite grants cleared');
    is(scalar(keys %CLIO::Tools::WebOperations::_url_session_grants), 0,
        'web grants cleared');
};

done_testing();
