# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::UI::Commands::API;

use strict;
use warnings;
use utf8;
use parent 'CLIO::UI::Commands::Base';
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Carp qw(croak);
use CLIO::Core::Logger qw(log_debug);

use CLIO::UI::Commands::API::Auth;
use CLIO::UI::Commands::API::Models;
use CLIO::UI::Commands::API::Config;

=head1 NAME

CLIO::UI::Commands::API - Router for /api slash commands

=head1 SYNOPSIS

  my $api_cmd = CLIO::UI::Commands::API->new(
      chat => $chat, config => $config,
      session => $session, ai_agent => $agent,
  );
  $api_cmd->handle_api_command('show');
  $api_cmd->handle_api_command('set', 'model', 'gpt-4.1');

=head1 DESCRIPTION

Thin router that dispatches /api sub-commands to focused modules:

  Auth   - login, logout, quota
  Models - /model, /api models, model listing
  Config - /api set, /api show, /api providers, /api alias

=cut

sub new {
    my ($class, %args) = @_;

    my $self = $class->SUPER::new(%args);
    $self->{config}   = $args{config};
    $self->{session}  = $args{session};
    $self->{ai_agent} = $args{ai_agent};

    my %common = (
        chat     => $args{chat},
        config   => $args{config},
        session  => $args{session},
        ai_agent => $args{ai_agent},
        debug    => $args{debug} // 0,
    );

    $self->{auth}   = CLIO::UI::Commands::API::Auth->new(%common);
    $self->{models} = CLIO::UI::Commands::API::Models->new(%common);
    $self->{cfg}    = CLIO::UI::Commands::API::Config->new(%common);

    return $self;
}

=head2 handle_api_command($action, @args)

Main dispatcher for /api commands.

=cut

sub handle_api_command {
    my ($self, $action, @args) = @_;

    $action ||= '';
    $action = lc($action);

    # Parse --session flag
    my $session_only = 0;
    @args = grep {
        if ($_ eq '--session') { $session_only = 1; 0; } else { 1; }
    } @args;

    if ($action eq '' || $action eq 'help')  { $self->_display_api_help(); return; }
    if ($action eq 'show')                   { $self->{cfg}->display_config(); return; }
    if ($action eq 'set') {
        my $setting = shift @args || '';
        my $value = shift @args;
        $self->{cfg}->handle_set($setting, $value, $session_only);
        return;
    }
    if ($action eq 'models')    { $self->{models}->handle_models(@args); return; }
    if ($action eq 'providers') { $self->{cfg}->display_providers(@args); return; }
    if ($action eq 'login')     { $self->{auth}->handle_login(@args); return; }
    if ($action eq 'logout')    { $self->{auth}->handle_logout(@args); return; }
    if ($action eq 'quota')     { $self->{auth}->handle_quota(@args); return; }
    if ($action eq 'alias')     { $self->{cfg}->handle_alias(@args); return; }

    # Backward compatibility
    if ($action eq 'key') {
        $self->display_system_message("Note: Use '/api set key <value>' (new syntax)");
        $self->{cfg}->handle_set('key', $args[0], 0);
        return;
    }
    if ($action eq 'base') {
        $self->display_system_message("Note: Use '/api set base <url>' (new syntax)");
        $self->{cfg}->handle_set('base', $args[0], $session_only);
        return;
    }
    if ($action eq 'model') {
        $self->display_system_message("Note: Use '/api set model <name>' (new syntax)");
        $self->{cfg}->handle_set('model', $args[0], $session_only);
        return;
    }
    if ($action eq 'provider') {
        $self->display_system_message("Note: Use '/api set provider <name>' (new syntax)");
        $self->{cfg}->handle_set('provider', $args[0], $session_only);
        return;
    }

    $self->display_error_message("Unknown action: /api $action");
    $self->_display_api_help();
}

# Public interface methods called by CommandHandler

sub handle_login_command   { shift->{auth}->handle_login(@_) }
sub handle_logout_command  { shift->{auth}->handle_logout(@_) }
sub handle_models_command  { shift->{models}->handle_models(@_) }
sub handle_model_command   { shift->{models}->handle_model(@_) }
sub handle_quota_command   { shift->{auth}->handle_quota(@_) }
sub check_github_auth      { shift->{auth}->check_github_auth(@_) }

sub _display_api_help {
    my ($self) = @_;

    $self->display_command_header("API - Configure AI Provider");

    $self->display_section_header("QUICK START - Discover Available Providers");
    $self->writeline("  Type: /api providers              Show all available AI providers", markdown => 0);
    $self->writeline("  Then: /api providers <name>      Get setup instructions for that provider", markdown => 0);
    $self->writeline("", markdown => 0);

    $self->display_section_header("SETUP COMMANDS");
    $self->display_command_row("/api show", "Display current configuration", 40);
    $self->writeline("", markdown => 0);

    $self->display_section_header("ALL COMMANDS");
    $self->display_command_row("/api show", "Display current API configuration", 40);
    $self->display_command_row("/api set model <name>", "Set AI model", 40);
    $self->display_command_row("/api set model <provider>/<model>", "Set model with provider prefix", 40);
    $self->display_command_row("/api set provider <name>", "Set provider (anthropic, google, etc.)", 40);
    $self->display_command_row("/api set base <url>", "Set API base URL", 40);
    $self->display_command_row("/api set key <value>", "Set API key (stored per-provider)", 40);
    $self->display_command_row("/api set thinking on|off", "Show model reasoning output", 40);
    $self->display_command_row("/api set github_pat <token>", "Set GitHub PAT for extended models", 40);
    $self->display_command_row("/api providers", "Show available providers", 40);
    $self->display_command_row("/api models", "List available models", 40);
    $self->display_command_row("/api models --refresh", "Refresh models (bypass cache)", 40);
    $self->display_command_row("/api login", "Authenticate with GitHub Copilot", 40);
    $self->display_command_row("/api logout", "Sign out from GitHub", 40);
    $self->display_command_row("/api quota", "Show provider quota (Copilot, MiniMax Token Plan)", 40);
    $self->display_command_row("/api alias", "List model aliases", 40);
    $self->display_command_row("/api alias <name> <model>", "Create model alias", 40);
    $self->display_command_row("/api alias <name> --delete", "Remove alias", 40);
    $self->writeline("", markdown => 0);

    $self->display_section_header("PROVIDERS");
    $self->display_command_row("github_copilot", "GitHub Copilot (OAuth login)", 40);
    $self->display_command_row("anthropic", "Anthropic Claude (native API) [EXPERIMENTAL]", 40);
    $self->display_command_row("google", "Google Gemini (native API) [EXPERIMENTAL]", 40);
    $self->display_command_row("openai", "OpenAI (compatible API)", 40);
    $self->display_command_row("openrouter", "OpenRouter (multi-model gateway)", 40);
    $self->display_command_row("minimax", "MiniMax (native API)", 40);
    $self->display_command_row("sam", "Local SAM server", 40);
    $self->display_command_row("llama.cpp", "Local llama.cpp server", 40);
    $self->display_command_row("lmstudio", "Local LM Studio server", 40);
    $self->display_command_row("custom", "Custom OpenAI-compatible API", 40);
    $self->writeline("", markdown => 0);

    $self->display_section_header("EXAMPLES");
    $self->writeline("  " . $self->colorize("/api set provider github_copilot", 'USER') . "  Switch to GitHub Copilot", markdown => 0);
    $self->writeline("  " . $self->colorize("/api login", 'USER') . "                        Authenticate with GitHub", markdown => 0);
    $self->writeline("  " . $self->colorize("/api set model gpt-4.1", 'USER') . "            Set model (uses current provider)", markdown => 0);
    $self->writeline("  " . $self->colorize("/api set model openrouter/deepseek/deepseek-r1", 'USER') . "  Cross-provider model", markdown => 0);
    $self->writeline("", markdown => 0);
}

1;

__END__

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

Same as CLIO.

=cut
