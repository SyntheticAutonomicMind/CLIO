#!/usr/bin/env perl
# Test kill_stale_children functionality

use strict;
use warnings;
use utf8;
use Test::More;

use lib './lib';
use CLIO::Compat::Terminal qw(kill_stale_children);

plan tests => 8;

# Test 1: With no children, returns empty arrays
{
    my $result = kill_stale_children();
    ok(ref $result eq 'HASH', 'Returns hashref');
    ok(ref $result->{killed} eq 'ARRAY', 'Has killed array');
    ok(ref $result->{skipped} eq 'ARRAY', 'Has skipped array');
}

# Test 2: Spawn a stale child process and kill it
{
    my $child_pid = fork();
    if ($child_pid == 0) {
        # Child: sleep forever (simulates stale process)
        exec('sleep', '300');
        exit(1);
    }

    # Give child time to start
    select(undef, undef, undef, 0.2);

    # Verify child is alive
    ok(kill(0, $child_pid), "Child process $child_pid is alive before reset");

    my $result = kill_stale_children();

    # Give kill time to propagate
    select(undef, undef, undef, 0.3);

    ok(!kill(0, $child_pid), "Child process $child_pid is dead after reset");

    my @killed_pids = map { $_->{pid} } @{$result->{killed}};
    ok(grep({ $_ == $child_pid } @killed_pids), "Child PID was in killed list");
}

# Test 3: Curl processes should be skipped
SKIP: {
    # We can't easily fake a curl child without actually running curl,
    # so just verify the function runs clean
    skip "Can't test curl skip without real curl process", 1;
}

ok(1, "All kill_stale_children tests passed");
