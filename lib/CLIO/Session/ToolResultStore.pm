package CLIO::Session::ToolResultStore;

use strict;
use warnings;
use CLIO::Core::Logger qw(should_log);
use feature 'say';
use File::Path qw(make_path remove_tree);
use File::Spec;
use Cwd 'abs_path';

=head1 NAME

CLIO::Session::ToolResultStore - Storage service for large tool results

=head1 DESCRIPTION

Manages persistence of large tool results that exceed inline size limits.
Based on SAM's ToolResultStorage pattern.

**Problem**: AI providers return errors when tool results exceed token limits.

**Solution**: Automatically persist large results to disk and return previews with
markers that the AI can use to retrieve the full content via read_tool_result.

**Thresholds**:
- MAX_INLINE_SIZE: 8192 bytes (8KB) - results larger than this are persisted
- PREVIEW_SIZE: 8192 bytes - preview shown in stored result marker

**Storage Location**: sessions/<session_id>/tool_results/<toolCallId>.txt

=head2 LINE WRAPPING (BUGFIX)

Lines exceeding 1000 characters are automatically wrapped at word boundaries during
persistence. This prevents ultra-long lines from causing AI context/tokenization issues.

**Why**: Very long lines (>2000 chars) can cause AI models to generate malformed JSON
in subsequent responses, leading to cascading failures. This was observed in session
2683331c-091c-45f3-b196-77d57231be2d where a 3,803-character package list caused
11 consecutive JSON errors and session termination.

**Implementation**: Lines >1000 chars are split at word boundaries (spaces preferred).
If no spaces exist, hard-breaks at 1000 chars. This preserves content while ensuring
digestibility.

**Impact**: Minimal - only affects extremely long lines (rare in normal output).
Total content size remains unchanged, only newlines are added.

=cut

# Storage thresholds (matches SAM)
our $MAX_INLINE_SIZE = 8192;  # 8KB
our $PREVIEW_SIZE = 8192;     # 8KB preview

=head2 new

Constructor.

Arguments:
- sessions_dir: Base directory for sessions (default: .clio/sessions)
- debug: Enable debug logging

Returns: New ToolResultStore instance

=cut

sub new {
    my ($class, %opts) = @_;
    
    my $self = {
        sessions_dir => $opts{sessions_dir} || '.clio/sessions',
        debug => $opts{debug} || 0,
    };
    
    return bless $self, $class;
}

=head2 processToolResult

Process a tool result: return inline content or persist and return marker.

This is the main entry point - call this for all tool results.

Arguments:
- toolCallId: Unique identifier for this tool call
- content: The tool result content (UTF-8 text)
- session_id: Session owning this result

Returns: Either the original content (if small) or a marker with preview (if large)

=cut

sub processToolResult {
    my ($self, $toolCallId, $content, $session_id) = @_;
    
    # Handle undefined content gracefully
    $content //= '';
    
    my $content_size = length($content);
    
    if ($content_size <= $MAX_INLINE_SIZE) {
        # Small enough to send inline
        print STDERR "[DEBUG][ToolResultStore] Inline: toolCallId=$toolCallId, size=$content_size bytes\n" if should_log('DEBUG');
        return $content;
    }
    
    # Analyze content for potential issues BEFORE persisting
    my $warnings = _analyze_content_issues($content);
    
    # Persist the full content to disk
    my $marker;
    eval {
        my $metadata = $self->persistResult($toolCallId, $content, $session_id);
        
        # Generate preview chunk
        my $preview = substr($content, 0, $PREVIEW_SIZE);
        
        my $remaining = $content_size - $PREVIEW_SIZE;
        
        # Build marker with optional warnings
        my $warning_text = '';
        if (@$warnings) {
            $warning_text = "\n[CONTENT WARNINGS]\n" . join("\n", map { "- $_" } @$warnings) . "\n";
        }
        
        $marker = <<END_MARKER;
[TOOL_RESULT_PREVIEW: First $PREVIEW_SIZE bytes shown]$warning_text

$preview

[TOOL_RESULT_STORED: toolCallId=$toolCallId, totalLength=$content_size, remaining=$remaining bytes]

To read the full result, use:
file_operations(operation: "read_tool_result", toolCallId: "$toolCallId", offset: 0, length: 8192)
END_MARKER
        
        print STDERR "[INFO][ToolResultStore] Persisted: toolCallId=$toolCallId, totalSize=$content_size bytes, preview=$PREVIEW_SIZE bytes, path=$metadata->{filePath}\n" if $self->{debug};
    };
    
    if ($@) {
        # Fallback: If persistence fails, truncate and log warning
        my $error = $@;
        print STDERR "[ERROR][ToolResultStore] Failed to persist result: $error\n" if should_log('ERROR');
        
        my $truncated = substr($content, 0, $MAX_INLINE_SIZE);
        $marker = <<END_FALLBACK;
[WARNING: Tool result too large ($content_size bytes) and persistence failed]

$truncated

[TRUNCATED: Remaining @{[$content_size - $MAX_INLINE_SIZE]} bytes not shown]
END_FALLBACK
    }
    
    return $marker;
}

=head2 _analyze_content_issues (private)

Analyze content for characteristics that might cause AI issues.

Detects:
- Ultra-long lines (>2000 chars) that can confuse AI models
- Content with very few newlines (potential formatting issues)
- Other anomalies

Arguments:
- content: Text to analyze

Returns: Arrayref of warning strings (empty if no issues)

=cut

sub _analyze_content_issues {
    my ($content) = @_;
    
    my @warnings;
    
    return \@warnings unless defined $content && length($content) > 0;
    
    # Check for ultra-long lines before wrapping
    my @lines = split /\n/, $content, -1;
    my $max_line_length = 0;
    for my $line (@lines) {
        my $len = length($line);
        $max_line_length = $len if $len > $max_line_length;
    }
    
    if ($max_line_length > 2000) {
        push @warnings, "Contains lines up to $max_line_length characters (will be wrapped at 1000 chars for readability)";
    }
    
    # Check for very few newlines (might be binary or unformatted)
    my $newline_count = ($content =~ tr/\n/\n/);
    my $content_size = length($content);
    if ($content_size > 10000 && $newline_count < 10) {
        push @warnings, "Large content with few line breaks (may be binary or unformatted data)";
    }
    
    return \@warnings;
}

=head2 persistResult

Persist a tool result to disk.

Arguments:
- toolCallId: Unique identifier for this tool call
- content: The tool result content (UTF-8 text)
- session_id: Session owning this result

Returns: Metadata hashref with filePath, totalLength, created

Throws: Dies on error

=cut

sub persistResult {
    my ($self, $toolCallId, $content, $session_id) = @_;
    
    # Build path: sessions/<session_id>/tool_results/<toolCallId>.txt
    my $session_dir = File::Spec->catdir($self->{sessions_dir}, $session_id);
    my $tool_results_dir = File::Spec->catdir($session_dir, 'tool_results');
    my $result_file = File::Spec->catfile($tool_results_dir, "$toolCallId.txt");
    
    print STDERR "[DEBUG][ToolResultStore] Persisting: $toolCallId to $result_file\n" if should_log('DEBUG');
    
    # Create tool_results directory if needed
    eval {
        make_path($tool_results_dir) unless -d $tool_results_dir;
    };
    if ($@) {
        my $error = $@;
        print STDERR "[ERROR][ToolResultStore] Failed to create directory: $error\n" if should_log('ERROR');
        die "Failed to create tool_results directory: $error";
    }
    
    # Wrap ultra-long lines to prevent AI context/JSON errors
    # Lines >1000 chars can confuse AI models and cause malformed JSON responses
    # See: session 2683331c-091c-45f3-b196-77d57231be2d failure with 3803-char line
    my $wrapped_content = _wrap_long_lines($content, 1000);
    
    # Write content to file (using wrapped version)
    eval {
        open my $fh, '>:utf8', $result_file or die "Failed to open $result_file: $!";
        print $fh $wrapped_content;
        close $fh;
    };
    if ($@) {
        my $error = $@;
        print STDERR "[ERROR][ToolResultStore] Failed to write file: $error\n" if should_log('ERROR');
        die "Failed to write tool result file: $error";
    }
    
    my $total_length = length($wrapped_content);
    my $created = time();
    
    return {
        toolCallId => $toolCallId,
        session_id => $session_id,
        filePath => $result_file,
        totalLength => $total_length,
        created => $created,
    };
}

=head2 _wrap_long_lines (private)

Wrap lines exceeding a maximum length at word boundaries.

Ultra-long lines (>1000 chars) can cause AI models to generate malformed JSON
in subsequent responses. This wraps such lines at natural word boundaries.

Arguments:
- content: Text content to wrap
- max_length: Maximum line length (default: 1000)

Returns: Content with long lines wrapped

=cut

sub _wrap_long_lines {
    my ($content, $max_length) = @_;
    
    $max_length //= 1000;
    
    return $content unless defined $content;
    
    my @input_lines = split /\n/, $content, -1;  # -1 preserves trailing empty lines
    my @output_lines;
    
    for my $line (@input_lines) {
        if (length($line) <= $max_length) {
            # Line is fine as-is
            push @output_lines, $line;
        } else {
            # Line is too long - wrap it at word boundaries
            my $remaining = $line;
            
            while (length($remaining) > $max_length) {
                # Try to find a space near the max_length boundary
                my $chunk = substr($remaining, 0, $max_length);
                
                # Look for last space in the chunk
                if ($chunk =~ /^(.+)\s+(\S*)$/) {
                    # Found a space - break there
                    my $before_space = $1;
                    my $partial_word = $2;
                    
                    push @output_lines, $before_space;
                    $remaining = substr($remaining, length($before_space) + 1);  # +1 to skip the space
                } else {
                    # No spaces found - hard break at max_length
                    push @output_lines, $chunk;
                    $remaining = substr($remaining, $max_length);
                }
            }
            
            # Add the final piece
            push @output_lines, $remaining if length($remaining) > 0;
        }
    }
    
    return join("\n", @output_lines);
}

=head2 retrieveChunk

Retrieve a chunk of a persisted tool result.

Arguments:
- toolCallId: Tool call identifier
- session_id: Session owning the result (for security validation)
- offset: Character offset to start reading from (0-based, default: 0)
- length: Number of characters to read (default: 8192)

Returns: Hashref with:
- toolCallId: Tool call ID
- offset: Actual offset read from
- length: Actual length read
- totalLength: Total size of stored result
- content: The chunk content
- hasMore: Boolean - true if more content remains

Throws: Dies on error

=cut

sub retrieveChunk {
    my ($self, $toolCallId, $session_id, $offset, $length) = @_;
    
    $offset //= 0;
    $length //= 8192;
    
    # Enforce maximum chunk size (32KB) - matches SAM's design
    my $max_chunk_size = 32_768;
    if ($length > $max_chunk_size) {
        print STDERR "[DEBUG][ToolResultStore] Requested length $length exceeds max $max_chunk_size, capping to $max_chunk_size\n" if should_log('DEBUG');
        $length = $max_chunk_size;
    }
    
    # Build path
    my $session_dir = File::Spec->catdir($self->{sessions_dir}, $session_id);
    my $tool_results_dir = File::Spec->catdir($session_dir, 'tool_results');
    my $result_file = File::Spec->catfile($tool_results_dir, "$toolCallId.txt");
    
    print STDERR "[DEBUG][ToolResultStore] Retrieving chunk: toolCallId=$toolCallId, offset=$offset, length=$length\n" if should_log('DEBUG');
    
    # Security check: Verify file exists in session's directory
    # If not found, try fuzzy matching to handle AI hallucination of tool call IDs
    unless (-f $result_file) {
        # Only log the "not found" warning in debug mode - if we auto-correct, user doesn't need to know
        print STDERR "[DEBUG][ToolResultStore] Result not found: $toolCallId in session $session_id (trying fuzzy match)\n" 
            if should_log('DEBUG');
        
        # Try to find similar files (handles AI hallucination of IDs)
        my $suggestions = $self->findSimilarResults($toolCallId, $session_id);
        
        # If exactly ONE close match exists, auto-correct to it
        # This handles common AI hallucination where 1-2 characters are wrong
        if ($suggestions && @$suggestions == 1) {
            my $corrected_id = $suggestions->[0];
            # Only log auto-correction in debug mode - silent recovery is the goal
            print STDERR "[DEBUG][ToolResultStore] Auto-corrected toolCallId: $toolCallId -> $corrected_id\n"
                if should_log('DEBUG');
            $toolCallId = $corrected_id;
            $result_file = File::Spec->catfile($tool_results_dir, "$toolCallId.txt");
        }
        # If multiple close matches, show suggestions and let AI pick
        elsif ($suggestions && @$suggestions > 1) {
            my $suggestion_text = join("\n", map { "  - $_" } @$suggestions);
            die "Tool result not found: $toolCallId\n\nMultiple similar results found. Did you mean one of these?\n$suggestion_text";
        }
        # No matches at all
        else {
            die "Tool result not found: $toolCallId";
        }
    }
    
    # Read file content
    my $full_content;
    eval {
        open my $fh, '<:utf8', $result_file or die "Failed to open $result_file: $!";
        local $/;
        $full_content = <$fh>;
        close $fh;
    };
    if ($@) {
        my $error = $@;
        print STDERR "[ERROR][ToolResultStore] Failed to read file: $error\n" if should_log('ERROR');
        die "Failed to read tool result file: $error";
    }
    
    my $total_length = length($full_content);
    
    # Validate offset
    if ($offset < 0 || $offset >= $total_length) {
        die "Invalid offset $offset for result with total length $total_length";
    }
    
    # Calculate chunk bounds
    my $end_offset = $offset + $length;
    $end_offset = $total_length if $end_offset > $total_length;
    
    my $chunk = substr($full_content, $offset, $length);
    my $actual_length = length($chunk);
    
    my $has_more = $end_offset < $total_length;
    
    print STDERR "[DEBUG][ToolResultStore] Retrieved: offset=$offset, requested=$length, actual=$actual_length, total=$total_length\n" if should_log('DEBUG');
    
    return {
        toolCallId => $toolCallId,
        offset => $offset,
        length => $actual_length,
        totalLength => $total_length,
        content => $chunk,
        hasMore => $has_more,
        nextOffset => $has_more ? $end_offset : undef,
    };
}

=head2 resultExists

Check if a tool result exists for the given session.

Arguments:
- toolCallId: Tool call identifier
- session_id: Session owning the result

Returns: True if result exists, false otherwise

=cut

sub resultExists {
    my ($self, $toolCallId, $session_id) = @_;
    
    my $session_dir = File::Spec->catdir($self->{sessions_dir}, $session_id);
    my $tool_results_dir = File::Spec->catdir($session_dir, 'tool_results');
    my $result_file = File::Spec->catfile($tool_results_dir, "$toolCallId.txt");
    
    return -f $result_file;
}

=head2 findSimilarResults

Find tool results with similar IDs (for fuzzy matching when AI hallucinates wrong ID).

Arguments:
- toolCallId: The (possibly incorrect) tool call identifier
- session_id: Session to search in

Returns: Arrayref of similar toolCallIds, or empty array if none found

=cut

sub findSimilarResults {
    my ($self, $toolCallId, $session_id) = @_;
    
    my $session_dir = File::Spec->catdir($self->{sessions_dir}, $session_id);
    my $tool_results_dir = File::Spec->catdir($session_dir, 'tool_results');
    
    return [] unless -d $tool_results_dir;
    
    # Get all result files
    opendir(my $dh, $tool_results_dir) or return [];
    my @files = grep { /^call_.*\.txt$/ } readdir($dh);
    closedir($dh);
    
    # Extract tool call IDs (remove .txt extension)
    my @all_ids = map { s/\.txt$//r } @files;
    
    return [] unless @all_ids;
    
    # Find similar IDs using simple string distance
    my @similar;
    for my $id (@all_ids) {
        my $distance = _string_distance($toolCallId, $id);
        my $max_len = length($toolCallId) > length($id) ? length($toolCallId) : length($id);
        
        # Consider it similar if edit distance is small relative to length
        # Allow up to ~10% difference (1 char per 10)
        my $threshold = int($max_len / 10) + 2;
        
        if ($distance <= $threshold) {
            push @similar, $id;
        }
    }
    
    # Sort by similarity (smaller distance first)
    @similar = sort { 
        _string_distance($toolCallId, $a) <=> _string_distance($toolCallId, $b) 
    } @similar;
    
    # Return top 3 most similar (or fewer if less available)
    my $max = @similar < 3 ? @similar : 3;
    return [ @similar[0..$max-1] ] if $max > 0;
    return [];
}

# Simple Levenshtein distance implementation
sub _string_distance {
    my ($s1, $s2) = @_;
    
    my @s1 = split //, $s1;
    my @s2 = split //, $s2;
    
    my $len1 = @s1;
    my $len2 = @s2;
    
    # Create distance matrix
    my @d;
    for my $i (0 .. $len1) {
        $d[$i][0] = $i;
    }
    for my $j (0 .. $len2) {
        $d[0][$j] = $j;
    }
    
    # Fill in the matrix
    for my $i (1 .. $len1) {
        for my $j (1 .. $len2) {
            my $cost = ($s1[$i-1] eq $s2[$j-1]) ? 0 : 1;
            
            $d[$i][$j] = _min(
                $d[$i-1][$j] + 1,      # deletion
                $d[$i][$j-1] + 1,      # insertion
                $d[$i-1][$j-1] + $cost # substitution
            );
        }
    }
    
    return $d[$len1][$len2];
}

sub _min {
    my $min = shift;
    for (@_) {
        $min = $_ if $_ < $min;
    }
    return $min;
}

=head2 deleteResult

Delete a specific tool result.

Arguments:
- toolCallId: Tool call identifier
- session_id: Session owning the result

Throws: Dies on error (except if file doesn't exist)

=cut

sub deleteResult {
    my ($self, $toolCallId, $session_id) = @_;
    
    my $session_dir = File::Spec->catdir($self->{sessions_dir}, $session_id);
    my $tool_results_dir = File::Spec->catdir($session_dir, 'tool_results');
    my $result_file = File::Spec->catfile($tool_results_dir, "$toolCallId.txt");
    
    return unless -f $result_file;  # Already deleted - not an error
    
    eval {
        unlink $result_file or die "Failed to delete $result_file: $!";
        print STDERR "[DEBUG][ToolResultStore] Deleted: $toolCallId\n" if should_log('DEBUG');
    };
    if ($@) {
        my $error = $@;
        print STDERR "[ERROR][ToolResultStore] Failed to delete result: $error\n" if should_log('ERROR');
        die "Failed to delete tool result: $error";
    }
}

=head2 deleteAllResults

Delete all tool results for a session.

This is called when a session is deleted.

Arguments:
- session_id: Session to clean up

Throws: Dies on error (except if directory doesn't exist)

=cut

sub deleteAllResults {
    my ($self, $session_id) = @_;
    
    my $session_dir = File::Spec->catdir($self->{sessions_dir}, $session_id);
    my $tool_results_dir = File::Spec->catdir($session_dir, 'tool_results');
    
    return unless -d $tool_results_dir;  # No tool results - not an error
    
    eval {
        remove_tree($tool_results_dir);
        print STDERR "[DEBUG][ToolResultStore] Deleted all results for session: $session_id\n" if should_log('DEBUG');
    };
    if ($@) {
        my $error = $@;
        print STDERR "[ERROR][ToolResultStore] Failed to delete tool results directory: $error\n" if should_log('ERROR');
        die "Failed to delete tool results directory: $error";
    }
}

=head2 cleanupOldResults

Delete tool results older than a specified age.

This prevents tool_results/ directories from growing indefinitely in long-running
sessions. Tool results are only needed during active conversation - once the AI
has processed the output and generated a response, the raw tool result is rarely
needed again.

Arguments:
- session_id: Session to clean up
- max_age_hours: Maximum age in hours (default: 24)

Returns: Hashref with {deleted_count, reclaimed_bytes, errors}

=cut

sub cleanupOldResults {
    my ($self, $session_id, $max_age_hours) = @_;
    
    $max_age_hours //= 24;  # Default: delete results older than 24 hours
    
    my $session_dir = File::Spec->catdir($self->{sessions_dir}, $session_id);
    my $tool_results_dir = File::Spec->catdir($session_dir, 'tool_results');
    
    my $deleted_count = 0;
    my $reclaimed_bytes = 0;
    my @errors;
    
    # No tool results directory - nothing to clean
    return {
        deleted_count => 0,
        reclaimed_bytes => 0,
        errors => [],
    } unless -d $tool_results_dir;
    
    # Calculate cutoff time (current time - max_age_hours)
    my $cutoff_time = time() - ($max_age_hours * 3600);
    
    print STDERR "[DEBUG][ToolResultStore] Cleaning up tool results older than $max_age_hours hours (cutoff: $cutoff_time) in session $session_id\n"
        if should_log('DEBUG');
    
    # Scan tool results directory
    opendir(my $dh, $tool_results_dir) or do {
        push @errors, "Failed to open tool_results directory: $!";
        return {
            deleted_count => 0,
            reclaimed_bytes => 0,
            errors => \@errors,
        };
    };
    
    my @files = grep { /\.txt$/ && -f File::Spec->catfile($tool_results_dir, $_) } readdir($dh);
    closedir($dh);
    
    # Check each file's age and delete if too old
    for my $filename (@files) {
        my $filepath = File::Spec->catfile($tool_results_dir, $filename);
        
        # Get file modification time
        my $mtime = (stat($filepath))[9];
        
        unless (defined $mtime) {
            push @errors, "Failed to stat $filename: $!";
            next;
        }
        
        # Skip if file is newer than cutoff
        next if $mtime >= $cutoff_time;
        
        # File is old - delete it
        my $size = (stat($filepath))[7] || 0;
        
        if (unlink $filepath) {
            $deleted_count++;
            $reclaimed_bytes += $size;
            
            my $age_hours = int((time() - $mtime) / 3600);
            print STDERR "[DEBUG][ToolResultStore] Deleted old result: $filename (age: ${age_hours}h, size: $size bytes)\n"
                if should_log('DEBUG');
        } else {
            push @errors, "Failed to delete $filename: $!";
        }
    }
    
    # Log summary
    if ($deleted_count > 0) {
        my $reclaimed_mb = sprintf("%.2f", $reclaimed_bytes / 1_048_576);
        print STDERR "[INFO][ToolResultStore] Cleanup completed: deleted $deleted_count old tool results, reclaimed ${reclaimed_mb}MB in session $session_id\n"
            if should_log('INFO');
    } elsif ($self->{debug}) {
        print STDERR "[DEBUG][ToolResultStore] Cleanup: no old results to delete in session $session_id\n";
    }
    
    return {
        deleted_count => $deleted_count,
        reclaimed_bytes => $reclaimed_bytes,
        errors => \@errors,
    };
}

=head2 listResults

List all tool result IDs for a session.

Arguments:
- session_id: Session to query

Returns: Array of tool call IDs with persisted results

=cut

sub listResults {
    my ($self, $session_id) = @_;
    
    my $session_dir = File::Spec->catdir($self->{sessions_dir}, $session_id);
    my $tool_results_dir = File::Spec->catdir($session_dir, 'tool_results');
    
    return () unless -d $tool_results_dir;
    
    opendir my $dh, $tool_results_dir or return ();
    my @files = grep { /\.txt$/ && -f File::Spec->catfile($tool_results_dir, $_) } readdir($dh);
    closedir $dh;
    
    # Extract toolCallId from filename (remove .txt extension)
    my @tool_call_ids = map { s/\.txt$//r } @files;
    
    return @tool_call_ids;
}

1;
