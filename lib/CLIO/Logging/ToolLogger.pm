package CLIO::Logging::ToolLogger;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use feature 'say';
use CLIO::Util::JSON qw(encode_json decode_json);
use File::Path qw(make_path);
use File::Spec;
use POSIX qw(strftime);
use Time::HiRes qw(time);
use CLIO::Core::Logger qw(should_log);

=head1 NAME

CLIO::Logging::ToolLogger - Comprehensive logging for tool operations

=head1 DESCRIPTION

Logs ALL tool operations with complete transparency:
- Tool name, operation, parameters
- Full output (not truncated)
- What was sent to AI vs what user saw
- Execution time, success/failure
- Searchable newline-delimited JSON format

Logs are stored in .clio/logs/ in the working directory (project-specific),
not in ~/.clio/ (which is for user configuration).

This enables users to review what tools actually did via the /log command.

=head1 SYNOPSIS

    use CLIO::Logging::ToolLogger;
    
    my $logger = CLIO::Logging::ToolLogger->new(
        session_id => 'sess_20260118_143052',
        debug => 1
    );
    
    # Log a tool operation
    $logger->log({
        tool_name => 'terminal',
        operation => 'execute',
        parameters => { command => 'perl -c file.pm' },
        output => { stdout => 'syntax OK', exit_code => 0 },
        action_description => 'Executing: perl -c file.pm',
        sent_to_ai => 'Command executed successfully',
        success => 1,
        execution_time_ms => 45
    });
    
    # Retrieve recent operations
    my $recent = $logger->get_recent(20);
    
    # Filter by tool name
    my $terminal_ops = $logger->filter('terminal');

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        session_id => $args{session_id} || 'unknown',
        debug => $args{debug} || 0,
        log_dir => $args{log_dir} || File::Spec->catdir('.clio', 'logs'),
        max_log_days => $args{max_log_days} || 30,
    };
    
    bless $self, $class;
    
    # Ensure log directory exists
    unless (-d $self->{log_dir}) {
        eval {
            make_path($self->{log_dir});
        };
        if ($@) {
            print STDERR "[ERROR][ToolLogger] Failed to create log directory $self->{log_dir}: $@\n" if should_log('ERROR');
            # Continue anyway - logging is not critical to operation
        } else {
            print STDERR "[DEBUG][ToolLogger] Created log directory: $self->{log_dir}\n" if should_log('DEBUG');
        }
    }
    
    return $self;
}

=head2 log

Log a tool operation.

Arguments:
- $entry: Hashref with:
  * tool_call_id: Unique ID for this tool call
  * tool_name: Name of the tool (e.g., 'terminal', 'file_operations')
  * operation: Specific operation (e.g., 'execute', 'read_file')
  * parameters: Hashref of input parameters
  * output: Tool's output (can be string, hashref, or arrayref)
  * action_description: User-visible description of what happened
  * sent_to_ai: What was actually sent to the AI as tool result
  * success: Boolean - did the operation succeed?
  * execution_time_ms: How long the operation took (milliseconds)
  * error: Error message if operation failed (optional)

Returns: 1 on success, 0 on failure

=cut

sub log {
    my ($self, $entry) = @_;
    
    unless ($entry && ref($entry) eq 'HASH') {
        print STDERR "[ERROR][ToolLogger] Invalid log entry (not a hashref)\n" if should_log('ERROR');
        return 0;
    }
    
    # Add metadata
    $entry->{timestamp} = strftime("%Y-%m-%dT%H:%M:%S", localtime(time()));
    $entry->{session_id} = $self->{session_id};
    
    # Get log file for today
    my $log_file = $self->_get_log_file();
    
    # Serialize to JSON (one line)
    my $json_line;
    eval {
        $json_line = encode_json($entry);
    };
    if ($@) {
        print STDERR "[ERROR][ToolLogger] Failed to serialize log entry: $@\n" if should_log('ERROR');
        return 0;
    }
    
    # Append to log file (with file locking)
    eval {
        open my $fh, '>>', $log_file or die "Cannot open log file: $!";
        flock($fh, 2) or die "Cannot lock log file: $!";  # LOCK_EX = 2
        print $fh $json_line, "\n";
        flock($fh, 8);  # LOCK_UN = 8
        close $fh;
    };
    if ($@) {
        print STDERR "[ERROR][ToolLogger] Failed to write log entry: $@\n" if should_log('ERROR');
        return 0;
    }
    
    print STDERR "[DEBUG][ToolLogger] Logged tool operation: $entry->{tool_name}/$entry->{operation}\n" 
        if should_log('DEBUG');
    
    return 1;
}

=head2 get_recent

Get the N most recent tool operations.

Arguments:
- $count: Number of entries to retrieve (default 20)
- %opts: Optional filters
  * session => 'session_id' - Filter by session
  * tool => 'tool_name' - Filter by tool name

Returns: Arrayref of log entries (most recent first)

=cut

sub get_recent {
    my ($self, $count, %opts) = @_;
    
    $count ||= 20;
    
    my @entries;
    
    # Read log files in reverse chronological order (today first)
    my @log_files = $self->_get_all_log_files();
    
    for my $log_file (reverse @log_files) {
        next unless -f $log_file;
        
        open my $fh, '<', $log_file or next;
        my @lines = <$fh>;
        close $fh;
        
        # Process lines in reverse (most recent first)
        for my $line (reverse @lines) {
            chomp $line;
            next unless $line;
            
            my $entry = eval { decode_json($line) };
            next unless $entry;
            
            # Apply filters
            if ($opts{session} && $entry->{session_id} ne $opts{session}) {
                next;
            }
            if ($opts{tool} && $entry->{tool_name} ne $opts{tool}) {
                next;
            }
            
            push @entries, $entry;
            last if @entries >= $count;
        }
        
        last if @entries >= $count;
    }
    
    return \@entries;
}

=head2 filter

Get all tool operations matching criteria.

Arguments:
- %filters:
  * tool => 'tool_name' - Filter by tool name
  * operation => 'operation_name' - Filter by operation
  * session => 'session_id' - Filter by session
  * success => 1/0 - Filter by success status
  * since => 'YYYY-MM-DD' - Only entries since date

Returns: Arrayref of matching log entries

=cut

sub filter {
    my ($self, %filters) = @_;
    
    my @matches;
    
    # Get all log files (or just recent ones if 'since' specified)
    my @log_files = $self->_get_all_log_files();
    
    if ($filters{since}) {
        my ($since_year, $since_month, $since_day) = split /-/, $filters{since};
        @log_files = grep {
            my $filename = File::Basename::basename($_);
            $filename =~ /tool_operations_(\d{4})-(\d{2})-(\d{2})\.log$/;
            my ($year, $month, $day) = ($1, $2, $3);
            "$year$month$day" >= "$since_year$since_month$since_day";
        } @log_files;
    }
    
    for my $log_file (@log_files) {
        next unless -f $log_file;
        
        open my $fh, '<', $log_file or next;
        while (my $line = <$fh>) {
            chomp $line;
            next unless $line;
            
            my $entry = eval { decode_json($line) };
            next unless $entry;
            
            # Apply all filters
            my $match = 1;
            
            if ($filters{tool} && $entry->{tool_name} ne $filters{tool}) {
                $match = 0;
            }
            if ($filters{operation} && $entry->{operation} ne $filters{operation}) {
                $match = 0;
            }
            if ($filters{session} && $entry->{session_id} ne $filters{session}) {
                $match = 0;
            }
            if (defined $filters{success} && $entry->{success} != $filters{success}) {
                $match = 0;
            }
            
            push @matches, $entry if $match;
        }
        close $fh;
    }
    
    return \@matches;
}

=head2 search

Search log entries for a pattern (in tool name, operation, or output).

Arguments:
- $pattern: Regular expression pattern to search for
- %opts: Optional
  * case_sensitive => 1 - Case-sensitive search (default: case-insensitive)

Returns: Arrayref of matching log entries

=cut

sub search {
    my ($self, $pattern, %opts) = @_;
    
    my @matches;
    my $flags = $opts{case_sensitive} ? '' : 'i';
    
    # Get all log files
    my @log_files = $self->_get_all_log_files();
    
    for my $log_file (@log_files) {
        next unless -f $log_file;
        
        open my $fh, '<', $log_file or next;
        while (my $line = <$fh>) {
            chomp $line;
            next unless $line;
            
            my $entry = eval { decode_json($line) };
            next unless $entry;
            
            # Search in multiple fields
            my $searchable = join(' ',
                $entry->{tool_name} || '',
                $entry->{operation} || '',
                $entry->{action_description} || '',
                ref($entry->{output}) ? encode_json($entry->{output}) : $entry->{output} || '',
                $entry->{error} || ''
            );
            
            if ($flags eq 'i' ? $searchable =~ /$pattern/i : $searchable =~ /$pattern/) {
                push @matches, $entry;
            }
        }
        close $fh;
    }
    
    return \@matches;
}

=head2 cleanup_old_logs

Remove log files older than max_log_days.

Returns: Number of files removed

=cut

sub cleanup_old_logs {
    my ($self) = @_;
    
    my $max_age_seconds = $self->{max_log_days} * 86400;
    my $now = time();
    my $removed = 0;
    
    my @log_files = $self->_get_all_log_files();
    
    for my $log_file (@log_files) {
        next unless -f $log_file;
        
        my $mtime = (stat($log_file))[9];
        if ($now - $mtime > $max_age_seconds) {
            if (unlink $log_file) {
                $removed++;
                print STDERR "[DEBUG][ToolLogger] Removed old log file: $log_file\n" 
                    if should_log('DEBUG');
            }
        }
    }
    
    return $removed;
}

# Private methods

sub _get_log_file {
    my ($self) = @_;
    
    # Ensure log directory exists (create if missing)
    if (!-d $self->{log_dir}) {
        require File::Path;
        File::Path::make_path($self->{log_dir});
    }
    
    my $date = strftime("%Y-%m-%d", localtime(time()));
    return File::Spec->catfile($self->{log_dir}, "tool_operations_$date.log");
}

sub _get_all_log_files {
    my ($self) = @_;
    
    return () unless -d $self->{log_dir};
    
    opendir my $dh, $self->{log_dir} or return ();
    my @files = grep { /^tool_operations_\d{4}-\d{2}-\d{2}\.log$/ } readdir($dh);
    closedir $dh;
    
    return map { File::Spec->catfile($self->{log_dir}, $_) } sort @files;
}

1;

__END__

=head1 AUTHOR

Fewtarius

=head1 LICENSE

GPL-3.0-only

=cut

1;
