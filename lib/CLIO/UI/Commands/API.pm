package CLIO::UI::Commands::API;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Carp qw(croak);
use CLIO::Core::Logger qw(should_log);

=head1 NAME

CLIO::UI::Commands::API - API configuration commands for CLIO

=head1 SYNOPSIS

  use CLIO::UI::Commands::API;
  
  my $api_cmd = CLIO::UI::Commands::API->new(
      chat => $chat_instance,
      config => $config,
      session => $session,
      debug => 0
  );
  
  # Handle /api commands
  $api_cmd->handle_api_command('show');
  $api_cmd->handle_api_command('set', 'model', 'gpt-4');
  $api_cmd->handle_models_command();

=head1 DESCRIPTION

Handles all /api related commands including:
- /api show - Display current API configuration
- /api set - Set API configuration values
- /api providers - List available providers
- /api models - List available models
- /api login - GitHub Copilot authentication
- /api logout - Sign out

Extracted from Chat.pm to improve maintainability.

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        chat => $args{chat} || croak "chat instance required",
        debug => $args{debug} // 0,
    };
    
    # Assign object references separately (hash literal assignment bug workaround)
    $self->{config} = $args{config};
    $self->{session} = $args{session};
    $self->{ai_agent} = $args{ai_agent};
    
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
sub colorize { shift->{chat}->colorize(@_) }
sub refresh_terminal_size { shift->{chat}->refresh_terminal_size(@_) }
sub writeline { shift->{chat}->writeline(@_) }

=head2 handle_api_command($action, @args)

Main dispatcher for /api commands.

=cut

sub handle_api_command {
    my ($self, $action, @args) = @_;
    
    $action ||= '';
    $action = lc($action);
    
    # Parse --session flag from args
    my $session_only = 0;
    @args = grep {
        if ($_ eq '--session') {
            $session_only = 1;
            0;  # Remove from args
        } else {
            1;  # Keep in args
        }
    } @args;
    
    # /api (no args) - show help
    if ($action eq '' || $action eq 'help') {
        $self->_display_api_help();
        return;
    }
    
    # /api show - display current config
    if ($action eq 'show') {
        $self->_display_api_config();
        return;
    }
    
    # /api set <setting> <value> [--session]
    if ($action eq 'set') {
        my $setting = shift @args || '';
        my $value = shift @args;
        $self->_handle_api_set($setting, $value, $session_only);
        return;
    }
    
    # /api models - list available models
    if ($action eq 'models') {
        $self->handle_models_command(@args);
        return;
    }
    
    # /api providers - list available providers
    if ($action eq 'providers') {
        $self->_display_api_providers(@args);
        return;
    }
    
    # /api login - GitHub Copilot authentication
    if ($action eq 'login') {
        $self->handle_login_command(@args);
        return;
    }
    
    # /api logout - sign out
    if ($action eq 'logout') {
        $self->handle_logout_command(@args);
        return;
    }
    
    # BACKWARD COMPATIBILITY: Support old syntax during transition
    if ($action eq 'key') {
        $self->display_system_message("Note: Use '/api set key <value>' (new syntax)");
        $self->_handle_api_set('key', $args[0], 0);
        return;
    }
    if ($action eq 'base') {
        $self->display_system_message("Note: Use '/api set base <url>' (new syntax)");
        $self->_handle_api_set('base', $args[0], $session_only);
        return;
    }
    if ($action eq 'model') {
        $self->display_system_message("Note: Use '/api set model <name>' (new syntax)");
        $self->_handle_api_set('model', $args[0], $session_only);
        return;
    }
    if ($action eq 'provider') {
        $self->display_system_message("Note: Use '/api set provider <name>' (new syntax)");
        $self->_handle_api_set('provider', $args[0], $session_only);
        return;
    }
    
    # Unknown action
    $self->display_error_message("Unknown action: /api $action");
    $self->_display_api_help();
}

=head2 _display_api_help

Display help for /api commands

=cut

sub _display_api_help {
    my ($self) = @_;
    
    $self->display_command_header("API COMMANDS");
    
    $self->display_list_item("/api show - Display current API configuration");
    $self->display_list_item("/api set model <name> - Set AI model");
    $self->display_list_item("/api set provider <name> - Set provider (github_copilot, openai, etc.)");
    $self->display_list_item("/api set base <url> - Set API base URL");
    $self->display_list_item("/api set key <value> - Set API key (global only)");
    $self->display_list_item("/api providers - Show available providers and their details");
    $self->display_list_item("/api models - List available models");
    $self->display_list_item("/api login - Authenticate with GitHub Copilot");
    $self->display_list_item("/api logout - Sign out from GitHub");
    
    $self->writeline("", markdown => 0);
    $self->display_section_header("WEB SEARCH CONFIGURATION");
    $self->display_list_item("/api set serpapi_key <key> - Set SerpAPI key (serpapi.com)");
    $self->display_list_item("/api set search_engine <name> - Set engine (google|bing|duckduckgo)");
    $self->display_list_item("/api set search_provider <name> - Set provider (auto|serpapi|duckduckgo_direct)");
    
    $self->writeline("", markdown => 0);
    $self->display_section_header("FLAGS");
    $self->writeline("  --session    Save setting to this session only (not global)", markdown => 0);
    $self->writeline("", markdown => 0);
    $self->display_section_header("EXAMPLES");
    $self->writeline("  /api set model claude-sonnet-4          # Global + session", markdown => 0);
    $self->writeline("  /api set model gpt-4o --session         # This session only", markdown => 0);
    $self->writeline("  /api set provider github_copilot        # Switch provider", markdown => 0);
    $self->writeline("  /api set serpapi_key YOUR_KEY           # Enable reliable web search", markdown => 0);
    $self->writeline("", markdown => 0);
}

=head2 _display_api_config

Display current API configuration

=cut

sub _display_api_config {
    my ($self) = @_;
    
    my $key = $self->{config}->get('api_key');
    my $base = $self->{config}->get('api_base');
    my $model = $self->{config}->get('model');
    my $provider = $self->{config}->get('provider');
    
    # Determine authentication status
    my $auth_status = '[NOT SET]';
    if ($key && length($key) > 0) {
        $auth_status = '[SET]';
    } else {
        # Check if using GitHub Copilot auth
        if ($provider && $provider eq 'github_copilot') {
            eval {
                require CLIO::Core::GitHubAuth;
                my $gh_auth = CLIO::Core::GitHubAuth->new(debug => 0);
                my $token = $gh_auth->get_copilot_token();
                if ($token) {
                    $auth_status = '[TOKEN]';
                } else {
                    $auth_status = '[NO TOKEN - use /api login]';
                }
            };
        }
    }
    
    $self->display_command_header("API CONFIGURATION");
    
    $self->display_key_value("Provider", $provider || '[not set]');
    $self->display_key_value("API Key", $auth_status);
    $self->display_key_value("API Base", $base || '[default]');
    $self->display_key_value("Model", $model || '[default]');
    
    # Show session-specific overrides if any
    if ($self->{session} && $self->{session}->state()) {
        my $state = $self->{session}->state();
        my $api_config = $state->{api_config} || {};
        
        if (%$api_config) {
            $self->writeline("", markdown => 0);
            $self->display_section_header("SESSION OVERRIDES");
            for my $key (sort keys %$api_config) {
                $self->display_key_value($key, $api_config->{$key});
            }
            $self->writeline("", markdown => 0);
        }
    }
}

=head2 _display_api_providers

Display available providers and their configurations.

=cut

sub _display_api_providers {
    my ($self, $provider_name) = @_;
    
    require CLIO::Providers;
    
    $self->writeline("", markdown => 0);
    $self->writeline($self->colorize("API PROVIDERS", 'DATA'), markdown => 0);
    $self->writeline($self->colorize("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", 'DIM'), markdown => 0);
    $self->writeline("", markdown => 0);
    
    # If specific provider requested, show details
    if ($provider_name) {
        $self->_show_provider_details($provider_name);
        return;
    }
    
    # Get current provider for comparison
    my $current_provider = $self->{config}->get('provider') if $self->{config};
    
    # Show all providers in organized table format
    my @providers = CLIO::Providers::list_providers();
    
    # Calculate column width based on longest provider name
    my $max_provider_length = 0;
    for my $prov_name (@providers) {
        my $prov = CLIO::Providers::get_provider($prov_name);
        next unless $prov;
        my $display_name = $prov->{name} || $prov_name;
        $max_provider_length = length($display_name) if length($display_name) > $max_provider_length;
    }
    
    # Table header
    my $header = $self->colorize("PROVIDER", 'LABEL') . 
                 " " x ($max_provider_length - 8 + 4) .
                 $self->colorize("DEFAULT MODEL", 'LABEL');
    $self->writeline($header, markdown => 0);
    $self->writeline($self->colorize("─" x 77, 'DIM'), markdown => 0);
    
    for my $prov_name (@providers) {
        my $prov = CLIO::Providers::get_provider($prov_name);
        next unless $prov;
        
        my $display_name = $prov->{name} || $prov_name;
        my $model = $prov->{model} || 'N/A';
        
        my $line = "  " . 
                   $self->colorize(sprintf("%-" . $max_provider_length . "s", $display_name), 'PROMPT') .
                   "  " . $model;
        $self->writeline($line, markdown => 0);
    }
    
    $self->writeline("", markdown => 0);
    $self->writeline($self->colorize("LEARN MORE", 'DATA'), markdown => 0);
    $self->writeline($self->colorize("─" x 77, 'DIM'), markdown => 0);
    $self->writeline("  /api providers <name>   - Show setup instructions for a specific provider", markdown => 0);
    $self->writeline("", markdown => 0);
    $self->writeline($self->colorize("EXAMPLES", 'DATA'), markdown => 0);
    $self->writeline($self->colorize("─" x 77, 'DIM'), markdown => 0);
    $self->writeline("  /api set provider github_copilot    - Setup GitHub Copilot", markdown => 0);
    $self->writeline("  /api set provider openai            - Switch to OpenAI", markdown => 0);
    $self->writeline("", markdown => 0);
}

=head2 _show_provider_details

Display detailed information about a specific provider

=cut

sub _show_provider_details {
    my ($self, $provider_name) = @_;
    
    require CLIO::Providers;
    
    my $prov = CLIO::Providers::get_provider($provider_name);
    
    unless ($prov) {
        $self->display_error_message("Provider not found: $provider_name");
        $self->writeline("Use '/api providers' to see available providers", markdown => 0);
        return;
    }
    
    my $display_name = $prov->{name} || $provider_name;
    
    $self->writeline("", markdown => 0);
    $self->writeline($self->colorize($display_name, 'DATA'), markdown => 0);
    $self->writeline($self->colorize("─" x 90, 'DIM'), markdown => 0);
    $self->writeline("", markdown => 0);
    
    # Basic information
    $self->writeline($self->colorize("OVERVIEW", 'LABEL'), markdown => 0);
    $self->writeline(sprintf("  ID:          %s", $provider_name), markdown => 0);
    $self->writeline(sprintf("  Model:       %s", $prov->{model} || 'N/A'), markdown => 0);
    $self->writeline(sprintf("  API Base:    %s", $prov->{api_base} || '[not specified]'), markdown => 0);
    
    # Authentication
    my $auth = $prov->{requires_auth} || 'none';
    my $auth_text = $self->_format_auth_requirement($auth);
    $self->writeline("", markdown => 0);
    $self->writeline($self->colorize("AUTHENTICATION", 'LABEL'), markdown => 0);
    $self->writeline(sprintf("  Method:      %s", $auth_text), markdown => 0);
    
    if ($auth eq 'copilot') {
        $self->writeline("", markdown => 0);
        $self->writeline($self->colorize("  Setup Steps", 'PROMPT'), markdown => 0);
        $self->writeline("    1. Run: /api login", markdown => 0);
        $self->writeline("    2. Follow the browser authentication flow", markdown => 0);
        $self->writeline("    3. Token will be stored securely", markdown => 0);
    } elsif ($auth eq 'apikey') {
        $self->writeline("", markdown => 0);
        $self->writeline($self->colorize("  Setup Steps", 'PROMPT'), markdown => 0);
        $self->writeline("    1. Obtain API key from the provider website", markdown => 0);
        $self->writeline("    2. Set it with: /api set key <your-api-key>", markdown => 0);
        $self->writeline("    3. Key is stored globally (not in session)", markdown => 0);
    } elsif ($auth eq 'none') {
        $self->writeline("", markdown => 0);
        $self->writeline($self->colorize("  Status", 'SUCCESS'), markdown => 0);
        $self->writeline("    Ready to use - no authentication needed", markdown => 0);
    }
    
    # Capabilities
    $self->writeline("", markdown => 0);
    $self->writeline($self->colorize("CAPABILITIES", 'LABEL'), markdown => 0);
    my $tools_str = $prov->{supports_tools} ? "Yes" : "No";
    my $stream_str = $prov->{supports_streaming} ? "Yes" : "No";
    $self->writeline(sprintf("  Functions:   %s (tool calling)", $tools_str), markdown => 0);
    $self->writeline(sprintf("  Streaming:   %s", $stream_str), markdown => 0);
    
    # Quick start
    $self->writeline("", markdown => 0);
    $self->writeline($self->colorize("QUICK START", 'LABEL'), markdown => 0);
    $self->writeline("  1. Switch to this provider:", markdown => 0);
    $self->writeline("     /api set provider $provider_name", markdown => 0);
    $self->writeline("", markdown => 0);
    if ($auth eq 'apikey' || $auth eq 'copilot') {
        $self->writeline("  2. Authenticate (if not done already):", markdown => 0);
        $self->writeline("     /api login", markdown => 0);
        $self->writeline("", markdown => 0);
        $self->writeline("  3. Verify setup:", markdown => 0);
        $self->writeline("     /api show", markdown => 0);
    } else {
        $self->writeline("  2. Verify setup:", markdown => 0);
        $self->writeline("     /api show", markdown => 0);
    }
    
    $self->writeline("", markdown => 0);
}

=head2 _format_auth_requirement

Format authentication requirement as human-readable text

=cut

sub _format_auth_requirement {
    my ($self, $auth_type) = @_;
    
    return 'None (local)' if !$auth_type || $auth_type eq 'none';
    return 'GitHub OAuth' if $auth_type eq 'copilot';
    return 'API Key' if $auth_type eq 'apikey';
    return $auth_type;
}

=head2 _handle_api_set

Handle /api set <setting> <value> [--session]

=cut

sub _handle_api_set {
    my ($self, $setting, $value, $session_only) = @_;
    
    $setting = lc($setting || '');
    
    unless ($setting) {
        $self->display_error_message("Usage: /api set <setting> <value>");
        $self->writeline("Settings: model, provider, base, key, serpapi_key, search_engine, search_provider", markdown => 0);
        return;
    }
    
    unless (defined $value && $value ne '') {
        $self->display_error_message("Usage: /api set $setting <value>");
        return;
    }
    
    # Handle each setting type
    if ($setting eq 'key') {
        # API key is always global
        if ($session_only) {
            $self->display_system_message("Note: API key is always global (ignoring --session)");
        }
        
        $self->{config}->set('api_key', $value);
        
        if ($self->{config}->save()) {
            $self->display_system_message("API key set and saved");
        } else {
            $self->display_system_message("API key set (warning: failed to save)");
        }
        
        $self->_reinit_api_manager();
    }
    elsif ($setting eq 'serpapi_key' || $setting eq 'serpapi') {
        if ($session_only) {
            $self->display_system_message("Note: API keys are always global (ignoring --session)");
        }
        
        $self->{config}->set('serpapi_key', $value);
        
        if ($self->{config}->save()) {
            my $display_key = substr($value, 0, 8) . '...' . substr($value, -4);
            $self->display_system_message("SerpAPI key set: $display_key (saved)");
            $self->display_system_message("Web search will now use SerpAPI for reliable results");
        } else {
            $self->display_system_message("SerpAPI key set (warning: failed to save)");
        }
    }
    elsif ($setting eq 'search_engine') {
        my @valid = qw(google bing duckduckgo);
        unless (grep { $_ eq lc($value) } @valid) {
            $self->display_error_message("Invalid search engine: $value");
            $self->display_system_message("Valid engines: " . join(", ", @valid));
            return;
        }
        
        $self->{config}->set('search_engine', lc($value));
        
        if ($self->{config}->save()) {
            $self->display_system_message("Search engine set to: $value (saved)");
            $self->display_system_message("SerpAPI will now use $value for searches");
        } else {
            $self->display_system_message("Search engine set (warning: failed to save)");
        }
    }
    elsif ($setting eq 'search_provider') {
        my @valid = qw(auto serpapi duckduckgo_direct);
        unless (grep { $_ eq lc($value) } @valid) {
            $self->display_error_message("Invalid search provider: $value");
            $self->display_system_message("Valid providers: " . join(", ", @valid));
            return;
        }
        
        $self->{config}->set('search_provider', lc($value));
        
        if ($self->{config}->save()) {
            $self->display_system_message("Search provider set to: $value (saved)");
        } else {
            $self->display_system_message("Search provider set (warning: failed to save)");
        }
    }
    elsif ($setting eq 'base') {
        $self->_set_api_setting('api_base', $value, $session_only);
        $self->display_system_message("API base set to: $value" . ($session_only ? " (session only)" : " (saved)"));
        $self->_reinit_api_manager();
    }
    elsif ($setting eq 'model') {
        $self->_set_api_setting('model', $value, $session_only);
        $self->display_system_message("Model set to: $value" . ($session_only ? " (session only)" : " (saved)"));
        $self->_reinit_api_manager();
    }
    elsif ($setting eq 'provider') {
        if ($session_only) {
            if ($self->{session} && $self->{session}->state()) {
                my $state = $self->{session}->state();
                $state->{api_config} ||= {};
                $state->{api_config}{provider} = $value;
                $self->{session}->save();
                $self->display_system_message("Provider set to: $value (session only)");
            }
        } else {
            if ($self->{config}->set_provider($value)) {
                my $config = $self->{config}->get_all();
                
                if ($self->{config}->save()) {
                    $self->display_system_message("Switched to provider: $value (saved)");
                    $self->display_system_message("  API Base: " . $config->{api_base} . " (from provider)");
                    $self->display_system_message("  Model: " . $config->{model} . " (from provider)");
                } else {
                    $self->display_system_message("Switched to provider: $value (warning: failed to save)");
                }
                
                if ($value eq 'github_copilot') {
                    $self->_check_github_auth();
                }
            }
        }
        $self->_reinit_api_manager();
    }
    else {
        $self->display_error_message("Unknown setting: $setting");
        $self->writeline("Valid settings: model, provider, base, key, serpapi_key, search_engine, search_provider", markdown => 0);
    }
}

=head2 _set_api_setting

Set an API setting, optionally session-only

=cut

sub _set_api_setting {
    my ($self, $key, $value, $session_only) = @_;
    
    if ($session_only) {
        if ($self->{session} && $self->{session}->state()) {
            my $state = $self->{session}->state();
            $state->{api_config} ||= {};
            $state->{api_config}{$key} = $value;
            $self->{session}->save();
        }
    } else {
        $self->{config}->set($key, $value);
        $self->{config}->save();
        
        if ($self->{session} && $self->{session}->state()) {
            my $state = $self->{session}->state();
            $state->{api_config} ||= {};
            $state->{api_config}{$key} = $value;
            $self->{session}->save();
        }
    }
}

=head2 _reinit_api_manager

Reinitialize APIManager after config changes

=cut

sub _reinit_api_manager {
    my ($self) = @_;
    
    print STDERR "[DEBUG][API] Re-initializing APIManager after config change\n" if $self->{debug};
    
    require CLIO::Core::APIManager;
    my $new_api = CLIO::Core::APIManager->new(
        debug => $self->{debug},
        session => $self->{session}->state(),
        config => $self->{config}
    );
    $self->{ai_agent}->{api} = $new_api;
    
    if ($self->{ai_agent}->{orchestrator}) {
        $self->{ai_agent}->{orchestrator}->{api_manager} = $new_api;
        print STDERR "[DEBUG][API] Orchestrator's api_manager updated after config change\n" if $self->{debug};
    }
}

=head2 _check_github_auth

Check GitHub authentication and offer to login

=cut

sub _check_github_auth {
    my ($self) = @_;
    
    require CLIO::Core::GitHubAuth;
    my $gh_auth = CLIO::Core::GitHubAuth->new(debug => $self->{debug});
    
    unless ($gh_auth->is_authenticated()) {
        $self->writeline("", markdown => 0);
        $self->display_system_message("GitHub Copilot requires authentication");
        print $self->colorize("  Would you like to login now? [Y/n]: ", 'PROMPT');
        my $response = <STDIN>;
        chomp $response if defined $response;
        $response = lc($response || 'y');
        
        if ($response eq 'y' || $response eq 'yes' || $response eq '') {
            $self->handle_login_command();
        } else {
            $self->display_system_message("You can login later with: /api login");
        }
    }
}

=head2 handle_login_command

Handle /api login for GitHub Copilot authentication

=cut

sub handle_login_command {
    my ($self, @args) = @_;
    
    require CLIO::Core::GitHubAuth;
    
    my $auth = CLIO::Core::GitHubAuth->new(debug => $self->{debug});
    
    # Check if already authenticated
    if ($auth->is_authenticated()) {
        my $username = $auth->get_username() || 'unknown';
        $self->display_system_message("Already authenticated as: $username");
        $self->display_system_message("Use /logout to sign out first");
        return;
    }
    
    $self->writeline("", markdown => 0);
    $self->writeline("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", markdown => 0);
    $self->writeline($self->colorize("GITHUB COPILOT AUTHENTICATION", 'DATA'), markdown => 0);
    $self->writeline("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", markdown => 0);
    $self->writeline("", markdown => 0);
    
    # Start device flow
    $self->writeline($self->colorize("Step 1:", 'PROMPT') . " Requesting device code from GitHub...", markdown => 0);
    
    my $device_data;
    eval {
        $device_data = $auth->start_device_flow();
    };
    
    if ($@) {
        $self->display_error_message("Failed to start device flow: $@");
        return;
    }
    
    # Display verification instructions
    $self->writeline("", markdown => 0);
    $self->writeline($self->colorize("Step 2:", 'PROMPT') . " Authorize in your browser", markdown => 0);
    $self->writeline("", markdown => 0);
    $self->writeline("  1. Visit: " . $self->colorize($device_data->{verification_uri}, 'USER'), markdown => 0);
    $self->writeline("  2. Enter code: " . $self->colorize($device_data->{user_code}, 'DATA'), markdown => 0);
    $self->writeline("", markdown => 0);
    # Progress indicator - needs immediate output
    print "  Waiting for authorization";
    
    # Poll for token with visual feedback
    my $github_token;
    
    # Progress message - needs immediate output without newline handling
    print "\n  " . $self->colorize("Waiting for authorization...", 'DIM') . " (this may take a few minutes)\n  ";
    
    eval {
        $github_token = $auth->poll_for_token(
            $device_data->{device_code}, 
            $device_data->{interval}
        );
    };
    
    if ($@) {
        $self->writeline("", markdown => 0);
        $self->display_error_message("Authentication failed: $@");
        return;
    }
    
    unless ($github_token) {
        $self->writeline("", markdown => 0);
        $self->display_error_message("Authentication timed out");
        return;
    }
    
    $self->writeline($self->colorize("✓", 'PROMPT') . " Authorized!", markdown => 0);
    $self->writeline("", markdown => 0);
    
    # Exchange for Copilot token
    $self->writeline($self->colorize("Step 3:", 'PROMPT') . " Exchanging for Copilot token...", markdown => 0);
    
    my $copilot_token;
    eval {
        $copilot_token = $auth->exchange_for_copilot_token($github_token);
    };
    
    if ($@) {
        $self->display_error_message("Failed to exchange for Copilot token: $@");
        return;
    }
    
    if ($copilot_token) {
        $self->writeline("  " . $self->colorize("✓", 'PROMPT') . " Copilot token obtained", markdown => 0);
    } else {
        $self->writeline("  " . $self->colorize("[ ]", 'DIM') . " Copilot token unavailable (will use GitHub token directly)", markdown => 0);
    }
    $self->writeline("", markdown => 0);
    
    # Save tokens
    $self->writeline($self->colorize("Step 4:", 'PROMPT') . " Saving tokens...", markdown => 0);
    
    eval {
        $auth->save_tokens($github_token, $copilot_token);
    };
    
    if ($@) {
        $self->display_error_message("Failed to save tokens: $@");
        return;
    }
    
    $self->writeline("  " . $self->colorize("✓", 'PROMPT') . " Tokens saved to ~/.clio/github_tokens.json", markdown => 0);
    $self->writeline("", markdown => 0);
    
    # Success!
    $self->writeline("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", markdown => 0);
    $self->writeline($self->colorize("SUCCESS!", 'PROMPT'), markdown => 0);
    $self->writeline("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", markdown => 0);
    $self->writeline("", markdown => 0);
    
    if ($copilot_token) {
        my $username = $copilot_token->{username} || 'unknown';
        my $expires_in = int(($copilot_token->{expires_at} - time()) / 60);
        $self->display_system_message("Authenticated as: $username");
        $self->display_system_message("Token expires in: ~$expires_in minutes");
        $self->display_system_message("Token will auto-refresh before expiration");
    } else {
        $self->display_system_message("Authenticated with GitHub token");
        $self->display_system_message("Using GitHub token directly (Copilot endpoint unavailable)");
    }
    $self->writeline("", markdown => 0);
    
    # Reload APIManager
    $self->_reinit_api_manager();
    print STDERR "[DEBUG][API] APIManager reloaded successfully\n" if $self->{debug};
}

=head2 handle_logout_command

Sign out of GitHub authentication

=cut

sub handle_logout_command {
    my ($self, @args) = @_;
    
    require CLIO::Core::GitHubAuth;
    
    my $auth = CLIO::Core::GitHubAuth->new(debug => $self->{debug});
    
    unless ($auth->is_authenticated()) {
        $self->display_system_message("Not currently authenticated");
        return;
    }
    
    my $username = $auth->get_username() || 'unknown';
    
    $auth->clear_tokens();
    
    $self->display_system_message("Signed out from GitHub (was: $username)");
    $self->display_system_message("Use /login to authenticate again");
}

=head2 handle_models_command

Handle /api models command to list available models

=cut

sub handle_models_command {
    my ($self, @args) = @_;
    
    my $provider = $self->{config}->get('provider') || '';
    my $api_base = $self->{config}->get('api_base');
    
    # For GitHub Copilot, use GitHubCopilotModelsAPI
    if ($provider eq 'github_copilot' || $api_base =~ /githubcopilot\.com/) {
        print STDERR "[DEBUG][API] Using GitHubCopilotModelsAPI for /models\n" if should_log('DEBUG');
        
        eval {
            require CLIO::Core::GitHubCopilotModelsAPI;
            my $models_api = CLIO::Core::GitHubCopilotModelsAPI->new(debug => $self->{debug});
            my $data = $models_api->fetch_models();
            
            unless ($data) {
                $self->display_error_message("Failed to fetch models from GitHub Copilot API");
                return;
            }
            
            my $models = $data->{data} || [];
            
            unless (@$models) {
                $self->display_error_message("No models returned from API");
                return;
            }
            
            $self->_display_models_list($models, 'https://api.githubcopilot.com');
        };
        
        if ($@) {
            $self->display_error_message("Error using GitHubCopilotModelsAPI: $@");
        }
        
        return;
    }
    
    # For other providers, use generic API call
    my $api_key = $self->{config}->get('api_key');
    
    unless ($api_key) {
        $self->display_error_message("API key not set");
        $self->display_system_message("Use /api key <value> to set API key");
        return;
    }
    
    my ($api_type, $models_url) = $self->_detect_api_type($api_base);
    
    unless ($models_url) {
        $self->display_error_message("Unable to determine models endpoint for: $api_base");
        return;
    }
    
    print STDERR "[DEBUG][API] Querying models from $models_url (type: $api_type)\n" if should_log('DEBUG');
    
    require CLIO::Compat::HTTP;
    my $ua = CLIO::Compat::HTTP->new(timeout => 30);
    my %headers = ('Authorization' => "Bearer $api_key");
    my $resp = $ua->get($models_url, headers => \%headers);
    
    unless ($resp->is_success) {
        $self->display_error_message("Failed to fetch models: " . $resp->code . " " . $resp->message);
        print STDERR "[ERROR][API] Response: " . $resp->decoded_content . "\n" if $self->{debug};
        return;
    }
    
    require JSON::PP;
    my $data = eval { JSON::PP::decode_json($resp->decoded_content) };
    if ($@) {
        $self->display_error_message("Failed to parse models response: $@");
        return;
    }
    
    my $models = $data->{data} || [];
    
    unless (@$models) {
        $self->display_error_message("No models returned from API");
        return;
    }
    
    $self->_display_models_list($models, $api_base);
}

=head2 _display_models_list

Display models list with billing categorization

=cut

sub _display_models_list {
    my ($self, $models, $api_base) = @_;
    
    # Categorize models by billing
    my @free_models;
    my @premium_models;
    my @unknown_models;
    
    for my $model (@$models) {
        my $is_premium = undef;
        
        if (exists $model->{billing} && defined $model->{billing}{is_premium}) {
            $is_premium = $model->{billing}{is_premium};
        } elsif (exists $model->{is_premium}) {
            $is_premium = $model->{is_premium};
        }
        
        if (defined $is_premium) {
            if ($is_premium) {
                push @premium_models, $model;
            } else {
                push @free_models, $model;
            }
        } else {
            push @unknown_models, $model;
        }
    }
    
    @free_models = sort { $a->{id} cmp $b->{id} } @free_models;
    @premium_models = sort { $a->{id} cmp $b->{id} } @premium_models;
    @unknown_models = sort { $a->{id} cmp $b->{id} } @unknown_models;
    
    my $has_billing = (@free_models || @premium_models);
    
    $self->refresh_terminal_size();
    $self->{chat}->{line_count} = 0;
    $self->{chat}->{pages} = [];
    $self->{chat}->{current_page} = [];
    $self->{chat}->{page_index} = 0;
    
    my @lines;
    
    push @lines, "";
    push @lines, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━";
    push @lines, $self->colorize("AVAILABLE MODELS", 'DATA') . " (" . $self->colorize($api_base, 'THEME') . ")";
    push @lines, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━";
    push @lines, "";
    
    if ($has_billing) {
        my $header = sprintf("  %-64s %12s", "Model", "Rate");
        push @lines, $self->colorize($header, 'THEME');
        push @lines, sprintf("  %-64s %12s", "━" x 64, "━" x 12);
    } else {
        my $header = sprintf("  %-70s", "Model");
        push @lines, $self->colorize($header, 'THEME');
        push @lines, sprintf("  %-70s", "━" x 70);
    }
    
    if (@free_models) {
        push @lines, "";
        push @lines, $self->colorize("FREE MODELS", 'THEME');
        for my $model (@free_models) {
            push @lines, "  " . $self->_format_model_for_display($model, $has_billing);
        }
    }
    
    if (@premium_models) {
        push @lines, "";
        push @lines, $self->colorize("PREMIUM MODELS", 'THEME');
        for my $model (@premium_models) {
            push @lines, "  " . $self->_format_model_for_display($model, $has_billing);
        }
    }
    
    if (@unknown_models) {
        push @lines, "";
        push @lines, $self->colorize($has_billing ? 'OTHER MODELS' : 'ALL MODELS', 'THEME');
        for my $model (@unknown_models) {
            push @lines, "  " . $self->_format_model_for_display($model, $has_billing);
        }
    }
    
    push @lines, "";
    push @lines, "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━";
    push @lines, sprintf("Total: %d models available", scalar(@$models));
    
    if ($has_billing) {
        push @lines, "";
        push @lines, $self->colorize("Note: Subscription-based billing", 'SYSTEM');
        push @lines, "      " . $self->colorize("FREE = Included in subscription", 'SYSTEM');
        push @lines, "      " . $self->colorize("1x/3x/10x = Premium multiplier on usage", 'SYSTEM');
    }
    push @lines, "";
    
    for my $line (@lines) {
        last unless $self->writeline($line);
    }
}

=head2 _format_model_for_display

Format a model for display

=cut

sub _format_model_for_display {
    my ($self, $model, $has_billing) = @_;
    
    my $name = $model->{id} || 'Unknown';
    
    my $max_name_length = $has_billing ? 62 : 68;
    if (length($name) > $max_name_length) {
        $name = substr($name, 0, $max_name_length - 3) . "...";
    }
    
    if ($has_billing) {
        my $billing_rate = '-';
        
        if ($model->{billing} && defined $model->{billing}{multiplier}) {
            my $mult = $model->{billing}{multiplier};
            
            if ($mult == 0) {
                $billing_rate = 'FREE';
            } elsif ($mult == int($mult)) {
                $billing_rate = int($mult) . 'x';
            } else {
                $billing_rate = sprintf("%.2fx", $mult);
            }
        } elsif (defined $model->{premium_multiplier}) {
            my $mult = $model->{premium_multiplier};
            if ($mult == 0) {
                $billing_rate = 'FREE';
            } elsif ($mult == int($mult)) {
                $billing_rate = int($mult) . 'x';
            } else {
                $billing_rate = sprintf("%.2fx", $mult);
            }
        }
        
        my $colored_name = $self->colorize($name, 'USER');
        my $name_display_width = length($name);
        my $padding = 64 - $name_display_width;
        my $spaces = $padding > 0 ? (' ' x $padding) : '';
        
        return sprintf("%s%s %12s", $colored_name, $spaces, $billing_rate);
    } else {
        my $colored_name = $self->colorize($name, 'USER');
        my $name_display_width = length($name);
        my $padding = 70 - $name_display_width;
        my $spaces = $padding > 0 ? (' ' x $padding) : '';
        
        return sprintf("%s%s", $colored_name, $spaces);
    }
}

=head2 _detect_api_type

Detect API type and models endpoint from base URL

=cut

sub _detect_api_type {
    my ($self, $api_base) = @_;
    
    my %api_configs = (
        'github-copilot' => ['github-copilot', 'https://api.githubcopilot.com/models'],
        'openai'         => ['openai', 'https://api.openai.com/v1/models'],
        'dashscope-cn'   => ['dashscope', 'https://dashscope.aliyuncs.com/compatible-mode/v1/models'],
        'dashscope-intl' => ['dashscope', 'https://dashscope-intl.aliyuncs.com/compatible-mode/v1/models'],
        'sam'            => ['sam', 'http://localhost:8080/v1/models'],
    );
    
    if (exists $api_configs{$api_base}) {
        return @{$api_configs{$api_base}};
    }
    
    if ($api_base =~ m{githubcopilot\.com}i) {
        return ('github-copilot', 'https://api.githubcopilot.com/models');
    } elsif ($api_base =~ m{openai\.com}i) {
        return ('openai', 'https://api.openai.com/v1/models');
    } elsif ($api_base =~ m{dashscope.*\.aliyuncs\.com}i) {
        my $base_url = $api_base;
        $base_url =~ s{/+$}{};
        $base_url =~ s{/compatible-mode/v1.*$}{};
        return ('dashscope', "$base_url/compatible-mode/v1/models");
    } elsif ($api_base =~ m{localhost:8080}i) {
        return ('sam', 'http://localhost:8080/v1/models');
    }
    
    if ($api_base =~ m{^https?://}) {
        my $models_url = $api_base;
        $models_url =~ s{/+$}{};
        
        if ($models_url =~ m{/chat/completions$}) {
            $models_url =~ s{/chat/completions$}{/models};
        }
        elsif ($models_url =~ m{/v1$}) {
            $models_url .= "/models";
        } elsif ($models_url !~ m{/models$}) {
            $models_url .= "/models";
        }
        
        return ('generic', $models_url);
    }
    
    return (undef, undef);
}

1;

__END__

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

Same as CLIO.

=cut
