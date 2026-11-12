# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Util::ShellSyntax;

use strict;
use warnings;
use utf8;
use POSIX qw(WNOHANG :signal_h);
use Time::HiRes ();
use File::Temp qw(tempfile);
use CLIO::Core::Logger qw(log_debug);

=head1 NAME

CLIO::Util::ShellSyntax - Parse-only validation of shell command strings

=head1 DESCRIPTION

Runs the shell's own parser (C<sh -n>) over a command string before it is
executed. The shell reads and parses the input but performs no command
execution, so the check has no side effects and completes in a few
milliseconds.

Validating with the same interpreter that will run the command means the
check cannot disagree with execution: anything C<sh -n> rejects, C<sh -c>
would also reject.

On failure the module returns the parser's message plus an advisory hint
when the failure matches a known shape. The most common shape is a heredoc
whose body and terminator never made it onto their own lines, which happens
when a model emits a multi-line command and the newlines are lost in transit.

The check never rejects a command on its own judgement. A return value of
C<undef> means "ok, or could not determine" - if the shell cannot be located,
fork fails, or the parser times out, the command is allowed through and the
condition is logged at debug level.

=head1 SYNOPSIS

    use CLIO::Util::ShellSyntax qw(check_shell_syntax);

    my $problem = check_shell_syntax($command);
    if ($problem) {
        print "Bad syntax: $problem->{error}\n";
        print "Hint: $problem->{hint}\n" if $problem->{hint};
    }

=cut

use Exporter 'import';
our @EXPORT_OK = qw(check_shell_syntax find_shell find_heredoc_defect);

# Parsing is a single-process operation. A pathological input should not be
# able to hold up a tool call, so give it a short leash.
my $CHECK_TIMEOUT = 5;

=head2 find_shell

Returns the path to the POSIX shell that will execute commands, or undef if
none is available. Matches the interpreter used by
L<CLIO::Tools::TerminalOperations> so parse results agree with execution.

Arguments: none
Returns: path string, or undef

=cut

sub find_shell {
    if ($^O eq 'MSWin32') {
        for my $dir (split /;/, $ENV{PATH} || '') {
            my $bash = "$dir\\bash.exe";
            return $bash if -x $bash;
        }
        return undef;
    }
    return -x '/bin/sh' ? '/bin/sh' : undef;
}

=head2 check_shell_syntax

Parses a command string without executing it.

Arguments:
    $command - Shell command string (may be multi-line)
    %opts    - Optional: shell => path override

Returns: undef when the command parses (or the check could not run),
otherwise a hashref with:
    error - the shell parser's message, newlines trimmed
    hint  - advisory text for known failure shapes (may be empty)

=cut

sub check_shell_syntax {
    my ($command, %opts) = @_;

    return undef unless defined $command && length $command;

    my $shell = $opts{shell} // find_shell();
    unless ($shell) {
        log_debug('ShellSyntax', 'No POSIX shell found - skipping syntax check');
        return undef;
    }

    # Write to a file rather than passing via -c so the parser reports real
    # line numbers and so no quoting layer can alter the command under test.
    my ($tfh, $tfile) = tempfile('clio_synchk_XXXXXX', TMPDIR => 1, UNLINK => 1);
    unless ($tfh) {
        log_debug('ShellSyntax', "Cannot create temp file - skipping check: $!");
        return undef;
    }
    my $raw = $command;
    utf8::encode($raw) if utf8::is_utf8($raw);
    print {$tfh} $raw;
    # A command not ending in a newline can make the parser report the last
    # construct as unterminated when it is only truncated.
    print {$tfh} "\n" unless substr($command, -1) eq "\n";
    close $tfh;

    my ($rh, $wh);
    pipe($rh, $wh) or do {
        log_debug('ShellSyntax', "pipe() failed - skipping check: $!");
        return undef;
    };

    my $pid = fork();
    unless (defined $pid) {
        close $rh; close $wh;
        log_debug('ShellSyntax', "fork() failed - skipping check: $!");
        return undef;
    }

    if ($pid == 0) {
        close $rh;
        # Own process group so a stuck parser can be killed without touching CLIO.
        eval { POSIX::setpgid(0, 0) };
        open(STDOUT, '>&', $wh) or POSIX::_exit(127);
        open(STDERR, '>&', $wh) or POSIX::_exit(127);
        close $wh;
        open(STDIN, '<', '/dev/null');
        exec($shell, '-n', $tfile) or POSIX::_exit(127);
    }

    close $wh;

    my $output = '';
    my $start  = Time::HiRes::time();
    my $status;

    while (1) {
        # Drain the pipe as we go; a full pipe buffer would deadlock the child.
        my $rin = '';
        vec($rin, fileno($rh), 1) = 1;
        my $remaining = $CHECK_TIMEOUT - (Time::HiRes::time() - $start);
        last if $remaining <= 0;
        if (select(my $rs = $rin, undef, undef, $remaining > 0.2 ? 0.2 : $remaining)) {
            my $chunk;
            my $n = sysread($rh, $chunk, 8192);
            if (defined $n && $n > 0) {
                $output .= $chunk;
            }
        }

        my $w = waitpid($pid, WNOHANG);
        if ($w > 0) {
            $status = $?;
            # The child has exited, so its end of the pipe is closed and these
            # reads cannot block. Collect whatever it wrote just before dying.
            while (1) {
                my $chunk;
                my $n = sysread($rh, $chunk, 8192);
                last unless defined $n && $n > 0;
                $output .= $chunk;
            }
            last;
        }
        if ($w < 0) {
            close $rh;
            log_debug('ShellSyntax', "waitpid failed - skipping check: $!");
            return undef;
        }
    }

    close $rh;

    unless (defined $status) {
        eval { POSIX::kill(SIGKILL, $pid) };
        waitpid($pid, 0);
        log_debug('ShellSyntax', "Syntax check timed out after ${CHECK_TIMEOUT}s - allowing command");
        return undef;
    }

    my $exit_code = $status >> 8;

    if ($exit_code == 0) {
        # The parser accepted the command. A heredoc running to end-of-input
        # without its terminator parses fine on dash and warns at most on bash,
        # so verify structure before clearing the command.
        my $defect = find_heredoc_defect($command);
        return $defect if $defect;
        return undef;
    }

    # Strip the temp filename from parser output; it is noise to the agent.
    $output =~ s/\Q$tfile\E/shell-command/g;
    $output =~ s/\r+\n/\n/g;
    my @lines = grep { /\S/ } split /\n/, $output;
    my $error = @lines ? join(' | ', @lines) : "shell rejected the command (exit $exit_code)";

    log_debug('ShellSyntax', "Syntax error detected: $error");

    return {
        error => $error,
        hint  => _hint_for($command, $output),
    };
}

=head2 find_heredoc_defect

Structural check for a heredoc whose body or terminator never materialised.

Neither shell reports this reliably: dash parses a heredoc that runs to
end-of-input without complaint and exits 0, and bash emits only a warning.
The command then executes and feeds the program a truncated body, so the
failure is silent rather than loud.

The check walks the command tracking quote and comment state, collects each
heredoc introducer, and confirms a matching terminator line exists.

Arguments:
    $command - Shell command string (may be multi-line)

Returns: undef when every heredoc is properly terminated, otherwise a
hashref with error, hint, and flattened (true when body text ended up on the
marker's own line).

=cut

sub find_heredoc_defect {
    my ($command) = @_;
    return undef unless defined $command && length $command;
    return undef unless $command =~ /<</;

    my @lines = split /\n/, $command, -1;

    my @pending;      # heredocs opened on the current line, awaiting bodies
    my $open;         # heredoc currently consuming body lines

    for my $idx (0 .. $#lines) {
        my $line = $lines[$idx];

        if ($open) {
            my $probe = $line;
            $probe =~ s/^\t+// if $open->{striptabs};
            if ($probe eq $open->{word}) {
                $open = @pending ? shift(@pending) : undef;
            }
            next;     # body lines are data, never syntax
        }

        my @found = _heredoc_markers_on($line);
        next unless @found;

        @pending = @found;
        $open = shift @pending;
        $open->{line} = $idx;
    }

    return undef unless $open;

    my $word = $open->{word};
    my $line_no = $open->{line} + 1;

    my ($error, $hint);
    if ($open->{flattened}) {
        $error = "line $line_no: heredoc '<<$word' has its body on the same line";
        $hint  = "This command uses a heredoc but the body text sits on the "
               . "'<<$word' line instead of the lines below it, which means the "
               . "literal newlines were lost before the command reached the "
               . "shell. Newlines inside tool-call strings must be sent as "
               . "escaped \\n. The most reliable fix is the 'stdin' parameter of "
               . "terminal_operations, which feeds a program's input without any "
               . "heredoc; alternatively write the script with file_operations "
               . "and run it by path.";
    }
    else {
        $error = "line $line_no: heredoc '<<$word' is never terminated";
        $hint  = "No line containing only '$word' follows the '<<$word' marker. "
               . "A heredoc terminator must sit alone on its own line, with no "
               . "trailing characters - not even a redirect or a pipe. When "
               . "using '<<-' the terminator may be indented with tabs.";
    }

    return { error => $error, hint => $hint, flattened => $open->{flattened} };
}

# Locate heredoc introducers on a single line, ignoring those inside quotes,
# comments, arithmetic expressions, and here-strings (<<<).
sub _heredoc_markers_on {
    my ($line) = @_;
    my @found;
    my $n = length $line;
    my $i = 0;
    my ($in_sq, $in_dq, $arith) = (0, 0, 0);

    while ($i < $n) {
        my $c = substr($line, $i, 1);

        if ($in_sq) { $in_sq = 0 if $c eq "'"; $i++; next; }
        if ($in_dq) {
            if    ($c eq "\\") { $i += 2; next; }
            $in_dq = 0 if $c eq '"';
            $i++;
            next;
        }

        # A '#' opens a comment only where a word could begin.
        if ($c eq '#' && ($i == 0 || substr($line, $i - 1, 1) =~ /\s/)) {
            last;
        }
        if ($c eq "'") { $in_sq = 1; $i++; next; }
        if ($c eq '"') { $in_dq = 1; $i++; next; }

        if (substr($line, $i, 3) eq '$((') { $arith = 1; $i += 3; next; }
        if ($arith && substr($line, $i, 2) eq '))') { $arith = 0; $i += 2; next; }

        if (substr($line, $i, 2) eq '<<') {
            # '<<<' is a here-string; it carries no terminator line.
            if (substr($line, $i + 2, 1) eq '<') { $i += 3; next; }
            if ($arith)                          { $i += 2; next; }

            my $j = $i + 2;
            my $striptabs = 0;
            if (substr($line, $j, 1) =~ /[-~]/) { $striptabs = 1; $j++; }
            $j++ while $j < $n && substr($line, $j, 1) =~ /[ \t]/;

            my $quote = '';
            if (substr($line, $j, 1) =~ /['"]/) { $quote = substr($line, $j, 1); $j++; }

            my $word = '';
            $word .= substr($line, $j, 1), $j++
                while $j < $n && substr($line, $j, 1) =~ /[A-Za-z0-9_]/;

            unless (length $word) { $i = $j > $i ? $j : $i + 2; next; }

            if ($quote) {
                if (substr($line, $j, 1) eq $quote) { $j++; }
                else { $i = $j; next; }     # malformed marker, leave it alone
            }

            # Anything after the marker should be a redirect, a pipe, a
            # separator, or a comment. Other text means the body was flattened
            # onto this line.
            my $rest = substr($line, $j);
            my $flattened = ($rest =~ /^[\s]*$/)                                     ? 0
                          : ($rest =~ /^[\s]*(?:\d*>|<|;|\||&|\#)/)                  ? 0
                          : 1;

            push @found, { word => $word, striptabs => $striptabs, flattened => $flattened };
            $i = $j;
            next;
        }

        $i++;
    }

    return @found;
}

# Advisory hints for failure shapes the agent can act on immediately. These
# never decide the verdict; they only explain a failure sh -n already found.
sub _hint_for {
    my ($command, $parser_output) = @_;

    my $defect = find_heredoc_defect($command);
    if ($defect) {
        return $defect->{hint};
    }

    if ($parser_output =~ /unexpected end of file|unexpected EOF/i) {
        if ($parser_output =~ /looking for matching/) {
            return "An opening quote is never closed. Check that quotes inside "
                 . "the command are escaped for JSON and for the shell.";
        }
        return "The command ends inside an unclosed construct (parenthesis, "
             . "brace, or quoted string). Check that every opener has a closer.";
    }

    if ($parser_output =~ /near unexpected token/i) {
        return "The shell cannot parse this command at the reported token. "
             . "If this was meant to be several statements, separate them with "
             . "newlines or ';' rather than spaces.";
    }

    return '';
}

1;

=head1 SEE ALSO

L<CLIO::Tools::TerminalOperations>, which calls this before executing a
command so a syntactically invalid command never reaches the user's system.

=cut
