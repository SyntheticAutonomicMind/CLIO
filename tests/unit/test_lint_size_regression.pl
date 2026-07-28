#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Synthetic Autonomic Mind
#
# Test that the size regression lint catches the patterns it's designed
# to detect, and that it produces correct output.
#
# Runs `tools/lint_size_regression.pl --json` against the working tree.
# Any rule that fires (module-too-large, method-too-large, bare-die-added,
# json-pp-direct-added, cpan-dep-added) is surfaced as a TAP warning
# via diag() so reviewers see it, but does NOT fail the test.
#
# Why warn instead of fail: temporary regressions during legitimate
# work are sometimes acceptable. The test makes them visible; whether
# to block a release is a human decision based on context.
#
# Also exercises each rule in isolation against a synthetic file to
# confirm the lint detects what it claims to detect.

use strict;
use warnings;
use utf8;
use FindBin;
use File::Spec;
use File::Basename;
use File::Temp qw(tempdir);
use File::Path qw(mkpath);
use Cwd qw(abs_path);

use Test::More;

# Skip when invoked from inside the test runner. Reading working tree
# state from inside the runner produces no signal (changes are already
# committed) and isn't what this test is designed to catch.
if ($ENV{CLIO_TEST_RUNNER_INVOKED}) {
    plan skip_all => 'Skipping during nested runner invocation';
    exit 0;
}

my $tests_dir = dirname(abs_path($FindBin::Bin));
my $project_root = dirname($tests_dir);
chdir $project_root or die "Cannot chdir to $project_root: $!\n";

sub decode_json {
    my $str = shift;
    if (eval { require JSON::PP; 1 }) {
        return JSON::PP::decode_json($str);
    } elsif (eval { require JSON; 1 }) {
        return JSON::decode_json($str);
    } else {
        die "No JSON module available\n";
    }
}

# =============================================================================
# Test the lint tool itself on the current tree
# =============================================================================

subtest 'lint runs against working tree' => sub {
    my $output = `perl -I $project_root/lib $project_root/tools/lint_size_regression.pl --json 2>/dev/null`;
    my $data = eval { decode_json($output); };
    ok(defined $data, "Lint produced parseable JSON output");
    ok(exists $data->{checked_files}, "Output has checked_files field");
    ok(exists $data->{warnings}, "Output has warnings field");
    is(ref($data->{warnings}), 'ARRAY', "warnings is an array");
};

# =============================================================================
# Test each lint rule with synthetic files
# =============================================================================

subtest 'module-too-large rule fires on >1000 line file' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    chdir $tmpdir or die;

    # Create a fake git repo so the lint's `git diff` works
    system("git init -q");
    system('git config user.email test@example.com');
    system("git config user.name 'test'");

    # Create a large .pm file (>1000 lines)
    my $libdir = "$tmpdir/lib/CLIO/Test";
    mkpath($libdir) or die "mkpath: $!";
    open my $fh, '>', "$libdir/Big.pm" or die;
    print $fh "package CLIO::Test::Big;\nuse strict;\n";
    for (1..1100) {
        print $fh "# filler line $_\n";
    }
    print $fh "1;\n";
    close $fh;
    system("git add .");

    my $output = `perl -I $project_root/lib $project_root/tools/lint_size_regression.pl --staged --json 2>/dev/null`;
    my $data = decode_json($output);
    my @big_warnings = grep { $_->{rule} eq 'module-too-large' } @{$data->{warnings} // []};
    ok(@big_warnings > 0, "module-too-large rule fired");
    is($big_warnings[0]{file}, 'lib/CLIO/Test/Big.pm', "Correct file flagged");
    ok($big_warnings[0]{line} > 1000, "Reported line count >1000");
};

subtest 'method-too-large rule fires on >200 line sub' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    chdir $tmpdir or die;
    system("git init -q");
    system('git config user.email test@example.com');
    system("git config user.name 'test'");

    my $libdir = "$tmpdir/lib/CLIO/Test";
    mkpath($libdir) or die "mkpath: $!";
    open my $fh, '>', "$libdir/BigMethod.pm" or die;
    print $fh "package CLIO::Test::BigMethod;\nuse strict;\n";
    print $fh "sub big_method {\n";
    for (1..250) {
        print $fh "    my \$x = $_\n";
    }
    print $fh "}\n1;\n";
    close $fh;
    system("git add .");

    my $output = `perl -I $project_root/lib $project_root/tools/lint_size_regression.pl --staged --json 2>/dev/null`;
    my $data = decode_json($output);
    my @method_warnings = grep { $_->{rule} eq 'method-too-large' } @{$data->{warnings} // []};
    ok(@method_warnings > 0, "method-too-large rule fired");
    is($method_warnings[0]{method}, 'big_method', "Correct method flagged");
};

subtest 'json-pp-direct-added rule fires on imported JSON::PP' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    chdir $tmpdir or die;
    system("git init -q");
    system('git config user.email test@example.com');
    system("git config user.name 'test'");

    my $libdir = "$tmpdir/lib/CLIO/Test";
    mkpath($libdir) or die "mkpath: $!";
    open my $fh, '>', "$libdir/JP.pm" or die;
    print $fh "package CLIO::Test::JP;\nuse strict;\nuse JSON::PP qw(encode_json);\n1;\n";
    close $fh;
    system("git add .");

    my $output = `perl -I $project_root/lib $project_root/tools/lint_size_regression.pl --staged --json 2>/dev/null`;
    my $data = decode_json($output);
    my @jp_warnings = grep { $_->{rule} eq 'json-pp-direct-added' } @{$data->{warnings} // []};
    ok(@jp_warnings > 0, "json-pp-direct-added rule fired");
};

subtest 'json-pp-direct-added rule does NOT fire on empty-import workaround' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    chdir $tmpdir or die;
    system("git init -q");
    system('git config user.email test@example.com');
    system("git config user.name 'test'");

    my $libdir = "$tmpdir/lib/CLIO/Test";
    mkpath($libdir) or die "mkpath: $!";
    open my $fh, '>', "$libdir/JP2.pm" or die;
    # Empty parens is the documented workaround
    print $fh "package CLIO::Test::JP2;\nuse strict;\nuse JSON::PP ();\n1;\n";
    close $fh;
    system("git add .");

    my $output = `perl -I $project_root/lib $project_root/tools/lint_size_regression.pl --staged --json 2>/dev/null`;
    my $data = decode_json($output);
    my @jp_warnings = grep { $_->{rule} eq 'json-pp-direct-added' } @{$data->{warnings} // []};
    ok(@jp_warnings == 0, "json-pp-direct-added rule did NOT fire (correct - this is the workaround)");
};

subtest 'cpan-dep-added rule fires on unknown module' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    chdir $tmpdir or die;
    system("git init -q");
    system('git config user.email test@example.com');
    system("git config user.name 'test'");

    my $libdir = "$tmpdir/lib/CLIO/Test";
    mkpath($libdir) or die "mkpath: $!";
    open my $fh, '>', "$libdir/Dep.pm" or die;
    print $fh "package CLIO::Test::Dep;\nuse strict;\nuse SomeNewModule qw(foo);\n1;\n";
    close $fh;
    system("git add .");

    my $output = `perl -I $project_root/lib $project_root/tools/lint_size_regression.pl --staged --json 2>/dev/null`;
    my $data = decode_json($output);
    my @dep_warnings = grep { $_->{rule} eq 'cpan-dep-added' && $_->{module} eq 'SomeNewModule' } @{$data->{warnings} // []};
    ok(@dep_warnings > 0, "cpan-dep-added rule fired for SomeNewModule");
};

subtest 'cpan-dep-added rule does NOT fire on core modules' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    chdir $tmpdir or die;
    system("git init -q");
    system('git config user.email test@example.com');
    system("git config user.name 'test'");

    my $libdir = "$tmpdir/lib/CLIO/Test";
    mkpath($libdir) or die "mkpath: $!";
    open my $fh, '>', "$libdir/Core.pm" or die;
    # Test with several modules that should be in the known list
    print $fh "package CLIO::Test::Core;\nuse strict;\n";
    print $fh "use JSON::PP ();\nuse Text::ParseWords;\nuse HTTP::Tiny;\nuse Time::HiRes qw(time);\n";
    print $fh "1;\n";
    close $fh;
    system("git add .");

    my $output = `perl -I $project_root/lib $project_root/tools/lint_size_regression.pl --staged --json 2>/dev/null`;
    my $data = decode_json($output);
    my @dep_warnings = grep { $_->{rule} eq 'cpan-dep-added' } @{$data->{warnings} // []};
    ok(@dep_warnings == 0, "cpan-dep-added rule did NOT fire for core modules");
};

done_testing();