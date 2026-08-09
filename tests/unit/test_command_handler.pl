#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Test: CommandHandler.handle_command() does not emit uninitialized-value
# warnings for slash-only or empty input, and still routes real commands.
#
# Catches the regression where typing `/` at the prompt produced:
#   Use of uninitialized value within @parts in lc at
#     lib/CLIO/UI/CommandHandler.pm line 257.
# Root cause was `lc(shift @parts)` running on the empty list returned by
# `shellwords('')`, so `shift` returned undef.
#
# Also exercises other edge cases that previously could have been silent
# under-initialized paths:
#   - `/`           (slash only)
#   - `/  `         (slash with whitespace)
#   - `//`          (double slash)
#   - `/unknown`    (unknown command path, no args)
#   - `/help`       (real command, ensures no regression)
#   - `/exit`       (real command with returns=exit)

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

my ($pass, $fail) = (0, 0);
sub ok {
    my ($cond, $label) = @_;
    if ($cond) { $pass++; print "OK: $label\n"; }
    else       { $fail++; print "FAIL: $label\n"; }
}

# Build a Chat with no config/session/ai so CommandHandler init succeeds.
my $chat = eval {
    CLIO::UI::Chat->new(
        debug    => 0,
        config   => undef,
        session  => undef,
        ai_agent => undef,
        no_color => 1,
    );
};
ok(defined $chat && !$@, "Chat->new succeeds");

my $handler = $chat->{command_handler};
ok(defined $handler && ref($handler) eq 'CLIO::UI::CommandHandler',
    "Chat->{command_handler} is a CommandHandler");

# Capture writeline + display_error_message + display_system_message
# so we can both suppress rendering and assert on what was emitted.
my @rendered;
no warnings 'redefine';
my $orig_writeline            = \&CLIO::UI::Chat::writeline;
my $orig_display_error        = \&CLIO::UI::Chat::display_error_message;
my $orig_display_system       = \&CLIO::UI::Chat::display_system_message;
*CLIO::UI::Chat::writeline = sub {
    my ($self, $text, %opts) = @_;
    push @rendered, $text // '';
    return 1;
};
*CLIO::UI::Chat::display_error_message  = sub {
    my ($self, $text) = @_;
    push @rendered, "[ERR] " . ($text // '');
};
*CLIO::UI::Chat::display_system_message = sub {
    my ($self, $text) = @_;
    push @rendered, "[SYS] " . ($text // '');
};

# Helper: invoke handle_command while capturing all warnings.
sub run_with_warnings {
    my ($input) = @_;
    my @warnings;
    local $SIG{__WARN__} = sub {
        my ($msg) = @_;
        push @warnings, $msg;
        # Also let it print so we can see it in --verbose runs.
    };
    my $rc;
    eval { $rc = $handler->handle_command($input); 1 };
    return ($rc, $@ || '', \@warnings);
}

# ── Slash-only input regression (the original bug) ───────────────────

for my $input ('/', '/  ', '//', '/   ') {
    @rendered = ();
    my ($rc, $err, $warnings) = run_with_warnings($input);

    my @uninit = grep { /\bUse of uninitialized value\b/ } @$warnings;
    ok(@uninit == 0,
        "No uninitialized-value warnings for input '$input' (got "
            . scalar(@uninit) . ")")
      or do {
        for my $w (@uninit) { print "    warn: $w"; }
      };

    ok(!$err, "No exception for input '$input'")
      or print "    exception: $err\n";

    ok($rc == 1, "handle_command('$input') returns 1 (continue)");

    my $found_err = grep { m{\QUnknown command:\E} } @rendered;
    ok($found_err, "Emitted 'Unknown command:' for input '$input'");
}

# ── Unknown command with no args ────────────────────────────────────

@rendered = ();
my ($rc_u, $err_u, $warn_u) = run_with_warnings('/totally_made_up_command');
my @uninit_u = grep { /\bUse of uninitialized value\b/ } @$warn_u;
ok(@uninit_u == 0, "No uninit warnings for unknown command")
  or do { for my $w (@uninit_u) { print "    warn: $w"; } };
my $count_unknown = grep { m{\bUnknown command:\s*/totally_made_up_command\b} } @rendered;
ok($count_unknown, "Unknown command path names the bad command verbatim");

# ── Real command sanity (ensure the fix did not break dispatch) ──────

@rendered = ();
my ($rc_h, $err_h, $warn_h) = run_with_warnings('/help');
my @uninit_h = grep { /\bUse of uninitialized value\b/ } @$warn_h;
ok(@uninit_h == 0, "No uninit warnings for /help")
  or do { for my $w (@uninit_h) { print "    warn: $w"; } };
ok($rc_h == 1, "/help returns 1 (continue)");
ok(scalar(@rendered) > 0, "/help rendered some content");

# ── Real command that returns 0 (exit) ──────────────────────────────

@rendered = ();
my ($rc_e, $err_e, $warn_e) = run_with_warnings('/exit');
my @uninit_e = grep { /\bUse of uninitialized value\b/ } @$warn_e;
ok(@uninit_e == 0, "No uninit warnings for /exit")
  or do { for my $w (@uninit_e) { print "    warn: $w"; } };
ok($rc_e == 0, "/exit returns 0 (exit signal)");

# ── Restore overridden methods (good hygiene, even though process ends) ─

*CLIO::UI::Chat::writeline            = $orig_writeline;
*CLIO::UI::Chat::display_error_message  = $orig_display_error;
*CLIO::UI::Chat::display_system_message = $orig_display_system;

# ── Summary ──────────────────────────────────────────────────────────

print "\n";
print "Passed: $pass\n";
print "Failed: $fail\n";
exit($fail == 0 ? 0 : 1);
