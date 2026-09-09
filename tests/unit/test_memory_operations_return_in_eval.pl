#!/usr/bin/env perl
# Test: MemoryOperations methods properly return error_result (not undef)
# when the return path would have been caught by eval.
#
# Root cause: In Perl 5.42, `return` inside `eval { }` returns from the eval
# block, not from the enclosing subroutine. If code does:
#   my $result;
#   eval { return $self->error_result(...) unless $cond; ... $result = ...; };
#   return $result;
# The error_result is returned from the eval (discarded), $result stays undef,
# and `return $result` returns undef to the caller. ToolExecutor sees "undefined"
# and reports "Tool returned invalid result".
#
# This test verifies that after the fix, all code paths properly return a
# hashref (success or error result) instead of undef.

use strict;
use warnings;
use Test::More;
use File::Temp;
use File::Spec;
use Cwd;

use lib 'lib';
use CLIO::Tools::MemoryOperations;
use CLIO::Session::State;
use CLIO::Session::Manager;
use CLIO::Util::JSON qw(encode_json);

my $tool = CLIO::Tools::MemoryOperations->new();

# Plan: 3 + 2 + 3 + 2 + 3 + 3 + 7*3 = 42 assertions, but done_testing handles it
# Use done_testing() at the end instead of plan.

# ─── Helper: create mock session with empty goals ─────────────────────
sub make_mock_session {
    my $id = shift // "test";
    my $state = CLIO::Session::State->new(session_id => $id);
    $state->{session_goals} = [];
    return bless { state => $state, session_id => $id }, "CLIO::Session::Manager";
}

# ─── 1. retrieve: empty state goals + nonexistent file ────────────────
{
    my $session = make_mock_session("retrieve-empty");
    my $params = {
        operation => "retrieve",
        key       => "session_goals",
        memory_dir => "/tmp/clio_test_nonexistent_mem_dir_xyz_1",
    };
    my $context = { session => $session };

    my $result = $tool->execute($params, $context);
    ok(ref($result) eq 'HASH', 'retrieve returns HASH when goals empty + file missing');
    ok($result->{success} == 0, 'retrieve returns error result (success=0)');
    like($result->{error}, qr/Memory not found/, 'retrieve error mentions "Memory not found"');
}

# ─── 2. retrieve: no session context + nonexistent file ───────────────
{
    my $params = {
        operation => "retrieve",
        key       => "nonexistent_key",
        memory_dir => "/tmp/clio_test_nonexistent_mem_dir_xyz_2",
    };
    my $context = {};

    my $result = $tool->execute($params, $context);
    ok(ref($result) eq 'HASH', 'retrieve returns HASH when no session + file missing');
    ok($result->{success} == 0, 'retrieve returns error result without session');
}

# ─── 3. retrieve: success path still works ────────────────────────────
{
    my $tmpdir = File::Temp->newdir();
    my $mem_dir = File::Spec->catdir($tmpdir->dirname, 'mem');
    mkdir $mem_dir;
    my $file = File::Spec->catfile($mem_dir, 'mykey.json');
    open my $fh, '>:utf8', $file or die "Cannot write $file: $!";
    print $fh encode_json({ key => 'mykey', content => 'hello world', timestamp => time() });
    close $fh;

    my $params = {
        operation => "retrieve",
        key       => "mykey",
        memory_dir => $mem_dir,
    };
    my $context = {};

    my $result = $tool->execute($params, $context);
    ok(ref($result) eq 'HASH', 'retrieve returns HASH on success');
    ok($result->{success} == 1, 'retrieve success result');
    like($result->{output}, qr/hello world/, 'retrieve returns correct content');
}

# ─── 4. list (list_memories): nonexistent directory ───────────────────
{
    my $params = {
        operation => "list",
        memory_dir => "/tmp/clio_test_nonexistent_mem_dir_xyz_4",
    };
    my $context = {};

    my $result = $tool->execute($params, $context);
    ok(ref($result) eq 'HASH', 'list returns HASH when dir missing');
    ok($result->{success} == 0, 'list returns error result');
    like($result->{error}, qr/directory not found/, 'list error mentions directory not found');
}

# ─── 5. delete: nonexistent file ──────────────────────────────────────
{
    my $params = {
        operation => "delete",
        key       => "nonexistent_to_delete",
        memory_dir => "/tmp/clio_test_nonexistent_mem_dir_xyz_5",
    };
    my $context = {};

    my $result = $tool->execute($params, $context);
    ok(ref($result) eq 'HASH', 'delete returns HASH when file missing');
    ok($result->{success} == 0, 'delete returns error result');
    like($result->{error}, qr/Memory not found/, 'delete error mentions Memory not found');
}

# ─── 6. recall_sessions: nonexistent sessions dir ─────────────────────
# The recall_sessions method hardcodes '.clio/sessions' as the sessions
# directory. We run this test from a temp dir where that doesn't exist,
# to verify the method returns a proper error_result (not undef) when the
# directory is missing -- the exact bug this test suite was written for.
{
    my $tmpdir = File::Temp->newdir();
    my $orig_cwd = Cwd::getcwd();
    chdir $tmpdir->dirname or die "Cannot chdir to $tmpdir: $!";

    my $params = {
        operation => "recall_sessions",
        query     => "some query",
    };
    my $context = {};

    my $result = $tool->execute($params, $context);
    ok(ref($result) eq 'HASH', 'recall_sessions returns HASH when sessions dir missing');
    ok($result->{success} == 0, 'recall_sessions returns error result');
    like($result->{error}, qr/Sessions directory not found/, 'recall_sessions error mentions directory not found');

    chdir $orig_cwd or die "Cannot chdir back to $orig_cwd: $!";
}

# ─── 7. LTM methods: no LTM in context ────────────────────────────────
for my $method (qw(add_discovery add_solution add_pattern update_ltm prune_ltm ltm_stats add_corroboration)) {
    my $params;
    if ($method eq 'add_discovery') {
        $params = { operation => $method, fact => "test fact" };
    } elsif ($method eq 'add_solution') {
        $params = { operation => $method, error => "test error", solution => "test solution" };
    } elsif ($method eq 'add_pattern') {
        $params = { operation => $method, pattern => "test pattern" };
    } elsif ($method eq 'update_ltm') {
        $params = { operation => $method, search_text => "old", replacement => "new" };
    } elsif ($method eq 'prune_ltm') {
        $params = { operation => $method };
    } elsif ($method eq 'ltm_stats') {
        $params = { operation => $method };
    } elsif ($method eq 'add_corroboration') {
        $params = { operation => $method, search_text => "some text" };
    }

    my $context = {};  # No LTM in context
    my $result = $tool->execute($params, $context);
    ok(ref($result) eq 'HASH', "$method returns HASH when LTM not available");
    ok($result->{success} == 0, "$method returns error result");
    like($result->{error}, qr/LTM not available/, "$method error mentions LTM not available");
}

done_testing();
