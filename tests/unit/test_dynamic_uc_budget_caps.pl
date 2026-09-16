#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test: dynamic userContext components must be capped
# so they cannot balloon the prompt budget on iteration 1
# (where no proactive trim runs). Caps active_todos at 10 entries
# with an "...and N more" hint when items exceed the cap.

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
};

my $prose = messages_to_prose_dynamic($proj);
my $len = length($prose);

# SMELL #5 regression guard: total dynamic UC bounded
ok($len < 15000, "dynamic UC bounded (was ~88K before caps, now $len chars)");

# Both todos and LTM entries render as "- [...]" bullets, so a bare /^- \[/
# counts them together. Split them by the todo status vocabulary instead.
my @bullets = $prose =~ /^- \[.*?\]/gm;
my $is_todo = qr/^- \[(?:not-started|pending|in-progress|completed|blocked)\]/;
my @todo_bullets = grep { /$is_todo/ } @bullets;
my @ltm_bullets  = grep { !/$is_todo/ } @bullets;

my $todos_in_output = scalar @todo_bullets;
ok($todos_in_output <= 10, "active todos capped at 10 (rendered: $todos_in_output)");

# LTM renders (it belongs in the tail) but is capped at MAX_MEMORIES = 5.
my $ltm_in_output = scalar @ltm_bullets;
ok($ltm_in_output > 0 && $ltm_in_output <= 5,
   "LTM entries render and are capped at 5 (rendered: $ltm_in_output)");

# Overflow hint
like($prose, qr/...and \d+ more/, "overflow hint shown when items exceed cap");

done_testing();