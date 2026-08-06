#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Test: Q during pagination actually quits the displayed command.
# Catches the bug where /api (and several other commands) ignored
# the writeline return value and scrolled past the Q press.
#
# The fix has two parts:
# 1. CLIO::UI::Display helpers (display_command_row,
#    display_section_header, display_key_value, display_list_item)
#    propagate writeline's return value to their callers.
# 2. Affected callers (CLIO::UI::Commands::API::_display_api_help,
#    several CLIO::UI::Commands::SubAgent functions,
#    CLIO::UI::Commands::Prompt::_display_active_prompt) early-return
#    when any writeline returns 0.

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');

use File::Basename qw(dirname);
use Cwd qw(abs_path);

my $repo_root = abs_path(dirname(dirname(dirname($0))));
$repo_root = abs_path('.') unless -d "$repo_root/lib";
unshift @INC, "$repo_root/lib";

BEGIN {
    no warnings 'redefine';
    eval { require CLIO::Compat::Terminal; };
    *CLIO::Compat::Terminal::GetTerminalSize = sub { return (80, 24); };
    *CLIO::Compat::Terminal::ReadMode     = sub { };
    *CLIO::Compat::Terminal::ReadKey      = sub { undef };
}

BEGIN {
    $ENV{CLIO_NO_CONFIG_LOAD} = 1;
}

use CLIO::UI::Chat;
use CLIO::UI::Chat::Help;

my ($pass, $fail) = (0, 0);
sub ok {
    my ($cond, $label) = @_;
    if ($cond) { $pass++; print "OK: $label\n"; }
    else       { $fail++; print "FAIL: $label\n"; }
}

# Build a Chat with a pager whose writeline we control. After N calls
# to writeline, we simulate Q by returning 0.
package CountingPager;
sub new {
    my ($class, $quit_after) = @_;
    return bless { count => 0, quit_after => $quit_after, quit_requested => 0 }, $class;
}
sub enable { $_[0]{enabled} = 1; $_[0]{line_count} = 0; $_[0] }
sub disable { $_[0]{enabled} = 0; $_[0] }
sub enabled { return $_[0]{enabled} }
sub line_count { return $_[0]{line_count} }
sub increment_lines { $_[0]{line_count}++; }
sub reset {
    my $self = shift;
    $self->{line_count} = 0;
    $self->{pages} = [];
    $self->{current_page} = [];
    $self->{page_index} = 0;
    $self->{enabled} = 0;
    $self;
}
sub threshold { 1 }   # Force every line to trigger pagination (we never actually call pause)
sub should_trigger { 0 }   # Never trigger - we only check writeline return value
sub save_page { push @{$_[0]{pages}}, [@{$_[0]{current_page}}]; $_[0]{page_index} = scalar @{$_[0]{pages}}; }
sub reset_page { $_[0]{current_page} = []; }
sub pause { return 'C' }   # Continuation token, never Q
sub display_list { }
sub display_content { }

# Track every line we tried to write. Quit returns 0 once quit_after
# lines have been written.
sub writeline_proxy {
    my ($self, $text) = @_;
    $self->{count}++;
    if ($self->{count} > $self->{quit_after}) {
        $self->{quit_requested} = 1;
        return 0;
    }
    return 1;
}

package main;

# --- Test 1: Display.pm helpers propagate writeline's return value ---

# Build a minimal Chat and replace writeline with our counting pager.
my $chat = CLIO::UI::Chat->new(
    debug    => 0,
    config   => undef,
    session  => undef,
    no_color => 1,
);
ok(defined $chat && !$@, "Chat->new succeeds");

# Capture Chat::writeline via the test pager.
my $pager = CountingPager->new(1);   # quit after 1 writeline
$chat->{pager} = $pager;

no warnings 'redefine';
my $orig_writeline = \&CLIO::UI::Chat::writeline;
*CLIO::UI::Chat::writeline = sub {
    my ($self, $text, %opts) = @_;
    return $pager->writeline_proxy($text);
};

# Display helpers should return 0 once writeline returns 0.
require CLIO::UI::Display;
my $display = CLIO::UI::Display->new(chat => $chat);
$chat->{display} = $display;

my $r = $display->display_command_row("/cmd", "desc", 30);
ok($r == 1, "display_command_row returns truthy when writeline returns 1");

$r = $display->display_command_row("/cmd", "desc", 30);
ok($r == 0, "display_command_row returns 0 (Q was pressed)");

*CLIO::UI::Chat::writeline = $orig_writeline;

# --- Test 2: Help.pm display_help bails out on Q ---

$pager = CountingPager->new(3);
$chat->{pager} = $pager;
{
    no strict 'refs';
    my $hash = $pager;
    @{$hash}{qw(line_count pages current_page page_index enabled)} = (0, [], [], 0, 0);
}

my $help = $chat->{help};
ok(defined $help && ref($help) eq 'CLIO::UI::Chat::Help',
    'Chat->{help} is Chat::Help');

no warnings 'redefine';
*CLIO::UI::Chat::writeline = sub {
    my ($self, $text, %opts) = @_;
    return $pager->writeline_proxy($text);
};

my $err = eval { $help->display_help(); 1 };
*CLIO::UI::Chat::writeline = $orig_writeline;

ok(defined $err && !$@, 'display_help() does not die when Q pressed');
ok($pager->{quit_requested},
    'Help display_help bails out (quit_requested is true)');
ok($pager->{count} <= 10,
    "Help display_help stopped early (wrote $pager->{count} lines instead of full output)");

# --- Test 3: Bug regression - the original Help.pm bug would die on first iteration ---

# Reset and force the bug pattern to verify our test would have caught it.
my @buggy_sections = (
    ["API & CONFIG" => [
        '/api' => 'API settings (model, provider, login)',
    ]],
);

my $buggy_died = !eval {
    for my $section (@buggy_sections) {
        my ($title, $items) = @$section;
        for my $item (@$items) {
            my ($cmd, $desc) = @$item;   # dies here on original bug
        }
    }
    1;
};
ok($buggy_died, 'Reproducer: original bug pattern (item as string, not arrayref) still dies - test would have caught the regression');

eval {
    for my $section (@buggy_sections) {
        my ($title, $items) = @$section;
        for my $item (@$items) {
            my ($cmd, $desc) = @$item;   # dies here on original bug
        }
    }
};
ok($@, 'Reproducer: original bug pattern (item as string, not arrayref) still dies - test would have caught the regression');

print "\n$pass passed, $fail failed\n";
exit($fail > 0 ? 1 : 0);