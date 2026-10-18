#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Test: /help is a faithful, drift-free rendering of the live command
# registry.  Every registered command and every category must appear in the
# listing, and /help <command> must route to the per-command renderer (or a
# synthesized summary) without dying.
#
# This replaces the old test that hardcoded the @sections data structure
# (issue #28 regression guard).  That fixture was itself the source of the
# help/registry drift, so this version derives expectations from the registry
# directly: if a command is registered but not listed, the test fails.

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
BEGIN { $ENV{CLIO_NO_CONFIG_LOAD} = 1; }

use CLIO::UI::Chat;
use CLIO::UI::Chat::Help;

my ($pass, $fail) = (0, 0);
sub ok {
    my ($cond, $label) = @_;
    $label //= '(no label)';
    if ($cond) { $pass++; print "OK: $label\n"; }
    else       { $fail++; print "FAIL: $label\n"; }
}

my $chat = eval {
    CLIO::UI::Chat->new(debug => 0, config => undef, session => undef, no_color => 1);
};
ok(defined $chat && !$@, 'Chat->new succeeds');

# Capture every writeline; return 1 so the full output renders (no paging).
my @rendered;
no warnings 'redefine';
my $orig_writeline = \&CLIO::UI::Chat::writeline;
*CLIO::UI::Chat::writeline = sub {
    my ($self, $text, %opts) = @_;
    push @rendered, $text // '';
    return 1;
};

my $help = $chat->{help};
ok(defined $help && ref($help) eq 'CLIO::UI::Chat::Help', 'Chat->{help} is Chat::Help');

my $err = eval { $help->display_help(); 1 };
ok(defined $err && !$@, 'display_help() runs without dying');

# --- Drift guard: every registered command is listed ---
my $ch = $chat->get_command_handler();
ok(defined $ch, 'command handler available');

my @defs = @{$ch->command_defs()};
ok(scalar(@defs) >= 50, "registry declares a full command set (" . scalar(@defs) . " defs)");

my $cmd_present = 0;
my @missing;
for my $def (@defs) {
    my @names = $def->{names} ? @{$def->{names}} : ($def->{name});
    my $cmd   = join(', ', map { "/$_" } @names);
    my $found = scalar(grep { $_ =~ /\Q$cmd\E/ } @rendered);
    $cmd_present++ if $found;
    push @missing, $cmd unless $found;
}
ok($cmd_present == scalar(@defs),
    "Every registered command is listed (missing: " . scalar(@missing) . ")");
ok(scalar @rendered > 0, 'Rendering produced output');

# --- Drift guard: every category is listed as a section header ---
my %cats;
$cats{$_->{category} // 'OTHER'} = 1 for @defs;
my $cat_missing = 0;
for my $cat (sort keys %cats) {
    $cat_missing++ unless scalar(grep { $_ eq $cat } @rendered);
}
ok($cat_missing == 0, 'Every registered category appears as a section header');

# --- Static help-only content still renders ---
ok(scalar(grep { $_ eq 'KEYBOARD SHORTCUTS' } @rendered), 'Keyboard shortcuts section present');
ok(scalar(grep { $_ =~ /COMMANDS/ } @rendered), 'Listing header present');

*CLIO::UI::Chat::writeline = $orig_writeline;

# --- Delegation chain: the user-visible entry point works too ---
@rendered = ();
*CLIO::UI::Chat::writeline = sub {
    my ($self, $text, %opts) = @_;
    push @rendered, $text // '';
    return 1;
};
my $delegated = eval { $chat->display_help(); 1 };
*CLIO::UI::Chat::writeline = $orig_writeline;
ok(defined $delegated && !$@, 'Chat->display_help() delegation works');
ok(scalar(@rendered) > 50, "Delegated output is substantial (" . scalar(@rendered) . " lines)");

# --- Routing: /help <command> dispatches to the dedicated renderer ---
@rendered = ();
*CLIO::UI::Chat::writeline = sub {
    my ($self, $text, %opts) = @_;
    push @rendered, $text // '';
    return 1;
};
my $routed = eval { $ch->display_help_for('git'); 1 };
*CLIO::UI::Chat::writeline = $orig_writeline;
ok(defined $routed && !$@, '/help git does not die');
ok(scalar(grep { $_ =~ /\bGIT\b/ } @rendered), '/help git dispatches to the git renderer');

# --- Unknown command: clean error, not a crash ---
@rendered = ();
*CLIO::UI::Chat::writeline = sub {
    my ($self, $text, %opts) = @_;
    push @rendered, $text // '';
    return 1;
};
my $rc = eval { $ch->display_help_for('no_such_command'); 1 };
*CLIO::UI::Chat::writeline = $orig_writeline;
ok($rc && !$@, 'Unknown command help does not die');
ok(scalar(grep { $_ =~ /Unknown command: \/no_such_command/ } @rendered),
    'Unknown command yields a clear error message');

# --- Synthesized fallback for a command without a dedicated renderer ---
@rendered = ();
*CLIO::UI::Chat::writeline = sub {
    my ($self, $text, %opts) = @_;
    push @rendered, $text // '';
    return 1;
};
my $fb = eval { $ch->display_help_for('color'); 1 };
*CLIO::UI::Chat::writeline = $orig_writeline;
ok($fb && !$@, '/help color (synthesized) does not die');
ok(scalar(grep { $_ eq 'COMMAND: /color' } @rendered), 'Synthesized help uses the command-header frame');
ok(scalar(grep { $_ =~ /Toggle color output/ } @rendered), 'Synthesized help shows the registry summary');

print "\n$pass passed, $fail failed\n";
exit($fail > 0 ? 1 : 0);
