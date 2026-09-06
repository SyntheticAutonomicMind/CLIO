#!/usr/bin/perl
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Test: Registry alias table consistency — get_tool, get_alias_info,
# and has_tool all use the same single source of truth and agree.
# Catches regressions where the two alias tables drift (the pre-fix bug
# where get_tool was missing ask_user/confirm/question that get_alias_info
# had, and has_tool didn't resolve aliases at all).

use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/../../lib";

use Test::More;
use CLIO::Tools::Registry;

# Register a minimal set of tools so get_tool/has_tool can actually find them.
use CLIO::Tools::FileOperations;
use CLIO::Tools::TerminalOperations;
use CLIO::Tools::MemoryOperations;
use CLIO::Tools::Interact;
use CLIO::Tools::VersionControl;
use CLIO::Tools::WebOperations;
use CLIO::Tools::TodoList;
use CLIO::Tools::CodeIntelligence;
use CLIO::Tools::ApplyPatch;

my $r = CLIO::Tools::Registry->new();
$r->register_tool(CLIO::Tools::FileOperations->new());
$r->register_tool(CLIO::Tools::TerminalOperations->new());
$r->register_tool(CLIO::Tools::MemoryOperations->new());
$r->register_tool(CLIO::Tools::Interact->new());
$r->register_tool(CLIO::Tools::VersionControl->new());
$r->register_tool(CLIO::Tools::WebOperations->new());
$r->register_tool(CLIO::Tools::TodoList->new());
$r->register_tool(CLIO::Tools::CodeIntelligence->new());
$r->register_tool(CLIO::Tools::ApplyPatch->new(subagent_name => 'test'));

# Every alias in the table must be resolvable by get_alias_info.
my $aliases = $r->_get_operation_aliases();

# Previously-missing aliases that caused the drift bug.
my @previously_broken = qw(ask_user confirm question);
for my $alias (@previously_broken) {
    my $info = $r->get_alias_info($alias);
    ok($info, "get_alias_info('$alias') returns info");
    is($info->{tool}, 'interact', "  $alias resolves to interact tool");
    is($info->{operation}, 'request_input', "  $alias resolves to request_input operation");
}

# Every alias in the table should also resolve via get_tool to a real tool.
my $mismatch = 0;
for my $alias (sort keys %$aliases) {
    my $info  = $r->get_alias_info($alias);
    my $tool  = $r->get_tool($alias);
    my $has   = $r->has_tool($alias);

    # Skip aliases for tools that aren't registered in this test (e.g. agent_operations).
    my $canonical = $info->{tool};
    next unless exists $r->{tools}{$canonical};

    ok($tool, "get_tool('$alias') resolves to registered tool");
    is($tool->{name}, $canonical, "  $alias -> $canonical") if $tool;
    ok($has, "has_tool('$alias') returns true");
    $mismatch++ unless $tool && $has;
}

# has_tool should also work for canonical tool names.
ok($r->has_tool('file_operations'), 'has_tool(file_operations) = YES');
ok($r->has_tool('interact'), 'has_tool(interact) = YES');
ok($r->has_tool('terminal_operations'), 'has_tool(terminal_operations) = YES');

# has_tool should return false for unknown tools.
ok(!$r->has_tool('nonexistent_tool'), 'has_tool(nonexistent_tool) = NO');

done_testing();
