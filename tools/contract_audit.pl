#!/usr/bin/env perl

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

=head1 NAME

tools/contract_audit.pl - Compare operation contracts against handler behaviour

=head1 SYNOPSIS

    perl tools/contract_audit.pl
    perl tools/contract_audit.pl --verbose

=head1 DESCRIPTION

Calls every contracted operation with empty parameters and compares what the
handler complains about against what the contract declares required.

The failure this catches: a tool publishes a schema whose C<required> array
names nothing useful, so the model omits a parameter the handler cannot run
without. The model then sees "Missing required parameter: old_string", reads
guidance that describes C<old_string> as optional, retries with the same
payload, and the loop breaker ends the turn. Schemas that lie about their
requirements are not cosmetic - they are unretryable failures.

An operation may legitimately accept one of several parameter names. Those
declare C<any_of> in the contract and the probe treats any satisfied
alternative as correct.

Operations with destructive side effects are skipped: calling them with empty
parameters is not a safety guarantee worth betting on.

Exit code is the number of undeclared requirements found, so this can gate CI.

=cut

use strict;
use warnings;
use lib './lib';
use CLIO::Util::JSON qw(decode_json);

my @TOOLS = (
    ['CLIO::Tools::FileOperations',     { session_dir => '.' }],
    ['CLIO::Tools::VersionControl',     {}],
    ['CLIO::Tools::MemoryOperations',   {}],
    ['CLIO::Tools::TodoList',           {}],
    ['CLIO::Tools::WebOperations',      {}],
    ['CLIO::Tools::CodeIntelligence',   {}],
    ['CLIO::Tools::SkillOperations',    {}],
    ['CLIO::Tools::RemoteExecution',    {}],
    ['CLIO::Tools::SubAgentOperations', {}],
);

# Never probe these, even with empty params.
my %SKIP = map { $_ => 1 } qw(
    killall cleanup_remote prepare_remote transfer_files retrieve_files
);

my $problems = 0;

for my $entry (@TOOLS) {
    my ($module, $args) = @$entry;
    eval "require $module; 1" or do { warn "load $module: $@"; next };
    my $tool = $module->new(%$args);

    my $contract = $tool->operation_contract() || {};
    next unless keys %$contract;

    for my $op (sort keys %$contract) {
        next if $SKIP{$op};
        my $spec = $contract->{$op};
        my %declared = map { $_ => 1 } @{ $spec->{required} || [] };

        my $raw = eval { $tool->execute({ operation => $op }, {}) };
        if ($@) {
            printf "%-24s %-22s DIED: %s\n", $tool->{name}, $op, substr($@, 0, 80);
            next;
        }
        my $result = eval { ref($raw) eq 'HASH' ? $raw : decode_json($raw) };
        next unless $result && ref($result) eq 'HASH';
        next if $result->{success};

        my $error = $result->{error} || '';
        my @demanded;
        while ($error =~ /missing required parameter:?\s*['"`]?(\w+)/gi) { push @demanded, $1 }
        while ($error =~ /['"`](\w+)['"`]\s+(?:parameter\s+)?is required/gi) { push @demanded, $1 }
        while ($error =~ /requires\s+['"`](\w+)['"`]/gi) { push @demanded, $1 }

        my @undeclared = grep { !$declared{$_} } @{ dedupe(\@demanded) };

        # anyOf alternatives are declared requirements too: the handler naming
        # one of them is the contract working as intended.
        if (@undeclared && $spec->{any_of}) {
            my %demanded = map { $_ => 1 } @demanded;
            for my $alternative (@{ $spec->{any_of} }) {
                my %alt = map { $_ => 1 } @$alternative;
                next unless %alt;
                next if grep { !$alt{$_} } keys %demanded;
                @undeclared = ();
                last;
            }
        }

        if (@undeclared) {
            printf "%-24s %-22s handler demands undeclared: %s   | %s\n",
                $tool->{name}, $op, join(',', @undeclared), substr($error, 0, 90);
            $problems++;
        }
    }
}

print "\n$problems undeclared requirement(s) found\n";
exit($problems > 255 ? 255 : $problems);

sub dedupe {
    my ($list) = @_;
    my %seen;
    return [ grep { !$seen{$_}++ } @$list ];
}
