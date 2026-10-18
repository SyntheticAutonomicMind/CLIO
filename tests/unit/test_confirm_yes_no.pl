#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Test: Commands::Base->confirm_yes_no routes the themed prompt through the
# Chat display buffer (writeline) rather than raw print, reads a yes/no
# response from STDIN, and degrades cleanly in non-interactive mode.

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
    $label //= '(no label)';
    if ($cond) { $pass++; print "OK: $label\n"; }
    else       { $fail++; print "FAIL: $label\n"; }
}

my $chat = CLIO::UI::Chat->new(debug => 0, config => undef, session => undef, no_color => 1);
ok(defined $chat && !$@, 'Chat->new succeeds');

# Build a concrete Base subclass that carries a {chat} ref.
my $cmd = bless { chat => $chat, debug => 0 }, 'CLIO::UI::Commands::Base';

# --- Non-interactive mode: short-circuits with a clear error ---
$chat->{non_interactive} = 1;
my @caught;
no warnings 'redefine';
my $orig_werror = \&CLIO::UI::Chat::display_error_message;
my $orig_sysmsg = \&CLIO::UI::Chat::display_system_message;
*CLIO::UI::Chat::display_error_message   = sub { push @caught, "ERR:" . ($_[1] // '') };
*CLIO::UI::Chat::display_system_message = sub { push @caught, "SYS:" . ($_[1] // '') };
my $rc = $cmd->confirm_yes_no("Clear all patterns?");
ok($rc == 0, 'confirm_yes_no returns false in non-interactive mode');
ok(grep({ $_ =~ /Not available in non-interactive mode/ } @caught), 'non-interactive emits clear error');
*CLIO::UI::Chat::display_error_message   = $orig_werror;
*CLIO::UI::Chat::display_system_message = $orig_sysmsg;
$chat->{non_interactive} = 0;

# --- Interactive mode: prompt routed through writeline, input drives result ---

# Feed a "y" answer by aliasing the filehandle used by <STDIN> in the helper.
my @written;
*CLIO::UI::Chat::writeline = sub {
    my ($self, $text, %opts) = @_;
    push @written, $text;
    return 1;
};

# Intercept <STDIN> read inside confirm_yes_no via a tied filehandle.
require Symbol;
my $stdin_fh = Symbol::gensym();
my $fake_input = "yes\n";
my $pos = 0;
{
    package CLIO::_FakeStdin;
    sub TIEHANDLE { my ($c, $str_ref) = @_; bless { s => $$str_ref, p => 0 }, $c }
    sub READLINE { my $s = shift; return unless $s->{p} < length($s->{s});
                   my $nl = index($s->{s}, "\n", $s->{p});
                   return undef if $nl < 0;
                   my $line = substr($s->{s}, $s->{p}, $nl - $s->{p} + 1);
                   $s->{p} = $nl + 1;
                   return $line; }
    sub EOF { my $s = shift; $s->{p} >= length($s->{s}); }
    sub CLOSE { }
}
tie *STDIN, 'CLIO::_FakeStdin', \$fake_input or die;

my $yes_rc = $cmd->confirm_yes_no("Clear all patterns?");
ok($yes_rc == 1, 'confirm_yes_no returns true for "yes" input');
ok(scalar(grep { $_ =~ /\bCLIO\b/ || $_ =~ /Clear all patterns\?/ } @written),
    'prompt rendered through writeline (not raw print)');
ok(scalar(grep { $_ eq "raw print" } @written) == 0, 'no raw-print marker leaked');

# "n" answer -> false
@written = ();
$fake_input = "no\n";
my $no_rc = $cmd->confirm_yes_no("Delete file?");
ok($no_rc == 0, 'confirm_yes_no returns false for "no" input');

untie *STDIN;

print "\n$pass passed, $fail failed\n";
exit($fail > 0 ? 1 : 0);
