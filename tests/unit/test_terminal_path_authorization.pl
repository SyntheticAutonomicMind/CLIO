#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test: shell commands are checked against path authorization.
#
# file_operations and apply_patch enforce the session directory, but an
# arbitrary command could route around them with a redirect, so the file guard
# alone did not bound where a command could write. Strict security level now
# checks the destinations a command names.
#
# The extractor reads only surface syntax and cannot see a path a script builds
# internally, so these tests cover what it does claim, not containment.

use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::RealBin/../../lib";

use Test::More;
use File::Temp qw(tempdir);
use CLIO::Security::CommandAnalyzer qw(extract_write_targets);
use CLIO::Tools::TerminalOperations;

# ── Destinations the extractor recognizes ──────────────────────────────────
{
    my %expected = (
        'echo hi > /etc/passwd'                 => ['/etc/passwd'],
        'echo hi >> out.txt'                    => ['out.txt'],
        'cat a | tee -a log.txt'                => ['log.txt'],
        'dd if=/dev/zero of=/dev/sda bs=1M'     => ['/dev/sda'],
        'cp /tmp/a /etc/b'                      => ['/etc/b'],
        'rm -rf /var/tmp/x'                     => ['/var/tmp/x'],
        'mkdir -p /opt/a/b'                     => ['/opt/a/b'],
        'touch /etc/x'                          => ['/etc/x'],
        'chmod 755 /opt/bin/run'                => ['/opt/bin/run'],
        'sed -i s/a/b/ file.txt'                => ['file.txt'],
        'echo hi 2> err.txt'                    => ['err.txt'],
        'echo t > /tmp/x && rm /tmp/y'          => ['/tmp/x', '/tmp/y'],
        'FOO=1 sudo -u root cp a b'             => ['b'],
        'nice -n 5 tee out.log'                 => ['out.log'],
    );

    for my $command (sort keys %expected) {
        is_deeply(extract_write_targets($command), $expected{$command},
            "targets extracted: $command");
    }
}

# ── Read-only and unknowable destinations produce nothing ──────────────────
{
    my @nothing = (
        'ls -la',
        'git status',
        'grep -rn foo lib/',
        'cat /etc/passwd',
        'sed s/a/b/ file.txt',            # no -i, no write
        'echo x > /dev/null',             # pseudo-file
        'echo x > $HOME/file',            # value unknown until run
        'echo x > /proc/self/comm',       # pseudo-filesystem
    );

    for my $command (@nothing) {
        is_deeply(extract_write_targets($command), [],
            "no targets claimed: $command");
    }
}

# ── The sed program is not mistaken for a file ────────────────────────────
{
    is_deeply(extract_write_targets('sed -i -e s/a/b/ f1 f2'), ['f1', 'f2'],
        'the -e program is dropped and both files kept');
    is_deeply(extract_write_targets('sed -i -f prog.sed f1'), ['f1'],
        'the -f script is dropped');
}

# ── Enforcement at strict level ───────────────────────────────────────────
{
    # Config stub: only security_level and sandbox are consulted here.
    package FakeConfig;
    sub new { my ($class, %a) = @_; return bless { %a }, $class }
    sub get {
        my ($self, $key) = @_;
        return $self->{security_level} if $key eq 'security_level';
        return $self->{sandbox}        if $key eq 'sandbox';
        return undef;
    }
    package main;

    my $session_dir = tempdir(CLEANUP => 1);
    my $outside     = tempdir(CLEANUP => 1);

    my $check = sub {
        my ($level, $command) = @_;
        my $tool = CLIO::Tools::TerminalOperations->new(debug => 0);
        $tool->{session_dir} = $session_dir;
        my $context = {
            config  => FakeConfig->new(security_level => $level),
            session => { session_id => 'probe' },
        };
        return $tool->validate_command({ command => $command }, $context);
    };

    ok(!$check->('strict', "echo x > $outside/file.txt")->{success},
        'strict: a write outside the session directory is refused');
    like($check->('strict', "echo x > $outside/file.txt")->{error},
        qr/outside the session directory/,
        'strict: the refusal names the reason');

    ok($check->('strict', "echo x > $session_dir/file.txt")->{success},
        'strict: a write inside the session directory is allowed');
    ok($check->('strict', 'ls -la')->{success},
        'strict: a read-only command is allowed');

    # Standard and relaxed keep their previous behaviour; only strict is new.
    ok($check->('standard', "echo x > $outside/file.txt")->{success},
        'standard: shell writes outside the session directory are unchanged');
    ok($check->('relaxed', "echo x > $outside/file.txt")->{success},
        'relaxed: shell writes outside the session directory are unchanged');
}

# ── No session directory means no containment to enforce ─────────────────
{
    my $tool = CLIO::Tools::TerminalOperations->new(debug => 0);
    delete $tool->{session_dir};
    my $result = eval {
        $tool->validate_command(
            { command => 'echo x > /tmp/whatever.txt' },
            { config => FakeConfig->new(security_level => 'strict'), session => { session_id => 'p' } },
        );
    };
    is($@, '', 'no session_dir does not die');
    ok($result->{success}, 'with no session_dir the command is not path-checked');
}

done_testing();
