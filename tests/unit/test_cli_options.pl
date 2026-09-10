#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Test: CLI option validation for --dir, --style, --theme, --prompt
#
# Covers:
#   --dir /nonexistent    -> stderr error + exit 1
#   --dir /file           -> stderr "not a directory" + exit 1
#   --dir /valid          -> resolves to absolute path, starts up
#   --style bogus         -> stderr "not found" + exits 1 (with list)
#   --style valid         -> transient config set, starts up
#   --theme bogus         -> stderr "not found" + exit 1 (with list)
#   --theme valid         -> transient config set, starts up
#   --prompt bogus        -> stderr "not found" + exit 1 (with list)
#   --prompt default      -> starts up
#   --help includes --style and --theme in OPTIONS

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');

use FindBin qw($RealBin);
use File::Temp qw(tempdir);
use File::Spec;

my $repo_root = "$RealBin/../../";
my $clio_bin  = "$repo_root/clio";

my ($pass, $fail) = (0, 0);
sub ok_int {
    my ($cond, $label) = @_;
    if ($cond) { $pass++; print "PASS: $label\n"; }
    else       { $fail++; print "FAIL: $label\n"; }
}

# Run clio with given args, isolated config dir, capture stdout+stderr+exit.
# Returns ($combined_output, $exit_code).
sub run_clio {
    my (@args) = @_;
    # Use an isolated config dir so we never touch the real user config.
    my $cfg = tempdir(CLEANUP => 1);
    my $out = `CLIO_NO_CONFIG_LOAD=1 "$^X" "$clio_bin" --config "$cfg" @args --no-color 2>&1`;
    my $rc = $? >> 8;
    return ($out, $rc);
}

# ── Source-level checks ──────────────────────────────────────────────
ok_int(-x $clio_bin, "clio executable exists");

open my $fh, '<', $clio_bin or die "Cannot read $clio_bin: $!";
my $src = do { local $/; <$fh> };
close $fh;

ok_int($src =~ qr/use Cwd qw\(abs_path\)/, "clio imports abs_path from Cwd");
ok_int($src =~ qr/--style.*ARGV/, "clio parses --style from ARGV");
ok_int($src =~ qr/--theme.*ARGV/, "clio parses --theme from ARGV");
ok_int($src =~ qr/style_override/, "clio has style_override variable");
ok_int($src =~ qr/theme_override/, "clio has theme_override variable");
ok_int($src =~ qr/Error: --dir/, "clio has --dir validation error message");
ok_int($src =~ qr/Error: --style/, "clio has --style validation error message");
ok_int($src =~ qr/Error: --theme/, "clio has --theme validation error message");
ok_int($src =~ qr/Error: --prompt/, "clio has --prompt validation error message");

# --help should list --style and --theme in OPTIONS
my ($help_out, $help_rc) = run_clio('--help');
ok_int($help_rc == 0, "--help exits 0");
ok_int($help_out =~ /--style\s+<name>/, "--help lists --style option");
ok_int($help_out =~ /--theme\s+<name>/, "--help lists --theme option");

# ── --dir validation ─────────────────────────────────────────────────
{
    my ($out, $rc) = run_clio('--dir', '/nonexistent_dir_xyz/', '--exit');
    ok_int($rc != 0, "--dir nonexistent exits non-zero");
    ok_int($out =~ /Error: --dir directory does not exist/, "--dir nonexistent reports missing dir");

    my $tmp = tempdir(CLEANUP => 0);
    my ($out2, $rc2) = run_clio('--dir', $tmp, '--input', '/session', '--exit');
    ok_int($rc2 == 0, "--dir valid directory starts up");

    # A regular file should be rejected as "not a directory"
    my $file = "$tmp/regular_file.txt";
    open my $wfh, '>', $file or die;
    print $wfh "test";
    close $wfh;
    my ($out3, $rc3) = run_clio('--dir', $file, '--exit');
    ok_int($rc3 != 0, "--dir file path exits non-zero");
    ok_int($out3 =~ /Error: --dir path is not a directory/, "--dir file path reports 'not a directory'");
}

# ── --style validation ───────────────────────────────────────────────
{
    my ($out, $rc) = run_clio('--style', 'bogus_style_xyz', '--exit');
    ok_int($rc != 0, "--style invalid exits non-zero");
    ok_int($out =~ /Error: --style 'bogus_style_xyz' not found/, "--style invalid reports not found");
    ok_int($out =~ /Available styles:/, "--style invalid lists available styles");

    my ($out2, $rc2) = run_clio('--style', 'default', '--input', '/session', '--exit');
    ok_int($rc2 == 0, "--style valid starts up");
}

# ── --theme validation ───────────────────────────────────────────────
{
    my ($out, $rc) = run_clio('--theme', 'bogus_theme_xyz', '--exit');
    ok_int($rc != 0, "--theme invalid exits non-zero");
    ok_int($out =~ /Error: --theme 'bogus_theme_xyz' not found/, "--theme invalid reports not found");
    ok_int($out =~ /Available themes:/, "--theme invalid lists available themes");

    my ($out2, $rc2) = run_clio('--theme', 'default', '--input', '/session', '--exit');
    ok_int($rc2 == 0, "--theme valid starts up");
}

# ── --prompt validation ──────────────────────────────────────────────
{
    my ($out, $rc) = run_clio('--prompt', 'bogus_prompt_xyz', '--exit');
    ok_int($rc != 0, "--prompt invalid exits non-zero");
    ok_int($out =~ /Error: --prompt 'bogus_prompt_xyz' not found/, "--prompt invalid reports not found");
    ok_int($out =~ /Available prompts:/, "--prompt invalid lists available prompts");

    my ($out2, $rc2) = run_clio('--prompt', 'default', '--input', '/session', '--exit');
    ok_int($rc2 == 0, "--prompt valid starts up");
}

# ── --dir validation fires before API calls ─────────────────────────
# Using --input with a nonexistent dir should exit before any network activity.
{
    my ($out, $rc) = run_clio('--dir', '/nonexistent_dir_xyz/', '--input', 'hi there', '--exit');
    ok_int($rc != 0, "--dir nonexistent + --input exits early (no API call)");
    ok_int($out =~ /Error: --dir/, "--dir error shown before any API activity");
}

print "\n--- Results: $pass passed, $fail failed ---\n";
exit($fail > 0 ? 1 : 0);
