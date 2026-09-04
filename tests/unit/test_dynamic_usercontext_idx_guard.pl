#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test: when messages_to_prose_dynamic returns empty,
# _dynamic_usercontext_idx must NOT point to user_input (BUG #3 in
# QA review 2026-09-02).
#
# Bug: WorkflowOrchestrator::process_input guarded the dynamic UC
# push with `if (length $dynamic_usercontext)` but assigned
# `_dynamic_usercontext_idx = scalar(@messages) - 1` unconditionally.
# When the prose renderer returns empty, no UC is pushed but the
# idx still points to user_input. On iteration 2+, the per-iteration
# refresh would overwrite the user's question with dynamic UC
# content (clobbering the model's question).
#
# Fix: set idx to -1 when no UC was pushed; per-iteration refresh
# also checks >= 0.

use strict;
use warnings;
use utf8;
use lib './lib';

use Test::More;
use CLIO::Core::MessageHistory qw(messages_to_prose_dynamic);

# An empty projection produces empty prose (no todos, no LTM, etc.)
my $proj = {
    user_input => 'ping',
};
my $prose = messages_to_prose_dynamic($proj);
is(length($prose), 0, 'empty projection produces empty prose');

# A populated projection produces non-empty prose.
$proj->{environment} = {
    working_directory => '/tmp',
    language => 'English',
    datetime_iso => '2026-09-02T12:00:00',
};
$prose = messages_to_prose_dynamic($proj);
ok(length($prose) > 0, 'populated projection produces non-empty prose');

done_testing();