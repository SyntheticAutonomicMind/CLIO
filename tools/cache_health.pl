#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

# Per-turn LCP cache hit ratio estimator for a session.
#
# Uses the canonical 6-section layout (see docs/SPECS/PROMPT_PIPELINE.md)
# to model how each section's cache lifetime affects the cumulative
# cache hit. The model is a rough estimator, not a simulator - it's
# accurate enough to detect the regression pattern "every turn
# invalidates the cache" but not enough to predict exact provider
# behavior.
#
# Cache model:
#   [0] system_prompt      NEVER invalidated after session start
#   [1] context_files      Invalidated only on /context add|remove
#   [2] dialog+tools        Invalidated when units dropped from front
#                            (unit-based trim keeps byte positions)
#   [3] summary            Invalidated ONLY when CSSS slot content
#                            changes (CSSS locks to a constant size)
#   [4] user_context       Invalidated every minute (date ticks)
#   [5] user_input         Always fresh (per turn)
#
# The hit ratio is the cumulative bytes the model gets to reuse from
# cache (sections [0..4] prefix) divided by the total bytes that
# would have been processed without cache. Trim events and CSSS
# rotations degrade the cumulative hit.
#
# Usage:
#   tools/cache_health.pl <session.json>
#   tools/cache_health.pl <session.json> --json

use strict;
use warnings;
use utf8;
use JSON::PP;
use File::Basename;
use File::Spec;
use Getopt::Long qw(GetOptions);
use CLIO::Memory::TokenEstimator qw(estimate_tokens);

binmode(STDOUT, ":encoding(UTF-8)");
binmode(STDERR, ":encoding(UTF-8)");

my $session_file;
my $json_output = 0;

GetOptions(
    "session=s" => \$session_file,
    "json"      => \$json_output,
) or die "Bad options\n";

$session_file //= $ARGV[0];

die "Usage: $0 <session.json> [--json]\n"
    unless $session_file;

unless (-f $session_file) {
    my $alt = File::Spec->catfile(".clio", "sessions", basename($session_file));
    $session_file = $alt if -f $alt;
    die "File not found: $session_file\n" unless -f $session_file;
}

# Load session
open my $fh, "<", $session_file or die "Cannot open $session_file: $!\n";
local $/;
my $raw = <$fh>;
close $fh;
my $j = decode_json($raw);

# Build a synthetic sequence of "turns" from the session. We don't have
# per-turn snapshots in the session file (that's last_api_payload only),
# so we approximate by walking the history and detecting trim events
# ([CONTEXT TRIM:] markers).
my @hist = @{$j->{history} || []};
my @payload = @{$j->{last_api_payload} || []};

# Build the "turn sequence": for each segment between trim markers,
# compute the cumulative cache hit.
my @turns;
my $current_turn = {
    start_idx => 0,
    trim_events => 0,
    csss_rotations => 0,
    bytes_processed => 0,
    bytes_cached => 0,
};

sub bucket_message {
    my ($m, $idx) = @_;
    my $role = $m->{role} // '?';
    my $content = $m->{content} // '';
    return 'system_prompt' if $idx == 0 && $role eq 'system';
    return 'summary' if $role eq 'system' && $content =~ /<thread_summary>/;
    return 'user_context' if $role eq 'system'
        && $content =~ /^\s*<(?:userContext|dynamicContext|sessionGoals)/;
    return 'context_files' if $role eq 'system';
    return 'dialog';
}

sub turn_signature {
    my ($messages) = @_;
    # Canonical signature: hash of role + content for each message.
    # Used to detect structural changes between turns.
    require Digest::MD5;
    my $concat = '';
    for my $m (@$messages) {
        $concat .= ($m->{role} // '?') . ':'
            . substr($m->{content} // '', 0, 200) . "\n";
    }
    return Digest::MD5::md5_hex($concat);
}

# Walk history: detect [CONTEXT TRIM:] markers (split turns) and
# thread_summary size changes (CSSS rotations).
my $prev_summary_len = 0;
my $prev_sig = '';
my $turn_idx = 0;
$current_turn->{turn_idx} = $turn_idx;

for (my $i = 0; $i < @hist; $i++) {
    my $m = $hist[$i];
    my $role = $m->{role} // '?';
    my $content = $m->{content} // '';
    my $tokens = estimate_tokens($content) + 4;
    $tokens += 8 if $role eq 'tool';

    # Trim event marker splits turns
    if ($role eq 'system' && $content =~ /\[CONTEXT TRIM:/) {
        push @turns, $current_turn if $current_turn->{bytes_processed} > 0;
        $turn_idx++;
        $current_turn = {
            turn_idx => $turn_idx,
            start_idx => $i,
            trim_events => 0,
            csss_rotations => 0,
            bytes_processed => 0,
            bytes_cached => 0,
        };
        next;
    }

    # Track thread_summary size changes
    if ($role eq 'system' && $content =~ /<thread_summary>/) {
        if ($prev_summary_len > 0 && abs(length($content) - $prev_summary_len) > 100) {
            $current_turn->{csss_rotations}++;
        }
        $prev_summary_len = length($content);
    }

    # Allocate this message's tokens to the current turn's budget
    my $bucket = bucket_message($m, $i);
    $current_turn->{bytes_processed} += $tokens;

    # Cached portion depends on bucket
    my $cached = 0;
    if ($bucket eq 'system_prompt') {
        # First-turn: 0% cached. Subsequent: 100% cached (system_prompt
        # only changes on tool/skill changes which we don't track here).
        $cached = $turn_idx == 0 ? 0 : $tokens;
    } elsif ($bucket eq 'context_files') {
        $cached = $turn_idx == 0 ? 0 : $tokens;
    } elsif ($bucket eq 'dialog') {
        # Dialog is mostly cached on subsequent turns IF unit-based
        # trim kept the byte positions stable. With trim events this
        # turn, the cached portion drops.
        my $cache_ratio = $current_turn->{trim_events} > 0 ? 0.5 : 0.95;
        $cached = int($tokens * $cache_ratio);
    } elsif ($bucket eq 'summary') {
        # CSSS slot is always cached after lock (lock = same byte count).
        $cached = $current_turn->{csss_rotations} > 0 ? 0.5 : 0.98;
        $cached = int($tokens * $cached);
    } elsif ($bucket eq 'user_context') {
        # user_context invalidates every minute. Assume cache held
        # for the previous turn's tail (~50% of dialog lifespan).
        $cached = int($tokens * 0.5);
    }
    $current_turn->{bytes_cached} += $cached;
}
push @turns, $current_turn if $current_turn->{bytes_processed} > 0;

# Aggregate stats
my $total_processed = 0;
my $total_cached = 0;
my $total_trims = 0;
my $total_csss = 0;
for my $t (@turns) {
    $total_processed += $t->{bytes_processed};
    $total_cached += $t->{bytes_cached};
    $total_trims += $t->{trim_events};
    $total_csss += $t->{csss_rotations};
}

my $overall_ratio = $total_processed > 0
    ? sprintf("%.1f%%", 100 * $total_cached / $total_processed)
    : '0%';

if ($json_output) {
    require JSON;
    my %out = (
        session => $session_file,
        turns => scalar(@turns),
        total_processed_tokens => $total_processed,
        total_cached_tokens => $total_cached,
        overall_cache_hit_ratio => $overall_ratio,
        total_trim_events => $total_trims,
        total_csss_rotations => $total_csss,
        per_turn => [],
    );
    for my $t (@turns) {
        my $ratio = $t->{bytes_processed} > 0
            ? sprintf("%.1f%%", 100 * $t->{bytes_cached} / $t->{bytes_processed})
            : '0%';
        push @{$out{per_turn}}, {
            turn_idx => $t->{turn_idx},
            processed => $t->{bytes_processed},
            cached => $t->{bytes_cached},
            hit_ratio => $ratio,
            trim_events => $t->{trim_events},
            csss_rotations => $t->{csss_rotations},
        };
    }
    print encode_json(\%out), "\n";
    exit 0;
}

print "=" x 78, "\n";
print "CACHE HEALTH - $session_file\n";
print "=" x 78, "\n";
print "Turns: " . scalar(@turns) . "\n";
print "Total processed: $total_processed tokens\n";
print "Total cached: $total_cached tokens\n";
print "Overall hit ratio: $overall_ratio\n";
print "Trim events: $total_trims\n";
print "CSSS rotations: $total_csss\n";
print "\n";

print sprintf("%-8s  %10s  %10s  %8s  %6s  %6s\n",
    'Turn', 'Processed', 'Cached', 'Hit %', 'Trims', 'CSSS');
print "-" x 78, "\n";
for my $t (@turns) {
    my $ratio = $t->{bytes_processed} > 0
        ? sprintf("%.1f%%", 100 * $t->{bytes_cached} / $t->{bytes_processed})
        : '0%';
    printf "%-8d  %10d  %10d  %8s  %6d  %6d\n",
        $t->{turn_idx}, $t->{bytes_processed},
        $t->{bytes_cached}, $ratio,
        $t->{trim_events}, $t->{csss_rotations};
}
print "\n";

# Heuristic warnings
my @warnings;
if ($total_trims > scalar(@turns)) {
    push @warnings, "More trim events than turns ($total_trims trims / " . scalar(@turns) . " turns) - sessions thrashing";
}
if ($total_csss > scalar(@turns) / 2) {
    push @warnings, "CSSS rotating on more than half of turns ($total_csss rotations) - summary not stable";
}
for my $t (@turns) {
    my $ratio = $t->{bytes_processed} > 0
        ? 100 * $t->{bytes_cached} / $t->{bytes_processed}
        : 0;
    if ($ratio < 50) {
        push @warnings, sprintf("Turn %d: low hit ratio (%.0f%%) - structural change detected",
            $t->{turn_idx}, $ratio);
    }
}

if (@warnings) {
    print "Warnings:\n";
    for my $w (@warnings) {
        print "  ! $w\n";
    }
}

exit 0;