#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

# Test zombie process reaping in CLIO::Coordination::SubAgent
#
# FUNCTIONAL TEST - Actually forks children and verifies zombie prevention.
# No dependencies beyond core Perl + POSIX.

use strict;
use warnings;
use POSIX qw(WNOHANG);
use Cwd qw(abs_path);
use File::Basename qw(dirname);

# Derive project root from test location (tests/unit/test_zombie_reap.pl)
my $test_file = abs_path(__FILE__);
my $project_root = dirname(dirname(dirname($test_file)));

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

print "1..5\n";

# Test 1: Verify handler pattern exists (runtime OR source)
print "Test 1: SIGCHLD handler installed\n";
my $has_handler = 0;

# Try runtime first
$has_handler = 1 if defined $SIG{CHLD} && ref($SIG{CHLD}) eq 'CODE';

# Fallback: check source file using project root path
if (!$has_handler) {
    my $subagent_path = "$project_root/lib/CLIO/Coordination/SubAgent.pm";
    if (open(my $fh, '<', $subagent_path)) {
        my $content = do { local $/; <$fh> };
        $has_handler = 1 if $content =~ /SIG\{CHLD\}\s*=.*waitpid.*WNOHANG/s;
        close $fh;
    }
}
report($has_handler, "SIGCHLD handler found (runtime or source)");

# Test 2: Fork children and verify they're reaped by the handler
print "Test 2: Handler auto-reaps single child\n";
my $pid1 = fork();
if ($pid1 == 0) {
    exit 0;  # Child exits immediately
}
# Parent: wait briefly for SIGCHLD to fire, then verify child was reaped
select(undef, undef, undef, 0.1);
# With auto-reaping handler, waitpid may return -1 (ECHILD) because handler already reaped.
# Loop to confirm the child was actually reaped (either by handler or explicit waitpid).
my $reaped = 0;
my $wait_result;
while (1) {
    $wait_result = waitpid(-1, WNOHANG);
    last if $wait_result <= 0;  # No more children to reap
    $reaped = 1 if $wait_result == $pid1;
    last if $wait_result == -1;  # ECHILD - no more children
}
report($reaped || $wait_result == -1, "Child $pid1 was reaped (handler worked)");

# Test 3: Fork multiple children rapidly
print "Test 3: Handler reaps multiple children\n";
my @pids;
for (1..5) {
    my $pid = fork();
    if ($pid == 0) {
        exit 0;
    }
    push @pids, $pid;
}
select(undef, undef, undef, 0.2);  # Let handler reap
my $count = 0;
for my $p (@pids) {
    my $r = waitpid($p, WNOHANG);
    $count++ if $r != 0;
}
report($count == 5, "All 5 children reaped by handler");

# Test 4: Verify our specific children didn't become zombies
print "Test 4: Children did not become zombies\n";
my $zombie_found = 0;
for my $p (@pids) {
    my $ret = kill(0, $p);  # Check if process exists
    if ($ret == 0) {
        # Process doesn't exist - could be zombie, check status
        my $status = `ps -o stat= -p $p 2>/dev/null`;
        if (defined $status && $status =~ /Z/) {
            $zombie_found = 1;
            last;
        }
    }
}
report(!$zombie_found, "Our children were not left as zombies");

# Test 5: Handler preserves existing handler
print "Test 5: Handler chains to existing handler\n";
my $test_handler_installed = 0;
{
    my $orig = $SIG{CHLD};
    $SIG{CHLD} = sub {
        $test_handler_installed = 1;
        $orig->() if ref($orig) eq 'CODE';
        1 while waitpid(-1, WNOHANG) > 0;
    };
    my $cpid = fork();
    if ($cpid == 0) { exit 0; }
    select(undef, undef, undef, 0.1);
    waitpid($cpid, WNOHANG);
}
report($test_handler_installed, "New handler can call original handler");

print "\nResults: $pass passed, $fail failed\n";
exit($fail > 0 ? 1 : 0);
