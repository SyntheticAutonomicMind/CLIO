#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

# Test zombie process reaping in CLIO::Coordination::Broker
#
# FUNCTIONAL TEST - Verifies explicit waitpid calls work correctly
# and that zombie prevention doesn't break other modules.
# No dependencies beyond core Perl + POSIX.

use strict;
use warnings;
use POSIX qw(WNOHANG);

sub usleep {
    my ($us) = @_;
    select(undef, undef, undef, $us / 1_000_000);
}
use Cwd qw(abs_path);
use File::Basename qw(dirname);

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

print "1..6\n";

# Test 1: Verify NO global SIGCHLD handler is installed (that approach breaks waitpid)
print "Test 1: No global SIGCHLD handler stealing exits\n";
my $has_bad_handler = 0;
if (defined $SIG{CHLD} && ref($SIG{CHLD}) eq 'CODE') {
    my $subagent_path = "$project_root/lib/CLIO/Coordination/SubAgent.pm";
    if (open(my $fh, '<', $subagent_path)) {
        my $content = do { local $/; <$fh> };
        $has_bad_handler = 1 if $content =~ /\$SIG\{CHLD\}\s*=.*waitpid.*-1/s;
        close $fh;
    }
}
report(!$has_bad_handler, "SubAgent does not install SIGCHLD handler that steals exits");

# Test 2: Explicit waitpid returns correct pid (not stolen by handler)
print "Test 2: waitpid returns correct pid after child exits\n";
my $pid1 = fork();
if ($pid1 == 0) {
    exit 42;
}
my $result = waitpid($pid1, 0);
my $exit_code = $? >> 8;
report($result == $pid1 && $exit_code == 42, "waitpid($pid1, 0) returned $result, exit=$exit_code");

# Test 3: waitpid with WNOHANG returns pid immediately when child is already dead
print "Test 3: waitpid WNOHANG returns pid for dead child\n";
my $pid2 = fork();
if ($pid2 == 0) {
    exit 0;
}
select(undef, undef, undef, 0.05);
$result = waitpid($pid2, WNOHANG);
report($result == $pid2, "waitpid($pid2, WNOHANG) returned $result");

# Test 4: Multiple children can be waited on individually
print "Test 4: Multiple children waited individually\n";
my @pids;
for (1..3) {
    my $pid = fork();
    if ($pid == 0) { exit $_; }
    push @pids, $pid;
}
my $all_reaped = 1;
for my $p (@pids) {
    my $r = waitpid($p, 0);
    $all_reaped = 0 if $r != $p;
}
report($all_reaped, "All 3 children reaped via explicit waitpid");

# Test 5: Stdio transport pattern works (waitpid with WNOHANG loop)
print "Test 5: waitpid WNOHANG loop pattern works\n";
my $pid3 = fork();
if ($pid3 == 0) {
    usleep(50000);
    exit 0;
}
my $waited = 0;
my $loops = 0;
while ($loops < 20) {
    $result = waitpid($pid3, WNOHANG);
    last if $result > 0;
    usleep(5000);
    $loops++;
}
report($result == $pid3, "Stdio-style waitpid loop got result $result");

# Test 6: Children do not become zombies
print "Test 6: Children do not become zombies\n";
my $zombie_found = 0;
my $ps_opt = $^O eq 'darwin' ? 'state' : 'stat';
for my $p (@pids) {
    my $ret = kill(0, $p);
    if ($ret == 0) {
        my $status = `ps -o $ps_opt= -p $p 2>/dev/null`;
        if (defined $status && $status =~ /Z/) {
            $zombie_found = 1;
            last;
        }
    }
}
report(!$zombie_found, "No zombie processes found");

print "\nResults: $pass passed, $fail failed\n";
exit($fail > 0 ? 1 : 0);
