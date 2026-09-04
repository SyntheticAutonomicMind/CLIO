#!/usr/bin/env perl
# Parser for llama.cpp server log to analyze LCP cache hit patterns.
#
# Reads a llama.cpp server log and reports:
#   - LCP cache hit ratios (sim_best, f_keep) per request
#   - Token counts processed per request
#   - Anomalies (cache hits dropped, full reprocesses, etc.)
#
# Usage: perl tools/parse_llama_log.pl <logfile>

use strict;
use warnings;
use utf8;

my $log = $ARGV[0] or die "Usage: $0 <logfile>\n";

open my $fh, '<', $log or die "Cannot open $log: $!";

sub t2s {
    my $t = shift;
    my ($h, $m, $s, $ms) = split /\./, $t;
    return $h * 3600 + $m * 60 + $s + ($ms // 0) / 1000;
}

my @events;
my $current_task;
my %tasks;
my $last_prefix;
my $last_sim = 1.0;
my $last_fkeep = 1.0;

while (<$fh>) {
    chomp;
    if (/^(\d+\.\d+\.\d+\.\d+)\s+([IWED])\s+(\S+)\s+(.*)$/) {
        my ($time, $level, $cat, $msg) = ($1, $2, $3, $4);
        my $ts = t2s($time);

        if ($msg =~ /stable prefix=(\d+).*sim_best = ([\d.]+).*f_keep = ([\d.]+)/) {
            push @events, {time => $ts, time_str => $time, kind => 'lcp',
                prefix => $1, sim => $2, fkeep => $3, mode => 'LCP'};
            $last_prefix = $1; $last_sim = $2; $last_fkeep = $3;
        }
        elsif ($msg =~ /selected slot by LRU/) {
            push @events, {time => $ts, time_str => $time, kind => 'lcp',
                prefix => $last_prefix, sim => 0, fkeep => 0, mode => 'LRU'};
        }

        if ($msg =~ /launch_slot_.*task (\d+)/) {
            $current_task = $1;
            $tasks{$1}{start_time} = $ts;
            $tasks{$1}{start_str} = $time;
            $tasks{$1}{lcp_at_start} = $last_sim;
            $tasks{$1}{fkeep_at_start} = $last_fkeep;
            push @events, {time => $ts, time_str => $time, kind => 'launch', task => $1};
        }

        if ($msg =~ /release:.*task (\d+).*n_tokens = (\d+)/) {
            $tasks{$1}{end_time} = $ts;
            $tasks{$1}{end_str} = $time;
            $tasks{$1}{final_n_tokens} = $2;
            push @events, {time => $ts, time_str => $time, kind => 'release', task => $1, n_tokens => $2};
        }

        if ($msg =~ /task (\d+) \| prompt eval time =\s+([\d.]+) ms \/\s+(\d+) tokens \(/) {
            $tasks{$1}{prompt_eval_ms} = $2;
            $tasks{$1}{prompt_tokens} = $3;
        }
        if ($msg =~ /task (\d+) \|        eval time =\s+([\d.]+) ms \/\s+(\d+) tokens \(/) {
            $tasks{$1}{eval_ms} = $2;
            $tasks{$1}{eval_tokens} = $3;
        }
        if ($msg =~ /task (\d+) \|    graphs reused =\s+(\d+)/) {
            $tasks{$1}{graphs_reused} = $2;
        }
        if ($msg =~ /task (\d+) \| prompt processing, n_tokens =\s+(\d+), progress =/) {
            my $tk = $1; my $n = $2;
            $tasks{$tk}{processed_n_tokens} = $n if !exists $tasks{$tk}{processed_n_tokens} || $n > $tasks{$tk}{processed_n_tokens};
        }
        if ($msg =~ /task (\d+) \| n_decoded =\s+(\d+)/) {
            my $tk = $1; my $n = $2;
            $tasks{$tk}{decoded_tokens} = $n if !exists $tasks{$tk}{decoded_tokens} || $n > $tasks{$tk}{decoded_tokens};
        }

        if ($msg =~ /deferred_cre.*appended new slot at back/) {
            $current_task //= 0;
            $tasks{$current_task}{appended_slot} = 1;
        }
        if ($msg =~ /deferred_cre.*recycled and rewrote slot at back/) {
            $current_task //= 0;
            $tasks{$current_task}{recycled_slot} = 1;
        }
        if ($msg =~ /deferred_cre.*recycling front->back \(in place\)/) {
            $current_task //= 0;
            $tasks{$current_task}{recycled_inplace} = 1;
        }
    }
}
close $fh;

sub task_for_time {
    my $ts = shift;
    my $best_task;
    my $best_diff = 1e9;
    for my $tid (keys %tasks) {
        next unless defined $tasks{$tid}{start_time};
        next if $ts < $tasks{$tid}{start_time};
        my $diff = $ts - $tasks{$tid}{start_time};
        if ($diff < $best_diff) {
            $best_diff = $diff;
            $best_task = $tid;
        }
    }
    return $best_task;
}

print "=" x 110, "\n";
print "LLAMA.CPP SERVER LOG ANALYSIS: $log\n";
print "=" x 110, "\n";
print "Total LCP/release events: ", scalar(@events), "\n";
print "Total tasks:  ", scalar(keys %tasks), "\n\n";

print "-" x 110, "\n";
print "LCP CACHE HIT TIMELINE\n";
print "-" x 110, "\n";
printf "%-15s %-8s %-7s %-8s %-8s %-20s\n", "Time", "Task", "Mode", "Sim", "FKeep", "Note";
print "-" x 110, "\n";

my $prev_sim = 1.0;
my @anomalies;

for my $e (@events) {
    next if $e->{kind} ne 'lcp';
    my $task = task_for_time($e->{time});
    my $note = '';
    if ($e->{mode} eq 'LRU') {
        $note = '** NO LCP MATCH **';
        push @anomalies, sprintf("[%s] LRU (no LCP match) - task=%s", $e->{time_str}, ($task // '?'));
    } elsif ($e->{sim} < 0.95 && $prev_sim >= 0.95) {
        $note = '** SUDDEN DROP **';
        push @anomalies, sprintf("[%s] LCP sim dropped %.3f -> %.3f - task=%s", $e->{time_str}, $prev_sim, $e->{sim}, ($task // '?'));
    } elsif ($e->{sim} < 0.95) {
        $note = 'LOW';
    } elsif ($e->{sim} >= 0.99) {
        $note = 'PERFECT';
    } elsif ($e->{sim} >= 0.97) {
        $note = 'GOOD';
    }
    printf "%-15s %-8s %-7s %-8s %-8s %-20s\n",
        $e->{time_str}, ($task // '-'),
        $e->{mode}, sprintf("%.3f", $e->{sim}), sprintf("%.3f", $e->{fkeep}), $note;
    $prev_sim = $e->{sim};
}

print "\n";
print "-" x 110, "\n";
print "TASK SUMMARY (sorted by start time, last 30 entries)\n";
print "-" x 110, "\n";
printf "%-7s %-15s %-10s %-12s %-12s %-10s %-10s %-15s\n",
    "Task", "Start", "LCP_at_start", "ProcTokens", "FinalTokens", "EvalMs", "GraphsR", "Slot";
print "-" x 110, "\n";

my @task_list = sort { $tasks{$a}{start_time} <=> $tasks{$b}{start_time} } keys %tasks;
for my $tid (@task_list[-30 .. $#task_list]) {
    my $t = $tasks{$tid};
    my $slot = '-';
    $slot = 'NEW'   if $t->{appended_slot};
    $slot = 'RECYCLED' if $t->{recycled_slot};
    $slot = 'INPLACE'   if $t->{recycled_inplace};

    my $lcp = defined $t->{lcp_at_start} ? sprintf("%.3f", $t->{lcp_at_start}) : '-';
    printf "%-7s %-15s %-10s %-12s %-12s %-10s %-10s %-15s\n",
        $tid, $t->{start_str} // '-',
        $lcp,
        $t->{processed_n_tokens} // '-',
        $t->{final_n_tokens} // '-',
        $t->{prompt_eval_ms} // '-',
        $t->{graphs_reused} // '-',
        $slot;
}

print "\n";
print "=" x 110, "\n";
print "ANOMALIES DETECTED\n";
print "=" x 110, "\n";
if (@anomalies) {
    print "$_\n" for @anomalies;
} else {
    print "None.\n";
}

print "\n";
print "=" x 110, "\n";
print "FULL REPROCESS EVENTS (prompt processed > 50000 tokens)\n";
print "=" x 110, "\n";
my $found_reprocess = 0;
for my $tid (@task_list) {
    my $t = $tasks{$tid};
    if (defined $t->{processed_n_tokens} && $t->{processed_n_tokens} > 50000) {
        $found_reprocess++;
        printf "Task %s: processed %s tokens (FULL REPROCESS), LCP_at_start=%s, final_n=%s, eval_ms=%s\n",
            $tid, $t->{processed_n_tokens},
            (defined $t->{lcp_at_start} ? sprintf("%.3f", $t->{lcp_at_start}) : '-'),
            ($t->{final_n_tokens} // '-'),
            ($t->{prompt_eval_ms} // '-');
    }
}
print "Total full-reprocess events: $found_reprocess\n" if $found_reprocess;
