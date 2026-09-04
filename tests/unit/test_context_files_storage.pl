#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test: /context add files must be included in the dynamic
# userContext when _render_context_files_for_user_context is called.
#
# Before the fix: _render_context_files_for_user_context read from
# $session->state()->{context_files} (an always-empty array). The
# /context add command writes to $session->{context_files} (session
# object hash). The two storage locations never synced, so every
# /context add file was silently dropped from the dynamic userContext.
#
# After the fix: _render_context_files_for_user_context reads from
# $session->{context_files} directly, matching what /context add
# writes.

use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/../../lib";

use Test::More;
use File::Temp qw(tempfile);
use CLIO::Core::WorkflowOrchestrator;

# Create a temp file the test session "added via /context add".
my ($fh, $filename) = tempfile(SUFFIX => '.txt', UNLINK => 1);
print $fh "CONTEXT FILE CONTENT FOR TEST\n";
close $fh;

package FakeSession;
sub FakeSession::new { my $pkg = shift || 'FakeSession'; my %a = @_; bless { %a }, $pkg }
sub FakeSession::can {
    my ($self, $method) = @_;
    return 1 if $method eq 'state';
    return 0;
}
sub FakeSession::state {
    my $self = shift;
    require CLIO::Session::State;
    return CLIO::Session::State->new(session_id => 'test', max_tokens => 128000);
}

package main;

# Simulate what /context add command does: writes to session->{context_files}.
my $session = FakeSession->new(context_files => [$filename]);

my $wo = bless { _tools_cache => 1 }, 'CLIO::Core::WorkflowOrchestrator';

my $block = $wo->_render_context_files_for_user_context($session);

like($block, qr/\[CONTEXT FILES\]/, "Block includes [CONTEXT FILES] header");
like($block, qr/CONTEXT FILE CONTENT FOR TEST/, "Block includes the file content");
like($block, qr/\Q$filename\E/, "Block includes the file path");

# Empty context_files -> empty block.
my $session_empty = FakeSession->new(context_files => []);
my $empty_block = $wo->_render_context_files_for_user_context($session_empty);
is($empty_block, '', "Empty context_files produces empty block");

# Missing context_files (undef) -> empty block, not an error.
my $session_none = FakeSession::new();
my $none_block = $wo->_render_context_files_for_user_context($session_none);
is($none_block, '', "Missing context_files produces empty block");

# The legacy inject_context_files path still works (state-based).
# We don't test that here because it's been removed from the rebuild
# path; tests for the legacy behavior live in test_conversation_manager.

done_testing();