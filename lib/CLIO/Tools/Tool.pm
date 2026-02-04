package CLIO::Tools::Tool;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use Carp qw(croak confess);
use CLIO::Core::Logger qw(should_log);
use feature 'say';

=head1 NAME

CLIO::Tools::Tool - Base class for operation-based tools

=head1 DESCRIPTION

Base class for tools that combine multiple related operations into a single
tool with operation-based routing. Pattern inspired by SAM's MCPFramework
ConsolidatedMCP protocol.

Tools reduce system prompt size by grouping related operations under one
tool name (e.g., file_operations with 16 operations instead of 16 separate tools).

=head1 SYNOPSIS

    package CLIO::Tools::FileOperations;
    use parent 'CLIO::Tools::Tool';
    
    sub new {
        my ($class, %opts) = @_;
        return $class->SUPER::new(
            name => 'file_operations',
            description => 'File operations: read, write, search',
            supported_operations => [qw(read_file write_file search_files)],
            %opts,
        );
    }
    
    sub route_operation {
        my ($self, $operation, $params, $context) = @_;
        
        if ($operation eq 'read_file') {
            return $self->read_file($params, $context);
        }
        # ... etc
    }

=cut

sub new {
    my ($class, %opts) = @_;
    
    # Validate required fields
    croak "Subclass must define 'name'" unless $opts{name};
    croak "Subclass must define 'description'" unless $opts{description};
    croak "Subclass must define 'supported_operations'" unless $opts{supported_operations};
    
    return bless {
        name => $opts{name},
        description => $opts{description},
        supported_operations => $opts{supported_operations},
        debug => $opts{debug} || 0,
        
        # Execution control metadata (SAM-inspired pattern + CLIO enhancements)
        requires_blocking => $opts{requires_blocking} || 0,  # Tool must wait for completion before workflow continues
        requires_serial => $opts{requires_serial} || 0,      # Tool executes one-at-a-time (but doesn't block workflow)
        is_interactive => $opts{is_interactive} || 0,        # Tool needs terminal I/O by default (can be overridden per-call)
    }, $class;
}

=head2 execute

Main entry point for tool execution. Extracts operation parameter,
validates it, and routes to appropriate handler.

Arguments:
- $params: Hashref of parameters (must include 'operation')
- $context: Execution context (session, conversation_id, etc.)

Returns: Hashref with success, output/error, metadata

=cut

sub execute {
    my ($self, $params, $context) = @_;
    
    print STDERR "[DEBUG][Tool:$self->{name}] Execute called\n" if should_log('DEBUG');
    
    # Extract operation parameter
    my $operation = $params->{operation};
    unless ($operation) {
        my $available = join(', ', @{$self->{supported_operations}});
        print STDERR "[DEBUG][Tool:$self->{name}] Missing 'operation' parameter. Available: $available\n" if should_log('ERROR');
        return $self->operation_error("Missing 'operation' parameter");
    }
    
    # Validate operation
    unless ($self->validate_operation($operation)) {
        my $available = join(', ', @{$self->{supported_operations}});
        print STDERR "[DEBUG][Tool:$self->{name}] Unknown operation: '$operation'. Available: $available\n" if should_log('ERROR');
        return $self->operation_error("Unknown operation: $operation");
    }
    
    # Route to operation handler
    print STDERR "[DEBUG][Tool:$self->{name}] Routing to operation: $operation\n" if should_log('DEBUG');
    
    return $self->route_operation($operation, $params, $context);
}

=head2 validate_operation

Check if an operation is supported by this tool.

Arguments:
- $operation: Operation name to validate

Returns: Boolean (1 if supported, 0 if not)

=cut

sub validate_operation {
    my ($self, $operation) = @_;
    
    return grep { $_ eq $operation } @{$self->{supported_operations}};
}

=head2 route_operation

Route to specific operation implementation. MUST be implemented by subclass.

Arguments:
- $operation: Operation name (already validated)
- $params: Hashref of parameters
- $context: Execution context

Returns: Hashref with success, output/error, metadata

=cut

sub route_operation {
    my ($self, $operation, $params, $context) = @_;
    croak "Subclass must implement route_operation()";
}

=head2 operation_error

Generate helpful error message when operation is invalid or fails.

Arguments:
- $message: Error message

Returns: Hashref with success=0, error message, and available operations

=cut

sub operation_error {
    my ($self, $message) = @_;
    
    my $operations = join("\n  - ", @{$self->{supported_operations}});
    
    my $error_text = <<EOF;
ERROR: $message

Available operations for '$self->{name}':
  - $operations

Example usage:
{
  "tool": "$self->{name}",
  "operation": "$self->{supported_operations}[0]",
  ... other parameters depending on operation
}

Tip: Each operation may have different required parameters.
EOF
    
    return {
        success => 0,
        error => $error_text,
        tool_name => $self->{name},
    };
}

=head2 get_tool_definition

Generate tool definition for API (GitHub Copilot, OpenAI, etc.)

Returns: Hashref with name, description, parameters schema

=cut

sub get_tool_definition {
    my ($self) = @_;
    
    return {
        name => $self->{name},
        description => $self->{description},
        parameters => {
            type => "object",
            properties => {
                operation => {
                    type => "string",
                    enum => $self->{supported_operations},
                    description => "Operation to perform",
                },
                # Subclass can add more parameters via get_additional_parameters()
                %{$self->get_additional_parameters() || {}},
            },
            required => ["operation"],
        },
    };
}

=head2 get_additional_parameters

Override this to add tool-specific parameters to the tool definition.

Returns: Hashref of additional parameter definitions (default: empty)

=cut

sub get_additional_parameters {
    my ($self) = @_;
    return {};
}

=head2 success_result

Helper to create a success result.

Arguments:
- $output: Output data (string or hashref)
- %metadata: Optional metadata fields
  * action_description: Human-readable action performed (e.g., "reading file.txt")

Returns: Hashref with success=1, output, metadata

=cut

sub success_result {
    my ($self, $output, %metadata) = @_;
    
    return {
        success => 1,
        output => $output,
        tool_name => $self->{name},
        action_description => $metadata{action_description},  # For user feedback
        %metadata,
    };
}

=head2 error_result

Helper to create an error result.

Arguments:
- $error: Error message
- %metadata: Optional metadata fields

Returns: Hashref with success=0, error, metadata

=cut

sub error_result {
    my ($self, $error, %metadata) = @_;
    
    return {
        success => 0,
        error => $error,
        tool_name => $self->{name},
        %metadata,
    };
}

1;

__END__

=head1 BENEFITS

Operation-based tools provide several advantages:

1. **Token Reduction**: One tool description covers multiple operations
2. **Logical Grouping**: Related operations grouped by domain (files, git, memory)
3. **Clear Intent**: Tool names clearly indicate purpose
4. **Extensibility**: New operations can be added without new tools
5. **Smaller System Prompts**: Fewer tools = faster inference

=head1 PATTERN ORIGIN

This pattern is inspired by SAM's ConsolidatedMCP protocol, which reduced
SAM's tool count from ~39 individual tools to 15 tools (62% reduction).

Major tools in SAM:
- file_operations (16 operations)
- memory_operations (3 operations)
- terminal_operations (11+ operations)
- todo_operations (4 operations)

=head1 SEE ALSO

- ai-assisted/SAM_ANALYSIS.md - Detailed analysis of SAM patterns
- IMPLEMENTATION_PLAN_SAM_PATTERNS.md - Implementation roadmap

=cut

1;
