#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Test: YaRN::compress_for_context_recovery
#
# Verifies that compress_for_context_recovery:
# 1. Extracts previous_summary from <thread_summary> blocks in the message array
# 2. Passes it to compress_messages for cross-cycle carryover
# 3. Returns a system message with <thread_summary> content (slimmed:
#    only original task + recent user requests, no commit/file/decision
#    statistical noise)

use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/../../lib";

use Test::More tests => 8;
use CLIO::Memory::YaRN;

my $yarn = CLIO::Memory::YaRN->new();

# ---------------------------------------------------------------------------
# previous_summary is extracted from messages and only user_requests carried
# forward (no commits/files/decisions — slimmed format)
# ---------------------------------------------------------------------------
my @messages = (
    {
        role => 'system',
        content => '<thread_summary>

Current task: Build a widget system

Recent user requests:
- [original] Build a widget system
- Add a test suite
</thread_summary>'
    },
    { role => 'user', content => 'Deploy the widget system to production' },
    { role => 'assistant', content => 'Deploying now' },
    { role => 'tool', tool_call_id => 'tc1', content => 'Deploy result' },
);

my $result = $yarn->compress_for_context_recovery(
    \@messages,
    original_task => 'Deploy the widget system to production'
);

ok(defined $result, 'compress_for_context_recovery returns a result');
ok(ref($result) eq 'HASH', 'Result is a hashref');
ok(defined $result->{content} && length($result->{content}), 'Result has content');
like($result->{content}, qr/<thread_summary>/, 'Result is wrapped in <thread_summary> tags');

# Previous user request carried forward
like($result->{content}, qr/Build a widget system/, 'Previous original request carried forward');

# No statistical noise in the slimmed output
unlike($result->{content}, qr/abc1234|Commits:|Files:|Decisions:|Tool calls:/,
    'No commit/file/decision/tool noise in slimmed output');

# Current task is surfaced
like($result->{content}, qr/Current task:/, 'Current task section present');

# New user request is included
like($result->{content}, qr/Deploy the widget system/, 'New user request included');

done_testing();
