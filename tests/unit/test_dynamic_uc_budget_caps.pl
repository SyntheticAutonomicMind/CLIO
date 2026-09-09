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

# Active todos capped at 10
my $todos_in_output = () = $prose =~ /^- \[/gm;
ok($todos_in_output <= 10, "active todos capped at 10 (rendered: $todos_in_output)");

# LTM not rendered (metadata-leak fix removed the Relevant memory: section)
my $ltm_in_output = () = $prose =~ /^- \(\d+\.\d+\)/gm;
ok($ltm_in_output == 0, "no LTM entries in prose (Relevant memory section removed, rendered: $ltm_in_output)");

# Overflow hint
like($prose, qr/...and \d+ more/, "overflow hint shown when items exceed cap");

done_testing();