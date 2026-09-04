#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test: _select_turns must not die with "Undefined subroutine
# YaRN::recover_substantive_task" when no anchor turn is found in
# history. The fix loads YaRN in ContextBuilder (use CLIO::Memory::YaRN)
# and dedupes the duplicate fallback block.
#
# Previously ContextBuilder.pm called
# CLIO::Memory::YaRN::recover_substantive_task without loading the
# module. When YaRN hadn't been loaded by some prior require, the
# call died with "Undefined subroutine ... called at lib/CLIO/Core/
# ContextBuilder.pm line 688." This was a fatal error in the rare
# but real case where _split_into_turns produces only continuation
# prompts (e.g. a session whose first substantive user message was
# trimmed past by aggressive context trimming, leaving only
# "continue" / "ok" / "go on" in history).

use strict;
use warnings;
use utf8;
use lib './lib';

use Test::More;
use CLIO::Core::ContextBuilder;

# Mock session - bare hash with ->yarn accessor (YaRN::recover_substantive_task
# calls $session_or_yarn->yarn when given a session). We don't need a real
# YaRN instance because the test asserts the call doesn't die; if YaRN
# can't recover, the last-resort fallback picks the first user message
# (even if it's a continuation prompt).
package FakeSession;
sub new { bless { id => 'test-yarn-fallback' }, shift }
sub id { $_[0]->{id} }
sub yarn { undef }   # No durable thread; forces YaRN-recovery to return ''
package main;
my $session = FakeSession->new();

# Build a history with only continuation prompts - no substantive user
# messages (>=50 chars). _select_turns will not find an anchor and must
# fall back to YaRN-recovery (which returns '') and then to the first
# user message (a continuation prompt). The test asserts no fatal error.
my @continuation_history = (
    { role => 'user', content => 'continue' },
    { role => 'assistant', content => '', tool_calls => [{ id => 'tc_1', function => { name => 'foo' } }] },
    { role => 'tool',    content => 'tool result', tool_call_id => 'tc_1' },
    { role => 'assistant', content => 'ok' },
    { role => 'user', content => 'go on' },
    { role => 'assistant', content => '', tool_calls => [{ id => 'tc_2', function => { name => 'bar' } }] },
    { role => 'tool',    content => 'tool result 2', tool_call_id => 'tc_2' },
    { role => 'assistant', content => 'done' },
);

my $proj = CLIO::Core::ContextBuilder::build_projection(
    history    => \@continuation_history,
    user_input => 'continue',
    session    => $session,
);

ok(defined $proj, 'build_projection completes without fatal error (BUG #2 regression guard)');
ok(ref($proj) eq 'HASH', 'projection is a hashref');

# The last-resort fallback picks the first user message even if it's a
# continuation prompt - that's better than no anchor.
ok(defined $proj->{anchor}, 'anchor is defined (last-resort fallback used)');
if (ref($proj->{anchor}) eq 'ARRAY') {
    is($proj->{anchor}[0]{content}, 'continue',
        'anchor is the first user message even when it is a continuation prompt');
}

done_testing();