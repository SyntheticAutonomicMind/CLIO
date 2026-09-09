#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test: with the remove-and-rebuild approach, an empty
# projection produces empty prose (no UC pushed at tail), so the
# model's user_input is not clobbered. The new _replace_dynamic_
# usercontext filters old UC by content (not index) and only
# appends when non-empty.

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
$proj->{active_todos} = [
    { status => 'pending', content => 'fix the bug' },
];
$prose = messages_to_prose_dynamic($proj);
ok(length($prose) > 0, 'populated projection produces non-empty prose');

done_testing();
