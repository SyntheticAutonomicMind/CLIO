package CLIO::UI::Commands::Config;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Carp qw(croak);
use File::Spec;

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

# Delegate display methods to chat
sub display_command_header { shift->{chat}->display_command_header(@_) }
sub display_section_header { shift->{chat}->display_section_header(@_) }
sub display_key_value { shift->{chat}->display_key_value(@_) }
sub display_command_row { shift->{chat}->display_command_row(@_) }
sub display_list_item { shift->{chat}->display_list_item(@_) }
sub display_tip { shift->{chat}->display_tip(@_) }
sub display_system_message { shift->{chat}->display_system_message(@_) }
sub display_error_message { shift->{chat}->display_error_message(@_) }
sub writeline { shift->{chat}->writeline(@_) }
sub display_info_message { shift->{chat}->display_info_message(@_) }
sub colorize { shift->{chat}->colorize(@_) }

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
            $dir =~ s/^~/$ENV{HOME}/;  # Expand tilde
            
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
    $self->display_key_value("workdir", "Working directory path", 25);
    $self->display_key_value("terminal_passthrough", "Force direct terminal access", 25);
    $self->display_key_value("terminal_autodetect", "Auto-detect interactive commands", 25);
    $self->display_key_value("redact_level", "Redaction level: strict|standard|api_permissive|pii|off", 25);
    $self->writeline("", markdown => 0);
    
    $self->display_section_header("REDACTION LEVELS");
    $self->display_key_value("strict", "Redact all (PII + crypto + API keys + tokens)", 25);
    $self->display_key_value("standard", "Same as strict", 25);
    $self->display_key_value("api_permissive", "Allow API keys/tokens (PII + crypto redacted)", 25);
    $self->display_key_value("pii", "Only redact PII (default)", 25);
    $self->display_key_value("off", "No redaction (use with caution)", 25);
    $self->writeline("", markdown => 0);
    
    $self->display_section_header("EXAMPLES");
    $self->display_command_row("/config set style dark", "Switch to dark color scheme", 35);
    $self->display_command_row("/config set theme photon", "Use photon theme", 35);
    $self->display_command_row("/config workdir ~/projects", "Change working directory", 35);
    $self->display_command_row("/config set redact_level api_permissive", "Allow API keys in agent output", 35);
    $self->writeline("", markdown => 0);
    
    $self->display_section_header("TIPS");
    $self->display_tip("For API settings, use /api set");
    $self->display_tip("terminal_autodetect detects vim, nano, GPG, ssh, etc.");
    $self->display_tip("Use api_permissive when agent needs to work with API tokens");
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
        $self->writeline("Keys: style, theme, working_directory, terminal_passthrough, terminal_autodetect, redact_level", markdown => 0);
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
        working_directory => 1,
        terminal_passthrough => 1,
        terminal_autodetect => 1,
        redact_level => 1,
        redact_secrets => 1,  # Deprecated, for backward compat
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
    if ($key =~ /^terminal_/) {
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
    
    my $model = $self->{config}->get('model') || 'gpt-4';
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
    my $loglevel = $self->{config}->get('loglevel') || $self->{config}->get('log_level') || 'WARNING';
    
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
    $self->writeline($self->colorize("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", 'DIM'), markdown => 0);
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
    my $session_model = $state->{selected_model} || $self->{config}->get('model') || 'gpt-4';
    $self->writeline(sprintf("  Selected:     %s%s", $session_model, ($state->{selected_model} ? '' : ' (from global)')), markdown => 0);
    
    $self->writeline("", markdown => 0);
}

=head2 handle_loglevel_command

Handle /loglevel command

=cut

sub handle_loglevel_command {
    my ($self, $level) = @_;
    
    unless ($level) {
        my $current = $self->{config}->get('loglevel') || $self->{config}->get('log_level') || 'WARNING';
        $self->writeline("", markdown => 0);
        $self->writeline($self->colorize("CURRENT LOG LEVEL", 'DATA'), markdown => 0);
        $self->writeline($self->colorize("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", 'DIM'), markdown => 0);
        $self->writeline("", markdown => 0);
        $self->writeline("  $current", markdown => 0);
        $self->writeline("", markdown => 0);
        return;
    }
    
    my %valid = map { $_ => 1 } qw(DEBUG INFO WARNING ERROR CRITICAL);
    
    unless ($valid{uc($level)}) {
        $self->display_error_message("Invalid log level: $level");
        $self->writeline("Valid levels: DEBUG, INFO, WARNING, ERROR, CRITICAL", markdown => 0);
        return;
    }
    
    $self->{config}->set('loglevel', uc($level));
    $self->display_system_message("Log level set to: " . uc($level));
    $self->display_system_message("Use /config save to persist");
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
        
        $self->writeline($self->colorize("━ AVAILABLE STYLES ━" . ("━" x 41), 'DATA'), markdown => 0);
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
        $self->writeline($self->colorize("━ CURRENT STYLE ━" . ("━" x 47), 'DATA'), markdown => 0);
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
        
        $self->writeline($self->colorize("━ AVAILABLE THEMES ━" . ("━" x 41), 'DATA'), markdown => 0);
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
        $self->writeline($self->colorize("━ CURRENT THEME ━" . ("━" x 47), 'DATA'), markdown => 0);
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

1;

__END__

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

Same as CLIO.

=cut
