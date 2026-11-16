#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

# Print the context budget record for a session.
#
# Every API request records one entry in the session's `context_stats`
# ring: the budget that was enforced, the token estimate by role, what
# the projection kept and archived, and the provider's reported usage.
# This tool renders that record so a question about context behavior can
# be answered from the session file instead of guessing.
#
# Usage:
#   tools/context_trace.pl <session.json>
#   tools/context_trace.pl <session.json> --last 5
#   tools/context_trace.pl <session.json> --json

use strict;
use warnings;
use utf8;
use JSON::PP;
use Getopt::Long qw(GetOptions);

binmode(STDOUT, ":encoding(UTF-8)");
binmode(STDERR, ":encoding(UTF-8)");

my $session_file;
my $last_n;
my $json_output = 0;

GetOptions(
    "session=s" => \$session_file,
    "last=i"    => \$last_n,
    "json"      => \$json_output,
) or die "Bad options\n";

$session_file //= $ARGV[0];
die "Usage: $0 <session.json> [--last N] [--json]\n" unless $session_file;
die "File not found: $session_file\n" unless -f $session_file;

open my $fh, '<:raw', $session_file or die "Cannot open $session_file: $!\n";
my $raw = do { local $/; <$fh> };
close $fh;

my $session = eval { decode_json($raw) };
die "Cannot parse $session_file: $@\n" if $@;

my $entries = $session->{context_stats};
unless (ref($entries) eq 'ARRAY' && @$entries) {
    print "No context_stats recorded in this session.\n";
    print "Entries are recorded per API request; a session that has not made a\n";
    print "request since this feature was added has none.\n";
    exit 0;
}

$entries = [ @$entries[ -$last_n .. -1 ] ] if $last_n && $last_n < @$entries;

if ($json_output) {
    print JSON::PP->new->canonical->pretty->encode($entries), "\n";
    exit 0;
}

sub k {
    my ($n) = @_;
    return '-' unless defined $n;
    return sprintf('%.1fM', $n / 1_000_000) if $n >= 1_000_000;
    return sprintf('%.0fK', $n / 1000) if $n >= 1000;
    return "$n";
}

print "=" x 110, "\n";
print "CONTEXT TRACE - $session_file\n";
print "=" x 110, "\n";
printf "%-19s %9s %9s %9s %8s %6s %7s %7s %7s\n",
    'time', 'model', 'est', 'limit', 'target', 'trim', 'dropped', 'tail', 'provider';
print "-" x 110, "\n";

for my $e (@$entries) {
    my $b = ref($e->{budget}) eq 'HASH' ? $e->{budget} : {};
    my $p = ref($e->{projection}) eq 'HASH' ? $e->{projection} : {};
    my $pre = ref($e->{pre_api_trim}) eq 'HASH' ? $e->{pre_api_trim} : {};

    my $prompt = $e->{usage_prompt_tokens} // 0;
    my $cached = $e->{usage_cached_tokens} // 0;
    my $hit = ($prompt && $cached) ? sprintf('%d%%', 100 * $cached / $prompt) : '-';

    printf "%-19s %9s %9s %9s %8s %6s %7s %7s %7s %5s\n",
        (scalar localtime($e->{timestamp} // 0)),
        k($b->{context_window}),
        k($b->{estimated_after}),
        k($b->{effective_limit}),
        k($b->{trim_target}),
        ($b->{trimmed} ? 'yes' : 'no'),
        (($p->{dropped_messages} // 0) + ($pre->{dropped_messages} // 0)),
        k(($p->{compressed_tail_chars} // 0) + ($pre->{thread_summary_chars} // 0)),
        k($prompt),
        $hit;
}

print "-" x 110, "\n";
print "Columns: model = context window, est = estimated prompt tokens,\n";
print "limit = effective limit, target = trim target, dropped = messages\n";
print "archived by the projection + pre-call trim, tail = characters of\n";
print "compressed summary, provider = prompt tokens the provider reported,\n";
print "hit = share of the prompt the provider served from its cache.\n";

my $last = $entries->[-1];
if (ref($last->{budget}{breakdown}) eq 'HASH') {
    my $bd = $last->{budget}{breakdown};
    print "\nCOMPOSITION OF THE LAST REQUEST\n";
    my $roles = ref($bd->{roles}) eq 'HASH' ? $bd->{roles} : {};
    for my $role (sort keys %$roles) {
        my $s = $roles->{$role};
        printf "  %-10s %6d messages  %10s total  (%s content, %s tool calls, %s reasoning)\n",
            $role, $s->{messages}, k($s->{total}),
            k($s->{content}), k($s->{tool_calls}), k($s->{reasoning});
    }
    printf "  %-10s %24s  (%s characters, %s tool-call characters)\n",
        'overhead', k($bd->{overhead}),
        k($bd->{content_chars}), k($bd->{tool_call_chars});
}

print "\n";
exit 0;
