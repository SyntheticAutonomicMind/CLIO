package CLIO::Logging::ProcessStats;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;
use CLIO::Util::JSON qw(encode_json);
use File::Path qw(make_path);
use File::Spec;
use POSIX qw(strftime);
use Time::HiRes qw(time);
use CLIO::Core::Logger qw(should_log log_debug);

=head1 NAME

CLIO::Logging::ProcessStats - Lightweight process memory and resource tracking

=head1 DESCRIPTION

Captures RSS (resident set size) and VSZ (virtual size) at key lifecycle
points during CLIO execution. Tracks baseline, deltas, and per-phase
memory growth to help identify memory creep over time.

Stats are logged as JSONL to .clio/logs/process_stats_YYYY-MM-DD.log,
one entry per capture point.

No CPAN dependencies - uses ps(1) on macOS/Linux and /proc/self/status
on Linux for zero-overhead reads.

=head1 SYNOPSIS

    use CLIO::Logging::ProcessStats;

    my $stats = CLIO::Logging::ProcessStats->new(
        session_id => 'sess_20260222_074100',
    );

    # Record baseline at session start
    $stats->capture('session_start');

    # Record at iteration boundaries
    $stats->capture('iteration_start', { iteration => 1 });
    $stats->capture('iteration_end',   { iteration => 1, tool_count => 3 });

    # Record after specific tool execution
    $stats->capture('after_tool', { tool_name => 'terminal_operations' });

    # Record at session end
    $stats->capture('session_end');

    # Get current snapshot without logging
    my $snapshot = $stats->snapshot();
    # { rss_kb => 61440, vsz_kb => 421888, rss_mb => 60.0, vsz_mb => 412.0 }

    # Get summary (baseline vs current)
    my $summary = $stats->summary();
    # { baseline_rss_mb => 50.0, current_rss_mb => 60.0, delta_rss_mb => 10.0, ... }

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        session_id    => $args{session_id} || 'unknown',
        debug         => $args{debug} || 0,
        log_dir       => $args{log_dir} || File::Spec->catdir('.clio', 'logs'),
        pid           => $$,
        baseline_rss  => undef,    # KB, set on first capture
        baseline_vsz  => undef,    # KB, set on first capture
        baseline_time => undef,
        capture_count => 0,
        _use_proc     => (-f '/proc/self/status'),  # Linux fast path
    };

    bless $self, $class;

    # Ensure log directory exists
    if (!-d $self->{log_dir}) {
        eval { make_path($self->{log_dir}); };
        if ($@) {
            print STDERR "[ERROR][ProcessStats] Failed to create log directory: $@\n"
                if should_log('ERROR');
        }
    }

    return $self;
}

=head2 capture

Capture current process stats and log them.

Arguments:
- $phase: String identifying the capture point (e.g., 'session_start',
  'iteration_start', 'after_tool', 'session_end')
- $metadata: Optional hashref of extra context (iteration number, tool name, etc.)

Returns: The captured entry hashref

=cut

sub capture {
    my ($self, $phase, $metadata) = @_;

    my $snap = $self->snapshot();
    return undef unless $snap;

    # Set baseline on first capture
    if (!defined $self->{baseline_rss}) {
        $self->{baseline_rss}  = $snap->{rss_kb};
        $self->{baseline_vsz}  = $snap->{vsz_kb};
        $self->{baseline_time} = time();
    }

    $self->{capture_count}++;

    my $entry = {
        timestamp  => strftime("%Y-%m-%dT%H:%M:%S", localtime(time())),
        session_id => $self->{session_id},
        phase      => $phase || 'unknown',
        pid        => $self->{pid},
        rss_kb     => $snap->{rss_kb},
        vsz_kb     => $snap->{vsz_kb},
        rss_mb     => $snap->{rss_mb},
        vsz_mb     => $snap->{vsz_mb},
        delta_rss_kb => $snap->{rss_kb} - ($self->{baseline_rss} // $snap->{rss_kb}),
        delta_vsz_kb => $snap->{vsz_kb} - ($self->{baseline_vsz} // $snap->{vsz_kb}),
        delta_rss_mb => sprintf("%.1f", ($snap->{rss_kb} - ($self->{baseline_rss} // $snap->{rss_kb})) / 1024),
        capture_num  => $self->{capture_count},
    };

    # Merge metadata if provided
    if ($metadata && ref($metadata) eq 'HASH') {
        $entry->{metadata} = $metadata;
    }

    $self->_write_entry($entry);

    log_debug('ProcessStats', sprintf(
        "%s: RSS=%.1fMB (delta %+.1fMB) VSZ=%.1fMB",
        $phase,
        $snap->{rss_mb},
        ($snap->{rss_kb} - ($self->{baseline_rss} // $snap->{rss_kb})) / 1024,
        $snap->{vsz_mb}
    ));

    return $entry;
}

=head2 snapshot

Get current memory stats without logging.

Returns: Hashref with rss_kb, vsz_kb, rss_mb, vsz_mb, or undef on failure.

=cut

sub snapshot {
    my ($self) = @_;

    my ($rss_kb, $vsz_kb);

    if ($self->{_use_proc}) {
        # Linux fast path: read /proc/self/status directly (no fork)
        ($rss_kb, $vsz_kb) = $self->_read_proc_status();
    }

    # Fallback to ps(1) - works on macOS, Linux, BSDs
    if (!defined $rss_kb) {
        ($rss_kb, $vsz_kb) = $self->_read_ps();
    }

    return undef unless defined $rss_kb;

    return {
        rss_kb => $rss_kb,
        vsz_kb => $vsz_kb,
        rss_mb => sprintf("%.1f", $rss_kb / 1024),
        vsz_mb => sprintf("%.1f", $vsz_kb / 1024),
    };
}

=head2 summary

Get a summary comparing baseline to current stats.

Returns: Hashref with baseline, current, and delta values.

=cut

sub summary {
    my ($self) = @_;

    my $snap = $self->snapshot();
    return undef unless $snap;

    return {
        baseline_rss_mb  => defined $self->{baseline_rss} ? sprintf("%.1f", $self->{baseline_rss} / 1024) : undef,
        baseline_vsz_mb  => defined $self->{baseline_vsz} ? sprintf("%.1f", $self->{baseline_vsz} / 1024) : undef,
        current_rss_mb   => $snap->{rss_mb},
        current_vsz_mb   => $snap->{vsz_mb},
        delta_rss_mb     => defined $self->{baseline_rss} ? sprintf("%.1f", ($snap->{rss_kb} - $self->{baseline_rss}) / 1024) : undef,
        delta_vsz_mb     => defined $self->{baseline_vsz} ? sprintf("%.1f", ($snap->{vsz_kb} - $self->{baseline_vsz}) / 1024) : undef,
        captures         => $self->{capture_count},
        uptime_seconds   => defined $self->{baseline_time} ? sprintf("%.0f", time() - $self->{baseline_time}) : undef,
    };
}

# ─── Private Methods ───────────────────────────────────────────────

# Read RSS/VSZ from /proc/self/status (Linux, no fork required)
sub _read_proc_status {
    my ($self) = @_;

    my ($rss_kb, $vsz_kb);

    eval {
        open my $fh, '<', '/proc/self/status' or die "Cannot open: $!";
        while (my $line = <$fh>) {
            if ($line =~ /^VmRSS:\s+(\d+)\s+kB/) {
                $rss_kb = $1;
            } elsif ($line =~ /^VmSize:\s+(\d+)\s+kB/) {
                $vsz_kb = $1;
            }
            last if defined $rss_kb && defined $vsz_kb;
        }
        close $fh;
    };

    return (defined $rss_kb && defined $vsz_kb) ? ($rss_kb, $vsz_kb) : ();
}

# Read RSS/VSZ via ps(1) - portable fallback (macOS, BSDs, Linux)
sub _read_ps {
    my ($self) = @_;

    my $output = `ps -o rss=,vsz= -p $self->{pid} 2>/dev/null`;
    return () unless defined $output && $output =~ /\S/;

    # ps output: "  61440 421888\n"  (values in KB)
    if ($output =~ /^\s*(\d+)\s+(\d+)/) {
        return ($1, $2);
    }

    return ();
}

# Write a JSONL entry to the log file
sub _write_entry {
    my ($self, $entry) = @_;

    my $date = strftime("%Y-%m-%d", localtime(time()));
    my $log_file = File::Spec->catfile($self->{log_dir}, "process_stats_$date.log");

    # Ensure log directory exists
    if (!-d $self->{log_dir}) {
        eval { make_path($self->{log_dir}); };
        return if $@;
    }

    my $json_line;
    eval { $json_line = encode_json($entry); };
    return if $@;

    eval {
        open my $fh, '>>', $log_file or die "Cannot open: $!";
        flock($fh, 2);  # LOCK_EX
        print $fh $json_line, "\n";
        flock($fh, 8);  # LOCK_UN
        close $fh;
    };

    if ($@) {
        print STDERR "[ERROR][ProcessStats] Failed to write stats: $@\n"
            if should_log('ERROR');
    }
}

1;

__END__

=head1 LOG FORMAT

Each line is a JSON object:

    {
        "timestamp": "2026-02-22T07:41:00",
        "session_id": "sess_20260222_074100",
        "phase": "iteration_start",
        "pid": 12345,
        "rss_kb": 61440,
        "vsz_kb": 421888,
        "rss_mb": "60.0",
        "vsz_mb": "412.0",
        "delta_rss_kb": 10240,
        "delta_rss_mb": "10.0",
        "delta_vsz_kb": 20480,
        "capture_num": 5,
        "metadata": { "iteration": 3 }
    }

=head1 AUTHOR

Fewtarius

=head1 LICENSE

GPL-3.0-only

=cut
