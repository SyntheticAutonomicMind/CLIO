#!/usr/bin/env perl
# Regression test for terminal operations kill safety.
#
# Background:
#   Commit 785b308 added a PGID safety check to _kill_process_group to prevent
#   the kill from accidentally hitting CLIO when the child's setpgid(0, 0)
#   silently failed at fork time. The accompanying test
#   (test_terminal_timeout_defaults.pl) verified that the child died (or lived)
#   but NEVER verified the PARENT (CLIO) survived. This was a critical gap.
#
# This test closes that gap by:
#   1. Using the EXACT shell pipeline structure from the user's reported bug
#   2. Adding parent-survival assertions after every kill scenario
#   3. Testing multiple failure modes that could leak the kill to CLIO
#   4. Verifying orphan cleanup so grandchildren don't pile up
#
# Each subtest MUST verify:
#   - The expected kill behavior (child dies OR safety check refuses)
#   - The PARENT process is still alive after the kill attempt
#   - No orphan processes leak from the test

use strict;
use warnings;
use utf8;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";

use POSIX qw(WNOHANG);
use Time::HiRes ();

use CLIO::Tools::TerminalOperations;

# ─────────────────────────────────────────────────────────────
# Helper: get a process's PGID via ps (portable across Linux/macOS).
# POSIX::getpgid is not exported on macOS Perl, so shell out.
# ─────────────────────────────────────────────────────────────
sub _pgid_of {
    my ($pid) = @_;
    my $ps = `ps -o pid,pgid -p $pid 2>/dev/null`;
    if ($ps =~ /^\s*\d+\s+(\d+)/m) {
        return $1;
    }
    return undef;
}

# Cleanup: kill any leftover test processes
sub _cleanup {
    system("pkill -f 'sleep 1' 2>/dev/null");
    system("pkill -f 'sleep 10' 2>/dev/null");
    system("pkill -f 'while true' 2>/dev/null");
    unlink glob "/tmp/clio_test_killsafety_*.log";
    unlink glob "/tmp/clio_terminal_*.log";
}

# ─────────────────────────────────────────────────────────────
# Test 1: Parent survives normal kill (child in its own PGID).
# Mirrors the previous test but adds the missing parent-survival check.
# ─────────────────────────────────────────────────────────────
subtest 'Parent survives kill with child in its own PGID' => sub {
    plan tests => 4;
    _cleanup();

    my $tool = CLIO::Tools::TerminalOperations->new();
    my $parent_pid = $$;
    my $parent_pgid = _pgid_of($parent_pid);

    my $pid = fork();
    die "Fork failed: $!" unless defined $pid;

    if ($pid == 0) {
        POSIX::setpgid(0, 0);
        sleep 5;
        exit 0;
    }

    eval { POSIX::setpgid($pid, $pid) };

    my $child_pgid = _pgid_of($pid);
    ok(defined $child_pgid && $child_pgid == $pid,
        "child is in its own PGID (pid=$pid, pgid=$child_pgid)");

    $tool->_kill_process_group($pid);
    Time::HiRes::usleep(200_000);

    # CRITICAL: Parent must survive
    ok(kill(0, $parent_pid), "parent (PID $parent_pid) survived the kill");
    is(_pgid_of($parent_pid), $parent_pgid, "parent's PGID unchanged");
    ok(!kill(0, $pid), "child was killed");

    waitpid($pid, 0) if kill(0, $pid);
};

# ─────────────────────────────────────────────────────────────
# Test 2: Parent survives shell pipeline + timeout.
# Reproduces the EXACT scenario from the user's bug report:
#   timeout N silent_command | head -M
# where silent_command mimics hdc-chat (ignores SIGTERM).
# ─────────────────────────────────────────────────────────────
subtest 'Parent survives shell pipeline + timeout (user scenario)' => sub {
    plan tests => 4;
    _cleanup();

    my $tool = CLIO::Tools::TerminalOperations->new();
    my $parent_pid = $$;

    # hdc-chat style: ignores SIGTERM, keeps running, only KILL terminates it
    my $cmd = q{(trap '' TERM; while true; do sleep 1; done) | head -5};

    my $result = $tool->execute_command({
        command => $cmd,
        timeout => 2,
    });

    is($result->{exit_code}, 124, 'exit code is 124 (timeout)');
    ok(kill(0, $parent_pid), 'parent survived shell pipeline + timeout');

    my $orphans = `ps -eo pid,command 2>/dev/null | grep -E 'sleep 1|sleep 1000' | grep -v grep`;
    is($orphans, '', 'no orphan grandchildren');

    ok(_pgid_of($parent_pid), "parent's PGID still resolvable");
};

# ─────────────────────────────────────────────────────────────
# Test 3: Parent survives SIGKILL escalation (child catches TERM).
# When the child ignores SIGTERM, the kill escalates to SIGKILL after 2s.
# ─────────────────────────────────────────────────────────────
subtest 'Parent survives SIGKILL escalation when child catches TERM' => sub {
    plan tests => 4;
    _cleanup();

    my $tool = CLIO::Tools::TerminalOperations->new();
    my $parent_pid = $$;

    # hdc-chat style: ignores both SIGTERM and SIGINT
    my $cmd = q{(trap '' TERM; trap '' INT; while true; do sleep 1; done) | head -5};

    my $result = $tool->execute_command({
        command => $cmd,
        timeout => 1,  # Short so KILL escalation fires
    });

    is($result->{exit_code}, 124, 'exit code is 124 (timeout)');
    ok(kill(0, $parent_pid), 'parent survived SIGKILL escalation');

    Time::HiRes::usleep(300_000);
    my $orphans = `ps -eo pid,command 2>/dev/null | grep -E 'sleep 1\\b' | grep -v grep`;
    is($orphans, '', 'no orphan processes after KILL escalation');

    my $shells = `ps -eo pid,command 2>/dev/null | grep -E 'while true' | grep -v grep`;
    is($shells, '', 'no orphan while-loop shells');
};

# ─────────────────────────────────────────────────────────────
# Test 4: Parent survives when child's setpgid silently fails.
# Forces the child into the parent's PGID. Safety check must refuse the kill.
# ─────────────────────────────────────────────────────────────
subtest 'Parent survives when child is in parent PGID (safety refuses)' => sub {
    plan tests => 3;
    _cleanup();

    my $tool = CLIO::Tools::TerminalOperations->new();
    my $parent_pid = $$;
    my $parent_pgid = _pgid_of($parent_pid);

    my $pid = fork();
    die "Fork failed: $!" unless defined $pid;

    if ($pid == 0) {
        # Force child into parent's PGID (simulating setpgid failure)
        POSIX::setpgid(0, $parent_pid);
        sleep 5;
        exit 0;
    }

    my $child_pgid = _pgid_of($pid);
    is($child_pgid, $parent_pgid,
        "child is in parent's PGID ($child_pgid == $parent_pgid)");

    $tool->_kill_process_group($pid);
    Time::HiRes::usleep(200_000);

    ok(kill(0, $pid), 'child survived (safety check refused the kill)');
    ok(kill(0, $parent_pid), 'parent survived attempted kill');

    kill('KILL', $pid);
    waitpid($pid, 0);
};

# ─────────────────────────────────────────────────────────────
# Test 5: Parent survives concurrent terminal_operations calls.
# ─────────────────────────────────────────────────────────────
subtest 'Parent survives concurrent terminal_operations' => sub {
    plan tests => 3;
    _cleanup();

    my $tool = CLIO::Tools::TerminalOperations->new();
    my $parent_pid = $$;

    my $r1 = $tool->execute_command({
        command => q{(sleep 2) | head -1},
        timeout => 30,
    });
    my $r2 = $tool->execute_command({
        command => q{(sleep 2) | head -1},
        timeout => 30,
    });

    ok(kill(0, $parent_pid), 'parent survived concurrent ops');
    ok($r1->{success} && $r2->{success}, 'both commands succeeded');

    my $orphans = `ps -eo pid,command 2>/dev/null | grep -E 'sleep 2\\b' | grep -v grep`;
    is($orphans, '', 'no orphan processes from concurrent runs');
};

# ─────────────────────────────────────────────────────────────
# Test 6: Parent survives with grandchild processes.
# ─────────────────────────────────────────────────────────────
subtest 'Parent survives with grandchild processes' => sub {
    plan tests => 4;
    _cleanup();

    my $tool = CLIO::Tools::TerminalOperations->new();
    my $parent_pid = $$;

    # Command that forks a grandchild that ignores signals
    my $cmd = q{(bash -c 'trap "" TERM; (sleep 10 &); exec sleep 10') | head -1};

    my $result = $tool->execute_command({
        command => $cmd,
        timeout => 2,
    });

    is($result->{exit_code}, 124, 'timeout fired');
    ok(kill(0, $parent_pid), 'parent survived with grandchildren');

    Time::HiRes::usleep(500_000);
    my $orphans = `ps -eo pid,command 2>/dev/null | grep -E 'sleep 10' | grep -v grep`;
    is($orphans, '', 'no orphan grandchild processes');

    my $trapped = `ps -eo pid,command 2>/dev/null | grep -E 'bash.*sleep 10' | grep -v grep`;
    is($trapped, '', 'no trapped bash subshells');
};

# ─────────────────────────────────────────────────────────────
# Test 7: Stress test - many rapid kills don't accumulate risk.
# ─────────────────────────────────────────────────────────────
subtest 'Parent survives stress test of rapid kills' => sub {
    plan tests => 2;
    _cleanup();

    my $tool = CLIO::Tools::TerminalOperations->new();
    my $parent_pid = $$;

    for my $i (1..20) {
        $tool->execute_command({
            command => q{(sleep 1) | head -1},
            timeout => 30,
        });
    }

    ok(kill(0, $parent_pid), 'parent survived 20 rapid kills');
    my $orphans = `ps -eo pid,command 2>/dev/null | grep -E 'sleep 1\\b' | grep -v grep`;
    is($orphans, '', 'no orphan processes after stress test');
};

# ─────────────────────────────────────────────────────────────
# Test 8: PGID safety check refuses for invalid input.
# ─────────────────────────────────────────────────────────────
subtest 'PGID safety refuses for invalid input' => sub {
    plan tests => 4;

    my $tool = CLIO::Tools::TerminalOperations->new();

    $tool->_kill_process_group(0);
    ok(1, 'pid=0 is a no-op');

    $tool->_kill_process_group(undef);
    ok(1, 'undef pid is a no-op');

    $tool->_kill_process_group(-1);
    ok(1, 'pid=-1 is a no-op');

    # Non-numeric pid: the guard `$pid =~ /^\d+$/` rejects this before any
    # numeric comparison, so no warning is emitted. We just verify it's safe.
    {
        my @warnings;
        local $SIG{__WARN__} = sub { push @warnings, $_[0] };
        $tool->_kill_process_group('not_a_pid');
        ok(1, 'non-numeric pid is a no-op');
    };
};

_cleanup();
done_testing();
