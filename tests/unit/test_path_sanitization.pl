#!/usr/bin/env perl
# test_path_sanitization.pl - Test that AI-emitted quoted paths are sanitized
# Bug: AI sometimes emits tool calls like path=`"/home/foo/test.txt"` (with literal
# quote chars) instead of `/home/foo/test.txt`. Without sanitization, CLIO's
# directory-creation helpers (make_path, mkdir) treat the leading `"` as a
# directory name and create a literal `"` directory.

use strict;
use warnings;
use utf8;
use File::Basename qw(dirname);
use Cwd qw(getcwd abs_path);
use File::Temp qw(tempdir);
use File::Spec;
use File::Path qw(remove_tree make_path);
use CLIO::Util::PathResolver qw(strip_path_quotes);

# Add lib path - use absolute path since we chdir to test_dir below
use lib abs_path(dirname(__FILE__) . '/../../lib');

my $DQ = chr(34);  # "
my $SQ = chr(39);  # '

# Run all tests in an isolated temp directory so relative paths in
# operations resolve consistently and we don't pollute the repo.
my $test_dir = tempdir(CLEANUP => 1);
chdir $test_dir or die "Cannot chdir to $test_dir: $!";

my $passed = 0;
my $failed = 0;

sub test_case {
    my ($desc, $cond, $err) = @_;
    if ($cond) {
        print "PASS: $desc\n";
        return 1;
    } else {
        print "FAIL: $desc";
        print " (error: $err)" if defined $err;
        print "\n";
        return 0;
    }
}

# ---------------------------------------------------------------------------
# Unit tests for strip_path_quotes() itself
# ---------------------------------------------------------------------------
print "\n=== strip_path_quotes() unit tests ===\n";

my @unit_tests = (
    # The bug patterns (most important)
    [$DQ . "/home/foo/test.txt" . $DQ, "/home/foo/test.txt", "BUG PATTERN: balanced double quotes"],
    [$SQ . "/home/foo/test.txt" . $SQ, "/home/foo/test.txt", "BUG PATTERN: balanced single quotes"],

    [$DQ . "test.txt" . $DQ, "test.txt", "balanced short path"],

    [$DQ . "/home/foo/test.txt", "/home/foo/test.txt", "unbalanced leading dq + path-like next char"],
    [$SQ . "/home/foo/test.txt", "/home/foo/test.txt", "unbalanced leading sq + path-like next char"],

    ["foo" . $DQ . "bar", "foo" . $DQ . "bar", "embedded quote preserved"],
    ["/home/foo/" . $DQ . "test.txt" . $DQ, "/home/foo/" . $DQ . "test.txt" . $DQ, "mid-string quotes preserved"],

    ["/home/foo/test.txt", "/home/foo/test.txt", "no quotes (control case)"],
    ["test.txt", "test.txt", "relative path (control case)"],

    [$DQ . $DQ, $DQ . $DQ, "empty pair preserved for downstream empty check"],
    [$DQ, $DQ, "single quote preserved (not path-like)"],
    ["", "", "empty string"],
);

for my $t (@unit_tests) {
    my ($input, $expected, $desc) = @$t;
    my $got = strip_path_quotes($input);
    if (test_case($desc, $got eq $expected)) {
        $passed++;
    } else {
        $failed++;
        print "  input    = [$input]\n";
        print "  expected = [$expected]\n";
        print "  got      = [$got]\n";
    }
}

# undef should return undef
my $undef_result = strip_path_quotes(undef);
if (test_case("undef returns undef", !defined $undef_result)) {
    $passed++;
} else {
    $failed++;
}

# ---------------------------------------------------------------------------
# Integration: file_operations tools must not create a `"` directory when
# AI-emitted quoted paths are passed.
# ---------------------------------------------------------------------------
print "\n=== file_operations integration tests ===\n";

require CLIO::Tools::FileOperations;
my $fo = CLIO::Tools::FileOperations->new(session_dir => $test_dir);

my $ctx = {
    config => undef,
    session => { session_id => 'test' },
};

my $weird_dir = File::Spec->catdir($test_dir, $DQ);

# Helper: assert NO directory named $DQ exists in test_dir
sub assert_no_quote_dir {
    my ($desc) = @_;
    if (-d $weird_dir) {
        test_case($desc, 0, "directory '$DQ' exists at $weird_dir (BUG!)");
        return 0;
    }
    test_case($desc, 1);
    return 1;
}

# Test 1: create_file with quoted path (using write_file since create_file is aliased)
print "\n--- Test: create_file with quoted path ---\n";
my $result = $fo->execute(
    { operation => 'write_file', path => $DQ . "test-create.txt" . $DQ, content => "test\n" },
    $ctx
);
$passed++ if test_case("create_file returned success", $result->{success}, $result->{error});
$failed++ unless $result->{success};
$passed++ if assert_no_quote_dir("create_file: no '$DQ' directory created");

# Verify the file was created at the correct location (not under '"')
my $expected_file = File::Spec->catfile($test_dir, "test-create.txt");
$passed++ if test_case("create_file: file at correct location", -f $expected_file);

# Test 2: create_directory with quoted path
print "\n--- Test: create_directory with quoted path ---\n";
$result = $fo->execute(
    { operation => 'create_directory', path => $DQ . "mydir" . $DQ },
    $ctx
);
$passed++ if test_case("create_directory returned success", $result->{success}, $result->{error});
$failed++ unless $result->{success};
$passed++ if assert_no_quote_dir("create_directory: no '$DQ' directory created");
$passed++ if test_case("create_directory: mydir created",
    -d File::Spec->catdir($test_dir, "mydir"));

# Test 3: write_file with quoted path (must create the parent file first)
print "\n--- Test: write_file with quoted absolute path ---\n";
my $write_target = File::Spec->catfile($test_dir, "test-write.txt");
$result = $fo->execute(
    { operation => 'write_file', path => $write_target, content => "initial\n" },
    $ctx
);
$result = $fo->execute(
    { operation => 'write_file', path => $DQ . $write_target . $DQ, content => "wrote\n" },
    $ctx
);
$passed++ if test_case("write_file returned success", $result->{success}, $result->{error});
$failed++ unless $result->{success};
$passed++ if assert_no_quote_dir("write_file: no '$DQ' directory created");

# Test 4: append_file with quoted path
print "\n--- Test: append_file with quoted path ---\n";
$result = $fo->execute(
    { operation => 'write_file', path => $DQ . $write_target . $DQ, content => "appended\n", append => 1 },
    $ctx
);
$passed++ if test_case("append_file returned success", $result->{success}, $result->{error});
$failed++ unless $result->{success};
$passed++ if assert_no_quote_dir("append_file: no '$DQ' directory created");

# Test 5: read_file with quoted path
print "\n--- Test: read_file with quoted path ---\n";
$result = $fo->execute(
    { operation => 'read_file', path => $DQ . $write_target . $DQ },
    $ctx
);
$passed++ if test_case("read_file returned success", $result->{success}, $result->{error});
$failed++ unless $result->{success};

# Test 6: file_exists with quoted path
print "\n--- Test: file_exists with quoted path ---\n";
$result = $fo->execute(
    { operation => 'file_exists', path => $DQ . $write_target . $DQ },
    $ctx
);
my $exists_ok = $result->{success} && ($result->{output} // 0) == 1;
$passed++ if test_case("file_exists returned true", $exists_ok);
$failed++ unless $exists_ok;

# Test 7: insert_at_line with quoted path
print "\n--- Test: insert_at_line with quoted path ---\n";
$result = $fo->execute(
    { operation => 'insert_at_line', path => $DQ . $write_target . $DQ, line => 2, content => "inserted\n" },
    $ctx
);
$passed++ if test_case("insert_at_line returned success", $result->{success}, $result->{error});
$failed++ unless $result->{success};

# Test 8: replace_string with quoted path
print "\n--- Test: replace_string with quoted path ---\n";
$result = $fo->execute(
    { operation => 'replace_string', path => $DQ . $write_target . $DQ, old_string => "wrote\n", new_string => "replaced\n" },
    $ctx
);
$passed++ if test_case("replace_string returned success", $result->{success}, $result->{error});
$failed++ unless $result->{success};

# Test 9: rename_file with quoted paths
print "\n--- Test: rename_file with quoted paths ---\n";
my $renamed_target = File::Spec->catfile($test_dir, "renamed.txt");
$result = $fo->execute(
    { operation => 'rename_file',
      old_path => $DQ . $write_target . $DQ,
      new_path => $DQ . $renamed_target . $DQ },
    $ctx
);
$passed++ if test_case("rename_file returned success", $result->{success}, $result->{error});
$failed++ unless $result->{success};
$passed++ if assert_no_quote_dir("rename_file: no '$DQ' directory created");
$passed++ if test_case("rename_file: renamed file exists", -f $renamed_target);

# Test 10: multi_replace_string with quoted paths
print "\n--- Test: multi_replace_string with quoted paths ---\n";
my $multi1 = File::Spec->catfile($test_dir, "multi1.txt");
my $multi2 = File::Spec->catfile($test_dir, "multi2.txt");
$fo->execute({ operation => 'write_file', path => $multi1, content => "alpha\n" }, $ctx);
$fo->execute({ operation => 'write_file', path => $multi2, content => "beta\n" }, $ctx);
$result = $fo->execute(
    { operation => 'multi_replace_string', replacements => [
        { path => $DQ . $multi1 . $DQ, old_string => "alpha", new_string => "ALPHA" },
        { path => $DQ . $multi2 . $DQ, old_string => "beta", new_string => "BETA" },
    ] },
    $ctx
);
$passed++ if test_case("multi_replace_string returned success", $result->{success}, $result->{error});
$failed++ unless $result->{success};
$passed++ if assert_no_quote_dir("multi_replace_string: no '$DQ' directory created");

# Test 11: list_dir with quoted path
print "\n--- Test: list_dir with quoted path ---\n";
$result = $fo->execute(
    { operation => 'list_dir', path => $DQ . $test_dir . $DQ },
    $ctx
);
$passed++ if test_case("list_dir returned success", $result->{success}, $result->{error});
$failed++ unless $result->{success};

# Test 12: get_file_info with quoted path
print "\n--- Test: get_file_info with quoted path ---\n";
$result = $fo->execute(
    { operation => 'get_file_info', path => $DQ . $multi1 . $DQ },
    $ctx
);
$passed++ if test_case("get_file_info returned success", $result->{success}, $result->{error});
$failed++ unless $result->{success};

# ---------------------------------------------------------------------------
# ApplyPatch integration: verify apply_patch doesn't create a `"` directory
# when patch text contains `*** Add File: "..."` etc.
# ---------------------------------------------------------------------------
print "\n=== apply_patch integration tests ===\n";

require CLIO::Tools::ApplyPatch;
my $ap = CLIO::Tools::ApplyPatch->new(base_dir => $test_dir);

# Build a patch with quoted Add File path
my $patch_text = qq{*** Begin Patch
*** Add File: } . $DQ . "patch-quoted.txt" . $DQ . qq{
+patched content
*** End Patch
};

$result = $ap->execute({ operation => 'apply', patch => $patch_text }, $ctx);
$passed++ if test_case("apply_patch with quoted Add File path", $result->{success}, $result->{error});
$failed++ unless $result->{success};
$passed++ if assert_no_quote_dir("apply_patch add: no '$DQ' directory created");

my $patched_file = File::Spec->catfile($test_dir, "patch-quoted.txt");
$passed++ if test_case("apply_patch: patch-quoted.txt exists", -f $patched_file);

# apply_patch with quoted Delete File path
print "\n--- Test: apply_patch with quoted Delete File path ---\n";
my $delete_patch = qq{*** Begin Patch
*** Delete File: } . $DQ . "patch-quoted.txt" . $DQ . qq{
*** End Patch
};

$result = $ap->execute({ operation => 'apply', patch => $delete_patch }, $ctx);
$passed++ if test_case("apply_patch with quoted Delete File path", $result->{success}, $result->{error});
$failed++ unless $result->{success};
$passed++ if test_case("apply_patch: file deleted", !-f $patched_file);

# apply_patch with quoted Update File path
print "\n--- Test: apply_patch with quoted Update File path ---\n";
my $update_target = File::Spec->catfile($test_dir, "update-test.txt");
$fo->execute({ operation => 'write_file', path => $update_target, content => "line1\nline2\n" }, $ctx);

my $update_patch = qq{*** Begin Patch
*** Update File: } . $DQ . $update_target . $DQ . qq{
@@ line1
 line1
+inserted
*** End Patch
};

$result = $ap->execute({ operation => 'apply', patch => $update_patch }, $ctx);
$passed++ if test_case("apply_patch with quoted Update File path", $result->{success}, $result->{error});
$failed++ unless $result->{success};
$passed++ if assert_no_quote_dir("apply_patch update: no '$DQ' directory created");

# apply_patch with quoted Move to path
print "\n--- Test: apply_patch with quoted Move to path ---\n";
my $moved_target = File::Spec->catfile($test_dir, "moved-update.txt");
my $move_patch = qq{*** Begin Patch
*** Update File: } . $DQ . $update_target . $DQ . qq{
*** Move to: } . $DQ . $moved_target . $DQ . qq{
*** End Patch
};

$result = $ap->execute({ operation => 'apply', patch => $move_patch }, $ctx);
$passed++ if test_case("apply_patch with quoted Move to path", $result->{success}, $result->{error});
$failed++ unless $result->{success};
$passed++ if assert_no_quote_dir("apply_patch move: no '$DQ' directory created");
$passed++ if test_case("apply_patch move: moved file exists", -f $moved_target);

# ---------------------------------------------------------------------------
# MemoryOperations integration: verify memory_dir with quoted value
# ---------------------------------------------------------------------------
print "\n=== memory_operations integration tests ===\n";

require CLIO::Tools::MemoryOperations;

my $mem = CLIO::Tools::MemoryOperations->new();

my $mem_dir = File::Spec->catdir($test_dir, ".clio-test-mem");
$result = $mem->execute(
    { operation => 'store', key => 'test-key', content => 'test-content', memory_dir => $DQ . $mem_dir . $DQ },
    $ctx
);
$passed++ if test_case("memory store with quoted memory_dir", $result->{success}, $result->{error});
$failed++ unless $result->{success};
$passed++ if assert_no_quote_dir("memory store: no '$DQ' directory created");

my $mem_file = File::Spec->catfile($mem_dir, "test-key.json");
$passed++ if test_case("memory store: file at expected location", -f $mem_file);

# Cleanup test memory directory
remove_tree($mem_dir) if -d $mem_dir;

print "\n=== Results: $passed passed, $failed failed ===\n";
exit($failed > 0 ? 1 : 0);
