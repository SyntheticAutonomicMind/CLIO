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
    my ($class, $plugin_manager, $qualified_name, $arguments) = @_;

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
