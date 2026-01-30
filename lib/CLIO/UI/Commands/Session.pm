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
        session => $args{session},
        debug => $args{debug} // 0,
    };
    
    bless $self, $class;
    return $self;
}

# Delegate display methods to chat
sub display_command_header { shift->{chat}->display_command_header(@_) }
sub display_section_header { shift->{chat}->display_section_header(@_) }
sub display_key_value { shift->{chat}->display_key_value(@_) }
sub display_list_item { shift->{chat}->display_list_item(@_) }
sub display_system_message { shift->{chat}->display_system_message(@_) }
sub display_error_message { shift->{chat}->display_error_message(@_) }
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
    
    # Unknown action
    $self->display_error_message("Unknown action: /session $action");
    $self->_display_session_help();
}

=head2 _display_session_help

Display help for /session commands

=cut

sub _display_session_help {
    my ($self) = @_;
    
    $self->display_command_header("SESSION COMMANDS");
    
    $self->display_list_item("/session show - Display current session info");
    $self->display_list_item("/session list - List all available sessions");
    $self->display_list_item("/session switch - Interactive session picker");
    $self->display_list_item("/session switch <id> - Switch to specific session");
    $self->display_list_item("/session new - Show how to create new session");
    $self->display_list_item("/session clear - Clear current session history");
    
    print "\n";
    $self->display_section_header("EXAMPLES");
    print "  /session show                        # See current session\n";
    print "  /session list                        # See all sessions\n";
    print "  /session switch abc123-def456        # Switch by ID\n";
    print "\n";
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
        print "\n";
        $self->display_section_header("SESSION API CONFIG");
        for my $key (sort keys %{$state->{api_config}}) {
            $self->display_key_value($key, $state->{api_config}{$key});
        }
    }
    
    # Billing info
    if ($state->{billing}) {
        print "\n";
        $self->display_section_header("SESSION USAGE");
        my $billing = $state->{billing};
        $self->display_key_value("Requests", $billing->{request_count} || 0);
        $self->display_key_value("Input tokens", $billing->{input_tokens} || 0);
        $self->display_key_value("Output tokens", $billing->{output_tokens} || 0);
    }
    
    print "\n";
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
    
    print "\n";
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
    print $self->colorize("Clear all conversation history for this session? [y/N]: ", 'PROMPT');
    my $response = <STDIN>;
    chomp $response if defined $response;
    $response = lc($response || 'n');
    
    unless ($response eq 'y' || $response eq 'yes') {
        $self->display_system_message("Cancelled");
        return;
    }
    
    # Clear history
    my $state = $self->{session}->state();
    $state->{history} = [];
    $self->{session}->save();
    
    $self->display_system_message("Session history cleared");
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
        print "\n";
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
        
        print "\n";
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
    print "\n";
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
