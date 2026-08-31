# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::UI::Commands::API;

use strict;
use warnings;
use utf8;
use parent 'CLIO::UI::Commands::Base';

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
    if ($action eq 'route')     { $self->{cfg}->handle_route(@args); return; }
    if ($action eq 'remove' || $action eq 'rm') { $self->{cfg}->handle_remove(@args); return; }

    # Backward compatibility
    if ($action eq 'key') {
        $self->display_warning_message("Deprecated syntax. Use '/api set key <value>' instead.");
        $self->{cfg}->handle_set('key', $args[0], 0);
        return;
    }
    if ($action eq 'base') {
        $self->display_warning_message("Deprecated syntax. Use '/api set base <url>' instead.");
        $self->{cfg}->handle_set('base', $args[0], $session_only);
        return;
    }
    if ($action eq 'model') {
        $self->display_warning_message("Deprecated syntax. Use '/api set model <name>' instead.");
        $self->{cfg}->handle_set('model', $args[0], $session_only);
        return;
    }
    if ($action eq 'provider') {
        $self->display_warning_message("Deprecated syntax. Use '/api set provider <name>' instead.");
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

    # Enable pagination for long help output
    $self->{chat}{pager}->enable();

    # Data-driven: each section is a hashref with header + lines/rows.
    # The display loop bails out on the first item that returns false
    # (Q pressed during pagination) - fixes #28 where Q in /api help was
    # ignored and the rest of the help scrolled past.
    my @sections = (
        { header => 'QUICK START - Discover Available Providers',
          lines  => [
            '  Type: /api providers              Show all available AI providers',
            '  Then: /api providers <name>      Get setup instructions for that provider',
            '',
          ],
        },
        { header => 'SETUP COMMANDS',
          rows   => [['/api show', 'Display current configuration', 40]],
          lines  => [''],
        },
        { header => 'ALL COMMANDS',
          rows   => [
            ['/api show',                         'Display current API configuration', 40],
            ['/api set model <name>',             'Set AI model (saved globally)', 40],
            ['/api set model <provider>/<model>', 'Set model with provider prefix', 40],
            ['/api set model "m1 m2 m3"',        'Set multiple models for routing (auto-fallback)', 40],
            ['/api route add <name> m1 m2...',   'Save a named model routing profile', 40],
            ['/api route list',                  'List saved routing profiles and settings', 40],
            ['/api route use <name>',            'Activate a named routing profile', 40],
            ['/api route replace <name> m1 m2...', 'Replace a routing profile\'s models', 40],
            ['/api route remove <name>',         'Delete a routing profile', 40],
            ['/api route verbose [on|off]',      'Show or toggle rerouting system messages (default: on)', 40],
            ['/api route set delay <seconds>',   'Wait between model switches on routing (default: 1.0)', 40],
            ['/api route set max_attempts <N>',  'Max total routing attempts before giving up (default: 15)', 40],
            ['/api set provider <name>',          'Set provider (google, minimax, etc.)', 40],
            ['/api set base <url>',               'Set API base URL', 40],
            ['/api set key <value>',              'Set API key (stored per-provider)', 40],
            ['/api set thinking on|off',          'Show model reasoning output', 40],
            ['/api set thinking_effort low|medium|high|xhigh|max', 'Reasoning depth (xhigh/max require Anthropic 4.6+ adaptive)', 40],
            ['/api set thinking_mode auto|enabled|disabled', 'Thinking on/off mode (default: auto; auto=adaptive for Anthropic)', 40],
            ['/api set temperature <value>',      'Override sampling temperature', 40],
            ['/api set top_p <value>',            'Override top_p sampling', 40],
            ['/api set top_k <value>',            'Override top_k sampling', 40],
            ['/api set context_window <value>',   'Cap context window (e.g. 128k, 256000, reset)', 40],
            ['/api set max_output <value>',       'Cap max output tokens (e.g. 16k, reset)', 40],
            ['/api set max_prompt <value>',       'Cap max prompt tokens (e.g. 200k, reset)', 40],
            ['/api set tools on|off|auto',        'Force tool calling on/off (auto = model default)', 40],
            ['/api set vision on|off|auto',       'Force vision support on/off', 40],
            ['/api set reasoning on|off|auto',    'Force reasoning support on/off', 40],
            ['/api set github_pat <token>',       'Set GitHub PAT for extended models', 40],
            ['/api providers',                    'Show available providers', 40],
            ['/api models',                       'List available models', 40],
            ['/api models --refresh',             'Refresh models (bypass cache)', 40],
            ['/api login',                        'Authenticate with GitHub Copilot', 40],
            ['/api logout',                       'Sign out from GitHub', 40],
            ['/api quota',                        'Show provider quota (Copilot, MiniMax Token Plan)', 40],
            ['/api alias',                        'List model aliases', 40],
            ['/api alias <name> <model>',         'Create model alias', 40],
            ['/api alias <name> --delete',        'Remove alias', 40],
            ['/api remove <provider>',            'Remove stored credentials for a provider', 40],
          ],
          lines => [''],
        },
        { header => 'CAPABILITY OVERRIDES',
          lines  => [
            '  Caps and forces apply to the current model\'s reported capabilities.',
            '  Token values accept k/M suffixes: ' . $self->colorize('128000, 128k, 1M', 'USER'),
            '  Use ' . $self->colorize('reset', 'USER') . ' or ' . $self->colorize('auto', 'USER') . ' to clear and use model default.',
            '  Example: /api set context_window 128k caps DeepSeek\'s 1M context to 128k',
            '',
          ],
        },
        { header => 'SESSION OVERRIDES',
          lines  => [
            '  Add --session to set model/provider/base for this session only:',
          ],
          rows   => [
            ['/api set model <name> --session',    'Set model for this session only', 40],
            ['/api set provider <name> --session', 'Set provider for this session only', 40],
            ['/api set base <url> --session',      'Set API base for this session only', 40],
          ],
          after_rows => [
            '  Session overrides are shown in /api show and the session header.',
            '',
          ],
        },
        { header => 'PROVIDERS',
          rows   => [
            ['anthropic',         'Anthropic (native API, Claude models)', 40],
            ['deepseek',          'DeepSeek (compatible API)', 40],
            ['github_copilot',    'GitHub Copilot (OAuth login)', 40],
            ['google',            'Google Gemini (native API) [EXPERIMENTAL]', 40],
            ['minimax',           'MiniMax (native API)', 40],
            ['minimax_token',     'MiniMax Token Plan', 40],
            ['nvidia',            'NVIDIA NIM (compatible API)', 40],
            ['ollama_cloud',      'Ollama Cloud (compatible API)', 40],
            ['openai',            'OpenAI (compatible API)', 40],
            ['openrouter',        'OpenRouter (multi-model gateway)', 40],
            ['zai',               'Z.AI (GLM-5.1 flagship, vision, reasoning)', 40],
            ['zai_coding',        'Z.AI Coding Plan (free GLM-4.7/5 for coding)', 40],
            ['custom',            'Custom OpenAI-compatible API', 40],
            ['llama.cpp',         'Local llama.cpp server', 40],
            ['lmstudio',          'Local LM Studio server', 40],
            ['sam',               'Local SAM server', 40],
          ],
          lines => [''],
        },
        { header => 'EXAMPLES',
          lines  => [
            '  ' . $self->colorize('/api set provider github_copilot', 'USER') . '  Switch to GitHub Copilot',
            '  ' . $self->colorize('/api login', 'USER') . '                        Authenticate with GitHub',
            '  ' . $self->colorize('/api set model gpt-4.1', 'USER') . '            Set model (uses current provider)',
            '  ' . $self->colorize('/api set model openrouter/deepseek/deepseek-r1', 'USER') . '  Cross-provider model',
            '',
          ],
        },
    );

    return unless $self->display_command_header("API - Configure AI Provider");

    for my $section (@sections) {
        return unless $self->display_section_header($section->{header});
        for my $line (@{$section->{lines} || []}) {
            return unless $self->writeline($line, markdown => 0);
        }
        for my $row (@{$section->{rows} || []}) {
            return unless $self->display_command_row(@{$row});
        }
        for my $line (@{$section->{after_rows} || []}) {
            return unless $self->writeline($line, markdown => 0);
        }
    }

    # Disable pagination after command completes
    $self->{chat}{pager}->disable();
}

1;

__END__

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

Same as CLIO.

=cut

1;
