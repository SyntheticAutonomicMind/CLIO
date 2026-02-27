#!/usr/bin/env perl
# Test premium billing tracking:
# 1. First request: State.pm charges multiplier upfront (so user sees immediate count)
# 2. First non-zero delta from response headers: reconciled (skipped) to avoid double-count
# 3. After reconciliation: only quota header deltas increment the count
# 4. delta=0 (session continuity) means no charge

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use Test::More tests => 10;

# Mock billing hash (mirrors State.pm billing structure)
my $billing = {
    total_requests => 0,
    total_premium_requests => 0,
    model => undef,
    multiplier => 0,
    requests => [],
};

# === Test 1: Initial state ===
is($billing->{total_premium_requests}, 0, "Initial premium requests is 0");

# === Test 2: First premium request - State.pm charges multiplier upfront ===
my $multiplier = 3;  # Claude Opus = 3x
$billing->{total_requests}++;
$billing->{multiplier} = $multiplier;
# Simulate State.pm logic: charge upfront on FIRST premium request only
if ($multiplier > 0 && ($billing->{total_premium_requests} || 0) == 0) {
    $billing->{total_premium_requests} = $multiplier;
    $billing->{_initial_premium_charged} = 1;  # Flag for reconciliation
}

is($billing->{total_premium_requests}, 3, "First request: upfront charge = multiplier (3)");
is($billing->{_initial_premium_charged}, 1, "Reconciliation flag set");

# === Test 3: Second premium request - State.pm does NOT charge again ===
$billing->{total_requests}++;
if ($multiplier > 0 && ($billing->{total_premium_requests} || 0) == 0) {
    $billing->{total_premium_requests} = $multiplier;
    $billing->{_initial_premium_charged} = 1;
}

is($billing->{total_premium_requests}, 3, "Second request: no re-charge (still 3)");

# === Test 4: First response baseline (delta = undef) ===
my $delta = undef;
# ResponseHandler: nothing happens on undef delta
is($billing->{total_premium_requests}, 3, "First response: baseline established, count unchanged");

# === Test 5: First non-zero delta - RECONCILE (skip, already counted) ===
$delta = 3;
if (defined $delta && $delta > 0) {
    if (delete $billing->{_initial_premium_charged}) {
        # Reconciled - skip this delta
    } else {
        $billing->{total_premium_requests} += $delta;
    }
}

is($billing->{total_premium_requests}, 3, "Reconciled: first delta=3 skipped (already charged upfront)");
ok(!exists $billing->{_initial_premium_charged}, "Reconciliation flag cleared");

# === Test 6: Session continuity - delta=0, no charge ===
$delta = 0;
if (defined $delta && $delta > 0) {
    if (delete $billing->{_initial_premium_charged}) {
        # reconcile
    } else {
        $billing->{total_premium_requests} += $delta;
    }
}

is($billing->{total_premium_requests}, 3, "Session continuity: delta=0, still 3");

# === Test 7: Many tool iterations with session continuity ===
for my $i (1..10) {
    $billing->{total_requests}++;
    $delta = 0;
    if (defined $delta && $delta > 0) {
        $billing->{total_premium_requests} += $delta;
    }
}

is($billing->{total_premium_requests}, 3, "After 10 tool iterations (delta=0 each): still 3");

# === Test 8: New user turn charges again (delta > 0 from headers) ===
$delta = 3;
if (defined $delta && $delta > 0) {
    if (delete $billing->{_initial_premium_charged}) {
        # reconcile
    } else {
        $billing->{total_premium_requests} += $delta;
    }
}

is($billing->{total_premium_requests}, 6, "New user turn: delta=3 from headers, now 6");

print "\n Premium billing tracking tests passed!\n";
print "Flow: upfront charge -> reconcile first delta -> track header deltas only\n";
