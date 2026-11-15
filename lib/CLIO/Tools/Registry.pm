package CLIO::Tools::Registry;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;
use feature 'state';
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
use Carp qw(croak confess);
use CLIO::Core::Logger qw(log_debug log_warning);

# Operation names that are too generic to publish as a bare top-level tool
# name. "read", "write", and "delete" mean different things to different
# tools, and a model that means "delete the file" must not silently reach
# "delete the memory key". Every operation in this set is namespaced:
# todo_read, memory_delete, and so on.
my %GENERIC_OPERATIONS = map { $_ => 1 } qw(
    read write add update delete list search store retrieve get save forget
    create load unload history kill killall send broadcast report wait
    acknowledge inbox spawn
);

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

=head2 standard_tool_specs

The tool set a normal session registers, in registration order.

Registration order decides which caller keeps a contested bare name (see
_operation_name_map), so this list is the single source of truth for the
emitted surface. WorkflowOrchestrator registers from it, and
classify_callable() replays it when it needs the same names without a live
session.

Returns: Arrayref of hashrefs with C<name> and C<module>.

=cut

sub standard_tool_specs {
    return [
        { name => 'file_operations',     module => 'CLIO::Tools::FileOperations' },
        { name => 'version_control',     module => 'CLIO::Tools::VersionControl' },
        { name => 'terminal_operations', module => 'CLIO::Tools::TerminalOperations' },
        { name => 'memory_operations',   module => 'CLIO::Tools::MemoryOperations' },
        { name => 'web_operations',      module => 'CLIO::Tools::WebOperations' },
        { name => 'todo_operations',     module => 'CLIO::Tools::TodoList' },
        { name => 'code_intelligence',   module => 'CLIO::Tools::CodeIntelligence' },
        { name => 'interact',            module => 'CLIO::Tools::Interact' },
        { name => 'apply_patch',         module => 'CLIO::Tools::ApplyPatch' },
    ];
}

=head2 conditional_tool_specs

Tools that a session registers only when their configuration switch is on.

Returns: Arrayref of hashrefs with C<name>, C<module>, C<config_key>, and
C<subagent_blocked>.

=cut

sub conditional_tool_specs {
    return [
        {
            name             => 'remote_execution',
            module           => 'CLIO::Tools::RemoteExecution',
            config_key       => 'enable_remote',
            subagent_blocked => 1,
        },
        {
            name             => 'agent_operations',
            module           => 'CLIO::Tools::SubAgentOperations',
            config_key       => 'enable_subagents',
            subagent_blocked => 1,
        },
        {
            name             => 'skill_operations',
            module           => 'CLIO::Tools::SkillOperations',
            config_key       => 'auto_discover_skills',
            subagent_blocked => 0,
        },
    ];
}

=head2 _spec_registry (Internal)

Build the registry the surface helpers classify against.

The helpers below answer questions about names without a live session, so
they need a registry built from the same specs a session registers. It is
constructed once per process and cached.

Returns: A CLIO::Tools::Registry holding the standard and conditional tools

=cut

sub _spec_registry {
    my ($class) = @_;

    state $registry;
    return $registry if $registry;

    my $built = $class->new();

    for my $spec (@{ $class->standard_tool_specs() },
                  @{ $class->conditional_tool_specs() }) {
        (my $file = "$spec->{module}.pm") =~ s{::}{/}g;
        my $loaded = eval { require $file; 1 };
        next unless $loaded;

        my $tool = eval { $spec->{module}->new() };
        next unless $tool;

        $built->register_tool($tool);
    }

    $registry = $built;
    return $registry;
}

=head2 callable_map

Map every emitted callable name to the tool and operation behind it.

Callers outside the dispatcher - loop detection, guidance text, replay
summaries - see a tool call after the surface has already been flattened to
one callable per operation. They need to know which tool owns a name such as
C<write_file> without holding a live registry. Building the map from the
standard specs keeps those answers identical to what dispatch does, so a
classifier cannot drift from the surface it classifies.

Returns: Hashref of callable name => { tool => ..., operation => ... }. A
single-callable tool maps to itself with C<operation> set to undef.

=cut

sub callable_map {
    my ($class) = @_;

    state $map;
    return $map if $map;

    my $registry = $class->_spec_registry();

    my %map;
    my $name_map = $registry->_operation_name_map();

    for my $tool_name (@{ $registry->{tool_order} }) {
        my $tool = $registry->{tools}{$tool_name};
        my $contract = eval { $tool->operation_contract() };

        unless ($contract && ref($contract) eq 'HASH' && keys %$contract) {
            $map{$tool_name} = { tool => $tool_name, operation => undef };
            next;
        }

        for my $op (keys %$contract) {
            my $callable = $name_map->{$tool_name}{$op} // $op;
            $map{$callable} = { tool => $tool_name, operation => $op };
        }
    }

    $map = \%map;
    return $map;
}

=head2 _grouping_map (Internal)

Map each grouping tool and operation to the callable name that dispatch uses.

Returns: Hashref of tool name => { operation => callable name }

=cut

sub _grouping_map {
    my ($class) = @_;

    state $map;
    return $map if $map;

    my $registry = $class->_spec_registry();
    my $name_map = $registry->_operation_name_map();

    my %map;
    for my $tool_name (@{ $registry->{tool_order} }) {
        my $tool = $registry->{tools}{$tool_name};
        my $contract = eval { $tool->operation_contract() };
        next unless $contract && ref($contract) eq 'HASH' && keys %$contract;

        $map{$tool_name} = {
            map { $_ => ($name_map->{$tool_name}{$_} // $_) } keys %$contract
        };
    }

    $map = \%map;
    return $map;
}

=head2 is_grouping_name

True when C<$name> is a grouping tool that publishes per-operation
callables instead of being callable itself (C<file_operations> yes,
C<replace_string> no, C<apply_patch> no).

Arguments:
- $name: name to test

Returns: 1 or 0

=cut

sub is_grouping_name {
    my ($class, $name) = @_;
    return 0 unless defined $name && length $name;
    my $grouping = $class->_grouping_map();
    return $grouping->{$name} ? 1 : 0;
}

=head2 classify_callable

Resolve a callable name to the tool and operation that own it.

Arguments:
- $name: callable name as the model called it
- $operation (optional): operation field carried by the same call

Returns: Hashref with C<tool> and C<operation>, or undef for an unknown name

The second form exists for reading stored history, not for dispatch. Calls
recorded before a tool published per-operation callables carry the grouping
name plus an operation ("file_operations" + "read_file"), and so do calls that
arrive in the textual "[tool operation]" format. Classification gets those
right; dispatch still refuses the name because the model was never given it.

=cut

sub classify_callable {
    my ($class, $name, $operation) = @_;

    return undef unless defined $name && length $name;

    my $map = $class->callable_map();
    return $map->{$name} if $map->{$name};

    return undef unless defined $operation && length $operation;

    # A grouping name is not a callable, but it does name the tool that owns
    # the operation, which is what callers of this function need.
    my $grouping = $class->_grouping_map();
    my $callable = $grouping->{$name} ? $grouping->{$name}{$operation} : undef;
    return undef unless $callable;

    return $map->{$callable} || { tool => $name, operation => $operation };
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
    $self->{_emitted_names_cache} = undef;
    
    log_debug('Registry', "Registered tool: $name");
    
    return 1;
}

=head2 _operation_name_map

Compute the callable name for every operation of every registered tool.

Publishing one definition per operation means the emitted names have to be
globally unique, but operations are only unique within a tool: both
memory_operations and skill_operations have C<list>, and both version_control
and agent_operations have C<status>. A name that does not resolve is worse
than the consolidated schema it replaces - the model calls it and gets
"tool not found".

Resolution order:

1. A generic name (C<read>, C<write>, C<delete>, C<list>, C<search>, ...)
   is always namespaced, even when only one tool claims it. The bare word
   means different things to different tools.
2. A non-generic name with one claimant keeps the bare name.
3. For a contested non-generic name, the first tool in registration order
   keeps the bare name and every other claimant gets
   C<< <namespace>_<operation> >>.

Returns: Hashref of tool name => { operation => callable name }

=cut

sub _operation_name_map {
    my ($self) = @_;

    return $self->{_operation_name_map} if $self->{_operation_name_map};

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
        my $generic = $GENERIC_OPERATIONS{$op};

        # A generic name is never published bare, even when only one tool
        # claims it. A non-generic name with a single claimant keeps the
        # bare name for readability (read_file, commit, diff).
        if (@tools == 1 && !$generic) {
            $map{ $tools[0] }{$op} = $op;
            next;
        }

        my $incumbent = $tools[0];
        for my $tool_name (@tools) {
            $map{$tool_name}{$op} =
                (!$generic && $tool_name eq $incumbent)
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

    # Only names the registry actually emits are resolvable. The old static
    # table advertised names that were never sent to the model (read, write,
    # delete, patch, shell, ...), so a model could call a tool that did not
    # exist and still get a result from a different tool. An emitted name is
    # resolvable by construction; anything else is not an alias.
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

=head2 get_emitted_names

Return the set of callable names the registry actually publishes to the
model, as a hashref of name => 1.

Dispatch uses this to reject names that were never on the wire. A canonical
tool name such as C<file_operations> is a real registered tool, but it is not
emitted when the tool publishes per-operation definitions - accepting it would
let a model call a name it was never given and reach a guessed operation.

Returns: Hashref of emitted callable name => 1

=cut

sub get_emitted_names {
    my ($self) = @_;

    return $self->{_emitted_names_cache} if $self->{_emitted_names_cache};

    my %names;
    for my $definition (@{ $self->get_tool_definitions() }) {
        my $name = $definition->{function}{name};
        $names{$name} = 1 if defined $name && length $name;
    }

    $self->{_emitted_names_cache} = \%names;
    return \%names;
}

=head2 is_emitted_name

Check whether a name is advertised to the model.

Arguments: $name - callable name from a tool call
Returns: Boolean

=cut

sub is_emitted_name {
    my ($self, $name) = @_;

    return 0 unless defined $name && length $name;
    return $self->get_emitted_names()->{$name} ? 1 : 0;
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
