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

use Test::More tests => 6;
use CLIO::Memory::YaRN;

my $yarn = CLIO::Memory::YaRN->new();

# Cycle 1: Compress initial messages
my @cycle1_msgs = (
    { role => 'user', content => 'Build a widget system' },
    { role => 'assistant', content => 'Starting...' },
    { role => 'tool', tool_call_id => 'tc1', content => 'Result: created Base.pm' },
    { role => 'user', content => 'Add a renderer' },
    { role => 'assistant', content => 'Writing renderer...' },
);

my $result1 = $yarn->compress_for_context_recovery(
    \@cycle1_msgs,
    original_task => 'Build a widget system'
);

ok(defined $result1 && $result1->{content}, 'Cycle 1: compression produced output');
my $content1 = $result1->{content};
like($content1, qr/Build a widget system/, 'Cycle 1: original task preserved');
like($content1, qr/Add a renderer/, 'Cycle 1: user request preserved');

# Cycle 2: Simulate session reload — thread_summary from cycle 1
# is in the message array (as system message), plus new messages.
my @cycle2_msgs = (
    { role => 'system', content => $content1 },
    { role => 'user', content => 'Add CSS styling' },
    { role => 'assistant', content => 'Styling...' },
    { role => 'tool', tool_call_id => 'tc3', content => 'CSS applied' },
);

my $result2 = $yarn->compress_for_context_recovery(
    \@cycle2_msgs,
    original_task => 'Add CSS styling'
);

ok(defined $result2 && $result2->{content}, 'Cycle 2: compression produced output');
my $content2 = $result2->{content};

# Cross-cycle carryover: previous user requests must survive
like($content2, qr/Build a widget system/, 'Cycle 2 carryover: previous original task preserved');
like($content2, qr/Add a renderer/, 'Cycle 2 carryover: previous user request preserved');

# New content should also be present
like($content2, qr/Add CSS styling/, 'Cycle 2: new user request included');

done_testing();