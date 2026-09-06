#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Test: Recovery path is clean — no XML tags, no narration

use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/../../lib";

use Test::More;
use CLIO::Core::WorkflowOrchestrator;

# Build dropped messages simulating a reactive trim
my @dropped = (
    { role => 'user', content => 'Build the new feature' },
    { role => 'assistant', content => 'Starting work...' },
    { role => 'tool', tool_call_id => 'tc1', content => 'Tool result: created feat.pm' },
    { role => 'user', content => 'Also update the README' },
);

# The full message array (dropped + kept, simulating pre-trim state)
my @all_messages = (
    @dropped,
    { role => 'user', content => 'New question from user' },
);

my $last_user_msg = $all_messages[-1];

my $result = CLIO::Core::WorkflowOrchestrator::_compress_dropped_for_recovery(
    \@dropped, $last_user_msg, undef, \@all_messages, undef
);

ok(defined $result, 'Recovery compression produced a result');
is($result->{role}, 'system', 'Result is a system message (not user)');

my $content = $result->{content} // '';
ok(length($content) > 0, 'Result content is non-empty');

# Must contain a thread_summary block
like($content, qr/<thread_summary>/, 'Contains <thread_summary> block');

# Must NOT contain any framework narration
unlike($content, qr/Older conversation history/, 'No "Older conversation history" narration');
unlike($content, qr/Continue your current work/, 'No "Continue your current work" instruction');
unlike($content, qr/Do NOT say things/, 'No "Do NOT say things" instruction');
unlike($content, qr/I've recovered context/, 'No "I have recovered context" narration');

# Must NOT contain any XML recovery tags
unlike($content, qr/<current_topic>/, 'No <current_topic> tag');
unlike($content, qr/<task_recovery>/, 'No <task_recovery> tag');
unlike($content, qr/<recent_context>/, 'No <recent_context> tag');
unlike($content, qr/<git_recovery>/, 'No <git_recovery> tag');
unlike($content, qr/<session_progress>/, 'No <session_progress> tag');

done_testing();
