package CLIO::Tools::Registry;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
use Carp qw(croak confess);
use CLIO::Core::Logger qw(log_debug log_warning);

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
        log_debug('Registry', "Tool '$name' already registered, replacing");
    }
    
    $self->{tools}{$name} = $tool;
    
    # Add to ordered list (if not already present)
    unless (grep { $_ eq $name } @{$self->{tool_order}}) {
        push @{$self->{tool_order}}, $name;
    }

    $self->{_definitions_cache} = undef;
    $self->{_operation_name_map} = undef;
    $self->{_derived_aliases} = undef;
    
    log_debug('Registry', "Registered tool: $name");
    
    return 1;
}

=head2 _get_operation_aliases

Return the single canonical alias table mapping alias tool-names to their
parent tool + default operation. This is the SINGLE SOURCE OF TRUTH — both
get_tool() and get_alias_info() read from this lazily-initialised, cached
hashref so they can never drift out of sync (the previous design had two
copies that diverged: get_tool was missing ask_user/confirm/question).

Note: this table only maps ALIAS TOOL NAMES to their canonical parent tool.
It does NOT cover operation-level aliases inside a tool (e.g. FileOperations'
'read' -> 'read_file'); those live in the tool's own operation_aliases field
+ dispatch_table and are resolved by Tool.pm.

=cut

sub _get_operation_aliases {
    my ($self) = @_;

    return $self->{_operation_aliases_cache} if $self->{_operation_aliases_cache};

    my %aliases = (
        # file_operations aliases — canonical op names used as tool names
        'file_search'       => { tool => 'file_operations', operation => 'file_search' },
        'list_dir'          => { tool => 'file_operations', operation => 'list_dir' },
        'read_file'         => { tool => 'file_operations', operation => 'read_file' },
        'write_file'        => { tool => 'file_operations', operation => 'write_file' },
        'create_file'       => { tool => 'file_operations', operation => 'write_file' },
        'delete_file'       => { tool => 'file_operations', operation => 'delete_file' },
        'grep_search'       => { tool => 'file_operations', operation => 'grep_search' },
        'semantic_search'   => { tool => 'file_operations', operation => 'semantic_search' },
        'file_exists'       => { tool => 'file_operations', operation => 'file_exists' },
        'get_file_info'     => { tool => 'file_operations', operation => 'get_file_info' },
        'rename_file'       => { tool => 'file_operations', operation => 'rename_file' },
        # append_file routes to write_file with append=1 injected into call args.
        'append_file'       => { tool => 'file_operations', operation => 'write_file', append => 1 },
        'replace_string'    => { tool => 'file_operations', operation => 'replace_string' },
        'multi_replace_string' => { tool => 'file_operations', operation => 'multi_replace_string' },
        'insert_at_line'    => { tool => 'file_operations', operation => 'insert_at_line' },
        'create_directory'  => { tool => 'file_operations', operation => 'create_directory' },
        'get_errors'        => { tool => 'file_operations', operation => 'get_errors' },
        'read_tool_result'  => { tool => 'file_operations', operation => 'read_tool_result' },

        # version_control aliases
        'git'               => { tool => 'version_control', operation => 'status' },
        'status'            => { tool => 'version_control', operation => 'status' },
        'log'               => { tool => 'version_control', operation => 'log' },
        'diff'              => { tool => 'version_control', operation => 'diff' },
        'commit'            => { tool => 'version_control', operation => 'commit' },
        'push'              => { tool => 'version_control', operation => 'push' },
        'pull'              => { tool => 'version_control', operation => 'pull' },
        'branch'            => { tool => 'version_control', operation => 'branch' },
        'stash'             => { tool => 'version_control', operation => 'stash' },

        # terminal_operations aliases — natural-language verbs for "run a shell command"
        'shell'             => { tool => 'terminal_operations', operation => 'exec' },
        'exec'              => { tool => 'terminal_operations', operation => 'exec' },
        'run'               => { tool => 'terminal_operations', operation => 'exec' },
        'bash'              => { tool => 'terminal_operations', operation => 'exec' },
        'cmd'               => { tool => 'terminal_operations', operation => 'exec' },

        # memory_operations aliases
        'store'             => { tool => 'memory_operations', operation => 'store' },
        'retrieve'          => { tool => 'memory_operations', operation => 'retrieve' },
        'search'            => { tool => 'memory_operations', operation => 'search' },
        'recall_sessions'   => { tool => 'memory_operations', operation => 'recall_sessions' },
        'list'              => { tool => 'memory_operations', operation => 'list' },
        'delete'            => { tool => 'memory_operations', operation => 'delete' },
        'get'               => { tool => 'memory_operations', operation => 'retrieve' },
        'save'              => { tool => 'memory_operations', operation => 'store' },
        'forget'            => { tool => 'memory_operations', operation => 'delete' },

        # web_operations aliases
        'search_web'        => { tool => 'web_operations', operation => 'search_web' },
        'fetch_url'         => { tool => 'web_operations', operation => 'fetch_url' },
        'curl'              => { tool => 'web_operations', operation => 'fetch_url' },
        'wget'              => { tool => 'web_operations', operation => 'fetch_url' },
        'http'              => { tool => 'web_operations', operation => 'fetch_url' },
        'google'            => { tool => 'web_operations', operation => 'search_web' },

        # todo_operations aliases
        'todo'              => { tool => 'todo_operations', operation => 'write' },
        'todos'             => { tool => 'todo_operations', operation => 'read' },

        # code_intelligence aliases
        'list_usages'       => { tool => 'code_intelligence', operation => 'list_usages' },
        'search_history'    => { tool => 'code_intelligence', operation => 'search_history' },

        # interact aliases
        'ask'               => { tool => 'interact', operation => 'request_input' },
        'collab'            => { tool => 'interact', operation => 'request_input' },
        'interact'          => { tool => 'interact', operation => 'request_input' },
        'ask_user'          => { tool => 'interact', operation => 'request_input' },
        'confirm'           => { tool => 'interact', operation => 'request_input' },
        'question'          => { tool => 'interact', operation => 'request_input' },

        # agent_operations aliases
        'spawn'             => { tool => 'agent_operations', operation => 'spawn' },
        'agents'            => { tool => 'agent_operations', operation => 'list' },
        'inbox'             => { tool => 'agent_operations', operation => 'inbox' },

        # apply_patch alias
        'patch'             => { tool => 'apply_patch', operation => 'patch' },
    );

    $self->{_operation_aliases_cache} = \%aliases;
    return \%aliases;
}

=head2 _operation_name_map

Compute the callable name for every operation of every registered tool.

Publishing one definition per operation means the emitted names have to be
globally unique, but operations are only unique within a tool: both
memory_operations and skill_operations have C<list>, and both version_control
and agent_operations have C<status>. A name that does not resolve is worse
than the consolidated schema it replaces - the model calls it and gets
"tool not found".

Resolution order for a contested name:

1. The incumbent static alias entry keeps the bare name.
2. Otherwise the first tool in registration order keeps it.
3. Every other claimant gets C<< <namespace>_<operation> >>.

Returns: Hashref of tool name => { operation => callable name }

=cut

sub _operation_name_map {
    my ($self) = @_;

    return $self->{_operation_name_map} if $self->{_operation_name_map};

    my $static = $self->_get_operation_aliases();
    my (%claimants, %claims);

    for my $tool_name (@{ $self->{tool_order} }) {
        my $tool = $self->{tools}{$tool_name};
        my $contract = eval { $tool->operation_contract() };
        next unless $contract && ref($contract) eq 'HASH' && keys %$contract;

        for my $op (sort keys %$contract) {
            $claims{$tool_name}{$op} = 1;
            push @{ $claimants{$op} }, $tool_name;
        }
    }

    my %map;
    for my $op (sort keys %claimants) {
        my @tools = @{ $claimants{$op} };

        my $incumbent = $static->{$op} ? $static->{$op}{tool} : undef;
        $incumbent = undef if $incumbent && !$claims{$incumbent}{$op};

        if (@tools == 1) {
            my $only = $tools[0];
            $map{$only}{$op} =
                (!$incumbent || $incumbent eq $only)
                    ? $op
                    : $self->_namespaced_operation($only, $op);
            next;
        }

        $incumbent ||= $tools[0];
        for my $tool_name (@tools) {
            $map{$tool_name}{$op} = $tool_name eq $incumbent
                ? $op
                : $self->_namespaced_operation($tool_name, $op);
        }
    }

    $self->{_operation_name_map} = \%map;
    return \%map;
}

=head2 _namespaced_operation (Internal)

Prefix an operation name with its tool namespace for collision resolution.

=cut

=head2 get_operation_callable

Return the emitted callable name for one (tool, operation) pair.

Collisions are resolved once in _operation_name_map - two tools both exposing
a "list" operation leave one bare and prefix the other. Anything that
describes callable names, such as the system prompt, must read from the same
table or it will advertise a name the registry never emits.

Arguments: $tool_name - canonical tool name, $operation - operation name
Returns: The callable name, or undef when the tool publishes no such operation

=cut

sub get_operation_callable {
    my ($self, $tool_name, $operation) = @_;

    return undef unless defined $tool_name && defined $operation;

    my $map = $self->_operation_name_map();
    return $map->{$tool_name}{$operation};
}

sub _namespaced_operation {
    my ($self, $tool_name, $op) = @_;

    my $namespace = $tool_name;
    $namespace =~ s/_operations$//;

    return "${namespace}_${op}";
}

=head2 _derived_aliases (Internal)

Alias entries derived from the live operation contracts.

The static table below is hand-maintained and had already drifted: it lacked
multi_replace_string while that name was being emitted as a callable, so the
model could call a tool the registry could not resolve. Deriving from the
contracts means an emitted name is resolvable by construction.

Returns: Hashref of callable name => { tool, operation }

=cut

sub _derived_aliases {
    my ($self) = @_;

    return $self->{_derived_aliases} if $self->{_derived_aliases};

    my $map = $self->_operation_name_map();
    my %derived;

    for my $tool_name (sort keys %$map) {
        for my $op (sort keys %{ $map->{$tool_name} }) {
            my $callable = $map->{$tool_name}{$op};
            $derived{$callable} ||= { tool => $tool_name, operation => $op };
        }
    }

    $self->{_derived_aliases} = \%derived;
    return \%derived;
}

=head2 get_tool

Get a tool instance by name. Supports aliasing for common mistakes.

When an operation name is used as a tool name (e.g., "file_search" instead of
"file_operations" with operation="file_search"), this method automatically
resolves the alias and returns the correct tool.

Arguments:
- $name: Tool name (may be an alias)

Returns: Tool instance, or undef if not found (after alias resolution)

=cut

sub get_tool {
    my ($self, $name) = @_;

    my $alias = $self->get_alias_info($name);
    if ($alias) {
        log_debug('Registry', "Resolving alias '$name' -> '$alias->{tool}' with operation='$alias->{operation}'");
        $name = $alias->{tool};
    }

    my $tool = $self->{tools}{$name};

    unless ($tool) {
        log_debug('Registry', "Tool not found: $name");
    }

    return $tool;
}

=head2 get_alias_info

Get alias information for a tool name. Returns the alias mapping if the name
is an alias, or undef if it's a real tool name.

This allows callers to detect when an alias was used and extract the default
operation that should be set.

Arguments:
- $name: Tool name

Returns: Hashref with { tool => '...', operation => '...' } or undef

=cut

sub get_alias_info {
    my ($self, $name) = @_;

    my $static = $self->_get_operation_aliases()->{$name};
    return $static if $static;

    return $self->_derived_aliases()->{$name};
}

=head2 has_tool

Check if a tool is registered (by canonical name or alias).

Arguments:
- $name: Tool name (may be an alias)

Returns: Boolean (1 if registered, 0 if not)

=cut

sub has_tool {
    my ($self, $name) = @_;

    return 1 if exists $self->{tools}{$name};

    my $alias = $self->get_alias_info($name);
    if ($alias) {
        return exists $self->{tools}{$alias->{tool}};
    }

    return 0;
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

=head2 get_definition

Return the emitted definition for a tool name or operation callable.

Callers that need to explain a failed call must use the definition the model
was shown. get_tool_definition() on the module returns the consolidated
schema, which lists every parameter of every operation and so describes the
wrong command when the failed call was a per-operation name.

Arguments: $name - canonical tool name or operation callable
Returns: Hashref of { name, description, parameters }, or undef

=cut

sub get_definition {
    my ($self, $name) = @_;

    return undef unless defined $name && length $name;

    for my $definition (@{ $self->get_tool_definitions() }) {
        return $definition->{function}
            if $definition->{function}{name} eq $name;
    }

    return undef;
}

sub get_tool_definitions {
    my ($self) = @_;
    
    # Return cached definitions if available (they don't change during a session)
    return $self->{_definitions_cache} if $self->{_definitions_cache};
    
    my @definitions;

    my $name_map = $self->_operation_name_map();
    my %per_operation;

    for my $name (@{$self->{tool_order}}) {
        my $tool = $self->{tools}{$name};
        next unless $tool->can('get_operation_tool_definitions');

        my $operations = $tool->get_operation_tool_definitions();
        next unless $operations && ref($operations) eq 'HASH';

        $per_operation{$name} = $operations;
    }

    # The consolidated definition can only declare `required => ["operation"]`.
    # When a tool publishes per-operation definitions, that flat schema is a
    # second, contradictory description of the same commands - and the one a
    # model is likelier to reach for, because it is cheaper to satisfy. Ship
    # the truthful surface only.
    for my $name (@{$self->{tool_order}}) {
        next if $per_operation{$name};

        my $tool_def = $self->{tools}{$name}->get_tool_definition();

        push @definitions, {
            type => 'function',
            function => {
                name => $tool_def->{name},
                description => $tool_def->{description},
                parameters => $tool_def->{parameters},
            },
        };
    }

    for my $name (sort keys %per_operation) {
        my $operations = $per_operation{$name};

        for my $op (sort keys %$operations) {
            my $spec = $operations->{$op};
            my $callable = $name_map->{$name}{$op} || $op;

            my %parameters = (
                type       => 'object',
                properties => ($spec->{properties} || {}),
                required   => ($spec->{required} || []),
            );
            $parameters{anyOf} = $spec->{anyOf} if $spec->{anyOf};

            push @definitions, {
                type => 'function',
                function => {
                    name => $callable,
                    description => $spec->{description},
                    parameters => \%parameters,
                },
            };
        }
    }

    # An emitted name that does not resolve is a dead end for the caller.
    # Fail loudly at build time instead of at dispatch time.
    for my $definition (@definitions) {
        my $callable = $definition->{function}{name};
        next if exists $self->{tools}{$callable};
        next if $self->get_alias_info($callable);

        log_warning('Registry', "Tool definition '$callable' does not resolve to any tool");
    }

    log_debug('Registry', "Generated " . scalar(@definitions) . " tool definitions");
    
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

=head2 unregister_tool

Remove a tool from the registry.

Arguments:
- $name: Tool name

Returns: 1 if removed, 0 if not found

=cut

sub unregister_tool {
    my ($self, $name) = @_;
    
    unless (exists $self->{tools}{$name}) {
        log_debug('Registry', "Cannot unregister unknown tool: $name");
        return 0;
    }
    
    delete $self->{tools}{$name};
    
    # Remove from order list
    $self->{tool_order} = [grep { $_ ne $name } @{$self->{tool_order}}];
    
    log_debug('Registry', "Unregistered tool: $name");
    
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
    
    log_debug('Registry', "Cleared $count tools");
    
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
