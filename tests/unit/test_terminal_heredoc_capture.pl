#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Tests for heredoc-safe command execution and shell syntax pre-flight.
#
# Background: captured mode wrapped commands as "($command) > $log 2>&1" and
# passthrough as "$command 2>&1 | tee $log". Both append text to whatever the
# command's final line is, so a command ending in a heredoc terminator stopped
# having that terminator alone on its line. The heredoc then ran to end of
# input. Captured mode failed with a shell syntax error and never created the
# log file, so the agent got no output to reason about. Passthrough fed
# "EOF 2>&1 | tee /tmp/..." into the child program's stdin, reporting the
# failure as a bug in the agent's script.
#
# Captured mode now dup2s the log onto stdout/stderr and execs the command
# verbatim; passthrough groups with braces and closes on its own line. A
# parse-only `sh -n` pre-flight rejects unparseable commands before anything
# runs, and a structural check catches missing heredoc terminators that
# neither shell reports as an error.

use strict;
use warnings;
use utf8;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";

use CLIO::Tools::TerminalOperations;
use CLIO::Util::ShellSyntax qw(check_shell_syntax find_heredoc_defect);

my $tool = CLIO::Tools::TerminalOperations->new();
ok(defined $tool, 'TerminalOperations constructs');

# Pull the text out of a result regardless of output shape.
sub out_text {
    my ($r) = @_;
    return '' unless $r;
    my $o = $r->{output};
    return ref($o) eq 'HASH' ? ($o->{text} // '') : ($o // '');
}

# ─────────────────────────────────────────────────────────────
# Regression: captured mode must not corrupt trailing heredocs
# ─────────────────────────────────────────────────────────────
{
    my $cmd = "cat <<EOF\nalpha\nbeta\nEOF";
    my $r = $tool->execute_command({ operation => 'exec', command => $cmd });
    ok($r->{success}, 'heredoc command succeeds in captured mode');
    like(out_text($r), qr/alpha\nbeta/, 'heredoc body reached stdout');
    unlike(out_text($r), qr/syntax error/, 'no shell syntax error leaked');
}

# A heredoc whose body is a program with shell-significant characters.
{
    my $cmd = "wc -l <<'END'\na (b) c\nx; y & z\n'quoted'\nEND";
    my $r = $tool->execute_command({ operation => 'exec', command => $cmd });
    ok($r->{success}, 'quoted heredoc with metacharacters succeeds');
    like(out_text($r), qr/^\s*3\b/m, 'wc counted the three body lines');
}

# Trailing comment: the old wrapper put ") > log 2>&1" inside the comment.
{
    my $r = $tool->execute_command({
        operation => 'exec',
        command   => 'echo captured-output # trailing note',
    });
    ok($r->{success}, 'command ending in a comment succeeds');
    like(out_text($r), qr/captured-output/, 'output captured despite trailing comment');
}

# Multi-line command with a heredoc in the middle, more after it.
{
    my $cmd = "total=0\nwhile read -r n; do total=\$((total+n)); done <<'NUMS'\n1\n2\n3\nNUMS\necho \"sum=\$total\"";
    my $r = $tool->execute_command({ operation => 'exec', command => $cmd });
    ok($r->{success}, 'multi-line command with mid heredoc succeeds');
    like(out_text($r), qr/sum=6/, 'heredoc fed the loop correctly');
}

# ─────────────────────────────────────────────────────────────
# Passthrough wrap must be heredoc- and comment-safe
# ─────────────────────────────────────────────────────────────
{
    my $log = '/tmp/clio_test_pt.log';
    unlink $log;

    my $wrapped = CLIO::Tools::TerminalOperations::_passthrough_wrap(
        "cat <<EOF\nline-one\nEOF", $log
    );
    like($wrapped, qr/\n\} 2>&1 \| tee /, 'closing brace sits on its own line');

    # Execute the wrap for real: the terminator must stay alone.
    my $got = `$wrapped 2>&1`;
    like($got, qr/line-one/, 'passthrough wrap runs heredoc command');
    unlike($got, qr/SyntaxError|syntax error/, 'passthrough wrap produces no syntax error');
    unlink $log;

    # Trailing comment must not swallow the pipeline.
    my $w2 = CLIO::Tools::TerminalOperations::_passthrough_wrap('echo pt-out # note', $log);
    my $got2 = `$w2 2>&1`;
    like($got2, qr/pt-out/, 'passthrough wrap survives trailing comment');
    unlink $log;

    # A path with a single quote must not break out of the tee argument.
    my $tricky = "/tmp/clio_'rm'-test.log";
    my $w3 = CLIO::Tools::TerminalOperations::_passthrough_wrap('echo safe', $tricky);
    my $got3 = `$w3 2>&1`;
    like($got3, qr/safe/, 'log path with single quotes still runs the command');
    ok(-f $tricky, 'log written to path containing single quotes');
    unlink $tricky;
}

# ─────────────────────────────────────────────────────────────
# stdin parameter removes the need for heredocs
# ─────────────────────────────────────────────────────────────
{
    my $r = $tool->execute_command({
        operation => 'exec',
        command   => 'tr a-z A-Z',
        stdin     => "hello world\nsecond line\n",
    });
    ok($r->{success}, 'stdin parameter command succeeds');
    like(out_text($r), qr/HELLO WORLD/, 'stdin content reached the command');
    like(out_text($r), qr/SECOND LINE/, 'all stdin lines delivered');
}

# A payload with no trailing newline must still be readable in full.
{
    my $r = $tool->execute_command({
        operation => 'exec',
        command   => 'cat',
        stdin     => 'from-stdin',
    });
    like(out_text($r), qr/from-stdin/, 'stdin delivered without trailing newline');
}

# stdin must not leak the temp file afterwards.
{
    my $before =()= glob('/tmp/clio_stdin_*');
    my $r = $tool->execute_command({
        operation => 'exec',
        command   => 'cat',
        stdin     => 'cleanup-check',
    });
    ok($r->{success}, 'stdin command ran');
    my @after = glob('/tmp/clio_stdin_*');
    is(scalar(@after), $before, 'stdin temp file cleaned up');
}

# ─────────────────────────────────────────────────────────────
# Pre-flight: unparseable commands are rejected before running
# ─────────────────────────────────────────────────────────────
{
    my $marker = '/tmp/clio_preflight_marker';
    unlink $marker;

    my $r = $tool->execute_command({
        operation => 'exec',
        # Flattened heredoc: body on the marker line, so the shell chokes.
        command   => "touch $marker; python3 - <<'EOF' import os print(1)",
    });
    ok(!$r->{success}, 'flattened heredoc rejected');
    like($r->{error}, qr/could not parse it/, 'error explains parse failure');
    ok(!-f $marker, 'nothing executed when pre-flight rejects');
    unlink $marker;
}

{
    my $r = $tool->execute_command({
        operation => 'exec',
        command   => 'echo $(find /tmp',
    });
    ok(!$r->{success}, 'unclosed command substitution rejected');
    like($r->{error}, qr/Hint:/, 'actionable hint supplied');
}

{
    my $r = $tool->execute_command({
        operation => 'exec',
        command   => q{echo "unclosed quote},
    });
    ok(!$r->{success}, 'unclosed quote rejected');
}

# Pre-flight must not reject legitimate commands.
{
    for my $cmd (
        'echo hello',
        'ls -la | grep -E "^d" | head -3',
        "cat <<EOF\nbody\nEOF",
        "sh <<-TERM\n\techo indented\n\tTERM",
        'echo $((1<<3))',
        'grep x <<< "hello"',
        'if true; then echo yes; fi',
        'T=$(find /tmp -name "*.py" | head -1); echo done',
    ) {
        my $r = $tool->validate_command({ command => $cmd });
        ok($r->{success}, "valid command allowed: " . ($cmd =~ s/\n/\\n/gr));
    }
}

# ─────────────────────────────────────────────────────────────
# Structural heredoc check (sh -n exits 0 on these)
# ─────────────────────────────────────────────────────────────
{
    my $d = find_heredoc_defect("python3 - <<EOF\nimport os\nprint(1)");
    ok($d, 'missing terminator detected structurally');
    like($d->{error}, qr/never terminated/, 'reports missing terminator');

    my $f = find_heredoc_defect("python3 - <<'EOF' import os print(1)");
    ok($f && $f->{flattened}, 'flattened body flagged');

    ok(!find_heredoc_defect("cat <<EOF\nbody\nEOF"), 'well-formed heredoc clean');
    ok(!find_heredoc_defect('echo $((1<<3))'), 'arithmetic shift not a heredoc');
    ok(!find_heredoc_defect('echo "text << NOPE"'), 'quoted << not a heredoc');
    ok(!find_heredoc_defect('grep x <<< here'), 'here-string not a heredoc');
    ok(!find_heredoc_defect("cat <<A <<B > /dev/null\nfoo\nA\nbar\nB"), 'two heredocs on one line');
    ok(!find_heredoc_defect("sh <<-T\n\tx\n\tT"), '<<- accepts tab-indented terminator');
}

# check_shell_syntax surfaces the structural defect even when sh exits 0.
{
    my $r = check_shell_syntax("python3 - <<EOF\nimport os\nprint(1)");
    ok($r, 'check_shell_syntax blocks unterminated heredoc despite clean parse');
}

done_testing();
