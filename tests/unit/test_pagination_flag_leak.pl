#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt
#
# Test: _tools_invoked_this_request must not leak from a prior AI tool
# workflow into the NEXT slash command's output.
#
# Regression: "/api models and /api by itself sometimes don't paginate
# correctly". The tools-invoked flag set during streaming suppresses
# pagination on the next /command even though no tools are running.

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');

use FindBin qw($Bin);
use lib "$Bin/../../lib";

BEGIN {
    no warnings 'redefine';
    require CLIO::Compat::Terminal;
    *CLIO::Compat::Terminal::GetTerminalSize = sub { return (80, 10); };
    *CLIO::Compat::Terminal::ReadMode        = sub { };
    *CLIO::Compat::Terminal::ReadKey         = sub { return ' ' };
}

BEGIN {
    $ENV{CLIO_NO_CONFIG_LOAD} = 1;
}

use CLIO::UI::Chat;
use CLIO::UI::PaginationManager;

my ($pass, $fail) = (0, 0);
sub ok { my ($c, $l) = @_; $c ? ($pass++, print "PASS: $l\n") : ($fail++, print "FAIL: $l\n"); }

my $chat = CLIO::UI::Chat->new(debug => 0, config => undef, session => undef, no_color => 1);
my $pager = $chat->{pager};
$pager->{is_terminal} = 1;   # force interactive (test harness may not be a TTY)
$chat->refresh_terminal_size();

# threshold = height - 2 = 10 - 2 = 8
ok($pager->threshold() == 8, "threshold is height-2 (10-2=8)");

# --- Test 1: handle_command clears the stale flag ---
$chat->{_tools_invoked_this_request} = 1;   # simulate leftover from prior AI turn

# Stub CommandHandler so we don't trigger real /api logic (needs config/network).
{
    no warnings 'redefine';
    $chat->{command_handler} = bless {}, 'CmdHandlerStub';
    *CmdHandlerStub::handle_command = sub { return 1 };
    my $rc = $chat->handle_command('/api models');
    ok($rc, "handle_command returns truthy continue-signal");
}
ok(!$chat->{_tools_invoked_this_request},
   "_tools_invoked_this_request cleared after handle_command");

# --- Test 2: should_trigger fires after handle_command cleared the flag ---
$pager->reset();
$pager->enable();
$chat->{_tools_invoked_this_request} = 0;   # cleared (as handle_command would do)
$pager->line_count(9);                       # > threshold (8)
ok($pager->should_trigger(),
   "Pagination triggers after flag cleared (line_count=9 >= threshold=8)");

# --- Test 3: guard - stale flag suppresses should_trigger ---
$pager->reset();
$pager->enable();
$chat->{_tools_invoked_this_request} = 1;   # stale, not cleared
$pager->line_count(9);
ok(!$pager->should_trigger(),
   "Guard: stale flag suppresses should_trigger (pauses would be 0)");

# --- Test 4: fresh turn (flag already 0) triggers normally ---
$pager->reset();
$pager->enable();
$chat->{_tools_invoked_this_request} = 0;
$pager->line_count(9);
ok($pager->should_trigger(),
   "Fresh command (flag already 0) triggers pagination");

# --- Test 5: should_trigger still respects disable ---
$pager->reset();
$pager->disable();
$chat->{_tools_invoked_this_request} = 1;   # stale flag
$pager->line_count(100);
ok(!$pager->should_trigger(),
   "should_trigger respects disable even with stale flag");

print "\n$pass passed, $fail failed\n";
exit($fail > 0 ? 1 : 0);
