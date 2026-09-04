#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test: dynamic userContext components must be capped
# so they cannot balloon the prompt budget on iteration 1
# (where no proactive trim runs).
#
# Bug (SMELL #5 in QA review 2026-09-02): 200 todos x 500 chars
# produced ~22K tokens of dynamic UC content. For a 128K-context
# model that's ~17% of budget; for smaller models it's catastrophic.
#
# Fix: cap each component (active_todos, relevant_memory,
# unresolved) in messages_to_prose_dynamic. Show an "...and N more"
# hint when items exceed the cap.

use strict;
use warnings;
use utf8;
use lib './lib';

use Test::More;
use CLIO::Core::MessageHistory qw(messages_to_prose_dynamic);

# Build a projection with WAY more data than the caps allow
my @todos;
for my $i (1..200) {
    push @todos, { id => $i, status => 'pending', content => ("todo content $i " x 20) };
}
my @ltm;
for my $i (1..20) {
    push @ltm, { confidence => 0.9, content => ("LTM entry $i framework detail" x 20), type => 'pattern' };
}
my @unresolved;
for my $i (1..20) {
    push @unresolved, ("tool error $i: " . ('details ' x 20));
}

my $proj = {
    active_todos => \@todos,
    relevant_memory => \@ltm,
    ltm_total_count => 20,
    unresolved => \@unresolved,
    environment => {
        working_directory => '/tmp',
        language => 'English',
        datetime_iso => '2026-09-02T12:00:00',
    },
};

my $prose = messages_to_prose_dynamic($proj);
my $len = length($prose);

# SMELL #5 regression guard: total dynamic UC bounded
ok($len < 15000, "dynamic UC bounded (was ~88K before caps, now $len chars)");

# Active todos capped at 10
my $todos_in_output = () = $prose =~ /^- \[/gm;
ok($todos_in_output <= 10, "active todos capped at 10 (rendered: $todos_in_output)");

# LTM capped at 5
my $ltm_in_output = () = $prose =~ /^- \(\d+\.\d+\)/gm;
ok($ltm_in_output <= 5, "relevant memory capped at 5 (rendered: $ltm_in_output)");

# Overflow hint
like($prose, qr/...and \d+ more/, "overflow hint shown when items exceed cap");

done_testing();