#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# run_strict_tests.pl - Run the unit test suite under -W and surface any
# uninitialized-value (or other) warnings emitted to STDERR.
#
# Usage:
#   perl tests/run_strict_tests.pl                # all tests/unit/*.pl
#   perl tests/run_strict_tests.pl path/to/t.pl    # single file
#   perl tests/run_strict_tests.pl --fatal path... # use warnings FATAL=>'all'
#   perl tests/run_strict_tests.pl --quiet         # only print failing tests
#   perl tests/run_strict_tests.pl --strict-redefine  # also flag redefined sub
#
# Exit code:
#   0  no CLIO warnings
#   1  warnings found (or test itself failed)
#
# Why this exists:
#   CLIO enables `use warnings;` per module template, but a warning only
#   fires when the offending code path is actually executed. A slash-only
#   regression in CommandHandler (commit unfixed) shipped despite passing
#   the entire test suite because no test exercised `/` with no trailing
#   token. This harness re-runs every test under `perl -W` so warnings are
#   enabled even for code paths that don't normally reach STDERR, captures
#   stderr to a tempfile, and greps for the standard "uninitialized value"
#   pattern. Optionally upgrades to `warnings FATAL=>'all'` for a harder
#   pass. CLIO warnings (in lib/CLIO/...) are reported as failures; vendor
#   perl/core warnings (in /System/Library/Perl/...) are surfaced for
#   awareness but do not fail the run.

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use File::Basename qw(dirname);
use Cwd qw(abs_path);
use File::Temp qw(tempfile);
use File::Spec;

my $repo_root = abs_path(dirname(dirname(__FILE__)));
$repo_root = abs_path('.') unless -d "$repo_root/lib";

# Argv parsing
my @targets;
my $fatal = 0;
my $quiet = 0;
my $strict_redefine = 0;
for my $arg (@ARGV) {
    if ($arg eq '--fatal')           { $fatal = 1; next; }
    if ($arg eq '--quiet')           { $quiet = 1; next; }
    if ($arg eq '--strict-redefine') { $strict_redefine = 1; next; }
    if ($arg eq '--help' || $arg eq '-h') {
        print "Usage: $0 [--fatal] [--quiet] [--strict-redefine] [test.pl ...]\n";
        exit 0;
    }
    push @targets, $arg;
}

if (!@targets) {
    my $unit_dir = "$repo_root/tests/unit";
    opendir my $dh, $unit_dir or die "Cannot open $unit_dir: $!\n";
    @targets = sort grep { /\.pl$/ && -f "$unit_dir/$_" } readdir($dh);
    closedir $dh;
}

# `targets` may contain bare filenames (auto-discovery from tests/unit/),
# paths relative to the repo root, or absolute paths. Normalize each entry
# once into an absolute path so the per-test runner can use it directly
# without re-applying $repo_root.
my $unit_dir_for_discovery = "$repo_root/tests/unit";
@targets = map {
    if (File::Spec->file_name_is_absolute($_)) {
        $_;
    } elsif (-f $_) {
        abs_path($_);
    } elsif (-f "$repo_root/$_") {
        abs_path("$repo_root/$_");
    } elsif (-f "$unit_dir_for_discovery/$_") {
        abs_path("$unit_dir_for_discovery/$_");
    } else {
        $_;  # runner will report missing
    }
} @targets;

print "Strict test run: ", scalar(@targets), " test(s)";
print $fatal ? " (warnings FATAL=>'all')\n" : " (-W)\n";

# Per-test runner
my $total_clio_warnings = 0;
my $total_vendor_warnings = 0;
my $total_failures = 0;
my @failing_tests;

# Warning patterns. `redefined-sub` is excluded by default because
# stubbing CLIO::Compat::Terminal::GetTerminalSize, Chat display methods,
# etc. is the standard test pattern. Opt in via --strict-redefine.
my @warning_patterns = (
    [qr/\bUse of uninitialized value\b/, 'uninitialized'],
    [qr/\bWide character in\b/,          'wide-character'],
    [qr/\bSubroutine .* redefined\b/,    'redefined-sub'],
);
@warning_patterns = grep { $_->[1] ne 'redefined-sub' } @warning_patterns
    unless $strict_redefine;

for my $test (@targets) {
    my $abs = $test;  # already normalized to an absolute path
    unless (-f $abs) {
        print STDERR "  ! missing: $abs\n";
        $total_failures++;
        next;
    }

    my ($tmp_fh, $tmp_path) = tempfile(SUFFIX => '.log', UNLINK => 1);
    close $tmp_fh;

    my @cmd = ($^X, '-I', "$repo_root/lib");
    if ($fatal) {
        push @cmd, '-M-warnings=FATAL,all', '-W';
    } else {
        push @cmd, '-W';
    }
    push @cmd, $abs;

    my $pid = fork();
    if (!defined $pid) {
        die "fork failed: $!\n";
    }
    if ($pid == 0) {
        # child: redirect stderr to tempfile, exec
        open my $err_fh, '>', $tmp_path or exit 99;
        open STDERR, '>&', $err_fh or exit 99;
        exec { $cmd[0] } @cmd;
        exit 99;  # exec failed
    }

    # parent: wait for child, capture exit code
    waitpid $pid, 0;
    my $exit_code = $? >> 8;

    # Read stderr.
    open my $rfh, '<', $tmp_path or die "Cannot read $tmp_path: $!\n";
    my $stderr = do { local $/; <$rfh> };
    close $rfh;

    # Categorise stderr by source: CLIO (lib/CLIO/...) vs vendor
    # (perl core, CPAN, .cpan). Unknown provenance defaults to CLIO
    # because it is safer to flag a possible bug than to silently
    # ignore it.
    my @clio_findings;
    my @vendor_findings;
    for my $pat (@warning_patterns) {
        my ($re, $label) = @$pat;
        my @clio;
        my @vendor;
        for my $line (split /\n/, $stderr) {
            if ($line =~ m{$re}) {
                if ($line =~ m{\blib/CLIO/}) {
                    push @clio, $line;
                } elsif ($line =~ m{/System/Library/Perl/}
                        || $line =~ m{/Library/Perl/}
                        || $line =~ m{at\s+\S*perl/\S+/\S+\.pm\s+line\s+\d+}) {
                    push @vendor, $line;
                } else {
                    push @clio, $line;
                }
            }
        }
        if (@clio) {
            push @clio_findings, { label => $label, count => scalar @clio };
        }
        if (@vendor) {
            push @vendor_findings, { label => $label, count => scalar @vendor };
        }
    }

    my $clio_count    = sum(map { $_->{count} } @clio_findings);
    my $vendor_count  = sum(map { $_->{count} } @vendor_findings);
    $total_clio_warnings   += $clio_count;
    $total_vendor_warnings += $vendor_count;

    # A test that returned non-zero is also a "failure" for this harness.
    my $test_failed = $exit_code != 0 && !$clio_count;

    if ($clio_count || $test_failed) {
        $total_failures++;
        push @failing_tests, $test;
        printf "   %s (exit=%d)\n", $test, $exit_code;
        for my $f (@clio_findings) {
            printf "      %d × %s  [CLIO]\n", $f->{count}, $f->{label};
        }
        if ($test_failed) {
            # Show a small preview of stderr.
            my $preview = $stderr;
            $preview =~ s/\e\[[0-9;]*m//g;  # strip ANSI
            my @lines = split /\n/, $preview;
            my $n = scalar @lines;
            my $show = $n > 6 ? 6 : $n;
            for my $i (0 .. $show - 1) {
                print "      | $lines[$i]\n";
            }
            print "      | ($n line(s) total)\n" if $n > $show;
        }
    } elsif (!$quiet) {
        my $vendor_summary = $vendor_count
            ? " [$vendor_count vendor warn(s)]"
            : '';
        printf "   %s%s\n", $test, $vendor_summary;
    }
}

# Summary
print "\n";
print "Tests run:           ", scalar(@targets), "\n";
print "Failures:            $total_failures\n";
print "CLIO warnings:       $total_clio_warnings\n";
print "Vendor warnings:     $total_vendor_warnings  (informational)\n";

if ($total_failures) {
    print "\nFailing tests:\n";
    for my $t (@failing_tests) {
        print "  - $t\n";
    }
}

exit($total_failures ? 1 : 0);

sub sum {
    my $s = 0;
    $s += $_ for @_;
    $s;
}
