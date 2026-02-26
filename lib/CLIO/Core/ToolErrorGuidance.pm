package CLIO::Core::ToolErrorGuidance;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;
use CLIO::Util::JSON qw(encode_json);

=head1 NAME

CLIO::Core::ToolErrorGuidance - Provide agents with clear error guidance for bad tool calls

=head1 DESCRIPTION

When agents make bad tool calls (missing required params, invalid values, etc.),
they need clear, actionable error messages that help them fix the problem.

This module:
1. Categorizes tool errors (missing required, invalid operation, invalid params, etc.)
2. Provides specific guidance for each error type
3. Includes the correct schema from the tool definition
4. Gives examples of correct usage

This prevents agents from abandoning tools after repeated failures.

=head1 SYNOPSIS

    use CLIO::Core::ToolErrorGuidance;
    
    my $guidance = CLIO::Core::ToolErrorGuidance->new();
    
    # When a tool returns an error:
    my $enhanced = $guidance->enhance_tool_error(
        error => "Missing required parameter: message",
        tool_name => "user_collaboration",
        tool_definition => $tool_def,
        attempted_params => $params
    );
    
    # Returns comprehensive error with schema and examples

=cut

sub new {
    my ($class) = @_;
    
    my $self = {};
    bless $self, $class;
    
    return $self;
}

=head2 enhance_tool_error

Enhance a tool error with comprehensive guidance for the agent.

Arguments:
- error (required): The error message from the tool
- tool_name (required): Name of the tool that failed
- tool_definition (optional): Full tool definition with schema
- attempted_params (optional): Parameters agent tried to use

Returns: String with enhanced error message including:
1. Clear error classification
2. What went wrong
3. Correct schema (if available)
4. Example of correct usage
5. Common mistakes to avoid

=cut

sub enhance_tool_error {
    my ($self, %args) = @_;
    
    my $error = $args{error} || 'Unknown error';
    my $tool_name = $args{tool_name} || 'unknown_tool';
    my $tool_def = $args{tool_definition};
    my $attempted = $args{attempted_params} || {};
    
    # Categorize the error
    my $category = $self->_categorize_error($error, $tool_name);
    
    # Build enhanced error message with guidance
    my @parts;
    
    # 1. Clear error statement
    push @parts, "TOOL ERROR: $tool_name";
    push @parts, $error;
    push @parts, "";
    
    # 2. Guidance based on error category
    my $guidance = $self->_get_category_guidance($category, $tool_name, $error, $attempted, $tool_def);
    push @parts, $guidance;
    
    # 3. Schema information (if available)
    if ($tool_def && ref($tool_def) eq 'HASH') {
        push @parts, $self->_format_schema_help($tool_name, $tool_def);
    }
    
    # 4. Examples
    push @parts, $self->_get_examples_for_error($category, $tool_name);
    
    return join("\n", @parts);
}

=head2 _categorize_error

Categorize the error to provide targeted guidance.

=cut

sub _categorize_error {
    my ($self, $error, $tool_name) = @_;
    
    # Edit/patch content mismatch errors (must check BEFORE generic file_not_found)
    return 'edit_content_mismatch' if $error =~ /string not found in file|old_?string not found/i;
    return 'edit_content_mismatch' if $error =~ /cannot find match position for chunk/i;
    return 'edit_ambiguous_match' if $error =~ /old_?string found multiple times|multiple matches/i;
    
    return 'missing_required' if $error =~ /missing required parameter/i;
    return 'invalid_operation' if $error =~ /unknown operation|unsupported.*operation/i;
    return 'invalid_json' if $error =~ /json|parse error/i;
    return 'missing_ui' if $error =~ /ui.*not available/i;
    return 'invalid_value' if $error =~ /invalid.*value|must be|should be/i;
    return 'insufficient_params' if $error =~ /insufficient|need/i;
    return 'file_not_found' if $error =~ /cannot.*find|not found|no such file/i;
    return 'permission_denied' if $error =~ /permission|denied|access/i;
    return 'generic_error';
}

=head2 _get_category_guidance

Get guidance text specific to the error category.

=cut

sub _get_category_guidance {
    my ($self, $category, $tool_name, $error, $attempted, $tool_def) = @_;
    
    my %guidance = (
        edit_content_mismatch => sub {
            return "WHAT WENT WRONG: Your edit failed because the text you're trying to replace does not match the file's current content.\n" .
                   "Your assumption about what the file contains is WRONG.\n\n" .
                   "IMMEDIATE ACTION REQUIRED:\n" .
                   "1. READ the file NOW to see its ACTUAL current content\n" .
                   "2. FIND the real text you want to change\n" .
                   "3. RETRY with the correct old_string that exactly matches the file\n\n" .
                   "DO NOT retry the same edit without reading the file first.";
        },
        
        edit_ambiguous_match => sub {
            return "WHAT WENT WRONG: The text you're trying to replace appears MULTIPLE TIMES in the file.\n" .
                   "The replacement would be ambiguous.\n\n" .
                   "IMMEDIATE ACTION REQUIRED:\n" .
                   "1. READ the file to see ALL occurrences of the text\n" .
                   "2. Include MORE surrounding context in old_string to uniquely identify the target\n" .
                   "3. RETRY with a longer, unique old_string that matches exactly ONE location\n\n" .
                   "TIP: Include 2-3 surrounding lines in old_string to make the match unique.";
        },
        
        missing_required => sub {
            my @missing = $error =~ /parameter[s]?:\s*([a-z_]+)/gi;
            my $params_str = join(', ', @missing);
            
            return "WHAT WENT WRONG: You didn't include the required parameter(s): $params_str\n" .
                   "HOW TO FIX: Include these required parameters in your tool call.\n" .
                   "REQUIRED: All parameters marked 'required' in the schema MUST be included.";
        },
        
        invalid_operation => sub {
            my $ops_str = '';
            if ($tool_def && $tool_def->{parameters} && 
                $tool_def->{parameters}->{properties} && 
                $tool_def->{parameters}->{properties}->{operation} &&
                $tool_def->{parameters}->{properties}->{operation}->{enum}) {
                my @ops = @{$tool_def->{parameters}->{properties}->{operation}->{enum}};
                $ops_str = join(', ', @ops);
            }
            
            my $valid = $ops_str ? "\nVALID operations: $ops_str" : '';
            
            return "WHAT WENT WRONG: You used an invalid 'operation' value.\n" .
                   "HOW TO FIX: Set 'operation' to one of the valid values.$valid";
        },
        
        invalid_json => sub {
            return "WHAT WENT WRONG: The arguments JSON you provided is malformed.\n" .
                   "HOW TO FIX: Check your JSON syntax - all string values must be quoted, all braces/brackets must match.\n" .
                   "COMMON MISTAKES:\n" .
                   "  - String without quotes: {path: /tmp/file}  (WRONG)\n" .
                   "  - Missing comma: {path: \"/tmp\", content: \"text\" \"more\"} (WRONG)\n" .
                   "  - Newlines in strings not escaped: {message: \"line1\nline2\"} (WRONG - use \\\\n)";
        },
        
        missing_ui => sub {
            return "WHAT WENT WRONG: The UI is not available (terminal interface not initialized).\n" .
                   "HOW TO FIX: This tool requires an interactive terminal. Check that CLIO is running with terminal UI enabled.";
        },
        
        invalid_value => sub {
            return "WHAT WENT WRONG: One of your parameter values is invalid (wrong type, wrong range, etc.).\n" .
                   "HOW TO FIX: Check the schema below to see what values are allowed for each parameter.";
        },
        
        insufficient_params => sub {
            return "WHAT WENT WRONG: You don't have enough information to complete this operation.\n" .
                   "HOW TO FIX: Check what parameters are needed and provide all of them.";
        },
        
        file_not_found => sub {
            return "WHAT WENT WRONG: The file or directory you're trying to access doesn't exist.\n" .
                   "HOW TO FIX: Check the path is correct. Use the correct absolute or relative path.";
        },
        
        permission_denied => sub {
            return "WHAT WENT WRONG: You don't have permission to access this file or directory.\n" .
                   "HOW TO FIX: Check file permissions or try a different path.";
        },
        
        generic_error => sub {
            return "WHAT WENT WRONG: Tool execution failed.\n" .
                   "HOW TO FIX: Check the error message for details. Review the schema below to ensure all parameters are correct.";
        },
    );
    
    if (exists $guidance{$category}) {
        return $guidance{$category}->();
    }
    
    return $guidance{generic_error}->();
}

=head2 _format_schema_help

Format the tool's schema as clear, readable guidance.

=cut

sub _format_schema_help {
    my ($self, $tool_name, $tool_def) = @_;
    
    unless ($tool_def && ref($tool_def) eq 'HASH') {
        return '';
    }
    
    my @help;
    push @help, "";
    push @help, "--- SCHEMA REFERENCE ---";
    
    # Get parameters
    my $params = $tool_def->{parameters};
    if ($params && ref($params) eq 'HASH' && $params->{properties}) {
        my $props = $params->{properties};
        my $required = $params->{required} || [];
        my %required_map = map { $_ => 1 } @$required;
        
        push @help, "";
        push @help, "Parameters:";
        
        foreach my $param_name (sort keys %$props) {
            my $param = $props->{$param_name};
            my $req_marker = $required_map{$param_name} ? ' [REQUIRED]' : ' [optional]';
            
            push @help, "";
            push @help, "  $param_name$req_marker";
            
            # Type
            if ($param->{type}) {
                push @help, "    Type: $param->{type}";
            }
            
            # Description
            if ($param->{description}) {
                push @help, "    Description: $param->{description}";
            }
            
            # Enum values
            if ($param->{enum} && ref($param->{enum}) eq 'ARRAY') {
                my $values = join(', ', @{$param->{enum}});
                push @help, "    Allowed values: $values";
            }
            
            # Default
            if (defined $param->{default}) {
                push @help, "    Default: $param->{default}";
            }
            
            # Item type for arrays
            if ($param->{type} eq 'array' && $param->{items}) {
                my $item_type = $param->{items}->{type} || 'unknown';
                push @help, "    Array of: $item_type";
            }
        }
    }
    
    return join("\n", @help);
}

=head2 _get_examples_for_error

Provide examples of correct usage for the tool.

=cut

sub _get_examples_for_error {
    my ($self, $category, $tool_name) = @_;
    
    # Map tool names to example functions
    my %examples = (
        file_operations => sub {
            return "--- CORRECT USAGE EXAMPLES ---\n" .
                   "Reading a file:\n" .
                   '  {"operation": "read_file", "path": "/path/to/file.txt"}\n' .
                   "\n" .
                   "Writing to a file:\n" .
                   '  {"operation": "write_file", "path": "/path/to/file.txt", "content": "Hello world"}\n' .
                   "\n" .
                   "Searching files:\n" .
                   '  {"operation": "grep_search", "query": "pattern", "pattern": "*.pm"}';
        },
        
        user_collaboration => sub {
            return "--- CORRECT USAGE EXAMPLES ---\n" .
                   "Requesting user input:\n" .
                   '  {"operation": "request_input", "message": "Which approach should I use?", "context": "Optional context here"}\n' .
                   "\n" .
                   "The message parameter is REQUIRED and must clearly ask the user for what you need.";
        },
        
        version_control => sub {
            return "--- CORRECT USAGE EXAMPLES ---\n" .
                   "Check git status:\n" .
                   '  {"operation": "status"}\n' .
                   "\n" .
                   "Make a commit:\n" .
                   '  {"operation": "commit", "message": "description of changes"}\n' .
                   "\n" .
                   "View recent commits:\n" .
                   '  {"operation": "log", "limit": 10}';
        },
        
        terminal_operations => sub {
            return "--- CORRECT USAGE EXAMPLES ---\n" .
                   "Execute a command:\n" .
                   '  {"operation": "exec", "command": "ls -la"}\n' .
                   "\n" .
                   "Validate command safety:\n" .
                   '  {"operation": "validate", "command": "npm install"}';
        },
    );
    
    if (exists $examples{$tool_name}) {
        return $examples{$tool_name}->();
    }
    
    return "--- SCHEMA DETAILS ---\nRefer to the schema section above for parameter details.";
}

=head2 format_error_for_ai

Format a tool error in a way that helps AI agents recover from mistakes.

This is the main entry point for WorkflowOrchestrator.

Arguments:
- error (required): The error message
- tool_name (required): Name of tool that failed
- tool_definition (optional): Tool's schema definition
- attempted_params (optional): Parameters agent tried

Returns: String ready to send to AI as tool result

=cut

sub format_error_for_ai {
    my ($self, %args) = @_;
    
    my $enhanced = $self->enhance_tool_error(%args);
    
    # Wrap in clear ERROR marker
    return "ERROR: " . $enhanced;
}

1;

=head1 LICENSE

SPDX-License-Identifier: GPL-3.0-only

=head1 AUTHOR

Andrew Wyatt (Fewtarius) <andrew@fewtarius.dev>

=cut
