#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

# Aggregate statistics across all sessions in .clio/sessions/.
# Outputs:
#   - Total sessions, average messages per session
#   - Tool error rate (errors / total tool calls)
#   - Restart indicator frequency
#   - Trim event frequency
#   - Most common tool calls
#
# Use this for regression detection: "trim event rate up 20% this week"
# or "tool error rate climbing since the latest prompt update".

use strict;
use warnings;
use utf8;
use JSON::PP;
use File::Glob;
use File::Spec;
use Getopt::Long qw(GetOptions);

binmode(STDOUT, ":encoding(UTF-8)");
binmode(STDERR, ":encoding(UTF-8)");

my $dir = '.clio/sessions';
my $limit = 0;
my $json_output = 0;

GetOptions(
    "dir=s"   => \$dir,
    "limit=i" => \$limit,
    "json"    => \$json_output,
) or die "Bad options\n";

# Find session files (not session metadata subdirectories)
my @files = glob(File::Spec->catfile($dir, '*.json'));
@files = sort @files;
@files = @files[0..$limit-1] if $limit > 0 && scalar(@files) > $limit;

if (!@files) {
    die "No session files found in $dir\n";
}

my $total_messages = 0;
my $total_tool_calls = 0;
my $total_tool_errors = 0;
my $total_restarts = 0;
my $total_trims = 0;
my %tool_call_count;
my %error_pattern_count;
my %session_models;
my %session_tokens;
my %session_class;

# Detect trim events by scanning for "[CONTEXT TRIM:" markers in system messages.
# Detect restarts by looking for assistant messages starting with
# "OK" / "Got it" / "Let me try" / "I see" that immediately follow a
# tool_error burst (a heuristic, but a useful one).
sub detect_restarts {
    my ($msgs) = @_;
    my $restarts = 0;
    my $i = 0;
    while ($i < @$msgs - 1) {
        my $cur = $msgs->[$i];
        my $next = $msgs->[$i + 1];
        # Pattern: many tool_errors followed by an assistant message that
        # starts with a "starting over" indicator.
        if (($cur->{role} // '') eq 'tool' && ($cur->{content} // '') =~ /^TOOL ERROR/i
            && ($next->{role} // '') eq 'assistant') {
            my $content = $next->{content} // '';
            if ($content =~ /^(OK|Got it|Let me try|I see|Sure|Understood)/i) {
                $restarts++;
            }
        }
        $i++;
    }
    return $restarts;
}

for my $file (@files) {
    open my $fh, "<", $file or do {
        warn "Cannot open $file: $!\n";
        next;
    };
    local $/;
    my $raw = <$fh>;
    close $fh;
    my $j = eval { decode_json($raw); };
    unless ($j) {
        warn "Cannot parse $file: $@\n";
        next;
    }

    my @hist = @{$j->{history} || []};
    $total_messages += scalar(@hist);

    # Tool calls + errors
    my @msgs = @{$j->{last_api_payload} || []};
    @msgs = @hist if !@msgs;
    for my $m (@msgs) {
        if (($m->{role} // '') eq 'assistant' && $m->{tool_calls}) {
            for my $tc (@{$m->{tool_calls}}) {
                my $name = $tc->{function}{name} // 'unknown';
                $tool_call_count{$name}++;
                $total_tool_calls++;
            }
        }
        if (($m->{role} // '') eq 'tool' && ($m->{content} // '') =~ /^TOOL ERROR/i) {
            $total_tool_errors++;
            # Capture error pattern (first 60 chars)
            my $pattern = substr($m->{content}, 0, 60);
            $error_pattern_count{$pattern}++;
        }
        if (($m->{role} // '') eq 'system' && ($m->{content} // '') =~ /\[CONTEXT TRIM:/) {
            $total_trims++;
        }
    }

    my $restarts = detect_restarts(\@msgs);
    $total_restarts += $restarts;

    my $model = $j->{selected_model} // 'unknown';
    $session_models{$model}++;

    my $max = $j->{max_tokens} // 0;
    $session_tokens{$model} = $max if $max;
}

# Model class breakdown if max_tokens present
if (%session_tokens) {
    require CLIO::Core::ModelBudget;
    for my $model (keys %session_tokens) {
        my $ctx = $session_tokens{$model};
        my $class = CLIO::Core::ModelBudget::model_class($ctx);
        $session_class{$class}++;
    }
}

my $total_sessions = scalar(@files);
my $avg_messages = $total_sessions > 0 ? sprintf("%.1f", $total_messages / $total_sessions) : 0;
my $error_rate = $total_tool_calls > 0
    ? sprintf("%.1f%%", 100 * $total_tool_errors / $total_tool_calls)
    : '0%';
my $restart_rate = $total_messages > 0
    ? sprintf("%.2f%%", 100 * $total_restarts / $total_messages)
    : '0%';
my $trim_rate = $total_messages > 0
    ? sprintf("%.2f%%", 100 * $total_trims / $total_messages)
    : '0%';

if ($json_output) {
    require JSON;
    my %out = (
        total_sessions => $total_sessions,
        total_messages => $total_messages,
        avg_messages_per_session => $avg_messages,
        total_tool_calls => $total_tool_calls,
        total_tool_errors => $total_tool_errors,
        tool_error_rate => $error_rate,
        total_restart_indicators => $total_restarts,
        restart_rate => $restart_rate,
        total_trim_events => $total_trims,
        trim_rate => $trim_rate,
        tool_call_distribution => \%tool_call_count,
        error_pattern_distribution => \%error_pattern_count,
        session_models => \%session_models,
        session_class_distribution => \%session_class,
    );
    print encode_json(\%out), "\n";
    exit 0;
}

print "=" x 78, "\n";
print "SESSION STATS - $dir\n";
print "=" x 78, "\n";
print "Sessions analyzed: $total_sessions\n";
print "Total messages: $total_messages (avg $avg_messages/session)\n";
print "\n";
print "Tool calls: $total_tool_calls\n";
print "Tool errors: $total_tool_errors (rate: $error_rate)\n";
print "Trim events: $total_trims (rate: $trim_rate)\n";
print "Restart indicators: $total_restarts (rate: $restart_rate)\n";
print "\n";

if (%tool_call_count) {
    print "Tool call frequency:\n";
    for my $tool (sort { $tool_call_count{$b} <=> $tool_call_count{$a} } keys %tool_call_count) {
        printf "  %-30s  %5d\n", $tool, $tool_call_count{$tool};
    }
    print "\n";
}

if (%session_models) {
    print "Sessions by model:\n";
    for my $model (sort { $session_models{$b} <=> $session_models{$a} } keys %session_models) {
        my $ctx = $session_tokens{$model} // 0;
        printf "  %-40s  %5d  (ctx=%d)\n",
            $model, $session_models{$model}, $ctx;
    }
    print "\n";
}

if (%session_class) {
    print "Sessions by model class:\n";
    for my $class (qw/XS S M L XL/) {
        next unless $session_class{$class};
        printf "  %-3s  %5d\n", $class, $session_class{$class};
    }
    print "\n";
}

if (%error_pattern_count) {
    print "Top error patterns (first 60 chars):\n";
    my $i = 0;
    for my $pat (sort { $error_pattern_count{$b} <=> $error_pattern_count{$a} } keys %error_pattern_count) {
        last if $i++ >= 5;
        my $pat_clean = $pat;
        $pat_clean =~ s/\n/ /g;
        printf "  %3d  %s\n", $error_pattern_count{$pat}, $pat_clean;
    }
    print "\n";
}

exit 0;