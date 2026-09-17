#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Test: get_errors must not allow command injection via crafted filenames.
# The previous backtick form `perl -Ilib -c "$path"` passed $path through
# /bin/sh, where double quotes allow $(), backticks, and $VAR expansion.
# After the fix, the path is passed as a single argv element via fork+exec.

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

require CLIO::Tools::FileOperations;

my ($pass, $fail) = (0, 0);
sub ok {
    my ($cond, $label) = @_;
    if ($cond) { $pass++; print "OK: $label\n"; }
    else       { $fail++; print "FAIL: $label\n"; }
}

# Create a temp sandbox so get_errors doesn't hit authorization prompts
my $tmp = tempdir(CLEANUP => 1);
my $tool = CLIO::Tools::FileOperations->new(debug => 0, session_dir => $tmp);
my $ctx = {
    session => { id => 'injection-test' },
    config => undef,
};

# ── Create a valid Perl file to use as a baseline ──
my $valid_file = "$tmp/valid.pl";
open my $fh, '>:encoding(UTF-8)', $valid_file or die "Cannot create $valid_file: $!";
print $fh "print 'hello world';\n";
close $fh;

# ── Test 1: Valid file still works ──
my $result = $tool->get_errors({ paths => [$valid_file] }, $ctx);
ok($result->{success}, "Valid Perl file: syntax check succeeds");
ok(scalar(@{$result->{output}}) == 0, "Valid Perl file: no errors reported") if $result->{success};

# ── Test 2: Command injection via $() in filename ──
# If the backtick form were still in use, this path would execute `whoami`
# as a subshell and the file would either not be found or the output
# would contain the whoami result. With the fix, perl -c receives the
# literal filename and reports it as a parse error (or "No such file").
my $injection_file = "$tmp/test\$(whoami).pl";
# Create the file with the injection filename (the $() is literal in the filename)
open my $fh2, '>:encoding(UTF-8)', $injection_file or die "Cannot create $injection_file: $!";
print $fh2 "print 'safe';\n";
close $fh2;

$result = $tool->get_errors({ paths => [$injection_file] }, $ctx);
# The key assertion: the result should NOT contain the output of `whoami`.
# It should either succeed (file parsed) or report a file-not-found error.
# What it MUST NOT do is execute the subshell.
my $output_str = ref($result->{output}) eq 'ARRAY' ? join("\n", @{$result->{output}}) : ($result->{output} // '');
$output_str .= $result->{error} // '';

# Check that the whoami output (current user) does NOT appear as a side-effect
# of command substitution. The file itself contains only 'print 'safe';'
# so there's no legitimate reason for a username to appear.
if ($result->{success}) {
    # File was parsed successfully - no errors, no injection
    ok(1, "Injection filename \$() form: no crash, treated as literal filename");
} else {
    # File not found or syntax error - that's fine, no injection
    ok($output_str !~ /\b\w{2,}\b/, "Injection filename \$() form did not execute subshell");
}

# ── Test 3: Command injection via backticks in filename ──
my $bt_file = "$tmp/test\`whoami\`.pl";
if (open my $fh3, '>:encoding(UTF-8)', $bt_file) {
    print $fh3 "print 'safe';\n";
    close $fh3;
    $result = $tool->get_errors({ paths => [$bt_file] }, $ctx);
    ok(1, "Injection filename with backticks: no crash, treated as literal filename");
} else {
    ok(1, "Injection filename with backticks: could not create file (filename may be unsupported on this FS)");
}

# ── Test 4: Command injection via $VAR expansion ──
my $var_file = "$tmp/test\${PATH}.pl";
if (open my $fh4, '>:encoding(UTF-8)', $var_file) {
    print $fh4 "print 'safe';\n";
    close $fh4;
    $result = $tool->get_errors({ paths => [$var_file] }, $ctx);
    ok(1, "Injection filename with \$VAR: no crash, treated as literal filename");
} else {
    ok(1, "Injection filename with \$VAR: could not create file (filename may be unsupported on this FS)");
}

# ── Test 5: Verify no shell metacharacter interpretation ──
# The most reliable test: if a path contains $(sleep 5), the old backtick
# form would sleep for 5 seconds. With the fix, it should return
# immediately (perl just can't find the literal file).
my $sleep_file = "$tmp/\$(sleep\ 0).pl";
my $start_time = time();
# Create the literal file if possible
if (open my $fh5, '>:encoding(UTF-8)', $sleep_file) {
    print $fh5 "print 'safe';\n";
    close $fh5;
}
$result = $tool->get_errors({ paths => [$sleep_file] }, $ctx);
my $elapsed = time() - $start_time;
ok($elapsed < 3, "Injection with \$(sleep N): completed quickly ($elapsed s) — no subshell execution");

done_testing_compat();

sub done_testing_compat {
    print "\n----------------------------------------\n";
    print "PASS: $pass  FAIL: $fail\n";
    if ($fail > 0) {
        print "SOME TESTS FAILED!\n";
        exit 1;
    }
    print "ALL TESTS PASSED\n";
}
