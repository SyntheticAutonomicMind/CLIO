#!/usr/bin/env perl

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

=head1 NAME

test_version_control_validation.pl - Regression tests for tool validation error messages

=head1 DESCRIPTION

Verifies that VersionControl tool operations (branch, tag, stash, worktree) return
clean error_result() messages for parameter validation failures, instead of croak
errors that leak the internal file path and line number through the eval/croak
chain.

Reproduces the bug seen in production: AI calls `version_control(operation="branch",
action="create")` with no `name`, and sees an error like:
    Error: Git branch failed: Invalid branch action or missing name at
    /Users/.../ToolExecutor.pm line 358

After the fix, the error should be:
    Error: Missing required parameter: name (required for action 'create')

The error must:
  1. NOT contain "at /" followed by a file path (no caller-location leak)
  2. NOT contain the wrapping prefix "Git X failed:" (caller wraps; the tool
     returns the clean message)
  3. Match the ToolErrorGuidance categories (missing_required / invalid_value)
  4. Distinguish between "invalid action" and "missing required parameter"

=cut

use Test::More;
use File::Temp qw(tempdir);
use Cwd qw(getcwd);

BEGIN { use_ok('CLIO::Tools::VersionControl') or BAIL_OUT("Cannot load VersionControl"); }
use_ok('CLIO::Core::ToolErrorGuidance');

print "\n=== VersionControl Validation Tests ===\n\n";

my $vc = CLIO::Tools::VersionControl->new(debug => 0);
ok($vc, 'VersionControl object created');

# Set up a real git repo so we don't get "Not a Git repository" instead of the
# validation error we're testing.
my $temp_repo = tempdir(CLEANUP => 1);
my $original_cwd = getcwd();
system("cd $temp_repo && git init -b main >/dev/null 2>&1");
system("cd $temp_repo && git config user.email 'test\@test.com' >/dev/null 2>&1");
system("cd $temp_repo && git config user.name 'Test User' >/dev/null 2>&1");
system("cd $temp_repo && git config commit.gpgsign false >/dev/null 2>&1");
system("cd $temp_repo && echo 'hello' > README.md && git add . && git commit -m 'initial' >/dev/null 2>&1");

# Helper: assert the result is a clean error with no caller-location leak
sub assert_clean_error {
    my (%args) = @_;
    my $result = $args{result};
    my $description = $args{description};
    my $expected_substring = $args{expected_substring};
    my $expected_pattern = $args{expected_pattern};

    ok($result, "$description: result is defined");
    ok($result->{error}, "$description: result has error key");
    ok(!$result->{success}, "$description: success is false");

    my $err = $result->{error};
    unlike($err, qr{ at \S+\.pm line \d+},
        "$description: error does not leak caller file/line ($err)");
    unlike($err, qr{^Git \w+ failed:},
        "$description: error does not have outer 'Git X failed:' wrapper ($err)");

    if ($expected_substring) {
        like($err, qr/\Q$expected_substring\E/,
            "$description: error contains '$expected_substring' ($err)");
    }
    if ($expected_pattern) {
        like($err, $expected_pattern,
            "$description: error matches expected pattern ($err)");
    }
    return $err;
}

# Helper: assert ToolErrorGuidance categorizes the error correctly
sub assert_guidance_category {
    my (%args) = @_;
    my $guidance = CLIO::Core::ToolErrorGuidance->new();
    my $error = $args{error};
    my $tool_name = $args{tool_name};
    my $expected_category_marker = $args{expected_marker};

    my $enhanced = $guidance->enhance_tool_error(
        error => $error,
        tool_name => $tool_name,
        tool_definition => {},
        attempted_params => {},
    );

    if ($expected_category_marker eq 'missing_required') {
        like($enhanced, qr/required field\(s\)/i,
            "  -> guidance for $tool_name error categorized as missing_required ($error)");
    } elsif ($expected_category_marker eq 'invalid_value') {
        like($enhanced, qr/wrong type|wrong range/i,
            "  -> guidance for $tool_name error categorized as invalid_value ($error)");
    } else {
        fail("unknown expected category: $expected_category_marker");
    }
}

# ============================================================
# BRANCH
# ============================================================
print "--- branch ---\n";

# The bug: sub_action=create, name missing -> croak + eval wraps with "at file line N"
my $r = $vc->route_operation('branch', {
    repository_path => $temp_repo,
    sub_action => 'create',
    # name intentionally omitted
}, {});
my $err = assert_clean_error(
    result => $r,
    description => 'branch: action=create without name',
    expected_substring => 'Missing required parameter: name',
);
assert_guidance_category(error => $err, tool_name => 'version_control', expected_marker => 'missing_required');

# delete without name
$r = $vc->route_operation('branch', {
    repository_path => $temp_repo,
    sub_action => 'delete',
}, {});
$err = assert_clean_error(
    result => $r,
    description => 'branch: action=delete without name',
    expected_substring => 'Missing required parameter: name',
);
assert_guidance_category(error => $err, tool_name => 'version_control', expected_marker => 'missing_required');

# switch without name
$r = $vc->route_operation('branch', {
    repository_path => $temp_repo,
    sub_action => 'switch',
}, {});
$err = assert_clean_error(
    result => $r,
    description => 'branch: action=switch without name',
    expected_substring => 'Missing required parameter: name',
);
assert_guidance_category(error => $err, tool_name => 'version_control', expected_marker => 'missing_required');

# invalid action
$r = $vc->route_operation('branch', {
    repository_path => $temp_repo,
    sub_action => 'foo',
}, {});
$err = assert_clean_error(
    result => $r,
    description => 'branch: invalid action',
    expected_substring => "Invalid action 'foo'",
);
assert_guidance_category(error => $err, tool_name => 'version_control', expected_marker => 'invalid_value');

# list with name should still work (name is ignored for list)
$r = $vc->route_operation('branch', {
    repository_path => $temp_repo,
    sub_action => 'list',
    name => 'whatever',
}, {});
ok($r && !$r->{error}, 'branch: list with extra name succeeds')
    or diag("Error: " . ($r->{error} || ''));

# ============================================================
# TAG
# ============================================================
print "--- tag ---\n";

$r = $vc->route_operation('tag', {
    repository_path => $temp_repo,
    sub_action => 'create',
}, {});
$err = assert_clean_error(
    result => $r,
    description => 'tag: action=create without name',
    expected_substring => 'Missing required parameter: name',
);
assert_guidance_category(error => $err, tool_name => 'version_control', expected_marker => 'missing_required');

$r = $vc->route_operation('tag', {
    repository_path => $temp_repo,
    sub_action => 'delete',
}, {});
$err = assert_clean_error(
    result => $r,
    description => 'tag: action=delete without name',
    expected_substring => 'Missing required parameter: name',
);
assert_guidance_category(error => $err, tool_name => 'version_control', expected_marker => 'missing_required');

$r = $vc->route_operation('tag', {
    repository_path => $temp_repo,
    sub_action => 'foo',
}, {});
$err = assert_clean_error(
    result => $r,
    description => 'tag: invalid action',
    expected_substring => "Invalid action 'foo'",
);
assert_guidance_category(error => $err, tool_name => 'version_control', expected_marker => 'invalid_value');

# ============================================================
# STASH
# ============================================================
print "--- stash ---\n";

$r = $vc->route_operation('stash', {
    repository_path => $temp_repo,
    sub_action => 'foo',
}, {});
$err = assert_clean_error(
    result => $r,
    description => 'stash: invalid action',
    expected_substring => "Invalid action 'foo'",
);
assert_guidance_category(error => $err, tool_name => 'version_control', expected_marker => 'invalid_value');

$r = $vc->route_operation('stash', {
    repository_path => $temp_repo,
    sub_action => 'list',
}, {});
ok($r && !$r->{error}, 'stash: list succeeds')
    or diag("Error: " . ($r->{error} || ''));

# ============================================================
# WORKTREE
# ============================================================
print "--- worktree ---\n";

$r = $vc->route_operation('worktree', {
    repository_path => $temp_repo,
    sub_action => 'add',
}, {});
$err = assert_clean_error(
    result => $r,
    description => 'worktree: action=add without worktree_path',
    expected_substring => 'Missing required parameter: worktree_path',
);
assert_guidance_category(error => $err, tool_name => 'version_control', expected_marker => 'missing_required');

$r = $vc->route_operation('worktree', {
    repository_path => $temp_repo,
    sub_action => 'remove',
}, {});
$err = assert_clean_error(
    result => $r,
    description => 'worktree: action=remove without worktree_path',
    expected_substring => 'Missing required parameter: worktree_path',
);
assert_guidance_category(error => $err, tool_name => 'version_control', expected_marker => 'missing_required');

$r = $vc->route_operation('worktree', {
    repository_path => $temp_repo,
    sub_action => 'merge',
}, {});
$err = assert_clean_error(
    result => $r,
    description => 'worktree: action=merge without worktree_path',
    expected_substring => 'Missing required parameter: worktree_path',
);
assert_guidance_category(error => $err, tool_name => 'version_control', expected_marker => 'missing_required');

$r = $vc->route_operation('worktree', {
    repository_path => $temp_repo,
    sub_action => 'pr',
}, {});
$err = assert_clean_error(
    result => $r,
    description => 'worktree: action=pr without worktree_path',
    expected_substring => 'Missing required parameter: worktree_path',
);
assert_guidance_category(error => $err, tool_name => 'version_control', expected_marker => 'missing_required');

$r = $vc->route_operation('worktree', {
    repository_path => $temp_repo,
    sub_action => 'foo',
}, {});
$err = assert_clean_error(
    result => $r,
    description => 'worktree: invalid action',
    expected_substring => "Invalid action 'foo'",
);
assert_guidance_category(error => $err, tool_name => 'version_control', expected_marker => 'invalid_value');

# ============================================================
# FULL PIPELINE TEST: The exact scenario from the bug report
# ============================================================
print "--- full pipeline (bug reproduction) ---\n";

# The original error: "Git branch failed: Invalid branch action or missing name
# at /Users/andrew/.local/clio/lib/CLIO/Core/ToolExecutor.pm line 358."
# Simulate the WorkflowOrchestrator display path: result.error is wrapped
# with the operation name and displayed to the user.
# Reproduce: version_control(operation="branch", sub_action="create") with no `name`
$r = $vc->route_operation('branch', {
    repository_path => $temp_repo,
    sub_action => 'create',
}, {});

# What the user sees in the action_detail line:
my $user_visible = "branch: " . $r->{error};
like($user_visible, qr/Missing required parameter: name/,
    'user-visible message mentions the missing parameter');
unlike($user_visible, qr{ToolExecutor\.pm line},
    'user-visible message does NOT leak ToolExecutor.pm line number');
unlike($user_visible, qr{Git branch failed},
    'user-visible message does NOT have outer "Git branch failed" wrapping');

# Ensure cwd is restored
chdir $original_cwd;

done_testing();

print "\n VersionControl validation tests PASSED\n";
