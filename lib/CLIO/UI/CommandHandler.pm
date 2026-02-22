package CLIO::UI::CommandHandler;

use strict;
use warnings;
use Carp qw(croak confess);
use CLIO::Core::Logger qw(should_log);
use CLIO::UI::Commands::API;
use CLIO::UI::Commands::Config;
use CLIO::UI::Commands::Git;
use CLIO::UI::Commands::File;
use CLIO::UI::Commands::Session;
use CLIO::UI::Commands::AI;
use CLIO::UI::Commands::System;
use CLIO::UI::Commands::Todo;
use CLIO::UI::Commands::Billing;
use CLIO::UI::Commands::Memory;
use CLIO::UI::Commands::Log;
use CLIO::UI::Commands::Context;
use CLIO::UI::Commands::Update;
use CLIO::UI::Commands::Skills;
use CLIO::UI::Commands::Prompt;
use CLIO::UI::Commands::Project;
use CLIO::UI::Commands::Device;
use CLIO::UI::Commands::SubAgent;
use CLIO::UI::Commands::Stats;

=head1 NAME

CLIO::UI::CommandHandler - Slash command processing for CLIO chat interface

=head1 SYNOPSIS

  use CLIO::UI::CommandHandler;
  
  my $handler = CLIO::UI::CommandHandler->new(
      chat => $chat_instance,
      session => $session,
      config => $config,
      ai_agent => $ai_agent,
      debug => 0
  );
  
  # Handle a slash command
  my $result = $handler->handle_command($command_string);

=head1 DESCRIPTION

CommandHandler extracts all slash command processing logic from Chat.pm.
It handles 35+ commands including:

- /help, /api, /config, /loglevel
- /file, /git, /edit, /shell, /exec
- /todo, /billing, /memory, /models
- /session, /switch, /read, /skills
- /style, /theme, /login, /logout
- And many more...

This separation improves maintainability by isolating command logic
from core chat orchestration, display, and streaming.

=head1 METHODS

=head2 new(%args)

Create a new CommandHandler instance.

Arguments:
- chat: Parent Chat instance (for display methods and command handlers)
- session: Session object
- config: Config object  
- ai_agent: AI agent instance
- debug: Enable debug logging

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        chat => $args{chat} || croak "chat instance required",
        debug => $args{debug} // 0,
    };
    
    # Assign object references separately
    $self->{config} = $args{config};
    $self->{session} = $args{session};
    $self->{ai_agent} = $args{ai_agent};
    
    bless $self, $class;
    
    # Initialize command modules
    $self->{api_cmd} = CLIO::UI::Commands::API->new(
        chat => $self->{chat},
        config => $self->{config},
        session => $self->{session},
        ai_agent => $self->{ai_agent},
        debug => $self->{debug},
    );
    
    $self->{config_cmd} = CLIO::UI::Commands::Config->new(
        chat => $self->{chat},
        config => $self->{config},
        session => $self->{session},
        debug => $self->{debug},
    );
    
    $self->{git_cmd} = CLIO::UI::Commands::Git->new(
        chat => $self->{chat},
        session => $self->{session},
        debug => $self->{debug},
    );
    
    $self->{file_cmd} = CLIO::UI::Commands::File->new(
        chat => $self->{chat},
        session => $self->{session},
        config => $self->{config},
        debug => $self->{debug},
    );
    
    $self->{session_cmd} = CLIO::UI::Commands::Session->new(
        chat => $self->{chat},
        session => $self->{session},
        debug => $self->{debug},
    );
    
    $self->{ai_cmd} = CLIO::UI::Commands::AI->new(
        chat => $self->{chat},
        session => $self->{session},
        debug => $self->{debug},
    );
    
    $self->{system_cmd} = CLIO::UI::Commands::System->new(
        chat => $self->{chat},
        session => $self->{session},
        config => $self->{config},
        debug => $self->{debug},
    );
    
    $self->{todo_cmd} = CLIO::UI::Commands::Todo->new(
        chat => $self->{chat},
        session => $self->{session},
        ai_agent => $self->{ai_agent},
        debug => $self->{debug},
    );
    
    $self->{billing_cmd} = CLIO::UI::Commands::Billing->new(
        chat => $self->{chat},
        session => $self->{session},
        debug => $self->{debug},
    );
    
    $self->{memory_cmd} = CLIO::UI::Commands::Memory->new(
        chat => $self->{chat},
        session => $self->{session},
        debug => $self->{debug},
    );
    
    $self->{log_cmd} = CLIO::UI::Commands::Log->new(
        chat => $self->{chat},
        session => $self->{session},
        debug => $self->{debug},
    );
    
    $self->{context_cmd} = CLIO::UI::Commands::Context->new(
        chat => $self->{chat},
        session => $self->{session},
        api_manager => $self->{ai_agent} ? $self->{ai_agent}{api} : undef,
        debug => $self->{debug},
    );
    
    $self->{update_cmd} = CLIO::UI::Commands::Update->new(
        chat => $self->{chat},
        debug => $self->{debug},
    );
    
    $self->{skills_cmd} = CLIO::UI::Commands::Skills->new(
        chat => $self->{chat},
        session => $self->{session},
        debug => $self->{debug},
    );
    
    $self->{prompt_cmd} = CLIO::UI::Commands::Prompt->new(
        chat => $self->{chat},
        debug => $self->{debug},
    );
    
    $self->{project_cmd} = CLIO::UI::Commands::Project->new(
        chat => $self->{chat},
        debug => $self->{debug},
    );
    
    $self->{subagent_cmd} = CLIO::UI::Commands::SubAgent->new(
        chat => $self->{chat},
        debug => $self->{debug},
    );
    
    $self->{stats_cmd} = CLIO::UI::Commands::Stats->new(
        chat => $self->{chat},
        session => $self->{session},
        debug => $self->{debug},
    );
    
    return $self;
}

=head2 handle_command($command)

Main command dispatcher. Routes slash commands to appropriate handlers.

Returns:
- 0: Exit signal (quit/exit command)
- 1: Continue (command handled)
- (1, $prompt): Continue with AI prompt (for commands that generate prompts)

=cut

sub handle_command {
    my ($self, $command) = @_;
    
    my $chat = $self->{chat};
    
    # Remove leading slash
    $command =~ s/^\///;
    
    # Split into command and args
    my ($cmd, @args) = split /\s+/, $command;
    $cmd = lc($cmd);
    
    # Route to appropriate handler
    if ($cmd eq 'exit' || $cmd eq 'quit' || $cmd eq 'q') {
        return 0;  # Signal to exit
    }
    elsif ($cmd eq 'help' || $cmd eq 'h') {
        $chat->display_help();
    }
    elsif ($cmd eq 'clear' || $cmd eq 'cls') {
        $chat->repaint_screen();
    }
    elsif ($cmd eq 'reset') {
        # Terminal reset - restore terminal to known-good state
        require CLIO::Compat::Terminal;
        CLIO::Compat::Terminal::reset_terminal();
        $chat->display_system_message("Terminal reset complete");
    }
    elsif ($cmd eq 'shell' || $cmd eq 'sh') {
        # Use extracted System command module
        $self->{system_cmd}->handle_shell_command();
    }
    elsif ($cmd eq 'debug') {
        $chat->{debug} = !$chat->{debug};
        $chat->display_system_message("Debug mode: " . ($chat->{debug} ? "ON" : "OFF"));
    }
    elsif ($cmd eq 'color') {
        $chat->{use_color} = !$chat->{use_color};
        $chat->display_system_message("Color mode: " . ($chat->{use_color} ? "ON" : "OFF"));
    }
    elsif ($cmd eq 'session') {
        # Use extracted Session command module
        $self->{session_cmd}->handle_session_command(@args);
    }
    elsif ($cmd eq 'config') {
        # Use extracted Config command module
        $self->{config_cmd}->handle_config_command(@args);
    }
    elsif ($cmd eq 'api') {
        # Use extracted API command module
        $self->{api_cmd}->handle_api_command(@args);
    }
    elsif ($cmd eq 'loglevel') {
        # Use extracted Config command module
        $self->{config_cmd}->handle_loglevel_command(@args);
    }
    elsif ($cmd eq 'style') {
        # Use extracted Config command module
        $self->{config_cmd}->handle_style_command(@args);
    }
    elsif ($cmd eq 'theme') {
        # Use extracted Config command module
        $self->{config_cmd}->handle_theme_command(@args);
    }
    elsif ($cmd eq 'login') {
        # Backward compatibility - redirect to /api login
        $chat->display_system_message("Note: Use '/api login' (new syntax)");
        $self->{api_cmd}->handle_login_command(@args);
    }
    elsif ($cmd eq 'logout') {
        # Backward compatibility - redirect to /api logout
        $chat->display_system_message("Note: Use '/api logout' (new syntax)");
        $self->{api_cmd}->handle_logout_command(@args);
    }
    elsif ($cmd eq 'file') {
        # Use extracted File command module
        $self->{file_cmd}->handle_file_command(@args);
    }
    elsif ($cmd eq 'edit') {
        # Backward compatibility
        $chat->display_system_message("Note: Use '/file edit <path>' (new syntax)");
        $self->{file_cmd}->handle_edit_command(join(' ', @args));
    }
    elsif ($cmd eq 'multi-line' || $cmd eq 'multiline' || $cmd eq 'ml') {
        # Use extracted System command module
        my $content = $self->{system_cmd}->handle_multiline_command();
        return (1, $content) if $content;  # Return content as AI prompt
    }
    elsif ($cmd eq 'performance' || $cmd eq 'perf') {
        # Use extracted System command module
        $self->{system_cmd}->handle_performance_command(@args);
    }
    elsif ($cmd eq 'todo') {
        # Use extracted Todo command module
        $self->{todo_cmd}->handle_todo_command(@args);
    }
    elsif ($cmd eq 'billing' || $cmd eq 'bill' || $cmd eq 'usage') {
        # Use extracted Billing command module
        $self->{billing_cmd}->handle_billing_command(@args);
    }
    elsif ($cmd eq 'models') {
        # Backward compatibility - redirect to /api models
        $chat->display_system_message("Note: Use '/api models' (new syntax)");
        $self->{api_cmd}->handle_models_command(@args);
    }
    elsif ($cmd eq 'context' || $cmd eq 'ctx') {
        # Use extracted Context command module
        $self->{context_cmd}->handle_context_command(@args);
    }
    elsif ($cmd eq 'skills' || $cmd eq 'skill') {
        # Use extracted Skills command module
        # Must capture list return value: (1, $prompt) for AI execution
        my @result = $self->{skills_cmd}->handle_skills_command(@args);
        return @result if @result > 1;  # Return (1, $prompt) if prompt was returned
    }
    elsif ($cmd eq 'prompt') {
        # Use extracted Prompt command module
        $self->{prompt_cmd}->handle_prompt_command(@args);
    }
    elsif ($cmd eq 'explain') {
        # Use extracted AI command module
        my $prompt = $self->{ai_cmd}->handle_explain_command(@args);
        return (1, $prompt) if $prompt;
    }
    elsif ($cmd eq 'review') {
        # Use extracted AI command module
        my $prompt = $self->{ai_cmd}->handle_review_command(@args);
        return (1, $prompt) if $prompt;
    }
    elsif ($cmd eq 'test') {
        # Use extracted AI command module
        my $prompt = $self->{ai_cmd}->handle_test_command(@args);
        return (1, $prompt) if $prompt;
    }
    elsif ($cmd eq 'fix') {
        # Use extracted AI command module
        my $prompt = $self->{ai_cmd}->handle_fix_command(@args);
        return (1, $prompt) if $prompt;
    }
    elsif ($cmd eq 'doc') {
        # Use extracted AI command module
        my $prompt = $self->{ai_cmd}->handle_doc_command(@args);
        return (1, $prompt) if $prompt;
    }
    elsif ($cmd eq 'git') {
        # Use extracted Git command module
        $self->{git_cmd}->handle_git_command(@args);
    }
    elsif ($cmd eq 'commit') {
        # Backward compatibility
        $chat->display_system_message("Note: Use '/git commit' (new syntax)");
        $self->{git_cmd}->handle_commit_command(@args);
    }
    elsif ($cmd eq 'diff') {
        # Backward compatibility
        $chat->display_system_message("Note: Use '/git diff' (new syntax)");
        $self->{git_cmd}->handle_diff_command(@args);
    }
    elsif ($cmd eq 'status' || $cmd eq 'st') {
        # Backward compatibility
        $chat->display_system_message("Note: Use '/git status' (new syntax)");
        $self->{git_cmd}->handle_status_command(@args);
    }
    elsif ($cmd eq 'log') {
        # Use extracted Log command module
        $self->{log_cmd}->handle_log_command(@args);
    }
    elsif ($cmd eq 'gitlog' || $cmd eq 'gl') {
        # Backward compatibility
        $chat->display_system_message("Note: Use '/git log' (new syntax)");
        $self->{git_cmd}->handle_gitlog_command(@args);
    }
    elsif ($cmd eq 'exec' || $cmd eq 'shell' || $cmd eq 'sh') {
        # Use extracted System command module
        $self->{system_cmd}->handle_exec_command(@args);
    }
    elsif ($cmd eq 'switch') {
        # Backward compatibility - redirect to /session switch
        $chat->display_system_message("Note: Use '/session switch' (new syntax)");
        $self->{session_cmd}->handle_switch_command(@args);
    }
    elsif ($cmd eq 'read' || $cmd eq 'view' || $cmd eq 'cat') {
        # Backward compatibility
        $chat->display_system_message("Note: Use '/file read <path>' (new syntax)");
        $self->{file_cmd}->handle_read_command(@args);
    }
    elsif ($cmd eq 'memory' || $cmd eq 'mem' || $cmd eq 'ltm') {
        # Use extracted Memory command module
        my $result = $self->{memory_cmd}->handle_memory_command(@args);
        return $result if $result;  # Returns (1, $prompt) for store command
    }
    elsif ($cmd eq 'update') {
        # Use extracted Update command module
        $self->{update_cmd}->handle_update_command(@args);
    }
    elsif ($cmd eq 'subagent' || $cmd eq 'agent') {
        # Multi-agent coordination
        my $subcommand = shift @args || 'help';
        my $result = $self->{subagent_cmd}->handle($subcommand, join(' ', @args));
        print "$result\n" if $result;
    }
    elsif ($cmd eq 'init') {
        # Use extracted Project command module
        my $prompt = $self->{project_cmd}->handle_init_command(@args);
        return (1, $prompt) if $prompt;  # Return prompt to be sent to AI
    }
    elsif ($cmd eq 'design') {
        # Use extracted Project command module
        my $prompt = $self->{project_cmd}->handle_design_command(@args);
        return (1, $prompt) if $prompt;  # Return prompt to be sent to AI
    }
    elsif ($cmd eq 'device' || $cmd eq 'dev') {
        # Device registry management
        CLIO::UI::Commands::Device::handle_device_command(join(' ', @args), { chat => $chat });
    }
    elsif ($cmd eq 'group') {
        # Device group management
        CLIO::UI::Commands::Device::handle_group_command(join(' ', @args), { chat => $chat });
    }
    elsif ($cmd eq 'undo') {
        $self->handle_undo_command(@args);
    }
    elsif ($cmd eq 'mcp') {
        $self->handle_mcp_command(@args);
    }
    elsif ($cmd eq 'stats') {
        $self->{stats_cmd}->handle_stats_command(@args);
    }
    else {
        $chat->display_error_message("Unknown command: /$cmd (type /help for help)");
    }
    
    print "\n";
    return 1;  # Continue
}

=head2 handle_undo_command

Revert file changes from the last AI turn using the snapshot system.

Usage:
    /undo          - Revert all changes from last turn
    /undo list     - Show recent snapshots
    /undo diff     - Show what would be reverted

=cut

sub handle_undo_command {
    my ($self, @args) = @_;
    
    my $chat = $self->{chat};
    my $subcommand = $args[0] || '';
    
    # Get snapshot from session state
    my $session = $self->{session};
    unless ($session && $session->can('state')) {
        $chat->display_error_message("No session available for undo");
        return;
    }
    
    my $state = $session->state();
    
    # Get orchestrator's snapshot object
    my $snapshot = $self->{ai_agent} && $self->{ai_agent}->{orchestrator} 
                 ? $self->{ai_agent}->{orchestrator}{snapshot} 
                 : undef;
    
    unless ($snapshot) {
        $chat->display_error_message("Snapshot system not available. Git may not be installed.");
        return;
    }
    
    if ($subcommand eq 'list') {
        # Show snapshot history
        my $history = $state->{snapshot_history} || [];
        if (!@$history) {
            $chat->display_system_message("No snapshots available yet.");
            return;
        }
        
        $chat->writeline("", markdown => 0);
        $chat->display_system_message("Recent snapshots (" . scalar(@$history) . "):");
        for my $i (reverse 0..$#$history) {
            my $snap = $history->[$i];
            my $ago = int((time() - $snap->{timestamp}) / 60);
            my $time_str = $ago < 1 ? "just now" : "${ago}m ago";
            my $hash_short = substr($snap->{hash}, 0, 8);
            my $input = $snap->{user_input} || '(no input)';
            $input =~ s/\n/ /g;
            $input = substr($input, 0, 60) . '...' if length($input) > 60;
            $chat->writeline("  [$hash_short] $time_str - $input", markdown => 0);
        }
        return;
    }
    
    if ($subcommand eq 'diff') {
        # Show what would be reverted
        my $last = $state->{last_snapshot};
        unless ($last) {
            $chat->display_system_message("No snapshot to diff against.");
            return;
        }
        
        my $diff = eval { $snapshot->diff($last) };
        if ($diff && length($diff) > 0) {
            $chat->writeline("", markdown => 0);
            $chat->display_system_message("Changes since last snapshot:");
            $chat->writeline("```diff\n$diff\n```", markdown => 1);
        } else {
            $chat->display_system_message("No changes detected since last snapshot.");
        }
        return;
    }
    
    # Default: undo last turn
    my $last = $state->{last_snapshot};
    unless ($last) {
        $chat->display_error_message("No snapshot available. Undo is only available after the AI makes file changes.");
        return;
    }
    
    # Check if there are actually changes to revert
    my $changes = eval { $snapshot->changed_files($last) };
    if (!$changes || !$changes->{files} || !@{$changes->{files}}) {
        $chat->display_system_message("No file changes to undo.");
        return;
    }
    
    my $file_count = scalar(@{$changes->{files}});
    my $file_list = join(', ', map { "`$_`" } @{$changes->{files}}[0..($file_count > 5 ? 4 : $file_count-1)]);
    $file_list .= " and " . ($file_count - 5) . " more" if $file_count > 5;
    
    $chat->display_system_message("Reverting $file_count file(s): $file_list");
    
    my $success = eval { $snapshot->revert($last) };
    if ($success) {
        $chat->display_system_message("Undo complete. Files reverted to state before last AI turn.");
        
        # Remove the used snapshot so we don't undo twice
        # Pop the last entry from history
        if ($state->{snapshot_history} && @{$state->{snapshot_history}}) {
            pop @{$state->{snapshot_history}};
        }
        # Set last_snapshot to the previous one if available
        if ($state->{snapshot_history} && @{$state->{snapshot_history}}) {
            $state->{last_snapshot} = $state->{snapshot_history}[-1]{hash};
        } else {
            delete $state->{last_snapshot};
        }
    } else {
        my $err = $@ || 'unknown error';
        $chat->display_error_message("Undo failed: $err");
    }
}

=head1 FUTURE COMMAND HANDLERS

The following methods will be gradually extracted from Chat.pm to this module:

- display_help
- handle_api_command
- handle_config_command
- handle_file_command
=head2 handle_mcp_command

Manage MCP (Model Context Protocol) server connections.

Usage:
    /mcp              - Show MCP server status
    /mcp list         - List connected servers and their tools
    /mcp add <name> <cmd...> - Add an MCP server
    /mcp remove <name>       - Remove an MCP server
    /mcp auth <name>         - Trigger OAuth authentication

=cut

sub handle_mcp_command {
    my ($self, @args) = @_;
    
    my $chat = $self->{chat};
    my $subcommand = $args[0] || '';
    
    # Get MCP manager from orchestrator
    my $mcp_manager = $self->{ai_agent} && $self->{ai_agent}->{orchestrator}
                    ? $self->{ai_agent}->{orchestrator}{mcp_manager}
                    : undef;
    
    unless ($mcp_manager) {
        $chat->display_system_message("MCP not initialized. Check that a compatible runtime (npx, node, python) is installed.");
        return;
    }
    
    unless ($mcp_manager->is_available()) {
        $chat->display_system_message("MCP disabled: no compatible runtime found (npx, node, uvx, or python).");
        $chat->display_system_message("Install Node.js (https://nodejs.org) to enable MCP support.");
        return;
    }
    
    if ($subcommand eq '' || $subcommand eq 'status') {
        # Show status of all servers
        my $status = $mcp_manager->server_status();
        
        unless ($status && keys %$status) {
            $chat->display_system_message("No MCP servers configured.");
            $chat->display_system_message("Add servers in ~/.clio/config.json under the \"mcp\" key, or use /mcp add <name> <command...>");
            return;
        }
        
        $chat->display_system_message("MCP Server Status:");
        $chat->display_system_message("");
        
        for my $name (sort keys %$status) {
            my $info = $status->{$name};
            my $indicator;
            if ($info->{status} eq 'connected') {
                my $tools = $info->{tools_count} || 0;
                my $server_name = $info->{server_info} ? ($info->{server_info}{name} || $name) : $name;
                $indicator = "  \x{2713} $name ($server_name) - $tools tool(s)";
            } elsif ($info->{status} eq 'disabled') {
                $indicator = "  \x{2212} $name (disabled)";
            } else {
                my $err = $info->{error} || 'unknown error';
                $indicator = "  \x{2717} $name (failed: $err)";
            }
            $chat->display_system_message($indicator);
        }
    }
    elsif ($subcommand eq 'list') {
        # List all tools from all connected servers
        my $all_tools = $mcp_manager->all_tools();
        
        unless ($all_tools && @$all_tools) {
            $chat->display_system_message("No MCP tools available. Check /mcp status for server connections.");
            return;
        }
        
        $chat->display_system_message("MCP Tools (" . scalar(@$all_tools) . " total):");
        $chat->display_system_message("");
        
        my $current_server = '';
        for my $entry (@$all_tools) {
            if ($entry->{server} ne $current_server) {
                $current_server = $entry->{server};
                $chat->display_system_message("  [$current_server]");
            }
            my $desc = $entry->{tool}{description} || 'no description';
            # Truncate long descriptions
            $desc = substr($desc, 0, 60) . '...' if length($desc) > 63;
            $chat->display_system_message("    mcp_$entry->{name}: $desc");
        }
    }
    elsif ($subcommand eq 'add') {
        my $name = $args[1];
        unless ($name) {
            $chat->display_error_message("Usage: /mcp add <name> <command...> OR /mcp add <name> <url>");
            $chat->display_system_message("Examples:");
            $chat->display_system_message("  /mcp add filesystem npx -y \@modelcontextprotocol/server-filesystem /tmp");
            $chat->display_system_message("  /mcp add remote-tools https://mcp.example.com/api");
            return;
        }
        
        my @rest = @args[2..$#args];
        unless (@rest) {
            $chat->display_error_message("No command or URL specified for MCP server '$name'");
            return;
        }
        
        # Detect if this is a URL (remote) or command (local)
        my $is_url = ($rest[0] =~ m{^https?://});
        
        $chat->display_system_message("Connecting to MCP server '$name'...");
        my $result;
        
        if ($is_url) {
            # Remote HTTP server
            $result = $mcp_manager->add_server($name, { url => $rest[0] });
            if ($result->{success}) {
                $self->_save_mcp_to_config($name, undef, $rest[0]);
            }
        } else {
            # Local stdio server
            $result = $mcp_manager->add_server($name, \@rest);
            if ($result->{success}) {
                $self->_save_mcp_to_config($name, \@rest);
            }
        }
        
        if ($result->{success}) {
            $chat->display_system_message("Connected to '$name' ($result->{tools_count} tools available)");
        } else {
            $chat->display_error_message("Failed to connect: $result->{error}");
        }
    }
    elsif ($subcommand eq 'remove') {
        my $name = $args[1];
        unless ($name) {
            $chat->display_error_message("Usage: /mcp remove <name>");
            return;
        }
        
        $mcp_manager->remove_server($name);
        $chat->display_system_message("Removed MCP server '$name'");
        
        # Also remove from config
        $self->_remove_mcp_from_config($name);
    }
    elsif ($subcommand eq 'auth') {
        # /mcp auth <name> - Manually trigger OAuth flow for a server
        my $name = $args[1];
        unless ($name) {
            $chat->display_error_message("Usage: /mcp auth <server-name>");
            $chat->display_system_message("Trigger OAuth authentication for an MCP server");
            return;
        }
        
        # Check if server has OAuth config
        my $config = $self->{config};
        my $mcp_config = ($config && ref($config) ne 'HASH' && $config->can('get'))
                       ? $config->get('mcp') : undef;
        
        my $server_config = $mcp_config ? $mcp_config->{$name} : undef;
        unless ($server_config && $server_config->{auth} && $server_config->{auth}{type} eq 'oauth') {
            $chat->display_error_message("Server '$name' does not have OAuth configured");
            $chat->display_system_message("Add auth config: { \"auth\": { \"type\": \"oauth\", \"authorization_url\": \"...\", \"token_url\": \"...\", \"client_id\": \"...\" } }");
            return;
        }
        
        eval {
            require CLIO::MCP::Auth::OAuth;
            my $ac = $server_config->{auth};
            my $oauth = CLIO::MCP::Auth::OAuth->new(
                server_name       => $name,
                authorization_url => $ac->{authorization_url},
                token_url         => $ac->{token_url},
                client_id         => $ac->{client_id},
                client_secret     => $ac->{client_secret},
                scopes            => $ac->{scopes} || [],
                redirect_port     => $ac->{redirect_port} || 8912,
                debug             => $self->{debug} || 0,
            );
            
            # Clear existing token to force re-auth
            $oauth->clear_token();
            
            my $token = $oauth->get_access_token();
            if ($token) {
                $chat->display_system_message("Authentication successful for '$name'");
                $chat->display_system_message("Token cached. Reconnect with /mcp remove $name && restart to use.");
            } else {
                $chat->display_error_message("Authentication failed for '$name'");
            }
        };
        if ($@) {
            $chat->display_error_message("OAuth error: $@");
        }
    }
    else {
        $chat->display_error_message("Unknown MCP subcommand: $subcommand");
        $chat->display_system_message("Usage: /mcp [status|list|add|remove|auth]");
    }
}

sub _save_mcp_to_config {
    my ($self, $name, $command, $url) = @_;
    
    eval {
        my $config = $self->{config};
        return unless $config && ref($config) ne 'HASH' && $config->can('get');
        
        my $mcp = $config->get('mcp') || {};
        
        if ($url) {
            # Remote server
            $mcp->{$name} = {
                type    => 'remote',
                url     => $url,
                enabled => JSON::PP::true,
            };
        } else {
            # Local server
            $mcp->{$name} = {
                command => $command,
                enabled => JSON::PP::true,
            };
        }
        
        $config->set('mcp', $mcp);
        
        my $chat = $self->{chat};
        $chat->display_system_message("Saved '$name' to MCP config") if $chat;
    };
    if ($@) {
        print STDERR "[WARN][CommandHandler] Failed to save MCP config: $@\n" if should_log('WARNING');
    }
}

sub _remove_mcp_from_config {
    my ($self, $name) = @_;
    
    eval {
        my $config = $self->{config};
        return unless $config && ref($config) ne 'HASH' && $config->can('get');
        
        my $mcp = $config->get('mcp') || {};
        delete $mcp->{$name};
        $config->set('mcp', $mcp);
    };
    if ($@) {
        print STDERR "[WARN][CommandHandler] Failed to update MCP config: $@\n" if should_log('WARNING');
    }
}

=head1 REMAINING EXTRACTIONS

=over 4

=item handle_git_command

=item handle_todo_command

=item handle_billing_command

=item handle_memory_command

=item handle_models_command

=item handle_session_command

=item handle_skills_command

=item And 25+ more...

=back

Each extraction will be tested before proceeding to the next.

=cut

1;

