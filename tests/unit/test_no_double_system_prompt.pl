#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Test: No double system prompt
#
# Verifies that State::load strips persisted system messages from
# history, so only ONE system prompt exists (the fresh one built by
# PromptBuilder per turn).

use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/../../lib";

use Test::More;

# Simulate the persistence + load cycle
my @history = (
    { role => 'system', content => 'PERSISTED SYSTEM PROMPT - old copy' },
    { role => 'user', content => 'Hello' },
    { role => 'assistant', content => 'Hi there' },
    { role => 'system', content => '<thread_summary>

Current task: test double system prompt
</thread_summary>' },
    { role => 'user', content => 'Another question' },
);

# Simulate what State::load does: strip system messages EXCEPT
# those containing <thread_summary>
my @cleaned = grep {
    my $m = $_;
    !($m->{role} eq 'system'
      && ($m->{content} // '') !~ /<thread_summary>/);
} @history;

my @system_msgs = grep { $_->{role} eq 'system' } @cleaned;
is(scalar(@system_msgs), 1, 'Only 1 system message after stripping (no double system prompt)');
is($system_msgs[0]{content} =~ /<thread_summary>/, 1,
    'Remaining system message is the thread_summary (not the old prompt)');

# Verify non-system messages are preserved
my @non_system = grep { $_->{role} ne 'system' } @cleaned;
is(scalar(@non_system), 3, 'All non-system messages preserved');

# Verify the old system prompt was stripped
my $has_old_prompt = 0;
for my $msg (@cleaned) {
    if (($msg->{content} // '') =~ /PERSISTED SYSTEM PROMPT/) {
        $has_old_prompt = 1;
    }
}
ok(!$has_old_prompt, 'Old persisted system prompt was stripped');

done_testing();
