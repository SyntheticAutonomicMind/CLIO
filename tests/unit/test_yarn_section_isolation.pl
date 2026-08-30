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
<threadSummary>

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

</threadSummary>
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

# tool_counts must be empty - tool counts are no longer parsed into buckets
# (the "Tools:" section is not a rendering section; tool call IDs for
# re-reading are tracked via persisted_chunks instead)
is(scalar(keys %{$buckets{tool_counts} || {}}), 0,
   'No tool_counts entries — counts are no longer parsed');

done_testing();
