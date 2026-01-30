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
        session => $args{session},
        config => $args{config},
        ai_agent => $args{ai_agent},
        debug => $args{debug} // 0,
    };
    
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
        my $result = $chat->handle_skills_command(@args);
        return $result if $result;  # May return (1, $prompt) for AI execution
    }
    elsif ($cmd eq 'prompt') {
        $chat->handle_prompt_command(@args);
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
        $chat->handle_update_command(@args);
    }
    elsif ($cmd eq 'init') {
        my $prompt = $chat->handle_init_command(@args);
        return (1, $prompt) if $prompt;  # Return prompt to be sent to AI
    }
    elsif ($cmd eq 'design') {
        my $prompt = $chat->handle_design_command(@args);
        return (1, $prompt) if $prompt;  # Return prompt to be sent to AI
    }
    else {
        $chat->display_error_message("Unknown command: /$cmd (type /help for help)");
    }
    
    print "\n";
    return 1;  # Continue
}

=head1 FUTURE COMMAND HANDLERS

The following methods will be gradually extracted from Chat.pm to this module:

- display_help
- handle_api_command
- handle_config_command
- handle_file_command
- handle_git_command
- handle_todo_command
- handle_billing_command
- handle_memory_command
- handle_models_command
- handle_session_command
- handle_skills_command
- And 25+ more...

Each extraction will be tested before proceeding to the next.

=cut

1;

