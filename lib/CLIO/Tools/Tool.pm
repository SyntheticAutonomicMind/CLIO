package CLIO::Tools::Tool;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;
use Carp qw(croak confess);
use CLIO::Core::Logger qw(log_debug);

=head1 NAME

CLIO::Tools::Tool - Base class for operation-based tools

=head1 DESCRIPTION

Base class for tools that combine multiple related operations into a single
tool with operation-based routing. Pattern inspired by SAM's MCPFramework
ConsolidatedMCP protocol.

Tools reduce system prompt size by grouping related operations under one
tool name (e.g., file_operations with 17 operations instead of 17 separate tools).

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
    
    sub dispatch_table {
        return {
            read_file  => 'read_file',
            write_file => 'write_file',
        };
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
        # Short aliases for operations. These are accepted as operation
        # values (via validate_operation + dispatch_table) but are NOT
        # advertised in the operation enum sent to the LLM. This prevents
        # the LLM from seeing e.g. "read" in the enum and calling it as a
        # tool name instead of "file_operations" with operation="read_file".
        operation_aliases => $opts{operation_aliases} || [],
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
    
    log_debug("Tool:$self->{name}", "Execute called");
    
    # Extract operation parameter. Use the canonical phrasing so
    # ToolErrorGuidance categorizes this as 'missing_operation' and emits
    # the targeted "you forgot the operation field" guidance instead of
    # falling through to the generic "missing required parameter" branch.
    my $operation = $params->{operation};
    unless ($operation) {
        my $available = join(', ', @{$self->{supported_operations}});
        log_debug("Tool:$self->{name}", "Missing 'operation' parameter. Available: $available");
        return $self->operation_error("Missing 'operation' parameter");
    }

    # Validate operation
    unless ($self->validate_operation($operation)) {
        my $available = join(', ', @{$self->{supported_operations}});
        my $suggestion = $self->_suggest_operation($operation);
        my $hint = $suggestion ? " Did you mean: $suggestion?" : "";
        log_debug("Tool:$self->{name}", "Unknown operation: '$operation'. Available: $available");
        return $self->operation_error("Unknown operation: $operation.$hint Valid operations: $available");
    }

    # Pre-validate required parameters BEFORE dispatching. Uses the
    # get_tool_definition() schema's `required` array (when defined) to
    # emit a canonical "Missing required parameter: <name>" error for any
    # required field that wasn't supplied. Without this hook, the
    # missing-required regex in ToolErrorGuidance can miss some forms
    # (e.g. when the tool's handler does its own ad-hoc check and the
    # error string has an unusual shape). The categorizer now matches
    # those forms, but pre-validating here means we get a consistent
    # error shape regardless of which handler short-circuits.
    my $guard = $self->_pre_validate_required_params($params);
    return $guard if $guard;
    
    # Route to operation handler
    log_debug("Tool:$self->{name}", "Routing to operation: $operation");
    
    # DEFENSE-IN-DEPTH: wrap the dispatch in eval{} so any unexpected
    # die/croak from before_route() or the dispatched method converts
    # into a proper error_result() instead of propagating up and taking
    # down the entire conversation (which previously surfaced as the
    # generic "I'm experiencing technical difficulties. Please try again."
    # from SimpleAIAgent's outermost eval).
    #
    # Common real-world triggers that this catches:
    #   - VersionControl._in_repo croaking on chdir failure for a
    #     non-existent repository_path (e.g. hallucinated macOS path)
    #   - FileOperations.open/unlink croaking on permission/path errors
    #     in code paths that forgot to wrap
    #   - Any third-party tool that uses bare die/croak instead of
    #     error_result()
    #
    # The cleaned error message preserves the underlying cause (after
    # _clean_eval_error strips Carp caller-location suffixes), and the
    # returned error_result() flows through the existing ToolErrorGuidance
    # pipeline so the AI sees a categorized, schema-aware recovery message.
    my $result;
    eval {
        $result = $self->route_operation($operation, $params, $context);
    };
    if ($@) {
        my $clean_err = $self->_clean_eval_error($@);
        log_debug("Tool:$self->{name}", "Caught uncaught exception during dispatch: $clean_err");
        return $self->error_result(
            defined $clean_err && length $clean_err
                ? $clean_err
                : "Tool execution failed unexpectedly (no error message)"
        );
    }
    return $result;
}

=head2 dispatch_table

Return a hashref mapping operation names to method names or coderefs.
Subclasses override this to define their dispatch table.

Operations map to methods called with ($self, $params, $context).
Aliases are supported by mapping multiple keys to the same method.

Arguments:
    None

Returns: Hashref of { operation_name => 'method_name' } or { operation_name => \&coderef }

=cut

sub dispatch_table {
    my ($self) = @_;
    return {};
}

=head2 before_route

Hook called before dispatching an operation. Override for pre-dispatch
checks (sandbox validation, repo verification, etc).

Arguments:
- $operation: Operation name (already validated)
- $params: Hashref of parameters
- $context: Execution context

Returns: undef to proceed, or a result hashref to short-circuit dispatch

=cut

sub before_route {
    my ($self, $operation, $params, $context) = @_;
    return undef;
}

=head2 validate_operation

Check if an operation is supported by this tool.

Arguments:
- $operation: Operation name to validate

Returns: Boolean (1 if supported, 0 if not)

=cut

sub _suggest_operation {
    my ($self, $bad_op) = @_;
    return undef unless $bad_op && $self->{supported_operations};
    
    my $lc = lc($bad_op);
    my @ops = @{$self->{supported_operations}};
    
    # Exact substring match (e.g., "write" matches "write_file")
    my @substr_matches = grep { index(lc($_), $lc) >= 0 || index($lc, lc($_)) >= 0 } @ops;
    return $substr_matches[0] if @substr_matches == 1;
    
    # Edit distance 1-2 (simple: check shared prefix >= 60% of length)
    my $min_prefix = int(length($lc) * 0.6) || 1;
    my @prefix_matches;
    for my $op (@ops) {
        my $lo = lc($op);
        my $shared = 0;
        for my $i (0 .. length($lc) - 1) {
            last if $i >= length($lo) || substr($lc, $i, 1) ne substr($lo, $i, 1);
            $shared++;
        }
        push @prefix_matches, $op if $shared >= $min_prefix;
    }
    return $prefix_matches[0] if @prefix_matches == 1;
    return join(' or ', @prefix_matches) if @prefix_matches && @prefix_matches <= 3;
    
    return undef;
}

sub validate_operation {
    my ($self, $operation) = @_;
    
    # Build hash lookup on first call (avoids linear grep on every tool dispatch).
    # Includes both canonical operations (sent in the schema enum to the LLM) and
    # operation_aliases (silently accepted as operation values but not advertised).
    unless ($self->{_supported_ops_hash}) {
        my @all = (@{$self->{supported_operations}}, @{$self->{operation_aliases} || []});
        $self->{_supported_ops_hash} = { map { $_ => 1 } @all };
    }
    return $self->{_supported_ops_hash}{$operation} ? 1 : 0;
}

=head2 route_operation

Route to specific operation handler via dispatch table. Subclasses
define dispatch_table() instead of overriding this method directly.

Arguments:
- $operation: Operation name (already validated)
- $params: Hashref of parameters
- $context: Execution context

Returns: Hashref with success, output/error, metadata

=cut

sub route_operation {
    my ($self, $operation, $params, $context) = @_;

    # Pre-dispatch hook
    my $guard = $self->before_route($operation, $params, $context);
    return $guard if $guard;

    # Look up in dispatch table. Each entry maps operation name (as the
    # LLM would supply it) to a method name. Some entries also carry a
    # hashref with default parameters to inject; the schema is
    # 'operation_alias_name' => 'method_name' OR 'operation_alias_name'
    # => { method => 'method_name', defaults => { key => value, ... } }.
    # The defaults form lets legacy aliases (append_file, create_file)
    # route to the merged write_file handler with the right flags pre-set.
    my $table = $self->dispatch_table();
    my $handler = $table->{$operation};

    if ($handler) {
        my $method_name;
        my $defaults = {};
        if (ref($handler) eq 'HASH') {
            # New-style: { method => '...', defaults => {...} }
            $method_name = $handler->{method};
            $defaults = $handler->{defaults} || {};
        } else {
            # Legacy: bare method-name string
            $method_name = $handler;
        }

        # Inject defaults into params without clobbering caller-supplied values
        for my $k (keys %$defaults) {
            $params->{$k} = $defaults->{$k} unless exists $params->{$k};
        }

        my $method = $self->can($method_name);
        if ($method) {
            return $method->($self, $params, $context);
        }
        croak "Dispatch table maps '$operation' to '$method_name' but method does not exist";
    }

    return $self->error_result("Operation not implemented: $operation");
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

    # Use the canonical "Missing required parameter: <name>" form whenever
    # the message looks like a parameter-missing case. This guarantees
    # ToolErrorGuidance categorizes it correctly regardless of which
    # tool emitted it. For unknown-operation errors we keep the bare
    # text so the categorizer's invalid_operation branch fires.
    my $normalized = $message;
    if ($message =~ /missing\s+['"`]?(\w+)['"`]?\s+parameter/i && $message !~ /operation/) {
        $normalized = "Missing required parameter: $1";
    }

    my $error_text = <<EOF;
ERROR: $normalized

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

    return $self->error_result($error_text);
}

=head2 _pre_validate_required_params

Validate that all parameters listed in the tool's JSON schema as `required`
are present before dispatching to the handler. Returns an error_result() with
a canonical "Missing required parameter: <name>" message for the first missing
field, or undef if validation passes.

Design:
- The base class only marks `operation` as required. Each tool that needs
  additional universally-required fields (e.g. TerminalOperations needs
  `command`, Interact needs `message`) sets them in its own
  get_tool_definition() override. The pre-validator trusts the schema's
  `required` array as the source of truth.
- Tools with per-operation requirements (e.g. FileOperations where
  `read_file` needs `path` but `grep_search` does not) set `required`
  to just `operation` in their schema, and enforce operation-specific
  fields in the handler. Handlers use the same "Missing required
  parameter: <name>" format so ToolErrorGuidance categorizes them
  consistently.

Arguments:
- $params: Hashref of parameters supplied by the LLM

Returns:
- undef when all required parameters are present (or when no schema
  is available)
- error_result() hashref when a required parameter is missing

=cut

sub _pre_validate_required_params {
    my ($self, $params) = @_;

    my $def = eval { $self->get_tool_definition(); };
    return undef unless $def && ref($def) eq 'HASH';

    my $required = $def->{parameters}{required} || [];
    return undef unless @$required;

    $params ||= {};

    for my $field (@$required) {
        my $val = $params->{$field};
        next if defined $val && (!ref($val) || ref($val) eq 'ARRAY' || ref($val) eq 'HASH');
        next if ref($val) eq 'ARRAY' && @$val;  # non-empty arrayref
        # Missing or empty - return canonical error.
        return $self->error_result("Missing required parameter: $field");
    }
    return undef;
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

=head2 add_dual_json_parameters

Helper method to generate both string and JSON object parameter variants.

This reduces escaping complexity for agents by allowing them to pass complex
data as JSON objects instead of escaped strings.

Usage in subclass get_additional_parameters():

    return {
        %{$self->add_dual_json_parameters('content', {
            description => 'File content to write',
            string_format => 'any',  # text, json, yaml, code, etc.
        })},
        # ... other parameters ...
    };

This generates BOTH:
    - "content": string (escaped format - backward compatible)
    - "content_json": object (new format - no escaping needed)

Arguments:
- $param_name: Base parameter name (e.g., 'content', 'data', 'config')
- $opts: Options hashref:
    * description: Parameter description (required)
    * string_format: Expected format when passed as string (default: 'any')
    * example: Example value for documentation (optional)

Returns: Hashref with both string and _json parameter definitions

=cut

sub add_dual_json_parameters {
    my ($self, $param_name, $opts) = @_;
    
    croak "add_dual_json_parameters requires param_name" unless $param_name;
    croak "add_dual_json_parameters requires description" unless $opts->{description};
    
    my $description = $opts->{description};
    my $format = $opts->{string_format} || 'any';
    my $example = $opts->{example} || '';
    
    my $example_text = $example ? "\n\nExample: $example" : '';
    
    return {
        # String version (backward compatible)
        $param_name => {
            type => "string",
            description => "$description (as string - escape JSON quotes if needed)$example_text",
        },
        
        # JSON object version (new - no escaping needed)
        "${param_name}_json" => {
            type => "object",
            description => "$description (as JSON object - RECOMMENDED: no escaping needed, pass structured data directly)",
        },
    };
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

=head2 _clean_eval_error

Strip Carp/croak caller-location suffix from a $@ string so internal
file paths don't leak into user-visible error messages. Also used
whenever an eval/croak error is forwarded to $self->error_result().

Without stripping, the AI sees messages like:
    Git status failed: Not a git repository
        at /home/user/.local/clio/lib/CLIO/Core/ToolExecutor.pm line 358.
which (a) leaks the executor file path and (b) prevents
ToolErrorGuidance from cleanly categorizing the underlying failure.

Arguments:
    $err: Raw $@ string (may be undef or empty)

Returns:
    Cleaned error string with trailing " at <path> line <num>." removed,
    or empty string if input was undef/empty.

=cut

sub _clean_eval_error {
    my ($self, $err) = @_;
    return '' unless defined $err && length $err;
    # Strip "at <path> line <num>." (Carp/croak caller-location suffix).
    # Works for any path: .pm, .pl, bare paths, or relative paths.
    $err =~ s/\s+at\s+\S+\s+line\s+\d+\.?\s*$//;
    # Trailing whitespace
    $err =~ s/\s+\z//;
    return $err;
}

=head2 check_interrupt

Check whether the user has requested an interrupt (ESC).

Long-running operations should poll this method periodically so the user
does not have to wait for the entire operation to finish before their
ESC is honoured. Note that only ESC triggers an interrupt - Ctrl+C is
intentionally left to the global SIGINT handler so it terminates CLIO
cleanly (classic Unix behaviour). The implementation is intentionally
cheap: it first checks the in-process flag set by the ALRM handler,
then performs a non-blocking read of STDIN. The escape-sequence
disambiguation (50ms wait) happens only when we actually see a
non-empty byte, not on the common no-key-pressed path, so the overhead
is one boolean check plus (at most) one non-blocking syscall per call.

Usage in a tool loop:

    while (my $chunk = read_more()) {
        last if $self->check_interrupt($context);
        process($chunk);
    }

Arguments:
- $context: Execution context hashref (optional but recommended). The
  session is read from $context->{session} when available.

Returns: 1 if interrupt was detected, 0 if not.

=cut

sub check_interrupt {
    my ($self, $context) = @_;

    # Lazy require so tools that don't need interrupt detection don't
    # pay the import cost.
    require CLIO::Core::Interrupt;
    my $session = $context && $context->{session};
    return CLIO::Core::Interrupt::check(session => $session);
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
- file_operations (17 operations)
- memory_operations (3 operations)
- terminal_operations (11+ operations)
- todo_operations (4 operations)

=head1 SEE ALSO

- ai-assisted/SAM_ANALYSIS.md - Detailed analysis of SAM patterns
- IMPLEMENTATION_PLAN_SAM_PATTERNS.md - Implementation roadmap

=cut

1;
