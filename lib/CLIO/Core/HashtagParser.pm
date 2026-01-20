package CLIO::Core::HashtagParser;

use strict;
use warnings;
use feature 'say';
use File::Basename;
use File::Spec;
use Cwd 'abs_path';
use CLIO::Memory::TokenEstimator;

=head1 NAME

CLIO::Core::HashtagParser - Parse and resolve hashtag variables in user input

=head1 DESCRIPTION

Parses hashtag variables (like #file, #codebase, #selection) in user input
and resolves them to actual content for context injection into AI prompts.

Implements the CLIO Hashtag System Specification with token budget enforcement
to prevent context window overflow (matching VS Code Copilot Chat behavior).

=head1 SYNOPSIS

    my $parser = CLIO::Core::HashtagParser->new(
        session => $session,
        config => $config,
        debug => 1
    );
    
    # Parse input for hashtags
    my $tags = $parser->parse("Explain #file:lib/CLIO/UI/Chat.pm");
    
    # Resolve hashtags to context
    my $context = $parser->resolve($tags);
    
    # Get formatted context for AI prompt
    my $prompt_addition = $parser->format_context($context);

=cut

# Token budget constants (matching VS Code Copilot Chat)
use constant {
    MAX_TOKENS_PER_FILE => 8_000,   # Maximum tokens for a single file
    MAX_TOTAL_TOKENS => 32_000,     # Maximum total tokens for all hashtag context
    TRUNCATE_HEAD_LINES => 50,      # Lines to keep from start when truncating
    TRUNCATE_TAIL_LINES => 50,      # Lines to keep from end when truncating
};

sub new {
    my ($class, %opts) = @_;
    
    my $self = {
        session => $opts{session},
        config => $opts{config},
        debug => $opts{debug} || 0,
        max_file_size => $opts{max_file_size} || 1_000_000,  # 1MB default (byte limit)
        max_total_size => $opts{max_total_size} || 10_000_000, # 10MB default (byte limit)
        max_tokens_per_file => $opts{max_tokens_per_file} || MAX_TOKENS_PER_FILE,
        max_total_tokens => $opts{max_total_tokens} || MAX_TOTAL_TOKENS,
        total_tokens_used => 0,  # Track tokens as we add context
        truncated_items => [],   # Track what was truncated for user feedback
    };
    
    return bless $self, $class;
}

=head2 parse

Parse user input and extract all hashtag variables.

Arguments:
    $input - User input string

Returns:
    Arrayref of hashtag objects: [
        {
            type => 'file',
            value => 'path/to/file.pm',
            raw => '#file:path/to/file.pm',
            position => 15
        },
        ...
    ]

=cut

sub parse {
    my ($self, $input) = @_;
    
    return [] unless $input;
    
    my @tags;
    
    # Track position for ordering
    my $pos = 0;
    
    # Parse #file:path
    while ($input =~ /#file:([^\s#]+)/g) {
        push @tags, {
            type => 'file',
            value => $1,
            raw => $&,
            position => pos($input) - length($&)
        };
        print STDERR "[DEBUG][HashtagParser] Found #file:$1\n" if $self->{debug};
    }
    
    # Parse #folder:path
    while ($input =~ /#folder:([^\s#]+)/g) {
        push @tags, {
            type => 'folder',
            value => $1,
            raw => $&,
            position => pos($input) - length($&)
        };
        print STDERR "[DEBUG][HashtagParser] Found #folder:$1\n" if $self->{debug};
    }
    
    # Parse #codebase (no argument)
    if ($input =~ /#codebase\b/) {
        push @tags, {
            type => 'codebase',
            value => undef,
            raw => '#codebase',
            position => $-[0]
        };
        print STDERR "[DEBUG][HashtagParser] Found #codebase\n" if $self->{debug};
    }
    
    # Parse #selection (no argument)
    if ($input =~ /#selection\b/) {
        push @tags, {
            type => 'selection',
            value => undef,
            raw => '#selection',
            position => $-[0]
        };
        print STDERR "[DEBUG][HashtagParser] Found #selection\n" if $self->{debug};
    }
    
    # Parse #terminalLastCommand (no argument)
    if ($input =~ /#terminalLastCommand\b/) {
        push @tags, {
            type => 'terminalLastCommand',
            value => undef,
            raw => '#terminalLastCommand',
            position => $-[0]
        };
        print STDERR "[DEBUG][HashtagParser] Found #terminalLastCommand\n" if $self->{debug};
    }
    
    # Parse #terminalSelection (no argument)
    if ($input =~ /#terminalSelection\b/) {
        push @tags, {
            type => 'terminalSelection',
            value => undef,
            raw => '#terminalSelection',
            position => $-[0]
        };
        print STDERR "[DEBUG][HashtagParser] Found #terminalSelection\n" if $self->{debug};
    }
    
    # Sort by position to maintain order
    @tags = sort { $a->{position} <=> $b->{position} } @tags;
    
    print STDERR "[DEBUG][HashtagParser] Parsed " . scalar(@tags) . " hashtags\n" if $self->{debug};
    
    return \@tags;
}

=head2 resolve

Resolve parsed hashtags to actual content with token budget enforcement.

Implements token budgets matching VS Code Copilot Chat:
- MAX_TOKENS_PER_FILE: 8,000 tokens per file
- MAX_TOTAL_TOKENS: 32,000 tokens total for all hashtag context

Large files are truncated (head + tail) rather than excluded entirely.

Arguments:
    $tags - Arrayref of hashtag objects from parse()

Returns:
    Arrayref of context objects with token tracking

=cut

sub resolve {
    my ($self, $tags) = @_;
    
    return [] unless $tags && @$tags;
    
    # Reset token tracking
    $self->{total_tokens_used} = 0;
    $self->{truncated_items} = [];
    
    my @context;
    my $total_size = 0;
    
    for my $tag (@$tags) {
        print STDERR "[DEBUG][HashtagParser] Resolving $tag->{type}\n" if $self->{debug};
        
        my $result;
        
        if ($tag->{type} eq 'file') {
            $result = $self->resolve_file($tag->{value});
        }
        elsif ($tag->{type} eq 'folder') {
            $result = $self->resolve_folder($tag->{value});
        }
        elsif ($tag->{type} eq 'codebase') {
            $result = $self->resolve_codebase();
        }
        elsif ($tag->{type} eq 'selection') {
            $result = $self->resolve_selection();
        }
        elsif ($tag->{type} eq 'terminalLastCommand') {
            $result = $self->resolve_terminal_last_command();
        }
        elsif ($tag->{type} eq 'terminalSelection') {
            $result = $self->resolve_terminal_selection();
        }
        else {
            print STDERR "[WARN]HashtagParser] Unknown hashtag type: $tag->{type}\n";
            next;
        }
        
        if ($result) {
            # Check byte size limits first (fast check)
            my $size = $result->{size} || 0;
            if ($size > $self->{max_file_size}) {
                print STDERR "[WARN]HashtagParser] Content too large: $size bytes (max $self->{max_file_size})\n";
                $result->{error} = "Content exceeds size limit ($size bytes)";
                $result->{content} = "[Content too large to include]";
                push @context, $result;
                next;
            }
            
            if ($total_size + $size > $self->{max_total_size}) {
                print STDERR "[WARN]HashtagParser] Total context too large: would be " . ($total_size + $size) . " bytes\n";
                $result->{error} = "Would exceed total context limit";
                $result->{content} = "[Skipped due to context limit]";
                push @context, $result;
                next;
            }
            
            # Estimate tokens for this content
            my $tokens = CLIO::Memory::TokenEstimator::estimate_tokens($result->{content} || '');
            $result->{estimated_tokens} = $tokens;
            
            print STDERR "[DEBUG][HashtagParser] Content tokens: $tokens (current total: $self->{total_tokens_used})\n" 
                if $self->{debug};
            
            # Check if this single item exceeds per-file token limit
            if ($tokens > $self->{max_tokens_per_file}) {
                print STDERR "[WARN]HashtagParser] Content exceeds per-file token limit: $tokens > $self->{max_tokens_per_file}\n";
                # Truncate the content
                $result = $self->truncate_content($result, $self->{max_tokens_per_file});
                $tokens = $result->{estimated_tokens};
            }
            
            # Check if adding this would exceed total token budget
            if ($self->{total_tokens_used} + $tokens > $self->{max_total_tokens}) {
                my $remaining = $self->{max_total_tokens} - $self->{total_tokens_used};
                
                if ($remaining > 1000) {  # If we have at least 1K tokens left, include truncated version
                    print STDERR "[WARN]HashtagParser] Would exceed total token budget, truncating to fit ($remaining tokens remaining)\n";
                    $result = $self->truncate_content($result, $remaining);
                    $tokens = $result->{estimated_tokens};
                } else {
                    # Not enough budget left - skip this item entirely
                    print STDERR "[WARN]HashtagParser] Insufficient token budget remaining: $remaining tokens\n";
                    $result->{error} = "Skipped - insufficient token budget";
                    $result->{content} = "[Skipped due to token budget]";
                    $result->{estimated_tokens} = 0;
                    push @context, $result;
                    next;
                }
            }
            
            # Add to running totals
            $self->{total_tokens_used} += $tokens;
            $total_size += $size;
            
            push @context, $result;
        }
    }
    
    print STDERR "[DEBUG][HashtagParser] Resolved " . scalar(@context) . " items\n" if $self->{debug};
    print STDERR "[DEBUG][HashtagParser] Total: $total_size bytes, $self->{total_tokens_used} tokens\n" if $self->{debug};
    
    if (@{$self->{truncated_items}}) {
        print STDERR "[INFO][HashtagParser] Truncated " . scalar(@{$self->{truncated_items}}) . " items to fit token budget\n";
    }
    
    return \@context;
}

=head2 truncate_content

Truncate content to fit within a token budget.

For files: Keeps beginning and end, truncates middle with marker.
For other content: Truncates from end with marker.

Arguments:
    $result - Content hash from resolve_*
    $max_tokens - Maximum tokens allowed

Returns:
    Modified result hash with truncated content

=cut

sub truncate_content {
    my ($self, $result, $max_tokens) = @_;
    
    my $content = $result->{content} || '';
    my $original_tokens = CLIO::Memory::TokenEstimator::estimate_tokens($content);
    
    # Already within limit
    return $result if $original_tokens <= $max_tokens;
    
    my $type = $result->{type} || 'unknown';
    my $path = $result->{path} || $result->{raw} || 'content';
    
    print STDERR "[DEBUG][HashtagParser] Truncating $type content: $original_tokens → $max_tokens tokens\n" 
        if $self->{debug};
    
    # Track truncation for user feedback
    push @{$self->{truncated_items}}, {
        type => $type,
        path => $path,
        original_tokens => $original_tokens,
        truncated_tokens => $max_tokens
    };
    
    # For file content, use head + tail strategy
    if ($type eq 'file' && $content =~ /\n/) {
        my @lines = split /\n/, $content;
        my $total_lines = scalar(@lines);
        
        # Calculate how many lines we can keep
        my $target_chars = int($max_tokens * 4);  # Rough conversion
        my $head_lines = TRUNCATE_HEAD_LINES;
        my $tail_lines = TRUNCATE_TAIL_LINES;
        
        # Ensure we don't try to keep more lines than exist
        if ($head_lines + $tail_lines >= $total_lines) {
            # Just truncate from the end
            my $truncated = CLIO::Memory::TokenEstimator::truncate($content, $max_tokens);
            $result->{content} = $truncated;
            $result->{estimated_tokens} = CLIO::Memory::TokenEstimator::estimate_tokens($truncated);
            $result->{truncated} = 1;
            return $result;
        }
        
        # Keep head and tail
        my @head = @lines[0 .. $head_lines - 1];
        my @tail = @lines[-$tail_lines .. -1];
        my $omitted = $total_lines - $head_lines - $tail_lines;
        
        my $truncated = join("\n", @head) . 
                       "\n\n... ($omitted lines omitted to fit token budget) ...\n\n" .
                       join("\n", @tail);
        
        $result->{content} = $truncated;
        $result->{estimated_tokens} = CLIO::Memory::TokenEstimator::estimate_tokens($truncated);
        $result->{truncated} = 1;
        $result->{truncation_note} = "Showing first $head_lines and last $tail_lines lines ($omitted lines omitted)";
        
        return $result;
    }
    
    # For non-file content, use simple truncation
    my $truncated = CLIO::Memory::TokenEstimator::truncate($content, $max_tokens);
    $result->{content} = $truncated;
    $result->{estimated_tokens} = CLIO::Memory::TokenEstimator::estimate_tokens($truncated);
    $result->{truncated} = 1;
    
    return $result;
}

=head2 resolve_file

Resolve #file:path to file content.

Arguments:
    $path - File path (relative or absolute)

Returns:
    Hashref with file content and metadata

=cut

sub resolve_file {
    my ($self, $path) = @_;
    
    return undef unless $path;
    
    # Resolve relative paths
    unless (File::Spec->file_name_is_absolute($path)) {
        # Try relative to current directory
        if (-f $path) {
            $path = abs_path($path);
        }
        # Try relative to session working directory
        elsif ($self->{session} && $self->{session}->{working_directory}) {
            my $session_path = File::Spec->catfile($self->{session}->{working_directory}, $path);
            if (-f $session_path) {
                $path = abs_path($session_path);
            }
        }
    }
    
    # Check if file exists and is readable
    unless (-f $path && -r $path) {
        print STDERR "[WARN]HashtagParser] File not found or not readable: $path\n";
        return {
            type => 'file',
            path => $path,
            error => 'File not found or not readable',
            content => "[File not found: $path]",
            size => 0
        };
    }
    
    # Read file content
    my $content;
    if (open my $fh, '<:encoding(UTF-8)', $path) {
        local $/;
        $content = <$fh>;
        close $fh;
    }
    else {
        print STDERR "[ERROR][HashtagParser] Failed to read file $path: $!\n";
        return {
            type => 'file',
            path => $path,
            error => "Failed to read: $!",
            content => "[Error reading file: $!]",
            size => 0
        };
    }
    
    my $size = length($content);
    my $line_count = ($content =~ tr/\n//) + 1;
    my $basename = basename($path);
    
    print STDERR "[DEBUG][HashtagParser] Read file: $path ($size bytes, $line_count lines)\n" if $self->{debug};
    
    return {
        type => 'file',
        path => $path,
        basename => $basename,
        content => $content,
        size => $size,
        line_count => $line_count
    };
}

=head2 resolve_folder

Resolve #folder:path to folder listing and files.

Arguments:
    $path - Folder path (relative or absolute)

Returns:
    Hashref with folder structure and file contents

=cut

sub resolve_folder {
    my ($self, $path) = @_;
    
    return undef unless $path;
    
    # Resolve relative paths
    unless (File::Spec->file_name_is_absolute($path)) {
        if (-d $path) {
            $path = abs_path($path);
        }
        elsif ($self->{session} && $self->{session}->{working_directory}) {
            my $session_path = File::Spec->catfile($self->{session}->{working_directory}, $path);
            if (-d $session_path) {
                $path = abs_path($session_path);
            }
        }
    }
    
    unless (-d $path && -r $path) {
        print STDERR "[WARN]HashtagParser] Folder not found or not readable: $path\n";
        return {
            type => 'folder',
            path => $path,
            error => 'Folder not found or not readable',
            content => "[Folder not found: $path]",
            size => 0
        };
    }
    
    # Get folder structure (non-recursive for now)
    my @files;
    my $total_size = 0;
    
    if (opendir my $dh, $path) {
        my @entries = grep { !/^\.\.?$/ } readdir($dh);
        closedir $dh;
        
        for my $entry (sort @entries) {
            my $fullpath = File::Spec->catfile($path, $entry);
            if (-f $fullpath) {
                my $size = -s $fullpath;
                push @files, {
                    name => $entry,
                    path => $fullpath,
                    size => $size,
                    type => 'file'
                };
                $total_size += $size;
            }
            elsif (-d $fullpath) {
                push @files, {
                    name => $entry,
                    path => $fullpath,
                    type => 'directory'
                };
            }
        }
    }
    
    # Build content summary
    my $content = "Folder: $path\n";
    $content .= "Files: " . scalar(grep { $_->{type} eq 'file' } @files) . "\n";
    $content .= "Directories: " . scalar(grep { $_->{type} eq 'directory' } @files) . "\n\n";
    $content .= "Contents:\n";
    
    for my $file (@files) {
        if ($file->{type} eq 'file') {
            $content .= "  - $file->{name} ($file->{size} bytes)\n";
        }
        else {
            $content .= "  - $file->{name}/\n";
        }
    }
    
    print STDERR "[DEBUG][HashtagParser] Read folder: $path (" . scalar(@files) . " entries)\n" if $self->{debug};
    
    return {
        type => 'folder',
        path => $path,
        content => $content,
        files => \@files,
        size => length($content),
        total_size => $total_size
    };
}

=head2 resolve_codebase

Resolve #codebase to entire project structure.

Returns:
    Hashref with codebase summary and structure

=cut

sub resolve_codebase {
    my ($self) = @_;
    
    # Get working directory
    my $base_dir = $self->{session}->{working_directory} || '.';
    
    print STDERR "[DEBUG][HashtagParser] Resolving codebase from: $base_dir\n" if $self->{debug};
    
    # Build a concise codebase summary using RepoMap protocol
    my $content = "Codebase Overview\n";
    $content .= "=================\n\n";
    $content .= "Working Directory: $base_dir\n\n";
    
    # Get directory structure using RepoMap
    eval {
        require CLIO::Protocols::RepoMap;
        my $repomap = CLIO::Protocols::RepoMap->new();
        
        # Get structure with limited depth to keep it concise
        my $result = $repomap->handle({
            action => 'structure',
            max_depth => 3,  # Limit depth to keep output manageable
            file_details => 0,  # Don't include detailed file info
            include_hidden => 0  # Skip hidden files/dirs
        });
        
        if ($result && $result->{success} && $result->{data}) {
            $content .= "Directory Structure:\n";
            $content .= $self->_format_structure($result->{data}->{structure}, 0);
            $content .= "\n";
            
            # Add summary stats if available
            if ($result->{data}->{summary}) {
                my $summary = $result->{data}->{summary};
                $content .= "Summary:\n";
                $content .= "  Total Files: " . ($summary->{total_files} || 0) . "\n";
                $content .= "  Total Directories: " . ($summary->{total_dirs} || 0) . "\n";
                $content .= "  Total Size: " . ($summary->{total_size} || 0) . " bytes\n";
                $content .= "\n";
            }
        }
    };
    if ($@) {
        print STDERR "[WARN]HashtagParser] Failed to get repo structure: $@\n";
        $content .= "[Unable to generate structure - RepoMap protocol error]\n\n";
    }
    
    $content .= "Note: For specific files, use #file:path\n";
    $content .= "Note: For specific directories, use #folder:path\n";
    
    return {
        type => 'codebase',
        path => $base_dir,
        content => $content,
        size => length($content)
    };
}

=head2 _format_structure

Format directory structure for display.

Arguments:
    $structure - Structure hash from RepoMap
    $indent - Current indentation level

Returns:
    Formatted string

=cut

sub _format_structure {
    my ($self, $structure, $indent) = @_;
    
    return '' unless $structure && ref($structure) eq 'HASH';
    
    my $output = '';
    my $prefix = '  ' x $indent;
    
    # Handle directory name
    if ($structure->{name}) {
        $output .= $prefix . $structure->{name};
        $output .= '/' if $structure->{type} && $structure->{type} eq 'directory';
        $output .= "\n";
    }
    
    # Handle children
    if ($structure->{children} && ref($structure->{children}) eq 'ARRAY') {
        for my $child (@{$structure->{children}}) {
            $output .= $self->_format_structure($child, $indent + 1);
        }
    }
    
    # Handle files
    if ($structure->{files} && ref($structure->{files}) eq 'ARRAY') {
        for my $file (@{$structure->{files}}) {
            if (ref($file) eq 'HASH') {
                $output .= $prefix . '  ' . ($file->{name} || $file) . "\n";
            }
            else {
                $output .= $prefix . '  ' . $file . "\n";
            }
        }
    }
    
    return $output;
}

=head2 resolve_selection

Resolve #selection to currently selected text.

Returns:
    Hashref with selection content

=cut

sub resolve_selection {
    my ($self) = @_;
    
    # Check session for selection
    my $selection = $self->{session}->{selection} || '';
    
    if ($selection) {
        print STDERR "[DEBUG][HashtagParser] Resolved selection: " . length($selection) . " bytes\n" if $self->{debug};
        
        return {
            type => 'selection',
            content => $selection,
            size => length($selection)
        };
    }
    
    return {
        type => 'selection',
        content => "[No text currently selected]",
        size => 0,
        note => 'No selection available'
    };
}

=head2 resolve_terminal_last_command

Resolve #terminalLastCommand to last terminal command.

Returns:
    Hashref with last command and output

=cut

sub resolve_terminal_last_command {
    my ($self) = @_;
    
    # Check session for terminal history
    my $last_cmd = $self->{session}->{terminal_last_command} || '';
    my $last_output = $self->{session}->{terminal_last_output} || '';
    
    if ($last_cmd) {
        my $content = "Last Terminal Command:\n\$ $last_cmd\n\n";
        if ($last_output) {
            $content .= "Output:\n$last_output\n";
        }
        
        print STDERR "[DEBUG][HashtagParser] Resolved terminal last command\n" if $self->{debug};
        
        return {
            type => 'terminalLastCommand',
            command => $last_cmd,
            output => $last_output,
            content => $content,
            size => length($content)
        };
    }
    
    return {
        type => 'terminalLastCommand',
        content => "[No terminal command history available]",
        size => 0,
        note => 'No terminal history'
    };
}

=head2 resolve_terminal_selection

Resolve #terminalSelection to selected terminal text.

Returns:
    Hashref with terminal selection

=cut

sub resolve_terminal_selection {
    my ($self) = @_;
    
    # Check session for terminal selection
    my $selection = $self->{session}->{terminal_selection} || '';
    
    if ($selection) {
        print STDERR "[DEBUG][HashtagParser] Resolved terminal selection: " . length($selection) . " bytes\n" if $self->{debug};
        
        return {
            type => 'terminalSelection',
            content => $selection,
            size => length($selection)
        };
    }
    
    return {
        type => 'terminalSelection',
        content => "[No terminal text currently selected]",
        size => 0,
        note => 'No terminal selection'
    };
}

=head2 format_context

Format resolved context for inclusion in AI prompt.

Includes truncation warnings if any content was truncated to fit token budgets.

Arguments:
    $context - Arrayref of resolved context objects

Returns:
    String formatted for prompt injection

=cut

sub format_context {
    my ($self, $context) = @_;
    
    return '' unless $context && @$context;
    
    my $output = "\n--- Context from Hashtags ---\n";
    
    # Add token budget info if items were truncated
    if (@{$self->{truncated_items}}) {
        $output .= "\n⚠️  Note: Some content was truncated to fit token budget (max " . 
                   $self->{max_total_tokens} . " tokens total)\n";
        for my $item (@{$self->{truncated_items}}) {
            $output .= "  - $item->{type}: $item->{path} " .
                      "($item->{original_tokens} → $item->{truncated_tokens} tokens)\n";
        }
    }
    
    $output .= "\n";
    
    for my $item (@$context) {
        # Show truncation note for this specific item if present
        if ($item->{truncation_note}) {
            $output .= "⚠️  $item->{truncation_note}\n\n";
        }
        
        if ($item->{type} eq 'file') {
            $output .= "File: $item->{path}";
            if ($item->{truncated}) {
                $output .= " [TRUNCATED]";
            }
            $output .= "\n```\n";
            $output .= $item->{content};
            $output .= "\n```\n\n";
        }
        elsif ($item->{type} eq 'folder') {
            $output .= $item->{content} . "\n\n";
        }
        elsif ($item->{type} eq 'codebase') {
            $output .= $item->{content} . "\n\n";
        }
        elsif ($item->{type} eq 'selection') {
            $output .= "Selected Text:\n```\n";
            $output .= $item->{content};
            $output .= "\n```\n\n";
        }
        elsif ($item->{type} eq 'terminalLastCommand') {
            $output .= $item->{content} . "\n\n";
        }
        elsif ($item->{type} eq 'terminalSelection') {
            $output .= "Terminal Selection:\n```\n";
            $output .= $item->{content};
            $output .= "\n```\n\n";
        }
    }
    
    $output .= "--- End Context ---\n\n";
    
    # Add summary of token usage
    if ($self->{total_tokens_used} > 0) {
        $output .= sprintf("(Context: %d tokens used of %d max)\n\n", 
                          $self->{total_tokens_used}, $self->{max_total_tokens});
    }
    
    return $output;
}

1;
