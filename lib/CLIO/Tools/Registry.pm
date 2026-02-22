package CLIO::Tools::Registry;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use Carp qw(croak confess);
use CLIO::Core::Logger qw(should_log);
use feature 'say';

=head1 NAME

CLIO::Tools::Registry - Tool registration and lookup system

=head1 DESCRIPTION

Centralized registry for managing CLIO::Tools::Tool instances. Provides
registration, lookup, and tool definition generation for API calls.

Pattern inspired by SAM's MCPToolRegistry which maintains explicit
tool ordering for KV cache efficiency.

Refactored from schema-based approach to class-based Tool pattern
for cleaner architecture and better maintainability.

=head1 SYNOPSIS

    use CLIO::Tools::Registry;
    use CLIO::Tools::FileOperations;
    
    my $registry = CLIO::Tools::Registry->new(debug => 1);
    
    # Register tools
    $registry->register_tool(
        CLIO::Tools::FileOperations->new()
    );
    
    # Get tool by name
    my $tool = $registry->get_tool('file_operations');
    
    # Execute tool
    my $result = $tool->execute($params, $context);
    
    # Get all tool definitions for API
    my $definitions = $registry->get_tool_definitions();

=cut

sub new {
    my ($class, %opts) = @_;
    
    return bless {
        tools => {},        # name -> tool instance
        tool_order => [],   # ordered list of tool names
        debug => $opts{debug} || 0,
    }, $class;
}

=head2 register_tool

Register a tool with the registry.

Arguments:
- $tool: Tool instance (must have {name} field)

Returns: 1 on success, dies on error

=cut

sub register_tool {
    my ($self, $tool) = @_;
    
    croak "Tool must have a 'name' field" unless $tool->{name};
    
    my $name = $tool->{name};
    
    # Check for duplicate
    if (exists $self->{tools}{$name}) {
        print STDERR "[WARN]Registry] Tool '$name' already registered, replacing\n";
    }
    
    $self->{tools}{$name} = $tool;
    
    # Add to ordered list (if not already present)
    unless (grep { $_ eq $name } @{$self->{tool_order}}) {
        push @{$self->{tool_order}}, $name;
    }
    
    print STDERR "[DEBUG][Registry] Registered tool: $name\n" if should_log('DEBUG');
    
    return 1;
}

=head2 get_tool

Get a tool instance by name.

Arguments:
- $name: Tool name

Returns: Tool instance, or undef if not found

=cut

sub get_tool {
    my ($self, $name) = @_;
    
    my $tool = $self->{tools}{$name};
    
    unless ($tool) {
        print STDERR "[WARN]Registry] Tool not found: $name\n" if $self->{debug};
    }
    
    return $tool;
}

=head2 get_all_tools

Get all registered tools in registration order.

Returns: Arrayref of tool instances

=cut

sub get_all_tools {
    my ($self) = @_;
    
    return [map { $self->{tools}{$_} } @{$self->{tool_order}}];
}

=head2 get_tool_definitions

Generate tool definitions for API calls (GitHub Copilot, OpenAI, etc.)

Converts tool instances to OpenAI function calling format.

Returns: Arrayref of tool definition hashrefs in OpenAI format

=cut

sub get_tool_definitions {
    my ($self) = @_;
    
    # Return cached definitions if available (they don't change during a session)
    return $self->{_definitions_cache} if $self->{_definitions_cache};
    
    my @definitions;
    
    for my $name (@{$self->{tool_order}}) {
        my $tool = $self->{tools}{$name};
        
        # Get definition from tool
        my $tool_def = $tool->get_tool_definition();
        
        # Convert to OpenAI function calling format
        my $definition = {
            type => 'function',
            function => {
                name => $tool_def->{name},
                description => $tool_def->{description},
                parameters => $tool_def->{parameters},
            },
        };
        
        push @definitions, $definition;
    }
    
    print STDERR "[DEBUG][Registry] Generated " . scalar(@definitions) . " tool definitions\n" 
        if $self->{debug};
    
    # Cache for subsequent calls
    $self->{_definitions_cache} = \@definitions;
    
    return \@definitions;
}

=head2 list_tools

Get list of registered tool names.

Returns: Arrayref of tool names in registration order

=cut

sub list_tools {
    my ($self) = @_;
    
    return [@{$self->{tool_order}}];
}

=head2 count_tools

Count registered tools.

Returns: Integer count

=cut

sub count_tools {
    my ($self) = @_;
    
    return scalar @{$self->{tool_order}};
}

=head2 has_tool

Check if a tool is registered.

Arguments:
- $name: Tool name

Returns: Boolean (1 if registered, 0 if not)

=cut

sub has_tool {
    my ($self, $name) = @_;
    
    return exists $self->{tools}{$name};
}

=head2 unregister_tool

Remove a tool from the registry.

Arguments:
- $name: Tool name

Returns: 1 if removed, 0 if not found

=cut

sub unregister_tool {
    my ($self, $name) = @_;
    
    unless (exists $self->{tools}{$name}) {
        print STDERR "[WARN]Registry] Cannot unregister unknown tool: $name\n" if $self->{debug};
        return 0;
    }
    
    delete $self->{tools}{$name};
    
    # Remove from order list
    $self->{tool_order} = [grep { $_ ne $name } @{$self->{tool_order}}];
    
    print STDERR "[DEBUG][Registry] Unregistered tool: $name\n" if should_log('DEBUG');
    
    return 1;
}

=head2 clear

Remove all tools from the registry.

Returns: Count of tools removed

=cut

sub clear {
    my ($self) = @_;
    
    my $count = $self->count_tools();
    
    $self->{tools} = {};
    $self->{tool_order} = [];
    
    print STDERR "[DEBUG][Registry] Cleared $count tools\n" if should_log('DEBUG');
    
    return $count;
}

1;

__END__

=head1 DESIGN NOTES

The registry maintains explicit ordering of tools for several reasons:

1. **KV Cache Efficiency**: Tools should appear in system prompts in consistent
   order to maximize KV cache hits across requests

2. **Priority Ordering**: More commonly used tools can be registered first,
   appearing earlier in the tool list

3. **Predictable Behavior**: Iteration order is guaranteed, not hash-dependent

This pattern is based on SAM's MCPToolRegistry which uses explicit ordering
for optimal performance with language model caching mechanisms.

=head1 OPENAI TOOL CALLING FORMAT

Tools are sent to the AI model in this format:

    {
        "tools": [
            {
                "type": "function",
                "function": {
                    "name": "file_operations",
                    "description": "...",
                    "parameters": { ... }
                }
            }
        ]
    }

AI responds with tool_calls:

    {
        "role": "assistant",
        "content": null,
        "tool_calls": [
            {
                "id": "call_abc123",
                "type": "function",
                "function": {
                    "name": "file_operations",
                    "arguments": "{\"operation\":\"read\",\"path\":\"README.md\"}"
                }
            }
        ]
    }

We execute the tool and send back:

    {
        "role": "tool",
        "tool_call_id": "call_abc123",
        "content": "File contents here..."
    }

This continues until AI responds without tool_calls (conversation complete).

=head1 MIGRATION FROM OLD REGISTRY

Old registry had hardcoded tool schemas in _register_builtin_tools().
New registry uses CLIO::Tools::Tool pattern with class-based tools.

Benefits:
- Separation of concerns (schema vs execution)
- Easier testing
- Extensible architecture
- Matches SAM production patterns

=head1 SEE ALSO

- CLIO::Tools::Tool - Base class for operation-based tools
- ai-assisted/SAM_ANALYSIS.md - SAM pattern analysis
- IMPLEMENTATION_PLAN_SAM_PATTERNS.md - Implementation roadmap

=cut

1;
