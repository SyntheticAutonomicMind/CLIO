#!/usr/bin/env perl

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

=head1 NAME

test_tool_eval_error_cleaning.pl - Regression tests for the cross-tool $@ cleanup pattern

=head1 DESCRIPTION

The bug: several tools wrap their work in `eval { ... }; if ($@) { return $self->error_result("X failed: $@"); }`.
When the work croaks, Carp appends a caller-location suffix like
"at /home/user/.local/clio/lib/CLIO/Core/ToolExecutor.pm line 358."
which (a) leaks internal file paths to the AI and (b) prevents
ToolErrorGuidance from cleanly categorizing the failure.

The fix is in two parts:
  1. CLIO::Tools::Tool provides _clean_eval_error() that strips the
     "at <path> line <num>." suffix from any error string.
  2. Every tool that consumes $@ in an error_result message must wrap
     it in _clean_eval_error() before forwarding.

This test exercises:
  - The _clean_eval_error helper directly (unit test).
  - Interact tool: missing_required path now sets tool_name and uses error_result.
  - VersionControl: pre-eval validation paths AND eval/croak paths both strip the suffix.
  - RemoteExecution: validation paths AND eval/croak paths both strip the suffix.
  - WebOperations: 3 search helpers all call _clean_eval_error on $@ (verified structurally).

Categories exercised through ToolErrorGuidance:
  - missing_required (Interact, VersionControl, RemoteExecution)
  - invalid_value    (VersionControl branch/tag/stash/worktree)

=cut

use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use Cwd qw(getcwd);

BEGIN { use_ok('CLIO::Tools::Tool') or BAIL_OUT("Cannot load Tool base"); }
use_ok('CLIO::Core::ToolErrorGuidance');

print "\n=== Tool \$@ Cleanup Tests ===\n\n";

# Helper: build a temp dir that is a real git repo (needed to bypass
# VersionControl.before_route()'s _is_git_repo check).
sub _make_git_repo {
    my $dir = tempdir(CLEANUP => 1);
    system('git', '-C', $dir, 'init', '-q') == 0
        or die "git init failed: $?";
    system('git', '-C', $dir, 'config', 'user.email', 'test@example.com') == 0
        or die "git config email failed: $?";
    system('git', '-C', $dir, 'config', 'user.name', 'Test User') == 0
        or die "git config name failed: $?";
    return $dir;
}

# ── Unit test: _clean_eval_error itself ──────────────────────────────

print "--- _clean_eval_error helper unit tests ---\n";

{
    package TestTool;
    use parent 'CLIO::Tools::Tool';
    sub new {
        my ($class, %opts) = @_;
        return bless { name => 'test_tool', %opts }, $class;
    }
}

my $tt = TestTool->new();

is($tt->_clean_eval_error(undef), '', 'helper: undef returns empty string');
is($tt->_clean_eval_error(''), '', 'helper: empty string returns empty string');

my $raw_pm = "Permission denied at /home/user/.local/clio/lib/CLIO/Tools/ApplyPatch.pm line 354.";
is($tt->_clean_eval_error($raw_pm), 'Permission denied',
    'helper: strips .pm caller-location');

my $raw_bare = "Cannot write temp: Permission denied at /tmp/foo line 12.";
is($tt->_clean_eval_error($raw_bare), 'Cannot write temp: Permission denied',
    'helper: strips bare path caller-location');

my $raw_rel = "boom at lib/Foo.pm line 5.";
is($tt->_clean_eval_error($raw_rel), 'boom',
    'helper: strips relative path caller-location');

my $raw_pl = "syntax error at script.pl line 99.";
is($tt->_clean_eval_error($raw_pl), 'syntax error',
    'helper: strips .pl path caller-location');

my $raw_no_dot = "oops at /foo/bar.pm line 7";
is($tt->_clean_eval_error($raw_no_dot), 'oops',
    'helper: strips suffix without trailing dot');

is($tt->_clean_eval_error('Permission denied'), 'Permission denied',
    'helper: clean message unchanged');

my $raw_ws = "message at foo.pm line 1.   ";
is($tt->_clean_eval_error($raw_ws), 'message', 'helper: trims trailing whitespace');

is($tt->_clean_eval_error('look at this carefully'), 'look at this carefully',
    'helper: mid-sentence "at" not stripped');

# ── Test 2: Interact tool sets tool_name ─────────────────────────────

print "\n--- Interact tool: missing tool_name fix ---\n";

require_ok('CLIO::Tools::Interact');
my $interact = CLIO::Tools::Interact->new(debug => 0);

my $r = $interact->execute({ operation => 'request_input' }, {});
ok($r, 'interact: missing param: result defined');
ok(!$r->{success}, 'interact: missing param: success is false');
ok($r->{error}, 'interact: missing param: has error');
is($r->{tool_name}, 'interact',
    'interact: missing param: tool_name is set');
like($r->{error}, qr/Missing required parameter: message/,
    'interact: missing param: error mentions missing param');
unlike($r->{error}, qr{ at \S+ line \d+},
    'interact: missing param: no caller-location leak');

# ── Test 3: VersionControl $@ cleanup ────────────────────────────────

print "\n--- VersionControl: \$@ cleanup ---\n";

require_ok('CLIO::Tools::VersionControl');
my $vc = CLIO::Tools::VersionControl->new(debug => 0);

# Pre-eval validation path: non-git directory triggers before_route's
# _is_git_repo check which returns "Not a Git repository" directly.
my $non_git_dir = tempdir(CLEANUP => 1);

$r = $vc->execute({
    operation => 'status',
    repository_path => $non_git_dir,
}, {});
ok($r && !$r->{success}, 'vc.status non_git: failed as expected');
is($r->{tool_name}, 'version_control', 'vc.status non_git: tool_name is set');
unlike($r->{error}, qr{ at \S+ line \d+},
    'vc.status non_git: error does not leak caller-location');
like($r->{error}, qr/Not a Git repository/,
    'vc.status non_git: error mentions non-repo');

$r = $vc->execute({
    operation => 'log',
    repository_path => $non_git_dir,
}, {});
ok($r && !$r->{success}, 'vc.log non_git: failed as expected');
is($r->{tool_name}, 'version_control', 'vc.log non_git: tool_name is set');
unlike($r->{error}, qr{ at \S+ line \d+},
    'vc.log non_git: error does not leak caller-location');

$r = $vc->execute({
    operation => 'diff',
    repository_path => $non_git_dir,
}, {});
ok($r && !$r->{success}, 'vc.diff non_git: failed as expected');
is($r->{tool_name}, 'version_control', 'vc.diff non_git: tool_name is set');
unlike($r->{error}, qr{ at \S+ line \d+},
    'vc.diff non_git: error does not leak caller-location');

$r = $vc->execute({
    operation => 'branch',
    action => 'list',
    repository_path => $non_git_dir,
}, {});
ok($r && !$r->{success}, 'vc.branch non_git: failed as expected');
is($r->{tool_name}, 'version_control', 'vc.branch non_git: tool_name is set');
unlike($r->{error}, qr{ at \S+ line \d+},
    'vc.branch non_git: error does not leak caller-location');

# Direct validation paths (no $@ involved) - need a real git repo so
# before_route passes and the inner validation runs.
my $git_dir = _make_git_repo();

$r = $vc->execute({
    operation => 'commit',
    repository_path => $git_dir,
}, {});
ok($r && !$r->{success}, 'vc.commit no_msg: failed as expected');
is($r->{tool_name}, 'version_control', 'vc.commit no_msg: tool_name is set');
unlike($r->{error}, qr{ at \S+ line \d+},
    'vc.commit no_msg: error does not leak caller-location');
like($r->{error}, qr/Missing 'message' parameter/,
    'vc.commit no_msg: error mentions missing message');

$r = $vc->execute({
    operation => 'blame',
    repository_path => $git_dir,
}, {});
ok($r && !$r->{success}, 'vc.blame no_file: failed as expected');
is($r->{tool_name}, 'version_control', 'vc.blame no_file: tool_name is set');
unlike($r->{error}, qr{ at \S+ line \d+},
    'vc.blame no_file: error does not leak caller-location');
like($r->{error}, qr/Missing 'file' parameter/, 'vc.blame no_file: clean missing-file');

$r = $vc->execute({
    operation => 'branch',
    action => 'bogus',
    repository_path => $git_dir,
}, {});
ok($r && !$r->{success}, 'vc.branch.invalid: failed as expected');
is($r->{tool_name}, 'version_control', 'vc.branch.invalid: tool_name is set');
unlike($r->{error}, qr{ at \S+ line \d+},
    'vc.branch.invalid: error does not leak caller-location');
like($r->{error}, qr/Invalid action 'bogus'/,
    'vc.branch.invalid: clean invalid-action error');

$r = $vc->execute({
    operation => 'stash',
    action => 'bogus',
    repository_path => $git_dir,
}, {});
ok($r && !$r->{success}, 'vc.stash.invalid: failed as expected');
is($r->{tool_name}, 'version_control', 'vc.stash.invalid: tool_name is set');
unlike($r->{error}, qr{ at \S+ line \d+},
    'vc.stash.invalid: error does not leak caller-location');
like($r->{error}, qr/Invalid action 'bogus'/,
    'vc.stash.invalid: clean invalid-action error');

$r = $vc->execute({
    operation => 'tag',
    action => 'bogus',
    repository_path => $git_dir,
}, {});
ok($r && !$r->{success}, 'vc.tag.invalid: failed as expected');
is($r->{tool_name}, 'version_control', 'vc.tag.invalid: tool_name is set');
unlike($r->{error}, qr{ at \S+ line \d+},
    'vc.tag.invalid: error does not leak caller-location');

$r = $vc->execute({
    operation => 'worktree',
    action => 'bogus',
    repository_path => $git_dir,
}, {});
ok($r && !$r->{success}, 'vc.worktree.invalid: failed as expected');
is($r->{tool_name}, 'version_control', 'vc.worktree.invalid: tool_name is set');
unlike($r->{error}, qr{ at \S+ line \d+},
    'vc.worktree.invalid: error does not leak caller-location');

# Eval/croak path: command inside eval fails. The error captured into $@
# goes through _clean_eval_error before being passed to error_result.
# We deliberately exercise paths where the eval block sets an error.
$r = $vc->execute({
    operation => 'commit',
    message => 'test',
    repository_path => $git_dir,
}, {});
ok($r && !$r->{success}, 'vc.commit nothing_to_commit: failed as expected');
is($r->{tool_name}, 'version_control',
    'vc.commit nothing_to_commit: tool_name is set');
unlike($r->{error}, qr{ at \S+?\.pm line \d+},
    'vc.commit nothing_to_commit: error does NOT leak .pm caller-location');
like($r->{error}, qr/Nothing to commit/,
    'vc.commit nothing_to_commit: clean error message');

# ── Test 4: RemoteExecution $@ cleanup ───────────────────────────────

print "\n--- RemoteExecution: \$@ cleanup ---\n";

require_ok('CLIO::Tools::RemoteExecution');
my $rx = CLIO::Tools::RemoteExecution->new(debug => 0);

# Missing host: clean validation path
$r = $rx->execute({ operation => 'check_remote' }, {});
ok($r && !$r->{success}, 'rx.check_remote.missing: failed as expected');
is($r->{tool_name}, 'remote_execution',
    'rx.check_remote.missing: tool_name is set');
unlike($r->{error}, qr{ at \S+ line \d+},
    'rx.check_remote.missing: error does not leak caller-location');
like($r->{error}, qr/Missing required parameter: host/,
    'rx.check_remote.missing: clean missing-host');

# check_remote() with a bogus host - eval croaks, $@ gets the suffix,
# which must be stripped before being passed to error_result.
$r = $rx->execute({
    operation => 'check_remote',
    host => 'this-host-definitely-does-not-exist.invalid',
    timeout => 2,
}, {});
ok($r && !$r->{success}, 'rx.check_remote: failed as expected');
is($r->{tool_name}, 'remote_execution', 'rx.check_remote: tool_name is set');
unlike($r->{error}, qr{ at \S+ line \d+},
    'rx.check_remote: error does not leak caller-location');
like($r->{error}, qr/Remote check failed:/,
    'rx.check_remote: contextual wrapper present');

# prepare_remote() with bogus host
$r = $rx->execute({
    operation => 'prepare_remote',
    host => 'this-host-definitely-does-not-exist.invalid',
    timeout => 2,
}, {});
ok($r && !$r->{success}, 'rx.prepare_remote: failed as expected');
is($r->{tool_name}, 'remote_execution', 'rx.prepare_remote: tool_name is set');
unlike($r->{error}, qr{ at \S+ line \d+},
    'rx.prepare_remote: error does not leak caller-location');
like($r->{error}, qr/Preparation failed:/,
    'rx.prepare_remote: contextual wrapper present');

# cleanup_remote() missing install_dir
$r = $rx->execute({
    operation => 'cleanup_remote',
    host => 'somehost',
}, {});
ok($r && !$r->{success}, 'rx.cleanup_remote: failed as expected');
is($r->{tool_name}, 'remote_execution', 'rx.cleanup_remote: tool_name is set');
unlike($r->{error}, qr{ at \S+ line \d+},
    'rx.cleanup_remote: error does not leak caller-location');
like($r->{error}, qr/Missing required parameters/,
    'rx.cleanup_remote: clean missing-params');

# transfer_files() missing files param
$r = $rx->execute({
    operation => 'transfer_files',
    host => 'somehost',
}, {});
ok($r && !$r->{success}, 'rx.transfer_files: failed as expected');
is($r->{tool_name}, 'remote_execution', 'rx.transfer_files: tool_name is set');
unlike($r->{error}, qr{ at \S+ line \d+},
    'rx.transfer_files: error does not leak caller-location');
like($r->{error}, qr/Missing or empty 'files' parameter/,
    'rx.transfer_files: clean missing-files');

# retrieve_files() missing files param
$r = $rx->execute({
    operation => 'retrieve_files',
    host => 'somehost',
}, {});
ok($r && !$r->{success}, 'rx.retrieve_files: failed as expected');
is($r->{tool_name}, 'remote_execution', 'rx.retrieve_files: tool_name is set');
unlike($r->{error}, qr{ at \S+ line \d+},
    'rx.retrieve_files: error does not leak caller-location');

# ── Test 5: WebOperations helper-level $@ cleanup (structural) ──────

print "\n--- WebOperations: \$@ cleanup (structural) ---\n";

require_ok('CLIO::Tools::WebOperations');
my $web = CLIO::Tools::WebOperations->new(debug => 0);
ok($web, 'web: instantiated');

# Easiest way to verify the $@ cleanup happens inside the search helpers
# without making live HTTP calls: check the source. Each helper's $@-handler
# branch must call _clean_eval_error on $@, not forward $@ raw.
my $src = do {
    open my $fh, '<:encoding(UTF-8)', "$RealBin/../../lib/CLIO/Tools/WebOperations.pm" or die;
    local $/;
    <$fh>;
};

my $helper_count = () = $src =~ /sub _search_(?:serpapi|brave|duckduckgo_direct)/g;
is($helper_count, 3, 'web: 3 search helpers exist');

my $clean_count = () = $src =~ /error\s*=>\s*\$self->_clean_eval_error\(\$@\)/g;
is($clean_count, 3, 'web: all 3 search helpers use _clean_eval_error() on $@');

my $raw_count = () = $src =~ /error\s*=>\s*\$@/g;
is($raw_count, 0, 'web: no raw $@ leaks in search helpers');

# ── Test 5b: TerminalOperations / MemoryOperations / FileOperations audit ─

print "\n--- Other tools: \$@ cleanup audit ---\n";

# Structural check: all $@-forwarding error_result() calls must use
# _clean_eval_error(). Search for the (now-fixed) anti-pattern in each file.
my $lib_root = "$RealBin/../../lib";
for my $rel_path (qw(
    CLIO/Tools/TerminalOperations.pm
    CLIO/Tools/MemoryOperations.pm
    CLIO/Tools/FileOperations.pm
    CLIO/Tools/ApplyPatch.pm
)) {
    my $abs = "$lib_root/$rel_path";
    open my $fh, '<:encoding(UTF-8)', $abs or die "Cannot read $abs: $!";
    my $contents = do { local $/; <$fh> };
    close $fh;

    my $short = $rel_path;
    $short =~ s|^CLIO/Tools/||;

    # Anti-pattern: error_result("...: \$@") without _clean_eval_error wrapping
    # Allow the case where the SAME line has _clean_eval_error either before or after
    # the literal: we accept either form. We test for the BAD form.
    my @bad;
    my @lines = split /\n/, $contents;
    for my $i (0 .. $#lines) {
        next unless $lines[$i] =~ /error_result/ && $lines[$i] =~ /\$@/;
        next if $lines[$i] =~ /_clean_eval_error/;
        # Skip log_* lines that happen to contain both keywords
        next if $lines[$i] =~ /^\s*log_/;
        push @bad, "line " . ($i + 1) . ": " . $lines[$i];
    }

    is(scalar(@bad), 0, "$short: no raw \$@ in error_result() calls")
        or diag(join("\n", @bad));
}

# Also count the $@-forwarding paths that ARE cleaned (just to confirm coverage)
for my $rel_path (qw(
    CLIO/Tools/MemoryOperations.pm
    CLIO/Tools/FileOperations.pm
    CLIO/Tools/TerminalOperations.pm
)) {
    my $abs = "$lib_root/$rel_path";
    open my $fh, '<:encoding(UTF-8)', $abs or next;
    my $contents = do { local $/; <$fh> };
    close $fh;

    my $short = $rel_path;
    $short =~ s|^CLIO/Tools/||;

    my $count = () = $contents =~ /error_result\("[^"]*:\s*"\s*\.\s*\$self->_clean_eval_error\(\$@\)\)/g;
    ok($count >= 1, "$short: at least 1 cleaned error_result() path (found $count)");
}

# ── Test 6: ToolErrorGuidance categorizes cleaned errors ─────────────

print "\n--- ToolErrorGuidance categorizes cleaned errors ---\n";

my $guidance = CLIO::Core::ToolErrorGuidance->new();

my $enhanced = $guidance->enhance_tool_error(
    error => 'Missing required parameter: message',
    tool_name => 'interact',
    tool_definition => {},
    attempted_params => {},
);
like($enhanced, qr/required field\(s\)/i,
    'guidance: interact missing_param -> missing_required');

$enhanced = $guidance->enhance_tool_error(
    error => "Invalid action 'bogus'. Must be one of: list, create, delete, switch",
    tool_name => 'version_control',
    tool_definition => {},
    attempted_params => {},
);
like($enhanced, qr/wrong type|wrong range|schema/i,
    'guidance: vc invalid_action -> invalid_value');

$enhanced = $guidance->enhance_tool_error(
    error => 'Missing required parameter: host',
    tool_name => 'remote_execution',
    tool_definition => {},
    attempted_params => {},
);
like($enhanced, qr/required field\(s\)/i,
    'guidance: rx missing_host -> missing_required');

done_testing();

print "\n=== Tool \$@ cleanup tests COMPLETE ===\n";
