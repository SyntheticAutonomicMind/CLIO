package CLIO::UI::Commands::Config;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Carp qw(croak);
use File::Spec;
use CLIO::Core::Logger qw(should_log);

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
        config => $args{config},
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

Display help for /config commands

=cut

sub _display_config_help {
    my ($self) = @_;
    
    $self->display_command_header("CONFIG COMMANDS");
    
    $self->display_list_item("/config show - Display global configuration");
    $self->display_list_item("/config set <key> <value> - Set a configuration value");
    $self->display_list_item("/config save - Save current configuration to disk");
    $self->display_list_item("/config load - Reload configuration from disk");
    $self->display_list_item("/config workdir [path] - Get or set working directory");
    $self->display_list_item("/config loglevel [level] - Get or set log level");
    
    print "\n";
    $self->display_section_header("SETTABLE KEYS");
    print "  style                    UI color scheme (default, dark, light, amber-terminal, etc.)\n";
    print "  theme                    Banner and template theme\n";
    print "  workdir                  Current working directory path\n";
    print "  terminal_passthrough     Force direct terminal access for all commands (true/false)\n";
    print "  terminal_autodetect      Auto-detect interactive commands for passthrough (true/false)\n";
    
    print "\n";
    $self->display_section_header("EXAMPLES");
    print "  /config set style dark                      # Switch to dark color scheme\n";
    print "  /config set theme photon                    # Use photon theme\n";
    print "  /config set workdir ~/projects              # Change working directory\n";
    print "  /config set terminal_passthrough true       # Enable passthrough for all commands\n";
    print "  /config set terminal_autodetect false       # Disable interactive command detection\n";
    print "  /config workdir                             # Show current working directory\n";
    
    print "\n";
    $self->display_info_message("For API settings, use /api set");
    print "\n";
    
    print "\n";
    $self->display_section_header("TERMINAL SETTINGS");
    print "  terminal_passthrough: When enabled, commands execute with direct terminal access.\n";
    print "    - User can interact (editor, GPG prompts, etc.)\n";
    print "    - Agent sees exit codes but no output\n";
    print "    - Default: false (use auto-detection instead)\n";
    print "\n";
    print "  terminal_autodetect: When enabled, interactive commands are detected automatically.\n";
    print "    - Detects: git commit (no -m), vim, nano, GPG, ssh, etc.\n";
    print "    - Uses passthrough only for detected commands\n";
    print "    - Default: true (smart detection enabled)\n";
    print "\n";
}

=head2 _handle_config_set

Handle /config set <key> <value>

=cut

sub _handle_config_set {
    my ($self, $key, $value) = @_;
    
    $key = lc($key || '');
    
    unless ($key) {
        $self->display_error_message("Usage: /config set <key> <value>");
        print "Keys: style, theme, working_directory, terminal_passthrough, terminal_autodetect\n";
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
    );
    
    unless ($allowed{$key}) {
        $self->display_error_message("Unknown config key: $key");
        print "Allowed keys: " . join(', ', sort keys %allowed) . "\n";
        return;
    }
    
    # Handle boolean values for terminal settings
    if ($key =~ /^terminal_/) {
        if ($value =~ /^(true|1|yes|on)$/i) {
            $value = 1;
        } elsif ($value =~ /^(false|0|no|off)$/i) {
            $value = 0;
        } else {
            $self->display_error_message("Invalid boolean value for $key: $value");
            print "Use: true/false, 1/0, yes/no, on/off\n";
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
    print "\n";
    $self->display_section_header("UI Settings");
    my $style = $self->{config}->get('style') || 'default';
    my $theme = $self->{config}->get('theme') || 'default';
    my $loglevel = $self->{config}->get('loglevel') || $self->{config}->get('log_level') || 'WARNING';
    
    $self->display_key_value("Color Style", $style, 18);
    $self->display_key_value("Output Theme", $theme, 18);
    $self->display_key_value("Log Level", $loglevel, 18);
    
    # Paths
    print "\n";
    $self->display_section_header("Paths & Files");
    require Cwd;
    my $workdir = $self->{config}->get('working_directory') || Cwd::getcwd();
    my $config_file = $self->{config}->{config_file};
    
    $self->display_key_value("Working Dir", $workdir, 18);
    $self->display_key_value("Config File", $config_file, 18);
    $self->display_key_value("Sessions Dir", File::Spec->catdir('.', 'sessions'), 18);
    $self->display_key_value("Styles Dir", File::Spec->catdir('.', 'styles'), 18);
    $self->display_key_value("Themes Dir", File::Spec->catdir('.', 'themes'), 18);
    
    print "\n";
    $self->display_info_message("Use '/config save' to persist changes");
    print "\n";
}

=head2 show_session_config

Display session-specific configuration

=cut

sub show_session_config {
    my ($self) = @_;
    
    my $state = $self->{session}->state();
    
    print "\n", $self->colorize("SESSION CONFIGURATION", 'DATA'), "\n";
    print $self->colorize("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", 'DIM'), "\n\n";
    
    print $self->colorize("Session Info:", 'SYSTEM'), "\n";
    printf "  Session ID:   %s\n", $state->{session_id};
    printf "  Messages:     %d\n", scalar(@{$state->{history} || []});
    require Cwd;
    printf "  Working Dir:  %s\n", $state->{working_directory} || Cwd::getcwd();
    
    print "\n", $self->colorize("UI Settings:", 'SYSTEM'), "\n";
    my $session_style = $state->{style} || $self->{config}->get('style') || 'default';
    my $session_theme = $state->{theme} || $self->{config}->get('theme') || 'default';
    printf "  Style:        %s%s\n", $session_style, ($state->{style} ? '' : ' (from global)');
    printf "  Theme:        %s%s\n", $session_theme, ($state->{theme} ? '' : ' (from global)');
    
    print "\n", $self->colorize("Model:", 'SYSTEM'), "\n";
    my $session_model = $state->{selected_model} || $self->{config}->get('model') || 'gpt-4';
    printf "  Selected:     %s%s\n", $session_model, ($state->{selected_model} ? '' : ' (from global)');
    
    print "\n";
}

=head2 handle_loglevel_command

Handle /loglevel command

=cut

sub handle_loglevel_command {
    my ($self, $level) = @_;
    
    unless ($level) {
        my $current = $self->{config}->get('loglevel') || $self->{config}->get('log_level') || 'WARNING';
        print "\n", $self->colorize("CURRENT LOG LEVEL", 'DATA'), "\n";
        print $self->colorize("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", 'DIM'), "\n\n";
        print "  $current\n\n";
        return;
    }
    
    my %valid = map { $_ => 1 } qw(DEBUG INFO WARNING ERROR CRITICAL);
    
    unless ($valid{uc($level)}) {
        $self->display_error_message("Invalid log level: $level");
        print "Valid levels: DEBUG, INFO, WARNING, ERROR, CRITICAL\n";
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
        
        print $self->colorize("━ AVAILABLE STYLES ━" . ("━" x 41), 'DATA'), "\n\n";
        for my $style (@styles) {
            my $marker = ($style eq $current) ? ' (current)' : '';
            printf "  %-20s%s\n", $style, $self->colorize($marker, 'PROMPT');
        }
        print "\n";
        print "Use ", $self->colorize("/style set <name>", 'PROMPT'), " to switch styles\n";
    }
    elsif ($action eq 'show') {
        my $current = $theme_mgr->get_current_style();
        print $self->colorize("━ CURRENT STYLE ━" . ("━" x 47), 'DATA'), "\n\n";
        print "  ", $self->colorize($current, 'USER'), "\n\n";
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
        
        print $self->colorize("━ AVAILABLE THEMES ━" . ("━" x 41), 'DATA'), "\n\n";
        for my $theme (@themes) {
            my $marker = ($theme eq $current) ? ' (current)' : '';
            printf "  %-20s%s\n", $theme, $self->colorize($marker, 'PROMPT');
        }
        print "\n";
        print "Use ", $self->colorize("/theme set <name>", 'PROMPT'), " to switch themes\n";
    }
    elsif ($action eq 'show') {
        my $current = $theme_mgr->get_current_theme();
        print $self->colorize("━ CURRENT THEME ━" . ("━" x 47), 'DATA'), "\n\n";
        print "  ", $self->colorize($current, 'USER'), "\n\n";
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
