package CLIO::UI::Commands::Stats;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Carp qw(croak);
use CLIO::Core::Logger qw(should_log);
use CLIO::Util::JSON qw(encode_json decode_json);

=head1 NAME

CLIO::UI::Commands::Stats - Process statistics commands for CLIO

=head1 SYNOPSIS

  use CLIO::UI::Commands::Stats;
  
  my $stats_cmd = CLIO::UI::Commands::Stats->new(
      chat => $chat_instance,
      session => $session,
      debug => 0
  );
  
  $stats_cmd->handle_stats_command();          # Show current snapshot
  $stats_cmd->handle_stats_command('history'); # Show session history
  $stats_cmd->handle_stats_command('log');     # Show raw log entries

=head1 DESCRIPTION

Displays process memory and resource statistics. Shows current RSS/VSZ,
baseline comparison, and session history from ProcessStats log data.

Commands:
  /stats          - Current memory snapshot with baseline comparison
  /stats history  - Per-iteration memory history for this session
  /stats log      - Raw log entries from today's stats log

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        chat => $args{chat} || croak "chat instance required",
        debug => $args{debug} // 0,
    };
    
    $self->{session} = $args{session};
    
    bless $self, $class;
    return $self;
}

# Delegate display methods to chat
sub display_command_header { shift->{chat}->display_command_header(@_) }
sub display_system_message { shift->{chat}->display_system_message(@_) }
sub display_error_message  { shift->{chat}->display_error_message(@_) }
sub writeline              { shift->{chat}->writeline(@_) }
sub colorize               { shift->{chat}->colorize(@_) }

=head2 handle_stats_command(@args)

Main handler for /stats commands.

=cut

sub handle_stats_command {
    my ($self, @args) = @_;
    
    my $action = lc(shift @args || '');
    
    if ($action eq '' || $action eq 'current') {
        $self->_show_current();
    }
    elsif ($action eq 'history' || $action eq 'hist') {
        $self->_show_history();
    }
    elsif ($action eq 'log' || $action eq 'raw') {
        $self->_show_log(@args);
    }
    elsif ($action eq 'help') {
        $self->_show_help();
    }
    else {
        $self->display_error_message("Unknown stats action: $action");
        $self->_show_help();
    }
}

sub _show_current {
    my ($self) = @_;
    
    my $process_stats = $self->_get_process_stats();
    
    $self->display_command_header("PROCESS STATISTICS");
    
    if (!$process_stats) {
        $self->display_system_message("Process stats not available (no active orchestrator)");
        # Fall back to direct ps reading
        $self->_show_fallback_stats();
        return;
    }
    
    my $snap = $process_stats->snapshot();
    my $summary = $process_stats->summary();
    
    unless ($snap) {
        $self->display_error_message("Unable to read process stats");
        return;
    }
    
    # Current memory
    $self->writeline("", markdown => 0);
    $self->writeline($self->colorize("  Current Memory", 'command_subheader'), markdown => 0);
    $self->writeline($self->colorize("  " . "\x{2500}" x 40, 'dim'), markdown => 0);
    $self->writeline(sprintf("  %-24s %s",
        "RSS (physical):",
        $self->colorize("$snap->{rss_mb} MB", 'success')),
        markdown => 0);
    $self->writeline(sprintf("  %-24s %s",
        "VSZ (virtual):",
        "$snap->{vsz_mb} MB"),
        markdown => 0);
    $self->writeline(sprintf("  %-24s %s",
        "PID:",
        "$$"),
        markdown => 0);
    
    # Baseline comparison
    if ($summary && defined $summary->{baseline_rss_mb}) {
        $self->writeline("", markdown => 0);
        $self->writeline($self->colorize("  Session Baseline", 'command_subheader'), markdown => 0);
        $self->writeline($self->colorize("  " . "\x{2500}" x 40, 'dim'), markdown => 0);
        $self->writeline(sprintf("  %-24s %s",
            "Baseline RSS:",
            "$summary->{baseline_rss_mb} MB"),
            markdown => 0);
        
        my $delta = $summary->{delta_rss_mb};
        my $delta_str = sprintf("%+.1f MB", $delta);
        my $color = $delta > 10 ? 'error' : $delta > 5 ? 'WARNING' : 'success';
        $self->writeline(sprintf("  %-24s %s",
            "Delta:",
            $self->colorize($delta_str, $color)),
            markdown => 0);
        
        if (defined $summary->{uptime_seconds}) {
            my $uptime = $summary->{uptime_seconds};
            my $uptime_str;
            if ($uptime < 60) {
                $uptime_str = sprintf("%ds", $uptime);
            } elsif ($uptime < 3600) {
                $uptime_str = sprintf("%dm %ds", int($uptime/60), $uptime%60);
            } else {
                $uptime_str = sprintf("%dh %dm", int($uptime/3600), int(($uptime%3600)/60));
            }
            $self->writeline(sprintf("  %-24s %s",
                "Session uptime:",
                $uptime_str),
                markdown => 0);
        }
        
        $self->writeline(sprintf("  %-24s %s",
            "Captures:",
            $summary->{captures}),
            markdown => 0);
    }
    
    $self->writeline("", markdown => 0);
}

sub _show_history {
    my ($self) = @_;
    
    $self->display_command_header("MEMORY HISTORY");
    
    # Read today's log file
    my @entries = $self->_read_log_entries();
    
    if (!@entries) {
        $self->display_system_message("No stats history available for today");
        return;
    }
    
    # Filter to current session if possible
    my $session_id;
    if ($self->{session} && $self->{session}->can('session_id')) {
        $session_id = $self->{session}->session_id();
    }
    
    my @session_entries = $session_id 
        ? grep { ($_->{session_id} || '') eq $session_id } @entries
        : @entries;
    
    if (!@session_entries) {
        @session_entries = @entries;  # Show all if session filter yields nothing
    }
    
    $self->writeline("", markdown => 0);
    
    # Table header
    $self->writeline(sprintf("  %-12s %-18s %8s %8s %10s  %s",
        "Time", "Phase", "RSS", "VSZ", "Delta", "Context"),
        markdown => 0);
    $self->writeline("  " . $self->colorize("\x{2500}" x 72, 'dim'), markdown => 0);
    
    for my $entry (@session_entries) {
        my $time = $entry->{timestamp} || '';
        $time =~ s/.*T//;  # Just show HH:MM:SS
        
        my $phase = $entry->{phase} || 'unknown';
        # Truncate phase name for table
        $phase = substr($phase, 0, 16) if length($phase) > 16;
        
        my $rss = defined $entry->{rss_mb} ? "$entry->{rss_mb}" : '?';
        my $vsz = defined $entry->{vsz_mb} ? "$entry->{vsz_mb}" : '?';
        
        my $delta = defined $entry->{delta_rss_mb} ? sprintf("%+.1f", $entry->{delta_rss_mb}) : '';
        my $delta_color = ($entry->{delta_rss_kb} || 0) > 10240 ? 'error' 
                        : ($entry->{delta_rss_kb} || 0) > 5120  ? 'WARNING' 
                        : 'dim';
        
        # Build context string from metadata
        my $ctx = '';
        if (my $meta = $entry->{metadata}) {
            my @parts;
            push @parts, "iter=$meta->{iteration}" if defined $meta->{iteration};
            push @parts, "tools=$meta->{tool_count}" if defined $meta->{tool_count};
            push @parts, "$meta->{tool_name}" if defined $meta->{tool_name};
            push @parts, sprintf("%.0fs", $meta->{elapsed_time}) if defined $meta->{elapsed_time};
            $ctx = join(', ', @parts);
        }
        
        $self->writeline(sprintf("  %-12s %-18s %6s MB %6s MB %8s MB  %s",
            $time,
            $phase,
            $rss,
            $vsz,
            $self->colorize($delta, $delta_color),
            $ctx),
            markdown => 0);
    }
    
    $self->writeline("", markdown => 0);
    $self->writeline(sprintf("  %d entries", scalar @session_entries), markdown => 0);
    $self->writeline("", markdown => 0);
}

sub _show_log {
    my ($self, @args) = @_;
    
    my $count = $args[0] || 20;
    $count = 50 if $count > 50;
    
    $self->display_command_header("RAW STATS LOG");
    
    my @entries = $self->_read_log_entries();
    
    if (!@entries) {
        $self->display_system_message("No log entries for today");
        return;
    }
    
    # Show last N entries
    my $start = @entries > $count ? @entries - $count : 0;
    my @recent = @entries[$start .. $#entries];
    
    $self->writeline("", markdown => 0);
    
    require JSON::PP;
    for my $entry (@recent) {
        my $json = eval { encode_json($entry) };
        $self->writeline("  $json", markdown => 0) if $json;
    }
    
    $self->writeline("", markdown => 0);
    $self->writeline(sprintf("  Showing %d of %d entries", scalar @recent, scalar @entries), markdown => 0);
    $self->writeline("", markdown => 0);
}

sub _show_help {
    my ($self) = @_;
    
    $self->writeline("", markdown => 0);
    $self->display_system_message("Usage: /stats [subcommand]");
    $self->writeline("", markdown => 0);
    $self->writeline("  /stats              Current memory snapshot", markdown => 0);
    $self->writeline("  /stats history      Per-iteration memory timeline", markdown => 0);
    $self->writeline("  /stats log [N]      Raw log entries (last N, default 20)", markdown => 0);
    $self->writeline("  /stats help         This help message", markdown => 0);
    $self->writeline("", markdown => 0);
}

sub _show_fallback_stats {
    my ($self) = @_;
    
    # Direct ps reading when orchestrator isn't available
    my $output = `ps -o rss=,vsz= -p $$ 2>/dev/null`;
    if ($output && $output =~ /^\s*(\d+)\s+(\d+)/) {
        my ($rss_kb, $vsz_kb) = ($1, $2);
        $self->writeline("", markdown => 0);
        $self->writeline($self->colorize("  Current Memory (direct)", 'command_subheader'), markdown => 0);
        $self->writeline($self->colorize("  " . "\x{2500}" x 40, 'dim'), markdown => 0);
        $self->writeline(sprintf("  %-24s %s",
            "RSS (physical):",
            $self->colorize(sprintf("%.1f MB", $rss_kb / 1024), 'success')),
            markdown => 0);
        $self->writeline(sprintf("  %-24s %s",
            "VSZ (virtual):",
            sprintf("%.1f MB", $vsz_kb / 1024)),
            markdown => 0);
        $self->writeline(sprintf("  %-24s %s",
            "PID:",
            "$$"),
            markdown => 0);
        $self->writeline("", markdown => 0);
        $self->writeline($self->colorize("  Note: Baseline tracking requires an active session", 'dim'), markdown => 0);
        $self->writeline("", markdown => 0);
    } else {
        $self->display_error_message("Unable to read process memory stats");
    }
}

# Get ProcessStats instance from the orchestrator
sub _get_process_stats {
    my ($self) = @_;
    
    # Navigate: session -> chat -> ai_agent -> orchestrator -> process_stats
    my $chat = $self->{chat};
    return undef unless $chat;
    
    my $ai_agent = $chat->{ai_agent};
    return undef unless $ai_agent;
    
    my $orchestrator = $ai_agent->{orchestrator};
    return undef unless $orchestrator;
    
    return $orchestrator->{process_stats};
}

# Read JSONL log entries from today's stats file
sub _read_log_entries {
    my ($self) = @_;
    
    require POSIX;
    require File::Spec;
    require JSON::PP;
    
    my $date = POSIX::strftime("%Y-%m-%d", localtime(time()));
    my $log_file = File::Spec->catfile('.clio', 'logs', "process_stats_$date.log");
    
    return () unless -f $log_file;
    
    my @entries;
    eval {
        open my $fh, '<:encoding(UTF-8)', $log_file or die "Cannot open: $!";
        while (my $line = <$fh>) {
            chomp $line;
            next unless $line =~ /\S/;
            my $entry = eval { decode_json($line) };
            push @entries, $entry if $entry;
        }
        close $fh;
    };
    
    return @entries;
}

1;

__END__

=head1 AUTHOR

Fewtarius

=head1 LICENSE

GPL-3.0-only

=cut
