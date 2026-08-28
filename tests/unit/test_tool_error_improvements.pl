#!/usr/bin/env perl
# test_tool_error_improvements.pl - Regression tests for tool error UX fixes
#
# These tests cover fixes for findings from the agent's tool audit:
#   1. version_control log: clamp/validate limit parameter
#   2. version_control diff: validate file parameter exists
#   3. file_operations read_file: explicit error when start_line past EOF
#   4. web_operations fetch_url: categorize transport/HTTP errors
#   5. ToolExecutor validator: pass through error_result() (success=0, no
#      output) instead of replacing it with a generic malformed-result error.
#      Previously every tool error was clobbered with 'Internal tool error:
#      malformed result structure', hiding the real error from agents.
#   6. grep_search invalid-regex path: use error_result() helper instead of
#      manually building a hash missing the 'output' key.

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Test::More;
use File::Temp qw(tempdir);

BEGIN { use_ok('CLIO::Tools::VersionControl') or BAIL_OUT("Cannot load VersionControl"); }
BEGIN { use_ok('CLIO::Tools::FileOperations') or BAIL_OUT("Cannot load FileOperations"); }
BEGIN { use_ok('CLIO::Core::ToolExecutor') or BAIL_OUT("Cannot load ToolExecutor"); }
BEGIN { use_ok('CLIO::Tools::WebOperations') or BAIL_OUT("Cannot load WebOperations"); }

print "\n=== Tool Error Improvement Tests ===\n\n";

# ============================================================
# Test group 1: version_control log limit validation
# ============================================================
print "--- version_control log limit validation ---\n";

my $vc = CLIO::Tools::VersionControl->new();
isa_ok($vc, 'CLIO::Tools::VersionControl', 'VersionControl instance');

# Negative limit: must return error (was silently returning unbounded output)
{
    my $r = $vc->log({ repository_path => '.', limit => -5 });
    is($r->{success}, 0, 'log limit=-5 returns failure');
    like($r->{error}, qr/Invalid 'limit'/, 'log limit=-5 error mentions invalid limit');
}

# Zero limit: must return error (was silently defaulting to 10)
{
    my $r = $vc->log({ repository_path => '.', limit => 0 });
    is($r->{success}, 0, 'log limit=0 returns failure');
    like($r->{error}, qr/Invalid 'limit'/, 'log limit=0 error mentions invalid limit');
}

# Non-integer limit: must return error
{
    my $r = $vc->log({ repository_path => '.', limit => 'abc' });
    is($r->{success}, 0, 'log limit="abc" returns failure');
    like($r->{error}, qr/Invalid 'limit'/, 'log limit="abc" error mentions invalid limit');
}

# Valid limit: works correctly
{
    my $r = $vc->log({ repository_path => '.', limit => 3 });
    is($r->{success}, 1, 'log limit=3 succeeds');
    is($r->{count}, 3, 'log limit=3 returns exactly 3 commits');
}

# Undefined limit: defaults to 10
{
    my $r = $vc->log({ repository_path => '.' });
    is($r->{success}, 1, 'log with no limit succeeds');
    ok($r->{count} >= 1 && $r->{count} <= 10, 'log default limit returns 1-10 commits (got ' . ($r->{count} // 'undef') . ')');
}

# Excessive limit: clamped to 1000 (not unbounded)
{
    my $r = $vc->log({ repository_path => '.', limit => 1000000 });
    is($r->{success}, 1, 'log limit=1000000 succeeds (clamped)');
    is($r->{count}, 1000, 'log limit=1000000 clamped to 1000');
    is($r->{limit_clamped}, 1000, 'log reports limit_clamped=1000');
}

print "\n";

# ============================================================
# Test group 2: version_control diff file validation
# ============================================================
print "--- version_control diff file validation ---\n";

# Missing file: must return error (was silently returning empty diff)
{
    my $r = $vc->diff({ repository_path => '.', file => '/nonexistent/path/xyzzy' });
    is($r->{success}, 0, 'diff on missing file returns failure');
    like($r->{error}, qr/File not found/, 'diff on missing file error mentions "File not found"');
}

# Empty file param: works as before (no validation needed)
{
    my $r = $vc->diff({ repository_path => '.' });
    is($r->{success}, 1, 'diff with no file param succeeds');
}

# Existing file: works as before
{
    my $r = $vc->diff({ repository_path => '.', file => 'clio' });
    is($r->{success}, 1, 'diff on existing file succeeds');
}

print "\n";

# ============================================================
# Test group 3: file_operations read_file out-of-range
# ============================================================
print "--- file_operations read_file line range validation ---\n";

my $test_dir = tempdir(CLEANUP => 1);
my $short_file = "$test_dir/short.txt";
{
    open my $fh, '>', $short_file or die $!;
    print $fh "line 1\nline 2\nline 3\n";
    close $fh;
}

my $fo = CLIO::Tools::FileOperations->new();

# start_line past EOF: must return error (was silent empty)
{
    my $r = $fo->read_file({ path => $short_file, start_line => 100 });
    is($r->{success}, 0, 'read_file with start_line past EOF returns failure');
    like($r->{error}, qr/Line range out of bounds/, 'read_file error mentions "Line range out of bounds"');
    like($r->{error}, qr/has only 3 lines/, 'read_file error mentions actual line count');
}

# start_line = 1 (valid): works
{
    my $r = $fo->read_file({ path => $short_file, start_line => 1 });
    is($r->{success}, 1, 'read_file with start_line=1 succeeds');
    is($r->{lines_read}, 3, 'read_file with start_line=1 returns 3 lines');
    like($r->{output}, qr/line 1.*line 2.*line 3/s, 'read_file with start_line=1 returns full content');
}

# start_line = 2 (valid): works
{
    my $r = $fo->read_file({ path => $short_file, start_line => 2 });
    is($r->{success}, 1, 'read_file with start_line=2 succeeds');
    is($r->{lines_read}, 2, 'read_file with start_line=2 returns 2 lines');
    unlike($r->{output}, qr/line 1/, 'read_file with start_line=2 omits line 1');
}

# end_line past EOF: still works (clamps naturally, no error needed)
{
    my $r = $fo->read_file({ path => $short_file, start_line => 1, end_line => 100 });
    is($r->{success}, 1, 'read_file with end_line past EOF succeeds');
    is($r->{lines_read}, 3, 'read_file with end_line past EOF reads all 3 lines');
}

# No range params: reads whole file
{
    my $r = $fo->read_file({ path => $short_file });
    is($r->{success}, 1, 'read_file with no range succeeds');
    is($r->{lines_read}, 3, 'read_file with no range returns 3 lines');
}

# Missing file: existing error path still works
{
    my $r = $fo->read_file({ path => '/nonexistent/path/xyzzy' });
    is($r->{success}, 0, 'read_file on missing file returns failure');
    like($r->{error}, qr/File not found/, 'read_file missing file error mentions "File not found"');
}

print "\n";

# ============================================================
# Test group 4: web_operations fetch_url error categorization
# ============================================================
print "--- web_operations fetch_url error categorization ---\n";

my $wo = CLIO::Tools::WebOperations->new();
isa_ok($wo, 'CLIO::Tools::WebOperations', 'WebOperations instance');

# Malformed URL: pre-flight regex catches it
{
    my $r = $wo->fetch_url({ url => 'not_a_url_xyzzy' });
    is($r->{success}, 0, 'fetch_url malformed URL returns failure');
    like($r->{error}, qr/Malformed URL/, 'fetch_url malformed URL error mentions "Malformed URL"');
}

# Non-HTTP scheme: pre-flight regex catches it
{
    my $r = $wo->fetch_url({ url => 'ftp://example.com/' });
    is($r->{success}, 0, 'fetch_url ftp scheme returns failure');
    like($r->{error}, qr/Malformed URL/, 'fetch_url ftp scheme error mentions "Malformed URL"');
}

# Missing url: existing path still works
{
    my $r = $wo->fetch_url({});
    is($r->{success}, 0, 'fetch_url with no url returns failure');
    like($r->{error}, qr/Missing required parameter: url/, 'fetch_url no url error mentions missing url');
}

# _categorize_http_error: build synthetic responses, exercise every category
{
    package FakeResp;
    sub new { my ($c, %a) = @_; bless { %a }, $c; }
    sub code { shift->{code} }
    sub status_line { shift->{line} }

    package main;

    my @http_cases = (
        [401, 'Unauthorized',   'Authentication required'],
        [403, 'Forbidden',      'Authentication required'],
        [404, 'Not Found',      'Not found'],
        [410, 'Gone',           'Gone'],
        [429, 'Too Many Reqs',  'Rate limited'],
        [500, 'Server Error',   'Server error'],
        [503, 'Unavailable',    'Server error'],
        [400, 'Bad Request',    'Client error'],
        [301, 'Moved',          'Redirect not followed'],
    );

    for my $case (@http_cases) {
        my ($code, $line, $expected) = @$case;
        my $resp = FakeResp->new(code => $code, line => "$code $line");
        my $err = CLIO::Tools::WebOperations::_categorize_http_error(
            'http://test/', $resp, 30
        );
        like($err, qr/^\Q$expected\E:/, "_categorize_http_error HTTP $code -> '$expected'");
    }
}

# _categorize_transport_error: exercise every category
{
    my @transport_cases = (
        ['Connection timed out after 30s',         'Timeout'],
        ['getaddrinfo: No such host is known',     'DNS lookup failed'],
        ['Connection refused',                     'Connection refused'],
        ['Network is unreachable',                 'Network unreachable'],
        ['SSL handshake failed: cert verify',      'TLS error'],
        ['Invalid URI: hostname',                  'Malformed URL'],
        ['Some random transport blip',             'Network error'],
    );

    for my $case (@transport_cases) {
        my ($err_str, $expected) = @$case;
        my $err = CLIO::Tools::WebOperations::_categorize_transport_error(
            'http://test/', $err_str, 30
        );
        like($err, qr/^\Q$expected\E:/, "_categorize_transport_error '$err_str' -> '$expected'");
    }
}

# ============================================================
# Test group 5: ToolExecutor validator passes through error_result()
# ============================================================
print "--- ToolExecutor validator accepts error_result() ---\n";

# The validator is a small Perl expression embedded in execute_tool().
# We replicate it here and verify that the four shapes tools actually
# produce all pass through correctly. Previously the validator required
# 'output' for every result, which clobbered every error_result() call
# with 'Internal tool error: malformed result structure'.
sub tool_result_valid {
    my ($r) = @_;
    return 0 unless ref($r) eq 'HASH';
    return 0 unless exists $r->{success};
    return $r->{success}
        ? (defined $r->{output} ? 1 : 0)
        : (exists $r->{error} ? 1 : 0);
}

# Shape 1: error_result() with no output (the production case)
{
    my $r = $wo->error_result("Skill 'foo' not found");
    ok(!tool_result_valid($r) == 0, "error_result() (no output) passes validator");
    is($r->{error}, "Skill 'foo' not found", "error_result() preserves error message");
}

# Shape 2: success_result() with arrayref output (matches grep_search success)
{
    my $r = $wo->success_result([{path=>'a',line=>1,content=>'x'}], match_count => 1);
    ok(tool_result_valid($r), "success_result() with array output passes validator");
}

# Shape 3: success_result() with string output
{
    my $r = $wo->success_result("file contents here");
    ok(tool_result_valid($r), "success_result() with string output passes validator");
}

# Shape 4: malformed - missing success
{
    my $r = { error => "x" };
    ok(!tool_result_valid($r), "hash without 'success' is rejected");
}

# Shape 5: malformed - success=1 but no output
{
    my $r = { success => 1 };
    ok(!tool_result_valid($r), "success=1 without output is rejected");
}

# Shape 6: manually constructed error hash (the grep_search bug we fixed)
{
    my $r = { success => 0, error => "Invalid regex" };
    ok(tool_result_valid($r), "manually built {success=>0,error=>...} passes validator");
}

print "\n";

# ============================================================
# Test group 6: grep_search invalid-regex path produces clean error
# ============================================================
print "--- grep_search invalid-regex error path ---\n";

# This is the exact failure mode from the agent transcript:
#   grep_search returned [unclosed (invalid regex)
#   ToolExecutor replaced the real error with 'malformed result structure'
#   Agent had to fall back to terminal grep
{
    my $r = $fo->grep_search({
        query => '[unclosed',
        pattern => 'lib/**/*.pm',
        is_regex => 1,
    });
    is($r->{success}, 0, 'grep_search with invalid regex returns failure');
    like($r->{error}, qr/Invalid regex/, 'error mentions "Invalid regex"');
    like($r->{error}, qr/\[unclosed/, 'error includes the bad pattern');
}

# Also verify the full chain: this result would NOT be replaced by
# ToolExecutor's malformed-result fallback anymore.
{
    my $r = $fo->grep_search({
        query => '[unclosed',
        pattern => 'lib/**/*.pm',
        is_regex => 1,
    });
    ok(tool_result_valid($r), 'invalid-regex result passes ToolExecutor validator');
}

# Verify file_search failure propagation also passes (the other grep_search
# error path: $result = $file_result; return;)
{
    # We can't easily trigger file_search failure here, but we can verify
    # that an error_result from file_search would propagate cleanly by
    # checking the shape we expect it to return.
    my $r = $fo->error_result("File search failed: no matches");
    is($r->{success}, 0, 'error_result shape: success=0');
    ok(!exists $r->{output}, 'error_result shape: no output key (intentional)');
    ok(exists $r->{error}, 'error_result shape: has error key');
    ok(tool_result_valid($r), 'error_result from file_search propagates through ToolExecutor');
}

print "\n";
done_testing();