# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Tools::MCPBridge;

use strict;
use warnings;
use utf8;

=head1 NAME

CLIO::Tools::MCPBridge - Bridges MCP server tools into CLIO's tool registry

=head1 DESCRIPTION

Dynamically creates CLIO tool wrappers for each MCP tool discovered from
connected MCP servers. Each MCP tool becomes a first-class CLIO tool that
the AI can call like any other tool.

Tool names are namespaced as: mcp_<servername>_<toolname>

=cut

use CLIO::Util::JSON qw(encode_json decode_json);

use CLIO::Core::Logger qw(log_debug log_warning);

=head2 before_route

Security gate for MCP tool execution. Provides defense-in-depth alongside
the sandbox check in ToolExecutor. This method is called as a class method
before execute_tool dispatches to the MCP manager.

Arguments:
- $qualified_name: Full qualified tool name (with mcp_ prefix)
- $arguments: Hashref of tool arguments
- $context: Execution context (optional, may contain config for sandbox check)

Returns: undef to proceed, or a result hashref to short-circuit dispatch

=cut

sub before_route {
    my ($class, $qualified_name, $arguments, $context) = @_;

    # Sandbox mode: Block all MCP tool calls as defense-in-depth.
    # ToolExecutor already checks this, but having it here too ensures
    # that any future code path that calls execute_tool directly is
    # also protected.
    if ($context && $context->{config} && $context->{config}->get('sandbox')) {
        log_debug('MCP', "Sandbox: BLOCKED MCP tool '$qualified_name'");
        return {
            success          => 0,
            error            => "Sandbox mode: MCP tools are disabled.\n\n" .
                "The --sandbox flag blocks all MCP operations. " .
                "This is a security feature to prevent the agent from reaching outside the local project.",
            action_description => "Sandbox: blocked MCP tool '$qualified_name'",
        };
    }

    return undef;
}

=head2 generate_tool_definitions

Generate CLIO tool definitions for all MCP tools.

Arguments:
- $mcp_manager: CLIO::MCP::Manager instance

Returns: Arrayref of tool definitions in CLIO registry format

=cut

sub generate_tool_definitions {
    my ($class, $mcp_manager) = @_;
    
    return [] unless $mcp_manager;
    
    my $mcp_tools = $mcp_manager->all_tools();
    return [] unless $mcp_tools && @$mcp_tools;
    
    my @definitions;
    
    for my $entry (@$mcp_tools) {
        my $tool = $entry->{tool};
        my $qualified_name = "mcp_$entry->{name}";
        
        # Build parameters from MCP inputSchema
        my $parameters = $tool->{inputSchema} || {
            type       => 'object',
            properties => {},
        };
        
        # Ensure it's a proper JSON Schema object
        $parameters->{type} = 'object' unless $parameters->{type};
        
        my $description = $tool->{description} || "MCP tool: $entry->{original_name}";
        $description .= "\n\n[MCP Server: $entry->{server}]";
        
        push @definitions, {
            name           => $qualified_name,
            description    => $description,
            parameters     => $parameters,
            mcp_server     => $entry->{server},
            mcp_tool_name  => $entry->{original_name},
        };
        
        log_debug('MCP', "Registered MCP tool: $qualified_name");
    }
    
    return \@definitions;
}

=head2 execute_tool

Execute an MCP tool via the bridge.

Arguments:
- $mcp_manager: CLIO::MCP::Manager instance
- $qualified_name: Full qualified tool name (with mcp_ prefix)
- $arguments: Hashref of tool arguments

Returns: CLIO tool result hashref { success, output, action_description }

=cut

sub execute_tool {
    my ($class, $mcp_manager, $qualified_name, $arguments, $context) = @_;
    
    # Defense-in-depth: check before_route before dispatching.
    # ToolExecutor already checks sandbox mode, but this ensures any
    # direct caller is also protected.
    my $guard = $class->before_route($qualified_name, $arguments, $context);
    return $guard if $guard;
    
    unless ($mcp_manager) {
        return {
            success          => 0,
            error            => 'MCP not available',
            action_description => 'MCP tool execution failed: no MCP manager',
        };
    }
    
    # Strip mcp_ prefix to get the manager's qualified name
    my $manager_name = $qualified_name;
    $manager_name =~ s/^mcp_//;
    
    log_debug('MCP', "Executing MCP tool: $manager_name");
    
    my $result = eval { $mcp_manager->call_tool($manager_name, $arguments) };
    
    if ($@) {
        return {
            success          => 0,
            error            => "MCP tool error: $@",
            action_description => "MCP tool '$manager_name' failed: $@",
        };
    }
    
    if ($result->{error}) {
        return {
            success          => 0,
            error            => $result->{error},
            action_description => "MCP tool '$manager_name' error: $result->{error}",
        };
    }
    
    # Format the output
    my $output = $result->{text} || '';
    
    # If we have structured content, include it
    if ($result->{content} && ref($result->{content}) eq 'ARRAY') {
        # Already formatted in text, but include raw for structured tools
        if (!$output && @{$result->{content}}) {
            $output = encode_json($result->{content});
        }
    }
    
    return {
        success          => 1,
        output           => $output,
        action_description => "MCP tool '$manager_name' executed",
    };
}

=head2 is_mcp_tool

Check if a tool name is an MCP tool.

=cut

sub is_mcp_tool {
    my ($class, $tool_name) = @_;
    return ($tool_name && $tool_name =~ /^mcp_/) ? 1 : 0;
}

1;

__END__

=head1 SEE ALSO

L<CLIO::MCP::Manager>, L<CLIO::MCP::Client>

=cut

1;
