# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::UI::Commands::Config;

use strict;
use warnings;
use utf8;
use parent 'CLIO::UI::Commands::Base';

use Carp qw(croak);
use CLIO::UI::Terminal qw(box_char);
use File::Spec;
use CLIO::Util::PathResolver qw(expand_tilde);

=head1 NAME

CLIO::UI::Commands::Config - Configuration commands for CLIO

=head1 SYNOPSIS

  use CLIO::UI::Commands::Config;
  
  my $config_cmd = CLIO::UI::Commands::Config->new(
      chat => $chat_instance,
      config => $config,
      session => $session,
      debug => 0
  );
  
  # Handle /config commands
  $config_cmd->handle_config_command('show');
  $config_cmd->handle_loglevel_command('DEBUG');
  $config_cmd->handle_style_command('set', 'dark');
  $config_cmd->handle_theme_command('list');

=head1 DESCRIPTION

Handles all configuration-related commands including:
- /config show|set|save|load|workdir|loglevel
- /loglevel - Log level management
- /style - Color scheme management
- /theme - Output template management

Extracted from Chat.pm to improve maintainability.

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
    
    bless $self, $class;
    return $self;
}


=head2 handle_config_command(@args)

Main dispatcher for /config commands.

=cut

sub handle_config_command {
    my ($self, @args) = @_;
    
    unless ($self->{config}) {
        $self->display_error_message("Configuration system not available");
        return;
    }
    
    my $action = $args[0] || '';
    my $arg1 = $args[1] || '';
    my $arg2 = $args[2] || '';
    
    $action = lc($action);
    
    # /config (no args) - show help
    if ($action eq '' || $action eq 'help') {
        $self->_display_config_help();
        return;
    }
    
    # /config show - display global config
    if ($action eq 'show') {
        $self->show_global_config();
        return;
    }
    
    # /config set <key> <value> - set a config value
    if ($action eq 'set') {
        $self->_handle_config_set($arg1, $arg2);
        return;
    }
    
    # /config save - save configuration
    if ($action eq 'save') {
        my $theme_mgr = $self->{chat}->{theme_mgr};
        my $current_style = $theme_mgr->get_current_style();
        my $current_theme = $theme_mgr->get_current_theme();
        
        $self->{config}->set('style', $current_style);
        $self->{config}->set('theme', $current_theme);
        require Cwd;
        $self->{config}->set('working_directory', Cwd::getcwd());
        
        if ($self->{config}->save()) {
            $self->display_system_message("Configuration saved successfully");
        } else {
            $self->display_error_message("Failed to save configuration");
        }
        return;
    }
    
    # /config load - reload configuration
    if ($action eq 'load') {
        $self->{config}->load();
        $self->display_system_message("Configuration reloaded");
        return;
    }
    
    # /config workdir [path] - get/set working directory
    if ($action eq 'workdir') {
        if ($arg1) {
            # Set working directory
            my $dir = $arg1;
            $dir = expand_tilde($dir);
            
            unless (-d $dir) {
                $self->display_error_message("Directory does not exist: $dir");
                return;
            }
            
            require Cwd;
            $dir = Cwd::abs_path($dir);
            
            if ($self->{session} && $self->{session}->state()) {
                my $state = $self->{session}->state();
                $state->{working_directory} = $dir;
                $self->{session}->save();
                $self->display_system_message("Working directory set to: $dir");
            } else {
                $self->display_error_message("No active session");
            }
        } else {
            # Show working directory
            require Cwd;
            my $dir = '.';
            if ($self->{session} && $self->{session}->state()) {
                $dir = $self->{session}->state()->{working_directory} || Cwd::getcwd();
            }
            $self->display_system_message("Working directory: $dir");
        }
        return;
    }
    
    # /config loglevel [level] - get/set log level
    if ($action eq 'loglevel') {
        $self->handle_loglevel_command($arg1);
        return;
    }
    
    # Unknown action
    $self->display_error_message("Unknown action: /config $action");
    $self->_display_config_help();
}

=head2 _display_config_help

Display help for /config commands using unified style.

=cut

sub _display_config_help {
    my ($self) = @_;
    
    $self->display_command_header("CONFIG");
    
    $self->display_section_header("COMMANDS");
    $self->display_command_row("/config show", "Display global configuration", 35);
    $self->display_command_row("/config set <key> <value>", "Set a configuration value", 35);
    $self->display_command_row("/config save", "Save current configuration", 35);
    $self->display_command_row("/config load", "Reload from disk", 35);
    $self->display_command_row("/config workdir [path]", "Get or set working directory", 35);
    $self->display_command_row("/config loglevel [level]", "Get or set log level", 35);
    $self->writeline("", markdown => 0);
    
    $self->display_section_header("SETTABLE KEYS");
    $self->display_key_value("style", "UI color scheme", 25);
    $self->display_key_value("theme", "Banner and template theme", 25);
    $self->display_key_value("show_banner", "Display startup banner (on/off, override: --no-banner)", 25);
    $self->display_key_value("workdir", "Working directory path", 25);
    $self->display_key_value("terminal_passthrough", "Force direct terminal access", 25);
    $self->display_key_value("terminal_autodetect", "Auto-detect interactive commands", 25);
    $self->display_key_value("redact_level", "Redaction level: strict|standard|api_permissive|pii|off", 25);
    $self->display_key_value("security_level", "Command security: relaxed|standard|strict", 25);
    $self->display_key_value("sanitize_mode", "Text filter: strict|relaxed", 25);
    $self->display_key_value("enable_subagents", "Enable/disable sub-agent spawning (on/off)", 25);
    $self->display_key_value("enable_remote", "Enable/disable remote execution (on/off)", 25);
    $self->display_key_value("auto_discover_skills", "Inject installed skill catalog into system prompt (on/off)", 25);
    $self->writeline("", markdown => 0);
    
    $self->display_section_header("REDACTION LEVELS");
    $self->display_key_value("strict", "Redact all (PII + crypto + API keys + tokens)", 25);
    $self->display_key_value("standard", "Same as strict", 25);
    $self->display_key_value("api_permissive", "Allow API keys/tokens (PII + crypto redacted)", 25);
    $self->display_key_value("pii", "Only redact PII (default)", 25);
    $self->display_key_value("off", "No redaction (use with caution)", 25);
    $self->writeline("", markdown => 0);
    
    $self->display_section_header("COMMAND SECURITY LEVELS");
    $self->display_key_value("relaxed", "Only block system-destructive commands", 25);
    $self->display_key_value("standard", "Prompt for high-risk commands (default)", 25);
    $self->display_key_value("strict", "Prompt for all risky commands", 25);
    $self->writeline("", markdown => 0);
    
    $self->display_section_header("EXAMPLES");
    $self->display_command_row("/config set style dark", "Switch to dark color scheme", 35);
    $self->display_command_row("/config set theme photon", "Use photon theme", 35);
    $self->display_command_row("/config workdir ~/projects", "Change working directory", 35);
    $self->display_command_row("/config set redact_level api_permissive", "Allow API keys in agent output", 35);
    $self->display_command_row("/config set security_level strict", "Prompt for all risky commands", 35);
    $self->display_command_row("/config set sanitize_mode relaxed", "Quiet filtering for binary data work", 35);
    $self->display_command_row("/config set enable_subagents off", "Disable sub-agent tool", 35);
    $self->display_command_row("/config set enable_remote off", "Disable remote execution tool", 35);
    $self->display_command_row("/config set auto_discover_skills off", "Hide skill catalog and disable skill_operations tool", 35);
    $self->display_command_row("/config set show_banner off", "Suppress the startup banner", 35);
    $self->writeline("", markdown => 0);
    
    $self->display_section_header("TIPS");
    $self->display_tip("For API settings, use /api set");
    $self->display_tip("terminal_autodetect detects vim, nano, GPG, ssh, etc.");
    $self->display_tip("Use api_permissive when agent needs to work with API tokens");
    $self->display_tip("Feature toggles take effect on next session start");
    $self->writeline("", markdown => 0);
}

=head2 _handle_config_set

Handle /config set <key> <value>

=cut

sub _handle_config_set {
    my ($self, $key, $value) = @_;
    
    $key = lc($key || '');
    
    unless ($key) {
        $self->display_error_message("Usage: /config set <key> <value>");
        $self->writeline("Keys: style, theme, show_banner, working_directory, terminal_passthrough, terminal_autodetect, redact_level, security_level, sanitize_mode, enable_subagents, enable_remote, auto_discover_skills", markdown => 0);
        return;
    }
    
    unless (defined $value && $value ne '') {
        $self->display_error_message("Usage: /config set $key <value>");
        return;
    }
    
    # Validate allowed keys
    my %allowed = (
        style => 1,
        theme => 1,
        show_banner => 1,
        working_directory => 1,
        terminal_passthrough => 1,
        terminal_autodetect => 1,
        redact_level => 1,
        redact_secrets => 1,  # Deprecated, for backward compat
        security_level => 1,
        sanitize_mode => 1,
        enable_subagents => 1,
        enable_remote => 1,
        auto_discover_skills => 1,
    );
    
    unless ($allowed{$key}) {
        $self->display_error_message("Unknown config key: $key");
        $self->writeline("Allowed keys: " . join(', ', sort keys %allowed), markdown => 0);
        return;
    }
    
    # Handle redact_level (new multi-level system)
    if ($key eq 'redact_level') {
        my %valid_levels = map { $_ => 1 } qw(strict standard api_permissive pii off);
        unless ($valid_levels{$value}) {
            $self->display_error_message("Invalid redact_level: $value");
            $self->writeline("Valid levels: strict, standard, api_permissive, pii, off", markdown => 0);
            return;
        }
        
        $self->{config}->set('redact_level', $value);
        $self->{config}->save();
        
        my %level_desc = (
            strict => "Redact all: PII, crypto, API keys, tokens",
            standard => "Redact all: PII, crypto, API keys, tokens",
            api_permissive => "Allow API keys/tokens (PII and crypto still redacted)",
            pii => "Only redact PII (SSN, credit cards, phone, email)",
            off => "No redaction - sensitive data may be exposed",
        );
        
        $self->display_system_message("Redaction level set to: $value");
        $self->display_info_message($level_desc{$value});
        
        if ($value eq 'off') {
            $self->display_info_message("WARNING: All secrets and PII may be exposed to the AI and logs");
        }
        return;
    }
    
    # Handle security_level
    if ($key eq 'security_level') {
        my %valid_levels = map { $_ => 1 } qw(relaxed standard strict);
        unless ($valid_levels{$value}) {
            $self->display_error_message("Invalid security_level: $value");
            $self->writeline("Valid levels: relaxed, standard, strict", markdown => 0);
            return;
        }
        
        $self->{config}->set('security_level', $value);
        $self->{config}->save();
        
        my %level_desc = (
            relaxed => "Only block system-destructive commands (no prompts for network/credential access)",
            standard => "Prompt for high-risk commands (network transfers, credential access)",
            strict  => "Prompt for all risky commands including medium-risk (ssh, sudo, env dumps)",
        );
        
        $self->display_system_message("Security level set to: $value");
        $self->display_info_message($level_desc{$value});
        
        if ($value eq 'relaxed') {
            $self->display_info_message("WARNING: Network and credential access commands will not be flagged");
        }
        return;
    }
    
    # Handle sanitize_mode
    if ($key eq 'sanitize_mode') {
        my %valid_modes = map { $_ => 1 } qw(strict relaxed);
        unless ($valid_modes{$value}) {
            $self->display_error_message("Invalid sanitize_mode: $value");
            $self->writeline("Valid modes: strict, relaxed", markdown => 0);
            return;
        }
        
        $self->{config}->set('sanitize_mode', $value);
        $self->{config}->save();
        
        # Apply immediately to TextSanitizer
        eval {
            require CLIO::Util::TextSanitizer;
            CLIO::Util::TextSanitizer::set_sanitize_mode($value);
        };
        
        my %mode_desc = (
            strict  => "Warn on invisible character injection (default, recommended)",
            relaxed => "Filter invisible chars silently (for binary/hex data analysis)",
        );
        
        $self->display_system_message("Sanitize mode set to: $value");
        $self->display_info_message($mode_desc{$value});
        return;
    }
    
    # Handle deprecated redact_secrets -> convert to redact_level
    if ($key eq 'redact_secrets') {
        $self->display_info_message("Note: redact_secrets is deprecated. Use redact_level instead.");
        my $level;
        if ($value =~ /^(true|1|yes|on)$/i) {
            $level = 'standard';
        } elsif ($value =~ /^(false|0|no|off)$/i) {
            $level = 'off';
        } else {
            $self->display_error_message("Invalid boolean value for $key: $value");
            $self->writeline("Use: true/false, 1/0, yes/no, on/off", markdown => 0);
            return;
        }
        $self->{config}->set('redact_level', $level);
        $self->{config}->save();
        $self->display_system_message("Converted to redact_level: $level");
        return;
    }
    
    # Handle boolean values for terminal toggle settings
    if ($key =~ /^(terminal_|enable_|show_)/) {
        if ($value =~ /^(true|1|yes|on)$/i) {
            $value = 1;
        } elsif ($value =~ /^(false|0|no|off)$/i) {
            $value = 0;
        } else {
            $self->display_error_message("Invalid boolean value for $key: $value");
            $self->writeline("Use: true/false, 1/0, yes/no, on/off", markdown => 0);
            return;
        }
        
        if ($key eq 'terminal_passthrough') {
            if ($value) {
                $self->display_info_message("Passthrough mode: All commands will execute with direct terminal access");
                $self->display_info_message("Agent will see exit codes but not command output");
            } else {
                $self->display_info_message("Passthrough mode disabled: Output will be captured for agent");
                $self->display_info_message("Auto-detection (terminal_autodetect) may still enable passthrough for interactive commands");
            }
        } elsif ($key eq 'terminal_autodetect') {
            if ($value) {
                $self->display_info_message("Auto-detect enabled: Interactive commands (git commit, vim, GPG) will use passthrough automatically");
            } else {
                $self->display_info_message("Auto-detect disabled: All commands will capture output unless terminal_passthrough is true");
            }
        } elsif ($key eq 'enable_subagents') {
            if ($value) {
                $self->display_info_message("Sub-agents enabled: agent_operations tool will be available");
            } else {
                $self->display_info_message("Sub-agents disabled: agent_operations tool will be hidden from AI");
            }
            $self->{config}->set($key, $value);
            $self->{config}->save();
            $self->display_system_message("Restart session for changes to take effect");
            return;
        } elsif ($key eq 'enable_remote') {
            if ($value) {
                $self->display_info_message("Remote execution enabled: remote_execution tool will be available");
            } else {
                $self->display_info_message("Remote execution disabled: remote_execution tool will be hidden from AI");
            }
            $self->{config}->set($key, $value);
            $self->{config}->save();
            $self->display_system_message("Restart session for changes to take effect");
            return;
        } elsif ($key eq 'auto_discover_skills') {
            if ($value) {
                $self->display_info_message("Skill auto-discovery enabled: installed skill catalog will be injected into the system prompt");
            } else {
                $self->display_info_message("Skill auto-discovery disabled: skill catalog hidden and skill_operations tool removed");
            }
            $self->{config}->set($key, $value);
            $self->{config}->save();
            $self->display_system_message("Restart session for changes to take effect");
            return;
        } elsif ($key eq 'show_banner') {
            if ($value) {
                $self->display_info_message("Startup banner will be shown on next session");
            } else {
                $self->display_info_message("Startup banner will be suppressed on next session. Use --no-banner for one-off.");
            }
            $self->{config}->set($key, $value);
            $self->{config}->save();
            return;
        }
    }
    
    # Handle style separately
    if ($key eq 'style') {
        my $theme_mgr = $self->{chat}->{theme_mgr};
        if ($theme_mgr->set_style($value)) {
            if ($self->{session} && $self->{session}->state()) {
                $self->{session}->state()->{style} = $value;
                $self->{session}->save();
            }
            $self->display_system_message("Style set to: $value");
        } else {
            $self->display_error_message("Style '$value' not found. Use /style list to see available styles.");
        }
        return;
    }
    
    # Handle theme separately
    if ($key eq 'theme') {
        my $theme_mgr = $self->{chat}->{theme_mgr};
        if ($theme_mgr->set_theme($value)) {
            if ($self->{session} && $self->{session}->state()) {
                $self->{session}->state()->{theme} = $value;
                $self->{session}->save();
            }
            $self->display_system_message("Theme set to: $value");
        } else {
            $self->display_error_message("Theme '$value' not found. Use /theme list to see available themes.");
        }
        return;
    }
    
    # Set the config value
    if ($key eq 'working_directory') {
        # Validate directory exists and is accessible
        require CLIO::Util::InputHelpers;
        my ($valid, $result) = CLIO::Util::InputHelpers::validate_directory($value, 1, 0);
        unless ($valid) {
            $self->display_error_message($result);
            return;
        }
        $value = $result;  # Use validated/normalized path
    }
    
    $self->{config}->set($key, $value);
    $self->display_system_message("Config '$key' set to: $value");
    $self->display_system_message("Use /config save to persist");
}

=head2 show_global_config

Display global configuration in formatted view

=cut

sub show_global_config {
    my ($self) = @_;
    
    $self->display_command_header("GLOBAL CONFIGURATION");
    
    # API Settings
    $self->display_section_header("API Settings");
    
    my $provider = $self->{config}->get('provider');
    unless ($provider) {
        my $api_base = $self->{config}->get('api_base') || '';
        my $presets = $self->{config}->get('provider_presets') || {};
        if ($api_base && $presets) {
            for my $p (keys %$presets) {
                if ($presets->{$p}->{base} eq $api_base) {
                    $provider = $p;
                    last;
                }
            }
        }
    }
    $provider ||= 'unknown';
    
    require CLIO::Providers;
    my $model = $self->{config}->get('model') || CLIO::Providers::DEFAULT_MODEL();
    my $api_key = $self->{config}->get('api_key');
    my $api_base = $self->{config}->get('api_base');
    
    # Check for authentication status
    my $auth_status = '[NOT SET]';
    if ($api_key && length($api_key) > 0) {
        $auth_status = '[SET]';
    } elsif ($provider eq 'github_copilot') {
        eval {
            require CLIO::Core::GitHubAuth;
            my $gh_auth = CLIO::Core::GitHubAuth->new(debug => 0);
            my $token = $gh_auth->get_copilot_token();
            if ($token) {
                $auth_status = '[TOKEN]';
            } else {
                $auth_status = '[NO TOKEN - use /login]';
            }
        };
        if ($@) {
            $auth_status = '[NOT SET]';
        }
    }
    
    $self->display_key_value("Provider", $provider, 18);
    $self->display_key_value("Model", $model, 18);
    $self->display_key_value("API Key", $auth_status, 18);
    
    my $display_url = $api_base || '[default]';
    $self->display_key_value("API Base URL", $display_url, 18);
    
    # UI Settings
    $self->writeline("", markdown => 0);
    $self->display_section_header("UI Settings");
    my $style = $self->{config}->get('style') || 'default';
    my $theme = $self->{config}->get('theme') || 'default';
    my $loglevel = $ENV{CLIO_LOG_LEVEL} || $self->{config}->get('log_level') || 'WARNING';
    
    $self->display_key_value("Color Style", $style, 18);
    $self->display_key_value("Output Theme", $theme, 18);
    $self->display_key_value("Log Level", $loglevel, 18);
    
    # Security Settings
    $self->writeline("", markdown => 0);
    $self->display_section_header("Security");
    
    # Get redact_level (new), fall back to redact_secrets (deprecated)
    my $redact_level = $self->{config}->get('redact_level');
    unless ($redact_level) {
        my $redact_secrets = $self->{config}->get('redact_secrets');
        if (defined $redact_secrets) {
            $redact_level = $redact_secrets ? 'standard' : 'off';
        } else {
            $redact_level = 'pii';  # Default
        }
    }
    
    my %level_desc = (
        strict => '(all: PII + crypto + keys + tokens)',
        standard => '(all: PII + crypto + keys + tokens)',
        api_permissive => '(PII + crypto, allows API keys)',
        pii => '(SSN, credit cards, phone, email only)',
        off => '(DISABLED - use with caution)',
    );
    my $redact_display = "$redact_level " . ($level_desc{$redact_level} || '');
    $self->display_key_value("Redact Level", $redact_display, 18);
    
    # Command security level
    my $security_level = $self->{config}->get('security_level') || 'standard';
    my %sec_desc = (
        relaxed  => '(block destructive only)',
        standard => '(prompt for high-risk commands)',
        strict   => '(prompt for all risky commands)',
    );
    my $security_display = "$security_level " . ($sec_desc{$security_level} || '');
    $self->display_key_value("Security Level", $security_display, 18);
    
    # Sanitize mode
    my $sanitize_mode = $self->{config}->get('sanitize_mode') || 'strict';
    my %san_desc = (
        strict  => '(warn on invisible char injection)',
        relaxed => '(filter silently, for binary data)',
    );
    my $sanitize_display = "$sanitize_mode " . ($san_desc{$sanitize_mode} || '');
    $self->display_key_value("Sanitize Mode", $sanitize_display, 18);
    
    # Sandbox status
    my $sandbox = $self->{config}->get('sandbox') ? 'ACTIVE' : 'off';
    $self->display_key_value("Sandbox", $sandbox, 18);
    
    # Feature Switches
    $self->writeline("", markdown => 0);
    $self->display_section_header("Features");
    my $subagents = $self->{config}->get('enable_subagents');
    $subagents = 1 unless defined $subagents;
    my $remote = $self->{config}->get('enable_remote');
    $remote = 1 unless defined $remote;
    my $auto_discover_skills = $self->{config}->get('auto_discover_skills');
    $auto_discover_skills = 1 unless defined $auto_discover_skills;
    $self->display_key_value("Sub-agents", $subagents ? 'enabled' : 'disabled', 18);
    $self->display_key_value("Remote Exec", $remote ? 'enabled' : 'disabled', 18);
    $self->display_key_value("Skill Auto-Discover", $auto_discover_skills ? 'enabled' : 'disabled', 18);
    
    # Paths
    $self->writeline("", markdown => 0);
    $self->display_section_header("Paths & Files");
    require Cwd;
    my $workdir = $self->{config}->get('working_directory') || Cwd::getcwd();
    my $config_file = $self->{config}->{config_file};
    
    $self->display_key_value("Working Dir", $workdir, 18);
    $self->display_key_value("Config File", $config_file, 18);
    $self->display_key_value("Sessions Dir", File::Spec->catdir('.', 'sessions'), 18);
    $self->display_key_value("Styles Dir", File::Spec->catdir('.', 'styles'), 18);
    $self->display_key_value("Themes Dir", File::Spec->catdir('.', 'themes'), 18);
    
    $self->writeline("", markdown => 0);
    $self->display_info_message("Use '/config save' to persist changes");
    $self->writeline("", markdown => 0);
}

=head2 show_session_config

Display session-specific configuration

=cut

sub show_session_config {
    my ($self) = @_;
    
    my $state = $self->{session}->state();
    
    $self->writeline("", markdown => 0);
    $self->writeline($self->colorize("SESSION CONFIGURATION", 'DATA'), markdown => 0);
    $self->writeline($self->colorize(box_char("hhorizontal") x 51, "DIM"), markdown => 0);
    $self->writeline("", markdown => 0);
    
    $self->writeline($self->colorize("Session Info:", 'SYSTEM'), markdown => 0);
    $self->writeline(sprintf("  Session ID:   %s", $state->{session_id}), markdown => 0);
    $self->writeline(sprintf("  Messages:     %d", scalar(@{$state->{history} || []})), markdown => 0);
    require Cwd;
    $self->writeline(sprintf("  Working Dir:  %s", $state->{working_directory} || Cwd::getcwd()), markdown => 0);
    
    $self->writeline("", markdown => 0);
    $self->writeline($self->colorize("UI Settings:", 'SYSTEM'), markdown => 0);
    my $session_style = $state->{style} || $self->{config}->get('style') || 'default';
    my $session_theme = $state->{theme} || $self->{config}->get('theme') || 'default';
    $self->writeline(sprintf("  Style:        %s%s", $session_style, ($state->{style} ? '' : ' (from global)')), markdown => 0);
    $self->writeline(sprintf("  Theme:        %s%s", $session_theme, ($state->{theme} ? '' : ' (from global)')), markdown => 0);
    
    $self->writeline("", markdown => 0);
    $self->writeline($self->colorize("Model:", 'SYSTEM'), markdown => 0);
    require CLIO::Providers;
    my $session_model = $state->{selected_model} || $self->{config}->get('model') || CLIO::Providers::DEFAULT_MODEL();
    $self->writeline(sprintf("  Selected:     %s%s", $session_model, ($state->{selected_model} ? '' : ' (from global)')), markdown => 0);
    
    $self->writeline("", markdown => 0);
}

=head2 handle_loglevel_command

Handle /loglevel command

=cut

sub handle_loglevel_command {
    my ($self, $level) = @_;
    
    unless ($level) {
        my $current = $ENV{CLIO_LOG_LEVEL} || $self->{config}->get('log_level') || 'WARNING';
        $self->writeline("", markdown => 0);
        $self->writeline($self->colorize("CURRENT LOG LEVEL", 'DATA'), markdown => 0);
        $self->writeline($self->colorize(box_char("hhorizontal") x 51, "DIM"), markdown => 0);
        $self->writeline("", markdown => 0);
        $self->writeline("  $current", markdown => 0);
        $self->writeline("  Levels: ERROR, WARNING, INFO, DEBUG", markdown => 0);
        $self->writeline("", markdown => 0);
        return;
    }
    
    my %valid = map { $_ => 1 } qw(DEBUG INFO WARNING ERROR);
    
    unless ($valid{uc($level)}) {
        $self->display_error_message("Invalid log level: $level");
        $self->writeline("Valid levels: DEBUG, INFO, WARNING, ERROR", markdown => 0);
        return;
    }
    
    my $new_level = uc($level);
    
    # Set env var so Logger picks it up immediately for all modules
    $ENV{CLIO_LOG_LEVEL} = $new_level;
    
    # Persist to config
    $self->{config}->set('log_level', $new_level);
    $self->{config}->save();
    
    $self->display_system_message("Log level set to: $new_level (saved)");
}

=head2 handle_style_command

Handle /style command - manage color schemes

=cut

sub handle_style_command {
    my ($self, $action, @args) = @_;
    
    my $theme_mgr = $self->{chat}->{theme_mgr};
    
    # Default to 'show' if no action provided
    $action ||= 'show';
    
    # If action is not a known command, treat it as "set <action>"
    unless ($action =~ /^(list|show|set|save)$/) {
        unshift @args, $action;
        $action = 'set';
    }
    
    if ($action eq 'list') {
        my @styles = $theme_mgr->list_styles();
        my $current = $theme_mgr->get_current_style();
        
        $self->writeline($self->colorize(box_char("hhorizontal") . " AVAILABLE STYLES " . box_char("hhorizontal") . (box_char("hhorizontal") x 41), "DATA"), markdown => 0);
        $self->writeline("", markdown => 0);
        for my $style (@styles) {
            my $marker = ($style eq $current) ? ' (current)' : '';
            $self->writeline(sprintf("  %-20s%s", $style, $self->colorize($marker, 'PROMPT')), markdown => 0);
        }
        $self->writeline("", markdown => 0);
        $self->writeline("Use " . $self->colorize("/style set <name>", 'PROMPT') . " to switch styles", markdown => 0);
    }
    elsif ($action eq 'show') {
        my $current = $theme_mgr->get_current_style();
        $self->writeline($self->colorize(box_char("hhorizontal") . " CURRENT STYLE " . box_char("hhorizontal") . (box_char("hhorizontal") x 47), "DATA"), markdown => 0);
        $self->writeline("", markdown => 0);
        $self->writeline("  " . $self->colorize($current, 'USER'), markdown => 0);
        $self->writeline("", markdown => 0);
    }
    elsif ($action eq 'set') {
        my $name = $args[0];
        unless ($name) {
            $self->display_error_message("Usage: /style set <name>");
            return;
        }
        
        if ($theme_mgr->set_style($name)) {
            $self->{session}->state()->{style} = $name;
            $self->{session}->save();
            $self->display_system_message("Style changed to: $name");
            # Re-render header to show new style immediately
            if ($self->{chat} && $self->{chat}->can('display_header')) {
                $self->{chat}->display_header();
            }
        } else {
            $self->display_error_message("Style '$name' not found. Use /style list to see available styles.");
        }
    }
    elsif ($action eq 'save') {
        my $name = $args[0];
        unless ($name) {
            $self->display_error_message("Usage: /style save <name>");
            return;
        }
        
        if ($theme_mgr->save_style($name)) {
            $self->display_system_message("Style saved as: $name");
            $self->display_system_message("Use " . $self->colorize("/style set $name", 'PROMPT') . " to activate later.");
        } else {
            $self->display_error_message("Failed to save style");
        }
    }
}

=head2 handle_theme_command

Handle /theme command - manage output templates

=cut

sub handle_theme_command {
    my ($self, $action, @args) = @_;
    
    my $theme_mgr = $self->{chat}->{theme_mgr};
    
    # Default to 'show' if no action provided
    $action ||= 'show';
    
    # If action is not a known command, treat it as "set <action>"
    unless ($action =~ /^(list|show|set|save)$/) {
        unshift @args, $action;
        $action = 'set';
    }
    
    if ($action eq 'list') {
        my @themes = $theme_mgr->list_themes();
        my $current = $theme_mgr->get_current_theme();
        
        $self->writeline($self->colorize(box_char("hhorizontal") . " AVAILABLE THEMES " . box_char("hhorizontal") . (box_char("hhorizontal") x 41), "DATA"), markdown => 0);
        $self->writeline("", markdown => 0);
        for my $theme (@themes) {
            my $marker = ($theme eq $current) ? ' (current)' : '';
            $self->writeline(sprintf("  %-20s%s", $theme, $self->colorize($marker, 'PROMPT')), markdown => 0);
        }
        $self->writeline("", markdown => 0);
        $self->writeline("Use " . $self->colorize("/theme set <name>", 'PROMPT') . " to switch themes", markdown => 0);
    }
    elsif ($action eq 'show') {
        my $current = $theme_mgr->get_current_theme();
        $self->writeline($self->colorize(box_char("hhorizontal") . " CURRENT THEME " . box_char("hhorizontal") . (box_char("hhorizontal") x 47), "DATA"), markdown => 0);
        $self->writeline("", markdown => 0);
        $self->writeline("  " . $self->colorize($current, 'USER'), markdown => 0);
        $self->writeline("", markdown => 0);
    }
    elsif ($action eq 'set') {
        my $name = $args[0];
        unless ($name) {
            $self->display_error_message("Usage: /theme set <name>");
            return;
        }
        
        if ($theme_mgr->set_theme($name)) {
            $self->{session}->state()->{theme} = $name;
            $self->{session}->save();
            $self->display_system_message("Theme changed to: $name");
            # Re-render header to show new theme immediately
            if ($self->{chat} && $self->{chat}->can('display_header')) {
                $self->{chat}->display_header();
            }
        } else {
            $self->display_error_message("Theme '$name' not found. Use /theme list to see available themes.");
        }
    }
    elsif ($action eq 'save') {
        my $name = $args[0];
        unless ($name) {
            $self->display_error_message("Usage: /theme save <name>");
            return;
        }
        
        if ($theme_mgr->save_theme($name)) {
            $self->display_system_message("Theme saved as: $name");
            $self->display_system_message("Use " . $self->colorize("/theme set $name", 'PROMPT') . " to activate later.");
        } else {
            $self->display_error_message("Failed to save theme");
        }
    }
}

=head2 handle_preview_command

Render a recognizable sample of UI output using a temporary style/theme
without persisting the change. Lets users audition a look before committing
via /style set or /theme set.

    /preview                  Show current style + theme
    /preview style [<name>]   Preview a style (or current if name omitted)
    /preview theme [<name>]   Preview a theme (or current if name omitted)

=cut

sub handle_preview_command {
    my ($self, @args) = @_;

    my $theme_mgr = $self->{chat}->{theme_mgr};
    unless ($theme_mgr) {
        $self->display_error_message("Theme manager not available");
        return;
    }

    my $action = lc($args[0] // '');
    my $target = $args[1] // '';

    # /preview (no args) -> preview the current style and theme.
    if ($action eq '' || $action eq 'show' || $action eq 'current') {
        $self->_render_preview_sample(
            style => $theme_mgr->get_current_style(),
            theme => $theme_mgr->get_current_theme(),
            label => 'current',
        );
        return;
    }

    if ($action eq 'style') {
        my $name = $target ne '' ? $target : $theme_mgr->get_current_style();
        unless (exists $theme_mgr->{styles}->{$name}) {
            $self->display_error_message("Style '$name' not found. Use /style list to see options.");
            return;
        }
        $self->_render_preview_sample(
            style => $name,
            theme => $theme_mgr->get_current_theme(),
            label => $target ne '' ? "style: $name" : "current style: $name",
        );
        return;
    }

    if ($action eq 'theme') {
        my $name = $target ne '' ? $target : $theme_mgr->get_current_theme();
        unless (exists $theme_mgr->{themes}->{$name}) {
            $self->display_error_message("Theme '$name' not found. Use /theme list to see options.");
            return;
        }
        $self->_render_preview_sample(
            style => $theme_mgr->get_current_style(),
            theme => $name,
            label => $target ne '' ? "theme: $name" : "current theme: $name",
        );
        return;
    }

    $self->display_error_message("Usage: /preview [style|theme] [<name>]");
}

# Internal: swap to (style, theme) without persisting, render a sample,
# then restore. The original style/theme are restored regardless of any
# error during rendering so /preview is always safe to run.
sub _render_preview_sample {
    my ($self, %opts) = @_;

    my $theme_mgr = $self->{chat}->{theme_mgr};
    my $orig_style = $theme_mgr->get_current_style();
    my $orig_theme = $theme_mgr->get_current_theme();

    my $new_style = $opts{style} // $orig_style;
    my $new_theme = $opts{theme} // $orig_theme;

    # Apply the requested style+theme for this preview only.
    $theme_mgr->set_style($new_style);
    $theme_mgr->set_theme($new_theme);

    # Header banner
    my $label = $opts{label} // "$new_style + $new_theme";
    $self->display_command_header("PREVIEW: $label");

    eval {
        # Section 1: Banner (uses theme templates).
        $self->writeline("", markdown => 0);
        $self->writeline($self->colorize("[ BANNER ]", 'ASSISTANT'), markdown => 0);
        my $banner_line = $theme_mgr->render('banner_line1', {
            agent_name      => 'CLIO',
            agent_subtitle  => 'AI Assistant',
        });
        $self->writeline($banner_line, markdown => 0);

        # Section 2: User message and agent response
        $self->writeline("", markdown => 0);
        $self->writeline($self->colorize("[ CONVERSATION ]", 'ASSISTANT'), markdown => 0);
        my $user_prefix = $theme_mgr->render('user_message_prefix');
        $self->writeline(
            $self->colorize($user_prefix, 'USER') . $self->colorize("Read lib/CLIO/Core/Config.pm and summarize the load() method.", 'USER'),
            markdown => 0,
        );
        my $agent_prefix = $theme_mgr->render('agent_message_prefix', { agent_name => 'CLIO' });
        $self->writeline(
            $self->colorize($agent_prefix, 'ASSISTANT') . $self->colorize("Config->load() reads .clio/config.json and merges it with defaults.", 'DATA'),
            markdown => 0,
        );

        # Section 3: Thinking block
        $self->writeline("", markdown => 0);
        $self->writeline($self->colorize("[ THINKING ]", 'ASSISTANT'), markdown => 0);
        my $bullet      = box_char('topleft') . box_char('horizontal') . box_char('horizontal') . box_char('tleft') . ' ';
        my $bullet_color = $theme_mgr->get_color('muted') // '';
        my $name_color   = $theme_mgr->get_color('ASSISTANT') || $theme_mgr->get_color('agent_label') || '';
        my $data_color   = $theme_mgr->get_color('agent_text') || $theme_mgr->get_color('value') || '';
        my $reset        = "\e[0m";
        $self->writeline(
            "${bullet_color}${bullet}${reset}" .
            "${name_color}THINKING${reset} " .
            "${bullet_color}${bullet}${reset}",
            markdown => 0,
        );
        $self->writeline(
            "${data_color}    Reading the file structure and identifying the load() function.${reset}",
            markdown => 0,
        );

        # Section 4: Tool header (inline format)
        $self->writeline("", markdown => 0);
        $self->writeline($self->colorize("[ TOOL CALL ]", 'ASSISTANT'), markdown => 0);
        my $tool_bullet = box_char('bullet') . ' ';
        my $tool_sep    = ' -> ';
        $self->writeline(
            "${bullet_color}${tool_bullet}${name_color}FILE OPERATIONS${reset} " .
            "${bullet_color}${tool_sep}${data_color}reading lib/CLIO/Core/Config.pm (1247 bytes)${reset}",
            markdown => 0,
        );

        # Section 5: Status indicators
        $self->writeline("", markdown => 0);
        $self->writeline($self->colorize("[ STATUS ]", 'ASSISTANT'), markdown => 0);
        $self->writeline($self->colorize('ERROR:', 'error') . ' ' . $self->colorize('Sample error message', 'DATA'), markdown => 0);
        $self->writeline($self->colorize('WARN:', 'warning') . '  ' . $self->colorize('Sample warning message', 'DATA'), markdown => 0);
        $self->writeline($self->colorize('OK:', 'success') . '   ' . $self->colorize('Sample success message', 'DATA'), markdown => 0);
        $self->writeline($self->colorize('INFO:', 'info') . '  ' . $self->colorize('Sample info message', 'DATA'), markdown => 0);

        # Section 6: Markdown
        $self->writeline("", markdown => 0);
        $self->writeline($self->colorize("[ MARKDOWN ]", 'ASSISTANT'), markdown => 0);
        $self->writeline(
            $theme_mgr->get_color('markdown_h1') . '# Heading 1' . $reset . ' ' .
            $theme_mgr->get_color('markdown_bold') . 'bold' . $reset . ' ' .
            $theme_mgr->get_color('markdown_italic') . 'italic' . $reset . ' ' .
            $theme_mgr->get_color('markdown_code') . 'inline code' . $reset,
            markdown => 0,
        );

        # Section 7: Input prompt
        $self->writeline("", markdown => 0);
        $self->writeline($self->colorize("[ PROMPT ]", 'ASSISTANT'), markdown => 0);
        my $input_prompt = $theme_mgr->render('input_prompt', { prompt => 'clio>' });
        $self->writeline($input_prompt, markdown => 0);
    };

    if ($@) {
        # Render error inline but continue to restore originals below.
        $self->writeline("", markdown => 0);
        $self->display_error_message("Preview render error: $@");
    }

    # Always restore originals - /preview never persists.
    $theme_mgr->set_style($orig_style);
    $theme_mgr->set_theme($orig_theme);

    $self->writeline("", markdown => 0);
    $self->display_info_message("Preview only - active style/theme unchanged.");
}

1;

__END__

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

Same as CLIO.

=cut

1;
