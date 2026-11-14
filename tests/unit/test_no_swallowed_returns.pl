#!/usr/bin/env perl

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

=head1 NAME

test_no_swallowed_returns.pl - Assert every tool operation honours the result contract

=head1 DESCRIPTION

A `return` inside an `eval { }` block returns from the eval, not from the
enclosing subroutine (perlfunc). Code shaped like

    my $result;
    eval { ...; return $self->error_result(...) };
    return $result;

therefore hands the caller undef: the error result exits the eval and is
discarded, $@ is never set, and $result was never assigned. This was live in
read_file (interrupt path) and fetch_url (non-2xx path).

Rather than watch for that shape by eye, this test asserts the contract
directly: for every operation that does not mutate state or require a user,
execute() must return a defined hashref carrying a `success` key, for every
class of malformed or failing input. An undef return is a contract violation
regardless of how it was produced.

Also pins the two specific regressions.

=cut

use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use File::Temp qw(tempdir);
use File::Spec;
use Test2::V0;

use CLIO::Tools::FileOperations;
use CLIO::Tools::TerminalOperations;
use CLIO::Tools::CodeIntelligence;
use CLIO::Tools::VersionControl;
use CLIO::Tools::MemoryOperations;
use CLIO::Tools::TodoList;
use CLIO::Tools::WebOperations;
use CLIO::Tools::ApplyPatch;
use CLIO::Tools::SkillOperations;
use CLIO::Tools::RemoteExecution;

# Operations excluded from the sweep: they mutate external state, contact other
# hosts, or block waiting on a human. The contract still applies to them, but
# exercising them here would be slow or destructive rather than informative.
my %SKIP_OPS = map { $_ => 1 } qw(
    spawn kill killall send broadcast wait inbox report acknowledge
    commit push pull stash worktree
    execute_remote execute_parallel prepare_remote transfer_files retrieve_files
    cleanup_remote check_remote
    request_input
    write_file replace_string multi_replace_string insert_at_line
    delete_file rename_file create_directory
);

my $root = tempdir(CLEANUP => 1);

my %TOOLS = (
    file_operations       => CLIO::Tools::FileOperations->new(session_dir => $root),
    terminal_operations   => CLIO::Tools::TerminalOperations->new(),
    code_intelligence     => CLIO::Tools::CodeIntelligence->new(),
    version_control       => CLIO::Tools::VersionControl->new(),
    memory_operations     => CLIO::Tools::MemoryOperations->new(),
    todo_operations       => CLIO::Tools::TodoList->new(),
    web_operations        => CLIO::Tools::WebOperations->new(),
    apply_patch           => CLIO::Tools::ApplyPatch->new(session_dir => $root),
    skill_operations      => CLIO::Tools::SkillOperations->new(),
    remote_execution      => CLIO::Tools::RemoteExecution->new(),
);

my $ctx = { session => { id => 'contract-test' }, working_directory => $root };

# Input classes that must produce a well-formed error, never a crash or undef.
my @BAD_PARAMS = (
    { label => 'no params',            params => {} },
    { label => 'unknown extra param',  params => { zzz_unrelated => 'x' } },
    { label => 'arrayref everywhere',  params => { path => ['a'], query => ['b'], url => ['c'] } },
    { label => 'hashref everywhere',   params => { path => {},     query => {},     url => {} } },
    { label => 'empty strings',        params => { path => '',     query => '',     url => '' } },
    { label => 'missing required key', params => { nonexistent_required => 1 } },
);

my $checked = 0;
for my $tool_name (sort keys %TOOLS) {
    my $tool = $TOOLS{$tool_name};

    for my $op (@{ $tool->{supported_operations} || [] }) {
        next if $SKIP_OPS{$op};

        for my $bad (@BAD_PARAMS) {
            my $what = "$tool_name.$op [" . $bad->{label} . "]";
            my $result = $tool->execute({ operation => $op, %{ $bad->{params} } }, $ctx);

            ok(defined $result, "$what returned a result, not undef");

            if (defined $result) {
                is(ref $result, 'HASH', "$what returned a hashref");
                ok(exists $result->{success}, "$what result carries a 'success' key");
            }
            $checked++;
        }
    }
}

ok($checked >= 100, "swept a meaningful number of operation/input combinations ($checked)");

# ---------------------------------------------------------------------------
# Regression: read_file must report an interruption as an error, not undef.
# ---------------------------------------------------------------------------
subtest 'read_file reports interruption instead of returning undef' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $file = File::Spec->catfile($dir, 'large.txt');

    open my $fh, '>', $file or die "cannot seed fixture: $!";
    print $fh "content line $_\n" for 1 .. 25_000;
    close $fh;

    # Trip the interrupt after the first poll so it lands inside the read loop,
    # past the pre-read gate.
    my $calls = 0;
    my $guarded = CLIO::Tools::FileOperations->can('check_interrupt');
    {
        no warnings 'redefine';
        *CLIO::Tools::FileOperations::check_interrupt = sub { $calls++; return $calls > 1 };
    }

    my $fo = CLIO::Tools::FileOperations->new(session_dir => $dir);
    my $r  = $fo->execute({ operation => 'read_file', path => $file }, $ctx);

    {
        no warnings 'redefine';
        *CLIO::Tools::FileOperations::check_interrupt = $guarded;
    }

    ok(defined $r, 'read_file returned a result rather than undef');
    is($r->{success}, 0, 'interruption is reported as a failure');
    like($r->{error} // '', qr/Interrupted/, 'error says it was interrupted');
    like($r->{error} // '', qr/start_line=\d+/,
        'error keeps the resume hint that the eval used to swallow');
};

# ---------------------------------------------------------------------------
# Regression: fetch_url must report a non-2xx response, not return undef.
# HTTP::Tiny reports failures as a non-success response rather than dying, so
# $@ is empty and the error only reaches the caller via the eval's value.
# ---------------------------------------------------------------------------
subtest 'fetch_url reports HTTP failures instead of returning undef' => sub {
    my $w = CLIO::Tools::WebOperations->new();
    require CLIO::Compat::HTTP;

    for my $code (404, 429, 500) {
        my $guarded = CLIO::Compat::HTTP->can('get');
        {
            no warnings 'redefine';
            *CLIO::Compat::HTTP::get = sub {
                return bless {
                    status  => $code,
                    success => '',
                    reason  => "Simulated $code",
                    headers => {},
                    content => '',
                }, 'CLIO::Compat::HTTP::Response';
            };
        }

        my $r = $w->execute({ operation => 'fetch_url', url => 'http://example.invalid/x' }, $ctx);

        {
            no warnings 'redefine';
            *CLIO::Compat::HTTP::get = $guarded;
        }

        ok(defined $r, "HTTP $code returned a result rather than undef");
        is($r->{success}, 0, "HTTP $code is reported as a failure");
        ok(length($r->{error} // ''), "HTTP $code carries an error message");
    }
};

done_testing();
