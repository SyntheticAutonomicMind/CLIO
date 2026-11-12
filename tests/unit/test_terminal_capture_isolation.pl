#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Tests that each command execution captures into storage of its own.
#
# Background: captured mode wrote command output to /tmp/clio_terminal_$$.log
# and passthrough used the same name on Unix. $$ is constant for the process
# and identical across threads, so every execution in a CLIO process shared one
# path, and each call began with `unlink $log_file`. Two consequences:
#
#   1. Concurrent executions - the orchestrator classifies tool calls as
#      parallel and runs them together - unlinked each other's file mid-flight.
#      The victim kept writing to the detached inode while its parent read an
#      empty or absent file, then reported success with the correct exit code
#      and no output at all.
#   2. Any other process able to guess the path could delete or pre-create it.
#      tests/unit/test_terminal_kill_safety.pl did exactly that, with
#      `unlink glob "/tmp/clio_terminal_*.log"`, which destroyed the capture
#      file of the very CLIO process running the suite.
#
# This test pins the replacement: a private 0700 directory per process and a
# unique file per execution, so neither failure can return.
#
# Run: perl -I./lib tests/unit/test_terminal_capture_isolation.pl
 
use strict;
use warnings;
use utf8;
use Config;
use File::Spec;
use Test::More;

use lib './lib';
use CLIO::Tools::TerminalOperations;

my $tool = CLIO::Tools::TerminalOperations->new();

# The storage helpers are internal; the concurrency assertion below is pure
# behaviour and runs either way. Skipping the structural subtests when they are
# absent lets this file report a behavioural failure against older code instead
# of aborting on an unknown method.
my $has_private_capture = $tool->can('_new_capture_file') ? 1 : 0;

# Strip the "[exit:N | Xms]" footer execute_command appends, so assertions are
# about what the command printed.
sub command_body {
    my ($result) = @_;
    my $out = $result->{output} // '';
    $out =~ s/\n*\[exit:[^\]]*\]\s*\z//s;
    $out =~ s/\s+\z//;
    return $out;
}

subtest 'sequential executions each return their own output' => sub {
    plan tests => 3;

    my $first  = $tool->execute_command({ command => 'echo FIRST_EXEC',  timeout => 30 }, {});
    my $second = $tool->execute_command({ command => 'echo SECOND_EXEC', timeout => 30 }, {});

    is(command_body($first),  'FIRST_EXEC',  'first execution captured its own output');
    is(command_body($second), 'SECOND_EXEC', 'second execution captured its own output');
    is($second->{exit_code}, 0, 'exit code reported');
};

subtest 'capture file is unique per execution' => sub {
    SKIP: {
        skip 'private capture allocation unavailable', 2 unless $has_private_capture;

        my @paths = map { $tool->_new_capture_file('out') } 1 .. 5;
        my %seen  = map { $_ => 1 } @paths;
        is(scalar(keys %seen), 5, 'five executions got five distinct capture files');

        my @missing = grep { !-e $_ } @paths;
        is(scalar(@missing), 0, 'every allocated capture file exists');
    }
};

subtest 'capture storage is a private directory, not a predictable tmp path' => sub {
    SKIP: {
        skip 'private capture directory unavailable', 4 unless $has_private_capture;

        my $dir = $tool->_capture_dir;
        ok(defined $dir && -d $dir, 'capture directory exists');

        my $mode = (stat($dir))[2] & 07777;
        is($mode, 0700, 'capture directory is mode 0700');

        # Capture files must not be scattered loose in the system temp
        # directory, where any other user's process could create or remove
        # them. Asserting on the directory itself keeps this independent of
        # what other CLIO processes happen to have in flight.
        isnt(File::Spec->canonpath($dir),
             File::Spec->canonpath(File::Spec->tmpdir),
             'capture directory is not the temp directory root');

        like($tool->_new_capture_file('out'),
             qr{^\Q$dir\E[\\/]out-},
             'capture files are allocated inside the private directory');
    }
};

subtest 'concurrent executions do not steal each other output' => sub {
    SKIP: {
        skip 'perl built without ithreads', 4 unless $Config{useithreads};

        require threads;
        require Time::HiRes;

        # A long execution in a thread, a short one from the main thread two
        # seconds later. Under the shared-path scheme the short call's unlink
        # removed the long call's capture file while it was still running.
        #
        # The thread returns a hashref: threads->create evaluates its sub in
        # scalar context, so `return ($x, $y)` collapses to the comma operator
        # and join hands back only the last element.
        my $long_thread = threads->create(sub {
            my $r = $tool->execute_command(
                { command => 'sleep 5; echo LONG_EXEC_DONE', timeout => 120 }, {});
            return { exit => $r->{exit_code}, body => command_body($r) };
        });

        Time::HiRes::sleep(2);
        my $short = $tool->execute_command({ command => 'echo SHORT_EXEC', timeout => 60 }, {});

        my $long = $long_thread->join;

        is($long->{body}, 'LONG_EXEC_DONE', 'long execution kept its output across concurrency');
        is($long->{exit}, 0,                'long execution exit code reported');
        is(command_body($short), 'SHORT_EXEC', 'short execution captured its own output');
        is($short->{exit_code}, 0,             'short execution exit code reported');
    }
};

done_testing();
