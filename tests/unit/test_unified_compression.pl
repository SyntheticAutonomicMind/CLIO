#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Test: YaRN::compress_for_context_recovery
#
# Verifies that compress_for_context_recovery:
# 1. Extracts previous_summary from <thread_summary> blocks in the message array
# 2. Passes it to compress_messages for cross-cycle carryover
# 3. Filters out old thread_summary system messages from the compressed set
# 4. Returns a system message with <thread_summary> content

use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/../../lib";

use Test::More tests => 8;
use CLIO::Memory::YaRN;

my $yarn = CLIO::Memory::YaRN->new();

# ---------------------------------------------------------------------------
# previous_summary is extracted from messages and carried forward
# ---------------------------------------------------------------------------
my @messages = (
    {
        role => 'system',
        content => '<thread_summary>

Current task: Build a widget system

Commits:
- abc1234: Add widget base class
- def5678: Implement widget renderer

Files:
- lib/Widget/Base.pm
- lib/Widget/Renderer.pm

Tools:
- file_operations: 5 calls
</thread_summary>'
    },
    { role => 'user', content => 'Add a test suite for the widget system' },
    { role => 'assistant', content => 'Writing tests now' },
    { role => 'tool', tool_call_id => 'tc1', content => '[ghi9012] Add test suite for widgets' },
);

my $result = $yarn->compress_for_context_recovery(
    \@messages,
    original_task => 'Add a test suite for the widget system'
);

ok(defined $result, 'compress_for_context_recovery returns a result');
ok(ref($result) eq 'HASH', 'Result is a hashref');
ok(defined $result->{content} && length($result->{content}), 'Result has content');
like($result->{content}, qr/<thread_summary>/, 'Result is wrapped in <thread_summary> tags');

# The previous commit should be carried forward (cross-cycle carryover)
like($result->{content}, qr/abc1234/, 'Previous commit preserved in new summary');
like($result->{content}, qr/def5678/, 'Previous commit def5678 preserved');
like($result->{content}, qr/Widget\/Renderer\.pm/, 'Previous file preserved');
like($result->{content}, qr/file_operations: 5 calls/, 'Tool counts carried forward from previous summary');

done_testing();
