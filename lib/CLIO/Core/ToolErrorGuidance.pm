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
        debug         => $args{debug} // 0,
        # Optional. When present, unknown-tool guidance can name the callables
        # the model should have used instead of describing them in the
        # abstract.
        tool_registry => $args{tool_registry},
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
    
    # 3. Schema information (if available). For missing_required errors,
    # only show the specific missing field(s) instead of dumping all 20+
    # parameters — the agent needs to focus on the one fix, not scroll
    # through a wall of schema.
    if ($tool_def && ref($tool_def) eq 'HASH') {
        my $focus = undef;
        if ($category eq 'missing_required') {
            $focus = $self->_extract_missing_fields($error);
        }
        push @parts, $self->_format_schema_help($tool_name, $tool_def, $focus);
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

    # The dispatcher refused the name: it is not a callable in this build.
    # This must come first - the message is not a "the tool ran and failed"
    # error, and generic file/not-found rules would mislabel it.
    return 'unknown_tool' if $error =~ /^unknown tool:|is not part of the current tool set/i;

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

    # Path exists but is the wrong kind: a file where a directory is
    # required, or a directory where a file is required. This is NOT
    # "not found" - the path is right there. Reporting it as missing sends
    # the caller hunting for a path it already has, so it gets its own
    # category with advice that is a correction, not a search.
    return 'path_kind_mismatch'
        if $error =~ /(?:path|file|directory)\s+is\s+a\s+(?:file|directory)\s*,?\s*not\s+a\s+(?:file|directory)/i;

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

    # Git author identity is missing or a placeholder (e.g. a task harness
    # left `Test User <test@test.com>` in .git/config). The commit/tag/stash
    # operations refuse to stamp bad authorship; the agent must fix the
    # identity, not retry the commit as-is.
    return 'git_identity_misconfigured'
        if $error =~ /git author identity/i;

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

=head2 _example_arguments (Internal)

Build a placeholder argument hash from a callable's own emitted schema, so an
error message can show the shape of the call it is asking for.

Arguments: $callable - emitted callable name

Returns: Hashref of required parameter => type placeholder, or undef when the
callable has no required parameters or no schema is available.

=cut

sub _example_arguments {
    my ($self, $callable) = @_;

    my $registry = $self->{tool_registry} or return undef;
    my $def = eval { $registry->get_definition($callable) } or return undef;

    my $required = $def->{parameters}{required} || [];
    my $props    = $def->{parameters}{properties} || {};
    return undef unless @$required;

    my %example;
    for my $name (@$required) {
        my $type = $props->{$name}{type} // 'string';
        $example{$name} =
              $type eq 'number'  ? 0
            : $type eq 'integer' ? 0
            : $type eq 'boolean' ? \1
            : $type eq 'array'   ? []
            : $type eq 'object'  ? {}
            :                      "<$name>";
    }

    return \%example;
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
        unknown_tool => sub {
            my $text = "WHAT WENT WRONG: '$tool_name' is not a callable name in this build's tool set, so nothing ran.\n" .
                       "The tool list is the complete set of callable names. Calling this name again, or adding an\n" .
                       "'operation' field to it, will fail the same way.\n\n";

            my $registry = $self->{tool_registry};

            # The attempt usually carries the answer: a grouping name plus the
            # operation it meant. Naming that one callable is a better fix than
            # listing every operation the tool owns.
            my $attempted_op = ref($attempted) eq 'HASH' ? $attempted->{operation} : undef;
            if ($registry && defined $attempted_op && length $attempted_op) {
                my $callable = $registry->get_operation_callable($tool_name, $attempted_op);
                $callable ||= $attempted_op if $registry->is_emitted_name($attempted_op);

                if ($callable) {
                    my %retry = %$attempted;
                    delete $retry{operation};
                    # An empty body tells the model nothing; the schema does.
                    my $example = $self->_example_arguments($callable);
                    my $shown = %retry ? \%retry : ($example || {});
                    my $params = eval { encode_json($shown) } || '{}';
                    return $text
                        . "HOW TO FIX: You meant the '$attempted_op' operation. Call the callable\n"
                        . "'$callable' directly - it is the same operation under its published name:\n"
                        . "  {\"name\": \"$callable\", \"parameters\": $params}\n"
                        . "The 'operation' field is not part of that call; the parameters travel at the top level.";
                }
            }

            # Direct hash lookup: get_tool() resolves aliases, which would
            # answer with the owning tool for an emitted callable name and
            # make a real callable look like a grouping tool.
            my $tool = $registry ? $registry->{tools}{$tool_name} : undef;
            if ($tool && $tool->can('get_operation_tool_definitions')) {
                my $defs = $tool->get_operation_tool_definitions();
                if ($defs && ref($defs) eq 'HASH' && keys %$defs) {
                    my @callables = map { $registry->get_operation_callable($tool_name, $_) || $_ }
                                    sort keys %$defs;
                    $text .= "HOW TO FIX: '$tool_name' groups operations that are published as separate callables.\n" .
                             "Call one of these names directly: " . join(', ', @callables) . ".\n" .
                             "Put that callable's parameters at the top level of the arguments - no 'operation' field.";
                    return $text;
                }
            }

            my @similar = $self->_similar_callables($tool_name);
            if (@similar) {
                $text .= "HOW TO FIX: Call one of these names instead: " . join(', ', @similar) . ".\n";
                if (@similar == 1) {
                    my $example = $self->_example_arguments($similar[0]);
                    if ($example) {
                        my $params = eval { encode_json($example) } || '{}';
                        $text .= "That callable takes: $params\n";
                    }
                }
            } else {
                $text .= "HOW TO FIX: Pick the callable from the tool list whose description matches what you want, and call it by that exact name.\n";
            }
            return $text;
        },

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

            # Param-swap detection: when 'query' is missing but 'pattern' was
            # provided in the attempted params, the model almost certainly
            # confused the two. 'query' is the search text; 'pattern' is a
            # file glob filter. Give a targeted hint instead of generic guidance.
            my $swap_hint = '';
            my $missing_query = grep { $_ eq 'query' } @missing;
            if ($missing_query && $attempted && exists $attempted->{pattern}) {
                $swap_hint = "\n\nALERT: You provided 'pattern' but forgot 'query'!\n" .
                             "  - 'query' = the TEXT to search for (REQUIRED for grep_search / semantic_search)\n" .
                             "  - 'pattern' = a file glob filter like '*.pm' (OPTIONAL - limits which files are searched)\n" .
                             "These are DIFFERENT parameters. Put your search text in 'query'.";
            }

            # Name the missing field and stop. The general checklist that used
            # to follow sent the model after todo-list mistakes it had not made,
            # and told it to add an 'operation' field to per-operation tools
            # that do not take one - the correction taught the next failure.
            my $required_note = '';
            if ($tool_def && ref($tool_def->{parameters}{properties}) eq 'HASH') {
                my $props = $tool_def->{parameters}{properties};
                my $has_array_items = grep {
                    ($props->{$_}{type} || '') eq 'array'
                        && $props->{$_}{items}
                        && ref($props->{$_}{items}) eq 'HASH'
                        && $props->{$_}{items}{properties}
                } sort keys %$props;

                $required_note = "REQUIRED: Include every field the schema marks required"
                    . ($has_array_items ? ", plus the required fields inside each array item" : "")
                    . ".\n";

                unless (exists $props->{operation}) {
                    $required_note .= "This tool takes no 'operation' field - its name already selects the action.\n";
                }
            }

            return "WHAT WENT WRONG: You didn't include the required field(s): $params_str\n" .
                   "HOW TO FIX: Add the missing field(s) and call again.\n" .
                   $required_note .
                   $swap_hint;
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

        path_kind_mismatch => sub {
            return "WHAT WENT WRONG: The path exists, but it is not the kind this operation needs - " .
                   "a file where a directory is required, or a directory where a file is required.\n" .
                   "HOW TO FIX: The path is correct. Do not hunt for a different path and do not " .
                   "retry the same call - read the error text, which states what the path is and " .
                   "which operations accept it.\n" .
                   "  - file_search and list_dir need a DIRECTORY. To read a file, use read_file. " .
                   "To search one file's contents, use grep_search with directory set to that file.\n" .
                   "  - read_file, replace_string, insert_at_line, and get_errors need a FILE. " .
                   "To see what a directory holds, use list_dir.";
        },

        directory_not_found => sub {
            return "WHAT WENT WRONG: The directory you're trying to access doesn't exist.\n" .
                   "HOW TO FIX: Check the path is correct. Confirm before guessing: " .
                   "file_exists on the path tells you whether it exists and what kind it is. " .
                   "If the path is a FILE rather than a directory, file_search and grep_search " .
                   "both accept a file path directly - pass it as 'directory' (or 'path') and " .
                   "they search just that file. " .
                   "If you need to CREATE the directory, call create_directory first.\n" .
                   "TIP: Verify your current working directory with terminal_operations: exec 'pwd'.";
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

        git_identity_misconfigured => sub {
            return "WHAT WENT WRONG: Git author identity is missing or looks like a placeholder " .
                   "(e.g. \`Test User <test\@test.com>\` left by a task harness).\n" .
                   "HOW TO FIX: Set a real git identity for this repository before committing, then retry:\n" .
                   "  git config user.name \"Your Name\"\n" .
                   "  git config user.email \"your\@email.com\"\n" .
                   "Check current values: git config user.name; git config user.email";
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
                   "HOW TO FIX: Call skill_list (no 'name' parameter) to see all available skills, then retry with the exact name from the catalog. " .
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

=head2 _extract_missing_fields

Extract the names of missing required fields from an error message.
Used to focus the schema dump on only the relevant parameters.

Arguments:
- $error: The error message text

Returns:
- ArrayRef of missing field names (may be empty)

=cut

sub _extract_missing_fields {
    my ($self, $error) = @_;

    my @missing;

    # "Missing required parameter(s): foo, bar" or "Missing required field(s): foo"
    if ($error =~ /missing\s+required\s+(?:parameter|field|param|argument)s?(?:\(s\))?\s*[:\-]\s*([a-zA-Z0-9_, ]+?)(?:\s*\(|\s*\.\s|$)/i) {
        @missing = split(/\s*,\s*/, $1);
    }
    # "Missing 'foo' or 'bar' parameter" — alternation form
    elsif ($error =~ /missing\s+(?:or\s+empty\s+)?['"`]?(\w+)['"`]?\s+or\s+['"`]?(\w+)['"`]?\s+parameter/i) {
        @missing = ($1, $2);
    }
    # "Missing 'foo' parameter" — simple form
    elsif ($error =~ /missing\s+(?:or\s+empty\s+)?['"`]?(\w+)['"`]?\s+parameter/i) {
        push @missing, $1;
    }
    # "'update' operation requires 'todoUpdates' parameter"
    elsif ($error =~ /['"`]?(\w+)['"`]?\s+operation\s+requires\s+['"`]?(\w+)['"`]?\s+parameter/i) {
        push @missing, $2;
    }

    return \@missing;
}

=head2 _format_schema_help

Format the tool's schema as clear, readable guidance.

=cut

sub _format_schema_help {
    my ($self, $tool_name, $tool_def, $focus_fields) = @_;
    
    unless ($tool_def && ref($tool_def) eq 'HASH') {
        return '';
    }
    
    my @help;
    push @help, "";
    push @help, "--- SCHEMA REFERENCE ---";
    
    # When focus_fields is provided (from missing_required categorization),
    # only show the specific missing fields instead of dumping all 20+
    # parameters. The agent needs to see just what they omitted.
    my %focus;
    my $trimmed = 0;
    if ($focus_fields && ref($focus_fields) eq 'ARRAY' && @$focus_fields) {
        %focus = map { $_ => 1 } @$focus_fields;
        $trimmed = 1;
        push @help, "";
        push @help, "(Showing only the field(s) that are missing — omit this note by providing all required fields.)";
    }
    
    # Get parameters
    my $params = $tool_def->{parameters};
    if ($params && ref($params) eq 'HASH' && $params->{properties}) {
        my $props = $params->{properties};
        my $required = $params->{required} || [];
        my %required_map = map { $_ => 1 } @$required;
        
        push @help, "";
        push @help, "Parameters:";
        
        my @param_names = $trimmed ? (sort keys %focus) : (sort keys %$props);
        foreach my $param_name (@param_names) {
            next unless exists $props->{$param_name};
            my $param = $props->{$param_name};
            # A field reported as missing is required for this call whatever
            # the flat schema says. The consolidated schema carries a single
            # `required: ["operation"]` array that cannot express
            # operation-specific requirements, so trusting it here printed
            # "content [optional]" directly beneath "Missing required
            # parameter: content" - guidance that contradicted the error it
            # was meant to repair.
            my $is_required = $required_map{$param_name}
                || ($trimmed && $focus{$param_name});
            my $req_marker = $is_required ? ' [REQUIRED]' : ' [optional]';
            
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

=head2 _similar_callables

Find emitted callable names that share a word with a name the model tried.

Used by unknown-tool recovery when the attempted name is not a registered
tool at all (a typo or an invented name). Token overlap is enough here: the
goal is a short, plausible list to steer the next call, not a ranked spell
checker.

Arguments:
- $name: the callable name that was attempted

Returns: List of up to 6 emitted callable names, best overlap first

=cut

sub _similar_callables {
    my ($self, $name) = @_;

    my $registry = $self->{tool_registry};
    return () unless $registry;

    my %tokens = map { $_ => 1 } grep { length($_) > 2 } split /[^a-z0-9]+/, lc($name // '');
    return () unless %tokens;

    my @scored;
    for my $candidate (sort keys %{ $registry->get_emitted_names() }) {
        my $score = 0;
        $score++ for grep { $tokens{$_} } split /_/, lc($candidate);
        push @scored, [ $score, $candidate ] if $score;
    }

    return () unless @scored;

    @scored = sort { $b->[0] <=> $a->[0] || $a->[1] cmp $b->[1] } @scored;
    splice(@scored, 6) if @scored > 6;

    return map { $_->[1] } @scored;
}

=head2 _get_examples_for_error

Provide examples of correct usage for the tool.

=cut

sub _get_examples_for_error {
    my ($self, $category, $tool_name) = @_;
    # A name that is not callable has no schema to illustrate, and examples
    # that show a different tool's shape would make the error longer without
    # making the next call more likely to succeed.
    return '' if $category eq 'unknown_tool';

    # Only tools published as a single callable are keyed here. Tools that
    # publish per-operation definitions are called by the operation name
    # itself, and their own descriptions already carry the parameter shape.
    my %examples = (
        interact => sub {
            return join("\n",
                '--- CORRECT USAGE EXAMPLES ---',
                'Requesting user input:',
                '  {"operation": "request_input", "message": "Which approach should I use?", "context": "Optional context here"}',
                '',
                'The message parameter is REQUIRED and must clearly ask the user for what you need.',
            );
        },

        terminal_operations => sub {
            return join("\n",
                '--- CORRECT USAGE EXAMPLES ---',
                'Execute a command:',
                '  {"operation": "exec", "command": "ls -la"}',
                '',
                'Validate command safety:',
                '  {"operation": "validate", "command": "npm install"}',
            );
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
