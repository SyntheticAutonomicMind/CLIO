#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Test: No framework narration in any thread_summary output

use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/../../lib";

use Test::More tests => 6;
use CLIO::Memory::YaRN;

my $yarn = CLIO::Memory::YaRN->new();

my @messages = (
    {
        role => 'system',
        content => '<thread_summary>

Current task: Fix the login bug

Files:
- lib/Auth.pm

Tools:
- file_operations: 3 calls
</thread_summary>'
    },
    { role => 'user', content => 'Also fix the password reset flow' },
    { role => 'assistant', content => 'Looking at the code...' },
    { role => 'tool', tool_call_id => 'tc1', content => 'file data' },
    { role => 'user', content => 'Add tests too' },
);

my $result = $yarn->compress_for_context_recovery(
    \@messages,
    original_task => 'Also fix the password reset flow'
);

ok(defined $result, 'Compression produced a result');
my $content = $result->{content} // '';
ok(length($content) > 0, 'Result content is non-empty');

# Check for framework narration patterns that must NOT appear
my @forbidden = (
    qr/To recover more context/,
    qr/DO NOT read handoff/,
    qr/Continue working on whatever/,
    qr/Do NOT say things/,
    qr/I've recovered context/,
    qr/<current_topic>/,
    qr/<task_recovery>/,
    qr/<recent_context>/,
    qr/<git_recovery>/,
    qr/<session_progress>/,
);

my $narration_found = 0;
for my $pattern (@forbidden) {
    if ($content =~ $pattern) {
        $narration_found++;
        diag("Forbidden narration found matching: $pattern");
    }
}

is($narration_found, 0, 'No framework narration or XML tags in thread_summary output');

# Verify the output is valid (has the thread_summary wrapper)
like($content, qr/<thread_summary>.*<\/thread_summary>/s, 'Output has proper <thread_summary> wrapper');

# Verify no confidence scores
unlike($content, qr/\(\d\.\d+\)/, 'No confidence scores in output');

# Verify no # section headers (YaRN section headers like "Commits:" are OK,
# but markdown "#" headers are not)
unlike($content, qr/^#\s/m, 'No markdown # section headers in output');

done_testing();
