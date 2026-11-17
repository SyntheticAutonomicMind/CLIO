#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

=head1 NAME

test_consent_read_answer.pl - the one place an approval prompt is read

=head1 DESCRIPTION

Six approval sites each hand-rolled the same terminal dance, and the copies
drifted: one drained buffered keystrokes two at a time, one drained after the
read (eating the answer), one never flushed STDOUT before blocking, and one
restored the alarm handler on some paths but not others.
L<CLIO::Security::Consent/read_answer> now owns that sequence for all of them.

These tests pin the behaviour the call sites depend on: the prompt is printed
before anything is read, a buffered keystroke is drained without eating the
answer, the alarm handler and pending alarm are restored, the terminal leaves
cooked mode, and an unreadable STDIN denies rather than approves.

A source scan at the end keeps a new prompt from reintroducing the hand-rolled
sequence.

=cut

use strict;
use warnings;
use FindBin;
use lib "$FindBin::RealBin/../../lib";

use Test::More;
use File::Temp qw(tempfile);

use CLIO::Security::Consent;
use CLIO::Compat::Terminal;

# ---------------------------------------------------------------------------
# The real ReadKey reads STDIN and re-bimodes it; the real ReadMode is a no-op
# when STDIN is not a tty. Both are replaced for the duration of this file so
# the drain can be fed a known queue and the mode changes can be observed.
my @readkey_queue;
my @readkeys_taken;
my @mode_calls;
our @events;

# A spinner that records what happens to it, without a bless'd anonymous hash
# and glob juggling - those two interact badly at runtime.
package FakeSpinner;
our @calls;
sub stop  { push @calls, 'stop';  push @main::events, 'spinner:stop' }
sub start { push @calls, 'start'; push @main::events, 'spinner:start' }

package main;

my $orig_readkey = \&CLIO::Compat::Terminal::ReadKey;
my $orig_readmode = \&CLIO::Compat::Terminal::ReadMode;

{
    no warnings 'redefine';
    *CLIO::Compat::Terminal::ReadKey = sub {
        my ($timeout) = @_;
        push @events, 'readkey';
        return undef unless defined $timeout && $timeout == -1;
        my $key = shift @readkey_queue;
        push @readkeys_taken, $key if defined $key;
        return $key;
    };
    *CLIO::Compat::Terminal::ReadMode = sub {
        push @mode_calls, $_[0];
        push @events, "readmode:$_[0]";
        return 1;
    };
}

END {
    no warnings 'redefine';
    *CLIO::Compat::Terminal::ReadKey  = $orig_readkey;
    *CLIO::Compat::Terminal::ReadMode = $orig_readmode;
}

# Run read_answer with a fake STDIN holding $input.
sub run_prompt {
    my (%args) = @_;
    my $input = delete $args{stdin};
    $input = defined $input ? $input : "\n";

    @FakeSpinner::calls = ();
    my $spinner = bless {}, 'FakeSpinner';

    my $decision;
    {
        local *STDIN;
        open STDIN, '<', \$input or die "Cannot fake stdin: $!";
        $decision = CLIO::Security::Consent::read_answer(
            spinner  => $spinner,
            prompt   => sub { push @events, 'prompt' },
            caller   => 'TestConsent',
            drain    => defined $args{drain} ? $args{drain} : 1,
            grantable => defined $args{grantable} ? $args{grantable} : 1,
        );
    }

    return ($decision, [ @FakeSpinner::calls ]);
}

sub reset_state {
    @readkey_queue = ();
    @readkeys_taken = ();
    @mode_calls = ();
    @events = ();
}

# ---------------------------------------------------------------------------
subtest 'answer classification' => sub {
    for my $case (
        [ "o\n", 'once' ],
        [ "a\n", 'all'  ],
        [ "n\n", 'deny' ],
        [ "\n", 'deny'  ],
        [ "  A  \n", 'all' ],
    ) {
        my ($input, $expected) = @$case;
        reset_state();
        my ($decision) = run_prompt(stdin => $input);
        (my $label = $input) =~ s/\s+$//;
        $label = '(empty)' unless length $label;
        is($decision, $expected, "'$label' -> $expected");
    }

    reset_state();
    my ($ungrantable) = run_prompt(stdin => "a\n", grantable => 0);
    is($ungrantable, 'once', '(a) on an ungrantable concern is approved once only');
};

# ---------------------------------------------------------------------------
subtest 'spinner is stopped for the prompt and restarted after' => sub {
    reset_state();
    my (undef, $calls) = run_prompt(stdin => "o\n");
    is_deeply($calls, ['stop', 'start'], 'stop before, start after');

    my @order;
    for my $event (@events) {
        next unless $event =~ /^(?:spinner:(?:stop|start)|prompt|readkey|readmode:\d)$/;
        push @order, $event;
    }
    is_deeply(\@order,
        [ 'spinner:stop', 'readmode:0', 'readkey', 'prompt', 'readmode:1', 'spinner:start' ],
        'stop -> cooked -> drain -> prompt -> cooked-mode restore -> spinner start')
        or diag(join(' | ', @events));

    # The drain has to run while the prompt is still invisible. Anything typed
    # at a visible prompt lands in the same buffer, so draining after printing
    # would discard an answer typed the instant the prompt appeared.
    my ($drain_at) = grep { $events[$_] eq 'readkey' } 0 .. $#events;
    my ($prompt_at) = grep { $events[$_] eq 'prompt' } 0 .. $#events;
    cmp_ok($drain_at, '<', $prompt_at,
        'the drain runs before the prompt is printed, so it cannot eat an answer');
};

# ---------------------------------------------------------------------------
subtest 'a buffered keystroke is drained without eating the answer' => sub {
    # Two junk bytes left over from the spinner's cbreak polling. The drain
    # must consume them, then <STDIN> must still see the answer. The old loop
    # in WebOperations read two bytes per iteration and could take the answer
    # with it.
    reset_state();
    @readkey_queue = ('j', 'k');
    my ($decision) = run_prompt(stdin => "a\n");
    is($decision, 'all', 'answer survived the drain');
    is_deeply(\@readkeys_taken, [ 'j', 'k' ], 'drain consumed exactly the buffered keys');

    # A queue that ends on the answer's first byte: the drain stops at the
    # first undef and never touches the line.
    reset_state();
    @readkey_queue = ('j');
    ($decision) = run_prompt(stdin => "n\n");
    is($decision, 'deny', 'deny survived a one-byte drain');
    is_deeply(\@readkeys_taken, ['j'], 'drain stopped at the end of the buffer');
};

# ---------------------------------------------------------------------------
subtest 'alarm handler and pending alarm are restored' => sub {
    reset_state();
    my $handler = sub { };
    my $fired_back;

    {
        local $SIG{ALRM} = $handler;
        alarm(30);
        run_prompt(stdin => "o\n");
        $fired_back = alarm(0);   # cancels and reports what was left
    }

    cmp_ok($fired_back, '>', 25, "pending alarm restored (${fired_back}s of 30 left)")
        unless !defined $fired_back;
};

# ---------------------------------------------------------------------------
subtest 'terminal mode returns to cooked-then-restore' => sub {
    reset_state();
    run_prompt(stdin => "o\n");
    is_deeply(\@mode_calls, [ 0, 1 ], 'cooked for the read, restored after');
};

# ---------------------------------------------------------------------------
subtest 'an unreadable STDIN denies' => sub {
    reset_state();
    my ($decision) = run_prompt(stdin => '');   # immediate EOF
    is($decision, 'deny', 'EOF denies, never approves');
};

# ---------------------------------------------------------------------------
subtest 'prompt may be omitted when the caller already printed' => sub {
    reset_state();
    my $decision;
    my $line = "a\n";
    {
        local *STDIN;
        open STDIN, '<', \$line or die $!;
        $decision = CLIO::Security::Consent::read_answer(caller => 'TestConsent');
    }
    is($decision, 'all', 'reads and classifies with no prompt callback');
};

# ---------------------------------------------------------------------------
# The point of the shared reader is that nobody writes the sequence again.
# A prompt site may print its own prompt and call read_answer; it may not call
# ReadMode/ReadKey and read STDIN itself.
subtest 'no prompt site hand-rolls the terminal dance' => sub {
    my $lib = "$FindBin::RealBin/../../lib";
    my @files = (
        "$lib/CLIO/Tools/TerminalOperations.pm",
        "$lib/CLIO/Tools/FileOperations.pm",
        "$lib/CLIO/Tools/WebOperations.pm",
        "$lib/CLIO/Security/PathAuthorizer.pm",
        "$lib/CLIO/UI/Chat/Security.pm",
    );

    my @offenders;
    for my $file (@files) {
        open my $fh, '<:encoding(UTF-8)', $file or die "Cannot read $file: $!";
        my @lines = <$fh>;
        close $fh;

        my $uses_shared_reader = 0;
        my $line_no = 0;
        for my $line (@lines) {
            $line_no++;
            $uses_shared_reader = 1 if $line =~ /Consent::read_answer/;
            next if $line =~ /^\s*#/;
            # Reading STDIN is how an answer gets taken, so it is the one thing
            # that cannot appear outside the shared reader. Command execution
            # legitimately uses ReadMode and $SIG{ALRM} for its own timeout and
            # terminal suspend, so those are not flagged here.
            push @offenders, "$file:$line_no reads STDIN outside the shared reader"
                if $line =~ /<\s*STDIN\s*>/;
        }

        push @offenders, "$file never calls Consent::read_answer"
            unless $uses_shared_reader;
    }

    is_deeply(\@offenders, [], 'every prompt goes through Consent::read_answer')
        or diag(join("\n", @offenders));
};

done_testing();
