#!/usr/bin/env perl

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

=head1 NAME

test_tool_execution_exception_recovery.pl - Regression tests for tool exception recovery

=head1 DESCRIPTION

The bug: when a tool's before_route() or dispatched method raises an
unexpected die/croak, the exception propagates all the way up through
ToolExecutor and the WorkflowOrchestrator. SimpleAIAgent's outermost
eval catches it and surfaces the generic "I'm experiencing technical
difficulties. Please try again." - which strips all diagnostic context
and prevents the AI from recovering.

Real-world example from production (ALICE session 2026-08-21):
  Agent invoked version_control with repository_path=/Users/andrew/ALICE
  (a hallucinated macOS path - the agent was actually on Linux at
  /home/deck/repositories/ALICE).
  - VersionControl.before_route() calls _is_git_repo() with no eval
  - _is_git_repo() calls _in_repo() which croaks on chdir failure
  - Croak propagates through Tool.execute() (also no eval)
  - Propagates through ToolExecutor.execute_tool() (also no eval)
  - Propagates through WorkflowOrchestrator._execute_tool_round
  - Propagates through process_input
  - SimpleAIAgent's eval catches it: "I'm experiencing technical
    difficulties. Please try again."
  - ToolErrorGuidance NEVER gets a chance to categorize the failure
  - The AI gets no actionable information and the conversation dies

The fix has two layers of defense:

  1. Tool::execute() wraps route_operation() in eval{} so ANY uncaught
     die/croak in any tool is converted to a proper error_result().
     This is the universal choke point - protects ALL tools, not just
     VersionControl.

  2. VersionControl::_in_repo() uses die() instead of croak() for chdir
     failure. A non-existent repository_path is an expected user error,
     not an exceptional condition. The die is caught by the existing
     eval{} blocks in each operation handler (status, log, diff, etc.)
     and produces a clean error message via _clean_eval_error().

This test exercises both layers:
  - Layer 1 (Tool::execute eval): a tool that raises from before_route
    or the dispatched method should still produce a structured error_result.
  - Layer 2 (VersionControl::_in_repo): VersionControl with a non-existent
    repository_path should produce a structured error_result with a clean
    message (no caller-location leak).

=cut

use Test::More;
use File::Temp qw(tempdir);

BEGIN { use_ok('CLIO::Tools::Tool') or BAIL_OUT("Cannot load Tool base"); }
use_ok('CLIO::Tools::VersionControl');
use_ok('CLIO::Core::ToolErrorGuidance');

print "\n=== Tool Execution Exception Recovery Tests ===\n";

# ── Layer 1: Tool::execute() eval catches arbitrary die/croak ──────

print "\n--- Layer 1: Tool::execute converts uncaught die to error_result ---\n";

# Define a tool whose before_route() croaks. With the fix, this should
# be caught and converted to a clean error_result.
{
    package ExplodingTool;
    use parent 'CLIO::Tools::Tool';
    sub new {
        my ($class, %opts) = @_;
        return $class->SUPER::new(
            name => 'exploding_tool',
            description => 'A tool whose before_route raises',
            supported_operations => [qw(blow_up)],
            %opts,
        );
    }
    sub dispatch_table {
        return { blow_up => 'blow_up' };
    }
    sub before_route {
        my ($self, $op, $params, $ctx) = @_;
        # Simulate the bug pattern: an uncaught croak in before_route.
        # This is exactly what VersionControl._in_repo() used to do.
        require Carp;
        Carp::croak("Cannot chdir to /Users/andrew/ALICE: No such file or directory");
    }
    sub blow_up {
        my ($self, $params, $context) = @_;
        return $self->success_result("should never reach here");
    }
}

my $et = ExplodingTool->new(debug => 0);
my $r;
eval {
    $r = $et->execute({operation => 'blow_up'}, {});
};
is($@, '', 'Tool::execute: no exception leaks past eval');
ok(defined($r), 'Tool::execute: result is defined');
ok(ref($r) eq 'HASH', 'Tool::execute: result is a hashref') or diag("got: ", ref($r));
is($r->{success}, 0, 'Tool::execute: result success=0');
ok(defined($r->{error}), 'Tool::execute: result has error');
is($r->{tool_name}, 'exploding_tool', 'Tool::execute: tool_name propagated');
like($r->{error}, qr/Cannot chdir to \/Users\/andrew\/ALICE/,
    'Tool::execute: error preserves underlying cause');
unlike($r->{error}, qr/ at \S+ line \d+/,
    'Tool::execute: error has no Carp caller-location suffix');

# Also test: die() (not croak) from before_route. The eval should
# convert to error_result and _clean_eval_error should strip any
# trailing caller-location that other die() forms might add.
{
    package DieTool;
    use parent 'CLIO::Tools::Tool';
    sub new {
        my ($class, %opts) = @_;
        return $class->SUPER::new(
            name => 'die_tool',
            description => 'A tool whose before_route die()s',
            supported_operations => [qw(fail)],
            %opts,
        );
    }
    sub dispatch_table {
        return { fail => 'fail' };
    }
    sub before_route {
        my ($self) = @_;
        die "Something bad happened\n";
    }
    sub fail {
        my ($self) = @_;
        return $self->success_result("unreachable");
    }
}

my $dt = DieTool->new(debug => 0);
$r = $dt->execute({operation => 'fail'}, {});
is($r->{success}, 0, 'Tool::execute: die() also converted to error_result');
like($r->{error}, qr/Something bad happened/,
    'Tool::execute: die() message preserved');

# Test: die() from the dispatched method itself (not before_route).
# Should also be caught.
{
    package MethodDieTool;
    use parent 'CLIO::Tools::Tool';
    sub new {
        my ($class, %opts) = @_;
        return $class->SUPER::new(
            name => 'method_die_tool',
            description => 'A tool whose dispatched method die()s',
            supported_operations => [qw(fail)],
            %opts,
        );
    }
    sub dispatch_table {
        return { fail => 'fail' };
    }
    sub before_route { return undef; }
    sub fail {
        my ($self) = @_;
        die "Method-level failure\n";
    }
}

my $mdt = MethodDieTool->new(debug => 0);
$r = $mdt->execute({operation => 'fail'}, {});
is($r->{success}, 0, 'Tool::execute: method die() also converted');
like($r->{error}, qr/Method-level failure/,
    'Tool::execute: method die() message preserved');

# ── Layer 2: VersionControl::_in_repo() handles chdir failure ──────

print "\n--- Layer 2: VersionControl with non-existent repository_path ---\n";

my $vc = CLIO::Tools::VersionControl->new(debug => 0);

# Test: the EXACT scenario from the bug report.
# version_control with repository_path=/Users/andrew/ALICE (hallucinated
# macOS path on Linux). Before the fix this would crash the entire
# conversation with "I'm experiencing technical difficulties". After
# the fix it returns a structured error_result that the AI can recover from.
$r = $vc->execute({
    operation => 'status',
    repository_path => '/Users/andrew/ALICE',
}, {});
ok(defined($r), 'vc.status hallucinated_path: result defined');
is($r->{success}, 0, 'vc.status hallucinated_path: success=0');
ok($r->{error}, 'vc.status hallucinated_path: has error');
is($r->{tool_name}, 'version_control', 'vc.status hallucinated_path: tool_name set');
like($r->{error}, qr/Cannot chdir to \/Users\/andrew\/ALICE/,
    'vc.status hallucinated_path: error mentions the bad path');
unlike($r->{error}, qr/ at \S+ line \d+/,
    'vc.status hallucinated_path: error has no caller-location leak');

# Test: same scenario for log, diff, branch, commit - all should be caught.
for my $op (qw(log diff branch commit)) {
    $r = $vc->execute({
        operation => $op,
        repository_path => '/Users/andrew/ALICE',
    }, {});
    is($r->{success}, 0, "vc.$op hallucinated_path: success=0")
        or diag("op=$op result=", explain($r));
    ok($r->{error}, "vc.$op hallucinated_path: has error");
    is($r->{tool_name}, 'version_control', "vc.$op hallucinated_path: tool_name set");
    unlike($r->{error}, qr/ at \S+ line \d+/,
        "vc.$op hallucinated_path: no caller-location leak");
}

# Test: status() called directly (not via execute()) - this is what
# happens for non-pre-routed paths. The existing eval{} in status()
# should produce a clean "Git status failed: Cannot chdir to ..." message.
$r = $vc->status({
    operation => 'status',
    repository_path => '/Users/andrew/ALICE',
}, {});
is($r->{success}, 0, 'vc.status direct: success=0');
like($r->{error}, qr/Git status failed: Cannot chdir to \/Users\/andrew\/ALICE/,
    'vc.status direct: clean wrapped error message');
unlike($r->{error}, qr/ at \S+ line \d+/,
    'vc.status direct: no caller-location leak');

# Test: pre-existing behavior for valid-but-not-git path is unchanged.
$r = $vc->execute({
    operation => 'status',
    repository_path => '/tmp',
}, {});
is($r->{success}, 0, 'vc.status /tmp: success=0 (regression check)');
like($r->{error}, qr/Not a Git repository: \/tmp/,
    'vc.status /tmp: still says Not a Git repository (no regression)');

# Test: pre-existing behavior for valid git repo is unchanged.
my $git_dir = tempdir(CLEANUP => 1);
system('git', '-C', $git_dir, 'init', '-q') == 0
    or die "git init failed: $?";
system('git', '-C', $git_dir, 'config', 'user.email', 'test@example.com') == 0;
system('git', '-C', $git_dir, 'config', 'user.name', 'Test User') == 0;

$r = $vc->execute({
    operation => 'status',
    repository_path => $git_dir,
}, {});
is($r->{success}, 1, 'vc.status valid_git_repo: success=1 (regression check)');
ok($r->{output}, 'vc.status valid_git_repo: has output');

# ── Layer 3: ToolErrorGuidance can categorize the recovered error ──

print "\n--- Layer 3: ToolErrorGuidance categorizes the recovered error ---\n";

my $guidance = CLIO::Core::ToolErrorGuidance->new();

# Simulate the full pipeline: ToolExecutor returns error_result,
# WorkflowOrchestrator extracts error and calls enhance_tool_error.
my $recovered_error = 'Cannot chdir to /Users/andrew/ALICE: No such file or directory';
my $enhanced = $guidance->enhance_tool_error(
    error => $recovered_error,
    tool_name => 'version_control',
    tool_definition => {},
    attempted_params => { operation => 'status', repository_path => '/Users/andrew/ALICE' },
);

like($enhanced, qr/file not found|doesn.t exist|not exist/i,
    'guidance: hallucinated_path error categorized as file_not_found')
    or diag("enhanced output:\n", $enhanced);
like($enhanced, qr/CHECK.*PATH|absolute|relative/i,
    'guidance: provides actionable file_not_found guidance');

done_testing();

print "\n=== Tool Execution Exception Recovery Tests COMPLETE ===\n";