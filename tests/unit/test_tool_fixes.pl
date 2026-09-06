#!/usr/bin/env perl
# Test fixes for tool infrastructure issues from the previous session:
# 1. ToolExecutor operation-alias fallback (e.g. "read" as tool name)
# 2. ApplyPatch _find_chunk_position_fuzzy retry-from-start
# 3. ApplyPatch error message formatting (period + space)
# 4. ReplaceString improved error diagnostics
# 5. ApplyPatch unrecognized lines treated as context

use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Spec;
use File::Path qw(make_path);
use JSON::PP qw(decode_json encode_json);
use lib './lib';

use CLIO::Tools::Registry;
use CLIO::Core::ToolExecutor;
use CLIO::Tools::FileOperations;
use CLIO::Tools::ApplyPatch;

my $tests_passed = 0;
my $tests_failed = 0;
my @failures;

sub ok {
    my ($condition, $name) = @_;
    if ($condition) {
        print "  PASS: $name\n";
        $tests_passed++;
    } else {
        print "  FAIL: $name\n";
        push @failures, $name;
        $tests_failed++;
    }
}

sub assert_like {
    my ($value, $pattern, $name) = @_;
    ok($value && $value =~ /$pattern/, $name);
}

my $tmpdir = tempdir(CLEANUP => 1);

# ── Set up tools ──────────────────────────────────────────────
my $registry = CLIO::Tools::Registry->new(debug => 0);
$registry->register_tool(CLIO::Tools::FileOperations->new(debug => 0));
$registry->register_tool(CLIO::Tools::ApplyPatch->new(debug => 0));

my $session = {
    session_id => 'test_session_'.time(),
    messages   => [],
    tool_calls => {},
};

my $executor = CLIO::Core::ToolExecutor->new(
    session       => $session,
    tool_registry => $registry,
    debug         => 0,
);

# ═══════════════════════════════════════════════════════════════
# Test 1: ToolExecutor resolves operation alias "read" as tool name
# This simulates an execution layer that extracts the operation name
# and uses it as the tool name (e.g. "read" instead of "file_operations")
# ═══════════════════════════════════════════════════════════════
print "\n=== Test 1: Operation alias 'read' as tool name ===\n";

my $test_file_1 = File::Spec->catfile($tmpdir, 'alias_test.txt');
open my $fh, '>', $test_file_1 or die $!;
print $fh "hello alias\n";
close $fh;

# Simulate: tool_name="read" (the operation alias), no operation param
my $tool_call = {
    function => {
        name       => 'read',
        arguments  => encode_json({ path => $test_file_1 })
    }
};

my $result_json = $executor->execute_tool($tool_call, 'test_alias_1');
my $result = eval { decode_json($result_json) };

ok($result && $result->{success}, "Tool name 'read' resolves to file_operations");
ok($result->{output} && $result->{output} =~ /hello alias/, "Correct file content returned");

# ═══════════════════════════════════════════════════════════════
# Test 2: ToolExecutor resolves operation alias "write" as tool name
# ═══════════════════════════════════════════════════════════════
print "\n=== Test 2: Operation alias 'write' as tool name ===\n";

my $test_file_2 = File::Spec->catfile($tmpdir, 'alias_write.txt');
$tool_call = {
    function => {
        name       => 'write',
        arguments  => encode_json({ path => $test_file_2, content => 'alias write test' })
    }
};

$result_json = $executor->execute_tool($tool_call, 'test_alias_2');
$result = eval { decode_json($result_json) };

ok($result && $result->{success}, "Tool name 'write' resolves to file_operations");
ok(-f $test_file_2, "File was created via alias");
if (-f $test_file_2) {
    open $fh, '<', $test_file_2;
    my $content = do { local $/; <$fh> };
    close $fh;
    ok($content eq 'alias write test', "File content correct");
}

# ═══════════════════════════════════════════════════════════════
# Test 3: ToolExecutor still rejects truly unknown tool names
# ═══════════════════════════════════════════════════════════════
print "\n=== Test 3: True unknown tool still fails ===\n";

$tool_call = {
    function => {
        name       => 'truly_nonexistent_tool',
        arguments  => encode_json({})
    }
};

$result_json = $executor->execute_tool($tool_call, 'test_unknown');
$result = eval { decode_json($result_json) };

ok($result && !$result->{success}, "Unknown tool still fails");
ok($result->{error} && $result->{error} =~ /Unknown tool/, "Error mentions unknown tool");

# ═══════════════════════════════════════════════════════════════
# Test 4: ApplyPatch error message has period + space
# ═══════════════════════════════════════════════════════════════
print "\n=== Test 4: ApplyPatch error message formatting ===\n";

my $patch_tool = CLIO::Tools::ApplyPatch->new(debug => 0, base_dir => $tmpdir);

# Create a file to patch
my $patch_file = File::Spec->catfile($tmpdir, 'patch_test.txt');
open $fh, '>', $patch_file or die $!;
print $fh "line A\nline B\nline C\n";
close $fh;

# Patch with old content that doesn't exist
my $bad_patch = '*** Begin Patch
*** Update File: patch_test.txt
@@ line A
-old line that does not exist
-new content
*** End Patch';

$result = $patch_tool->execute({ operation => 'apply', patch => $bad_patch }, {});
my $output = eval { decode_json($result->{output} || '{}') } || {};
my $err = $result->{error} || '';

ok(length($err) > 0, "Patch with no match returns error");
ok($err =~ /Cannot find match position for chunk\./, "Error has period after 'chunk'");
ok($err !~ /Cannot find match position for chunkRead/, "No concatenated 'chunkRead'");
ok($err =~ /Read the file to see its actual content/, "Error includes guidance text");

# ═══════════════════════════════════════════════════════════════
# Test 5: ApplyPatch fuzzy match retry from start
# ═══════════════════════════════════════════════════════════════
print "\n=== Test 5: ApplyPatch fuzzy match retry from start ===\n";

my $fuzzy_file = File::Spec->catfile($tmpdir, 'fuzzy_test.txt');
open $fh, '>', $fuzzy_file or die $!;
print $fh "target line\nother content\nmore lines\n";
close $fh;

# Patch where the context anchor is AFTER the target line,
# and the old line has different leading whitespace
my $fuzzy_patch = '*** Begin Patch
*** Update File: fuzzy_test.txt
@@ other content
-  target line
+REPLACED
*** End Patch';

$result = $patch_tool->execute({ operation => 'apply', patch => $fuzzy_patch }, {});
my $output2 = eval { decode_json($result->{output} || '{}') } || {};

ok($result->{success}, "Fuzzy match with offset context succeeds");
if ($result->{success}) {
    open $fh, '<', $fuzzy_file;
    my $content2 = do { local $/; <$fh> };
    close $fh;
    ok($content2 =~ /REPLACED/, "Target line replaced via fuzzy match");
}

# ═══════════════════════════════════════════════════════════════
# Test 6: ApplyPatch treats unrecognized lines as context
# ═══════════════════════════════════════════════════════════════
print "\n=== Test 6: ApplyPatch unrecognized lines treated as context ===\n";

my $unrec_file = File::Spec->catfile($tmpdir, 'unrec_test.txt');
open $fh, '>', $unrec_file or die $!;
print $fh "context line\nold line\nend\n";
close $fh;

# Patch where context line lacks leading space (unrecognized by parser)
# but old line has proper - prefix
my $unrec_patch = '*** Begin Patch
*** Update File: unrec_test.txt
@@ context line
-old line
+new line
*** End Patch';

$result = $patch_tool->execute({ operation => 'apply', patch => $unrec_patch }, {});
ok($result->{success}, "Patch with recognized lines succeeds");

open $fh, '<', $unrec_file;
my $unrec_content = do { local $/; <$fh> };
close $fh;
ok($unrec_content =~ /new line/, "Context line preserved, old line replaced");
ok($unrec_content !~ /old line/, "Old line correctly removed");

# ═══════════════════════════════════════════════════════════════
# Test 7: replace_string error message is more helpful
# ═══════════════════════════════════════════════════════════════
print "\n=== Test 7: replace_string improved error message ===\n";

my $replace_file = File::Spec->catfile($tmpdir, 'replace_test.txt');
open $fh, '>', $replace_file or die $!;
print $fh "some content here\n";
close $fh;

my $fop = CLIO::Tools::FileOperations->new(debug => 0);

# Try to replace a string that doesn't exist
my $replace_result = $fop->execute({
    operation => 'replace_string',
    path      => $replace_file,
    old_string => 'nonexistent string with $variables and {braces}',
    new_string => 'replacement',
}, { session => { session_id => 'test' } });

ok(!$replace_result->{success}, "replace_string fails for nonexistent content");
ok($replace_result->{error} && $replace_result->{error} =~ /String not found/, "Error mentions 'String not found'");
ok($replace_result->{error} && $replace_result->{error} =~ /literal/, "Error mentions literal matching");
ok($replace_result->{error} && $replace_result->{error} =~ /Whitespace/, "Error mentions whitespace as common cause");

# ═══════════════════════════════════════════════════════════════
# Test 8: replace_string still works with metacharacters when match exists
# ═══════════════════════════════════════════════════════════════
print "\n=== Test 8: replace_string works with Perl metacharacters ===\n";

my $meta_file = File::Spec->catfile($tmpdir, 'meta_test.txt');
open $fh, '>', $meta_file or die $!;
print $fh "    max_ctx => \$limits->{max_context_window}\n";
close $fh;

my $replace_ok = $fop->execute({
    operation => 'replace_string',
    path      => $meta_file,
    old_string => '    max_ctx => $limits->{max_context_window}',
    new_string => '    max_ctx => $limits->{max_input_tokens}',
}, { session => { session_id => 'test' } });

ok($replace_ok->{success}, "replace_string succeeds with metacharacters");
if ($replace_ok->{success}) {
    open $fh, '<', $meta_file;
    my $meta_content = do { local $/; <$fh> };
    close $fh;
    ok($meta_content =~ /max_input_tokens/, "Metacharacter string replaced correctly");
    ok($meta_content !~ /max_context_window/, "Old metacharacter string removed");
}

# ═══════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════
print "\n" . "=" x 60 . "\n";
print "Results: $tests_passed passed, $tests_failed failed\n";
print "=" x 60 . "\n";

if (@failures) {
    print "Failed tests:\n";
    for my $f (@failures) {
        print "  - $f\n";
    }
}

exit($tests_failed > 0 ? 1 : 0);
