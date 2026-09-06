#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Test: Cross-cycle carryover

use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/../../lib";

use Test::More tests => 7;
use CLIO::Memory::YaRN;

my $yarn = CLIO::Memory::YaRN->new();

# Cycle 1: Compress initial messages
my @cycle1_msgs = (
    { role => 'user', content => 'Build a widget system' },
    { role => 'assistant', content => 'Starting...' },
    { role => 'tool', tool_call_id => 'tc1', content => 'Result: created Base.pm' },
    { role => 'user', content => 'Add a renderer' },
    { role => 'assistant', content => 'Writing renderer...'},
    { role => 'tool', tool_call_id => 'tc2', content => '[abc1234] Add widget renderer' },
);

my $result1 = $yarn->compress_for_context_recovery(
    \@cycle1_msgs,
    original_task => 'Build a widget system'
);

ok(defined $result1 && $result1->{content}, 'Cycle 1: compression produced output');
my $content1 = $result1->{content};
like($content1, qr/abc1234/, 'Cycle 1: first commit preserved');
like($content1, qr/Add widget renderer/, 'Cycle 1: commit description preserved');

# Cycle 2: Simulate session reload — thread_summary from cycle 1
# is in the message array (as system message), plus new messages.
my @cycle2_msgs = (
    { role => 'system', content => $content1 },
    { role => 'user', content => 'Add CSS styling' },
    { role => 'assistant', content => 'Styling...' },
    { role => 'tool', tool_call_id => 'tc3', content => '[def5678] Add CSS styling' },
);

my $result2 = $yarn->compress_for_context_recovery(
    \@cycle2_msgs,
    original_task => 'Add CSS styling'
);

ok(defined $result2 && $result2->{content}, 'Cycle 2: compression produced output');
my $content2 = $result2->{content};

# Cross-cycle carryover: the previous commit must survive
like($content2, qr/abc1234/, 'Cycle 2 carryover: previous commit abc1234 preserved');
like($content2, qr/Add widget renderer/, 'Cycle 2 carryover: previous commit description preserved');

# New content should also be present
like($content2, qr/def5678/, 'Cycle 2: new commit included');

done_testing();
