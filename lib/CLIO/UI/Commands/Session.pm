package CLIO::UI::Commands::Session;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Carp qw(croak);
use CLIO::Core::Logger qw(should_log);

=head1 NAME

CLIO::UI::Commands::Session - Session commands for CLIO

=head1 SYNOPSIS

  use CLIO::UI::Commands::Session;
  
  my $session_cmd = CLIO::UI::Commands::Session->new(
      chat => $chat_instance,
      session => $session,
      debug => 0
  );
  
  # Handle /session commands
  $session_cmd->handle_session_command('show');
  $session_cmd->handle_session_command('list');
  $session_cmd->handle_switch_command('abc123');

=head1 DESCRIPTION

Handles all session-related commands including:
- /session show - Display current session info
- /session list - List all sessions
- /session switch - Switch to different session
- /session clear - Clear session history

Extracted from Chat.pm to improve maintainability.

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        chat => $args{chat} || croak "chat instance required",
        debug => $args{debug} // 0,
    };
    
    # Assign object references separately
    $self->{session} = $args{session};
    
    bless $self, $class;
    return $self;
}

=head2 auto_prune_sessions($config, $current_session_id)

Class method to automatically prune old sessions on startup.
Called from Chat.pm during initialization if auto-prune is enabled.

Arguments:
- $config - Config object with session_auto_prune and session_prune_days settings
- $current_session_id - Current session ID to protect from deletion

Returns: Number of sessions deleted (or 0 if disabled/nothing to delete)

=cut

sub auto_prune_sessions {
    my ($class, $config, $current_session_id) = @_;
    
    return 0 unless $config;
    
    # Check if auto-prune is enabled
    my $enabled = $config->get('session_auto_prune');
    return 0 unless $enabled;
    
    my $days = $config->get('session_prune_days') || 30;
    
    my $sessions_dir = '.clio/sessions';
    return 0 unless -d $sessions_dir;
    
    opendir(my $dh, $sessions_dir) or return 0;
    my @files = readdir($dh);
    closedir($dh);
    
    my $cutoff = time() - ($days * 86400);
    my $deleted = 0;
    
    for my $file (@files) {
        next unless $file =~ /^(.+)\.json$/;
        my $session_id = $1;
        
        # Never delete current session
        next if $current_session_id && $session_id eq $current_session_id;
        
        my $filepath = "$sessions_dir/$file";
        my $mtime = (stat($filepath))[9] || 0;
        
        if ($mtime < $cutoff) {
            if (unlink($filepath)) {
                $deleted++;
                # Also remove lock file if exists
                my $lock_file = "$sessions_dir/$session_id.lock";
                unlink($lock_file) if -f $lock_file;
                
                print STDERR "[DEBUG][Session] Auto-pruned old session: $session_id\n" 
                    if should_log('DEBUG');
            }
        }
    }
    
    if ($deleted > 0 && should_log('INFO')) {
        print STDERR "[INFO][Session] Auto-pruned $deleted old sessions (older than $days days)\n";
    }
    
    return $deleted;
}

# Delegate display methods to chat
sub display_command_header { shift->{chat}->display_command_header(@_) }
sub display_section_header { shift->{chat}->display_section_header(@_) }
sub display_key_value { shift->{chat}->display_key_value(@_) }
sub display_command_row { shift->{chat}->display_command_row(@_) }
sub display_list_item { shift->{chat}->display_list_item(@_) }
sub display_system_message { shift->{chat}->display_system_message(@_) }
sub display_error_message { shift->{chat}->display_error_message(@_) }
sub writeline { shift->{chat}->writeline(@_) }
sub display_success_message { shift->{chat}->display_success_message(@_) }
sub display_paginated_list { shift->{chat}->display_paginated_list(@_) }
sub colorize { shift->{chat}->colorize(@_) }

=head2 handle_session_command($action, @args)

Main dispatcher for /session commands.

=cut

sub handle_session_command {
    my ($self, $action, @args) = @_;
    
    $action ||= '';
    $action = lc($action);
    
    # /session (no args) - show help
    if ($action eq '' || $action eq 'help') {
        $self->_display_session_help();
        return;
    }
    
    # /session show - display current session info
    if ($action eq 'show') {
        $self->_display_session_info();
        return;
    }
    
    # /session list - list all sessions
    if ($action eq 'list') {
        $self->_list_sessions();
        return;
    }
    
    # /session switch [id] - switch sessions
    if ($action eq 'switch') {
        $self->handle_switch_command(@args);
        return;
    }
    
    # /session new - create new session (guidance)
    if ($action eq 'new') {
        $self->display_system_message("To create a new session, exit and run:");
        $self->display_system_message("  ./clio --new");
        return;
    }
    
    # /session clear - clear history
    if ($action eq 'clear') {
        $self->_clear_session_history();
        return;
    }
    
    # /session trim [days] - prune old sessions
    if ($action eq 'trim' || $action eq 'prune') {
        $self->_trim_sessions(@args);
        return;
    }
    
    # /session export [filename] - export to HTML
    if ($action eq 'export') {
        $self->_export_session(@args);
        return;
    }
    
    # Unknown action
    $self->display_error_message("Unknown action: /session $action");
    $self->_display_session_help();
}

=head2 _display_session_help

Display help for /session commands using unified style.

=cut

sub _display_session_help {
    my ($self) = @_;
    
    $self->display_command_header("SESSION");
    
    $self->display_section_header("COMMANDS");
    $self->display_command_row("/session show", "Display current session info", 30);
    $self->display_command_row("/session list", "List all available sessions", 30);
    $self->display_command_row("/session switch", "Interactive session picker", 30);
    $self->display_command_row("/session switch <id>", "Switch to specific session", 30);
    $self->display_command_row("/session new", "Show how to create new session", 30);
    $self->display_command_row("/session clear", "Clear current session history", 30);
    $self->display_command_row("/session trim [days]", "Remove old sessions (default: 30)", 30);
    $self->display_command_row("/session export [file]", "Export current session to HTML", 30);
    $self->writeline("", markdown => 0);
    
    $self->display_section_header("EXAMPLES");
    $self->display_command_row("/session show", "See current session", 35);
    $self->display_command_row("/session list", "See all sessions", 35);
    $self->display_command_row("/session switch abc123", "Switch by ID", 35);
    $self->writeline("", markdown => 0);
}

=head2 _display_session_info

Display current session information

=cut

sub _display_session_info {
    my ($self) = @_;
    
    my $session_id = $self->{session} ? $self->{session}->{session_id} : 'unknown';
    my $state = $self->{session} ? $self->{session}->state() : {};
    
    $self->display_command_header("SESSION INFORMATION");
    
    $self->display_key_value("Session ID", $session_id);
    
    # Working directory
    my $workdir = $state->{working_directory} || '.';
    $self->display_key_value("Working Dir", $workdir);
    
    # Created at
    if ($state->{created_at}) {
        my $created = localtime($state->{created_at});
        $self->display_key_value("Created", $created);
    }
    
    # History count
    my $history_count = $state->{history} ? scalar(@{$state->{history}}) : 0;
    $self->display_key_value("History", "$history_count messages");
    
    # API config (session-specific)
    if ($state->{api_config} && %{$state->{api_config}}) {
        $self->writeline("", markdown => 0);
        $self->display_section_header("SESSION API CONFIG");
        for my $key (sort keys %{$state->{api_config}}) {
            $self->display_key_value($key, $state->{api_config}{$key});
        }
    }
    
    # Billing info
    if ($state->{billing}) {
        $self->writeline("", markdown => 0);
        $self->display_section_header("SESSION USAGE");
        my $billing = $state->{billing};
        $self->display_key_value("Requests", $billing->{request_count} || 0);
        $self->display_key_value("Input tokens", $billing->{input_tokens} || 0);
        $self->display_key_value("Output tokens", $billing->{output_tokens} || 0);
    }
    
    $self->writeline("", markdown => 0);
}

=head2 _list_sessions

List all available sessions

=cut

sub _list_sessions {
    my ($self) = @_;
    
    my $sessions_dir = '.clio/sessions';
    unless (-d $sessions_dir) {
        $self->display_error_message("Sessions directory not found");
        return;
    }
    
    opendir(my $dh, $sessions_dir) or do {
        $self->display_error_message("Cannot read sessions directory: $!");
        return;
    };
    
    my @sessions = grep { /\.json$/ && -f "$sessions_dir/$_" } readdir($dh);
    closedir($dh);
    
    unless (@sessions) {
        $self->display_system_message("No sessions found");
        return;
    }
    
    # Get session info
    my @session_info;
    for my $session_file (@sessions) {
        my $id = $session_file;
        $id =~ s/\.json$//;
        
        my $filepath = "$sessions_dir/$session_file";
        my $mtime = (stat($filepath))[9] || 0;
        my $size = (stat($filepath))[7] || 0;
        
        push @session_info, {
            id => $id,
            mtime => $mtime,
            size => $size,
            is_current => ($self->{session} && $self->{session}->{session_id} eq $id),
        };
    }
    
    # Sort by modification time (most recent first)
    @session_info = sort { $b->{mtime} <=> $a->{mtime} } @session_info;
    
    # Create formatted items for paginated display
    my @items;
    for my $i (0 .. $#session_info) {
        my $sess = $session_info[$i];
        my $marker = $sess->{is_current} ? ' (current)' : '';
        my $time = _format_relative_time($sess->{mtime});
        
        push @items, sprintf("%3d) %s [%s]%s", 
            $i + 1, $sess->{id}, $time, $marker);
    }
    
    # Use standard pagination
    my $formatter = sub {
        my ($item, $idx) = @_;
        return $item;  # Already formatted
    };
    
    $self->display_paginated_list("AVAILABLE SESSIONS", \@items, $formatter);
    
    $self->writeline("", markdown => 0);
    $self->display_system_message("Use '/session switch <number>' or '/session switch <id>' to switch");
}

=head2 _clear_session_history

Clear the current session's conversation history

=cut

sub _clear_session_history {
    my ($self) = @_;
    
    unless ($self->{session}) {
        $self->display_error_message("No active session");
        return;
    }
    
    # Confirm
    my ($header, $input_line) = @{$self->{chat}{theme_mgr}->get_confirmation_prompt(
        "Clear all conversation history?",
        "yes/no",
        "cancel"
    )};
    
    print $header, "\n";
    print $input_line;
    my $response = <STDIN>;
    chomp $response if defined $response;
    
    unless ($response && $response =~ /^y(es)?$/i) {
        $self->display_system_message("Cancelled");
        return;
    }
    
    # Clear history
    my $state = $self->{session}->state();
    $state->{history} = [];
    $self->{session}->save();
    
    $self->display_system_message("Session history cleared");
}

=head2 _trim_sessions($days)

=head2 _export_session(@args)

Export current session to HTML file.

Arguments:
- $filename - Optional output filename (default: session-<id>.html)

=cut

sub _export_session {
    my ($self, @args) = @_;
    
    my $session = $self->{chat}->{session};
    unless ($session) {
        $self->display_error_message("No active session to export.");
        return;
    }
    
    my $state = $session->state();
    unless ($state && $state->{history} && @{$state->{history}}) {
        $self->display_error_message("Session has no messages to export.");
        return;
    }
    
    # Determine output filename
    my $filename = $args[0] || '';
    unless ($filename) {
        my $session_id = $session->{session_id} || 'unknown';
        my $short_id = substr($session_id, 0, 8);
        $filename = "session-$short_id.html";
    }
    
    # Ensure .html extension
    $filename .= '.html' unless $filename =~ /\.html?$/i;
    
    # Expand tilde to home directory
    $filename =~ s/^~/$ENV{HOME}/;
    
    eval {
        require CLIO::Session::Export;
        my $exporter = CLIO::Session::Export->new(
            debug => $self->{debug},
            include_tool_results => 1,
        );
        
        # Ensure session_id is available to the exporter
        $state->{session_id} ||= $session->{session_id};
        
        $exporter->export_to_file($state, $filename);
    };
    
    if ($@) {
        $self->display_error_message("Export failed: $@");
        return;
    }
    
    $self->display_system_message("Session exported to: $filename");
}

=head2 _trim_sessions($days_arg)

Remove sessions older than the specified number of days.

Arguments:
- $days - Number of days (default: 30)

=cut

sub _trim_sessions {
    my ($self, $days_arg) = @_;
    
    # Parse days argument (default: 30)
    my $days = 30;
    if (defined $days_arg && $days_arg =~ /^\d+$/) {
        $days = int($days_arg);
    } elsif (defined $days_arg && $days_arg ne '') {
        $self->display_error_message("Invalid days argument: $days_arg (must be a number)");
        return;
    }
    
    my $sessions_dir = '.clio/sessions';
    unless (-d $sessions_dir) {
        $self->display_error_message("Sessions directory not found");
        return;
    }
    
    opendir(my $dh, $sessions_dir) or do {
        $self->display_error_message("Cannot read sessions directory: $!");
        return;
    };
    
    my @all_files = readdir($dh);
    closedir($dh);
    
    # Get current session ID to protect it
    my $current_id = $self->{session} ? $self->{session}->{session_id} : '';
    
    # Find sessions to delete
    my $cutoff = time() - ($days * 86400);
    my @to_delete;
    my @protected;
    my $total_bytes = 0;
    
    for my $file (@all_files) {
        next unless $file =~ /^(.+)\.json$/;
        my $session_id = $1;
        
        my $filepath = "$sessions_dir/$file";
        my $mtime = (stat($filepath))[9] || 0;
        my $size = (stat($filepath))[7] || 0;
        
        # Skip current session
        if ($session_id eq $current_id) {
            push @protected, { id => $session_id, reason => 'current session' };
            next;
        }
        
        # Check age
        if ($mtime < $cutoff) {
            push @to_delete, {
                id => $session_id,
                file => $filepath,
                lock_file => "$sessions_dir/$session_id.lock",
                mtime => $mtime,
                size => $size,
            };
            $total_bytes += $size;
        }
    }
    
    if (!@to_delete) {
        $self->display_system_message("No sessions older than $days days found.");
        if (@protected) {
            $self->display_system_message("  (1 protected: current session)");
        }
        return;
    }
    
    # Show what will be deleted
    $self->display_command_header("SESSION CLEANUP");
    $self->display_key_value("Sessions to remove", scalar(@to_delete));
    $self->display_key_value("Space to reclaim", _format_bytes($total_bytes));
    $self->display_key_value("Age threshold", "$days days");
    
    $self->writeline("", markdown => 0);
    $self->display_section_header("SESSIONS TO DELETE");
    
    for my $sess (sort { $a->{mtime} <=> $b->{mtime} } @to_delete) {
        my $age = _format_relative_time($sess->{mtime});
        my $size = _format_bytes($sess->{size});
        printf "  %s [%s, %s]\n", 
            substr($sess->{id}, 0, 36) . "...",
            $age, $size;
    }
    
    # Confirm
    $self->writeline("", markdown => 0);
    
    my ($header, $input_line) = @{$self->{chat}{theme_mgr}->get_confirmation_prompt(
        "Delete these sessions?",
        "yes/no",
        "cancel"
    )};
    
    print $header, "\n";
    print $input_line;
    my $response = <STDIN>;
    chomp $response if defined $response;
    
    unless ($response && $response =~ /^y(es)?$/i) {
        $self->display_system_message("Cancelled");
        return;
    }
    
    # Delete sessions
    my $deleted = 0;
    my $failed = 0;
    my $bytes_freed = 0;
    
    for my $sess (@to_delete) {
        my $ok = 1;
        
        # Delete JSON file
        if (-f $sess->{file}) {
            if (unlink($sess->{file})) {
                $bytes_freed += $sess->{size};
            } else {
                print STDERR "[WARN] Failed to delete $sess->{file}: $!\n" if should_log('WARNING');
                $ok = 0;
            }
        }
        
        # Delete lock file if exists
        if (-f $sess->{lock_file}) {
            unlink($sess->{lock_file});  # Best effort
        }
        
        if ($ok) {
            $deleted++;
        } else {
            $failed++;
        }
    }
    
    $self->writeline("", markdown => 0);
    $self->display_success_message("Deleted $deleted sessions (" . _format_bytes($bytes_freed) . " freed)");
    
    if ($failed > 0) {
        $self->display_error_message("Failed to delete $failed sessions (check permissions)");
    }
}

# Helper to format bytes in human-readable form
sub _format_bytes {
    my ($bytes) = @_;
    
    return "0 B" unless $bytes;
    
    if ($bytes < 1024) {
        return "$bytes B";
    } elsif ($bytes < 1024 * 1024) {
        return sprintf("%.1f KB", $bytes / 1024);
    } elsif ($bytes < 1024 * 1024 * 1024) {
        return sprintf("%.1f MB", $bytes / (1024 * 1024));
    } else {
        return sprintf("%.2f GB", $bytes / (1024 * 1024 * 1024));
    }
}

=head2 handle_switch_command

Switch to a different session

=cut

sub handle_switch_command {
    my ($self, @args) = @_;
    
    require CLIO::Session::Manager;
    
    # List available sessions
    my $sessions_dir = '.clio/sessions';
    unless (-d $sessions_dir) {
        $self->display_error_message("Sessions directory not found");
        return;
    }
    
    opendir(my $dh, $sessions_dir) or do {
        $self->display_error_message("Cannot read sessions directory: $!");
        return;
    };
    
    my @session_files = grep { /\.json$/ && -f "$sessions_dir/$_" } readdir($dh);
    closedir($dh);
    
    unless (@session_files) {
        $self->display_system_message("No sessions available");
        return;
    }
    
    # Extract session IDs and get info
    my @sessions = map { 
        my $id = $_;
        $id =~ s/\.json$//;
        my $file = "$sessions_dir/$_";
        my $mtime = (stat($file))[9];
        { id => $id, file => $file, mtime => $mtime }
    } @session_files;
    
    # Sort by most recent first
    @sessions = sort { $b->{mtime} <=> $a->{mtime} } @sessions;
    
    my $target_session_id;
    
    # If session ID provided as argument, use it
    if (@args && $args[0]) {
        $target_session_id = $args[0];
        
        # Check if it's a number (selecting from list)
        if ($target_session_id =~ /^\d+$/) {
            my $idx = $target_session_id - 1;
            if ($idx >= 0 && $idx < @sessions) {
                $target_session_id = $sessions[$idx]{id};
            } else {
                $self->display_error_message("Invalid session number: $args[0] (valid: 1-" . scalar(@sessions) . ")");
                return;
            }
        }
        
        # Verify session exists
        my ($found) = grep { $_->{id} eq $target_session_id } @sessions;
        unless ($found) {
            $self->display_error_message("Session not found: $target_session_id");
            return;
        }
    } else {
        # Display sessions and ask for choice
        $self->writeline("", markdown => 0);
        $self->display_command_header("AVAILABLE SESSIONS");
        
        my $current_id = $self->{session} ? $self->{session}->{session_id} : '';
        my $chat = $self->{chat};
        
        for my $i (0..$#sessions) {
            my $s = $sessions[$i];
            my $current = ($s->{id} eq $current_id) ? ' @BOLD@(current)@RESET@' : "";
            my $time = _format_relative_time($s->{mtime});
            printf "  %d) %s %s%s\n", 
                $i + 1, 
                substr($s->{id}, 0, 20) . "...",
                $self->colorize("[$time]", 'dim'),
                $chat->{ansi}->parse($current);
        }
        
        $self->writeline("", markdown => 0);
        $self->display_system_message("Enter session number or ID to switch:");
        $self->display_system_message("  /session switch 1");
        $self->display_system_message("  /session switch abc123-def456...");
        return;
    }
    
    # Don't switch to current session
    if ($self->{session} && $self->{session}->{session_id} eq $target_session_id) {
        $self->display_system_message("Already in session: $target_session_id");
        return;
    }
    
    # Perform the switch
    $self->display_system_message("Switching to session: $target_session_id...");
    
    # 1. Save current session
    if ($self->{session}) {
        $self->display_system_message("  Saving current session...");
        $self->{session}->save();
        
        # Release lock if possible
        if ($self->{session}->{lock} && $self->{session}->{lock}->can('release')) {
            $self->{session}->{lock}->release();
        }
    }
    
    # 2. Load new session
    my $new_session = eval {
        CLIO::Session::Manager->load($target_session_id, debug => $self->{debug});
    };
    
    if ($@ || !$new_session) {
        my $err = $@ || "Unknown error";
        $self->display_error_message("Failed to load session: $err");
        
        # Re-acquire lock on original session
        if ($self->{session}) {
            $self->display_system_message("Staying in current session");
        }
        return;
    }
    
    # 3. Update Chat's session reference
    $self->{chat}->{session} = $new_session;
    $self->{session} = $new_session;
    
    # 4. Reload theme/style from new session
    my $state = $new_session->state();
    my $chat = $self->{chat};
    if ($state->{style} && $chat->{theme_mgr}) {
        $chat->{theme_mgr}->set_style($state->{style});
    }
    if ($state->{theme} && $chat->{theme_mgr}) {
        $chat->{theme_mgr}->set_theme($state->{theme});
    }
    
    # 5. Success
    $self->writeline("", markdown => 0);
    $self->display_success_message("Switched to session: $target_session_id");
    
    # Show session info
    my $history_count = $state->{history} ? scalar(@{$state->{history}}) : 0;
    $self->display_system_message("  Messages in history: $history_count");
    $self->display_system_message("  Working directory: " . ($state->{working_directory} || '.'));
}

# Helper to format relative time
sub _format_relative_time {
    my ($timestamp) = @_;
    
    my $now = time();
    my $diff = $now - $timestamp;
    
    if ($diff < 60) {
        return "just now";
    } elsif ($diff < 3600) {
        my $mins = int($diff / 60);
        return "$mins min ago";
    } elsif ($diff < 86400) {
        my $hours = int($diff / 3600);
        return "$hours hr ago";
    } elsif ($diff < 604800) {
        my $days = int($diff / 86400);
        return "$days day" . ($days > 1 ? "s" : "") . " ago";
    } else {
        my @t = localtime($timestamp);
        return sprintf("%04d-%02d-%02d", $t[5]+1900, $t[4]+1, $t[3]);
    }
}

1;

__END__

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

Same as CLIO.

=cut
