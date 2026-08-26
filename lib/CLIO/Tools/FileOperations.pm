package CLIO::Tools::FileOperations;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
use Carp qw(croak confess);
use CLIO::Core::Logger qw(log_debug log_info log_warning);
use CLIO::Security::CommandAnalyzer qw(analyze_command);
use parent 'CLIO::Tools::Tool';
use File::Spec;
use File::Basename;
use CLIO::Util::PathResolver qw(expand_tilde strip_path_quotes);
use File::Path qw(make_path);
use Cwd qw(abs_path getcwd);
use Encode qw(decode);
use File::Glob qw(:bsd_glob);
use CLIO::Core::WorkflowOrchestrator;
use JSON::PP ();  # For JSON::PP::false default in get_additional_parameters()

=head1 NAME

CLIO::Tools::FileOperations - Consolidated file operations tool

=head1 DESCRIPTION

Provides 17 file operations grouped into READ, SEARCH, and WRITE categories.
Replaces the legacy CLIO::Protocols::FileOp with a cleaner operation-based API.

Operations:
  READ (5):    read_file, list_dir, file_exists, get_file_info, get_errors
  SEARCH (4):  file_search, grep_search, semantic_search, read_tool_result
  WRITE (8):   create_file, write_file, append_file, replace_string,
               insert_at_line, delete_file, rename_file, create_directory

=head1 SYNOPSIS

    use CLIO::Tools::FileOperations;
    
    my $tool = CLIO::Tools::FileOperations->new(
        debug => 1,
        session_dir => '/path/to/session'
    );
    
    # Read file
    my $result = $tool->execute(
        { operation => 'read_file', path => 'README.md' },
        { session => { id => 'test' } }
    );
    
    # Search files
    $result = $tool->execute(
        { operation => 'grep_search', query => 'TODO', pattern => '**/*.pm' },
        { session => { id => 'test' } }
    );

=cut

sub new {
    my ($class, %opts) = @_;
    
    my $self = $class->SUPER::new(
        name => 'file_operations',
        description => q{File operations: read, write, search, and manage workspace files.

AUTHORIZATION:
-  Inside session directory: AUTO-APPROVED
-  Outside session directory: Requires authorization (path security policy)

━━━━━━━━━━━━━━━━━━━━━━━ READ (5 operations) ━━━━━━━━━━━━━━━━━━━━━━━
-  read_file - Read file content with optional line range
  Parameters: path (required), start_line (optional), end_line (optional)
  
-  list_dir - List directory contents
  Parameters: path (required), recursive (optional, default: false)
  
-  file_exists - Check if file or directory exists
  Parameters: path (required)
  
-  get_file_info - Get file metadata (size, type, modified time)
  Parameters: path (required)
  
-  get_errors - Get compilation/lint errors for file (Perl-specific)
  Parameters: path (required)

━━━━━━━━━━━━━━━━━━━━━ SEARCH (4 operations) ━━━━━━━━━━━━━━━━━━━━━
-  file_search - Find files matching pattern
  Parameters: pattern (required), directory (optional, default: .)
  
-  grep_search - Search file contents with regex
  Parameters: query (required), pattern (optional), directory (optional, default: .), is_regex (optional)
  Note: `directory` scopes the search to a DIRECTORY (not a file). If you
  need to search a single file, pass its directory as `directory` and use
  `pattern` to target the filename (e.g. directory='lib', pattern='Foo.pm').
  For full-shell grep on a single file, use terminal_operations instead.
  
-  semantic_search - Hybrid keyword + symbol search across codebase
  Parameters: query (required), scope (optional)
  Note: Extracts keywords from query, searches code files, ranks by relevance.
        Boosts files containing matching function/class definitions.
        Good for finding "where is X implemented?" or "files about Y"

-  read_tool_result - Read persisted large tool results in chunks
  Use when tool response contains [TOOL_RESULT_STORED] marker.
  Check first chunk for complete answer before reading more.
  Parameters: toolCallId (required), offset (optional, default: 0), length (optional, default: dynamic based on model context, max: 32768)

━━━━━━━━━━━━━━━━━━━━━ WRITE (7 operations) ━━━━━━━━━━━━━━━━━━━━━
-  write_file - Write content to a file. Creates the file if it doesn't exist,
  overwrites it if it does. Pass append=true to append instead of overwriting.
  Parameters: path (required), content (required), append (optional, default: false)
  Replaces the older create_file (refused to overwrite) and append_file.
  Both still work as silent aliases for backward compatibility.

-  replace_string - Find and replace text in file
  Parameters: path (required), old_string (required), new_string (required)

-  multi_replace_string - Batch replace operations across multiple files
  Parameters: replacements (required, array of {path, old_string, new_string})
  Returns: Summary of all replacements performed

-  insert_at_line - Insert content at specific line number
  Parameters: path (required), line (required), content (required)

-  delete_file - Delete file or directory
  Parameters: path (required), recursive (optional, for directories)

-  rename_file - Rename or move file
  Parameters: old_path (required), new_path (required)

-  create_directory - Create directory (with parents)
  Parameters: path (required)

ALIASES: Each operation above also accepts common natural-language aliases
(e.g. `list_dir` / `list_directory`, `read` / `read_file`, `delete` /
`delete_file`, `mv` / `rename_file`, `mkdir` / `create_directory`,
`bulk_replace` / `multi_replace_string`, `create` / `create_file`,
`append` / `append_file`). The canonical names above are
preferred for clarity; aliases exist so calling code that uses the more
familiar English form still dispatches correctly.
},
        supported_operations => [qw(
            read_file read
            list_dir list_directory
            file_exists exists
            get_file_info stat_file
            get_errors
            file_search find_files
            grep_search search
            semantic_search
            read_tool_result read_result
            create_file create
            write_file write
            append_file append
            replace_string replace edit
            multi_replace_string bulk_replace
            insert_at_line insert_line insert
            delete_file delete remove
            rename_file rename mv
            create_directory make_directory mkdir
        )],
        %opts,
    );
    
    # Store session directory for authorization checks
    $self->{session_dir} = $opts{session_dir} || '';

    # Initialize PathAuthorizer (lazy load to avoid circular dependencies)
    $self->{path_authorizer} = undef;

    return $self;
}

=head2 get_tool_definition

Return the base schema unchanged. The base class marks only `operation`
as required, which is correct for FileOperations: not all operations
need the same fields (e.g. `read_file` needs `path`, `grep_search`
needs `query` + `directory`, `write_file` needs `path` + `content`).

Per-operation requirements are enforced by individual handlers, which
use the canonical "Missing required parameter: <name>" error format so
ToolErrorGuidance categorizes them consistently.

=cut

sub get_tool_definition {
    my ($self) = @_;
    return $self->SUPER::get_tool_definition();
}

=head2 get_additional_parameters

Define ALL parameters for ALL file operations in the JSON schema.

Following SAM pattern: Define all possible parameters with required:false,
rather than trying to have separate schemas per operation.

This prevents AI from generating malformed JSON like {"offset":,}
when it doesn't know if a parameter is required or not.

=cut

sub get_additional_parameters {
    my ($self) = @_;
    
    return {
        # Common path parameters
        path => {
            type => "string",
            description => "[REQUIRED for most operations] File or directory path. Used by read_file, list_dir, file_exists, get_file_info, write operations, etc. REQUIRED on EVERY call (including multi_replace_string items) - a missing path returns a parameter validation error, not a graceful fallback. For grep_search, `path` is accepted as an alias for `directory` and must be a DIRECTORY (not a file) - to search a single file, pass its directory and use `pattern` to target the filename.",
        },
        paths => {
            type => "array",
            items => { type => "string" },
            description => "[OPTIONAL for get_errors] Multiple file paths as an array. When provided, get_errors iterates each path and aggregates results in the 'per_file' field. Use 'path' (singular) for a single file.",
        },
        
        # Read file parameters
        start_line => {
            type => "integer",
            description => "[OPTIONAL] Starting line number for read_file (1-indexed, inclusive).",
        },
        end_line => {
            type => "integer",
            description => "[OPTIONAL] Ending line number for read_file (inclusive).",
        },
        
        # List directory parameters
        recursive => {
            type => "boolean",
            description => "[OPTIONAL] Whether to list directory contents recursively (list_dir). Default: false.",
        },
        
        # Search parameters
        query => {
            type => "string",
            description => "[REQUIRED for grep_search, semantic_search] Search query or pattern. For semantic_search: use natural language keywords like 'authentication function'. For grep_search: literal text or regex.",
        },
        pattern => {
            type => "string",
            description => "[REQUIRED for file_search, OPTIONAL for grep_search] Glob pattern to filter which files to search (e.g., '**/*.pm', '*.pl').",
        },
        directory => {
            type => "string",
            description => "[OPTIONAL] Base directory for file_search and grep_search. MUST be a directory (not a file). Defaults to current directory. For grep_search, you may also pass `path` as an alias for this parameter.",
        },
        is_regex => {
            type => "boolean",
            description => "[OPTIONAL] Whether query is a regex pattern for grep_search. Default: false.",
        },
        scope => {
            type => "string",
            description => "[OPTIONAL] Directory to search for semantic_search. Default: current directory.",
        },
        max_results => {
            type => "integer",
            description => "[OPTIONAL] Maximum number of results to return from search.",
        },
        
        # Read tool result parameters (for chunked large results)
        toolCallId => {
            type => "string",
            description => "[REQUIRED for read_tool_result] Tool call ID to retrieve stored result chunks. Look for [TOOL_RESULT_STORED] marker in previous output.",
        },
        offset => {
            type => "integer",
            description => "[OPTIONAL] Byte offset to start reading from read_tool_result. Default: 0.",
        },
        length => {
            type => "integer",
            description => "[OPTIONAL] Number of bytes to read for read_tool_result. Default: dynamic (scales with model context). Max: 32768.",
        },
        
        # Write parameters - DUAL PARAMETER SUPPORT
        %{$self->add_dual_json_parameters('content', {
            description => '[REQUIRED for write_file] File content to write (as string - escape JSON quotes if needed).',
            string_format => 'any',
        })},

        append => {
            type => "boolean",
            description => "[OPTIONAL for write_file] When true, append content to the file instead of overwriting. Default: false. The file is created if it does not exist (matching Unix '>' vs '>>' semantics: write_file=overwrite, write_file with append=true=append).",
            default => JSON::PP::false,
        },
        
        old_string => {
            type => "string",
            description => "[REQUIRED for replace_string] Text to find and replace.",
        },
        new_string => {
            type => "string",
            description => "[REQUIRED for replace_string] Replacement text.",
        },
        replacements => {
            type => "array",
            items => {
                type => "object",
                properties => {
                    path => { type => "string" },
                    old_string => { type => "string" },
                    new_string => { type => "string" },
                },
                required => ["path", "old_string", "new_string"],
            },
            description => "[REQUIRED for multi_replace_string] Batch replacements for multi_replace_string.",
        },
        
        # insert_at_line parameters
        line => {
            type => "integer",
            description => "[REQUIRED for insert_at_line] Line number to insert at (1-indexed).",
        },
        
        # Rename parameters
        old_path => {
            type => "string",
            description => "[REQUIRED for rename_file] Original file path.",
        },
        new_path => {
            type => "string",
            description => "[REQUIRED for rename_file] New file path.",
        },
    };
}

sub dispatch_table {
    return {
        read_file           => 'read_file',
        read                => 'read_file',
        list_dir            => 'list_dir',
        list_directory      => 'list_dir',
        file_exists         => 'file_exists',
        exists              => 'file_exists',
        get_file_info       => 'get_file_info',
        stat_file           => 'get_file_info',
        get_errors          => 'get_errors',
        file_search         => 'file_search',
        find_files          => 'file_search',
        grep_search         => 'grep_search',
        search              => 'grep_search',
        semantic_search     => 'semantic_search',
        read_tool_result    => 'read_tool_result',
        read_result         => 'read_tool_result',
        create_file         => 'write_file',
        create              => 'write_file',
        # 2026-08-26 collapse: create_file and append_file became silent
        # aliases for write_file (which now creates-or-overwrites, with
        # append=true for append semantics). The hashref form injects
        # defaults into $params before dispatch so direct callers
        # (integration tests, internal code) get the legacy semantics
        # without having to set append=true themselves. End-to-end LLM
        # callers go through Registry's alias injection in
        # WorkflowOrchestrator which sets the same defaults earlier in
        # the pipeline.
        write_file          => 'write_file',
        write               => 'write_file',
        append_file         => { method => 'write_file', defaults => { append => 1 } },
        append              => { method => 'write_file', defaults => { append => 1 } },
        replace_string      => 'replace_string',
        replace             => 'replace_string',
        edit                => 'replace_string',
        multi_replace_string => 'multi_replace_string',
        bulk_replace        => 'multi_replace_string',
        insert_at_line      => 'insert_at_line',
        insert_line         => 'insert_at_line',
        insert              => 'insert_at_line',
        delete_file         => 'delete_file',
        delete              => 'delete_file',
        remove              => 'delete_file',
        rename_file         => 'rename_file',
        rename              => 'rename_file',
        mv                  => 'rename_file',
        create_directory    => 'create_directory',
        make_directory      => 'create_directory',
        mkdir               => 'create_directory',
    };
}

#
# AUTHORIZATION HELPERS
#

sub _get_path_authorizer {
    my ($self) = @_;
    
    unless ($self->{path_authorizer}) {
        require CLIO::Security::PathAuthorizer;
        $self->{path_authorizer} = CLIO::Security::PathAuthorizer->new(
            debug => $self->{debug},
        );
    }
    
    return $self->{path_authorizer};
}

=head2 _clean_path($path)

Strip JSON-string-style quote artifacts from an AI-supplied path.

LLMs sometimes emit tool calls like path=`"/home/foo/test.txt"` (with
literal `"` chars) when they meant `/home/foo/test.txt`. CLIO's
directory-creation helpers (`make_path`, `mkdir`) then treat the
leading `"` as a directory name and create a literal `"` directory.

Centralizes the fix in one place so every operation stays consistent.
Returns the stripped path or the original (empty input passes through
for downstream "missing path" handling).

=cut

sub _clean_path {
    my ($self, $path) = @_;
    return $path unless defined $path;
    return strip_path_quotes($path);
}

sub _check_write_authorization {
    my ($self, $path, $operation, $context) = @_;
    
    # Note: session object uses 'session_id' not 'id'
    my $session_id = $context->{session}->{session_id} || $context->{session}->{id} || '';
    my $working_dir = $self->{session_dir} || '';
    
    # If no session directory configured, allow (backwards compatibility)
    return { status => 'allowed', reason => 'No authorization configured' } unless $working_dir;
    
    my $authorizer = $self->_get_path_authorizer();
    
    my $result = $authorizer->checkPathAuthorization(
        path => $path,
        working_directory => $working_dir,
        conversation_id => $session_id,
        operation => "file_operations.$operation",
        is_user_initiated => 0,
    );
    
    return $result;
}

=head2 _acquire_file_lock

Attempt to acquire a file lock via the broker for multi-agent coordination.

Returns: (lock_acquired, error_message)
- lock_acquired: 1 if lock acquired, 0 otherwise
- error_message: undef if ok, error string if lock denied

=cut

sub _acquire_file_lock {
    my ($self, $path, $context) = @_;
    
    return (0, undef) unless $context->{broker_client};
    
    log_info('FileOp', "Requesting file lock via broker: $path");
    
    eval {
        my $lock_result = $context->{broker_client}->request_file_lock([$path], 'write');
        if ($lock_result) {
            log_info('FileOp', "Lock acquired for: $path");
            return (1, undef);
        } else {
            return (0, "File is locked by another agent. Wait for the other agent to finish or coordinate with them.");
        }
    };
    if ($@) {
        log_warning('FileOp', "Failed to acquire lock (broker error): $@");
        log_warning('FileOp', "Continuing without lock");
        return (0, undef);  # Continue without lock on broker errors
    }
}

=head2 _release_file_lock

Release a file lock via the broker.

=cut

sub _release_file_lock {
    my ($self, $path, $context) = @_;
    
    return unless $context->{broker_client};
    
    eval {
        $context->{broker_client}->release_file_lock([$path]);
        log_info('FileOp', "Released lock for: $path");
    };
    if ($@) {
        log_warning('FileOp', "Failed to release lock: $@");
    }
}

=head2 _vault_capture($path, $type, $context, $old_path)

Capture a file in the FileVault before modification for undo support.
Silently no-ops if vault is not available (never blocks file operations).

Arguments:
- $path: Path being modified/created/deleted
- $type: Operation type ('modify', 'create', 'delete', 'rename')
- $context: Tool execution context (contains file_vault and vault_turn_id)
- $old_path: Original path for rename operations (optional)

=cut

sub _vault_capture {
    my ($self, $path, $type, $context, $old_path) = @_;
    
    my $vault = $context->{file_vault};
    my $turn_id = $context->{vault_turn_id};
    return unless $vault && $turn_id;
    
    eval {
        if ($type eq 'modify') {
            $vault->capture_before($path, $turn_id);
        }
        elsif ($type eq 'create') {
            $vault->record_creation($path, $turn_id);
        }
        elsif ($type eq 'delete') {
            $vault->record_deletion($path, $turn_id);
        }
        elsif ($type eq 'rename') {
            $vault->record_rename($old_path, $path, $turn_id);
        }
    };
    if ($@) {
        log_debug('FileOp', "Vault capture failed (non-fatal): $@");
    }
}

=head2 _check_sandbox

Check if a path is allowed under sandbox mode.

Sandbox mode restricts all file operations to the project directory.
This is a soft sandbox - terminal operations are NOT restricted.

Arguments:
- path: Path to check (relative or absolute)
- context: Context with config object

Returns: Hashref with:
- allowed: 1 if allowed, 0 if blocked
- error: Error message if blocked

=cut

# Check if a file contains null bytes in its first N bytes
sub _has_null_bytes {
    my ($self, $path, $sample_size) = @_;
    $sample_size ||= 8192;
    
    my $fh;
    return 0 unless open $fh, '<:raw', $path;
    
    my $buf;
    my $bytes_read = read($fh, $buf, $sample_size);
    close $fh;
    
    return 0 unless $bytes_read;
    return index($buf, "\x00") >= 0;
}

sub _check_sandbox {
    my ($self, $path, $context) = @_;
    
    # Check if sandbox mode is enabled
    my $config = $context->{config};
    return { allowed => 1 } unless $config;
    
    my $sandbox_enabled = $config->get('sandbox');
    return { allowed => 1 } unless $sandbox_enabled;
    
    # Get project directory from session state (NOT getcwd() which can differ)
    my $project_dir;
    if ($context->{session} && $context->{session}->{state}) {
        $project_dir = $context->{session}->{state}->{working_directory};
    }
    
    # Fallback to getcwd if no session working_directory
    $project_dir //= getcwd();
    
    # Resolve project directory to absolute path
    $project_dir = abs_path($project_dir) || $project_dir;
    
    # Expand tilde in path
    $path = expand_tilde($path);
    
    # Resolve path to absolute - handle relative paths
    my $resolved_path;
    if ($path =~ m{^/}) {
        # Absolute path
        $resolved_path = abs_path($path) || $path;
    } else {
        # Relative path - resolve against project directory
        my $full_path = File::Spec->rel2abs($path, $project_dir);
        $resolved_path = abs_path($full_path) || $full_path;
    }
    
    # Normalize paths for comparison (ensure trailing slash handling)
    $project_dir =~ s{/+$}{};
    $resolved_path =~ s{/+$}{};
    
    # Check if path is inside project directory
    # Path is allowed if it equals project_dir OR starts with project_dir/
    my $is_inside = ($resolved_path eq $project_dir) ||
                    ($resolved_path =~ /^\Q$project_dir\E\//);
    
    if ($is_inside) {
        log_debug('FileOp', "Sandbox: allowed path $resolved_path (inside $project_dir)");
        return { allowed => 1 };
    }
    
    log_info('FileOp', "Sandbox: BLOCKED path $resolved_path (outside $project_dir)");
    
    return {
        allowed => 0,
        error => "Sandbox mode: Access denied to '$path' - path is outside project directory '$project_dir'",
    };
}

#
# READ OPERATIONS
#

sub read_file {
    my ($self, $params, $context) = @_;
    
    my $path = $self->_clean_path($params->{path});
    my $start_line = $params->{start_line} || 1;
    my $end_line = $params->{end_line};
    
    # Validation
    return $self->error_result("Missing required parameter: path") unless $path;
    
    # Sandbox check
    my $sandbox_check = $self->_check_sandbox($path, $context);
    return $self->error_result($sandbox_check->{error}) unless $sandbox_check->{allowed};
    
    return $self->error_result("File not found: $path") unless -f $path;
    return $self->error_result("File not readable: $path") unless -r $path;

    # Interrupt check before reading. read_file can take a long time on
    # large files (gigabytes), and any interrupt bypass used to be missed
    # until the read finished. Checking before the read gives the user a
    # chance to cancel before we burn I/O on a file they no longer want.
    if ($self->check_interrupt($context)) {
        return $self->error_result(
            "Interrupted by user before reading $path. File was not read."
        );
    }


    # Count total lines so we can give a helpful error when start_line is
    # Count total lines so we can give a helpful error when start_line is
    # past EOF (previously returned silent empty output with success=1).
    # Wrapped in eval{} because the prior -f/-r checks can race with the
    # actual open() call (e.g. file deleted between stat and open, or
    # permission revoked). Without eval the croak used to propagate up
    # to SimpleAIAgent's outermost catch, surfacing as the generic
    # "I'm experiencing technical difficulties" message and killing the
    # conversation. Now we surface a proper error_result and ToolErrorGuidance
    # can categorize it.
    my $total_lines = 0;
    my $line_count_error;
    eval {
        open my $lc_fh, '<:raw', $path or croak "Cannot open $path: $!";
        while (<$lc_fh>) { $total_lines++ }
        close $lc_fh;
    };
    if ($@) {
        $line_count_error = $self->_clean_eval_error($@);
    }
    if ($line_count_error) {
        return $self->error_result("Cannot read $path: $line_count_error");
    }

    if ($start_line > $total_lines) {
        return $self->error_result(
            "Line range out of bounds: requested start_line=$start_line, " .
            "but $path has only $total_lines line" . ($total_lines == 1 ? '' : 's') . ". " .
            "Read with start_line=1 or omit it to read the full file."
        );
    }
    
    # Binary file detection - check first 8KB for null bytes
    my $binary_check = $self->_detect_binary($path);
    if ($binary_check->{is_binary}) {
        my $file_size = -s $path // 0;
        my $size_kb = int($file_size / 1024);
        my $size_str = $file_size < 1024 ? "${file_size}B" : "${size_kb}KB";
        my $type = $binary_check->{type};
        return $self->error_result(
            "Binary file detected ($type, $size_str): $path\n" .
            "read_file only works with text files. Options:\n" .
            "- For images: describe the path to the user and ask them to view it\n" .
            "- For other binary files: use terminal_operations to run 'file $path' or 'xxd $path | head'"
        );
    }

    log_debug('FileOperations', "Reading file: $path (lines $start_line-" . ($end_line || 'EOF') . ")");
    
    # Read file
    my $result;
    eval {
        # Open in raw mode first, then try to decode UTF-8 gracefully
        open my $fh, '<:raw', $path or croak "Cannot open $path: $!";

        # Inline interrupt polling. Long file reads (millions of lines)
        # used to ignore user ESC until the read finished. The cost is
        # one boolean flag check per poll unit - negligible vs the I/O.
        my $poll_every = CLIO::Core::WorkflowOrchestrator::INTERRUPT_POLL_INTERVAL_MS() * 100;
        my $lines_since_check = 0;

        my @lines;
        if (defined $end_line) {
            # Read specific range
            while (<$fh>) {
                my $line_num = $.;
                last if $line_num > $end_line;

                # Decode UTF-8, replacing invalid bytes with  (replacement character)
                eval {
                    $_ = Encode::decode('UTF-8', $_, Encode::FB_CROAK);
                };
                if ($@) {
                    # Fallback: replace invalid UTF-8 with replacement character
                    $_ = Encode::decode('UTF-8', $_, Encode::FB_DEFAULT);
                }

                push @lines, $_ if $line_num >= $start_line;

                if (++$lines_since_check >= $poll_every) {
                    $lines_since_check = 0;
                    if ($self->check_interrupt($context)) {
                        close $fh;
                        return $self->error_result(
                            "Interrupted at line $line_num of $path. " .
                            "Retry with start_line=$line_num to resume."
                        );
                    }
                }
            }
        } else {
            # Read from start_line to EOF
            while (<$fh>) {
                my $line_num = $.;

                # Decode UTF-8, replacing invalid bytes with  (replacement character)
                eval {
                    $_ = Encode::decode('UTF-8', $_, Encode::FB_CROAK);
                };
                if ($@) {
                    # Fallback: replace invalid UTF-8 with replacement character
                    $_ = Encode::decode('UTF-8', $_, Encode::FB_DEFAULT);
                }

                push @lines, $_ if $line_num >= $start_line;

                if (++$lines_since_check >= $poll_every) {
                    $lines_since_check = 0;
                    if ($self->check_interrupt($context)) {
                        close $fh;
                        return $self->error_result(
                            "Interrupted at line $line_num of $path. " .
                            "Retry with start_line=$line_num to resume."
                        );
                    }
                }
            }
        }

        close $fh;
        
        my $content = join('', @lines);
        my $lines_read = scalar(@lines);

        # Informational hint when caller asked for more than was available.
        my $range_note = '';
        if (defined $end_line && $end_line > $total_lines) {
            $range_note = " (file ends at line $total_lines)";
        }
        
        log_debug('FileOp', "Read $lines_read lines from $path");
        
        # Format action description for UI feedback
        my $line_range = $end_line ? "lines $start_line-$end_line" : "from line $start_line";
        my $action_desc = "reading $path ($line_range)";
        
        $result = $self->success_result(
            $content,
            action_description => $action_desc,
            lines_read => $lines_read,
            path => $path,
            start_line => $start_line,
            end_line => $end_line || 'EOF',
        );
    };
    
    if ($@) {
        log_debug('FileOp', "Failed to read $path: $@");
        return $self->error_result("Failed to read file: " . $self->_clean_eval_error($@));
    }
    
    return $result;
}

sub list_dir {
    my ($self, $params, $context) = @_;
    
    my $path = $self->_clean_path($params->{path}) || '.';
    my $recursive = $params->{recursive} || 0;
    
    # Sandbox check
    my $sandbox_check = $self->_check_sandbox($path, $context);
    return $self->error_result($sandbox_check->{error}) unless $sandbox_check->{allowed};
    
    # Validation
    return $self->error_result("Directory not found: $path") unless -d $path;
    return $self->error_result("Directory not readable: $path") unless -r $path;
    
    log_debug('FileOp', "Listing directory: $path (recursive=$recursive)");
    
    my $result;
    eval {
        my @entries;
        
        if ($recursive) {
            # Recursive listing
            use File::Find;
            find(sub {
                my $name = $File::Find::name;
                $name =~ s{^\./}{};  # Remove leading ./
                push @entries, {
                    name => $name,
                    type => -d $_ ? 'directory' : 'file',
                    size => -s $_,
                };
            }, $path);
        } else {
            # Non-recursive listing
            opendir my $dh, $path or croak "Cannot open directory $path: $!";
            while (my $entry = readdir $dh) {
                next if $entry eq '.' || $entry eq '..';
                my $full_path = File::Spec->catfile($path, $entry);
                push @entries, {
                    name => $entry,
                    type => -d $full_path ? 'directory' : 'file',
                    size => -s $full_path,
                };
            }
            closedir $dh;
        }
        
        # Sort entries: directories first, then alphabetically
        @entries = sort {
            (($b->{type} eq 'directory') <=> ($a->{type} eq 'directory'))
            || ($a->{name} cmp $b->{name})
        } @entries;
        
        log_debug('FileOperations', "Listed " . scalar(@entries) . " entries");
        
        # Count files and directories for action description
        my $file_count = grep { $_->{type} eq 'file' } @entries;
        my $dir_count = grep { $_->{type} eq 'directory' } @entries;
        my $action_desc = "listing $path ($file_count files, $dir_count directories)";
        
        $result = $self->success_result(
            \@entries,
            action_description => $action_desc,
            path => $path,
            count => scalar(@entries),
            recursive => $recursive,
        );
    };
    
    if ($@) {
        log_debug('FileOp', "Failed to list directory $path: $@");
        return $self->error_result("Failed to list directory: " . $self->_clean_eval_error($@));
    }
    
    return $result;
}

sub file_exists {
    my ($self, $params, $context) = @_;
    
    my $path = $self->_clean_path($params->{path});
    
    return $self->error_result("Missing required parameter: path") unless $path;
    
    # Sandbox check
    my $sandbox_check = $self->_check_sandbox($path, $context);
    return $self->error_result($sandbox_check->{error}) unless $sandbox_check->{allowed};
    
    log_debug('FileOp', "Checking existence: $path");
    
    my $exists = -e $path;
    my $type = -d $path ? 'directory' : -f $path ? 'file' : 'unknown';
    
    my $action_desc = "checking if $path exists" . ($exists ? " ($type)" : " (not found)");
    
    return $self->success_result(
        $exists ? 1 : 0,
        action_description => $action_desc,
        path => $path,
        exists => $exists,
        type => $type,
    );
}

sub get_file_info {
    my ($self, $params, $context) = @_;
    
    my $path = $self->_clean_path($params->{path});
    
    return $self->error_result("Missing required parameter: path") unless $path;
    
    # Sandbox check
    my $sandbox_check = $self->_check_sandbox($path, $context);
    return $self->error_result($sandbox_check->{error}) unless $sandbox_check->{allowed};
    
    return $self->error_result("File not found: $path") unless -e $path;
    
    log_debug('FileOp', "Getting file info: $path");
    
    my @stat = stat($path);
    
    my $info = {
        path => $path,
        type => -d $path ? 'directory' : -f $path ? 'file' : 'other',
        size => $stat[7],
        modified => scalar(localtime($stat[9])),
        modified_epoch => $stat[9],
        permissions => sprintf("%04o", $stat[2] & 07777),
        readable => -r $path ? 1 : 0,
        writable => -w $path ? 1 : 0,
        executable => -x $path ? 1 : 0,
    };
    
    my $type = $info->{type};
    my $size = $stat[7];
    my $action_desc = "file info: $path ($type, $size bytes)";
    
    return $self->success_result($info, action_description => $action_desc);
}

sub get_errors {
    my ($self, $params, $context) = @_;

    # Accept either singular 'path' (string) or plural 'paths' (arrayref).
    # Iterate when multiple files are given and aggregate results.
    my @paths;
    if (ref($params->{paths}) eq 'ARRAY') {
        @paths = @{$params->{paths}};
    } elsif (defined $params->{path}) {
        @paths = ($params->{path});
    }

    return $self->error_result("Missing required parameter: paths") unless @paths;

    my @all_errors;
    my %per_file;
    my $total_with_errors = 0;

    for my $path (@paths) {
        my $entry = $self->_check_one_file_errors($path, $context);
        unless ($entry->{success}) {
            # File-level error (missing, not Perl, etc.) - record and continue
            $per_file{$path} = {
                success => 0,
                error => $entry->{error},
            };
            next;
        }
        $total_with_errors++ if $entry->{has_errors};
        push @all_errors, @{$entry->{output}} if $entry->{output};
        $per_file{$path} = {
            success => 1,
            has_errors => $entry->{has_errors},
            error_count => $entry->{error_count},
        };
    }

    my $total = scalar(@paths);
    my $action_desc = $total == 1
        ? sprintf("checking syntax of %s (%s)", $paths[0], $per_file{$paths[0]}{error_count} ? "$per_file{$paths[0]}{error_count} errors" : "no errors")
        : sprintf("checking syntax of %d files (%d with errors)", $total, $total_with_errors);

    return $self->success_result(
        \@all_errors,
        action_description => $action_desc,
        paths => \@paths,
        files_checked => $total,
        files_with_errors => $total_with_errors,
        per_file => \%per_file,
        has_errors => scalar(@all_errors) > 0,
        error_count => scalar(@all_errors),
    );
}

sub _check_one_file_errors {
    my ($self, $path, $context) = @_;

    return $self->error_result("File not found: $path") unless -f $path;

    log_debug('FileOp', "Checking syntax: $path");

    # Only works for Perl files
    unless ($path =~ /\.p[lm]$/) {
        my $action_desc = "syntax check skipped (not Perl)";
        return $self->success_result(
            [],
            action_description => $action_desc,
            message => "Syntax checking only supported for Perl files (.pl, .pm)",
            path => $path,
        );
    }

    # Run perl -c to check syntax
    my $output = `perl -Ilib -c "$path" 2>&1`;
    my $exit_code = $? >> 8;

    my @errors;
    if ($exit_code != 0) {
        # Parse error messages
        foreach my $line (split /\n/, $output) {
            if ($line =~ /(.+) at .+ line (\d+)/) {
                push @errors, {
                    message => $1,
                    line => $2,
                    severity => 'error',
                    path => $path,
                };
            }
        }
    }

    my $status = scalar(@errors) > 0 ? scalar(@errors) . " errors" : "no errors";
    my $action_desc = "checking syntax of $path ($status)";

    return $self->success_result(
        \@errors,
        action_description => $action_desc,
        path => $path,
        has_errors => scalar(@errors) > 0,
        error_count => scalar(@errors),
    );
}

#
# SEARCH OPERATIONS
#

sub file_search {
    my ($self, $params, $context) = @_;
    
    my $pattern = $params->{pattern};
    my $directory = $self->_clean_path($params->{directory}) || '.';
    
    return $self->error_result("Missing required parameter: pattern") unless $pattern;
    
    my $max_results = $params->{max_results} || 200;  # Limit result count
    
    # Sandbox check for directory
    my $sandbox_check = $self->_check_sandbox($directory, $context);
    return $self->error_result($sandbox_check->{error}) unless $sandbox_check->{allowed};
    
    return $self->error_result("Directory not found: $directory") unless -d $directory;
    
    # Auto-upgrade to recursive when pattern has no path components
    # Users/agents expect "*Patch*" to find "lib/X/ApplyPatch.pm"
    if ($pattern !~ m{/} && $pattern !~ /\*\*/) {
        $pattern = "**/$pattern";
        log_debug('FileOp', "Auto-recursive search: pattern upgraded to $pattern");
    }
    
    log_debug('FileOp', "Searching files: pattern=$pattern, dir=$directory");
    
    my $result;
    eval {
        my @matches;
        
        # Check if pattern contains ** for recursive matching
        # bsd_glob doesn't support ** properly - it treats it as single *
        if ($pattern =~ /\*\*/) {
            # Use File::Find for recursive glob patterns
            require File::Find;
            
            # Convert glob pattern to regex
            # **/ matches any directory depth, * matches any file/dir name
            my $regex_pattern = $pattern;
            
            # Escape regex special chars first (except *, ?, {})
            $regex_pattern =~ s{([.+^\$\[\]\\|()])}{\\$1}g;
            
            # Use markers for ** patterns first to avoid partial replacement by *
            $regex_pattern =~ s{\*\*/}{\x00DOUBLESTAR_SLASH\x00}g;  # **/ -> marker
            $regex_pattern =~ s{\*\*}{\x01DOUBLESTAR\x01}g;          # ** alone -> marker
            
            # Now convert single * and ?
            $regex_pattern =~ s{\*}{[^/]*}g;        # * -> [^/]* (match within dir)
            $regex_pattern =~ s{\?}{[^/]}g;         # ? -> single char
            
            # Now replace markers with regex
            $regex_pattern =~ s{\x00DOUBLESTAR_SLASH\x00}{(?:.*/)?}g;  # **/ -> optional any path
            $regex_pattern =~ s{\x01DOUBLESTAR\x01}{.*}g;              # ** -> any chars
            
            # Handle brace expansion {a,b} -> (?:a|b)
            while ($regex_pattern =~ /\{([^}]+)\}/) {
                my $inside = $1;
                $inside =~ s/,/|/g;
                $regex_pattern =~ s/\{[^}]+\}/(?:$inside)/;
            }
            
            $regex_pattern = "^$regex_pattern\$";   # Anchor the pattern
            
            log_debug('FileOp', "Recursive search, regex: $regex_pattern");
            
            # Directories to skip during recursive search
            my %skip_dirs = map { $_ => 1 } qw(
                .git .svn .hg .bzr node_modules __pycache__ .tox .venv
                .mypy_cache .pytest_cache .coverage vendor .bundle
                .clio
            );
            
            # Silence File::Find's "Can't cd to" warnings for permission-denied dirs
            # These are informational only - the find continues despite them
            open my $devnull, '>', '/dev/null' or die "Cannot open /dev/null: $!";
            my $old_stderr = \*STDERR;
            {
                local *STDERR = $devnull;
                eval {
                    File::Find::find({
                        wanted => sub {
                        return unless -f $_;  # Only match files
                        
                        # Get path relative to search directory
                        my $rel_path = $File::Find::name;
                        $rel_path =~ s{^\Q$directory\E/?}{};
                        
                        return unless $rel_path;  # Skip the root directory itself
                        
                        if ($rel_path =~ /$regex_pattern/) {
                            push @matches, {
                                path => $rel_path,
                                type => 'file',
                                size => -s $File::Find::name,
                            };
                            # Stop if we hit the limit
                            $File::Find::prune = 1 if @matches >= $max_results;
                            # Poll for interrupt every N matches so a recursive
                            # search across a big tree can be cancelled.
                            if (@matches % 100 == 0 && $self->check_interrupt($context)) {
                                $File::Find::prune = 1;
                                return;
                            }
                        }
                        },
                        preprocess => sub {
                            return grep { !$skip_dirs{$_} } @_;
                        },
                    }, $directory);
                };
            }
            # STDERR automatically restored here (even if eval dies)
            *STDERR = $old_stderr;
        } else {
            # Use File::Glob for non-recursive patterns (faster)
            # GLOB_BRACE allows {a,b} syntax, GLOB_NOCHECK returns pattern if no matches
            my @files = bsd_glob("$directory/$pattern", GLOB_BRACE);
            
            foreach my $path (@files) {
                next unless -e $path;  # Skip non-existent entries
                
                # Remove directory prefix for cleaner paths
                my $rel_path = $path;
                $rel_path =~ s{^\Q$directory\E/?}{};
                
                push @matches, {
                    path => $rel_path,
                    type => -d $path ? 'directory' : 'file',
                    size => -s $path,
                };
            }
        }
        
        log_debug('FileOperations', "Found " . scalar(@matches) . " matches");
        
        my $action_desc = "searching for '$pattern' in $directory (" . scalar(@matches) . " matches)";
        
        $result = $self->success_result(
            \@matches,
            action_description => $action_desc,
            pattern => $pattern,
            directory => $directory,
            count => scalar(@matches),
        );
    };
    
    if ($@) {
        log_debug('FileOp', "File search failed: $@");
        return $self->error_result("File search failed: " . $self->_clean_eval_error($@));
    }
    
    return $result;
}

sub grep_search {
    my ($self, $params, $context) = @_;

    my $query = $params->{query};
    # Scope the search to a directory. Accept either 'directory' (canonical, matches file_search)
    # or 'path' (alias for callers who expect the same parameter name they use elsewhere).
    my $pattern = $params->{pattern} || '**/*';
    my $is_regex = $params->{is_regex} || 0;
    my $max_results = $params->{max_results} || 50;  # Prevent runaway searches
    my $directory = $self->_clean_path($params->{directory}) || $self->_clean_path($params->{path}) || '.';

    return $self->error_result("Missing required parameter: query") unless defined $query && length($query);

    # Graceful file-path handling: if the model passed a FILE path as 'directory'
    # or 'path' (a common mistake since 'path' is described as "File or directory
    # path"), extract the file's directory and constrain the search to just that
    # file by adjusting the pattern. This prevents the confusing "Directory not
    # found" error that happens when a file path reaches file_search.
    if (-f $directory) {
        my $file_name = basename($directory);
        $directory = dirname($directory) || '.';
        $directory = $self->_clean_path($directory);
        # Only constrain pattern if the user didn't already specify one
        # (the pattern is a glob for filenames, so the file name is the right
        # constraint regardless of what the user passed)
        $pattern = $file_name;
        log_debug('FileOp', "grep_search: file path detected, extracting directory ($directory) and constraining to $pattern");
    }

    # Auto-detect regex intent when query contains metacharacters
    # Agents often pass regex patterns (e.g., "sdl|SDL") without setting is_regex
    if (!$is_regex && $query =~ /[|\(\)\[\]\{\}\+\^\\\$]/) {
        $is_regex = 1;
        log_debug('FileOp', "Auto-detected regex intent (query contains metacharacters): $query");
    }
    
    # Reject obviously dangerous regex patterns
    if ($is_regex && $query =~ /\(\?\{/) {
        return $self->error_result("Regex with code execution blocks is not allowed");
    }
    
    # Safeguards to prevent hangs on binary/large/problematic files
    my $MAX_FILE_SIZE    = 1_048_576;  # 1MB - skip files larger than this
    my $MAX_LINE_LENGTH  = 10_240;     # 10KB - skip file if any line exceeds this
    my $SEARCH_TIMEOUT   = 120;        # 2 minutes wall-clock limit
    my $BINARY_CHECK_SIZE = 8_192;     # 8KB sample for null byte detection
    
    log_debug('FileOp', "Grep search: query=$query, pattern=$pattern, regex=$is_regex, max_results=$max_results");
    
    my $result;
    eval {
        my @matches;
        my $files_searched = 0;
        my $files_skipped = 0;
        my $search_truncated = 0;
        my $timed_out = 0;
        my $start_time = time();
        
        # First, find files matching pattern
        # Forward the directory scope to file_search so grep is bounded by it.
        my $file_result = $self->file_search({ pattern => $pattern, directory => $directory }, $context);
        unless ($file_result->{success}) {
            $result = $file_result;
            return;
        }
        
        my @files = grep { $_->{type} eq 'file' } @{$file_result->{output}};
        
        # Sort files to prioritize code files over docs/other files
        # This ensures important files are searched even with limits
        @files = sort {
            my $a_code = ($a->{path} =~ /\.(pm|pl|t|py|js|ts|rb|go|rs|java|c|h|cpp|hpp)$/i) ? 0 : 1;
            my $b_code = ($b->{path} =~ /\.(pm|pl|t|py|js|ts|rb|go|rs|java|c|h|cpp|hpp)$/i) ? 0 : 1;
            $a_code <=> $b_code || $a->{path} cmp $b->{path};
        } @files;
        
        # Limit files searched to prevent slowdown with large codebases
        my $max_files_to_search = 200;  # Increased from 100
        if (scalar(@files) > $max_files_to_search) {
            $search_truncated = 1;
            @files = @files[0..$max_files_to_search-1];
        }
        
        # Search each file
        # Compile regex safely with error handling
        my $search_regex;
        if ($is_regex) {
            # User-provided regex - wrap in eval to catch invalid patterns
            $search_regex = eval { qr/$query/i };
            if ($@) {
                my $err = $@;
                $err =~ s/ at .* line \d+.*//;  # Clean up error message
                $result = $self->error_result("Invalid regex pattern '$query': $err");
                return;
            }
        } else {
            # Literal search - always safe with \Q...\E
            $search_regex = qr/\Q$query\E/i;
        }
        
        my $files_since_check = 0;
        foreach my $file (@files) {
            # file_search returns paths relative to the search directory. Rebuild the
            # absolute path so -T/-s/open work regardless of process cwd.
            my $path = $file->{path};
            unless (File::Spec->file_name_is_absolute($path)) {
                $path = File::Spec->catfile($directory, $path);
            }
            $files_searched++;

            # Poll for interrupt every N files so a long grep across many
            # files can be cancelled mid-stream.
            if (++$files_since_check >= 25) {
                $files_since_check = 0;
                if ($self->check_interrupt($context)) {
                    $search_truncated = 1;
                    last;
                }
            }

            # Wall-clock timeout check
            if (time() - $start_time > $SEARCH_TIMEOUT) {
                $timed_out = 1;
                $search_truncated = 1;
                log_debug('FileOp', "Grep search timed out after ${SEARCH_TIMEOUT}s");
                last;
            }

            # Skip files larger than size limit
            my $file_size = -s $path;
            if (defined $file_size && $file_size > $MAX_FILE_SIZE) {
                $files_skipped++;
                log_debug('FileOp', "Skipping large file ($file_size bytes): $path");
                next;
            }

            # Skip binary files - enhanced detection
            # First check Perl's -T heuristic
            unless (-T $path) {
                $files_skipped++;
                next;
            }

            # Then sample for null bytes (catches files -T misclassifies)
            if ($self->_has_null_bytes($path, $BINARY_CHECK_SIZE)) {
                $files_skipped++;
                log_debug('FileOp', "Skipping file with null bytes: $path");
                next;
            }
            
            # Open in raw mode and let Perl handle encoding gracefully
            my $fh;
            unless (open $fh, '<', $path) {
                log_warning('FileOp', "Cannot open $path: $!");
                next;
            }
            
            my $line_num = 0;
            while (my $line = <$fh>) {
                $line_num++;
                
                # Skip file if line is excessively long (binary/minified/data)
                if (length($line) > $MAX_LINE_LENGTH) {
                    log_debug('FileOp', "Skipping file with long line (${\length($line)} bytes) at line $line_num: $path");
                    $files_skipped++;
                    last;
                }
                
                # Regex matching is encoding-agnostic for ASCII queries
                if ($line =~ $search_regex) {
                    push @matches, {
                        path => $path,
                        relative_path => $file->{path},
                        line => $line_num,
                        content => $line,
                    };

                    # Stop if we hit result limit
                    if (scalar(@matches) >= $max_results) {
                        close $fh;
                        last;
                    }
                }
            }
            
            close $fh;
            last if scalar(@matches) >= $max_results;
        }
        
        log_debug('FileOperations', "Found " . scalar(@matches) . " matches (limited to $max_results) across " .
                     $files_searched . " files searched");
        
        my $match_summary = scalar(@matches) . " matches in " . $files_searched . " files"
            . ($files_skipped ? " ($files_skipped skipped)" : "");
        my $timeout_note = $timed_out ? " (timed out after ${SEARCH_TIMEOUT}s)" : "";
        my $truncated_note = ($search_truncated || scalar(@matches) >= $max_results) ? " (results may be truncated)" : "";
        my $action_desc = "searching for '$query' ($match_summary)$timeout_note$truncated_note";
        
        $result = $self->success_result(
            \@matches,
            action_description => $action_desc,
            query => $query,
            pattern => $pattern,
            directory => $directory,
            is_regex => $is_regex,
            match_count => scalar(@matches),
            files_searched => $files_searched,
            truncated => $search_truncated || (scalar(@matches) >= $max_results),
        );
    };
    
    if ($@) {
        log_debug('FileOp', "Grep search failed: $@");
        return $self->error_result("Grep search failed: " . $self->_clean_eval_error($@));
    }
    
    return $result;
}

sub semantic_search {
    my ($self, $params, $context) = @_;
    
    my $query = $params->{query};
    my $scope = $params->{scope} || '.';
    my $top_k = $params->{max_results} || 20;
    
    return $self->error_result("Missing required parameter: query") unless $query;
    
    log_debug('FileOp', "Semantic search for: $query (scope: $scope)");
    
    # Use hybrid keyword + structure search
    return $self->_semantic_search_hybrid($query, $scope, $top_k, $context);
}

# Hybrid semantic search: keyword matching + code structure analysis
sub _semantic_search_hybrid {
    my ($self, $query, $scope, $top_k, $context) = @_;
    
    # Extract keywords from query (simple word splitting)
    my @keywords = grep { length($_) > 2 } split(/\W+/, lc($query));
    
    unless (@keywords) {
        return $self->error_result("No valid search keywords in query");
    }
    
    log_debug('FileOperations', "Keywords: " . join(', ', @keywords));
    
    # Combine keywords into a single regex for efficient single-pass search
    # Use alternation to match any keyword
    my $combined_regex = join('|', map { quotemeta($_) } @keywords);
    
    # Use proper glob pattern
    my $pattern = ($scope eq '.' || !$scope) ? '**/*' : "$scope/**/*";
    
    my $grep_result = $self->grep_search({
        query => $combined_regex,
        pattern => $pattern,
        is_regex => 1,
        max_results => 500,  # Higher limit for semantic search
    }, $context);
    
    my %file_scores = ();  # file => score
    my %file_matches = ();  # file => array of match lines
    
    if ($grep_result->{success} && $grep_result->{output}) {
        foreach my $match (@{$grep_result->{output}}) {
            # grep_search returns {path, line, content}
            my $file = $match->{path};
            next unless $file;
            
            # Score: count how many keywords matched in this file
            my $content_lc = lc($match->{content});
            my $keyword_hits = 0;
            foreach my $keyword (@keywords) {
                $keyword_hits++ if $content_lc =~ /\Q$keyword\E/;
            }
            
            $file_scores{$file} ||= 0;
            $file_scores{$file} += $keyword_hits;
            
            # Boost score if keyword appears in file name
            foreach my $keyword (@keywords) {
                if ($file =~ /\Q$keyword\E/i) {
                    $file_scores{$file} += 2;
                    last;  # Only boost once per file
                }
            }
            
            # Store match details (normalize format)
            $file_matches{$file} ||= [];
            push @{$file_matches{$file}}, {
                file => $file,
                line => $match->{line},
                content => $match->{content},
            };
        }
    }
    
    # Apply tree-sitter analysis to boost scores for symbol definitions
    $self->_enhance_scores_with_symbols(\%file_scores, \%file_matches, \@keywords);
    
    # Sort files by relevance score
    my @ranked_files = sort { $file_scores{$b} <=> $file_scores{$a} } keys %file_scores;
    
    my $result_count = scalar(@ranked_files);
    
    if ($result_count == 0) {
        return $self->success_result(
            "No files matched query '$query'",
            files => [],
            count => 0,
            keywords => \@keywords,
            method => 'hybrid',
        );
    }
    
    # Build result with top N files
    @ranked_files = splice(@ranked_files, 0, $top_k) if @ranked_files > $top_k;
    
    my @results = ();
    foreach my $file (@ranked_files) {
        push @results, {
            file => $file,
            score => $file_scores{$file},
            matches => $file_matches{$file},
            match_count => scalar(@{$file_matches{$file}}),
        };
    }
    
    my $message = "Found $result_count files matching '$query' (hybrid search)";
    $message .= " (showing top $top_k)" if $result_count > $top_k;
    
    my $action_desc = "searching codebase for '$query' ($result_count matches)";
    
    log_debug('FileOp', "Hybrid search found $result_count files");
    
    return $self->success_result(
        $message,
        action_description => $action_desc,
        files => \@results,
        count => $result_count,
        keywords => \@keywords,
        method => 'hybrid',
    );
}

# Enhance scores using tree-sitter symbol analysis
sub _enhance_scores_with_symbols {
    my ($self, $file_scores, $file_matches, $keywords) = @_;
    
    # Try to load TreeSitter
    my $ts;
    eval {
        require CLIO::Code::TreeSitter;
        $ts = CLIO::Code::TreeSitter->new(debug => 0);
    };
    
    unless ($ts) {
        log_debug('FileOp', "TreeSitter not available, skipping symbol analysis");
        return;
    }
    
    log_debug('FileOp', "Enhancing scores with symbol analysis");
    
    # Analyze top files (limit to avoid slow performance)
    my @top_files = sort { $file_scores->{$b} <=> $file_scores->{$a} } keys %$file_scores;
    @top_files = splice(@top_files, 0, 50) if @top_files > 50;
    
    for my $file (@top_files) {
        # Skip non-code files
        next unless $file =~ /\.(pm|pl|t|py|js|jsx|ts|tsx)$/i;
        
        my $analysis = eval { $ts->analyze_file($file) };
        next unless $analysis && $analysis->{symbols};
        
        # Check each symbol against keywords
        for my $symbol (@{$analysis->{symbols}}) {
            my $name = lc($symbol->{name} || '');
            next unless $name;
            
            for my $keyword (@$keywords) {
                if ($name =~ /\Q$keyword\E/i) {
                    # Boost based on symbol type
                    my $boost = 0;
                    if ($symbol->{type} eq 'function') {
                        $boost = 5;  # Strong boost for function definitions
                    } elsif ($symbol->{type} eq 'package') {
                        $boost = 4;  # Good boost for package/class definitions
                    } elsif ($symbol->{type} eq 'variable' && $symbol->{scope} eq 'global') {
                        $boost = 2;  # Moderate boost for global variables
                    }
                    
                    if ($boost > 0) {
                        $file_scores->{$file} += $boost;
                        log_debug('FileOp', "Boosted $file +$boost (symbol: $name, type: $symbol->{type})");
                        
                        # Add symbol match to file matches
                        push @{$file_matches->{$file}}, {
                            file => $file,
                            line => $symbol->{line},
                            content => "$symbol->{type} definition: $symbol->{name}",
                            symbol_type => $symbol->{type},
                        };
                    }
                    last;  # One boost per keyword per file
                }
            }
        }
    }
}

# Helper to truncate text
sub _truncate {
    my ($text, $max) = @_;
    return '' unless defined $text;
    return $text if length($text) <= $max;
    return substr($text, 0, $max) . '...';
}

=head2 _detect_binary

Checks whether a file appears to be binary by sampling the first 8KB.
Returns a hashref with {is_binary, type}.

=cut

sub _detect_binary {
    my ($self, $path) = @_;

    open my $fh, '<:raw', $path or return { is_binary => 0 };
    my $sample = '';
    read $fh, $sample, 8192;
    close $fh;

    # Null bytes are the clearest binary indicator
    if ($sample =~ /\x00/) {
        # Identify common image/binary types by magic bytes
        my $type = 'binary';
        if (substr($sample, 0, 4) eq "\x89PNG")       { $type = 'image/png' }
        elsif (substr($sample, 0, 2) eq "\xff\xd8")   { $type = 'image/jpeg' }
        elsif (substr($sample, 0, 4) eq 'GIF8')       { $type = 'image/gif' }
        elsif (substr($sample, 0, 4) eq 'RIFF')       { $type = 'image/webp' }
        elsif (substr($sample, 0, 4) eq "\x1f\x8b\x08\x00") { $type = 'gzip' }
        elsif (substr($sample, 0, 2) eq 'PK')         { $type = 'zip/jar' }
        elsif (substr($sample, 0, 4) eq '%PDF')       { $type = 'pdf' }
        return { is_binary => 1, type => $type };
    }

    # True control characters (not UTF-8 continuation bytes \x80-\xBF)
    # \x01-\x08: control chars, \x0e-\x1f: formatting codes, \x7f: DEL
    my $non_text = () = $sample =~ /[\x01-\x08\x0e-\x1f\x7f]/g;
    my $ratio = length($sample) > 0 ? $non_text / length($sample) : 0;
    if ($ratio > 0.10) {
        return { is_binary => 1, type => 'binary (high non-text ratio)' };
    }

    return { is_binary => 0 };
}

sub read_tool_result {
    my ($self, $params, $context) = @_;
    
    my $toolCallId = $params->{toolCallId} || $params->{tool_call_id};
    my $offset = $params->{offset} // 0;

    # Default chunk size scales with model context window
    my $default_chunk = 8192;
    if ($context && $context->{api_manager} && $context->{api_manager}->can('get_model_capabilities')) {
        my $caps = eval { $context->{api_manager}->get_model_capabilities() };
        if ($caps && $caps->{max_prompt_tokens}) {
            require CLIO::Core::Defaults;
            $default_chunk = CLIO::Core::Defaults::default_chunk_size($caps->{max_prompt_tokens});
        }
    }
    my $length = $params->{length} // $default_chunk;
    
    # Validation
    return $self->error_result("Missing required parameter: toolCallId") unless $toolCallId;
    
    if ($offset < 0) {
        return $self->error_result("offset must be >= 0");
    }
    
    if ($length <= 0) {
        return $self->error_result("length must be > 0");
    }
    
    # Enforce maximum chunk size
    require CLIO::Core::Defaults;
    my $max_chunk_size = CLIO::Core::Defaults::TOOL_RESULT_MAX_CHUNK();
    if ($length > $max_chunk_size) {
        log_debug('FileOp', "Requested length $length exceeds max $max_chunk_size, capping to $max_chunk_size");
        $length = $max_chunk_size;
    }
    
    # Get session ID from context
    # Note: session object uses 'session_id' not 'id'
    my $session_id = $context->{session}->{session_id} || $context->{session}->{id};
    unless ($session_id) {
        return $self->error_result("No session ID in context. Cannot retrieve tool result.");
    }
    
    log_debug('FileOp', "Reading tool result: toolCallId=$toolCallId, offset=$offset, length=$length");
    
    # Load ToolResultStore (lazy load to avoid circular dependencies)
    require CLIO::Session::ToolResultStore;
    
    my $store = CLIO::Session::ToolResultStore->new(
        debug => $self->{debug},
    );
    
    # Retrieve chunk
    my $chunk;
    eval {
        $chunk = $store->retrieveChunk($toolCallId, $session_id, $offset, $length);
    };
    
    if ($@) {
        my $error = $@;
        
        # Parse error type - check for suggestions from fuzzy match
        if ($error =~ /Tool result not found.*Did you mean one of these\?/s) {
            # Error already contains helpful suggestions from ToolResultStore
            return $self->error_result($error);
        } elsif ($error =~ /not found/i) {
            return $self->error_result(
                "Tool result not found: $toolCallId\n\n" .
                "This result may have been:\n" .
                "- Already deleted\n" .
                "- Never persisted (small enough to send inline)\n" .
                "- From a different session (cross-session access denied)\n\n" .
                "Check that the toolCallId is correct and the result was actually persisted."
            );
        } elsif ($error =~ /Invalid offset (\d+) for result with total length (\d+)/) {
            my ($bad_offset, $total) = ($1, $2);
            return $self->error_result(
                "Invalid offset $bad_offset\n\n" .
                "The tool result has $total characters total.\n" .
                "Valid offset range: 0 to " . ($total - 1) . "\n\n" .
                "Start reading from offset 0:\n" .
                "file_operations(operation: \"read_tool_result\", toolCallId: \"$toolCallId\", offset: 0, length: $length)"
            );
        } else {
            return $self->error_result("Failed to retrieve tool result: $error");
        }
    }
    
    log_debug('FileOp', "Retrieved chunk: offset=$chunk->{offset}, length=$chunk->{length}, hasMore=$chunk->{hasMore}");
    
    # Format response
    my @lines;
    push @lines, "[TOOL_RESULT_CHUNK]";
    push @lines, "Tool Call ID: $chunk->{toolCallId}";
    push @lines, "Offset: $chunk->{offset}";
    push @lines, "Length: $chunk->{length}";
    push @lines, "Total Length: $chunk->{totalLength}";
    push @lines, "Has More: " . ($chunk->{hasMore} ? 'true' : 'false');
    push @lines, "Next Offset: $chunk->{nextOffset}" if $chunk->{nextOffset};
    push @lines, "";
    push @lines, "--- Content ---";
    push @lines, $chunk->{content};
    push @lines, "--- End Content ---";
    
    if ($chunk->{hasMore}) {
        push @lines, "";
        push @lines, "To read next chunk:";
        push @lines, "file_operations(operation: \"read_tool_result\", toolCallId: \"$chunk->{toolCallId}\", offset: $chunk->{nextOffset}, length: $length)";
    } else {
        push @lines, "";
        push @lines, "SUCCESS: All content retrieved (no more chunks)";
    }
    
    my $progress = sprintf("%d-%d of %d bytes", 
        $chunk->{offset}, $chunk->{offset} + $chunk->{length}, $chunk->{totalLength});
    my $action_desc = "reading tool result $toolCallId ($progress)";
    
    return $self->success_result(
        join("\n", @lines),
        action_description => $action_desc,
        toolCallId => $chunk->{toolCallId},
        offset => $chunk->{offset},
        length => $chunk->{length},
        totalLength => $chunk->{totalLength},
        hasMore => $chunk->{hasMore} ? 1 : 0,
    );
}

#
# WRITE OPERATIONS
#

sub write_file {
    my ($self, $params, $context) = @_;

    my $path = $self->_clean_path($params->{path});
    my $content = $params->{content};
    my $append = $params->{append} ? 1 : 0;

    return $self->error_result("Missing required parameter: path") unless $path;
    return $self->error_result("Missing required parameter: content") unless defined $content;

    # Sandbox check (before other validation to give clear error)
    my $sandbox_check = $self->_check_sandbox($path, $context);
    return $self->error_result($sandbox_check->{error}) unless $sandbox_check->{allowed};

    # Authorization key uses 'write_file' regardless of caller alias
    # (create_file/append_file both route here). Path authorizer sees a
    # consistent operation name for grant/revoke matching.
    my $auth_result = $self->_check_write_authorization($path, 'write_file', $context);
    if ($auth_result->{status} eq 'requires_authorization') {
        return $self->error_result(
            "Authorization required: $auth_result->{reason}\n\n" .
            "This operation requires user permission because the path is outside the session directory.\n" .
            "Use interact tool to request authorization."
        );
    } elsif ($auth_result->{status} eq 'denied') {
        return $self->error_result("Authorization denied: $auth_result->{reason}");
    }

    # Security: scan script content for risky patterns
    my $scan = $self->_scan_script_content($path, $content, $context);
    if ($scan) {
        my $approved = $self->_prompt_script_confirmation($path, $scan, $context);
        unless ($approved) {
            log_info('FileOp', "User DENIED script write: $path");
            return $self->error_result(
                "Script write denied by user.\n\n" .
                "Security analysis: $scan->{summary}\n" .
                "The user chose not to allow this file. Try a different approach."
            );
        }
        log_info('FileOp', "User APPROVED script write: $path");
    }

    # Multi-agent coordination: Request file lock via broker
    my ($lock_acquired, $lock_error) = $self->_acquire_file_lock($path, $context);
    return $self->error_result($lock_error) if $lock_error;

    # Snapshot the existence state BEFORE the write so we can pick the
    # right vault mode. 'create' lets undo delete the new file; 'modify'
    # lets undo restore the original content.
    my $file_existed = -f $path;
    my $vault_type = $file_existed ? 'modify' : 'create';
    $self->_vault_capture($path, $vault_type, $context);

    # Choose verb for log + action_description based on mode
    my $verb = $append ? 'appending to' : ($file_existed ? 'overwriting' : 'creating');

    log_debug('FileOp', "Write file: $path (mode=$verb, authorized: $auth_result->{reason})");

    my $result;
    my $written_size;
    eval {
        # Create parent directories if needed with secure permissions.
        # Only needed when appending to a new file or overwriting nothing -
        # both code paths can land here, so this is shared.
        my $dir = dirname($path);
        unless (-d $dir) {
            $self->_secure_mkdir($dir, 0700, $context);
        }

        if ($append) {
            # Append mode: opens the file directly with >> semantics. If
            # the file didn't exist before, opens creates it. We use the
            # same secure-permissions chmod as the original append_file to
            # avoid leaving existing files with overly permissive modes.
            chmod(0600, $path) if -f $path;

            open my $fh, '>>:utf8', $path or croak "Cannot append to $path: $!";
            print $fh $content;
            close $fh;
        } else {
            # Truncate-and-write mode: atomic write via temp + rename. The
            # temp-file approach guarantees we never leave a half-written
            # file behind if the rename fails midway.
            my $mode = $self->_get_file_mode($path, $content);
            my ($fh, $temp_path) = $self->_secure_open($path, $mode, $context);
            print $fh $content;
            $self->_secure_close($fh, $temp_path, $path, $context);
        }

        $written_size = -s $path;

        log_debug('FileOp', "Wrote file $path ($written_size bytes, mode=$verb)");

        my $action_desc = "$verb $path ($written_size bytes)";
        my $status_msg = $append
            ? "Content appended successfully"
            : ($file_existed ? "File written successfully" : "File created successfully");

        $result = $self->success_result(
            $status_msg,
            action_description => $action_desc,
            path => $path,
            size => $written_size,
            mode => $append ? 'append' : ($file_existed ? 'overwrite' : 'create'),
        );
    };

    # Release lock if acquired
    $self->_release_file_lock($path, $context) if $lock_acquired;

    if ($@) {
        log_debug('FileOp', "Failed to write file: $@");
        return $self->error_result("Failed to write file: " . $self->_clean_eval_error($@));
    }

    return $result;
}

sub replace_string {
    my ($self, $params, $context) = @_;
    
    my $path = $self->_clean_path($params->{path});
    my $old_string = $params->{old_string};
    my $new_string = $params->{new_string};
    
    return $self->error_result("Missing required parameter: path") unless $path;
    return $self->error_result("Missing required parameter: old_string") unless defined $old_string;
    return $self->error_result("Missing required parameter: new_string") unless defined $new_string;
    
    # Sandbox check
    my $sandbox_check = $self->_check_sandbox($path, $context);
    return $self->error_result($sandbox_check->{error}) unless $sandbox_check->{allowed};
    
    return $self->error_result("File not found: $path") unless -f $path;
    
    # Multi-agent coordination: Request file lock via broker
    my ($lock_acquired, $lock_error) = $self->_acquire_file_lock($path, $context);
    return $self->error_result($lock_error) if $lock_error;
    
    log_debug('FileOp', "Replacing string in: $path");
    
    # Vault: capture original content for undo support
    $self->_vault_capture($path, 'modify', $context);
    
    my $result;
    eval {
        # Read file
        open my $fh, '<:utf8', $path or croak "Cannot read $path: $!";
        my $content = do { local $/; <$fh> };
        close $fh;
        
        # Count occurrences
        my $count = 0;
        $count++ while $content =~ /\Q$old_string\E/g;
        
        if ($count == 0) {
            $result = $self->error_result(
                "String not found in '$path'. Read the file to see its actual content before retrying."
            );
            return;
        }
        
        # Replace
        $content =~ s/\Q$old_string\E/$new_string/g;
        
        # Write back using atomic write pattern
        my $mode = $self->_get_file_mode($path);
        my ($write_fh, $temp_path) = $self->_secure_open($path, $mode, $context);
        print $write_fh $content;
        $self->_secure_close($write_fh, $temp_path, $path, $context);
        
        log_debug('FileOp', "Replaced $count occurrences in $path");
        
        my $action_desc = "replacing string in $path ($count occurrences)";
        
        $result = $self->success_result(
            "Replaced $count occurrence(s) successfully",
            action_description => $action_desc,
            path => $path,
            replacements => $count,
        );
    };
    
    # Release lock if acquired
    $self->_release_file_lock($path, $context) if $lock_acquired;
    
    if ($@) {
        log_debug('FileOp', "Failed to replace string: $@");
        return $self->error_result("Failed to replace string: " . $self->_clean_eval_error($@));
    }
    
    return $result;
}

=head2 multi_replace_string

Perform multiple replace operations across multiple files in a single call.

Parameters:
- replacements: Array of replacement objects, each containing:
  - path: File path
  - old_string: String to find
  - new_string: Replacement string
  - explanation: (optional) Description of this replacement

Returns: Summary of all replacements performed

=cut

sub multi_replace_string {
    my ($self, $params, $context) = @_;
    
    my $replacements = $params->{replacements};
    
    return $self->error_result("Missing required parameter: replacements") unless $replacements;
    return $self->error_result("'replacements' must be an array") unless ref($replacements) eq 'ARRAY';
    return $self->error_result("'replacements' array is empty") unless @$replacements > 0;
    
    log_debug('FileOperations', "Processing " . scalar(@$replacements) . " replacement operations");
    
    my @successful = ();
    my @failed = ();
    my $total_replacements = 0;
    
    foreach my $i (0 .. $#$replacements) {
        my $rep = $replacements->[$i];
        my $idx = $i + 1;

        # Strip JSON-string-style quote artifacts from path so AI
        # emitted "/path/to/file" doesn't become a literal "/path"
        # directory under the workspace.
        $rep->{path} = $self->_clean_path($rep->{path}) if exists $rep->{path};

        unless (ref($rep) eq 'HASH') {
            push @failed, {
                index => $idx,
                error => "Replacement $idx is not a hash"
            };
            next;
        }
        
        my $path = $rep->{path};
        my $old_string = $rep->{old_string};
        my $new_string = $rep->{new_string};
        my $explanation = $rep->{explanation} || "replacement $idx";
        
        unless ($path) {
            push @failed, {
                index => $idx,
                error => "Missing required parameter: path in replacement $idx"
            };
            next;
        }
        
        unless (defined $old_string) {
            push @failed, {
                index => $idx,
                path => $path,
                error => "Missing required parameter: old_string in replacement $idx"
            };
            next;
        }
        
        unless (defined $new_string) {
            push @failed, {
                index => $idx,
                path => $path,
                error => "Missing required parameter: new_string in replacement $idx"
            };
            next;
        }
        
        # Perform the replacement using existing replace_string method
        my $result = $self->replace_string({
            path => $path,
            old_string => $old_string,
            new_string => $new_string,
        }, $context);
        
        if ($result->{success}) {
            push @successful, {
                index => $idx,
                path => $path,
                replacements => $result->{replacements} || 0,
                explanation => $explanation,
            };
            $total_replacements += ($result->{replacements} || 0);
        } else {
            push @failed, {
                index => $idx,
                path => $path,
                error => $result->{error} || "Unknown error",
                explanation => $explanation,
            };
        }
    }
    
    my $success_count = scalar(@successful);
    my $fail_count = scalar(@failed);
    my $total_count = scalar(@$replacements);
    
    log_debug('FileOp', "Completed: $success_count succeeded, $fail_count failed, $total_replacements total replacements");
    
    # Build summary message and action description
    my $message = "$success_count of $total_count operations succeeded ($total_replacements replacements)";
    my $action_desc = ($total_count == 1) 
        ? "replacing text in 1 file ($total_replacements replacement" . ($total_replacements == 1 ? ")" : "s)")
        : "replacing text in $total_count files ($total_replacements replacements)";
    
    # If all failed, return error
    if ($success_count == 0) {
        return $self->error_result(
            "All replacement operations failed",
            successful => \@successful,
            failed => \@failed,
            total => $total_count,
        );
    }
    
    # If some succeeded, return success with details
    return $self->success_result(
        $message,
        action_description => $action_desc,
        successful => \@successful,
        failed => \@failed,
        success_count => $success_count,
        fail_count => $fail_count,
        total_count => $total_count,
        total_replacements => $total_replacements,
    );
}

sub insert_at_line {
    my ($self, $params, $context) = @_;
    
    my $path = $self->_clean_path($params->{path});
    # Accept both 'line' (schema name) and 'line_number' (legacy/docs)
    my $line_number = $params->{line} // $params->{line_number};
    my $content = $params->{content};
    
    return $self->error_result("Missing required parameter: path") unless $path;
    return $self->error_result("Missing required parameter: line") unless defined $line_number;
    return $self->error_result("Missing required parameter: content") unless defined $content;
    
    # Sandbox check
    my $sandbox_check = $self->_check_sandbox($path, $context);
    return $self->error_result($sandbox_check->{error}) unless $sandbox_check->{allowed};
    
    return $self->error_result("File not found: $path") unless -f $path;
    return $self->error_result("Invalid line number") unless $line_number > 0;
    
    # Multi-agent coordination: Request file lock via broker
    my ($lock_acquired, $lock_error) = $self->_acquire_file_lock($path, $context);
    return $self->error_result($lock_error) if $lock_error;
    
    log_debug('FileOp', "Inserting at line $line_number in: $path");
    
    # Vault: capture original content for undo support
    $self->_vault_capture($path, 'modify', $context);
    
    my $result;
    eval {
        # Read file
        open my $fh, '<:utf8', $path or croak "Cannot read $path: $!";
        my @lines = <$fh>;
        close $fh;
        
        # Ensure content ends with newline if it doesn't already
        $content .= "\n" unless $content =~ /\n$/;
        
        # Insert at line (convert to 0-based index)
        splice @lines, $line_number - 1, 0, $content;
        
        # Write back using atomic write pattern
        my $mode = $self->_get_file_mode($path);
        my ($write_fh, $temp_path) = $self->_secure_open($path, $mode, $context);
        print $write_fh @lines;
        $self->_secure_close($write_fh, $temp_path, $path, $context);
        
        log_debug('FileOp', "Inserted content at line $line_number in $path");
        
        my $action_desc = "inserting at line $line_number in $path";
        
        $result = $self->success_result(
            "Content inserted successfully",
            action_description => $action_desc,
            path => $path,
            line_number => $line_number,
            total_lines => scalar(@lines),
        );
    };
    
    # Release lock if acquired
    $self->_release_file_lock($path, $context) if $lock_acquired;
    
    if ($@) {
        log_debug('FileOp', "Failed to insert at line: $@");
        return $self->error_result("Failed to insert at line: " . $self->_clean_eval_error($@));
    }
    
    return $result;
}

sub delete_file {
    my ($self, $params, $context) = @_;
    
    my $path = $self->_clean_path($params->{path});
    my $recursive = $params->{recursive} || 0;
    
    return $self->error_result("Missing required parameter: path") unless $path;
    
    # Sandbox check
    my $sandbox_check = $self->_check_sandbox($path, $context);
    return $self->error_result($sandbox_check->{error}) unless $sandbox_check->{allowed};
    
    return $self->error_result("Path not found: $path") unless -e $path;
    
    # Check authorization
    my $auth_result = $self->_check_write_authorization($path, 'delete_file', $context);
    if ($auth_result->{status} eq 'requires_authorization') {
        return $self->error_result(
            "Authorization required: $auth_result->{reason}\n\n" .
            "Use interact tool to request authorization."
        );
    } elsif ($auth_result->{status} eq 'denied') {
        return $self->error_result("Authorization denied: $auth_result->{reason}");
    }
    
    # Multi-agent coordination: Request file lock via broker
    my ($lock_acquired, $lock_error) = $self->_acquire_file_lock($path, $context);
    return $self->error_result($lock_error) if $lock_error;
    
    log_debug('FileOp', "Deleting: $path (recursive=$recursive, authorized: $auth_result->{reason})");
    
    # Vault: record deletion for undo support (backs up file content)
    $self->_vault_capture($path, 'delete', $context);
    
    my $result;
    eval {
        if (-d $path) {
            if ($recursive) {
                use File::Path qw(remove_tree);
                remove_tree($path) or croak "Cannot remove directory tree $path: $!";
            } else {
                rmdir $path or croak "Cannot remove directory $path: $! (use recursive=1 for non-empty dirs)";
            }
        } else {
            unlink $path or croak "Cannot delete file $path: $!";
        }
        
        log_debug('FileOp', "Deleted: $path");
        
        my $type = -d _ ? 'directory' : 'file';  # Use cached stat from -d check
        my $action_desc = $recursive ? "deleting $path recursively ($type)" : "deleting $path ($type)";
        
        $result = $self->success_result(
            "Deleted successfully",
            action_description => $action_desc,
            path => $path,
            recursive => $recursive,
        );
    };
    
    # Release lock if acquired
    $self->_release_file_lock($path, $context) if $lock_acquired;
    
    if ($@) {
        log_debug('FileOp', "Failed to delete: $@");
        return $self->error_result("Failed to delete: " . $self->_clean_eval_error($@));
    }
    
    return $result;
}

sub rename_file {
    my ($self, $params, $context) = @_;
    
    my $old_path = $self->_clean_path($params->{old_path});
    my $new_path = $self->_clean_path($params->{new_path});
    
    return $self->error_result("Missing required parameter: old_path") unless $old_path;
    return $self->error_result("Missing required parameter: new_path") unless $new_path;
    
    # Sandbox check for both paths
    my $sandbox_check = $self->_check_sandbox($old_path, $context);
    return $self->error_result($sandbox_check->{error}) unless $sandbox_check->{allowed};
    
    $sandbox_check = $self->_check_sandbox($new_path, $context);
    return $self->error_result($sandbox_check->{error}) unless $sandbox_check->{allowed};
    
    return $self->error_result("Source not found: $old_path") unless -e $old_path;
    return $self->error_result("Destination already exists: $new_path") if -e $new_path;
    
    # Check authorization for both paths
    my $auth_old = $self->_check_write_authorization($old_path, 'rename_file', $context);
    my $auth_new = $self->_check_write_authorization($new_path, 'rename_file', $context);
    
    if ($auth_old->{status} eq 'requires_authorization' || $auth_new->{status} eq 'requires_authorization') {
        my $reason = $auth_old->{status} eq 'requires_authorization' ? $auth_old->{reason} : $auth_new->{reason};
        return $self->error_result(
            "Authorization required: $reason\n\n" .
            "Use interact tool to request authorization."
        );
    }
    
    # Multi-agent coordination: Request file lock on source (old_path)
    my ($lock_acquired, $lock_error) = $self->_acquire_file_lock($old_path, $context);
    return $self->error_result($lock_error) if $lock_error;
    
    log_debug('FileOp', "Renaming: $old_path -> $new_path (authorized)");
    
    # Vault: record rename for undo support
    $self->_vault_capture($new_path, 'rename', $context, $old_path);
    
    my $result;
    eval {
        # Create parent directory for new path if needed
        my $dir = dirname($new_path);
        unless (-d $dir) {
            make_path($dir) or croak "Cannot create directory $dir: $!";
        }
        
        rename $old_path, $new_path or croak "Cannot rename $old_path to $new_path: $!";
        
        log_debug('FileOp', "Renamed: $old_path -> $new_path");
        
        my $action_desc = "renaming $old_path to $new_path";
        
        $result = $self->success_result(
            "Renamed successfully",
            action_description => $action_desc,
            old_path => $old_path,
            new_path => $new_path,
        );
    };
    
    # Release lock if acquired
    $self->_release_file_lock($old_path, $context) if $lock_acquired;
    
    if ($@) {
        log_debug('FileOp', "Failed to rename: $@");
        return $self->error_result("Failed to rename: " . $self->_clean_eval_error($@));
    }
    
    return $result;
}

sub create_directory {
    my ($self, $params, $context) = @_;
    
    my $path = $self->_clean_path($params->{path});
    
    return $self->error_result("Missing required parameter: path") unless $path;
    
    # Sandbox check
    my $sandbox_check = $self->_check_sandbox($path, $context);
    return $self->error_result($sandbox_check->{error}) unless $sandbox_check->{allowed};
    
    return $self->error_result("Directory already exists: $path") if -d $path;
    
    # Check authorization
    my $auth_result = $self->_check_write_authorization($path, 'create_directory', $context);
    if ($auth_result->{status} eq 'requires_authorization') {
        return $self->error_result(
            "Authorization required: $auth_result->{reason}\n\n" .
            "Use interact tool to request authorization."
        );
    } elsif ($auth_result->{status} eq 'denied') {
        return $self->error_result("Authorization denied: $auth_result->{reason}");
    }
    
    log_debug('FileOp', "Creating directory: $path (authorized: $auth_result->{reason})");
    
    my $result;
    eval {
        # Create directory with secure permissions
        $self->_secure_mkdir($path, 0700, $context);
        
        log_debug('FileOp', "Created directory: $path");
        
        my $action_desc = "creating directory $path";
        
        $result = $self->success_result(
            "Directory created successfully",
            action_description => $action_desc,
            path => $path,
        );
    };
    
    if ($@) {
        log_debug('FileOp', "Failed to create directory: $@");
        return $self->error_result("Failed to create directory: " . $self->_clean_eval_error($@));
    }
    
    return $result;
}

=head2 _scan_script_content

Scan file content for security-sensitive patterns when the file appears
to be a script (by extension or shebang line). Uses the CommandAnalyzer
to classify each significant line.

Returns undef if content is safe, or a hashref describing the concern:
  { requires_confirmation => 1, summary => $text, flags => [...] }

All flagged scripts route through user approval (via _prompt_script_confirmation
or the broker relay for sub-agents). The user always has final authority.

=cut

# Session-level grants for script writing
my %_script_write_grants;

sub _scan_script_content {
    my ($self, $path, $content, $context) = @_;

    return undef unless defined $content && length($content);

    # Determine if this file looks like a script
    my $is_script = 0;

    # Check extension
    if ($path =~ /\.(sh|bash|zsh|fish|py|pl|rb|js|ts|php|cgi|ps1|psm1|bat|cmd)$/i) {
        $is_script = 1;
    }

    # Check shebang line
    if ($content =~ /^#!\s*\//) {
        $is_script = 1;
    }

    # Check for Makefile (contains shell commands)
    if ($path =~ /(?:^|\/)(?:Makefile|makefile|GNUmakefile)$/) {
        $is_script = 1;
    }

    return undef unless $is_script;

    # Get security settings
    my $config = ($context && $context->{config}) ? $context->{config} : undef;
    my $sandbox = ($config && $config->get('sandbox')) ? 1 : 0;
    my $security_level = ($config) ? ($config->get('security_level') || 'standard') : 'standard';

    # In relaxed mode, don't scan scripts
    return undef if $security_level eq 'relaxed' && !$sandbox;

    # Check session grants
    return undef if $_script_write_grants{script_creation};

    # Scan each line for risky patterns
    my @all_flags;
    my %seen_categories;

    for my $line (split /\n/, $content) {
        # Skip comments and empty lines
        next if $line =~ /^\s*#/;
        next if $line =~ /^\s*$/;
        next if $line =~ /^\s*\/\//;  # JS/C++ comments

        my $analysis = analyze_command($line,
            sandbox        => $sandbox,
            security_level => $security_level,
        );

        if ($analysis->{risk_level} ne 'none') {
            for my $flag (@{$analysis->{flags}}) {
                unless ($seen_categories{$flag->{category}}) {
                    push @all_flags, $flag;
                    $seen_categories{$flag->{category}} = 1;
                }
            }
        }
    }

    return undef unless @all_flags;

    # Build summary
    my @descriptions = map { $_->{description} } @all_flags;
    my $has_blocked = grep { $_->{severity} eq 'critical' } @all_flags;
    my $summary = "Script contains: " . join('; ', @descriptions);

    # If any flag is marked as critical (e.g., destructive commands like
    # "rm -rf /"), we treat the script as blocked.  The caller can inspect
    # the `blocked` key to reject the write outright without prompting the
    # user for confirmation.
    my $result = {
        requires_confirmation => 1,
        summary                => $summary,
        flags                  => \@all_flags,
    };

    if ($has_blocked) {
        $result->{blocked} = 1;
    }

    return $result;
}

=head2 _prompt_script_confirmation

Prompt the user to approve writing a script with flagged content.

=cut

sub _prompt_script_confirmation {
    my ($self, $path, $scan_result, $context) = @_;

    my $ui = ($context && $context->{ui}) ? $context->{ui} : undef;

    unless ($ui && $ui->can('colorize')) {
        # No TTY - try broker relay for headless sub-agents
        my $broker = ($context && $context->{broker_client}) ? $context->{broker_client} : undef;
        if ($broker) {
            log_info('FileOp', "No TTY - relaying script authorization through broker");
            require CLIO::Security::AuthorizationRelay;
            my $relay = CLIO::Security::AuthorizationRelay->new(broker_client => $broker);
            if ($relay->available()) {
                my $result = $relay->request_script_authorization($path, $scan_result, $context);
                if ($result->{approved}) {
                    if ($result->{grant_type} eq 'session') {
                        $_script_write_grants{script_creation} = 1;
                        log_info('FileOp', "Session grant (via relay) for script creation");
                    }
                    return 1;
                }
                return 0;
            }
        }
        log_warning('FileOp', "No UI and no broker relay - denying script");
        return 0;
    }

    my $spinner = ($context && $context->{spinner}) ? $context->{spinner} : undef;
    $spinner->stop() if $spinner && $spinner->can('stop');

    # Use themed security prompt
    my $theme_mgr = $ui->{theme_mgr};
    if ($theme_mgr && $theme_mgr->can('get_security_prompt')) {
        my ($prompt_line, $input_line) = $theme_mgr->get_security_prompt(
            $path,
            $scan_result->{flags},
            '(y)es once | (a)llow scripts | (n)o deny',
        );
        print "\n$prompt_line\n$input_line";
    } else {
        # Build flag descriptions on one line
        my @flag_parts;
        for my $flag (@{$scan_result->{flags} || []}) {
            push @flag_parts, "[$flag->{severity}] $flag->{description}";
        }
        my $flags_str = join(" | ", @flag_parts);
        print "\n* Security | $path\n  $flags_str\n  (y)es once | (a)llow scripts | (n)o deny: ";
    }

    # Suspend ALRM handler - Chat.pm's 1-second timer calls ReadKey(-1)
    # which consumes keystrokes before <STDIN> can read them
    my $saved_alrm = $SIG{ALRM};
    my $remaining_alarm = alarm(0);

    require CLIO::Compat::Terminal;

    # Flush any buffered ReadKey input from cbreak mode
    while (defined(eval { CLIO::Compat::Terminal::ReadKey(-1) })) { }

    CLIO::Compat::Terminal::ReadMode(0);

    my $response = <STDIN>;
    chomp($response) if defined $response;
    $response = lc($response || 'n');

    CLIO::Compat::Terminal::ReadMode(1);

    # Restore ALRM handler
    $SIG{ALRM} = $saved_alrm || 'DEFAULT';
    alarm($remaining_alarm) if $remaining_alarm;

    $spinner->start() if $spinner && $spinner->can('start');

    if ($response eq 'y' || $response eq 'yes') {
        return 1;
    } elsif ($response eq 'a' || $response eq 'allow') {
        $_script_write_grants{script_creation} = 1;
        log_info('FileOp', "Session grant added for script creation");
        return 1;
    }

    return 0;
}

=head2 reset_script_session_grants

Reset script writing session grants. Called at session end.

=cut

sub reset_script_session_grants {
    %_script_write_grants = ();
}

=head2 _get_umask

Get the current umask for file/directory operations from config.

Returns: umask value as octal integer (e.g., 0022, 0077)

=cut

sub _get_umask {
    my ($self, $context) = @_;

    # Get from config if available
    if ($context && $context->{config}) {
        my $umask = $context->{config}->get('file_umask');
        return $umask if defined $umask;
    }

    # Fall back to process umask
    return umask();
}

=head2 _get_file_mode

Determine the appropriate permission mode for a file.

For existing files: preserves current permissions.
For new files: returns 0644 for regular files, 0755 for scripts.

Parameters:
  - path: File path
  - content: File content (used to detect scripts for new files)

Returns: Permission mode as octal integer

=cut

sub _get_file_mode {
    my ($self, $path, $content) = @_;

    # Existing file: preserve its current permissions
    if (-e $path) {
        my @stat = stat($path);
        if (@stat) {
            return $stat[2] & 07777;
        }
    }

    # New file: detect if it's a script
    my $is_script = 0;

    # Check extension
    if ($path =~ /\.(sh|bash|zsh|fish|py|pl|rb|cgi|ps1|bat|cmd)$/i) {
        $is_script = 1;
    }

    # Check shebang
    if (defined $content && $content =~ /^#!\s*\//) {
        $is_script = 1;
    }

    return $is_script ? 0755 : 0644;
}

=head2 _secure_open

Open a file for writing with secure permissions.
Uses atomic write pattern: write to temp file, then rename.

Parameters:
  - path: Target file path
  - mode: Permission mode for the file (use _get_file_mode to determine)
  - context: Context hashref with config

Returns: filehandle on success, croaks on failure

=cut

sub _secure_open {
    my ($self, $path, $mode, $context) = @_;

    $mode //= 0600;  # Default: owner read/write only

    my $dir = dirname($path);

    # Create temp file in same directory for atomic rename
    my $temp_path = "${path}.tmp.$$";

    # Open temp file
    open my $fh, '>:utf8', $temp_path
        or croak "Cannot create temp file $temp_path: $!";

    # Set permissions on temp file before writing sensitive content
    # Note: Perl's chmod works on the inode, affecting the file
    chmod($mode, $temp_path)
        or log_warning('FileOp', "Could not set permissions on temp file: $!");

    return ($fh, $temp_path);
}

=head2 _secure_close

Close a securely opened file with atomic rename.

Parameters:
  - fh: Filehandle to close
  - temp_path: Path to temp file
  - target_path: Final destination path
  - context: Context hashref with config

Returns: 1 on success, croaks on failure

=cut

sub _secure_close {
    my ($self, $fh, $temp_path, $target_path, $context) = @_;

    # Close the filehandle
    close $fh
        or croak "Error closing temp file $temp_path: $!";

    # Atomic rename (overwrites existing file)
    unless (rename($temp_path, $target_path)) {
        # Attempt to clean up temp file
        unlink($temp_path) if -e $temp_path;
        croak "Cannot rename $temp_path to $target_path: $!";
    }

    return 1;
}

=head2 _secure_mkdir

Create a directory with secure permissions.
Uses explicit mode rather than relying on umask.

Parameters:
  - path: Directory path to create
  - mode: Permission mode (default: 0700 for directories)
  - context: Context hashref with config

Returns: 1 on success, croaks on failure

=cut

sub _secure_mkdir {
    my ($self, $path, $mode, $context) = @_;

    $mode //= 0700;  # Default: owner only

    # Create directory with explicit mode
    # File::Path::make_path accepts mode parameter
    unless (-d $path) {
        make_path($path, { mode => $mode })
            or croak "Cannot create directory $path: $!";
    }

    return 1;
}

=head1 AUTHOR

CLIO Project

=head1 SEE ALSO

- CLIO::Tools::Tool - Base class

=cut

1;
