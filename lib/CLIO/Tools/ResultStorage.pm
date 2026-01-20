package CLIO::Tools::ResultStorage;

use strict;
use warnings;
use CLIO::Core::Logger qw(should_log);
use feature 'say';
use File::Path qw(make_path);
use File::Spec;
use JSON::PP qw(encode_json decode_json);

=head1 NAME

CLIO::Tools::ResultStorage - Storage for large tool results

=head1 DESCRIPTION

Handles persistence of large tool results to prevent API 400 errors.

Pattern from SAM's ToolResultStorage:
- Results <8KB: returned inline
- Results >8KB: saved to disk, preview + marker returned
- AI uses read_tool_result to fetch chunks

Storage location: sessions/<session_id>/tool_results/<tool_call_id>.txt

=cut

# Constants
use constant MAX_INLINE_SIZE => 8192;  # 8KB - safe for inline
use constant PREVIEW_SIZE => 8192;      # First 8KB as preview

sub new {
    my ($class, %opts) = @_;
    
    my $self = {
        base_dir => $opts{base_dir} || 'sessions',
        debug => $opts{debug} || 0,
    };
    
    return bless $self, $class;
}

=head2 process_result

Process a tool result: return inline or persist + preview.

Arguments:
- $tool_call_id: Unique tool call identifier
- $content: Tool result content
- $session_id: Session owning this result

Returns: Content (if small) or preview + marker (if large)

=cut

sub process_result {
    my ($self, $tool_call_id, $content, $session_id) = @_;
    
    my $size = length($content);
    
    print STDERR "[DEBUG][ResultStorage] Processing result: toolCallId=$tool_call_id, size=$size bytes\n" if should_log('DEBUG');
    
    # Small enough - return inline
    if ($size <= MAX_INLINE_SIZE) {
        print STDERR "[DEBUG][ResultStorage] Returning inline (size=$size <= " . MAX_INLINE_SIZE . ")\n" if $self->{debug};
        return $content;
    }
    
    # Large - persist and return preview + marker
    print STDERR "[DEBUG][ResultStorage] Large result - persisting to disk\n" if should_log('DEBUG');
    
    eval {
        $self->_persist($tool_call_id, $content, $session_id);
    };
    
    if ($@) {
        print STDERR "[ERROR][ResultStorage] Failed to persist: $@\n";
        # Fallback: truncate
        my $truncated = substr($content, 0, MAX_INLINE_SIZE);
        return "[WARNING: Result too large ($size bytes) and persistence failed]\n\n"
             . "$truncated\n\n"
             . "[TRUNCATED: Remaining " . ($size - MAX_INLINE_SIZE) . " bytes not shown]";
    }
    
    # Generate preview + marker
    my $preview = substr($content, 0, PREVIEW_SIZE);
    my $remaining = $size - PREVIEW_SIZE;
    
    my $marker = "[TOOL_RESULT_PREVIEW: First " . PREVIEW_SIZE . " bytes shown]\n\n"
               . "$preview\n\n"
               . "[TOOL_RESULT_STORED: toolCallId=$tool_call_id, totalLength=$size, remaining=$remaining bytes]\n\n"
               . "To read the full result, use:\n"
               . "read_tool_result tool with parameters: {\"tool_call_id\": \"$tool_call_id\", \"offset\": 0, \"length\": 8192}";
    
    print STDERR "[INFO][ResultStorage] Persisted toolCallId=$tool_call_id, size=$size bytes, preview=" . PREVIEW_SIZE . " bytes\n";
    
    return $marker;
}

=head2 retrieve_chunk

Retrieve a chunk of a persisted result.

Arguments:
- $tool_call_id: Tool call identifier
- $session_id: Session owning the result
- $offset: Character offset (default 0)
- $length: Chunk size (default 8192)

Returns: Hash with {content, offset, length, total_length, has_more}

=cut

sub retrieve_chunk {
    my ($self, $tool_call_id, $session_id, $offset, $length) = @_;
    
    $offset //= 0;
    $length //= 8192;
    
    print STDERR "[DEBUG][ResultStorage] Retrieving chunk: toolCallId=$tool_call_id, offset=$offset, length=$length\n" if should_log('DEBUG');
    
    # Build path
    my $file_path = $self->_get_result_path($session_id, $tool_call_id);
    
    unless (-f $file_path) {
        die "Tool result not found: $tool_call_id in session $session_id\n";
    }
    
    # Read file
    open my $fh, '<:utf8', $file_path or die "Failed to read $file_path: $!\n";
    my $full_content = do { local $/; <$fh> };
    close $fh;
    
    my $total_length = length($full_content);
    
    # Validate offset
    if ($offset < 0 || $offset >= $total_length) {
        die "Invalid offset $offset for result (total length: $total_length)\n";
    }
    
    # Extract chunk
    my $chunk = substr($full_content, $offset, $length);
    my $actual_length = length($chunk);
    my $has_more = ($offset + $actual_length) < $total_length;
    
    print STDERR "[DEBUG][ResultStorage] Retrieved chunk: offset=$offset, length=$actual_length, total=$total_length, has_more=$has_more\n" if should_log('DEBUG');
    
    return {
        content => $chunk,
        offset => $offset,
        length => $actual_length,
        total_length => $total_length,
        has_more => $has_more,
        next_offset => $has_more ? ($offset + $actual_length) : undef,
    };
}

=head2 result_exists

Check if a result exists.

Arguments:
- $tool_call_id: Tool call identifier
- $session_id: Session owning the result

Returns: 1 if exists, 0 otherwise

=cut

sub result_exists {
    my ($self, $tool_call_id, $session_id) = @_;
    
    my $file_path = $self->_get_result_path($session_id, $tool_call_id);
    return -f $file_path ? 1 : 0;
}

# Private methods

sub _persist {
    my ($self, $tool_call_id, $content, $session_id) = @_;
    
    my $file_path = $self->_get_result_path($session_id, $tool_call_id);
    my $dir = File::Spec->catdir($self->{base_dir}, $session_id, 'tool_results');
    
    # Create directory
    make_path($dir) unless -d $dir;
    
    # Write content
    open my $fh, '>:utf8', $file_path or die "Failed to write $file_path: $!\n";
    print $fh $content;
    close $fh;
    
    print STDERR "[DEBUG][ResultStorage] Persisted to: $file_path\n" if should_log('DEBUG');
}

sub _get_result_path {
    my ($self, $session_id, $tool_call_id) = @_;
    
    return File::Spec->catfile(
        $self->{base_dir},
        $session_id,
        'tool_results',
        "$tool_call_id.txt"
    );
}

1;
