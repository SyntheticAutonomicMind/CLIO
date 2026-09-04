#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

# Diff two session JSONs (or a session and its last_api_payload). Outputs:
#   - Added/removed messages
#   - LCP cache impact estimate
#   - thread_summary content delta
#   - Tool calls added since last snapshot
#
# Use this to debug LCP cache collapse by comparing what changed between
# two payloads. If the diff shows structural reordering (deinterleave/
# reinterleave cycle), the cache hash will diverge.

use strict;
use warnings;
use utf8;
use JSON::PP;
use File::Basename;
use File::Spec;
use Getopt::Long qw(GetOptions);
use CLIO::Memory::TokenEstimator qw(estimate_tokens);
require CLIO::Memory::TokenEstimator;

binmode(STDOUT, ":encoding(UTF-8)");
binmode(STDERR, ":encoding(UTF-8)");

my $file_a;
my $file_b;

GetOptions(
    "a=s" => \$file_a,
    "b=s" => \$file_b,
) or die "Bad options\n";

# Positional args: $0 session_a.json session_b.json
$file_a //= $ARGV[0];
$file_b //= $ARGV[1];

die "Usage: $0 <session_a.json> <session_b.json>\n"
    unless $file_a && $file_b;

for my $f ($file_a, $file_b) {
    unless (-f $f) {
        my $alt = File::Spec->catfile(".clio", "sessions", basename($f));
        if (-f $alt) {
            $f eq $file_a ? ($file_a = $alt) : ($file_b = $alt);
        } else {
            die "File not found: $f\n";
        }
    }
}

sub load_payload {
    my ($file) = @_;
    open my $fh, "<", $file or die "Cannot open $file: $!\n";
    local $/;
    my $raw = <$fh>;
    close $fh;
    my $j = decode_json($raw);
    # Prefer last_api_payload (what was sent to the model).
    my @payload = @{$j->{last_api_payload} || []};
    return @payload if @payload;
    return @{$j->{history} || []};
}

my @a = load_payload($file_a);
my @b = load_payload($file_b);

# Build canonical content signatures for diff
sub sig {
    my ($m) = @_;
    my $content = $m->{content} // '';
    return join("|",
        $m->{role} // '?',
        $m->{tool_call_id} // '',
        $m->{name} // '',
        substr($content, 0, 200),
    );
}

my %a_set = map { sig($_) => $_ } @a;
my %b_set = map { sig($_) => $_ } @b;

my @added;
my @removed;
my @common;

for my $s (keys %a_set) {
    if (exists $b_set{$s}) {
        push @common, $a_set{$s};
    } else {
        push @removed, $a_set{$s};
    }
}
for my $s (keys %b_set) {
    unless (exists $a_set{$s}) {
        push @added, $b_set{$s};
    }
}

# Token impact
my $removed_tokens = 0;
for my $m (@removed) {
    $removed_tokens += estimate_tokens($m->{content} // '');
}
my $added_tokens = 0;
for my $m (@added) {
    $added_tokens += estimate_tokens($m->{content} // '');
}

print "=" x 78, "\n";
print "PROMPT DIFF\n";
print "=" x 78, "\n";
print "A: $file_a (" . scalar(@a) . " messages)\n";
print "B: $file_b (" . scalar(@b) . " messages)\n";
print "\n";
print "Common: " . scalar(@common) . "\n";
print "Added (in B, not in A): " . scalar(@added) . " (+$added_tokens tokens)\n";
print "Removed (in A, not in B): " . scalar(@removed) . " (-$removed_tokens tokens)\n";
print "\n";

# Cache impact estimate
my $total_b = 0;
for my $m (@b) {
    $total_b += estimate_tokens($m->{content} // '');
}
my $delta_pct = $total_b > 0 ? sprintf("%.1f", 100 * ($added_tokens + $removed_tokens) / $total_b) : 0;
print "Cache impact (rough estimate):\n";
print "  Total B tokens: $total_b\n";
print "  Changed tokens: " . ($added_tokens + $removed_tokens) . " ($delta_pct% of B)\n";
print "  Note: structural reordering (deinterleave/reinterleave cycle) changes\n";
print "  byte positions even when content is the same, breaking the LCP cache hash.\n";
print "\n";

if (@added) {
    print "Added messages:\n";
    for my $m (@added) {
        my $preview = substr($m->{content} // '', 0, 80);
        $preview =~ s/\n/ /g;
        printf "  + [%s] %s\n",
            $m->{role} // '?',
            $preview;
    }
    print "\n";
}

if (@removed) {
    print "Removed messages:\n";
    for my $m (@removed) {
        my $preview = substr($m->{content} // '', 0, 80);
        $preview =~ s/\n/ /g;
        printf "  - [%s] %s\n",
            $m->{role} // '?',
            $preview;
    }
    print "\n";
}

# Summary delta
my $summary_a = '';
my $summary_b = '';
for my $m (@a) {
    if (($m->{role} // '') eq 'system' && ($m->{content} // '') =~ /<thread_summary>/) {
        $summary_a = $m->{content};
    }
}
for my $m (@b) {
    if (($m->{role} // '') eq 'system' && ($m->{content} // '') =~ /<thread_summary>/) {
        $summary_b = $m->{content};
    }
}
if ($summary_a || $summary_b) {
    print "Thread summary delta:\n";
    if ($summary_a && !$summary_b) {
        print "  A had summary, B doesn't.\n";
    } elsif (!$summary_a && $summary_b) {
        print "  B has summary, A didn't.\n";
    } else {
        my $a_tokens = estimate_tokens($summary_a);
        my $b_tokens = estimate_tokens($summary_b);
        my $delta = $b_tokens - $a_tokens;
        print "  A: $a_tokens tokens\n";
        print "  B: $b_tokens tokens\n";
        print "  Delta: " . ($delta >= 0 ? "+$delta" : $delta) . " tokens\n";
    }
    print "\n";
}

# Tool calls delta
my %tc_a;
my %tc_b;
for my $m (@a) {
    if (($m->{role} // '') eq 'assistant' && $m->{tool_calls}) {
        for my $tc (@{$m->{tool_calls}}) {
            $tc_a{$tc->{id}} = $tc if $tc->{id};
        }
    }
}
for my $m (@b) {
    if (($m->{role} // '') eq 'assistant' && $m->{tool_calls}) {
        for my $tc (@{$m->{tool_calls}}) {
            $tc_b{$tc->{id}} = $tc if $tc->{id};
        }
    }
}
my @tc_added = grep { !exists $tc_a{$_} } keys %tc_b;
my @tc_removed = grep { !exists $tc_b{$_} } keys %tc_a;
if (@tc_added || @tc_removed) {
    print "Tool call delta:\n";
    print "  Added: " . scalar(@tc_added) . "\n";
    print "  Removed: " . scalar(@tc_removed) . "\n";
    print "\n";
}

exit 0;