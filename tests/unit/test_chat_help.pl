#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Test: Help.pm display_help() does not crash and renders every
# section + command. Catches the @sections data-structure regression
# (issue #28) where '/cmd' => 'desc' pairs were flattened into a
# flat list, causing "Can't use string ("/api") as an ARRAY ref
# while "strict refs" in use at Help.pm line 199".

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

my ($pass, $fail) = (0, 0);
sub ok {
    my ($cond, $label) = @_;
    if ($cond) { $pass++; print "OK: $label\n"; }
    else       { $fail++; print "FAIL: $label\n"; }
}

# Build a minimal Chat instance and override writeline so display_help
# captures every line it tries to render instead of paginating.
my $chat = eval {
    CLIO::UI::Chat->new(
        debug    => 0,
        config   => undef,
        session  => undef,
        no_color => 1,
    );
};
ok(defined $chat && !$@, "Chat->new succeeds");

# Capture all writeline calls.
my @rendered;
no warnings 'redefine';
my $orig_writeline = \&CLIO::UI::Chat::writeline;
*CLIO::UI::Chat::writeline = sub {
    my ($self, $text, %opts) = @_;
    push @rendered, $text // '';
    return 1;  # never paginate
};

# Drive display_help through the Help sub-module directly.
my $help = $chat->{help};
ok(defined $help && ref($help) eq 'CLIO::UI::Chat::Help',
    'Chat->{help} is Chat::Help');

my $err = eval { $help->display_help(); 1 };
ok(defined $err && !$@, 'display_help() runs without dying');

# Restore writeline so the test harness output isn't broken.
*CLIO::UI::Chat::writeline = $orig_writeline;

if ($@) {
    print "  Exception: $@\n";
}

# Verify all 14 section titles rendered (API & CONFIG, SESSION, FILE & GIT,
# PLUGINS, TODO, SPECS (OpenSpec), MEMORY, PROFILE, UPDATES, DEVELOPER,
# SKILLS & PROMPTS, DEVICES & REMOTE, MULTI-AGENT, OTHER).
my @expected_titles = (
    'API & CONFIG', 'SESSION', 'FILE & GIT', 'PLUGINS', 'TODO',
    'SPECS (OpenSpec)', 'MEMORY', 'PROFILE', 'UPDATES', 'DEVELOPER',
    'SKILLS & PROMPTS', 'DEVICES & REMOTE', 'MULTI-AGENT', 'OTHER',
);
for my $title (@expected_titles) {
    my $found = grep { $_ eq $title } @rendered;
    ok($found, "Section title rendered: $title");
}

# Verify representative commands appear (sample across sections).
my @expected_commands = (
    '/api', '/api set model <name>', '/api models', '/api remove <provider>',
    '/session', '/session list',
    '/file', '/git', '/undo', '/mcp', '/mcp add <name> <cmd>',
    '/plugin', '/plugin enable <name>',
    '/todo', '/todo done <id>',
    '/spec', '/spec archive <name>',
    '/memory', '/memory clear',
    '/profile', '/profile clear',
    '/update', '/update switch <ver>',
    '/explain [file]', '/doc <file>',
    '/skills', '/prompt',
    '/device add <name> <host>', '/group add <name> <devs...>',
    '/agent spawn <task>', '/mux agent <id>',
    '/billing', '/debug',
);
for my $cmd (@expected_commands) {
    my $found = grep { $_ =~ /\Q$cmd\E\s/ || $_ =~ /\Q$cmd\E$/ } @rendered;
    ok($found, "Command rendered: $cmd");
}

# Verify descriptions also rendered (proves cmd/desc pairing survived).
my @expected_descriptions = (
    'API settings (model, provider, login)',
    'Quick model switch (alias-aware)',
    'Initialize openspec/ directory',
    'Build profile from session history',
    'Toggle debug mode',
);
for my $desc (@expected_descriptions) {
    ok(grep { $_ =~ /\Q$desc\E/ } @rendered,
        "Description rendered: $desc");
}

# Re-run through the Chat delegation chain to make sure the path the user
# actually hits (/help) works too.
@rendered = ();
no warnings 'redefine';
*CLIO::UI::Chat::writeline = sub {
    my ($self, $text, %opts) = @_;
    push @rendered, $text // '';
    return 1;
};
my $delegated = eval { $chat->display_help(); 1 };
*CLIO::UI::Chat::writeline = $orig_writeline;
ok(defined $delegated && !$@, 'Chat->display_help() delegation works');
ok(scalar @rendered > 50,
    'Delegated display_help rendered substantial output ('
        . scalar(@rendered) . " lines)");

print "\n$pass passed, $fail failed\n";
exit($fail > 0 ? 1 : 0);