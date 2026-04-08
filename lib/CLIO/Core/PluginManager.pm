# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Core::PluginManager;

use strict;
use warnings;
use utf8;
use Carp qw(croak);
use File::Spec;
use File::Path qw(make_path);
use CLIO::Core::Logger qw(log_debug log_info log_warning log_error);
use CLIO::Util::JSON qw(encode_json decode_json);

=head1 NAME

CLIO::Core::PluginManager - Load, configure, and manage CLIO plugins

=head1 DESCRIPTION

Manages plugins that bundle instructions, tools, and configuration into
reusable packages. Plugins can provide:

1. Instructions - Injected into the system prompt to guide AI behavior
2. Tools - HTTP API endpoints or executable scripts the AI can call
3. Configuration - Declarative config schema with secrets support

Plugin directories:
  ~/.clio/plugins/   - Global plugins (available in all projects)
  .clio/plugins/     - Project-level plugins (project-specific)

Each plugin is a directory containing:
  plugin.json        - Manifest (name, description, tools, config schema)
  instructions.md    - Optional instructions injected into system prompt
  tools/             - Optional directory of executable tool scripts

=head1 SYNOPSIS

    my $pm = CLIO::Core::PluginManager->new(
        config => $config,
        debug  => 1,
    );

    $pm->load_plugins();

    my $tools = $pm->get_tool_definitions();
    my $instructions = $pm->get_all_instructions();

    my $result = $pm->call_tool('myplugin_create', { title => 'Test' });

=cut

my $INSTANCE;

sub new {
    my ($class, %args) = @_;

    my $self = bless {
        config       => $args{config},
        debug        => $args{debug} || 0,
        plugins      => {},    # name => plugin data
        plugin_order => [],    # ordered list of plugin names
    }, $class;

    $INSTANCE = $self;
    return $self;
}

=head2 instance

Get the singleton PluginManager instance.

=cut

sub instance { return $INSTANCE }

=head2 load_plugins

Discover and load all plugins from global and project directories.

Returns: Number of plugins loaded

=cut

sub load_plugins {
    my ($self) = @_;

    my @plugin_dirs = $self->_get_plugin_directories();
    my $loaded = 0;

    for my $dir (@plugin_dirs) {
        next unless -d $dir;

        opendir my $dh, $dir or do {
            log_warning('PluginManager', "Cannot read plugin directory: $dir: $!");
            next;
        };

        my @entries = sort grep { !/^\./ && -d File::Spec->catdir($dir, $_) } readdir($dh);
        closedir $dh;

        for my $entry (@entries) {
            my $plugin_dir = File::Spec->catdir($dir, $entry);
            my $manifest_file = File::Spec->catfile($plugin_dir, 'plugin.json');

            unless (-f $manifest_file) {
                log_debug('PluginManager', "Skipping $entry: no plugin.json");
                next;
            }

            eval {
                $self->_load_plugin($entry, $plugin_dir, $manifest_file);
                $loaded++;
            };
            if ($@) {
                log_warning('PluginManager', "Failed to load plugin '$entry': $@");
            }
        }
    }

    if ($loaded > 0) {
        log_info('PluginManager', "Loaded $loaded plugin(s)");
    }

    return $loaded;
}

=head2 get_tool_definitions

Get tool definitions for all enabled plugins, formatted for the AI API.

Returns: Arrayref of tool definition hashrefs

=cut

sub get_tool_definitions {
    my ($self) = @_;

    my @definitions;

    for my $name (@{$self->{plugin_order}}) {
        my $plugin = $self->{plugins}{$name};
        next unless $plugin->{enabled};
        next unless $plugin->{manifest}{tools};

        for my $tool_def (@{$plugin->{manifest}{tools}}) {
            my $qualified_name = "plugin_${name}_$tool_def->{name}";
            my $description = $tool_def->{description} || "Plugin tool: $tool_def->{name}";
            $description .= "\n\n[Plugin: $name]";

            # Build parameters schema from tool operations
            my $parameters = $self->_build_tool_parameters($tool_def);

            push @definitions, {
                name        => $qualified_name,
                description => $description,
                parameters  => $parameters,
                _plugin     => $name,
                _tool       => $tool_def->{name},
            };
        }
    }

    return \@definitions;
}

=head2 get_all_instructions

Get merged instructions from all enabled plugins.

Returns: Combined instructions string, or undef if no plugins have instructions

=cut

sub get_all_instructions {
    my ($self) = @_;

    my @parts;

    for my $name (@{$self->{plugin_order}}) {
        my $plugin = $self->{plugins}{$name};
        next unless $plugin->{enabled};
        next unless $plugin->{instructions};

        push @parts, "## Plugin: $plugin->{manifest}{description} ($name)\n\n$plugin->{instructions}";
    }

    return undef unless @parts;
    return join("\n\n---\n\n", @parts);
}

=head2 call_tool

Execute a plugin tool.

Arguments:
- $qualified_name: Full qualified tool name (plugin_<name>_<tool>)
- $arguments: Hashref of arguments

Returns: Result hashref { success, output, action_description }

=cut

sub call_tool {
    my ($self, $qualified_name, $arguments) = @_;

    # Parse qualified name: plugin_<pluginname>_<toolname>
    unless ($qualified_name =~ /^plugin_([^_]+)_(.+)$/) {
        return { success => 0, error => "Invalid plugin tool name: $qualified_name" };
    }

    my ($plugin_name, $tool_name) = ($1, $2);
    my $plugin = $self->{plugins}{$plugin_name};

    unless ($plugin) {
        return { success => 0, error => "Plugin not found: $plugin_name" };
    }

    unless ($plugin->{enabled}) {
        return { success => 0, error => "Plugin '$plugin_name' is disabled" };
    }

    # Find the tool definition
    my $tool_def;
    for my $td (@{$plugin->{manifest}{tools} || []}) {
        if ($td->{name} eq $tool_name) {
            $tool_def = $td;
            last;
        }
    }

    unless ($tool_def) {
        return { success => 0, error => "Tool '$tool_name' not found in plugin '$plugin_name'" };
    }

    my $type = $tool_def->{type} || 'http';

    if ($type eq 'http') {
        return $self->_execute_http_tool($plugin, $tool_def, $arguments);
    } elsif ($type eq 'script') {
        return $self->_execute_script_tool($plugin, $tool_def, $arguments);
    } else {
        return { success => 0, error => "Unknown tool type: $type" };
    }
}

=head2 get_plugin_list

Get list of all loaded plugins with their status.

Returns: Arrayref of { name, description, enabled, tools_count, has_instructions }

=cut

sub get_plugin_list {
    my ($self) = @_;

    my @list;

    for my $name (@{$self->{plugin_order}}) {
        my $plugin = $self->{plugins}{$name};
        my $manifest = $plugin->{manifest};

        push @list, {
            name             => $name,
            description      => $manifest->{description} || '',
            version          => $manifest->{version} || '',
            enabled          => $plugin->{enabled} ? 1 : 0,
            tools_count      => scalar(@{$manifest->{tools} || []}),
            has_instructions  => $plugin->{instructions} ? 1 : 0,
            path             => $plugin->{path},
        };
    }

    return \@list;
}

=head2 get_plugin

Get a specific plugin by name.

Returns: Plugin hashref or undef

=cut

sub get_plugin {
    my ($self, $name) = @_;
    return $self->{plugins}{$name};
}

=head2 enable_plugin

Enable a loaded plugin.

=cut

sub enable_plugin {
    my ($self, $name) = @_;

    my $plugin = $self->{plugins}{$name};
    return 0 unless $plugin;

    $plugin->{enabled} = 1;
    $self->_save_plugin_state($name, 'enabled', 1);
    log_info('PluginManager', "Enabled plugin: $name");
    return 1;
}

=head2 disable_plugin

Disable a loaded plugin.

=cut

sub disable_plugin {
    my ($self, $name) = @_;

    my $plugin = $self->{plugins}{$name};
    return 0 unless $plugin;

    $plugin->{enabled} = 0;
    $self->_save_plugin_state($name, 'enabled', 0);
    log_info('PluginManager', "Disabled plugin: $name");
    return 1;
}

=head2 set_plugin_config

Set a configuration value for a plugin.

=cut

sub set_plugin_config {
    my ($self, $plugin_name, $key, $value) = @_;

    my $plugin = $self->{plugins}{$plugin_name};
    return 0 unless $plugin;

    $plugin->{user_config} ||= {};
    $plugin->{user_config}{$key} = $value;

    $self->_save_plugin_state($plugin_name, 'config', $plugin->{user_config});
    log_info('PluginManager', "Set config $key for plugin $plugin_name");
    return 1;
}

=head2 get_plugin_config

Get the resolved configuration for a plugin (user config merged with defaults).

=cut

sub get_plugin_config {
    my ($self, $plugin_name) = @_;

    my $plugin = $self->{plugins}{$plugin_name};
    return {} unless $plugin;

    my $schema = $plugin->{manifest}{config} || {};
    my $user_config = $plugin->{user_config} || {};

    # Merge: user values override schema defaults
    my %resolved;
    for my $key (keys %$schema) {
        if (exists $user_config->{$key}) {
            $resolved{$key} = $user_config->{$key};
        } elsif (exists $schema->{$key}{default}) {
            $resolved{$key} = $schema->{$key}{default};
        }
    }

    return \%resolved;
}

=head2 validate_plugin_config

Check if all required config values are set for a plugin.

Returns: (valid, missing_keys_arrayref)

=cut

sub validate_plugin_config {
    my ($self, $plugin_name) = @_;

    my $plugin = $self->{plugins}{$plugin_name};
    return (0, ['plugin not found']) unless $plugin;

    my $schema = $plugin->{manifest}{config} || {};
    my $resolved = $self->get_plugin_config($plugin_name);

    my @missing;
    for my $key (keys %$schema) {
        if ($schema->{$key}{required} && !exists $resolved->{$key}) {
            push @missing, $key;
        }
    }

    return (scalar(@missing) == 0, \@missing);
}

# --- Private methods ---

sub _get_plugin_directories {
    my ($self) = @_;

    my @dirs;

    # Global plugins: ~/.clio/plugins/
    my $home = $ENV{HOME} || $ENV{USERPROFILE} || '';
    if ($home) {
        push @dirs, File::Spec->catdir($home, '.clio', 'plugins');
    }

    # Project-level plugins: .clio/plugins/
    my $project_dir = File::Spec->catdir('.clio', 'plugins');
    push @dirs, $project_dir;

    return @dirs;
}

sub _load_plugin {
    my ($self, $name, $dir, $manifest_file) = @_;

    # Read manifest
    open my $fh, '<:encoding(UTF-8)', $manifest_file
        or croak "Cannot read $manifest_file: $!";
    my $json = do { local $/; <$fh> };
    close $fh;

    my $manifest = decode_json($json);
    croak "Invalid plugin manifest: missing 'name'" unless $manifest->{name};

    # Override name from directory name for consistency
    my $plugin_name = $name;

    # Read instructions if present
    my $instructions;
    my $instructions_file = File::Spec->catfile($dir, 'instructions.md');
    if (-f $instructions_file) {
        open my $ifh, '<:encoding(UTF-8)', $instructions_file or do {
            log_warning('PluginManager', "Cannot read instructions for $name: $!");
        };
        if ($ifh) {
            $instructions = do { local $/; <$ifh> };
            close $ifh;
            log_debug('PluginManager', "Loaded instructions for $name (" . length($instructions) . " bytes)");
        }
    }

    # Load saved state (enabled/disabled, user config)
    my $state = $self->_load_plugin_state($plugin_name);

    # Determine enabled status: default to manifest, override with saved state
    my $enabled = 1;
    if (exists $manifest->{enabled}) {
        $enabled = $manifest->{enabled} ? 1 : 0;
    }
    if (exists $state->{enabled}) {
        $enabled = $state->{enabled} ? 1 : 0;
    }

    # Store plugin
    $self->{plugins}{$plugin_name} = {
        name         => $plugin_name,
        path         => $dir,
        manifest     => $manifest,
        instructions => $instructions,
        enabled      => $enabled,
        user_config  => $state->{config} || {},
    };

    # Add to ordered list (project plugins can override global ones)
    $self->{plugin_order} = [grep { $_ ne $plugin_name } @{$self->{plugin_order}}];
    push @{$self->{plugin_order}}, $plugin_name;

    my $tools_count = scalar(@{$manifest->{tools} || []});
    my $status = $enabled ? 'enabled' : 'disabled';
    log_info('PluginManager', "Loaded plugin '$plugin_name' ($tools_count tools, $status)");
}

sub _build_tool_parameters {
    my ($self, $tool_def) = @_;

    # If the tool has explicit parameters schema, use it directly
    if ($tool_def->{parameters}) {
        return $tool_def->{parameters};
    }

    # Build from operations
    my $operations = $tool_def->{operations} || {};
    my @op_names = sort keys %$operations;

    if (@op_names) {
        my $params = {
            type       => 'object',
            properties => {
                operation => {
                    type        => 'string',
                    description => 'Operation to perform',
                    enum        => \@op_names,
                },
            },
            required => ['operation'],
        };

        # Merge parameters from all operations
        for my $op_name (@op_names) {
            my $op = $operations->{$op_name};
            if ($op->{parameters}) {
                for my $pname (keys %{$op->{parameters}}) {
                    $params->{properties}{$pname} ||= $op->{parameters}{$pname};
                }
            }
        }

        return $params;
    }

    # Fallback: empty schema
    return { type => 'object', properties => {} };
}

sub _execute_http_tool {
    my ($self, $plugin, $tool_def, $arguments) = @_;

    require CLIO::Compat::HTTP;

    my $config = $self->get_plugin_config($plugin->{name});

    # Determine base URL from plugin config
    my $base_url = $config->{url} || $config->{base_url} || '';
    unless ($base_url) {
        return {
            success          => 0,
            error            => "Plugin '$plugin->{name}' has no URL configured. Use: /plugin config $plugin->{name} url <value>",
            action_description => "Plugin HTTP tool failed: no URL configured",
        };
    }

    # Remove trailing slash from base URL
    $base_url =~ s{/+$}{};

    # Find the operation
    my $operation = $arguments->{operation} || '';
    my $operations = $tool_def->{operations} || {};
    my $op_def = $operations->{$operation};

    unless ($op_def) {
        my @available = sort keys %$operations;
        return {
            success => 0,
            error   => "Unknown operation '$operation'. Available: " . join(', ', @available),
            action_description => "Plugin tool: invalid operation",
        };
    }

    # Build the request
    my $method = uc($op_def->{method} || 'GET');
    my $path = $op_def->{path} || '/';

    # Substitute path parameters: {key} -> value from arguments
    $path =~ s/\{(\w+)\}/$arguments->{$1} || ''/ge;

    my $url = "${base_url}${path}";

    # Build headers
    my %headers = %{$tool_def->{headers} || {}};

    # Inject auth from config
    if ($config->{token}) {
        $headers{'Authorization'} = "Bearer $config->{token}";
    } elsif ($config->{api_key}) {
        $headers{'Authorization'} = "Bearer $config->{api_key}";
    }

    # Add content type for request body
    if ($method eq 'POST' || $method eq 'PUT' || $method eq 'PATCH') {
        $headers{'Content-Type'} ||= 'application/json';
    }

    # Build request body from non-meta arguments
    my %body;
    my %meta_keys = map { $_ => 1 } qw(operation);
    for my $key (keys %$arguments) {
        next if $meta_keys{$key};
        # Skip path parameters already consumed
        next if $path =~ /\{$key\}/;
        $body{$key} = $arguments->{$key};
    }

    # Build query string for GET requests
    if ($method eq 'GET' && %body) {
        my @pairs;
        for my $k (sort keys %body) {
            my $v = $body{$k} // '';
            push @pairs, "$k=$v";
        }
        $url .= ($url =~ /\?/ ? '&' : '?') . join('&', @pairs);
    }

    log_debug('PluginManager', "HTTP $method $url");

    my $http = CLIO::Compat::HTTP->new();
    my $response;

    eval {
        my $body_content = ($method ne 'GET' && %body) ? encode_json(\%body) : undef;
        $response = $http->request($method, $url, \%headers, $body_content);
    };

    if ($@) {
        return {
            success          => 0,
            error            => "HTTP request failed: $@",
            action_description => "Plugin HTTP request failed",
        };
    }

    my $status = $response->{status} || 0;
    my $body_text = $response->{content} || '';

    # Try to parse JSON response
    my $parsed;
    eval { $parsed = decode_json($body_text) };

    my $output;
    if ($parsed) {
        $output = encode_json($parsed);
    } else {
        $output = $body_text;
    }

    # Truncate very large responses
    if (length($output) > 50000) {
        $output = substr($output, 0, 50000) . "\n\n[Response truncated at 50KB]";
    }

    my $success = ($status >= 200 && $status < 300) ? 1 : 0;

    return {
        success          => $success,
        output           => "HTTP $status\n\n$output",
        error            => $success ? undef : "HTTP $status: $body_text",
        action_description => "Plugin '$plugin->{name}': $operation ($method $path) -> HTTP $status",
    };
}

sub _execute_script_tool {
    my ($self, $plugin, $tool_def, $arguments) = @_;

    my $script = $tool_def->{script} || $tool_def->{command};
    unless ($script) {
        return {
            success => 0,
            error   => "No script defined for tool '$tool_def->{name}'",
            action_description => "Plugin script tool: no script configured",
        };
    }

    # Resolve script path relative to plugin directory
    my $script_path;
    if (File::Spec->file_name_is_absolute($script)) {
        $script_path = $script;
    } else {
        $script_path = File::Spec->catfile($plugin->{path}, $script);
    }

    unless (-f $script_path) {
        return {
            success => 0,
            error   => "Script not found: $script_path",
            action_description => "Plugin script not found",
        };
    }

    unless (-x $script_path) {
        return {
            success => 0,
            error   => "Script not executable: $script_path",
            action_description => "Plugin script not executable",
        };
    }

    # Pass arguments as JSON via stdin, config as environment variables
    my $config = $self->get_plugin_config($plugin->{name});
    my $input_json = encode_json($arguments);

    # Build environment
    my %env = %ENV;
    for my $key (keys %$config) {
        my $env_key = 'PLUGIN_' . uc($key);
        $env_key =~ s/[^A-Z0-9_]/_/g;
        $env{$env_key} = $config->{$key} // '';
    }

    # Execute script with timeout
    my $timeout = $tool_def->{timeout} || 30;
    my $output = '';
    my $exit_code;

    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm($timeout);

        my $pid = open my $pipe, '-|';
        if (!defined $pid) {
            die "Cannot fork: $!";
        }

        if ($pid == 0) {
            # Child process
            open STDIN, '<', \$input_json;
            for my $k (keys %env) {
                $ENV{$k} = $env{$k};
            }
            exec($script_path) or die "Cannot exec: $!";
        }

        # Parent: read output
        $output = do { local $/; <$pipe> };
        close $pipe;
        $exit_code = $? >> 8;
        alarm(0);
    };

    if ($@ && $@ =~ /timeout/) {
        return {
            success          => 0,
            error            => "Script timed out after ${timeout}s",
            action_description => "Plugin script timed out",
        };
    } elsif ($@) {
        return {
            success          => 0,
            error            => "Script execution error: $@",
            action_description => "Plugin script error",
        };
    }

    # Try to parse JSON output
    my $parsed;
    eval { $parsed = decode_json($output) };

    if ($parsed && ref($parsed) eq 'HASH') {
        return {
            success          => $parsed->{success} // ($exit_code == 0 ? 1 : 0),
            output           => $parsed->{output} || encode_json($parsed),
            error            => $parsed->{error},
            action_description => "Plugin '$plugin->{name}': $tool_def->{name}" .
                ($parsed->{action_description} ? " - $parsed->{action_description}" : ''),
        };
    }

    return {
        success          => ($exit_code == 0) ? 1 : 0,
        output           => $output,
        action_description => "Plugin '$plugin->{name}': $tool_def->{name} (exit $exit_code)",
    };
}

sub _load_plugin_state {
    my ($self, $name) = @_;

    my $state_file = $self->_state_file($name);
    return {} unless -f $state_file;

    my $state;
    eval {
        open my $fh, '<:encoding(UTF-8)', $state_file or die "Cannot open: $!";
        my $json = do { local $/; <$fh> };
        close $fh;
        $state = decode_json($json);
    };

    if ($@) {
        log_warning('PluginManager', "Cannot read plugin state for $name: $@");
        return {};
    }

    return $state || {};
}

sub _save_plugin_state {
    my ($self, $name, $key, $value) = @_;

    my $state_file = $self->_state_file($name);
    my $state = $self->_load_plugin_state($name);
    $state->{$key} = $value;

    eval {
        my $dir = File::Spec->catdir($ENV{HOME} || '.', '.clio', 'plugin_state');
        make_path($dir) unless -d $dir;

        my $temp = "$state_file.tmp";
        open my $fh, '>:encoding(UTF-8)', $temp or croak "Cannot write $temp: $!";
        print $fh encode_json($state);
        close $fh;
        rename $temp, $state_file or croak "Cannot rename: $!";
    };

    if ($@) {
        log_warning('PluginManager', "Cannot save plugin state for $name: $@");
    }
}

sub _state_file {
    my ($self, $name) = @_;
    my $dir = File::Spec->catdir($ENV{HOME} || '.', '.clio', 'plugin_state');
    return File::Spec->catfile($dir, "$name.json");
}

1;

__END__

=head1 SEE ALSO

L<CLIO::Tools::PluginBridge>, L<CLIO::MCP::Manager>

=cut
