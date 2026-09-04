#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

# Dry-run trim on a session JSON at various budget levels.
# Reports what WOULD be dropped/kept at each budget without modifying
# the session file. Useful for testing trim priority changes against
# real sessions.
#
# Usage:
#   tools/trim_dryrun.pl <session.json>
#   tools/trim_dryrun.pl <session.json> --budgets=4000,8000,12000,16000

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
my $budgets = '4000,8000,12000,24000';
my $json_output = 0;

GetOptions(
    "session=s" => \$session_file,
    "budgets=s" => \$budgets,
    "json"      => \$json_output,
) or die "Bad options\n";

$session_file //= $ARGV[0];

die "Usage: $0 <session.json> [--budgets=N1,N2,...] [--json]\n"
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
my @msgs = @{$j->{last_api_payload} || []};
@msgs = @{$j->{history} || []} if !@msgs;

# Run trim at each budget
require CLIO::Core::API::MessageValidator;
require CLIO::Memory::TokenEstimator;

sub run_trim {
    my ($messages, $budget) = @_;
    my @trimmed = CLIO::Core::API::MessageValidator::validate_and_truncate(
        messages           => $messages,
        model_capabilities => { max_prompt_tokens => $budget * 2, max_output_tokens => 16000 },
        tools              => [],
        token_ratio        => 2.5,
        trim_threshold     => $budget,
        disable_post_trim_floor => 1,
    );

    my $input_count = scalar(@$messages);
    my $kept_count = scalar(@trimmed);
    my $dropped_count = $input_count - $kept_count;

    # Bucket the dropped messages
    my @dropped = @$messages;
    my %in_trimmed = map { $_ => 1 } @trimmed;
    my @dropped_msgs;
    for my $m (@$messages) {
        push @dropped_msgs, $m unless $in_trimmed{$m};
    }
    my %dropped_roles;
    for my $m (@dropped_msgs) {
        $dropped_roles{$m->{role} // '?'}++;
    }
    return {
        budget => $budget,
        input_count => $input_count,
        kept_count => $kept_count,
        dropped_count => $dropped_count,
        dropped_roles => \%dropped_roles,
        dropped_summary => $dropped_count > 0
            ? sprintf("%d msgs dropped (", $dropped_count)
              . join(", ", map { "$_=$dropped_roles{$_}" } sort keys %dropped_roles) . ")"
            : "0 msgs dropped",
    };
}

my @budget_list = split(/,/, $budgets);
my @results;
for my $b (@budget_list) {
    $b =~ s/^\s+|\s+$//g;
    push @results, run_trim(\@msgs, $b);
}

if ($json_output) {
    require JSON;
    print encode_json({ session => $session_file, results => \@results }), "\n";
    exit 0;
}

print "=" x 78, "\n";
print "TRIM DRYRUN - $session_file\n";
print "=" x 78, "\n";
print "Input messages: " . scalar(@msgs) . "\n";
print "\n";

print sprintf("%-12s  %8s  %8s  %8s  %s\n",
    'Budget', 'Input', 'Kept', 'Dropped', 'Detail');
print "-" x 78, "\n";
for my $r (@results) {
    printf "%-12d  %8d  %8d  %8d  %s\n",
        $r->{budget}, $r->{input_count}, $r->{kept_count},
        $r->{dropped_count}, $r->{dropped_summary};
}
print "\n";

print "Notes:\n";
print "  - 'Kept' is the number of messages the model would see.\n";
print "  - 'Dropped' is what would be archived into the thread_summary.\n";
print "  - The session file is NOT modified by this tool.\n";

exit 0;