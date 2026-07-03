#!/usr/bin/env perl

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

=head1 NAME

test_apply_patch_validation.pl - Regression tests for apply_patch tool error messages

=head1 DESCRIPTION

Verifies that apply_patch returns clean error_result() messages instead of
raw eval/croak errors that leak the internal file path and line number.

Reproduces the bug seen in production: AI calls apply_patch to write to a
read-only file (e.g. /usr/bin/brightness-bridge) and sees an error like:
    Error: Patch partially applied. Errors: /usr/bin/brightness-bridge:
    Write failed: Cannot write temp: Permission denied at
    /home/deck/.local/clio/lib/CLIO/Core/ToolExecutor.pm line 358.

After the fix, the error should:
  1. NOT contain "at /" followed by a file path (no caller-location leak)
  2. NOT contain the wrapping prefix "Apply_patch: " (caller wraps; the tool
     returns the clean message)
  3. Match the ToolErrorGuidance categories so the AI gets useful guidance
     instead of a generic "Internal tool error"
  4. Set tool_name on every error (so guidance can route correctly)

Categories exercised:
  - missing_required : "Missing required parameter: patch"
  - invalid_value    : "Invalid patch: no file operations found..."
  - file_not_found   : "File not found: <path>"
  - permission_denied: "Write failed for <path>: Permission denied"
  - edit_content_mismatch: "Cannot find match position for chunk..."

=cut

use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use File::Path qw(make_path);
use JSON::PP qw(decode_json);

BEGIN { use_ok('CLIO::Tools::ApplyPatch') or BAIL_OUT("Cannot load ApplyPatch"); }
use_ok('CLIO::Core::ToolErrorGuidance');

print "\n=== apply_patch Validation Tests ===\n\n";

# ── Helpers ──────────────────────────────────────────────────────────

# Assert the result is a clean error with no caller-location leak and proper
# tool_name, then check for the expected substring/pattern.
sub assert_clean_error {
    my (%args) = @_;
    my $result = $args{result};
    my $description = $args{description};
    my $expected_substring = $args{expected_substring};
    my $expected_pattern = $args{expected_pattern};

    ok($result, "$description: result is defined");
    ok($result->{error}, "$description: result has error key");
    ok(!$result->{success}, "$description: success is false");
    is($result->{tool_name}, 'apply_patch',
        "$description: tool_name is set to 'apply_patch'");

    my $err = $result->{error};
    # Match any path with a line number - .pm, .pl, bare, relative.
    unlike($err, qr{ at \S+ line \d+},
        "$description: error does not leak caller file/line ($err)");

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

# Assert ToolErrorGuidance categorizes the error correctly.
sub assert_guidance_category {
    my (%args) = @_;
    my $error = $args{error};
    my $tool_name = $args{tool_name} || 'apply_patch';
    my $expected_category_marker = $args{expected_marker};

    my $guidance = CLIO::Core::ToolErrorGuidance->new();
    my $enhanced = $guidance->enhance_tool_error(
        error => $error,
        tool_name => $tool_name,
        tool_definition => {},
        attempted_params => {},
    );

    if ($expected_category_marker eq 'missing_required') {
        like($enhanced, qr/required field\(s\)/i,
            "  -> guidance categorized as missing_required ($error)");
    } elsif ($expected_category_marker eq 'invalid_value') {
        like($enhanced, qr/wrong type|wrong range|schema/i,
            "  -> guidance categorized as invalid_value ($error)");
    } elsif ($expected_category_marker eq 'file_not_found') {
        like($enhanced, qr/path|file.*exist/i,
            "  -> guidance categorized as file_not_found ($error)");
    } elsif ($expected_category_marker eq 'permission_denied') {
        like($enhanced, qr/permission|denied|access|owner|chmod|sudo/i,
            "  -> guidance categorized as permission_denied ($error)");
    } elsif ($expected_category_marker eq 'edit_content_mismatch') {
        like($enhanced, qr/read.*file|file.*content|context/i,
            "  -> guidance categorized as edit_content_mismatch ($error)");
    } else {
        fail("unknown expected category: $expected_category_marker");
    }
}

# ── Setup ────────────────────────────────────────────────────────────

my $tmpdir = tempdir(CLEANUP => 1);

my $tool = CLIO::Tools::ApplyPatch->new(
    debug => 0,
    base_dir => $tmpdir,
);
ok($tool, 'ApplyPatch object created');

# Create a regular file we can update / delete successfully
my $existing_file = File::Spec->catfile($tmpdir, 'existing.txt');
open my $fh, '>:encoding(UTF-8)', $existing_file or die;
print $fh "line 1\nline 2\nline 3\n";
close $fh;

# ── Tests ────────────────────────────────────────────────────────────

# 1. Missing patch parameter
print "--- missing patch ---\n";
my $r = $tool->execute({ operation => 'apply' }, {});
my $err = assert_clean_error(
    result => $r,
    description => 'apply_patch: missing patch parameter',
    expected_substring => 'Missing required parameter: patch',
);
assert_guidance_category(error => $err, expected_marker => 'missing_required');

# Also test the explicit empty string
$r = $tool->execute({ operation => 'apply', patch => '' }, {});
$err = assert_clean_error(
    result => $r,
    description => 'apply_patch: empty patch string',
    expected_substring => 'Missing required parameter: patch',
);
assert_guidance_category(error => $err, expected_marker => 'missing_required');

# 2. Empty patch (just Begin/End markers)
print "--- empty patch (no operations) ---\n";
$r = $tool->execute({
    operation => 'apply',
    patch => "*** Begin Patch\n*** End Patch\n",
}, {});
$err = assert_clean_error(
    result => $r,
    description => 'apply_patch: empty patch with markers',
    expected_substring => 'Invalid patch: no file operations found',
);
assert_guidance_category(error => $err, expected_marker => 'invalid_value');

# 3. File not found on update
print "--- update: file not found ---\n";
$r = $tool->execute({
    operation => 'apply',
    patch => "*** Begin Patch\n*** Update File: does_not_exist.txt\n@@ line 1\n-old\n+new\n*** End Patch\n",
}, {});
$err = assert_clean_error(
    result => $r,
    description => 'apply_patch: update non-existent file',
    expected_substring => 'File not found: does_not_exist.txt',
);
assert_guidance_category(error => $err, expected_marker => 'file_not_found');

# 4. File not found on delete
print "--- delete: file not found ---\n";
$r = $tool->execute({
    operation => 'apply',
    patch => "*** Begin Patch\n*** Delete File: does_not_exist.txt\n*** End Patch\n",
}, {});
$err = assert_clean_error(
    result => $r,
    description => 'apply_patch: delete non-existent file',
    expected_substring => 'File not found: does_not_exist.txt',
);
assert_guidance_category(error => $err, expected_marker => 'file_not_found');

# 5. Cannot find match position for chunk (content mismatch)
print "--- update: chunk match failure ---\n";
$r = $tool->execute({
    operation => 'apply',
    patch => "*** Begin Patch\n*** Update File: existing.txt\n@@ line 2\n-totally different line\n+new content\n*** End Patch\n",
}, {});
$err = assert_clean_error(
    result => $r,
    description => 'apply_patch: chunk does not match file',
    expected_substring => 'Cannot find match position for chunk',
);
assert_guidance_category(error => $err, expected_marker => 'edit_content_mismatch');

# 6. Permission denied (write to a read-only directory)
#    We need a directory where we can list but not write. This works on
#    Unix-like systems by removing write permission from the directory.
print "--- write: permission denied ---\n";
my $ro_dir = File::Spec->catfile($tmpdir, 'readonly');
make_path($ro_dir);
my $ro_target = 'readonly/blocked.txt';

# Make the directory read-only (remove write bit). Note: root ignores this
# so we skip the assertion when running as root.
my $is_root = $> == 0;
chmod 0555, $ro_dir;

SKIP: {
    skip "running as root (chmod 0555 is bypassed)", 4 if $is_root;

    $r = $tool->execute({
        operation => 'apply',
        patch => "*** Begin Patch\n*** Add File: $ro_target\n+new content\n*** End Patch\n",
    }, {});
    $err = assert_clean_error(
        result => $r,
        description => 'apply_patch: write to read-only directory',
        expected_substring => 'Write failed for',
    );
    # The OS error "Permission denied" must be in the message
    like($err, qr/permission denied/i,
        "  -> error mentions 'Permission denied' (got: $err)");
    assert_guidance_category(error => $err, expected_marker => 'permission_denied');
}

# Restore perms so File::Temp cleanup can remove it
chmod 0755, $ro_dir;

# 7. Partial apply error: one hunk succeeds, one fails
#    Regression: the bug was that the partial-apply error was a giant
#    "Patch partially applied. Errors: <hunk1>; <hunk2>..." string with
#    caller-location leaks. After the fix, the error is a short header
#    and the per-hunk details live in the 'output' field.
print "--- partial apply ---\n";
$r = $tool->execute({
    operation => 'apply',
    patch => "*** Begin Patch\n*** Update File: existing.txt\n@@ line 1\n-line 1\n+LINE 1\n*** Update File: missing.txt\n@@ line 1\n-old\n+new\n*** End Patch\n",
}, {});

ok($r, 'partial apply: result is defined');
ok(!$r->{success}, 'partial apply: success is false');
is($r->{tool_name}, 'apply_patch', 'partial apply: tool_name is set');
like($r->{error}, qr/Patch partially applied/,
    'partial apply: error mentions partial apply');
unlike($r->{error}, qr{ at \S+?\.pm line \d+},
    'partial apply: error does NOT leak caller file/line');
like($r->{error}, qr/1 of 2 hunks failed/,
    'partial apply: error shows failed count');

# The per-hunk details are in output
ok($r->{output}, 'partial apply: output is set');
my $output_data = eval { decode_json($r->{output}) };
ok($output_data && ref($output_data) eq 'HASH',
    'partial apply: output is valid JSON');
ok($output_data->{results} && @{$output_data->{results}} == 2,
    'partial apply: output has 2 results');

# Find the failed hunk and verify it has a clean error
my $failed = [grep { !$_->{success} } @{$output_data->{results}}]->[0];
ok($failed, 'partial apply: at least one result failed');
is($failed->{type}, 'update', 'partial apply: failed hunk is type=update');
like($failed->{error}, qr/File not found: missing\.txt/,
    'partial apply: failed hunk error is clean');
unlike($failed->{error}, qr{ at \S+?\.pm line \d+},
    'partial apply: failed hunk error has no caller-location leak');

# 8. tool_name consistency: every error path sets tool_name='apply_patch'
#    (covered above; just assert for the success path too)
print "--- success path ---\n";
$r = $tool->execute({
    operation => 'apply',
    patch => "*** Begin Patch\n*** Update File: existing.txt\n@@ line 2\n-line 2\n+line 2 (modified)\n*** End Patch\n",
}, {});
ok($r->{success}, 'success path: success is true');
is($r->{tool_name}, 'apply_patch', 'success path: tool_name is set');
like($r->{action_description}, qr/apply_patch:.*modified/,
    'success path: action_description is set');

done_testing();

print "\n=== apply_patch validation tests COMPLETE ===\n";
