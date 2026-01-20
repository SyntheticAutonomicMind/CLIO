package CLIO::Tools::FileOperations;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use CLIO::Core::Logger qw(should_log);
use parent 'CLIO::Tools::Tool';
use File::Spec;
use File::Basename;
use File::Path qw(make_path);
use Cwd 'abs_path';
use Encode qw(decode);
use feature 'say';

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
-  Outside session directory: Requires user confirmation (future feature)

=== READ (5 operations) ===
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

=== SEARCH (4 operations) ===
-  file_search - Find files matching pattern
  Parameters: pattern (required), directory (optional, default: .)
  
-  grep_search - Search file contents with regex
  Parameters: query (required), pattern (optional), is_regex (optional)
  
-  semantic_search - AI-powered code search (placeholder for future)
  Parameters: query (required), scope (optional)

-  read_tool_result - Read persisted large tool results in chunks
  Parameters: toolCallId (required), offset (optional, default: 0), length (optional, default: 8192)
  When to use: Tool response contains [TOOL_RESULT_STORED] marker
  Purpose: Retrieve large results that exceed inline size limits (>8KB)

=== WRITE (8 operations) ===
-  create_file - Create new file with content
  Parameters: path (required), content (required)
  
-  write_file - Overwrite existing file
  Parameters: path (required), content (required)
  
-  append_file - Append content to file
  Parameters: path (required), content (required)
  
-  replace_string - Find and replace text in file
  Parameters: path (required), old_string (required), new_string (required)

-  multi_replace_string - Batch replace operations across multiple files
  Parameters: replacements (required, array of {path, old_string, new_string})
  Returns: Summary of all replacements performed
  
-  insert_at_line - Insert content at specific line number
  Parameters: path (required), line_number (required), content (required)
  
-  delete_file - Delete file or directory
  Parameters: path (required), recursive (optional, for directories)
  
-  rename_file - Rename or move file
  Parameters: old_path (required), new_path (required)
  
-  create_directory - Create directory (with parents)
  Parameters: path (required)
},
        supported_operations => [qw(
            read_file list_dir file_exists get_file_info get_errors
            file_search grep_search semantic_search read_tool_result
            create_file write_file append_file replace_string multi_replace_string
            insert_at_line delete_file rename_file create_directory
        )],
        %opts,
    );
    
    # Store session directory for authorization checks
    $self->{session_dir} = $opts{session_dir} || '';
    
    # Initialize PathAuthorizer (lazy load to avoid circular dependencies)
    $self->{path_authorizer} = undef;
    
    return $self;
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
            description => "File or directory path. Used by most operations. Can be relative or absolute.",
        },
        paths => {
            type => "array",
            items => { type => "string" },
            description => "Multiple file paths. Used by get_errors, multi_replace_string.",
        },
        
        # Read file parameters
        start_line => {
            type => "integer",
            description => "Starting line number for read_file (1-indexed, inclusive).",
        },
        end_line => {
            type => "integer",
            description => "Ending line number for read_file (inclusive).",
        },
        
        # List directory parameters
        recursive => {
            type => "boolean",
            description => "Whether to list directory contents recursively (list_dir).",
        },
        
        # Search parameters
        query => {
            type => "string",
            description => "Search query or pattern. Used by file_search, grep_search, semantic_search.",
        },
        pattern => {
            type => "string",
            description => "Glob pattern to filter files. Used by file_search, grep_search.",
        },
        is_regex => {
            type => "boolean",
            description => "Whether query is a regex pattern (grep_search).",
        },
        max_results => {
            type => "integer",
            description => "Maximum number of results to return from search.",
        },
        
        # Read tool result parameters (for chunked large results)
        toolCallId => {
            type => "string",
            description => "Tool call ID to retrieve stored result chunks. Used by read_tool_result.",
        },
        offset => {
            type => "integer",
            description => "Byte offset to start reading from (read_tool_result). Defaults to 0.",
        },
        length => {
            type => "integer",
            description => "Number of bytes to read (read_tool_result). Defaults to 8192.",
        },
        
        # Write parameters
        content => {
            type => "string",
            description => "File content to write. Used by create_file, write_file, append_file.",
        },
        old_string => {
            type => "string",
            description => "Text to find and replace (replace_string, multi_replace_string).",
        },
        new_string => {
            type => "string",
            description => "Replacement text (replace_string, multi_replace_string).",
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
            description => "Array of replacement operations (multi_replace_string).",
        },
        text => {
            type => "string",
            description => "Text to insert (insert_at_line).",
        },
        line => {
            type => "integer",
            description => "Line number to insert at (insert_at_line).",
        },
        
        # Rename parameters
        new_path => {
            type => "string",
            description => "New file path for rename_file operation.",
        },
    };
}

sub route_operation {
    my ($self, $operation, $params, $context) = @_;
    
    # Route to appropriate handler
    if ($operation eq 'read_file') {
        return $self->read_file($params, $context);
    } elsif ($operation eq 'list_dir') {
        return $self->list_dir($params, $context);
    } elsif ($operation eq 'file_exists') {
        return $self->file_exists($params, $context);
    } elsif ($operation eq 'get_file_info') {
        return $self->get_file_info($params, $context);
    } elsif ($operation eq 'get_errors') {
        return $self->get_errors($params, $context);
    } elsif ($operation eq 'file_search') {
        return $self->file_search($params, $context);
    } elsif ($operation eq 'grep_search') {
        return $self->grep_search($params, $context);
    } elsif ($operation eq 'semantic_search') {
        return $self->semantic_search($params, $context);
    } elsif ($operation eq 'read_tool_result') {
        return $self->read_tool_result($params, $context);
    } elsif ($operation eq 'create_file') {
        return $self->create_file($params, $context);
    } elsif ($operation eq 'write_file') {
        return $self->write_file($params, $context);
    } elsif ($operation eq 'append_file') {
        return $self->append_file($params, $context);
    } elsif ($operation eq 'replace_string') {
        return $self->replace_string($params, $context);
    } elsif ($operation eq 'multi_replace_string') {
        return $self->multi_replace_string($params, $context);
    } elsif ($operation eq 'insert_at_line') {
        return $self->insert_at_line($params, $context);
    } elsif ($operation eq 'delete_file') {
        return $self->delete_file($params, $context);
    } elsif ($operation eq 'rename_file') {
        return $self->rename_file($params, $context);
    } elsif ($operation eq 'create_directory') {
        return $self->create_directory($params, $context);
    }
    
    return $self->error_result("Operation not implemented: $operation");
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

sub _check_write_authorization {
    my ($self, $path, $operation, $context) = @_;
    
    my $session_id = $context->{session}->{id} || '';
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

#
# READ OPERATIONS
#

sub read_file {
    my ($self, $params, $context) = @_;
    
    my $path = $params->{path};
    my $start_line = $params->{start_line} || 1;
    my $end_line = $params->{end_line};
    
    # Validation
    return $self->error_result("Missing 'path' parameter") unless $path;
    return $self->error_result("File not found: $path") unless -f $path;
    return $self->error_result("File not readable: $path") unless -r $path;
    
    print STDERR "[DEBUG][FileOp] Reading file: $path (lines $start_line-" . ($end_line || 'EOF') . ")\n" 
        if $self->{debug};
    
    # Read file
    my $result;
    eval {
        # Open in raw mode first, then try to decode UTF-8 gracefully
        open my $fh, '<:raw', $path or die "Cannot open $path: $!";
        
        my @lines;
        if (defined $end_line) {
            # Read specific range
            while (<$fh>) {
                my $line_num = $.;
                last if $line_num > $end_line;
                
                # Decode UTF-8, replacing invalid bytes with � (replacement character)
                eval {
                    $_ = Encode::decode('UTF-8', $_, Encode::FB_CROAK);
                };
                if ($@) {
                    # Fallback: replace invalid UTF-8 with replacement character
                    $_ = Encode::decode('UTF-8', $_, Encode::FB_DEFAULT);
                }
                
                push @lines, $_ if $line_num >= $start_line;
            }
        } else {
            # Read from start_line to EOF
            while (<$fh>) {
                my $line_num = $.;
                
                # Decode UTF-8, replacing invalid bytes with � (replacement character)
                eval {
                    $_ = Encode::decode('UTF-8', $_, Encode::FB_CROAK);
                };
                if ($@) {
                    # Fallback: replace invalid UTF-8 with replacement character
                    $_ = Encode::decode('UTF-8', $_, Encode::FB_DEFAULT);
                }
                
                push @lines, $_ if $line_num >= $start_line;
            }
        }
        
        close $fh;
        
        my $content = join('', @lines);
        my $lines_read = scalar(@lines);
        
        print STDERR "[DEBUG][FileOp] Read $lines_read lines from $path\n" if should_log('DEBUG');
        
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
        print STDERR "[ERROR][FileOp] Failed to read $path: $@\n";
        return $self->error_result("Failed to read file: $@");
    }
    
    return $result;
}

sub list_dir {
    my ($self, $params, $context) = @_;
    
    my $path = $params->{path} || '.';
    my $recursive = $params->{recursive} || 0;
    
    # Validation
    return $self->error_result("Directory not found: $path") unless -d $path;
    return $self->error_result("Directory not readable: $path") unless -r $path;
    
    print STDERR "[DEBUG][FileOp] Listing directory: $path (recursive=$recursive)\n" if should_log('DEBUG');
    
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
            opendir my $dh, $path or die "Cannot open directory $path: $!";
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
        
        print STDERR "[DEBUG][FileOp] Listed " . scalar(@entries) . " entries\n" if $self->{debug};
        
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
        print STDERR "[ERROR][FileOp] Failed to list directory $path: $@\n";
        return $self->error_result("Failed to list directory: $@");
    }
    
    return $result;
}

sub file_exists {
    my ($self, $params, $context) = @_;
    
    my $path = $params->{path};
    
    return $self->error_result("Missing 'path' parameter") unless $path;
    
    print STDERR "[DEBUG][FileOp] Checking existence: $path\n" if should_log('DEBUG');
    
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
    
    my $path = $params->{path};
    
    return $self->error_result("Missing 'path' parameter") unless $path;
    return $self->error_result("File not found: $path") unless -e $path;
    
    print STDERR "[DEBUG][FileOp] Getting file info: $path\n" if should_log('DEBUG');
    
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
    
    my $action_desc = "getting info for $path ($info->{type}, " . $stat[7] . " bytes)";
    
    return $self->success_result($info, action_description => $action_desc);
}

sub get_errors {
    my ($self, $params, $context) = @_;
    
    my $path = $params->{path};
    
    return $self->error_result("Missing 'path' parameter") unless $path;
    return $self->error_result("File not found: $path") unless -f $path;
    
    print STDERR "[DEBUG][FileOp] Checking syntax: $path\n" if should_log('DEBUG');
    
    # Only works for Perl files
    unless ($path =~ /\.p[lm]$/) {
        my $action_desc = "checking syntax of $path (non-Perl, skipped)";
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
    my $directory = $params->{directory} || '.';
    
    return $self->error_result("Missing 'pattern' parameter") unless $pattern;
    return $self->error_result("Directory not found: $directory") unless -d $directory;
    
    print STDERR "[DEBUG][FileOp] Searching files: pattern=$pattern, dir=$directory\n" if should_log('DEBUG');
    
    my $result;
    eval {
        my @matches;
        
        # Convert glob pattern to regex
        my $regex = $pattern;
        $regex =~ s/\*\*/DOUBLESTAR/g;
        $regex =~ s/\*/[^\/]*/g;
        $regex =~ s/DOUBLESTAR/.*/g;
        $regex =~ s/\?/./g;
        
        use File::Find;
        find(sub {
            my $name = $File::Find::name;
            $name =~ s{^\./}{};  # Remove leading ./
            
            if ($name =~ /$regex/) {
                push @matches, {
                    path => $name,
                    type => -d $_ ? 'directory' : 'file',
                    size => -s $_,
                };
            }
        }, $directory);
        
        print STDERR "[DEBUG][FileOp] Found " . scalar(@matches) . " matches\n" if $self->{debug};
        
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
        print STDERR "[ERROR][FileOp] File search failed: $@\n";
        return $self->error_result("File search failed: $@");
    }
    
    return $result;
}

sub grep_search {
    my ($self, $params, $context) = @_;
    
    my $query = $params->{query};
    my $pattern = $params->{pattern} || '**/*';
    my $is_regex = $params->{is_regex} || 0;
    
    return $self->error_result("Missing 'query' parameter") unless $query;
    
    print STDERR "[DEBUG][FileOp] Grep search: query=$query, pattern=$pattern, regex=$is_regex\n" 
        if $self->{debug};
    
    my $result;
    eval {
        my @matches;
        
        # First, find files matching pattern
        my $file_result = $self->file_search({ pattern => $pattern }, $context);
        unless ($file_result->{success}) {
            $result = $file_result;
            return;
        }
        
        my @files = grep { $_->{type} eq 'file' } @{$file_result->{output}};
        
        # Search each file
        my $search_regex = $is_regex ? qr/$query/i : qr/\Q$query\E/i;
        
        foreach my $file (@files) {
            my $path = $file->{path};
            
            # Skip binary files
            next unless -T $path;
            
            # Open in raw mode and let Perl handle encoding gracefully
            my $fh;
            unless (open $fh, '<', $path) {
                print STDERR "[WARN][FileOp] Cannot open $path: $!\n" if $self->{debug};
                next;
            }
            
            my $line_num = 0;
            while (my $line = <$fh>) {
                $line_num++;
                
                # Regex matching is encoding-agnostic for ASCII queries
                if ($line =~ $search_regex) {
                    push @matches, {
                        path => $path,
                        line => $line_num,
                        content => $line,
                    };
                }
            }
            
            close $fh;
        }
        
        print STDERR "[DEBUG][FileOp] Found " . scalar(@matches) . " matches across " . 
                     scalar(@files) . " files\n" if $self->{debug};
        
        my $match_summary = scalar(@matches) . " matches in " . scalar(@files) . " files";
        my $action_desc = "searching for '$query' in $pattern ($match_summary)";
        
        $result = $self->success_result(
            \@matches,
            action_description => $action_desc,
            query => $query,
            pattern => $pattern,
            is_regex => $is_regex,
            match_count => scalar(@matches),
            files_searched => scalar(@files),
        );
    };
    
    if ($@) {
        print STDERR "[ERROR][FileOp] Grep search failed: $@\n";
        return $self->error_result("Grep search failed: $@");
    }
    
    return $result;
}

sub semantic_search {
    my ($self, $params, $context) = @_;
    
    my $query = $params->{query};
    my $scope = $params->{scope} || '.';
    
    return $self->error_result("Missing 'query' parameter") unless $query;
    
    print STDERR "[DEBUG][FileOp] Semantic search for: $query (scope: $scope)\n" if should_log('DEBUG');
    
    # Extract keywords from query (simple word splitting)
    my @keywords = grep { length($_) > 2 } split(/\W+/, lc($query));
    
    unless (@keywords) {
        return $self->error_result("No valid search keywords in query");
    }
    
    print STDERR "[DEBUG][FileOp] Keywords: " . join(', ', @keywords) . "\n" if should_log('DEBUG');
    
    # Use grep_search for each keyword
    my %file_scores = ();  # file => score
    my %file_matches = ();  # file => array of match lines
    
    foreach my $keyword (@keywords) {
        my $grep_result = $self->grep_search({
            query => $keyword,
            pattern => "$scope/**",
            is_regex => 0,
        }, $context);
        
        next unless $grep_result->{success} && $grep_result->{matches};
        
        foreach my $match (@{$grep_result->{matches}}) {
            my $file = $match->{file};
            
            # Score: number of keyword matches + position bonus
            $file_scores{$file} ||= 0;
            $file_scores{$file} += 1;
            
            # Boost score if keyword appears in file name
            if ($file =~ /\Q$keyword\E/i) {
                $file_scores{$file} += 2;
            }
            
            # Store match details
            $file_matches{$file} ||= [];
            push @{$file_matches{$file}}, $match;
        }
    }
    
    # Sort files by relevance score
    my @ranked_files = sort { $file_scores{$b} <=> $file_scores{$a} } keys %file_scores;
    
    my $result_count = scalar(@ranked_files);
    
    if ($result_count == 0) {
        return $self->success_result(
            "No files matched query '$query'",
            files => [],
            count => 0,
            keywords => \@keywords,
        );
    }
    
    # Build result with top N files (limit to 20 for readability)
    my $max_results = 20;
    @ranked_files = splice(@ranked_files, 0, $max_results) if @ranked_files > $max_results;
    
    my @results = ();
    foreach my $file (@ranked_files) {
        push @results, {
            file => $file,
            score => $file_scores{$file},
            matches => $file_matches{$file},
            match_count => scalar(@{$file_matches{$file}}),
        };
    }
    
    my $message = "Found $result_count files matching '$query'";
    $message .= " (showing top $max_results)" if $result_count > $max_results;
    
    print STDERR "[DEBUG][FileOp] Semantic search found $result_count files\n" if should_log('DEBUG');
    
    return $self->success_result(
        $message,
        files => \@results,
        count => $result_count,
        keywords => \@keywords,
    );
}

sub read_tool_result {
    my ($self, $params, $context) = @_;
    
    my $toolCallId = $params->{toolCallId} || $params->{tool_call_id};
    my $offset = $params->{offset} // 0;
    my $length = $params->{length} // 8192;
    
    # Validation
    return $self->error_result("Missing 'toolCallId' parameter") unless $toolCallId;
    
    if ($offset < 0) {
        return $self->error_result("offset must be >= 0");
    }
    
    if ($length <= 0) {
        return $self->error_result("length must be > 0");
    }
    
    # Enforce maximum chunk size (32KB like SAM)
    my $max_chunk_size = 32_768;
    if ($length > $max_chunk_size) {
        print STDERR "[WARN][FileOp] Requested length $length exceeds max $max_chunk_size, capping\n";
        $length = $max_chunk_size;
    }
    
    # Get session ID from context
    my $session_id = $context->{session}->{id};
    unless ($session_id) {
        return $self->error_result("No session ID in context. Cannot retrieve tool result.");
    }
    
    print STDERR "[DEBUG][FileOp] Reading tool result: toolCallId=$toolCallId, offset=$offset, length=$length\n" 
        if $self->{debug};
    
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
        
        # Parse error type
        if ($error =~ /not found/i) {
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
                "read_tool_result(toolCallId: \"$toolCallId\", offset: 0, length: $length)"
            );
        } else {
            return $self->error_result("Failed to retrieve tool result: $error");
        }
    }
    
    print STDERR "[DEBUG][FileOp] Retrieved chunk: offset=$chunk->{offset}, length=$chunk->{length}, hasMore=$chunk->{hasMore}\n" 
        if $self->{debug};
    
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
        push @lines, "read_tool_result(toolCallId: \"$chunk->{toolCallId}\", offset: $chunk->{nextOffset}, length: $length)";
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

sub create_file {
    my ($self, $params, $context) = @_;
    
    my $path = $params->{path};
    my $content = $params->{content};
    
    return $self->error_result("Missing 'path' parameter") unless $path;
    return $self->error_result("Missing 'content' parameter") unless defined $content;
    return $self->error_result("File already exists: $path") if -e $path;
    
    # Check authorization
    my $auth_result = $self->_check_write_authorization($path, 'create_file', $context);
    if ($auth_result->{status} eq 'requires_authorization') {
        return $self->error_result(
            "Authorization required: $auth_result->{reason}\n\n" .
            "This operation requires user permission because the path is outside the session directory.\n" .
            "Use user_collaboration tool to request authorization."
        );
    } elsif ($auth_result->{status} eq 'denied') {
        return $self->error_result("Authorization denied: $auth_result->{reason}");
    }
    
    print STDERR "[DEBUG][FileOp] Creating file: $path (authorized: $auth_result->{reason})\n" if should_log('DEBUG');
    
    my $result;
    eval {
        # Create parent directories if needed
        my $dir = dirname($path);
        unless (-d $dir) {
            make_path($dir) or die "Cannot create directory $dir: $!";
        }
        
        # Write file
        open my $fh, '>:utf8', $path or die "Cannot create $path: $!";
        print $fh $content;
        close $fh;
        
        my $size = -s $path;
        
        print STDERR "[DEBUG][FileOp] Created file $path ($size bytes)\n" if should_log('DEBUG');
        
        my $action_desc = "creating $path ($size bytes)";
        
        $result = $self->success_result(
            "File created successfully",
            action_description => $action_desc,
            path => $path,
            size => $size,
        );
    };
    
    if ($@) {
        print STDERR "[ERROR][FileOp] Failed to create file: $@\n";
        return $self->error_result("Failed to create file: $@");
    }
    
    return $result;
}

sub write_file {
    my ($self, $params, $context) = @_;
    
    my $path = $params->{path};
    my $content = $params->{content};
    
    return $self->error_result("Missing 'path' parameter") unless $path;
    return $self->error_result("Missing 'content' parameter") unless defined $content;
    return $self->error_result("File not found: $path") unless -f $path;
    
    # Check authorization
    my $auth_result = $self->_check_write_authorization($path, 'write_file', $context);
    if ($auth_result->{status} eq 'requires_authorization') {
        return $self->error_result(
            "Authorization required: $auth_result->{reason}\n\n" .
            "Use user_collaboration tool to request authorization."
        );
    } elsif ($auth_result->{status} eq 'denied') {
        return $self->error_result("Authorization denied: $auth_result->{reason}");
    }
    
    print STDERR "[DEBUG][FileOp] Writing file: $path (authorized: $auth_result->{reason})\n" if should_log('DEBUG');
    
    my $result;
    eval {
        open my $fh, '>:utf8', $path or die "Cannot write $path: $!";
        print $fh $content;
        close $fh;
        
        my $size = -s $path;
        
        print STDERR "[DEBUG][FileOp] Wrote file $path ($size bytes)\n" if should_log('DEBUG');
        
        my $action_desc = "writing $path ($size bytes)";
        
        $result = $self->success_result(
            "File written successfully",
            action_description => $action_desc,
            path => $path,
            size => $size,
        );
    };
    
    if ($@) {
        print STDERR "[ERROR][FileOp] Failed to write file: $@\n";
        return $self->error_result("Failed to write file: $@");
    }
    
    return $result;
}

sub append_file {
    my ($self, $params, $context) = @_;
    
    my $path = $params->{path};
    my $content = $params->{content};
    
    return $self->error_result("Missing 'path' parameter") unless $path;
    return $self->error_result("Missing 'content' parameter") unless defined $content;
    return $self->error_result("File not found: $path") unless -f $path;
    
    # Check authorization
    my $auth_result = $self->_check_write_authorization($path, 'append_file', $context);
    if ($auth_result->{status} eq 'requires_authorization') {
        return $self->error_result(
            "Authorization required: $auth_result->{reason}\n\n" .
            "Use user_collaboration tool to request authorization."
        );
    } elsif ($auth_result->{status} eq 'denied') {
        return $self->error_result("Authorization denied: $auth_result->{reason}");
    }
    
    print STDERR "[DEBUG][FileOp] Appending to file: $path (authorized: $auth_result->{reason})\n" if should_log('DEBUG');
    
    my $result;
    eval {
        open my $fh, '>>:utf8', $path or die "Cannot append to $path: $!";
        print $fh $content;
        close $fh;
        
        my $size = -s $path;
        
        print STDERR "[DEBUG][FileOp] Appended to file $path (new size: $size bytes)\n" if should_log('DEBUG');
        
        my $action_desc = "appending to $path (new size: $size bytes)";
        
        $result = $self->success_result(
            "Content appended successfully",
            action_description => $action_desc,
            path => $path,
            size => $size,
        );
    };
    
    if ($@) {
        print STDERR "[ERROR][FileOp] Failed to append to file: $@\n";
        return $self->error_result("Failed to append to file: $@");
    }
    
    return $result;
}

sub replace_string {
    my ($self, $params, $context) = @_;
    
    my $path = $params->{path};
    my $old_string = $params->{old_string};
    my $new_string = $params->{new_string};
    
    return $self->error_result("Missing 'path' parameter") unless $path;
    return $self->error_result("Missing 'old_string' parameter") unless defined $old_string;
    return $self->error_result("Missing 'new_string' parameter") unless defined $new_string;
    return $self->error_result("File not found: $path") unless -f $path;
    
    print STDERR "[DEBUG][FileOp] Replacing string in: $path\n" if should_log('DEBUG');
    
    my $result;
    eval {
        # Read file
        open my $fh, '<:utf8', $path or die "Cannot read $path: $!";
        my $content = do { local $/; <$fh> };
        close $fh;
        
        # Count occurrences
        my $count = 0;
        $count++ while $content =~ /\Q$old_string\E/g;
        
        if ($count == 0) {
            $result = $self->error_result("String not found in file");
            return;
        }
        
        # Replace
        $content =~ s/\Q$old_string\E/$new_string/g;
        
        # Write back
        open $fh, '>:utf8', $path or die "Cannot write $path: $!";
        print $fh $content;
        close $fh;
        
        print STDERR "[DEBUG][FileOp] Replaced $count occurrences in $path\n" if should_log('DEBUG');
        
        my $action_desc = "replacing string in $path ($count occurrences)";
        
        $result = $self->success_result(
            "Replaced $count occurrence(s) successfully",
            action_description => $action_desc,
            path => $path,
            replacements => $count,
        );
    };
    
    if ($@) {
        print STDERR "[ERROR][FileOp] Failed to replace string: $@\n";
        return $self->error_result("Failed to replace string: $@");
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
    
    return $self->error_result("Missing 'replacements' parameter") unless $replacements;
    return $self->error_result("'replacements' must be an array") unless ref($replacements) eq 'ARRAY';
    return $self->error_result("'replacements' array is empty") unless @$replacements > 0;
    
    print STDERR "[DEBUG][FileOp] Processing " . scalar(@$replacements) . " replacement operations\n" if should_log('DEBUG');
    
    my @successful = ();
    my @failed = ();
    my $total_replacements = 0;
    
    foreach my $i (0 .. $#$replacements) {
        my $rep = $replacements->[$i];
        my $idx = $i + 1;
        
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
                error => "Missing 'path' in replacement $idx"
            };
            next;
        }
        
        unless (defined $old_string) {
            push @failed, {
                index => $idx,
                path => $path,
                error => "Missing 'old_string' in replacement $idx"
            };
            next;
        }
        
        unless (defined $new_string) {
            push @failed, {
                index => $idx,
                path => $path,
                error => "Missing 'new_string' in replacement $idx"
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
    
    print STDERR "[DEBUG][FileOp] Completed: $success_count succeeded, $fail_count failed, $total_replacements total replacements\n" if should_log('DEBUG');
    
    # Build summary message
    my $message = "$success_count of $total_count operations succeeded ($total_replacements replacements)";
    
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
    
    my $path = $params->{path};
    my $line_number = $params->{line_number};
    my $content = $params->{content};
    
    return $self->error_result("Missing 'path' parameter") unless $path;
    return $self->error_result("Missing 'line_number' parameter") unless defined $line_number;
    return $self->error_result("Missing 'content' parameter") unless defined $content;
    return $self->error_result("File not found: $path") unless -f $path;
    return $self->error_result("Invalid line number") unless $line_number > 0;
    
    print STDERR "[DEBUG][FileOp] Inserting at line $line_number in: $path\n" if should_log('DEBUG');
    
    my $result;
    eval {
        # Read file
        open my $fh, '<:utf8', $path or die "Cannot read $path: $!";
        my @lines = <$fh>;
        close $fh;
        
        # Ensure content ends with newline if it doesn't already
        $content .= "\n" unless $content =~ /\n$/;
        
        # Insert at line (convert to 0-based index)
        splice @lines, $line_number - 1, 0, $content;
        
        # Write back
        open $fh, '>:utf8', $path or die "Cannot write $path: $!";
        print $fh @lines;
        close $fh;
        
        print STDERR "[DEBUG][FileOp] Inserted content at line $line_number in $path\n" if should_log('DEBUG');
        
        my $action_desc = "inserting at line $line_number in $path";
        
        $result = $self->success_result(
            "Content inserted successfully",
            action_description => $action_desc,
            path => $path,
            line_number => $line_number,
            total_lines => scalar(@lines),
        );
    };
    
    if ($@) {
        print STDERR "[ERROR][FileOp] Failed to insert at line: $@\n";
        return $self->error_result("Failed to insert at line: $@");
    }
    
    return $result;
}

sub delete_file {
    my ($self, $params, $context) = @_;
    
    my $path = $params->{path};
    my $recursive = $params->{recursive} || 0;
    
    return $self->error_result("Missing 'path' parameter") unless $path;
    return $self->error_result("Path not found: $path") unless -e $path;
    
    # Check authorization
    my $auth_result = $self->_check_write_authorization($path, 'delete_file', $context);
    if ($auth_result->{status} eq 'requires_authorization') {
        return $self->error_result(
            "Authorization required: $auth_result->{reason}\n\n" .
            "Use user_collaboration tool to request authorization."
        );
    } elsif ($auth_result->{status} eq 'denied') {
        return $self->error_result("Authorization denied: $auth_result->{reason}");
    }
    
    print STDERR "[DEBUG][FileOp] Deleting: $path (recursive=$recursive, authorized: $auth_result->{reason})\n" if should_log('DEBUG');
    
    my $result;
    eval {
        if (-d $path) {
            if ($recursive) {
                use File::Path qw(remove_tree);
                remove_tree($path) or die "Cannot remove directory tree $path: $!";
            } else {
                rmdir $path or die "Cannot remove directory $path: $! (use recursive=1 for non-empty dirs)";
            }
        } else {
            unlink $path or die "Cannot delete file $path: $!";
        }
        
        print STDERR "[DEBUG][FileOp] Deleted: $path\n" if should_log('DEBUG');
        
        my $type = -d _ ? 'directory' : 'file';  # Use cached stat from -d check
        my $action_desc = $recursive ? "deleting $path recursively ($type)" : "deleting $path ($type)";
        
        $result = $self->success_result(
            "Deleted successfully",
            action_description => $action_desc,
            path => $path,
            recursive => $recursive,
        );
    };
    
    if ($@) {
        print STDERR "[ERROR][FileOp] Failed to delete: $@\n";
        return $self->error_result("Failed to delete: $@");
    }
    
    return $result;
}

sub rename_file {
    my ($self, $params, $context) = @_;
    
    my $old_path = $params->{old_path};
    my $new_path = $params->{new_path};
    
    return $self->error_result("Missing 'old_path' parameter") unless $old_path;
    return $self->error_result("Missing 'new_path' parameter") unless $new_path;
    return $self->error_result("Source not found: $old_path") unless -e $old_path;
    return $self->error_result("Destination already exists: $new_path") if -e $new_path;
    
    # Check authorization for both paths
    my $auth_old = $self->_check_write_authorization($old_path, 'rename_file', $context);
    my $auth_new = $self->_check_write_authorization($new_path, 'rename_file', $context);
    
    if ($auth_old->{status} eq 'requires_authorization' || $auth_new->{status} eq 'requires_authorization') {
        my $reason = $auth_old->{status} eq 'requires_authorization' ? $auth_old->{reason} : $auth_new->{reason};
        return $self->error_result(
            "Authorization required: $reason\n\n" .
            "Use user_collaboration tool to request authorization."
        );
    }
    
    print STDERR "[DEBUG][FileOp] Renaming: $old_path -> $new_path (authorized)\n" if should_log('DEBUG');
    
    my $result;
    eval {
        # Create parent directory for new path if needed
        my $dir = dirname($new_path);
        unless (-d $dir) {
            make_path($dir) or die "Cannot create directory $dir: $!";
        }
        
        rename $old_path, $new_path or die "Cannot rename $old_path to $new_path: $!";
        
        print STDERR "[DEBUG][FileOp] Renamed: $old_path -> $new_path\n" if should_log('DEBUG');
        
        my $action_desc = "renaming $old_path to $new_path";
        
        $result = $self->success_result(
            "Renamed successfully",
            action_description => $action_desc,
            old_path => $old_path,
            new_path => $new_path,
        );
    };
    
    if ($@) {
        print STDERR "[ERROR][FileOp] Failed to rename: $@\n";
        return $self->error_result("Failed to rename: $@");
    }
    
    return $result;
}

sub create_directory {
    my ($self, $params, $context) = @_;
    
    my $path = $params->{path};
    
    return $self->error_result("Missing 'path' parameter") unless $path;
    return $self->error_result("Directory already exists: $path") if -d $path;
    
    # Check authorization
    my $auth_result = $self->_check_write_authorization($path, 'create_directory', $context);
    if ($auth_result->{status} eq 'requires_authorization') {
        return $self->error_result(
            "Authorization required: $auth_result->{reason}\n\n" .
            "Use user_collaboration tool to request authorization."
        );
    } elsif ($auth_result->{status} eq 'denied') {
        return $self->error_result("Authorization denied: $auth_result->{reason}");
    }
    
    print STDERR "[DEBUG][FileOp] Creating directory: $path (authorized: $auth_result->{reason})\n" if should_log('DEBUG');
    
    my $result;
    eval {
        make_path($path) or die "Cannot create directory $path: $!";
        
        print STDERR "[DEBUG][FileOp] Created directory: $path\n" if should_log('DEBUG');
        
        my $action_desc = "creating directory $path";
        
        $result = $self->success_result(
            "Directory created successfully",
            action_description => $action_desc,
            path => $path,
        );
    };
    
    if ($@) {
        print STDERR "[ERROR][FileOp] Failed to create directory: $@\n";
        return $self->error_result("Failed to create directory: $@");
    }
    
    return $result;
}

1;

__END__

=head1 MIGRATION FROM CLIO::Protocols::FileOp

This tool completely replaces CLIO::Protocols::FileOp with a cleaner,
more comprehensive API:

Old Protocol Format:
  [FILE_OP:action:path=<base64>:content=<base64>]

New Tool Format:
  {
    "tool": "file_operations",
    "operation": "read_file",
    "path": "/path/to/file"
  }

Benefits:
- No base64 encoding required
- Clear parameter names
- Better error messages
- 16 operations vs 4
- Consistent result format
- Extensible design

=head1 AUTHOR

CLIO Project

=head1 SEE ALSO

- CLIO::Tools::Tool - Base class
- IMPLEMENTATION_PLAN_SAM_PATTERNS.md - Implementation roadmap
- ai-assisted/SAM_ANALYSIS.md - SAM pattern analysis

=cut
