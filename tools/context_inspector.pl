#!/usr/bin/env perl
# Comprehensive context analysis tool. Inspects a session JSON to surface:
#  - message layout (positions, roles)
#  - presence/position of user_context, summary, system messages
#  - tool_result/user interleaving pattern
#  - token estimate per message
#  - simulated @messages array that would be sent to APIManager
#  - restart indicators in assistant messages
#  - repeated tool errors (loop detection)
#
# Use this to diagnose agent-restart and trim issues by looking at what
# the model sees at the start of each turn.

use strict;
use warnings;
use utf8;
use JSON::PP;
use File::Basename;
use File::Spec;
use Getopt::Long qw(GetOptions);

binmode(STDOUT, ":encoding(UTF-8)");
binmode(STDERR, ":encoding(UTF-8)");

my $session_file;
my $range;
my $summary_only = 0;
my $find_restarts = 0;
my $find_errors = 0;
my $show_all = 0;

GetOptions(
    "session=s" => \$session_file,
    "messages=s" => \$range,
    "summary" => \$summary_only,
    "restarts" => \$find_restarts,
    "errors" => \$find_errors,
    "all" => \$show_all,
) or die "Bad options. Try --help\n";

# Allow positional arg: perl tools/context_inspector.pl session.json
$session_file //= $ARGV[0];

die "Usage: $0 <session.json> [--messages=START-END] [--summary|--restarts|--errors]\n"
    unless $session_file;

unless (-f $session_file) {
    # Try relative to .clio/sessions/
    my $alt = File::Spec->catfile(".clio", "sessions", basename($session_file));
    if (-f $alt) {
        $session_file = $alt;
    } else {
        die "File not found: $session_file\n";
    }
}

open my $fh, "<", $session_file or die "Cannot open $session_file: $!\n";
local $/;
my $raw = <$fh>;
close $fh;
my $j = decode_json($raw);

# Header
print "=" x 78, "\n";
print "CONTEXT INSPECTOR\n";
print "=" x 78, "\n";
print "Session file: $session_file\n";
print "Session name: ", ($j->{session_name} // "<none>"), "\n";
print "Model: ", ($j->{selected_model} // "<unknown>"), "\n";
print "Created: ", scalar(localtime($j->{created_at} // 0)), "\n";
print "Max tokens: ", ($j->{max_tokens} // "<unknown>"), "\n";
print "Session goals: ", scalar(@{$j->{session_goals} || []}), "\n";
print "Input history entries: ", scalar(@{$j->{input_history} || []}), "\n";
print "last_api_payload size: ", scalar(@{$j->{last_api_payload} || []}), " messages\n";

my @hist = @{$j->{history}};
print "history size: ", scalar(@hist), " messages\n";
print "\n";

if ($find_restarts) {
    _find_restarts(\@hist);
    exit 0;
}

if ($find_errors) {
    _find_tool_errors(\@hist);
    exit 0;
}

# Role distribution
my %role_count;
for my $m (@hist) {
    $role_count{$m->{role} // '?'}++;
}
print "Role distribution:\n";
for my $r (sort keys %role_count) {
    print "  $r: $role_count{$r}\n";
}
print "\n";

# Categorize messages
my ($sys_count, $user_count, $asst_count, $tool_count) = (0, 0, 0, 0);
my ($sys_summary, $sys_user_ctx, $sys_trim_notif, $sys_other) = (0, 0, 0, 0);
my @user_indices;
my @tool_error_indices;
my @empty_assistant;
my @large_tool_msgs;
my @malformed_tool_calls;

for my $i (0..$#hist) {
    my $m = $hist[$i];
    my $role = $m->{role} // '?';
    my $content = $m->{content} // '';
    if ($role eq 'system') {
        $sys_count++;
        if ($content =~ /<thread_summary>/) { $sys_summary++ }
        elsif ($content =~ /^\[CONTEXT TRIM:/) { $sys_trim_notif++ }
        elsif (defined $content && $content =~ /<(?:userContext|dynamicContext|sessionGoals)[\s>]/) { $sys_user_ctx++ }
        else { $sys_other++ }
    } elsif ($role eq 'user') {
        $user_count++;
        push @user_indices, $i;
    } elsif ($role eq 'assistant') {
        $asst_count++;
        if (!defined $content || length($content) == 0) { push @empty_assistant, $i }
        if ($m->{tool_calls}) {
            for my $tc (@{$m->{tool_calls}}) {
                my $args = $tc->{function}{arguments} // '';
                my $name = $tc->{function}{name} // '?';
                if ($args =~ /<\/arg_key>/i || ($args ne '' && $args !~ /^\{/)) {
                    push @malformed_tool_calls, [$i, $name, $args];
                }
            }
        }
    } elsif ($role eq 'tool') {
        $tool_count++;
        if (defined $content && $content =~ /^TOOL ERROR/i) { push @tool_error_indices, $i }
        if (defined $content && length($content) > 3000) { push @large_tool_msgs, [$i, length($content)] }
    }
}

print "System messages: $sys_count\n";
print "  - thread_summary:    $sys_summary\n";
print "  - [CONTEXT TRIM:]:   $sys_trim_notif\n";
print "  - user_context:      $sys_user_ctx\n";
print "  - other (sysprompt): $sys_other\n";
print "User messages: $user_count\n";
print "Assistant messages: $asst_count\n";
print "Tool messages: $tool_count\n\n";

print "=== WARNINGS ===\n";
my $warn_count = 0;
if ($user_count == 0 && $sys_summary == 0) {
    print "  CRITICAL: No user messages and no thread_summary in history!\n";
    print "    Model has no anchor to the original task. Likely to 'start over'.\n";
    $warn_count++;
} elsif ($user_count == 0 && $sys_summary > 0) {
    print "  WARN: No user messages, but thread_summary is present.\n";
    print "    The summary preserves 'Current task:' - good. Model should anchor on that.\n";
    $warn_count++;
}

if (@tool_error_indices > 5) {
    print "  WARN: ", scalar(@tool_error_indices), " TOOL ERROR responses in history.\n";
    print "    If consecutive, the agent is stuck in an error loop. Bug B applies.\n";
    $warn_count++;
}

if (@empty_assistant > 5) {
    my $pct = sprintf("%.0f", 100 * scalar(@empty_assistant) / $asst_count);
    print "  WARN: ", scalar(@empty_assistant), " ($pct%) assistant messages have empty content.\n";
    print "    Model is generating tool calls without thinking text - may indicate confusion.\n";
    $warn_count++;
}

if (@malformed_tool_calls) {
    print "  CRITICAL: ", scalar(@malformed_tool_calls), " malformed tool calls detected!\n";
    print "    First few:\n";
    for my $m (@malformed_tool_calls) {
        last unless defined $m && defined $m->[0];
        print "      idx $m->[0]: $m->[1] - " . substr(($m->[2] // ''), 0, 100) . "\n";
        last if $m->[0] && $m == $malformed_tool_calls[-1];
    }
}

if ($warn_count == 0) {
    print "  No warnings. Session looks healthy.\n";
}
print "\n";

if ($summary_only) {
    exit 0;
}

# Show message details
my @indices;
if ($range && $range =~ /^(\d+)-(\d+)$/) {
    @indices = ($1..$2);
} else {
    @indices = (0..$#hist);
}

printf "%-5s %-10s %-8s %s\n", "IDX", "ROLE", "TOKENS", "PREVIEW";
print "-" x 78, "\n";

for my $i (@indices) {
    last if $i > $#hist;
    my $m = $hist[$i];
    my $role = $m->{role} // '?';
    my $content = $m->{content} // '';
    my $tokens = int(length($content) / 3);
    $tokens += 8 if $role eq 'tool';
    if ($m->{tool_calls}) {
        for my $tc (@{$m->{tool_calls}}) {
            $tokens += int(length($tc->{function}{arguments} // '') / 3);
        }
    }

    my $tag = '';
    if ($role eq 'system') {
        $tag = ($content // '') =~ /<thread_summary>/ ? " [SUMMARY]"
             : ($content // '') =~ /^\[CONTEXT TRIM:/ ? " [TRIM_NOTIF]"
             : ($content // '') =~ /<(?:userContext|dynamicContext|sessionGoals)[\s>]/ ? " [USER_CTX]"
             : " [SYS_PROMPT]";
    }
    if ($m->{tool_calls}) {
        $tag .= " [TOOLS=" . scalar(@{$m->{tool_calls}}) . "]";
    }

    my $preview = $content;
    $preview =~ s/\n/ /g;
    printf "%-5d %-10s %-8d%s\n    %s\n",
        $i, $role, $tokens, $tag,
        substr($preview, 0, 110) . (length($preview) > 110 ? "..." : "");
}

sub _find_restarts {
    my ($hist) = @_;
    print "=== Restart indicators ===\n";
    my $i = 0;
    my $found = 0;
    for my $m (@$hist) {
        next unless ($m->{role} // '') eq 'assistant';
        my $c = $m->{content} // '';
        if ($c =~ /\b(?:starting over|start(?:ing)? (?:over|fresh|anew)|as if the session was new|session is (?:new|fresh)|I lost (?:my )?context|I don.t have (?:any )?(?:context|prior conversation)|let me re-?(?:read|examine|study|look|investigate|establish)|re-?orient(?:ing)?)\b/i) {
            $found++;
            if ($found <= 10) {
                print "idx $i: " . substr($c, 0, 200) . "\n";
            }
        }
        $i++;
    }
    print "\nTotal restart indicators: $found\n";
}

sub _find_tool_errors {
    my ($hist) = @_;
    print "=== Tool errors (last 30) ===\n";
    my @err_idx;
    my $i = 0;
    for my $m (@$hist) {
        if (($m->{role} // '') eq 'tool' && ($m->{content} // '') =~ /^TOOL ERROR/i) {
            push @err_idx, $i;
        }
        $i++;
    }
    print "Total tool errors: ", scalar(@err_idx), "\n\n";
    for my $i (reverse @err_idx[0..29]) {
        my $m = $hist->[$i];
        my $c = $m->{content} // '';
        print "--- idx $i tool error ---\n";
        print substr($c, 0, 300) . "\n";
    }
}
