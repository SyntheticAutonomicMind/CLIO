#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Test: Cache stability — same inputs produce byte-identical output

use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/../../lib";

use Test::More tests => 5;
use CLIO::Memory::YaRN;

my $yarn = CLIO::Memory::YaRN->new();

my @messages = (
    { role => 'user', content => 'Build a new feature' },
    { role => 'assistant', content => 'Working on it' },
    { role => 'tool', tool_call_id => 'tc1', content => 'File contents here' },
    { role => 'user', content => 'Also fix tests' },
    { role => 'tool', tool_call_id => 'tc2', content => '[abc1234] Fix tests' },
);

# Compress twice with identical inputs
my $result1 = $yarn->compress_for_context_recovery(
    \@messages,
    original_task => 'Build a new feature'
);
my $result2 = $yarn->compress_for_context_recovery(
    \@messages,
    original_task => 'Build a new feature'
);

is($result1->{content}, $result2->{content},
    'Same inputs produce byte-identical thread_summary output');

# Compress again with a previous_summary (second cycle) — still deterministic
my @cycle2 = (
    { role => 'system', content => $result1->{content} },
    { role => 'user', content => 'Add CSS styling' },
    { role => 'tool', tool_call_id => 'tc3', content => '[def5678] Add CSS' },
);
my $result3 = $yarn->compress_for_context_recovery(
    \@cycle2,
    original_task => 'Add CSS styling'
);
my $result4 = $yarn->compress_for_context_recovery(
    \@cycle2,
    original_task => 'Add CSS styling'
);

is($result3->{content}, $result4->{content},
    'Cross-cycle compression is deterministic (byte-identical for same inputs)');

# Verify the second cycle includes carried-over content from the first
like($result3->{content}, qr/abc1234/, 'Cycle 2 summary includes carried-over commit from cycle 1');
like($result4->{content}, qr/abc1234/, 'Cycle 2 summary #2 also includes carried-over commit');
like($result3->{content}, qr/def5678/, 'Cycle 2 includes new commit');

done_testing();
