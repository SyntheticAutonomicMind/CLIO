#!/usr/bin/perl
#
# Regression test: _parse_previous_summary must not leak entries
# between sections. Previously, the /s modifier on the outer regex
# made .+ match across newlines, so each section's regex swallowed
# entries from all downstream sections (e.g. "Tool usage:" counts
# appeared in "Recent user requests:" and "Files created/modified:").
#
use strict;
use warnings;
use Test::More tests => 6;

use lib './lib';
use CLIO::Memory::YaRN;

my $summary = <<'END_SUMMARY';
<thread_summary>

Current task: Fix the bug

Recent user requests:
- What is the task
- Fix the bug

Commits:
- abc1234: first commit

Files:
- /path/to/file1.pm
- /path/to/file2.pm

Decisions:
- We chose approach A

Tools:
- file_operations: 10 calls
- terminal_operations: 2 calls

</thread_summary>
END_SUMMARY

my %buckets = (
    user_requests           => [],
    commits                 => [],
    files_touched           => [],
    decisions               => [],
    tool_counts             => {},
    collaboration_exchanges => [],
    persisted_chunks        => [],
);

CLIO::Memory::YaRN::_parse_previous_summary($summary, \%buckets);

# user_requests must NOT contain tool call entries
my @tool_leaks_in_user = grep { /^[\w-]+:\s*\d+\s+calls$/ } @{$buckets{user_requests}};
is(scalar(@tool_leaks_in_user), 0,
   'No tool call entries leaked into user_requests');

# files_touched must NOT contain tool call entries
my @tool_leaks_in_files = grep { /^[\w-]+:\s*\d+\s+calls$/ } @{$buckets{files_touched}};
is(scalar(@tool_leaks_in_files), 0,
   'No tool call entries leaked into files_touched');

# files_touched must NOT contain section headers from other sections
my @header_leaks = grep { /^(Commits|Decisions|Tools):$/ } @{$buckets{files_touched}};
is(scalar(@header_leaks), 0,
   'No section headers leaked into files_touched');

# decisions must NOT contain tool call entries
my @tool_leaks_in_decisions = grep { /^[\w-]+:\s*\d+\s+calls$/ } @{$buckets{decisions}};
is(scalar(@tool_leaks_in_decisions), 0,
   'No tool call entries leaked into decisions');

# commits must contain only commit entries
is(scalar(@{$buckets{commits}}), 1,
   'commits has exactly 1 entry (no leakage)');

# tool_counts must have correct counts from Tools section only
is($buckets{tool_counts}{file_operations}, 10,
   'file_operations count is correct (10, not leaked from other sections)');

done_testing();
