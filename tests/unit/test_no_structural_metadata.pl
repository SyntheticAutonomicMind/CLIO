#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Test: No structural metadata in model-facing content

use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/../../lib";

use Test::More;
use CLIO::Memory::YaRN;
use CLIO::Core::MessageHistory qw(messages_to_prose_dynamic);

# Build messages for YaRN compression
my $yarn = CLIO::Memory::YaRN->new();

my @messages = (
    { role => 'user', content => 'Build a new feature' },
    { role => 'assistant', content => 'Working on it' },
    { role => 'tool', tool_call_id => 'tc1', content => 'File contents here' },
    { role => 'user', content => 'Also fix tests' },
);

my $result = $yarn->compress_for_context_recovery(
    \@messages,
    original_task => 'Build a new feature'
);

my $summary = $result->{content} // '';

# Build projection for prose rendering
my $projection = {
    compressed_tail => $summary,
    active_task => 'Build a new feature',
    active_todos => [
        { status => 'in-progress', content => 'Write the feature' },
        { status => 'completed', content => 'Review code' },
    ],
    unresolved => [
        'Test failure in test_feature.pl',
    ],
    relevant_memory => [
        { confidence => 0.95, content => 'Always check LTM first before debugging', type => 'pattern' },
    ],
    ltm_total_count => 5,
    environment => {
        working_directory => '/home/user/project',
        language => 'English',
        datetime_iso => '2026-09-06T10:00:00Z',
    },
    context_files_block => '',
};

my $prose = messages_to_prose_dynamic($projection);

# Check thread_summary for structural metadata
unlike($summary, qr/\(\d\.\d+\)/, 'thread_summary has no confidence scores');
unlike($summary, qr/^#\s/m, 'thread_summary has no # markdown headers');
unlike($summary, qr/<current_topic>|<task_recovery>|<recent_context>|<git_recovery>|<session_progress>/,
    'thread_summary has no XML recovery tags');

# Check dynamic userContext for structural metadata
unlike($prose, qr/\(\d\.\d+\)/, 'dynamic UC has no confidence scores');
unlike($prose, qr/^#\s/m, 'dynamic UC has no # markdown headers');
unlike($prose, qr/call memory_operations/, 'dynamic UC has no memory_operations instruction');
unlike($prose, qr/more memories available/, 'dynamic UC has no "more memories available"');
unlike($prose, qr/<current_topic>|<task_recovery>|<recent_context>|<git_recovery>|<session_progress>|<sessionContext>|<dynamicContext>/,
    'dynamic UC has no XML tags');

# Verify working directory leads
like($prose, qr/^Working directory:/, 'dynamic UC leads with working directory');

done_testing();
