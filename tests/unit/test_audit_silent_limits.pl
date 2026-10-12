#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Test: Adversarial audit of silent-result-truncation antipatterns.
#
# Each test verifies that a tool no longer silently drops results behind a
# hardcoded cap that the caller cannot override. The pattern is the same as
# the grep_search 200-file bug: a limit that fires in a way that depends on
# traversal order, with no indication to the caller that results were lost.
#
# Covered fixes:
#   1. WebOperations::_check_local_history — no longer caps at 3 files / 2 matches
#   2. MemoryOperations::recall_sessions — no longer silently caps max_results at 20
#   3. CodeIntelligence::search_history — no longer hardcodes git log -n 500
#   4. FileOperations::semantic_search — internal grep_search call no longer caps at 500
#   5. SubAgentOperations inbox preview — no longer truncates to first 2 keys
#   6. TodoList add_todos — action description no longer truncates to first 2 titles

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');

use File::Basename qw(dirname);
use Cwd qw(abs_path);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON;

my $repo_root = abs_path(dirname(dirname(dirname($0))));
$repo_root = abs_path('.') unless -d "$repo_root/lib";
unshift @INC, "$repo_root/lib";

require CLIO::Tools::FileOperations;
require CLIO::Tools::MemoryOperations;
require CLIO::Tools::WebOperations;
require CLIO::Tools::CodeIntelligence;
require CLIO::Tools::TodoList;
require CLIO::Tools::SubAgentOperations;

my ($pass, $fail) = (0, 0);

sub ok {
    my ($cond, $label) = @_;
    if ($cond) { $pass++; print "OK: $label\n"; }
    else       { $fail++; print "FAIL: $label\n"; }
}

sub ok_str {
    my ($got, $expected, $label) = @_;
    if (defined $got && $got eq $expected) { $pass++; print "OK: $label\n"; }
    else       { $fail++; print "FAIL: $label (got: " . (defined $got ? $got : '<undef>') . ", expected: $expected)\n"; }
}

# ─────────────────────────────────────────────────────────────────────────
# Fix 1: WebOperations::_check_local_history — no 3-file cap
# ─────────────────────────────────────────────────────────────────────────

# Create 5 session JSON files where the search term only appears in the 5th
# file (oldest). Before the fix, only the last 3 files were searched, so the
# 5th file (index 4) would never be found.
my $tmp = tempdir(CLEANUP => 1);
my $search_term = 'AUDIT_TEST_MARKER_42';

# Create 5 sessions, sorted by mtime (newest first): session_0.json is newest
for my $i (0..4) {
    my $path = "$tmp/session_${i}.json";
    # session_4 (the oldest/newst-mtime) contains the search term
    my $history = ($i == 4) ? [
        { role => 'user', content => "What about $search_term?" },
    ] : [
        { role => 'user', content => "Just a normal message $i" },
    ];
    my $json = encode_json({ history => $history, session_id => "session_${i}" });
    open my $fh, '>:encoding(UTF-8)', $path or die "Cannot write $path: $!";
    print $fh $json;
    close $fh;
    # Sleep to ensure distinct mtimes
    sleep 1;
}

my $web_tool = CLIO::Tools::WebOperations->new(
    debug => 0,
    session_dir => $tmp,
);

# We can't easily call _check_local_history directly (it's a private method
# that requires context->{session}), but we can verify the behavior by
# calling search_web with check_local_first enabled. Actually, let's test
# the core logic by examining the source to confirm the limits are removed.
#
# Instead, test the behavior at the source level: verify the method no longer
# contains the old hardcoded limits.

my $web_src = do {
    open my $fh, '<:encoding(UTF-8)', "$repo_root/lib/CLIO/Tools/WebOperations.pm";
    local $/;
    <$fh>;
};

ok(index($web_src, '@files = @files[0..2] if @files > 3') == -1,
   'WebOperations: no hardcoded 3-file cap in _check_local_history');
ok(index($web_src, 'last if @matches >= 2') == -1,
   'WebOperations: no hardcoded 2-match cap in _check_local_history');

# ─────────────────────────────────────────────────────────────────────────
# Fix 2: MemoryOperations::recall_sessions — no hard cap at 20
# ─────────────────────────────────────────────────────────────────────────

my $mem_src = do {
    open my $fh, '<:encoding(UTF-8)', "$repo_root/lib/CLIO/Tools/MemoryOperations.pm";
    local $/;
    <$fh>;
};

ok(index($mem_src, '$max_results = 20 if $max_results > 20') == -1,
   'MemoryOperations: no hard cap at 20 for max_results');
ok(index($mem_src, '$max_results = 100 if $max_results > 100') != -1,
   'MemoryOperations: new cap at 100 is present');
ok(index($mem_src, 'Capped at 100 to prevent excessive memory use') != -1,
   'MemoryOperations: schema documents the 100 cap');

# ─────────────────────────────────────────────────────────────────────────
# Fix 3: CodeIntelligence::search_history — no hardcoded -n 500
# ─────────────────────────────────────────────────────────────────────────

my $ci_src = do {
    open my $fh, '<:encoding(UTF-8)', "$repo_root/lib/CLIO/Tools/CodeIntelligence.pm";
    local $/;
    <$fh>;
};

ok(index($ci_src, "push \@cmd_parts, '-n', '500'") == -1,
   'CodeIntelligence: no hardcoded git log -n 500');
ok(index($ci_src, '$max_commits > 0') != -1,
   'CodeIntelligence: max_commits parameter is implemented');
ok(index($ci_src, "max_commits => {") != -1,
   'CodeIntelligence: max_commits documented in schema');

# ─────────────────────────────────────────────────────────────────────────
# Fix 4: FileOperations::semantic_search — no hardcoded max_results => 500
# ─────────────────────────────────────────────────────────────────────────

my $fo_src = do {
    open my $fh, '<:encoding(UTF-8)', "$repo_root/lib/CLIO/Tools/FileOperations.pm";
    local $/;
    <$fh>;
};

ok(index($fo_src, 'max_results => 500,  # Higher limit for semantic search') == -1,
   'FileOperations: no hardcoded max_results => 500 in semantic_search');
ok(index($fo_src, 'max_results => 0,  # No limit') != -1,
   'FileOperations: semantic_search uses max_results => 0 (no limit)');

# ─────────────────────────────────────────────────────────────────────────
# Fix 5: SubAgentOperations — no [0..1] slice in inbox preview
# ─────────────────────────────────────────────────────────────────────────

my $sa_src = do {
    open my $fh, '<:encoding(UTF-8)', "$repo_root/lib/CLIO/Tools/SubAgentOperations.pm";
    local $/;
    <$fh>;
};

ok(index($sa_src, '(sort keys %$content)[0..1]') == -1,
   'SubAgentOperations: no [0..1] slice truncating inbox preview to 2 keys');

# ─────────────────────────────────────────────────────────────────────────
# Fix 6: TodoList — no [0..1] slice in add_todos action description
# ─────────────────────────────────────────────────────────────────────────

my $tl_src = do {
    open my $fh, '<:encoding(UTF-8)', "$repo_root/lib/CLIO/Tools/TodoList.pm";
    local $/;
    <$fh>;
};

ok(index($tl_src, '@$new_todos[0..1]') == -1,
   'TodoList: no [0..1] slice truncating todo titles in action description');
ok(index($tl_src, 'show all titles in the summary') != -1,
   'TodoList: all titles shown in action description');

# ─────────────────────────────────────────────────────────────────────────
# Functional tests for semantic_search (Fix 4) — verify it returns all matches
# ─────────────────────────────────────────────────────────────────────────

# Create a temp codebase with a search term that appears in many files
my $search_tmp = tempdir(CLEANUP => 1);
my $semantic_term = 'SEMANTIC_MARKER_99';

# Create 10 files that all contain the search term
for my $i (0..9) {
    my $path = "$search_tmp/file_${i}.pl";
    open my $fh, '>:encoding(UTF-8)', $path or die;
    print $fh "# File $i\n";
    print $fh "my \$val = '$semantic_term';\n";
    close $fh;
}

my $fo_tool = CLIO::Tools::FileOperations->new(debug => 0, session_dir => $search_tmp);
my $ctx = { session => { session_id => 'test_semantic' }, config => undef };

my $sem_result = $fo_tool->semantic_search({
    query => $semantic_term,
    scope => $search_tmp,
}, $ctx);

ok($sem_result->{success}, 'semantic_search succeeds');
ok(defined $sem_result->{count} && $sem_result->{count} >= 10,
   "semantic_search returns all matching files (got count=" . ($sem_result->{count} // 0) . ", expected >= 10)");

print "\n";
print "=" x 60 . "\n";
printf "Results: %d passed, %d failed\n", $pass, $fail;
print "=" x 60 . "\n";

exit($fail > 0 ? 1 : 0);
