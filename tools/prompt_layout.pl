#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

# Visual tree view of a session's prompt layout with token counts per section.
# Shows the canonical 6-section layout:
#
#   [0] system_prompt      Static (built once per session; includes tools schema)
#   [1] context_files      User-added files (stable until /context add|remove)
#   [2] dialog             user / assistant alternating, tool_results interleaved
#   [3] summary            CSSS slot; regenerates within size budget, at END
#   [4] user_context       Dynamic (date/time, working dir, LTM, session goals)
#   [5] user_input         Current turn's raw user input (no prefix)
#
# Use this to see at a glance what the model sees at the start of a turn.
# For finer-grained diagnosis, use context_inspector.pl with --messages.

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

my $session_file;
my $model_class;
my $json_output = 0;

GetOptions(
    "session=s"    => \$session_file,
    "model-class=s"=> \$model_class,
    "json"         => \$json_output,
) or die "Bad options\n";

$session_file //= $ARGV[0];

die "Usage: $0 <session.json> [--model-class=XS|S|M|L|XL] [--json]\n"
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

# Walk the message array and bucket each into one of the 6 sections.
my @msgs = @{$j->{history} || []};
my @payload = @{$j->{last_api_payload} || []};

# Prefer last_api_payload (what the model actually saw) over history.
my @source = @payload ? @payload : @msgs;

my %buckets = (
    system_prompt     => { count => 0, tokens => 0, msgs => [] },
    context_files     => { count => 0, tokens => 0, msgs => [] },
    dialog            => { count => 0, tokens => 0, msgs => [] },
    summary           => { count => 0, tokens => 0, msgs => [] },
    user_context      => { count => 0, tokens => 0, msgs => [] },
    user_input        => { count => 0, tokens => 0, msgs => [] },
);

my $i = 0;
my $saw_summary = 0;
my $saw_user_context = 0;
for my $m (@source) {
    my $role = $m->{role} // '?';
    my $content = $m->{content} // '';
    my $tokens = estimate_tokens($content) + 4;
    $tokens += 8 if $role eq 'tool';

    my $bucket;
    if ($i == 0 && $role eq 'system') {
        # First message: system_prompt
        $bucket = 'system_prompt';
    } elsif ($role eq 'system' && $content =~ /<thread_summary>/) {
        $bucket = 'summary';
        $saw_summary = 1;
    } elsif ($role eq 'system' && $content =~ /^\s*<(?:userContext|dynamicContext|sessionGoals)/) {
        $bucket = 'user_context';
        $saw_user_context = 1;
    } elsif ($role eq 'system' && !$saw_summary) {
        # Pre-dialog system messages at position [1] = context_files
        $bucket = 'context_files';
    } elsif ($i == $#source && $role eq 'user') {
        # Last message: user_input
        $bucket = 'user_input';
    } else {
        # Anything else: dialog
        $bucket = 'dialog';
    }
    $buckets{$bucket}{count}++;
    $buckets{$bucket}{tokens} += $tokens;
    push @{$buckets{$bucket}{msgs}}, $i;
    $i++;
}

# Total tokens
my $total = 0;
$total += $buckets{$_}{tokens} for keys %buckets;

if ($json_output) {
    require CLIO::Core::ModelBudget;
    my $ctx = $j->{max_tokens} || 0;
    my $detected_class = $model_class
        || ($ctx ? CLIO::Core::ModelBudget::model_class($ctx) : undef);
    my %out = (
        session => $session_file,
        total_tokens => $total,
        sections => {},
        detected_model_class => $detected_class,
    );
    for my $b (keys %buckets) {
        $out{sections}{$b} = {
            count => $buckets{$b}{count},
            tokens => $buckets{$b}{tokens},
            pct_of_total => $total > 0 ? sprintf("%.1f", 100 * $buckets{$b}{tokens} / $total) : 0,
        };
    }
    print encode_json(\%out), "\n";
    exit 0;
}

# Tree-style display
print "=" x 78, "\n";
print "PROMPT LAYOUT - $session_file\n";
print "=" x 78, "\n";

if ($model_class) {
    require CLIO::Core::ModelBudget;
    print "Model class: $model_class\n";
} elsif ($j->{max_tokens}) {
    require CLIO::Core::ModelBudget;
    my $class = CLIO::Core::ModelBudget::model_class($j->{max_tokens});
    print "Model class (auto): $class (from max_tokens=$j->{max_tokens})\n";
}
print "\n";

print sprintf("%-18s  %6s  %8s  %6s\n", 'Section', 'Count', 'Tokens', '%');
print "-" x 78, "\n";
my @order = qw(system_prompt context_files dialog summary user_context user_input);
my $max_name_len = 16;
my $max_tokens = $total;
my $bar_width = 40;
for my $b (@order) {
    my $count = $buckets{$b}{count};
    my $tokens = $buckets{$b}{tokens};
    my $pct = $total > 0 ? sprintf("%.1f", 100 * $tokens / $total) : 0;
    my $bar = $total > 0 ? '#' x int(($tokens / $total) * $bar_width) : '';
    printf "%-18s  %6d  %8d  %5s%%  %s\n",
        $b, $count, $tokens, $pct, $bar;
}
print "-" x 78, "\n";
printf "%-18s  %6d  %8d  100.0%%\n", 'TOTAL', scalar(@source), $total;
print "\n";

# Context window breakdown
if ($j->{max_tokens}) {
    my $ctx = $j->{max_tokens};
    my $pct_of_ctx = $total > 0 ? sprintf("%.1f", 100 * $total / $ctx) : 0;
    print "Context window: $ctx tokens\n";
    print "Total payload: $total tokens ($pct_of_ctx% of context)\n";
    print "Headroom: " . ($ctx - $total) . " tokens\n";
    print "\n";
}

# Warnings
my @warnings;
push @warnings, "No system_prompt at position [0]" unless $buckets{system_prompt}{count} > 0;
push @warnings, "No user_input at last position" unless $buckets{user_input}{count} > 0;
push @warnings, "Multiple thread_summary instances" if $buckets{summary}{count} > 1;
push @warnings, "CSSS summary outside dialog but before user_context (would invalidate cache)"
    if $buckets{summary}{count} > 0 && $buckets{dialog}{count} == 0;
push @warnings, "context_files bucket has 0 entries (no /context added or all dropped)"
    if $buckets{context_files}{count} == 0;
push @warnings, "Dialog section is empty (no user/assistant/tool messages)"
    if $buckets{dialog}{count} == 0;

if (@warnings) {
    print "Warnings:\n";
    for my $w (@warnings) {
        print "  ! $w\n";
    }
    print "\n";
}

# Budget table comparison (XS-class sanity check)
if ($model_class && $model_class eq 'XS') {
    require CLIO::Core::ModelBudget;
    my $budget = CLIO::Core::ModelBudget::budget_for('XS');
    print "XS-class budget allocations:\n";
    for my $section (sort keys %$budget) {
        next if $section eq 'description';
        my $limit = $budget->{$section};
        my $actual = $buckets{$section}{tokens} // 0;
        my $status = '';
        if ($limit == 0 && $actual > 0) {
            $status = ' OVER LIMIT (XS should skip)';
        } elsif ($limit > 0 && $actual > $limit) {
            $status = ' OVER LIMIT';
        }
        printf "  %-18s budget=%-5s actual=%-8d%s\n",
            $section,
            ($limit == -1 ? 'unlimited' : $limit == 0 ? 'skip' : $limit),
            $actual,
            $status;
    }
    print "\n";
}

exit 0;