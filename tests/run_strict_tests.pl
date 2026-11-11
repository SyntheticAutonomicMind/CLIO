#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# run_strict_tests.pl - Run the unit test suite under -W and report the
# warnings each test emits, kept separate from whether the test passed.
#
# Usage:
#   perl tests/run_strict_tests.pl                     # all tests/unit/*.pl
#   perl tests/run_strict_tests.pl tests/unit/t.pl ... # a subset
#
# Options:
#   --fatal              Report warning-only tests as failures (exit 1
#                        instead of 2). The child still runs to completion,
#                        so every warning in the file is reported rather than
#                        only the first.
#   --verbose            One line per test, clean ones included.
#   --quiet              Verdict line plus new warnings only.
#   --strict-redefine    Also flag "Subroutine ... redefined".
#   --timeout=N          Seconds per test before the process group is
#                        killed (default 120, 0 disables). Matches
#                        run_all_tests.pl: several tests deliberately
#                        fork, sleep, and get killed to prove cleanup
#                        works, so a short budget reports them as hung.
#   --full               Print failure evidence without truncation.
#   --json               Emit one JSON object instead of prose.
#   --baseline[=PATH]    Report only warnings absent from a recorded set.
#                        Defaults to tests/.strict-baseline.json.
#   --update-baseline    Record the current warning set, then exit.
#   --help, -h
#
# Exit codes:
#   0  every test passed and no new CLIO warnings
#   1  a test broke: non-zero exit, hung, missing, or --fatal escalation
#   2  every test passed but CLIO warnings were found
#
# Output contract:
#   stdout carries findings and the summary. Test stdout and stderr are
#   captured per test and discarded unless that test needs reporting, so a
#   clean run is a handful of lines rather than the whole suite's chatter.
#   Progress goes to stderr and only when stderr is a terminal; a captured
#   run therefore contains nothing but findings.
#   The last line is always machine-checkable:
#     STRICT VERDICT total=N clean=N warn=N broken=N hung=N missing=N
#                warnings=N new=N known=N vendor=N exit=N
#
# Warning provenance:
#   A warning is attributed to vendor when it names a system or CPAN perl
#   tree, and to CLIO otherwise. Warnings inside perl core count as CLIO:
#   core modules such as lib.pm report the undef they were handed, not the
#   caller that handed it, so excluding them would hide real defects. The
#   rules match the previous implementation so historical counts stay
#   comparable. Vendor warnings are informational and never affect the exit
#   code.
#
# Why this exists:
#   CLIO enables `use warnings;` per the module template, but a warning only
#   fires when the offending path executes. A slash-only regression in
#   CommandHandler shipped despite a passing suite because no test exercised
#   `/` with no trailing token. This harness re-runs every test under
#   `perl -W`, captures stderr, and attributes each warning to a file and
#   line. It answers two questions that must not be conflated: did the test
#   pass, and did the code warn.

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

# Findings must reach a reader tailing the output of a background run, and
# stdout is block-buffered whenever it is a file or pipe.
$| = 1;

use File::Basename qw(dirname);
use Cwd qw(abs_path);
use File::Temp qw(tempfile);
use File::Spec;
use Getopt::Long qw(GetOptions);
use POSIX qw(setpgid :sys_wait_h);
use Time::HiRes qw(time);

my $repo_root = abs_path(dirname(dirname(__FILE__)));
$repo_root = abs_path('.') unless -d "$repo_root/lib";

# Runtime, not `use lib`: a BEGIN-time lib import would see $repo_root
# undef, since the assignment above only runs after compilation.
unshift @INC, "$repo_root/lib";
require CLIO::Util::JSON;

my $BASELINE_FILE  = "$repo_root/tests/.strict-baseline.json";
my $BASELINE_VER   = 1;
my $EVIDENCE_LINES = 12;

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------

# Same budget as run_all_tests.pl. Tests that exercise terminal kills and
# rate-limit backoff sleep for tens of seconds on purpose.
my %opt = (
    fatal           => 0,
    verbose         => 0,
    quiet           => 0,
    strict_redefine => 0,
    timeout         => 120,
    full            => 0,
    json            => 0,
    baseline        => undef,
    baseline_path   => $BASELINE_FILE,
);

sub usage {
    my $fh = $_[0] || *STDOUT;
    print {$fh} "Usage: $0 [options] [test.pl ...]\n",
        "  --fatal              report warning-only tests as failures\n",
        "  --verbose            one line per test, clean ones included\n",
        "  --quiet              verdict line plus new warnings only\n",
        "  --strict-redefine    also flag redefined subroutines\n",
        "  --timeout=N          seconds per test before kill (default 120, 0 off)\n",
        "  --full               do not truncate failure evidence\n",
        "  --json               emit one JSON object instead of prose\n",
        "  --baseline[=PATH]    report only warnings absent from a baseline\n",
        "  --update-baseline    record the current warning set and exit\n",
        "Exit: 0 clean, 1 broken/hung/missing, 2 warnings found\n";
}

GetOptions(
    'fatal'           => \$opt{fatal},
    'verbose'         => \$opt{verbose},
    'quiet'           => \$opt{quiet},
    'strict-redefine' => \$opt{strict_redefine},
    'timeout=i'       => \$opt{timeout},
    'full'            => \$opt{full},
    'json'            => \$opt{json},
    'baseline:s'      => \$opt{baseline},
    'update-baseline' => \my $update_baseline,
    'help|h'          => sub { usage(); exit 0 },
) or do { usage(*STDERR); exit 1 };

# --baseline with no value keeps the default path; with a value it overrides.
$opt{baseline} = 0 unless defined $opt{baseline};
if ($opt{baseline} && $opt{baseline} ne '') {
    $opt{baseline_path} = abs_path($opt{baseline}) || $opt{baseline};
    $opt{baseline} = 1;
}

# ---------------------------------------------------------------------------
# Targets
# ---------------------------------------------------------------------------

my @targets = @ARGV;

if (!@targets) {
    my $unit_dir = "$repo_root/tests/unit";
    opendir my $dh, $unit_dir or die "Cannot open $unit_dir: $!\n";
    @targets = sort grep { /\.pl$/ && -f "$unit_dir/$_" } readdir($dh);
    closedir $dh;
}

# Entries may be bare filenames, repo-relative paths, or absolute paths.
my $unit_dir = "$repo_root/tests/unit";
@targets = map {
      File::Spec->file_name_is_absolute($_) ? $_
    : -f $_                                 ? abs_path($_)
    : -f "$repo_root/$_"                    ? abs_path("$repo_root/$_")
    : -f "$unit_dir/$_"                     ? abs_path("$unit_dir/$_")
    :                                         $_
} @targets;

# ---------------------------------------------------------------------------
# Warning patterns and provenance
# ---------------------------------------------------------------------------

my @warning_patterns = (
    [qr/\bUse of uninitialized value\b/, 'uninitialized'],
    [qr/\bWide character in\b/,          'wide-character'],
    [qr/\bSubroutine .* redefined\b/,    'redefined-sub'],
);
@warning_patterns = grep { $_->[1] ne 'redefined-sub' } @warning_patterns
    unless $opt{strict_redefine};

sub strip_ansi {
    my $s = shift;
    $s =~ s/\e\[[0-9;]*m//g;
    return $s;
}

# Provenance rules preserved from the previous implementation.
sub is_vendor_line {
    my ($line) = @_;
    return 1 if $line =~ m{/System/Library/Perl/};
    return 1 if $line =~ m{/Library/Perl/};
    return 1 if $line =~ m{\.cpan\b|/\.cpan/};
    return 1 if $line =~ m{at\s+\S*perl/\S+/\S+\.pm\s+line\s+\d+};
    return 0;
}

# Turn "at lib/CLIO/Foo/Bar.pm line 42." into "lib/CLIO/Foo/Bar.pm:42" so the
# report is directly navigable, relative to the repo root.
sub warning_location {
    my ($line) = @_;
    if ($line =~ m{\bat\s+(\S+?)\s+line\s+(\d+)}) {
        my ($file, $lineno) = ($1, $2);
        $file =~ s{^\Q$repo_root\E/}{};
        return "$file:$lineno";
    }
    return '(unknown location)';
}

sub summarize_warning {
    my ($line) = @_;
    $line =~ s/\s*at\s+\S+\s+line\s+\d+.*$//;
    $line =~ s/^\s+|\s+$//g;
    return $line;
}

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or return '';
    my $text = do { local $/; <$fh> };
    close $fh;
    return defined $text ? $text : '';
}

# ---------------------------------------------------------------------------
# Per-test execution
# ---------------------------------------------------------------------------

# Children run in their own process group so a timeout kills the test and
# everything it forked. Broker tests, MCP stubs, and daemonized helpers
# otherwise outlive their parent and pile up across a long run.
sub run_one_test {
    my ($abs) = @_;

    my (undef, $out_path) = tempfile('strict-out-XXXXXX', TMPDIR => 1, SUFFIX => '.log', UNLINK => 1);
    my (undef, $err_path) = tempfile('strict-err-XXXXXX', TMPDIR => 1, SUFFIX => '.log', UNLINK => 1);

    my @cmd = ($^X, '-I', "$repo_root/lib", '-I', "$repo_root/tests/lib");
    push @cmd, '-W';
    push @cmd, $abs;

    my $pid = fork();
    die "fork failed: $!\n" unless defined $pid;

    if ($pid == 0) {
        setpgid(0, 0) or exit 99;
        open my $ofh, '>', $out_path or exit 99;
        open STDOUT, '>&', $ofh      or exit 99;
        open my $efh, '>', $err_path or exit 99;
        open STDERR, '>&', $efh      or exit 99;
        # Meta tests invoke the suite themselves and skip when they detect a
        # runner above them. Without this a strict run recurses into a full
        # nested suite.
        $ENV{CLIO_TEST_RUNNER_INVOKED} = 1;
        exec { $cmd[0] } @cmd;
        exit 99;
    }

    my $start     = time();
    my $timed_out = 0;
    my $exit_code = 0;

    if ($opt{timeout} > 0) {
        my $deadline    = $start + $opt{timeout};
        my $wait_result = waitpid($pid, WNOHANG);
        while ($wait_result == 0) {
            if (time() >= $deadline) {
                kill('KILL', -$pid);
                $timed_out = 1;
                last;
            }
            select(undef, undef, undef, 0.05);
            $wait_result = waitpid($pid, WNOHANG);
        }
        waitpid($pid, 0) if $wait_result <= 0;
        $exit_code = $timed_out ? 124 : ($? >> 8);
    } else {
        waitpid($pid, 0);
        $exit_code = $? >> 8;
    }

    my $duration = time() - $start;

    return {
        exit     => $exit_code,
        timed    => $timed_out,
        duration => $duration,
        stdout   => slurp($out_path),
        stderr   => slurp($err_path),
    };
}

# ---------------------------------------------------------------------------
# Analysis
# ---------------------------------------------------------------------------

# Groups CLIO-attributed warnings by label then location, so the report names
# the exact place to fix instead of only a count. Returns (\@findings, $vendor).
sub classify_warnings {
    my ($stderr) = @_;
    my (%found, $vendor);
    $vendor = 0;

    for my $pat (@warning_patterns) {
        my ($re, $label) = @$pat;
        for my $line (split /\n/, $stderr) {
            next unless $line =~ m{$re};
            my $clean = strip_ansi($line);
            if (is_vendor_line($clean)) {
                $vendor++;
                next;
            }
            my $loc = warning_location($clean);
            $found{$label} ||= {};
            $found{$label}{$loc} ||= { count => 0, message => summarize_warning($clean) };
            $found{$label}{$loc}{count}++;
        }
    }

    my @findings;
    for my $label (sort keys %found) {
        my @places = map {
            { location => $_, count => $found{$label}{$_}{count}, message => $found{$label}{$_}{message} }
        } sort keys %{ $found{$label} };
        my $count = 0;
        $count += $_->{count} for @places;
        push @findings, { label => $label, count => $count, places => \@places };
    }
    return (\@findings, $vendor);
}

# Failing assertions a test printed without signalling through its exit code
# are still evidence the caller needs.
sub failing_output {
    my ($stdout) = @_;
    my @lines;
    for my $line (split /\n/, $stdout) {
        my $clean = strip_ansi($line);
        next unless $clean =~ /^\s*not ok\b/
                 || $clean =~ /^\s*Bail out!/
                 || $clean =~ /^# Failed test/
                 || $clean =~ /Looks like (?:you planned|tests failed)/;
        $clean =~ s/^\s+//;
        push @lines, $clean;
    }
    return @lines;
}

sub tail_lines {
    my ($text, $max) = @_;
    my @lines = grep { /\S/ } split /\n/, strip_ansi($text);
    return () unless @lines;
    $max = scalar @lines if @lines < $max;
    return @lines[-$max .. -1];
}

# ---------------------------------------------------------------------------
# Baseline
# ---------------------------------------------------------------------------

sub baseline_key {
    my ($rel, $label, $location) = @_;
    return "$rel|$label|$location";
}

sub load_baseline {
    return {} unless $opt{baseline};
    unless (-f $opt{baseline_path}) {
        print STDERR "  ! no baseline at $opt{baseline_path}; create one with --update-baseline\n";
        return {};
    }
    my $data = eval { CLIO::Util::JSON::decode_json(slurp($opt{baseline_path})) };
    if ($@ || ref $data ne 'HASH' || ref $data->{warnings} ne 'HASH') {
        print STDERR "  ! unreadable baseline at $opt{baseline_path}\n";
        return {};
    }
    return $data->{warnings};
}

sub iso_time {
    my @t = gmtime();
    return sprintf '%04d-%02d-%02dT%02d:%02d:%02dZ',
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0];
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

my $total         = scalar @targets;
my $show_progress = -t STDERR && !$opt{json};
# Loading the baseline during an update would warn about the file the update
# is about to write.
my $known = $update_baseline ? {} : load_baseline();

print STDERR "strict: running $total test(s)" . ($opt{fatal} ? " (--fatal: warnings fail)" : '') . "\n"
    if $show_progress;

my @records;
my $index = 0;

for my $abs (@targets) {
    $index++;
    my $rel = $abs;
    $rel =~ s{^\Q$repo_root\E/}{};

    printf STDERR "\r[%*d/%d] %s", length($total), $index, $total, $rel if $show_progress;

    if (!-f $abs) {
        my $record = {
            test => $rel, status => 'missing', exit => -1, duration => 0,
            findings => [], vendor => 0, evidence => ['file not found'],
            new_count => 0, known_count => 0, clio_count => 0,
        };
        push @records, $record;
        emit($record);
        next;
    }

    my $run             = run_one_test($abs);
    my ($findings, $vendor) = classify_warnings($run->{stderr});

    my $clio_count = 0;
    $clio_count += $_->{count} for @$findings;

    # Split each finding's locations into new and baselined.
    my ($new_count, $known_count) = (0, 0);
    for my $f (@$findings) {
        my (@new, @known_here);
        for my $p (@{ $f->{places} }) {
            if ($opt{baseline} && exists $known->{ baseline_key($rel, $f->{label}, $p->{location}) }) {
                push @known_here, $p;
                $known_count += $p->{count};
            } else {
                push @new, $p;
                $new_count += $p->{count};
            }
        }
        $f->{new_places}   = \@new;
        $f->{known_places} = \@known_here;
    }

    my $status = 'clean';
    $status = 'hung'   if $run->{timed};
    $status = 'broken' if !$run->{timed} && $run->{exit} != 0;
    $status = 'warn'   if $status eq 'clean' && $new_count > 0;
    # --fatal escalates a warning-only result to a failure. Making the child
    # die is not reachable from the command line: warnings fatal bits are
    # lexical, so -Mwarnings=FATAL,all never applies to the script under test.
    # Escalating here is also more informative, since the run continues and
    # reports every warning instead of stopping at the first.
    $status = 'broken' if $status eq 'warn' && $opt{fatal};

    # Evidence is collected when the process itself failed. An escalated
    # warning needs no stdout: the warning block already carries the detail.
    my @evidence;
    if ($run->{timed} || $run->{exit} != 0) {
        my @failing = failing_output($run->{stdout});
        if (@failing) {
            push @evidence, map { "stdout: $_" } @failing;
        } else {
            push @evidence, map { "stdout: $_" } tail_lines($run->{stdout}, $EVIDENCE_LINES);
        }
        push @evidence, map { "stderr: $_" } tail_lines($run->{stderr}, 4);
        # A killed process never flushes its block-buffered output, so a hung
        # test usually arrives with nothing to show. Say so instead of
        # presenting an empty block that reads like the test printed nothing.
        if ($status eq 'hung' && !@evidence) {
            push @evidence,
                "no output captured: stdout was buffered when the group was killed",
                sprintf 'rerun alone to see where it blocks: perl -W -Ilib -Itests/lib %s', $rel;
        }
    }

    my $record = {
        test        => $rel,
        status      => $status,
        exit        => $run->{exit},
        duration    => $run->{duration},
        findings    => $findings,
        vendor      => $vendor,
        evidence    => \@evidence,
        new_count   => $new_count,
        known_count => $known_count,
        clio_count  => $clio_count,
    };
    push @records, $record;
    emit($record);
}

print STDERR "\r", (' ' x 78), "\r" if $show_progress;

# ---------------------------------------------------------------------------
# Baseline update
# ---------------------------------------------------------------------------

if ($update_baseline) {
    my %warnings;
    for my $r (@records) {
        next if $r->{status} eq 'missing';
        for my $f (@{ $r->{findings} }) {
            for my $p (@{ $f->{places} }) {
                $warnings{ baseline_key($r->{test}, $f->{label}, $p->{location}) } = $p->{count};
            }
        }
    }
    my $raw = CLIO::Util::JSON::encode_json_pretty({
        version   => $BASELINE_VER,
        generated => iso_time(),
        warnings  => \%warnings,
    });
    open my $fh, '>', $opt{baseline_path} or die "Cannot write $opt{baseline_path}: $!\n";
    print {$fh} $raw;
    close $fh;
    printf "baseline written: %s (%d distinct warning location(s))\n",
        $opt{baseline_path}, scalar keys %warnings;
    exit 0;
}

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------

my %count = (clean => 0, warn => 0, broken => 0, hung => 0, missing => 0);
my ($tot_new, $tot_known, $tot_clio, $tot_vendor) = (0, 0, 0, 0);
for my $r (@records) {
    $count{ $r->{status} }++;
    $tot_new    += $r->{new_count};
    $tot_known  += $r->{known_count};
    $tot_clio   += $r->{clio_count};
    $tot_vendor += $r->{vendor};
}

my $exit_code = 0;
$exit_code = 1 if $count{broken} || $count{hung} || $count{missing};
$exit_code = 2 if !$exit_code && $tot_new;

if ($opt{json}) {
    print CLIO::Util::JSON::encode_json_pretty({
        summary => {
            total    => $total,
            clean    => $count{clean},
            warn     => $count{warn},
            broken   => $count{broken},
            hung     => $count{hung},
            missing  => $count{missing},
            warnings => $tot_clio,
            new      => $tot_new,
            known    => $tot_known,
            vendor   => $tot_vendor,
            exit     => $exit_code,
        },
        baseline => $opt{baseline} ? { enabled => 1, path => $opt{baseline_path} }
                                   : { enabled => 0 },
        tests    => [ map { record_to_json($_) } @records ],
    }), "\n";
    exit $exit_code;
}

# ---------------------------------------------------------------------------
# Verdict line
# ---------------------------------------------------------------------------

# Findings were streamed during the run; only the verdict remains.
printf "\nSTRICT VERDICT total=%d clean=%d warn=%d broken=%d hung=%d missing=%d"
     . " warnings=%d new=%d known=%d vendor=%d exit=%d\n",
    $total, $count{clean}, $count{warn}, $count{broken}, $count{hung},
    $count{missing}, $tot_clio, $tot_new, $tot_known, $tot_vendor, $exit_code;

if (grep { $_->{status} ne 'clean' } @records) {
    print $opt{verbose}
        ? "--full shows untruncated evidence\n"
        : "rerun with --verbose for a line per test, --full for untruncated evidence\n";
}

exit $exit_code;

# ---------------------------------------------------------------------------
# Formatting
# ---------------------------------------------------------------------------

# Streams one test's result as it completes, so a run observed in the
# background reports its first problem immediately instead of at the end.
# JSON mode buffers everything into a single document instead.
sub emit {
    my ($r) = @_;
    return if $opt{json};

    if ($r->{status} eq 'clean') {
        printf "%-7s %-56s %5.2fs\n", 'ok', $r->{test}, $r->{duration} if $opt{verbose};
        return;
    }

    return if $opt{quiet} && $r->{status} eq 'warn' && !$r->{new_count};
    print test_block($r);
}

sub status_word {
    my ($r) = @_;
    return 'FAIL'    if $r->{status} eq 'broken';
    return 'HUNG'    if $r->{status} eq 'hung';
    return 'MISSING' if $r->{status} eq 'missing';
    return 'WARN'    if $r->{status} eq 'warn';
    return 'ok';
}

sub test_block {
    my ($r) = @_;
    my $limit = $opt{full} ? 1_000_000 : $EVIDENCE_LINES;
    my @out;

    my $head = sprintf '%-7s %-56s %5.2fs', status_word($r), $r->{test}, $r->{duration};
    $head .= sprintf ' exit=%d', $r->{exit}
        if $r->{status} eq 'broken' || $r->{status} eq 'hung';
    $head .= sprintf ' warnings=%d new=%d', $r->{clio_count}, $r->{new_count}
        if $r->{clio_count};
    $head .= sprintf ' vendor=%d', $r->{vendor} if $r->{vendor};
    push @out, $head;

    my @ev = @{ $r->{evidence} };
    if (@ev) {
        my $shown = @ev < $limit ? scalar @ev : $limit;
        push @out, map { "  $_" } @ev[0 .. $shown - 1];
        if (@ev > $shown) {
            push @out, sprintf '  (%d more line(s); --full shows all)', scalar(@ev) - $shown;
        }
    }

    for my $f (@{ $r->{findings} }) {
        my @new        = @{ $f->{new_places} };
        my @known_here = @{ $f->{known_places} };
        next unless @new || !@known_here || !$opt{quiet};

        my %is_new = map { $_->{location} => 1 } @new;
        my @places = $opt{quiet} ? @new : (@new, @known_here);

        my $label = sprintf '  %s: %d new', $f->{label}, scalar @new;
        $label .= sprintf(', %d baselined', scalar @known_here) if @known_here;
        push @out, $label;

        my $shown = @places < $limit ? scalar @places : $limit;
        for my $p (@places[0 .. $shown - 1]) {
            push @out, sprintf '    %-5s %s  %s',
                ($is_new{ $p->{location} } ? 'NEW' : 'known'),
                $p->{location}, $p->{message};
            if ($p->{count} > 1) {
                push @out, sprintf '         (%d occurrence(s))', $p->{count};
            }
        }
        if (@places > $shown) {
            push @out, sprintf '    (%d more location(s); --full shows all)', scalar(@places) - $shown;
        }
    }

    if ($r->{vendor} && !$opt{quiet}) {
        push @out, sprintf '  vendor warnings: %d (informational)', $r->{vendor};
    }

    return join("\n", @out) . "\n";
}

sub record_to_json {
    my ($r) = @_;
    return {
        test     => $r->{test},
        status   => $r->{status},
        exit     => $r->{exit} + 0,
        duration => 0 + sprintf('%.3f', $r->{duration}),
        vendor   => $r->{vendor} + 0,
        new      => $r->{new_count} + 0,
        known    => $r->{known_count} + 0,
        evidence => [ @{ $r->{evidence} } ],
        warnings => [
            map {
                my $f      = $_;
                my %is_new = map { $_->{location} => 1 } @{ $f->{new_places} || [] };
                {
                    label  => $f->{label},
                    count  => $f->{count} + 0,
                    places => [
                        map {
                            {
                                location => $_->{location},
                                count    => $_->{count} + 0,
                                message  => $_->{message},
                                new      => ($is_new{ $_->{location} } ? 1 : 0),
                            }
                        } @{ $f->{places} }
                    ],
                }
            } @{ $r->{findings} }
        ],
    };
}
