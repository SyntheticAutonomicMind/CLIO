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
    
    my $content_size = length($content);
    
    if ($content_size <= $MAX_INLINE_SIZE) {
        # Small enough to send inline
        print STDERR "[DEBUG][ToolResultStore] Inline: toolCallId=$toolCallId, size=$content_size bytes\n" if should_log('DEBUG');
        return $content;
    }
    
    # Persist the full content to disk
    my $marker;
    eval {
        my $metadata = $self->persistResult($toolCallId, $content, $session_id);
        
        # Generate preview chunk
        my $preview = substr($content, 0, $PREVIEW_SIZE);
        
        my $remaining = $content_size - $PREVIEW_SIZE;
        
        $marker = <<END_MARKER;
[TOOL_RESULT_PREVIEW: First $PREVIEW_SIZE bytes shown]

$preview

[TOOL_RESULT_STORED: toolCallId=$toolCallId, totalLength=$content_size, remaining=$remaining bytes]

To read the full result, use:
read_tool_result(toolCallId: "$toolCallId", offset: 0, length: 8192)
END_MARKER
        
        print STDERR "[INFO][ToolResultStore] Persisted: toolCallId=$toolCallId, totalSize=$content_size bytes, preview=$PREVIEW_SIZE bytes, path=$metadata->{filePath}\n" if $self->{debug};
    };
    
    if ($@) {
        # Fallback: If persistence fails, truncate and log warning
        my $error = $@;
        print STDERR "[ERROR][ToolResultStore] Failed to persist result: $error\n";
        
        my $truncated = substr($content, 0, $MAX_INLINE_SIZE);
        $marker = <<END_FALLBACK;
[WARNING: Tool result too large ($content_size bytes) and persistence failed]

$truncated

[TRUNCATED: Remaining @{[$content_size - $MAX_INLINE_SIZE]} bytes not shown]
END_FALLBACK
    }
    
    return $marker;
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
        print STDERR "[ERROR][ToolResultStore] Failed to create directory: $error\n";
        die "Failed to create tool_results directory: $error";
    }
    
    # Write content to file
    eval {
        open my $fh, '>:utf8', $result_file or die "Failed to open $result_file: $!";
        print $fh $content;
        close $fh;
    };
    if ($@) {
        my $error = $@;
        print STDERR "[ERROR][ToolResultStore] Failed to write file: $error\n";
        die "Failed to write tool result file: $error";
    }
    
    my $total_length = length($content);
    my $created = time();
    
    return {
        toolCallId => $toolCallId,
        session_id => $session_id,
        filePath => $result_file,
        totalLength => $total_length,
        created => $created,
    };
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
    unless (-f $result_file) {
        print STDERR "[WARN]ToolResultStore] Result not found: $toolCallId in session $session_id\n";
        die "Tool result not found: $toolCallId";
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
        print STDERR "[ERROR][ToolResultStore] Failed to read file: $error\n";
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
        print STDERR "[ERROR][ToolResultStore] Failed to delete result: $error\n";
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
        print STDERR "[ERROR][ToolResultStore] Failed to delete tool results directory: $error\n";
        die "Failed to delete tool results directory: $error";
    }
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
