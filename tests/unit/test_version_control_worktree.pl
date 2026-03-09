#!/usr/bin/env perl

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

=head1 NAME

test_version_control_worktree.pl - Unit tests for VersionControl worktree operation

=head1 DESCRIPTION

Tests the git worktree operations (list, add, remove, prune, merge, pr) in VersionControl tool.

=cut

use Test::More;
use File::Temp qw(tempdir);
use Cwd qw(getcwd abs_path);

# Test 1: Module loads
BEGIN { use_ok('CLIO::Tools::VersionControl') or BAIL_OUT("Cannot load VersionControl"); }

print "\n=== VersionControl Worktree Tests ===\n\n";

# Test 2: Create VersionControl instance
my $vc = CLIO::Tools::VersionControl->new(debug => 0);
ok($vc, 'VersionControl object created');
isa_ok($vc, 'CLIO::Tools::VersionControl');

# Test 3: worktree is in supported_operations
my @ops = @{$vc->{supported_operations}};
ok((grep { $_ eq 'worktree' } @ops), 'worktree is in supported_operations');

# Test 4: get_additional_parameters includes worktree params
my $params = $vc->get_additional_parameters();
ok(exists $params->{worktree_path}, 'worktree_path parameter defined');
ok(exists $params->{create_branch}, 'create_branch parameter defined');
ok(exists $params->{force}, 'force parameter defined');

# Test 5: action parameter description includes worktree actions
like($params->{action}{description}, qr/add/, 'action description includes add');
like($params->{action}{description}, qr/remove/, 'action description includes remove');
like($params->{action}{description}, qr/prune/, 'action description includes prune');

# Test 6: route_operation routes worktree correctly
# First test with non-git-repo to verify routing reaches the git repo check
my $temp_non_git = tempdir(CLEANUP => 1);
my $result = $vc->route_operation('worktree', { repository_path => $temp_non_git }, {});
ok($result, 'route_operation returns result for worktree');
like($result->{error}, qr/Not a Git repository/, 'worktree routes through git repo check');

# Test 7-12: Set up a real git repo for functional tests
my $temp_repo = tempdir(CLEANUP => 1);
my $original_cwd = getcwd();

# Initialize a git repo
system("cd $temp_repo && git init -b main >/dev/null 2>&1");
system("cd $temp_repo && git config user.email 'test\@test.com' >/dev/null 2>&1");
system("cd $temp_repo && git config user.name 'Test User' >/dev/null 2>&1");
system("cd $temp_repo && echo 'hello' > README.md && git add . && git commit -m 'initial' >/dev/null 2>&1");

# Test 7: worktree list on a real repo
my $list_result = $vc->route_operation('worktree', {
    repository_path => $temp_repo,
    action => 'list',
}, {});
ok(!$list_result->{error}, 'worktree list succeeds on real repo');
like($list_result->{output}, qr/$temp_repo/, 'worktree list shows repo path');
is($list_result->{action}, 'list', 'worktree list metadata action is correct');

# Test 8: worktree add
my $worktree_dir = "$temp_repo/wt-test";
my $add_result = $vc->route_operation('worktree', {
    repository_path => $temp_repo,
    action => 'add',
    worktree_path => $worktree_dir,
    branch => 'test-branch',
    create_branch => 1,
}, {});
ok(!$add_result->{error}, 'worktree add succeeds') or diag("Error: " . ($add_result->{error} || ''));
ok(-d $worktree_dir, 'worktree directory was created');
is($add_result->{action}, 'add', 'worktree add metadata action is correct');
is($add_result->{worktree_path}, $worktree_dir, 'worktree add metadata path is correct');

# Test 9: worktree list now shows two worktrees
my $list_result2 = $vc->route_operation('worktree', {
    repository_path => $temp_repo,
    action => 'list',
}, {});
ok(!$list_result2->{error}, 'worktree list after add succeeds');
like($list_result2->{output}, qr/wt-test/, 'worktree list shows new worktree');

# Test 10: worktree remove
my $remove_result = $vc->route_operation('worktree', {
    repository_path => $temp_repo,
    action => 'remove',
    worktree_path => $worktree_dir,
}, {});
ok(!$remove_result->{error}, 'worktree remove succeeds') or diag("Error: " . ($remove_result->{error} || ''));
ok(! -d $worktree_dir, 'worktree directory was removed');
is($remove_result->{action}, 'remove', 'worktree remove metadata action is correct');

# Test 11: worktree prune
my $prune_result = $vc->route_operation('worktree', {
    repository_path => $temp_repo,
    action => 'prune',
}, {});
ok(!$prune_result->{error}, 'worktree prune succeeds');
is($prune_result->{action}, 'prune', 'worktree prune metadata action is correct');

# Test 12: worktree add without required worktree_path fails gracefully
my $fail_result = $vc->route_operation('worktree', {
    repository_path => $temp_repo,
    action => 'add',
}, {});
ok($fail_result->{error}, 'worktree add without path returns error');
like($fail_result->{error}, qr/Git worktree failed/, 'error message is descriptive');

# Test 13: invalid worktree action fails gracefully
my $invalid_result = $vc->route_operation('worktree', {
    repository_path => $temp_repo,
    action => 'invalid_action',
}, {});
ok($invalid_result->{error}, 'invalid worktree action returns error');
like($invalid_result->{error}, qr/Git worktree failed/, 'invalid action error is descriptive');

# Test 14: worktree add with existing branch (no create)
system("cd $temp_repo && git branch feature-existing >/dev/null 2>&1");
my $worktree_dir2 = "$temp_repo/wt-existing";
my $add_existing_result = $vc->route_operation('worktree', {
    repository_path => $temp_repo,
    action => 'add',
    worktree_path => $worktree_dir2,
    branch => 'feature-existing',
}, {});
ok(!$add_existing_result->{error}, 'worktree add with existing branch succeeds')
    or diag("Error: " . ($add_existing_result->{error} || ''));
ok(-d $worktree_dir2, 'worktree directory for existing branch created');

# Cleanup: remove worktree before temp dir cleanup
system("cd $temp_repo && git worktree remove $worktree_dir2 --force >/dev/null 2>&1");

# Test 15: merge action requires worktree_path
my $merge_no_path = $vc->route_operation('worktree', {
    repository_path => $temp_repo,
    action => 'merge',
}, {});
ok($merge_no_path->{error}, 'merge without worktree_path returns error');
like($merge_no_path->{error}, qr/worktree_path is required/, 'merge error message mentions worktree_path is required');

# Test 16: pr action requires worktree_path
my $pr_no_path = $vc->route_operation('worktree', {
    repository_path => $temp_repo,
    action => 'pr',
}, {});
ok($pr_no_path->{error}, 'pr without worktree_path returns error');
like($pr_no_path->{error}, qr/worktree_path is required/, 'pr error message mentions worktree_path is required');

# Test 17: merge action with a worktree
# Create a worktree with a new branch, make a commit in it, then merge into main
my $merge_wt_dir = "$temp_repo/wt-merge";
system("cd $temp_repo && git worktree add -b merge-feature $merge_wt_dir >/dev/null 2>&1");
system("cd $merge_wt_dir && echo 'merge test' > merge.txt && git add . && git commit -m 'merge commit' >/dev/null 2>&1");

my $merge_result = $vc->route_operation('worktree', {
    repository_path => $temp_repo,
    action => 'merge',
    worktree_path => 'wt-merge',
}, {});
ok(!$merge_result->{error}, 'merge worktree succeeds') or diag("Error: " . ($merge_result->{error} || ''));
is($merge_result->{action}, 'merge', 'merge metadata action is correct');
like($merge_result->{output}, qr/merge-feature|Fast-forward|Merge|Already up to date/i, 'merge output looks reasonable');

# Verify the merged file exists in main
ok(-f "$temp_repo/merge.txt", 'merged file exists in main worktree');

# Cleanup merge worktree
system("cd $temp_repo && git worktree remove $merge_wt_dir --force >/dev/null 2>&1");

# Test 18: pr action with a worktree (no remote, so push will fail - but branch resolution should work)
my $pr_wt_dir = "$temp_repo/wt-pr";
system("cd $temp_repo && git worktree add -b pr-feature $pr_wt_dir >/dev/null 2>&1");

my $pr_result = $vc->route_operation('worktree', {
    repository_path => $temp_repo,
    action => 'pr',
    worktree_path => 'wt-pr',
}, {});
# The push will fail (no remote), but the action should still produce output
ok($pr_result, 'pr action returns a result');
is($pr_result->{action}, 'pr', 'pr metadata action is correct');

# Cleanup pr worktree
system("cd $temp_repo && git worktree remove $pr_wt_dir --force >/dev/null 2>&1");

# Test 19: merge action with non-existent worktree name
my $merge_bad = $vc->route_operation('worktree', {
    repository_path => $temp_repo,
    action => 'merge',
    worktree_path => 'nonexistent-worktree',
}, {});
ok($merge_bad->{error}, 'merge with unknown worktree returns error');
like($merge_bad->{error}, qr/Could not find worktree/, 'error mentions worktree not found');

# Test 20: action description includes merge and pr
my $params_check = $vc->get_additional_parameters();
like($params_check->{action}{description}, qr/merge/, 'action description includes merge');
like($params_check->{action}{description}, qr/pr/, 'action description includes pr');

# Ensure cwd is restored
chdir $original_cwd;

done_testing();

print "\n✓ VersionControl worktree tests PASSED\n";
