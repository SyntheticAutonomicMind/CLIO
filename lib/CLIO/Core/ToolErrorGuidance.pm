package CLIO::Core::ToolErrorGuidance;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

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
        tool_name => "interact",
        tool_definition => $tool_def,
        attempted_params => $params
    );
    
    # Returns comprehensive error with schema and examples

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        debug => $args{debug} // 0,
    };
    bless $self, $class;

    return $self;
}

=head2 categorize_error

Public wrapper around _categorize_error so callers (e.g. the
tool-error-loop detector in WorkflowOrchestrator) can get a stable
category string without depending on the leading underscore convention.

Arguments:
    $error     - The error message text
    $tool_name - The tool that produced the error

Returns:
    Category string (e.g. 'missing_required', 'invalid_operation',
    'directory_not_found', 'generic_error'). See _categorize_error
    for the full taxonomy.

=cut

sub categorize_error {
    my ($self, $error, $tool_name) = @_;
    return $self->_categorize_error($error // '', $tool_name // '');
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

    # Validation-failed forms. These are emitted by TodoStore::validate() and
    # carry actionable detail ("Multiple todos marked as in-progress...") but
    # the previous "validation failed" message gave the agent no schema to
    # follow. Surface them under their own category with a targeted fix.
    return 'todo_validation_failed' if $error =~ /^update validation failed/i;
    return 'todo_validation_failed' if $error =~ /multiple todos marked as in-progress/i;

    # Missing the operation parameter entirely (must come BEFORE missing_required
    # since some messages mention 'parameter' too, but we want operation-specific
    # guidance here).
    return 'missing_operation' if $error =~ /missing\s+['"`]?operation['"`]?\s+parameter/i;

    # Generic missing-required-parameter patterns. Catches the common forms:
    #   - "Missing required parameter: foo"
    #   - "Missing required parameters: foo, bar"
    #   - "Missing 'foo' parameter"
    #   - "Missing 'foo' or 'bar' parameter"
    #   - "Missing or empty 'foo' parameter"
    return 'missing_required' if $error =~ /missing\s+required\s+(?:parameter|field|param|argument)s?(?:\(s\))?\s*[:\-]\s*([a-zA-Z0-9_, ]+?)(?:\s*\(|\s*\.\s|$)/i;
    return 'missing_required' if $error =~ /missing\s+(?:or\s+empty\s+)?['"`]?(\w+)['"`]?\s+parameter/i;
    # "Missing 'foo' or 'bar' parameter" - alternation form.
    return 'missing_required' if $error =~ /missing\s+(?:or\s+empty\s+)?['"`]?(\w+)['"`]?\s+or\s+['"`]?(\w+)['"`]?\s+parameter/i;

    # Operation-needs-parameter form: "'update' operation requires 'todoUpdates' parameter"
    return 'missing_required' if $error =~ /['"`]?(\w+)['"`]?\s+operation\s+requires\s+['"`]?(\w+)['"`]?\s+parameter/i;

    # Working directory / path-doesn't-exist forms. The agent often tries
    # to write a file under a directory that doesn't exist yet, or calls
    # a tool from the wrong cwd. Both surface as "Working directory does
    # not exist" / "Directory not found" - distinguish from file_not_found
    # because the agent needs to create the directory, not look harder.
    return 'directory_not_found' if $error =~ /working directory.*not.*(exist|found)|directory.*not.*found/i;
    return 'directory_not_found' if $error =~ /no such file or directory/i;
    return 'directory_not_readable' if $error =~ /directory.*not.*readable/i;

    return 'invalid_operation' if $error =~ /unknown operation|unsupported.*operation/i;
    return 'invalid_json' if $error =~ /json|parse error/i;
    return 'missing_ui' if $error =~ /ui.*not available/i;
    return 'invalid_value' if $error =~ /invalid.*value|must be|should be/i;
    # Remote execution input validation. Common agent mistakes when calling
    # remote_execution: empty host, missing port range, bad path. These are
    # distinct from "the tool failed" - they're "your inputs were bad".
    return 'invalid_value' if $error =~ /invalid host|invalid ssh port|invalid ssh key|invalid file path/i;
    # Invalid regex pattern (grep_search). Agent should fix the pattern, not
    # retry with the same regex.
    return 'invalid_regex' if $error =~ /invalid regex|invalid regex pattern/i;
    # Invalid status value in todoList/todoUpdates. Agent should use one of
    # the enum values listed in the schema.
    return 'invalid_value' if $error =~ /invalid status|invalid '?status'?\b/i;
    # Sandbox mode blocks the operation. Agent should NOT retry - it should
    # either disable sandbox or pick a different operation.
    return 'sandbox_blocked' if $error =~ /sandbox mode|sandbox.*disabled|sandbox.*blocked/i;
    return 'insufficient_params' if $error =~ /insufficient|need/i;
    # Unknown tool — the model called a tool name that doesn't exist in any
    # registered tool (e.g. "read" instead of "read_file"). This is common
    # with models trained on OpenAI/aider tool schemas. Surface a clear
    # "use the correct tool" message before file_not_found, which would
    # otherwise match "not found" in the error string and give path guidance.
    return 'unknown_tool' if $error =~ /^Unknown tool:/i;
    # file_not_found is intentionally AFTER the more-specific skill_not_found
    # and directory_not_found rules so the agent gets targeted guidance
    # instead of the generic "check the path" advice.
    return 'skill_not_found' if $error =~ /skill.*not found|skill not installed/i;
    return 'file_not_found' if $error =~ /cannot.*find|not found|no such file/i;
    return 'permission_denied' if $error =~ /permission|denied|access/i;

    # Git-specific forms - "Not a Git repository" is the most common
    # error agents hit when they try version_control ops on a fresh
    # clone or a directory that's not a repo. The agent usually recovers
    # by running `git init` or by running the command from the right cwd.
    return 'not_a_git_repository' if $error =~ /not a git repository/i;

    # Operation cancelled by the user/coordinator. The agent should not
    # retry - it should treat this as "user wants to stop" and surface
    # a final answer rather than continuing the loop.
    return 'operation_cancelled' if $error =~ /cancelled|stop signal|received stop/i;

    # User input timeout - the user didn't respond within the wait window.
    # Different from operation_cancelled: the user might still be there,
    # just slow. The agent can retry with a longer timeout or take an
    # alternative path that doesn't require user input.
    return 'user_input_timeout' if $error =~ /timeout.*user|user.*timeout/i;

    # Remote execution timeout. The remote agent or command didn't
    # finish in time. The agent should retry with a longer timeout
    # or check the remote agent's logs.
    return 'remote_timeout' if $error =~ /remote.*timed out|remote.*timeout/i;

    # Network unreachable / host unreachable. The remote SSH target
    # is offline. The agent should verify host connectivity before
    # retrying.
    return 'network_unreachable' if $error =~ /network is unreachable|host is unreachable|no route to host|connection refused|connection timed out/i;

    # External system unavailable (SkillManager, SubAgent system). The
    # agent should not retry - it needs to take an alternative path.
    return 'system_unavailable' if $error =~ /unavailable|system not available|not available/i;

    # Operation not implemented (defensive guard for tools that don't
    # handle a particular operation). Agent should check the schema's
    # operation enum for valid operations.
    return 'invalid_operation' if $error =~ /operation not implemented/i;

    # Skill name validation. Agent should use only alphanumeric, dash,
    # underscore, dot, slash.
    return 'invalid_value' if $error =~ /invalid skill name/i;

    return 'generic_error';
}

=head2 _get_category_guidance

Get guidance text specific to the error category.

Arguments:
- $category: Category from _categorize_error
- $tool_name: Name of the tool that failed
- $error: Original error string
- $attempted: Hashref of parameters the agent tried
- $tool_def: Full tool definition (for schema-aware hints)

Returns: Multi-line string with the guidance text.

=cut

sub _get_category_guidance {
    my ($self, $category, $tool_name, $error, $attempted, $tool_def) = @_;

    my %guidance = (
        edit_content_mismatch => sub {
            return "WHAT WENT WRONG: Your edit failed because the file's current content has changed since you last read it.\n" .
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

        missing_operation => sub {
            # The agent called the tool without an 'operation' field. This is the
            # single most common first-attempt error in CLIO - the agent includes
            # everything EXCEPT the operation. We need to surface a clear "add the
            # operation field" message with the valid options listed.
            my $ops = '';
            if ($tool_def && $tool_def->{parameters} &&
                $tool_def->{parameters}->{properties} &&
                $tool_def->{parameters}->{properties}->{operation} &&
                $tool_def->{parameters}->{properties}->{operation}->{enum}) {
                my @op_list = @{$tool_def->{parameters}->{properties}->{operation}->{enum}};
                $ops = join(', ', @op_list);
            }
            my $ops_text = $ops
                ? "\n\nVALID operations for '$tool_name': $ops"
                : "\n\nRead the tool's description above to see the list of valid operations.";
            return "WHAT WENT WRONG: You called '$tool_name' WITHOUT specifying which operation to perform.\n" .
                   "The 'operation' parameter is REQUIRED on every call to a CLIO tool.\n" .
                   "HOW TO FIX: Add an 'operation' field to your tool call with one of the values listed below." .
                   $ops_text . "\n\n" .
                   "QUICK EXAMPLE (use the operation that matches what you want to do):\n" .
                   "  {\"operation\": \"<one-of-the-above>\", ...other params...}";
        },

        missing_required => sub {
            # Try to extract the missing fields from the error message
            # Pattern 1: "missing required field(s): description, title"
            # Pattern 2: "missing required parameter: message"
            # Pattern 3: "missing required parameters: foo, bar"
            my @missing;
            # Canonical "Missing required parameter(s): foo, bar"
            # Trailing context: ( begins a parenthetical, . followed by space
            # begins a sentence, $ end-of-string.
            if ($error =~ /missing\s+required\s+(?:parameter|field|param|argument)s?(?:\(s\))?\s*[:\-]\s*([a-zA-Z0-9_, ]+?)(?:\s*\(|\s*\.\s|$)/i) {
                @missing = split(/\s*,\s*/, $1);
            }
            # Bare "Missing 'foo' parameter" - extract the named parameter(s).
            # IMPORTANT: try the alternation form ("Missing 'foo' or 'bar' parameter")
            # FIRST. The simple form's \w+ is greedy and would otherwise match only
            # "foo" or only "bar" but not both from "foo' or 'bar'". The two-word
            # form must come first.
            elsif ($error =~ /missing\s+(?:or\s+empty\s+)?['"`]?(\w+)['"`]?\s+or\s+['"`]?(\w+)['"`]?\s+parameter/i) {
                @missing = ($1, $2);
            }
            elsif ($error =~ /missing\s+(?:or\s+empty\s+)?['"`]?(\w+)['"`]?\s+parameter/i) {
                push @missing, $1;
            }
            # "'update' operation requires 'todoUpdates' parameter" - extract BOTH
            # the operation name AND the missing param, so we can show the agent
            # exactly which slot to use.
            elsif ($error =~ /['"`]?(\w+)['"`]?\s+operation\s+requires\s+['"`]?(\w+)['"`]?\s+parameter/i) {
                @missing = ($2);
            }

            my $params_str = @missing ? join(', ', @missing) : 'see schema below';

            return "WHAT WENT WRONG: You didn't include the required field(s): $params_str\n" .
                   "HOW TO FIX: Include ALL required fields in your tool call.\n" .
                   "REQUIRED: Every field marked 'required' in the schema MUST be included, including fields inside array items (like todoList items, newTodos items, etc.).\n" .
                   "COMMON MISTAKES:\n" .
                   "  - Omitting 'description' in todo items - it is REQUIRED, not optional\n" .
                   "  - Sending todo update content in the 'todoList' field - the 'update' operation needs 'todoUpdates' (NOT 'todoList')\n" .
                   "  - Sending new todo content in 'newTodos' for a 'write' - the 'write' operation needs 'todoList'\n" .
                   "  - Forgetting to specify an 'operation' at all (the most common mistake)";
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

        unknown_tool => sub {
            return "WHAT WENT WRONG: The tool name '$tool_name' does not match any tool " .
                   "CLIO has registered. This happens when the model uses a tool name from a " .
                   "different framework (e.g. 'read', 'write', 'list_directory' from the " .
                   "OpenAI/aider schema) instead of CLIO's own tool names.\n" .
                   "HOW TO FIX: Use the correct CLIO tool name. The valid tools are: " .
                   "file_operations, terminal_operations, version_control, memory_operations, " .
                   "web_operations, todo_operations, code_intelligence, interact, " .
                   "apply_patch, remote_execution, agent_operations, skill_operations. " .
                   "Each takes an 'operation' parameter (e.g. file_operations with " .
                   "operation='read_file').\n" .
                   "TIP: Read the tool schema in the system prompt — the JSON schema " .
                   "lists each tool's exact name and valid operations.";
        },

        todo_validation_failed => sub {
            # TodoStore::validate() returned one or more errors. Surface them
            # with the rule that triggered them so the agent can fix the
            # call without re-reading the schema.
            my $hint = '';
            if ($error =~ /multiple todos marked as in-progress/i) {
                $hint = "Only ONE todo may have status='in-progress' at a time. " .
                        "Mark the previous one 'completed' (or 'not-started') " .
                        "BEFORE marking the next one 'in-progress'.";
            } elsif ($error =~ /todo missing 'id' field/i) {
                $hint = "Every todo in todoUpdates needs an 'id' field. Use the 'read' " .
                        "operation first to see existing IDs.";
            } elsif ($error =~ /missing 'title' field|missing 'description' field|missing 'status' field/i) {
                $hint = "Every todo needs 'title', 'description', and 'status' fields. " .
                        "title and description are short strings; status must be one of " .
                        "not-started, pending, in-progress, completed, blocked.";
            } elsif ($error =~ /invalid status/i) {
                $hint = "Status must be one of: not-started, pending, in-progress, completed, blocked.";
            } elsif ($error =~ /depends on non-existent todo/i) {
                $hint = "A 'dependencies' entry references an ID that doesn't exist. " .
                        "Use the 'read' operation to confirm IDs before referencing them.";
            } elsif ($error =~ /circular dependency/i) {
                $hint = "Todos form a dependency cycle (A depends on B which depends on A). " .
                        "Break the cycle by removing one of the dependencies.";
            } elsif ($error =~ /no blockedReason|has no blockedReason/i) {
                $hint = "A todo with status='blocked' MUST have a 'blockedReason' field " .
                        "explaining what it's blocked on.";
            }
            return "WHAT WENT WRONG: The todo list update was rejected by validation.\n" .
                   "Original errors:\n$error\n\n" .
                   ($hint ? "HOW TO FIX: $hint\n" : "HOW TO FIX: Read each error line above; each one names a specific todo and the rule it violated.\n");
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

        directory_not_found => sub {
            return "WHAT WENT WRONG: The directory you're trying to access doesn't exist.\n" .
                   "HOW TO FIX: Check that the path is correct. If the parent directory should exist, " .
                   "verify your current working directory (terminal_operations: exec with 'pwd'). " .
                   "If you need to CREATE the directory, call file_operations with operation='create_directory' first.";
        },

        directory_not_readable => sub {
            return "WHAT WENT WRONG: The directory exists but you don't have read permission.\n" .
                   "HOW TO FIX: Check file permissions on the directory. The sandbox may be blocking access to this path.";
        },

        not_a_git_repository => sub {
            return "WHAT WENT WRONG: The current directory is not a Git repository.\n" .
                   "HOW TO FIX: Either run 'git init' to initialize a new repo, or change to a directory " .
                   "that is already a Git repo. Check your current working directory with terminal_operations: exec 'pwd'.";
        },

        operation_cancelled => sub {
            return "WHAT WENT WRONG: The operation was cancelled by the user or coordinator.\n" .
                   "HOW TO FIX: Do NOT retry this operation. Treat this as a stop signal and surface a final answer to the user instead of continuing the loop.";
        },

        user_input_timeout => sub {
            return "WHAT WENT WRONG: The user didn't respond within the wait window (default 300s).\n" .
                   "HOW TO FIX: Either retry with a longer timeout (pass timeout=<seconds>), or take an alternative path that doesn't require user input.\n" .
                   "If the user explicitly said 'go ahead' before the timeout fired, retry once with a fresh request.";
        },

        invalid_regex => sub {
            return "WHAT WENT WRONG: Your grep_search 'is_regex=true' pattern is not a valid Perl regex.\n" .
                   "HOW TO FIX: Fix the regex syntax. Common issues: unescaped brackets, unmatched parens, unescaped metacharacters like . * + ?.\n" .
                   "Test the pattern with terminal_operations: exec 'perl -e \"print \\\"ok\\\" if /<pattern>/\"' first if you are unsure.";
        },

        skill_not_found => sub {
            return "WHAT WENT WRONG: The skill name you provided is not in the catalog.\n" .
                   "HOW TO FIX: Call skill_operations with operation='list' (no 'name' parameter) to see all available skills, then retry with the exact name from the catalog. " .
                   "Skill names are case-sensitive and must match exactly.";
        },

        sandbox_blocked => sub {
            return "WHAT WENT WRONG: The --sandbox flag is enabled, which blocks this operation.\n" .
                   "HOW TO FIX: Do NOT retry. Either disable sandbox (run CLIO without --sandbox) or pick a different operation that doesn't require external access.";
        },

        remote_timeout => sub {
            return "WHAT WENT WRONG: A remote command or sub-agent didn't finish within the timeout.\n" .
                   "HOW TO FIX: Retry with a longer timeout, or check the remote agent's logs at /tmp/clio-agent-*.log.";
        },

        network_unreachable => sub {
            return "WHAT WENT WRONG: The remote host is unreachable (network down, host offline, or SSH service not running).\n" .
                   "HOW TO FIX: Verify the host is online (e.g. ping) and that SSH is running. Then retry. Do not retry indefinitely.";
        },

        system_unavailable => sub {
            return "WHAT WENT WRONG: A required subsystem is not available (SkillManager, SubAgent system, etc.).\n" .
                   "HOW TO FIX: Do NOT retry. Take an alternative path that does not depend on this subsystem, " .
                   "or surface the limitation to the user.";
        },

        invalid_value => sub {
            # Extract the parameter name when the error message names one
            # ("Invalid value for 'foo'"). The schema's enum/type for that
            # param is the most actionable hint we can give.
            my $param_name;
            if ($error =~ /invalid.*?(?:value.*?for\s+['"`]?(\w+)['"`]?|['"`]?(\w+)['"`]?\s+is\s+invalid)/i) {
                $param_name = $1 || $2;
            }
            my $hint = $param_name
                ? "\n\nThe invalid parameter appears to be '$param_name'. Check the schema's 'type' and 'enum' for that field below."
                : "";
            return "WHAT WENT WRONG: One of your parameter values is invalid (wrong type, wrong range, or not in the allowed enum).\n" .
                   "HOW TO FIX: Check the schema below to see what values are allowed for each parameter." . $hint;
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
            if (($param->{type} || '') eq 'array' && $param->{items}) {
                my $item_type = $param->{items}->{type} || 'unknown';
                push @help, "    Array of: $item_type";
                
                # Show nested required fields inside array items
                if ($param->{items}->{type} eq 'object' && $param->{items}->{properties}) {
                    my $item_required = $param->{items}->{required} || [];
                    my %item_req_map = map { $_ => 1 } @$item_required;
                    
                    if (@$item_required) {
                        push @help, "    Required fields in each item: " . join(', ', @$item_required);
                    }
                    
                    foreach my $item_prop (sort keys %{$param->{items}->{properties}}) {
                        my $item_field = $param->{items}->{properties}->{$item_prop};
                        my $req = $item_req_map{$item_prop} ? ' [REQUIRED]' : ' [optional]';
                        my $desc = $item_field->{description} || '';
                        push @help, "      $item_prop$req: $desc";
                    }
                }
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
        
        interact => sub {
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

        todo_operations => sub {
            return "--- CORRECT USAGE EXAMPLES ---\n" .
                   "Write a todo list (EVERY item needs title, description, AND status):\n" .
                   '  {"operation": "write", "todoList": [{"title": "Fix bug", "description": "Fix the null pointer in module X", "status": "not-started"}]}' . "\n" .
                   "\n" .
                   "Update todo status (uses todoUpdates, NOT todoList):\n" .
                   '  {"operation": "update", "todoUpdates": [{"id": 1, "status": "in-progress"}]}' . "\n" .
                   "\n" .
                   "Add new todos (uses newTodos, NOT todoList):\n" .
                   '  {"operation": "add", "newTodos": [{"title": "Write tests", "description": "Unit tests for module Y"}]}' . "\n" .
                   "\n" .
                   "CRITICAL: The 'description' field is REQUIRED for every todo item. Never omit it.";
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

1;
