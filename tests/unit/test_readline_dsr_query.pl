#!/usr/bin/perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test: DSR (Device Status Report) cursor-position query.
#
# The readline input system queries the terminal for the current cursor
# position with ESC[6n before printing the prompt, so it knows the
# physical row where the input area starts. The terminal answers with
# ESC[row;colR on stdin.
#
# The bug this covers: the probe used to reject a valid intermediate
# state of the response. The response arrives one byte at a time, so the
# probe passes through "ESC[24;" before the column digits arrive. The
# old prefix pattern required digits after the ';', so the probe was
# rejected mid-response: the remaining bytes (including the terminating
# 'R') were pushed into the input queue and appeared as literal text in
# the user's input line ("[24;80R" prefixed whatever they typed).
#
# A second defect: the DSR request was written to stdout even when
# stdout was not a TTY. With output redirected (e.g. `clio | tee log`)
# the escape sequence landed in the captured output and no response ever
# arrived.

use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../lib";
use Test::More;

require CLIO::Core::ReadLine;

my $rl = CLIO::Core::ReadLine->new(prompt => '> ');

# --- Test 1: every prefix of a real DSR response must stay a prefix ---
{
    my $response = "\e[24;80R";
    my @rejected;
    for (my $i = 1; $i < length($response); $i++) {
        my $partial = substr($response, 0, $i);
        push @rejected, unpack('H*', $partial)
            unless $rl->_is_dsr_prefix($partial);
    }
    is(scalar(@rejected), 0,
       'every intermediate byte of ESC[24;80R is a valid DSR prefix')
        or diag('rejected prefixes: ' . join(', ', @rejected));
}

# --- Test 2: the specific state that used to break (semicolon, no digits) ---
{
    ok($rl->_is_dsr_prefix("\e[24;"),
       'ESC[24; (semicolon before column digits) is a valid DSR prefix');
    ok($rl->_is_dsr_prefix("\e[24;8"),
       'ESC[24;8 is a valid DSR prefix');
    ok($rl->_is_dsr_prefix("\e[24;80"),
       'ESC[24;80 is a valid DSR prefix');
}

# --- Test 3: bare ESC and ESC[ are valid prefixes ---
{
    ok($rl->_is_dsr_prefix("\e"),   'bare ESC is a valid DSR prefix');
    ok($rl->_is_dsr_prefix("\e["),  'ESC[ is a valid DSR prefix');
}

# --- Test 4: non-DSR escape sequences are still rejected as prefixes ---
{
    # An arrow key (ESC[A) must NOT be mistaken for a DSR prefix, so it
    # is pushed to the input queue for the escape-sequence handler.
    ok(!$rl->_is_dsr_prefix("\e[A"), 'arrow key ESC[A is not a DSR prefix');
    ok(!$rl->_is_dsr_prefix("\e[1;5C"), 'modified arrow ESC[1;5C is not a DSR prefix');
    ok(!$rl->_is_dsr_prefix("\e[200~"), 'bracketed paste start is not a DSR prefix');
    ok(!$rl->_is_dsr_prefix("hello"), 'plain text is not a DSR prefix');
    ok(!$rl->_is_dsr_prefix(''), 'empty string is not a DSR prefix');
}

# --- Test 5: the DSR request is not written to a non-TTY stdout ---
{
    # _query_cursor_pos must route the ESC[6n request to the terminal
    # rather than to stdout when stdout has been redirected.
    my $src = do {
        open(my $fh, '<', "$FindBin::Bin/../../lib/CLIO/Core/ReadLine.pm")
            or die "Cannot read ReadLine.pm: $!";
        local $/;
        <$fh>;
    };
    like($src, qr/open\(my \$tty, '>', '\/dev\/tty'\)/,
         'DSR request falls back to /dev/tty when stdout is not a TTY');
    like($src, qr/if \(-t STDOUT\) \{/,
         'DSR request is guarded by a stdout-TTY check');
}

# --- Test 6: sub-second deadline (time() has one-second granularity) ---
{
    # A deadline built from integer time() would extend the query window
    # to a full second instead of the intended fraction, making the
    # prompt appear late and stretching the drain window.
    my $src = do {
        open(my $fh, '<', "$FindBin::Bin/../../lib/CLIO/Core/ReadLine.pm")
            or die "Cannot read ReadLine.pm: $!";
        local $/;
        <$fh>;
    };
    like($src, qr/Time::HiRes::time\(\) \+ \$timeout/,
         'DSR deadline uses a sub-second clock');
    unlike($src, qr/my \$deadline = time\(\) \+ \$timeout;/,
           'DSR deadline does not use integer time()');
}

# --- Test 7: the type-ahead queue survives the DSR query ---
{
    # Characters typed before the prompt appears are captured by the DSR
    # query and queued for the readline loop. They must not be lost when
    # the loop drains the queue.
    push @{$rl->{_key_queue}}, ('h', 'e', 'l', 'l', 'o');
    my $drained = '';
    while (@{$rl->{_key_queue}}) {
        $drained .= shift @{$rl->{_key_queue}};
    }
    is($drained, 'hello', 'queued type-ahead characters drain in order');
}

done_testing();
