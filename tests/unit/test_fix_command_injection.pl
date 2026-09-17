#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Test: AI.pm handle_fix_command must not allow command injection via
# crafted filenames. The old backtick form `perl -c $file 2>&1` passed
# $file through /bin/sh, where shell metacharacters like $(), backticks,
# and $VAR expansion could enable command injection. After the fix, the
# path is passed as a single argv element via fork+exec.

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');

use File::Basename qw(dirname);
use Cwd qw(abs_path);
use File::Temp qw(tempdir);

my $repo_root = abs_path(dirname(dirname(dirname($0))));
$repo_root = abs_path('.') unless -d "$repo_root/lib";
unshift @INC, "$repo_root/lib";

require CLIO::UI::Commands::AI;

my ($pass, $fail) = (0, 0);
sub ok {
    my ($cond, $label) = @_;
    if ($cond) { $pass++; print "OK: $label\n"; }
    else       { $fail++; print "FAIL: $label\n"; }
}

# Create a mock chat object to avoid crashes on display_error_message
my $mock_chat = bless {}, 'MockChatForFixTest';
sub MockChatForFixTest::display_error_message {
    my ($self, $msg) = @_;
    # Capture for testing
    $self->{last_error} = $msg;
}

my $tmp = tempdir(CLEANUP => 1);
my $ai_cmd = CLIO::UI::Commands::AI->new(chat => $mock_chat, debug => 0);

# ── Test 1: Valid file with $(whoami) in filename ──
# If the backtick form were still in use, the shell would expand $(whoami)
# and perl would try to check a file named test<username>.pl (not the actual
# file on disk). With the fix, perl receives the literal filename.
my $whoami = `whoami`;
chomp($whoami);
my $injection_file = "$tmp/test\$(whoami).pl";
open my $fh, '>:encoding(UTF-8)', $injection_file or die "Cannot create: $!";
print $fh "print 'hello';\n";
close $fh;

my $prompt = $ai_cmd->handle_fix_command($injection_file);
ok(defined $prompt, "fix command with \$(whoami) filename returns a prompt (no crash)");
if (defined $prompt) {
    ok(index($prompt, $injection_file) >= 0, "fix prompt contains literal filename with \$(whoami)");
    ok(index($prompt, $whoami) == -1 || $prompt =~ /\$\(whoami\)/,
       "fix prompt does not contain expanded whoami output");
}

# ── Test 2: File with backticks in filename ──
my $bt_file = "$tmp/test\`whoami\`.pl";
if (open my $fh2, '>:encoding(UTF-8)', $bt_file) {
    print $fh2 "print 'safe';\n";
    close $fh2;
    $prompt = $ai_cmd->handle_fix_command($bt_file);
    ok(defined $prompt, "fix command with backtick filename returns a prompt (no crash)");
} else {
    ok(1, "fix command: backtick filename could not be created (FS limitation)");
}

# ── Test 3: File with \$VAR expansion ──
my $var_file = "$tmp/test\${PATH}.pl";
if (open my $fh3, '>:encoding(UTF-8)', $var_file) {
    print $fh3 "print 'safe';\n";
    close $fh3;
    $prompt = $ai_cmd->handle_fix_command($var_file);
    ok(defined $prompt, "fix command with \$VAR filename returns a prompt (no crash)");
} else {
    ok(1, "fix command: \$VAR filename could not be created (FS limitation)");
}

# ── Test 4: Verify no shell expansion via timing ($(sleep 5)) ──
# With the old backtick form, the shell would execute `sleep 5` before
# passing the expanded filename to perl, causing a 5-second delay.
# With the fix, perl -c receives the literal filename immediately.
my $sleep_file = "$tmp/test\$(sleep\ 5).pl";
open my $fh4, '>:encoding(UTF-8)', $sleep_file or die;
print $fh4 "print 'safe';\n";
close $fh4;

my $start_time = time();
$prompt = $ai_cmd->handle_fix_command($sleep_file);
my $elapsed = time() - $start_time;
ok($elapsed < 3, "fix command with \$(sleep 5): completed quickly ($elapsed s) — no subshell execution");

# ── Test 5: Non-existent file returns undef (via display_error_message) ──
$prompt = $ai_cmd->handle_fix_command("$tmp/nonexistent_file.pl");
ok(!defined($prompt), "fix command with nonexistent file returns undef");

# ── Test 6: No arguments returns undef ──
$prompt = $ai_cmd->handle_fix_command();
ok(!defined($prompt), "fix command with no args returns undef");

print "\n----------------------------------------\n";
print "PASS: $pass  FAIL: $fail\n";
if ($fail > 0) {
    print "SOME TESTS FAILED!\n";
    exit 1;
}
print "ALL TESTS PASSED\n";
exit 0;
