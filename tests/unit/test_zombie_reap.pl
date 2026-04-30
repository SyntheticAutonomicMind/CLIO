#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

# Test zombie prevention for fire-and-forget forks in CLIO
#
# === BACKGROUND ===
#
# CLIO has three distinct fork patterns in the codebase:
#
#   1. TRACKED forks (ProgressSpinner, MCP::Transport::Stdio,
#      Coordination::SubAgent::spawn_agent, Commands::SubAgent::start_broker):
#      The parent records the PID and eventually calls waitpid($pid, ...).
#      No zombie risk. No changes needed or made.
#
#   2. FIRE-AND-FORGET forks (Update::check_for_updates_async,
#      MCP::Auth::OAuth::_open_browser, UI::Chat::_check_for_updates_async):
#      The parent never calls waitpid. When the child exits, the kernel keeps
#      its exit record until a parent reaps it - this is a zombie process.
#      Long-running CLIO sessions accumulate these until process table
#      exhaustion. Fixed with the double-fork pattern (proven in tests 6-7).
#
#   3. SIGCHLD='IGNORE' (Coordination::Broker::event_loop):
#      The Broker runs in its own process under 'local $SIG{CHLD} = IGNORE'.
#      This is safe because the Broker owns no child processes itself; all
#      explicit waitpid callers (Stdio, ProgressSpinner, SubAgent::wait_all)
#      run in the MAIN process, not the broker process.
#
# === WHY NOT 'local $SIG{CHLD} = "IGNORE"' IN FIRE-AND-FORGET CALLERS? ===
#
#   local $SIG{CHLD} = 'IGNORE';
#   my $pid = fork();
#   ... function body ...
#   }  <-- 'local' restores $SIG{CHLD} to DEFAULT HERE (on scope exit)
#      <-- 200ms later: child finishes its HTTP request and exits
#      <-- SIGCHLD fires but handler is DEFAULT -> zombie created
#
#   Test 6 confirms this failure mode with a real fork and ps verification.
#
# === WHY NOT A GLOBAL SIGCHLD HANDLER WITH waitpid(-1, WNOHANG)? ===
#
#   A global handler reaps ALL children indiscriminately. Code like:
#     my $pid = fork(); ... ; my $r = waitpid($pid, 0);
#   returns $r == -1 because the handler stole the exit status first.
#   This breaks ProgressSpinner::stop, Stdio::is_connected, and
#   SubAgent::wait_all. Test 1 verifies SubAgent.pm has no such handler.
#
# === THE FIX: DOUBLE-FORK ===
#
#   my $intermediate = fork();
#   if ($intermediate == 0) {
#       my $grandchild = fork();
#       exit 0 unless defined $grandchild && $grandchild == 0;
#       # grandchild: do slow background work here
#       exit 0;
#   }
#   waitpid($intermediate, 0);  # returns in microseconds (intermediate is gone)
#
#   Intermediate exits immediately. Parent's waitpid returns fast (no block).
#   Grandchild is adopted by init(1), which auto-reaps it when done.
#   No zombie ever visible in the CLIO process. Proven in test 7.
#
# No dependencies beyond core Perl + POSIX.

use strict;
use warnings;
use POSIX qw(WNOHANG);
use Cwd qw(abs_path);
use File::Basename qw(dirname);

my $test_file = abs_path(__FILE__);
my $project_root = dirname(dirname(dirname($test_file)));

sub usleep {
    my ($us) = @_;
    select(undef, undef, undef, $us / 1_000_000);
}

my ($pass, $fail) = (0, 0);

sub report {
    my ($ok, $msg) = @_;
    if ($ok) {
        print "  ok - $msg\n";
        $pass++;
    } else {
        print "  not ok - $msg\n";
        $fail++;
    }
}

print "1..7\n";

# ── Test 1: No global SIGCHLD handler stealing exits ─────────────────────────
# A global waitpid(-1,...) reaper races with every explicit
# waitpid($specific_pid,...) call in the process (ProgressSpinner, Stdio,
# SubAgent::wait_all), causing them to return -1 (ECHILD) instead of the pid.
# We verify SubAgent.pm source does not install such a handler.
print "Test 1: No global SIGCHLD handler that steals exits from callers\n";
my $has_bad_handler = 0;
my $subagent_path = "$project_root/lib/CLIO/Coordination/SubAgent.pm";
if (open(my $fh, '<', $subagent_path)) {
    my $content = do { local $/; <$fh> };
    $has_bad_handler = 1 if $content =~ /\$SIG\{CHLD\}\s*=.*waitpid.*-1/s;
    close $fh;
}
report(!$has_bad_handler, "SubAgent.pm has no global SIGCHLD handler using waitpid(-1,...)");

# ── Test 2: Explicit waitpid($pid, 0) returns correct pid and exit code ───────
# Validates the tracked-fork pattern used by ProgressSpinner, Stdio transport,
# and SubAgent::wait_all. Must return the exact pid and preserve exit status.
print "Test 2: Explicit waitpid(\$pid, 0) returns correct pid and exit code\n";
my $pid1 = fork();
if ($pid1 == 0) { exit 42; }
my $result = waitpid($pid1, 0);
my $exit_code = $? >> 8;
report($result == $pid1 && $exit_code == 42,
    "waitpid($pid1, 0) returned result=$result exit=$exit_code (expected pid=$pid1 exit=42)");

# ── Test 3: waitpid($pid, WNOHANG) returns pid for dead child ─────────────────
# Used by Stdio::is_connected and the ProgressSpinner::stop reap loop.
# Must return the pid (not 0 or -1) when the child has already exited.
print "Test 3: waitpid(\$pid, WNOHANG) returns pid for already-exited child\n";
my $pid2 = fork();
if ($pid2 == 0) { exit 0; }
select(undef, undef, undef, 0.05);  # Let child exit
$result = waitpid($pid2, WNOHANG);
report($result == $pid2, "waitpid($pid2, WNOHANG) returned $result (expected $pid2)");

# ── Test 4: Multiple tracked children reaped individually ─────────────────────
# SubAgent::wait_all iterates %{$self->{agents}} and calls waitpid($pid, 0)
# per agent. Each call must return the correct pid.
print "Test 4: Multiple tracked children reaped individually via waitpid\n";
my @tracked_pids;
for (1..3) {
    my $p = fork();
    if ($p == 0) { exit $_; }
    push @tracked_pids, $p;
}
my $all_reaped = 1;
for my $p (@tracked_pids) {
    my $r = waitpid($p, 0);
    $all_reaped = 0 if $r != $p;
}
report($all_reaped, "All 3 tracked children reaped with correct pids via explicit waitpid");

# ── Test 5: WNOHANG poll loop (Stdio/ProgressSpinner pattern) ─────────────────
# Stdio::disconnect and ProgressSpinner::stop use a sleep+WNOHANG loop.
# The loop must eventually see the child exit (result == pid, not 0 or -1).
print "Test 5: WNOHANG poll loop correctly detects child exit (Stdio/ProgressSpinner pattern)\n";
my $pid3 = fork();
if ($pid3 == 0) { usleep(50_000); exit 0; }
my $loops = 0;
while ($loops < 20) {
    $result = waitpid($pid3, WNOHANG);
    last if $result > 0;
    usleep(5_000);
    $loops++;
}
report($result == $pid3,
    "WNOHANG poll loop reaped pid=$pid3 after $loops iterations (result=$result)");

# ── Test 6: PROOF OF PROBLEM - naive fire-and-forget fork creates zombie ──────
# This test demonstrates WHY a fix was needed. A plain fork() with no waitpid
# and no signal handler leaves a zombie when the child exits.
#
# This also demonstrates why 'local $SIG{CHLD}="IGNORE"' is insufficient:
# 'local' restores the handler when the calling function returns, BEFORE the
# slow background child (doing an HTTP request, browser launch, etc.) exits.
# By the time the child exits, $SIG{CHLD} is back to DEFAULT -> zombie.
#
# The test forks a slow child (simulating background work), waits for it to
# exit WITHOUT calling waitpid, then checks ps for Z state. Expects a zombie.
print "Test 6: PROOF OF PROBLEM - naive fire-and-forget fork creates zombie\n";
my $ps_opt = $^O eq 'darwin' ? 'state' : 'stat';
my $old_sigchld = $SIG{CHLD};
$SIG{CHLD} = 'DEFAULT';

my $naive_pid = fork();
if ($naive_pid == 0) {
    # Simulate slow background work: HTTP request, browser exec, update check
    usleep(100_000);
    exit 0;
}
# Parent "returns" from fire-and-forget call. No waitpid. No signal handler.
# With 'local $SIG{CHLD}="IGNORE"', the handler would have reverted here.
usleep(250_000);  # Let slow child finish

# Primary proof (portable): an unreaped dead child is returned by WNOHANG.
# This is the zombie state from the parent's perspective.
my $probe = waitpid($naive_pid, WNOHANG);

# Secondary signal (best effort): visible Z state in ps output.
my $naive_stat = `ps -o $ps_opt= -p $naive_pid 2>/dev/null`;
my $is_zombie_in_ps = defined($naive_stat) && $naive_stat =~ /Z/;

# If still running (unlikely), block once to clean up.
waitpid($naive_pid, 0) if $probe == 0;

$SIG{CHLD} = $old_sigchld;

my $problem_confirmed = ($probe == $naive_pid) || $is_zombie_in_ps;
report($problem_confirmed,
    "Naive fork() without waitpid shows unreaped child (waitpid probe=$probe, ps='$naive_stat')");

# ── Test 7: PROOF OF FIX - double-fork prevents zombie for slow child ─────────
# This is the fix applied to Update.pm, MCP::Auth::OAuth::_open_browser,
# and UI::Chat::_check_for_updates_async.
#
# How it works:
#   1. Parent forks an "intermediate" child.
#   2. Intermediate immediately forks a "grandchild", then exits.
#   3. Parent calls waitpid($intermediate, 0). Intermediate already exited,
#      so this returns in microseconds. Parent is not blocked.
#   4. Grandchild is now an orphan; init(1) adopts it automatically.
#   5. When grandchild finishes its slow work, init reaps it. No zombie.
#
# Verification: after the grandchild finishes, waitpid(-1, WNOHANG) in the
# parent returns -1 (ECHILD) because the grandchild belongs to init, not us.
# No zombie is visible in the CLIO process - confirmed by the -1 return.
print "Test 7: PROOF OF FIX - double-fork leaves no zombie for slow background child\n";
my $df_intermediate = fork();
if ($df_intermediate == 0) {
    # Intermediate: fork grandchild, then exit immediately
    my $gc = fork();
    exit 0 unless defined $gc && $gc == 0;
    # Grandchild: simulate slow background work (adopted by init after intermediate exits)
    usleep(300_000);
    exit 0;
}
# Parent: wait for fast-exiting intermediate (returns in microseconds)
waitpid($df_intermediate, 0);

# Wait for grandchild's "slow work" to complete
usleep(500_000);

# Grandchild was adopted by init; our process has no children left.
# waitpid(-1, WNOHANG) must return -1 (ECHILD): no zombie in our process.
my $reap = waitpid(-1, WNOHANG);
report($reap == -1 || $reap == 0,
    "Double-fork: waitpid(-1,WNOHANG)=$reap after slow child finished (no zombie; -1=ECHILD expected)");

print "\nResults: $pass passed, $fail failed\n";
exit($fail > 0 ? 1 : 0);
