# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::UI::CommandHandler;

use strict;
use warnings;
use utf8;
use Carp qw(croak confess);
use CLIO::Core::Logger qw(log_warning);
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
use CLIO::UI::Commands::Mux;
use CLIO::UI::Commands::Profile;
use CLIO::UI::Commands::Spec;
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
    
    $self->{mux_cmd} = CLIO::UI::Commands::Mux->new(
        chat => $self->{chat},
        subagent_cmd => $self->{subagent_cmd},
        debug => $self->{debug},
    );
    
    $self->{stats_cmd} = CLIO::UI::Commands::Stats->new(
        chat => $self->{chat},
        session => $self->{session},
        debug => $self->{debug},
    );
    
    $self->{profile_cmd} = CLIO::UI::Commands::Profile->new(
        chat => $self->{chat},
        session => $self->{session},
        debug => $self->{debug},
    );
    
    $self->{spec_cmd} = CLIO::UI::Commands::Spec->new(
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
    
    # Build registry on first use
    $self->{_registry} ||= $self->_build_command_registry();
    
    # Look up command (direct or alias)
    my $entry = $self->{_registry}{$cmd};
    
    if (!$entry) {
        $chat->display_error_message("Unknown command: /$cmd (type /help for help)");
        print "\n";
        return 1;
    }
    
    # Show deprecation hint for backward-compat aliases
    if ($entry->{hint}) {
        $chat->display_system_message("Note: Use '$entry->{hint}' (new syntax)");
    }
    
    # Dispatch
    my @result = $entry->{handler}->(@args);
    
    # Handle special return values
    if ($entry->{returns} && $entry->{returns} eq 'exit') {
        return 0;
    }
    
    if ($entry->{returns} && $entry->{returns} eq 'prompt') {
        # Commands that may return (1, $prompt) for AI execution
        return @result if @result > 1;
    }
    
    print "\n";
    return 1;  # Continue
}

=head2 _build_command_registry

Build the command dispatch registry. Each entry maps a command name to:
- handler: coderef that receives @args
- hint: optional deprecation message for old syntax
- returns: 'exit', 'prompt', or undef for standard commands

=cut

sub _build_command_registry {
    my ($self) = @_;
    my $chat = $self->{chat};
    my %reg;
    
    # Helper to register a command with optional aliases
    my $register = sub {
        my ($names, %opts) = @_;
        my @names = ref $names ? @$names : ($names);
        for my $name (@names) {
            $reg{$name} = \%opts;
        }
    };
    
    # --- Exit ---
    $register->([qw(exit quit q)],
        handler => sub { return 0 },
        returns => 'exit',
    );
    
    # --- Core UI ---
    $register->([qw(help h)],
        handler => sub { $chat->display_help() },
    );
    $register->([qw(clear cls)],
        handler => sub { $chat->repaint_screen() },
    );
    $register->('reset',
        handler => sub { $self->_handle_reset_command() },
    );
    $register->('debug',
        handler => sub {
            $chat->{debug} = !$chat->{debug};
            $chat->display_system_message("Debug mode: " . ($chat->{debug} ? "ON" : "OFF"));
        },
    );
    $register->('color',
        handler => sub {
            $chat->{use_color} = !$chat->{use_color};
            $chat->display_system_message("Color mode: " . ($chat->{use_color} ? "ON" : "OFF"));
        },
    );
    
    # --- Primary commands (routed to extracted modules) ---
    $register->('session',   handler => sub { $self->{session_cmd}->handle_session_command(@_) });
    $register->('config',    handler => sub { $self->{config_cmd}->handle_config_command(@_) });
    $register->('api',       handler => sub { $self->{api_cmd}->handle_api_command(@_) });
    $register->('loglevel',  handler => sub { $self->{config_cmd}->handle_loglevel_command(@_) });
    $register->('style',     handler => sub { $self->{config_cmd}->handle_style_command(@_) });
    $register->('theme',     handler => sub { $self->{config_cmd}->handle_theme_command(@_) });
    $register->('file',      handler => sub { $self->{file_cmd}->handle_file_command(@_) });
    $register->('todo',      handler => sub { $self->{todo_cmd}->handle_todo_command(@_) });
    $register->('model',     handler => sub { $self->{api_cmd}->handle_model_command(@_) });
    $register->('prompt',    handler => sub { $self->{prompt_cmd}->handle_prompt_command(@_) });
    $register->('git',       handler => sub { $self->{git_cmd}->handle_git_command(@_) });
    $register->('log',       handler => sub { $self->{log_cmd}->handle_log_command(@_) });
    $register->('update',    handler => sub { $self->{update_cmd}->handle_update_command(@_) });
    $register->('undo',      handler => sub { $self->handle_undo_command(@_) });
    $register->('mcp',       handler => sub { $self->handle_mcp_command(@_) });
    $register->('plugin',    handler => sub { $self->handle_plugin_command(@_) });
    $register->('stats',     handler => sub { $self->{stats_cmd}->handle_stats_command(@_) });
    $register->([qw(context ctx)],
        handler => sub { $self->{context_cmd}->handle_context_command(@_) },
    );
    $register->([qw(billing bill usage)],
        handler => sub { $self->{billing_cmd}->handle_billing_command(@_) },
    );
    $register->([qw(performance perf)],
        handler => sub { $self->{system_cmd}->handle_performance_command(@_) },
    );
    $register->([qw(shell sh)],
        handler => sub { $self->{system_cmd}->handle_shell_command() },
    );
    $register->([qw(device dev)],
        handler => sub { CLIO::UI::Commands::Device::handle_device_command(join(' ', @_), { chat => $chat }) },
    );
    $register->('group',
        handler => sub { CLIO::UI::Commands::Device::handle_group_command(join(' ', @_), { chat => $chat }) },
    );
    
    # --- Commands that return prompts ---
    $register->([qw(multi-line multiline multi ml)],
        handler => sub { my $c = $self->{system_cmd}->handle_multiline_command(); return (1, $c) if $c; return () },
        returns => 'prompt',
    );
    $register->([qw(skills skill)],
        handler => sub { $self->{skills_cmd}->handle_skills_command(@_) },
        returns => 'prompt',
    );
    $register->([qw(memory mem ltm)],
        handler => sub { $self->{memory_cmd}->handle_memory_command(@_) },
        returns => 'prompt',
    );
    $register->([qw(profile)],
        handler => sub { $self->{profile_cmd}->handle_profile_command(@_) },
        returns => 'prompt',
    );
    $register->([qw(spec specs)],
        handler => sub { $self->{spec_cmd}->handle_spec_command(@_) },
        returns => 'prompt',
    );
    $register->('explain',
        handler => sub { my $p = $self->{ai_cmd}->handle_explain_command(@_); return (1, $p) if $p; return () },
        returns => 'prompt',
    );
    $register->('review',
        handler => sub { my $p = $self->{ai_cmd}->handle_review_command(@_); return (1, $p) if $p; return () },
        returns => 'prompt',
    );
    $register->('test',
        handler => sub { my $p = $self->{ai_cmd}->handle_test_command(@_); return (1, $p) if $p; return () },
        returns => 'prompt',
    );
    $register->('fix',
        handler => sub { my $p = $self->{ai_cmd}->handle_fix_command(@_); return (1, $p) if $p; return () },
        returns => 'prompt',
    );
    $register->('doc',
        handler => sub { my $p = $self->{ai_cmd}->handle_doc_command(@_); return (1, $p) if $p; return () },
        returns => 'prompt',
    );
    $register->('init',
        handler => sub { my $p = $self->{project_cmd}->handle_init_command(@_); return (1, $p) if $p; return () },
        returns => 'prompt',
    );
    $register->('design',
        handler => sub { my $p = $self->{project_cmd}->handle_design_command(@_); return (1, $p) if $p; return () },
        returns => 'prompt',
    );
    
    # --- Commands with subcommand dispatch ---
    $register->([qw(subagent agent)],
        handler => sub {
            my $sub = shift(@_) || 'help';
            my $r = $self->{subagent_cmd}->handle($sub, join(' ', @_));
            print "$r\n" if $r;
        },
    );
    $register->([qw(mux multiplexer)],
        handler => sub {
            my $sub = shift(@_) || 'help';
            my $r = $self->{mux_cmd}->handle($sub, join(' ', @_));
            print "$r\n" if $r;
        },
    );
    
    # --- Backward compatibility aliases ---
    $register->('login',
        handler => sub { $self->{api_cmd}->handle_login_command(@_) },
        hint    => '/api login',
    );
    $register->('logout',
        handler => sub { $self->{api_cmd}->handle_logout_command(@_) },
        hint    => '/api logout',
    );
    $register->('models',
        handler => sub { $self->{api_cmd}->handle_models_command(@_) },
        hint    => '/api models',
    );
    $register->('edit',
        handler => sub { $self->{file_cmd}->handle_edit_command(join(' ', @_)) },
        hint    => '/file edit <path>',
    );
    $register->('commit',
        handler => sub { $self->{git_cmd}->handle_commit_command(@_) },
        hint    => '/git commit',
    );
    $register->('diff',
        handler => sub { $self->{git_cmd}->handle_diff_command(@_) },
        hint    => '/git diff',
    );
    $register->([qw(status st)],
        handler => sub { $self->{git_cmd}->handle_status_command(@_) },
        hint    => '/git status',
    );
    $register->([qw(gitlog gl)],
        handler => sub { $self->{git_cmd}->handle_gitlog_command(@_) },
        hint    => '/git log',
    );
    $register->('switch',
        handler => sub { $self->{session_cmd}->handle_switch_command(@_) },
        hint    => '/session switch',
    );
    $register->([qw(read view cat)],
        handler => sub { $self->{file_cmd}->handle_read_command(@_) },
        hint    => '/file read <path>',
    );
    $register->('exec',
        handler => sub { $self->{system_cmd}->handle_exec_command(@_) },
    );
    
    return \%reg;
}

=head2 _handle_reset_command

Full terminal reset + kill stale child processes.

=cut

sub _handle_reset_command {
    my ($self) = @_;
    my $chat = $self->{chat};
    
    require CLIO::Compat::Terminal;
    
    my $result = CLIO::Compat::Terminal::kill_stale_children();
    my @killed = @{$result->{killed} || []};
    my @skipped = @{$result->{skipped} || []};
    
    CLIO::Compat::Terminal::reset_terminal_full();
    
    if (@killed) {
        $chat->display_system_message("Killed " . scalar(@killed) . " stale process(es):");
        for my $k (@killed) {
            $chat->display_system_message("  PID $k->{pid}: $k->{cmd}");
        }
    }
    if (@skipped) {
        $chat->display_system_message("Skipped " . scalar(@skipped) . " active process(es)");
    }
    $chat->display_system_message("Terminal reset complete");
}

=head2 handle_undo_command

Revert file changes from the last AI turn using the FileVault system.
FileVault tracks only the specific files CLIO modified, making undo fast
and available regardless of work tree size.

Usage:
    /undo          - Revert all changes from last turn
    /undo list     - Show recent turns with file changes
    /undo diff     - Show what would be reverted

=cut

sub handle_undo_command {
    my ($self, @args) = @_;
    
    my $chat = $self->{chat};
    my $subcommand = $args[0] || '';
    
    # Get session state
    my $session = $self->{session};
    unless ($session && $session->can('state')) {
        $chat->display_error_message("No session available for undo.");
        return;
    }
    
    my $state = $session->state();
    
    # Get orchestrator's FileVault object
    my $vault = $self->{ai_agent} && $self->{ai_agent}->{orchestrator} 
              ? $self->{ai_agent}->{orchestrator}{file_vault} 
              : undef;
    
    unless ($vault) {
        $chat->display_error_message("Undo system not available. This is unexpected - please report this as a bug.");
        return;
    }
    
    if ($subcommand eq 'list') {
        # Show turn history
        my $history = $state->{turn_history} || [];
        if (!@$history) {
            $chat->display_system_message("No undo history yet. History is created when the AI modifies files.");
            return;
        }
        
        $chat->writeline("", markdown => 0);
        $chat->display_system_message("Recent turns (" . scalar(@$history) . "):");
        for my $i (reverse 0..$#$history) {
            my $turn = $history->[$i];
            my $ago = int((time() - $turn->{timestamp}) / 60);
            my $time_str = $ago < 1 ? "just now" : "${ago}m ago";
            my $turn_id = $turn->{turn_id};
            my $input = $turn->{user_input} || '(no input)';
            $input =~ s/\n/ /g;
            $input = substr($input, 0, 60) . '...' if length($input) > 60;
            
            # Get file count for this turn
            my $changes = eval { $vault->changed_files($turn_id) };
            my $file_count = ($changes && $changes->{files}) ? scalar(@{$changes->{files}}) : 0;
            my $file_str = $file_count > 0 ? " ($file_count file" . ($file_count == 1 ? "" : "s") . ")" : "";
            
            $chat->writeline("  [$turn_id] $time_str$file_str - $input", markdown => 0);
        }
        return;
    }
    
    if ($subcommand eq 'diff') {
        # Show what would be reverted
        my $last = $state->{last_turn_id};
        unless ($last) {
            $chat->display_system_message("No changes to diff. The AI hasn't modified any files yet.");
            return;
        }
        
        my $diff = eval { $vault->diff($last) };
        if ($diff && length($diff) > 0) {
            $chat->writeline("", markdown => 0);
            $chat->display_system_message("Changes from last AI turn:");
            $chat->writeline("```diff\n$diff\n```", markdown => 1);
        } else {
            $chat->display_system_message("No file changes detected in the last turn.");
        }
        return;
    }
    
    # Default: undo last turn
    my $last = $state->{last_turn_id};
    unless ($last) {
        $chat->display_error_message("Nothing to undo. The AI hasn't modified any files yet.");
        return;
    }
    
    # Check if there are actually changes to revert
    my $changes = eval { $vault->changed_files($last) };
    if (!$changes || !$changes->{files} || !@{$changes->{files}}) {
        $chat->display_system_message("No file changes to undo in the last turn.");
        return;
    }
    
    my $file_count = scalar(@{$changes->{files}});
    my $file_list = join(', ', map { "`$_`" } @{$changes->{files}}[0..($file_count > 5 ? 4 : $file_count-1)]);
    $file_list .= " and " . ($file_count - 5) . " more" if $file_count > 5;
    
    $chat->display_system_message("Reverting $file_count file(s): $file_list");
    
    my $result = eval { $vault->undo_turn($last) };
    if ($result && $result->{success}) {
        $chat->display_system_message(
            "Undo complete. Reverted $result->{reverted} file(s) to their state before the last AI turn."
        );
        
        # Remove the used turn from vault and history
        $vault->remove_turn($last);
        
        if ($state->{turn_history} && @{$state->{turn_history}}) {
            pop @{$state->{turn_history}};
        }
        # Set last_turn_id to the previous one if available
        if ($state->{turn_history} && @{$state->{turn_history}}) {
            $state->{last_turn_id} = $state->{turn_history}[-1]{turn_id};
        } else {
            delete $state->{last_turn_id};
        }
    } elsif ($result && $result->{errors} && @{$result->{errors}}) {
        my $err_msg = "Undo partially completed ($result->{reverted} reverted). Errors:\n";
        $err_msg .= join("\n", map { "  - $_" } @{$result->{errors}});
        $chat->display_error_message($err_msg);
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
                enabled => \1,
            };
        } else {
            # Local server
            $mcp->{$name} = {
                command => $command,
                enabled => \1,
            };
        }
        
        $config->set('mcp', $mcp);
        
        my $chat = $self->{chat};
        $chat->display_system_message("Saved '$name' to MCP config") if $chat;
    };
    if ($@) {
        log_warning('CommandHandler', "Failed to save MCP config: $@");
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
        log_warning('CommandHandler', "Failed to update MCP config: $@");
    }
}

=head2 handle_plugin_command

Manage CLIO plugins.

Usage:
    /plugin              - List installed plugins and their status
    /plugin info <name>  - Show plugin details
    /plugin enable <name>  - Enable a plugin
    /plugin disable <name> - Disable a plugin
    /plugin config <name> <key> <value> - Set plugin configuration
    /plugin config <name> - Show plugin configuration

=cut

sub handle_plugin_command {
    my ($self, @args) = @_;

    my $chat = $self->{chat};
    my $subcommand = $args[0] || '';

    # Get or create plugin manager
    my $plugin_manager;
    eval {
        require CLIO::Core::PluginManager;
        $plugin_manager = CLIO::Core::PluginManager->instance();
    };

    unless ($plugin_manager) {
        $chat->display_system_message("Plugin system not initialized.");
        return;
    }

    if ($subcommand eq '' || $subcommand eq 'list') {
        my $plugins = $plugin_manager->get_plugin_list();

        unless ($plugins && @$plugins) {
            $chat->display_system_message("No plugins installed.");
            $chat->display_system_message("");
            $chat->display_system_message("Install plugins by creating directories in:");
            $chat->display_system_message("  ~/.clio/plugins/<name>/plugin.json   (global)");
            $chat->display_system_message("  .clio/plugins/<name>/plugin.json     (project)");
            return;
        }

        $chat->display_system_message("Installed Plugins:");
        $chat->display_system_message("");

        for my $p (@$plugins) {
            my $status = $p->{enabled} ? "\x{2713}" : "\x{2212}";
            my $tools = $p->{tools_count} || 0;
            my $desc = $p->{description} || '';
            my $ver = $p->{version} ? " v$p->{version}" : '';
            my $instr = $p->{has_instructions} ? ', instructions' : '';
            $chat->display_system_message("  $status $p->{name}${ver} - ${desc}");
            $chat->display_system_message("    ${tools} tool(s)${instr} | $p->{path}");
        }
    }
    elsif ($subcommand eq 'info') {
        my $name = $args[1];
        unless ($name) {
            $chat->display_error_message("Usage: /plugin info <name>");
            return;
        }

        my $plugin = $plugin_manager->get_plugin($name);
        unless ($plugin) {
            $chat->display_error_message("Plugin not found: $name");
            return;
        }

        my $manifest = $plugin->{manifest};
        $chat->display_system_message("Plugin: $name");
        $chat->display_system_message("  Description: " . ($manifest->{description} || 'none'));
        $chat->display_system_message("  Version: " . ($manifest->{version} || 'unknown'));
        $chat->display_system_message("  Enabled: " . ($plugin->{enabled} ? 'yes' : 'no'));
        $chat->display_system_message("  Path: $plugin->{path}");
        $chat->display_system_message("  Instructions: " . ($plugin->{instructions} ? 'yes' : 'no'));

        # Show tools
        my @tools = @{$manifest->{tools} || []};
        if (@tools) {
            $chat->display_system_message("  Tools:");
            for my $t (@tools) {
                my $type = $t->{type} || 'http';
                my $ops = $t->{operations} ? join(', ', sort keys %{$t->{operations}}) : 'none';
                $chat->display_system_message("    plugin_${name}_$t->{name} ($type): $ops");
            }
        }

        # Show config schema
        my $config_schema = $manifest->{config} || {};
        if (keys %$config_schema) {
            $chat->display_system_message("  Configuration:");
            my $resolved = $plugin_manager->get_plugin_config($name);
            for my $key (sort keys %$config_schema) {
                my $schema = $config_schema->{$key};
                my $required = $schema->{required} ? ' (required)' : '';
                my $is_secret = $schema->{secret};
                my $current = $resolved->{$key};
                my $display_val;
                if (defined $current) {
                    $display_val = $is_secret ? '****' : $current;
                } else {
                    $display_val = 'not set';
                }
                $chat->display_system_message("    $key = $display_val$required");
                if ($schema->{description}) {
                    $chat->display_system_message("      $schema->{description}");
                }
            }

            # Validate
            my ($valid, $missing) = $plugin_manager->validate_plugin_config($name);
            unless ($valid) {
                $chat->display_system_message("");
                $chat->display_error_message("Missing required config: " . join(', ', @$missing));
                $chat->display_system_message("Set with: /plugin config $name <key> <value>");
            }
        }
    }
    elsif ($subcommand eq 'enable') {
        my $name = $args[1];
        unless ($name) {
            $chat->display_error_message("Usage: /plugin enable <name>");
            return;
        }

        if ($plugin_manager->enable_plugin($name)) {
            $chat->display_system_message("Enabled plugin: $name");
            $chat->display_system_message("Plugin tools will be available in the next message.");
        } else {
            $chat->display_error_message("Plugin not found: $name");
        }
    }
    elsif ($subcommand eq 'disable') {
        my $name = $args[1];
        unless ($name) {
            $chat->display_error_message("Usage: /plugin disable <name>");
            return;
        }

        if ($plugin_manager->disable_plugin($name)) {
            $chat->display_system_message("Disabled plugin: $name");
        } else {
            $chat->display_error_message("Plugin not found: $name");
        }
    }
    elsif ($subcommand eq 'config') {
        my $name = $args[1];
        unless ($name) {
            $chat->display_error_message("Usage: /plugin config <name> [<key> <value>]");
            return;
        }

        my $plugin = $plugin_manager->get_plugin($name);
        unless ($plugin) {
            $chat->display_error_message("Plugin not found: $name");
            return;
        }

        my $key = $args[2];
        unless ($key) {
            # Show current config
            my $resolved = $plugin_manager->get_plugin_config($name);
            my $schema = $plugin->{manifest}{config} || {};

            if (!keys %$schema) {
                $chat->display_system_message("Plugin '$name' has no configurable settings.");
                return;
            }

            $chat->display_system_message("Configuration for '$name':");
            for my $k (sort keys %$schema) {
                my $s = $schema->{$k};
                my $current = $resolved->{$k};
                my $display = defined($current) ? ($s->{secret} ? '****' : $current) : 'not set';
                my $required = $s->{required} ? ' (required)' : '';
                $chat->display_system_message("  $k = $display$required");
            }
            return;
        }

        my $value = join(' ', @args[3..$#args]);
        unless (defined $value && length $value) {
            $chat->display_error_message("Usage: /plugin config $name $key <value>");
            return;
        }

        $plugin_manager->set_plugin_config($name, $key, $value);
        my $is_secret = ($plugin->{manifest}{config}{$key} || {})->{secret};
        my $display = $is_secret ? '****' : $value;
        $chat->display_system_message("Set $name.$key = $display");
    }
    else {
        $chat->display_error_message("Unknown plugin subcommand: $subcommand");
        $chat->display_system_message("Usage: /plugin [list|info|enable|disable|config]");
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

