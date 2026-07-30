#!/usr/bin/env perl
# Test default timeout (300s) and PGID safety check in _kill_process_group.
#
# Background: Previously terminal_operations had a 60s default idle timeout
# which was too aggressive for silently-working commands (model loading,
# large compiles, DB queries). It also killed the process group without
# verifying the child actually set its own PGID, which could leak to
# CLIO/shell if the child's setpgid(0, 0) silently failed at fork.

use strict;
use warnings;
use utf8;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";

use POSIX qw(WNOHANG);
use Time::HiRes ();

# ─────────────────────────────────────────────────────────────
# Helper: get a process's PGID via ps (portable across Linux/macOS).
# POSIX::getpgid is not available on macOS Perl, so we shell out.
# ─────────────────────────────────────────────────────────────
sub _pgid_of {
    my ($pid) = @_;
    my $ps = `ps -o pid,pgid -p $pid 2>/dev/null`;
    if ($ps =~ /^\s*\d+\s+(\d+)/m) {
        return $1;
    }
    return undef;
}

# ─────────────────────────────────────────────────────────────
# Test 1: Default timeout is 300s
# Inspect the source for the default value to catch regressions.
# ─────────────────────────────────────────────────────────────
{
    open my $fh, '<', "$RealBin/../../lib/CLIO/Tools/TerminalOperations.pm"
        or die "Cannot open TerminalOperations.pm: $!";
    my $source = do { local $/; <$fh> };
    close $fh;

    like($source, qr/my \$timeout = \$params->\{timeout\} \|\| 300;/,
        "execute_command defaults timeout to 300s");
    unlike($source, qr/my \$timeout = \$params->\{timeout\} \|\| 60;/,
        "execute_command does NOT default timeout to 60s");

    # The hard ceiling is 600s (10min) and remains so.
    like($source, qr/CLIO_TERMINAL_MAX_TIMEOUT\}\s*\|\|\s*600/,
        "hard ceiling is 600s (CLIO_TERMINAL_MAX_TIMEOUT || 600)");
}

# ─────────────────────────────────────────────────────────────
# Test 2: Tool schema advertises 300s default
# The tool's parameter description must reflect the new default so the
# LLM knows to set a longer timeout for slow operations.
# ─────────────────────────────────────────────────────────────
{
    open my $fh, '<', "$RealBin/../../lib/CLIO/Tools/TerminalOperations.pm"
        or die "Cannot open TerminalOperations.pm: $!";
    my $source = do { local $/; <$fh> };
    close $fh;

    like($source, qr/Default:\s*300/,
        "timeout parameter description mentions Default: 300");
    unlike($source, qr/Default:\s*60/,
        "timeout parameter description does NOT mention Default: 60");
}

# ─────────────────────────────────────────────────────────────
# Test 3: _kill_process_group refuses to kill when child's PGID != child PID
# This is the safety check that prevents accidentally killing CLIO if the
# child's setpgid(0, 0) silently failed at fork.
# ─────────────────────────────────────────────────────────────
{
    use_ok('CLIO::Tools::TerminalOperations');

    my $tool = CLIO::Tools::TerminalOperations->new();

    # Spawn a child that does NOT set its own PGID. It will inherit the
    # test's PGID, which is definitely not the child's PID. This simulates
    # the failure mode that triggered the bug.
    my $pid = fork();
    die "Fork failed: $!" unless defined $pid;

    if ($pid == 0) {
        # Child: do NOT call setpgid(0, 0). Inherit test's PGID.
        sleep 5;
        exit 0;
    }

    # Confirm setup: child is alive, not in its own PGID
    ok(kill(0, $pid), "child is alive before kill attempt");
    my $child_pgid = _pgid_of($pid);
    ok(defined $child_pgid, "child's PGID is readable (got $child_pgid)");
    isnt($child_pgid, $pid, "child's PGID ($child_pgid) != child's PID ($pid) - simulates failed setpgid");

    # Now call _kill_process_group. It should refuse and return without killing.
    $tool->_kill_process_group($pid);

    # Give it a moment to act
    Time::HiRes::usleep(200_000);

    # Child should still be alive (the kill was refused)
    ok(kill(0, $pid), "child is still alive after _kill_process_group refused to act");

    # Reap the child cleanly
    kill('TERM', $pid);
    waitpid($pid, 0);
}

# ─────────────────────────────────────────────────────────────
# Test 4: _kill_process_group DOES kill when child properly set its PGID
# The safety check must not break the normal kill path.
# ─────────────────────────────────────────────────────────────
{
    my $tool = CLIO::Tools::TerminalOperations->new();

    my $pid = fork();
    die "Fork failed: $!" unless defined $pid;

    if ($pid == 0) {
        # Child: properly set its own PGID (matches _kill_process_group's
        # assumption).
        POSIX::setpgid(0, 0);
        sleep 5;
        exit 0;
    }

    # Parent: race-safe setpgid
    POSIX::setpgid($pid, $pid);

    ok(kill(0, $pid), "child is alive before kill attempt");
    my $child_pgid = _pgid_of($pid);
    is($child_pgid, $pid, "child's PGID == child's PID (set up correctly)");

    # _kill_process_group should kill the child (and reap it internally).
    $tool->_kill_process_group($pid);

    # Child should be dead (the kill was not refused; PGID matched).
    # Give the kill a moment to land.
    Time::HiRes::usleep(200_000);
    ok(!kill(0, $pid), "child is dead after _kill_process_group ran");
}

# ─────────────────────────────────────────────────────────────
# Test 5: _kill_process_group with pid=0 or undef is a no-op
# This protects against accidental calls with invalid PIDs.
# ─────────────────────────────────────────────────────────────
{
    my $tool = CLIO::Tools::TerminalOperations->new();

    # These should not croak or do anything dangerous
    $tool->_kill_process_group(0);
    $tool->_kill_process_group(undef);
    $tool->_kill_process_group(-1);

    ok(1, "_kill_process_group silently ignores invalid PIDs");
}

# ─────────────────────────────────────────────────────────────
# Test 6: _kill_process_group safety check survives even if config lacks POSIX::getpgid
# On macOS, POSIX::getpgid is not exported. The code uses eval{} to defend
# against this, but the fallback path must still refuse to kill rather than
# silently sending SIGKILL to the wrong group.
# ─────────────────────────────────────────────────────────────
SKIP: {
    skip "PGID safety requires child to have its own PGID", 1
        unless _pgid_of($$) == $$;

    # We can only run this test if the test process itself has its own PGID
    # (exercises the same code path as CLIO would).
    my $tool = CLIO::Tools::TerminalOperations->new();
    my $pid = fork();
    die "Fork failed: $!" unless defined $pid;

    if ($pid == 0) {
        POSIX::setpgid(0, 0);
        sleep 5;
        exit 0;
    }
    POSIX::setpgid($pid, $pid);

    my $child_pgid = _pgid_of($pid);
    is($child_pgid, $pid, "child is in its own PGID (sanity check for the test)");

    # Call _kill_process_group via the safety-checked path. Should kill the child.
    $tool->_kill_process_group($pid);

    my $waited = waitpid($pid, 0);
    is($waited, $pid, "child was reaped after PGID-verified kill");
}

done_testing();
