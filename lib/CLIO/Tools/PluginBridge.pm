# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Tools::PluginBridge;

use strict;
use warnings;
use utf8;
use CLIO::Core::Logger qw(log_debug log_warning);

=head1 NAME

CLIO::Tools::PluginBridge - Bridges plugin tools into CLIO's tool registry

=head1 DESCRIPTION

Generates CLIO tool definitions for plugin tools and routes execution
to the PluginManager. Similar to MCPBridge but for the native plugin system.

Tool names are namespaced as: plugin_<pluginname>_<toolname>

=cut

=head2 before_route

Security gate for plugin tool execution. Provides defense-in-depth alongside
the sandbox check in ToolExecutor. This method is called as a class method
before execute_tool dispatches to the plugin manager.

Arguments:
- $qualified_name: Full qualified tool name (plugin_<name>_<tool>)
- $arguments: Hashref of tool arguments
- $context: Execution context (optional, may contain config for sandbox check)

Returns: undef to proceed, or a result hashref to short-circuit dispatch

=cut

sub before_route {
    my ($class, $qualified_name, $arguments, $context) = @_;

    # Sandbox mode: Block all plugin tool calls as defense-in-depth.
    # ToolExecutor already checks this, but having it here too ensures
    # that any future code path that calls execute_tool directly is
    # also protected.
    if ($context && $context->{config} && $context->{config}->get('sandbox')) {
        log_debug('PluginBridge', "Sandbox: BLOCKED plugin tool '$qualified_name'");
        return {
            success          => 0,
            error            => "Sandbox mode: Plugin tools are disabled.\n\n" .
                "The --sandbox flag blocks all plugin operations. " .
                "This is a security feature to prevent the agent from reaching outside the local project.",
            action_description => "Sandbox: blocked plugin tool '$qualified_name'",
        };
    }

    return undef;
}

=head2 generate_tool_definitions

Generate CLIO tool definitions for all plugin tools.

Arguments:
- $plugin_manager: CLIO::Core::PluginManager instance

Returns: Arrayref of tool definitions in CLIO API format

=cut

sub generate_tool_definitions {
    my ($class, $plugin_manager) = @_;

    return [] unless $plugin_manager;

    my $defs = $plugin_manager->get_tool_definitions();
    return [] unless $defs && @$defs;

    my @api_defs;
    for my $def (@$defs) {
        push @api_defs, {
            name        => $def->{name},
            description => $def->{description},
            parameters  => $def->{parameters},
        };

        log_debug('PluginBridge', "Registered plugin tool: $def->{name}");
    }

    return \@api_defs;
}

=head2 execute_tool

Execute a plugin tool via the bridge.

Arguments:
- $plugin_manager: CLIO::Core::PluginManager instance
- $qualified_name: Full qualified tool name (plugin_<name>_<tool>)
- $arguments: Hashref of tool arguments

Returns: CLIO tool result hashref { success, output, action_description }

=cut

sub execute_tool {
    my ($class, $plugin_manager, $qualified_name, $arguments, $context) = @_;

    # Defense-in-depth: check before_route before dispatching.
    # ToolExecutor already checks sandbox mode, but this ensures any
    # direct caller is also protected.
    my $guard = $class->before_route($qualified_name, $arguments, $context);
    return $guard if $guard;

    unless ($plugin_manager) {
        return {
            success          => 0,
            error            => 'Plugin system not available',
            action_description => 'Plugin tool execution failed: no PluginManager',
        };
    }

    log_debug('PluginBridge', "Executing plugin tool: $qualified_name");

    my $result = eval { $plugin_manager->call_tool($qualified_name, $arguments) };

    if ($@) {
        return {
            success          => 0,
            error            => "Plugin tool error: $@",
            action_description => "Plugin tool '$qualified_name' failed",
        };
    }

    return $result;
}

1;

__END__

=head1 SEE ALSO

L<CLIO::Core::PluginManager>, L<CLIO::Tools::MCPBridge>

=cut

1;
