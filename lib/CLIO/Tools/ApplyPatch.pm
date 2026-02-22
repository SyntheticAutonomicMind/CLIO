package CLIO::Tools::ApplyPatch;

use strict;
use warnings;
use utf8;
use File::Spec;
use File::Path qw(make_path);
use File::Basename qw(dirname);
use JSON::PP qw(encode_json);
use CLIO::Core::Logger qw(should_log log_debug);
use parent 'CLIO::Tools::Tool';

=head1 NAME

CLIO::Tools::ApplyPatch - Diff-based file editing tool for AI agents

=head1 DESCRIPTION

Provides a patch-based file editing tool that allows the AI to describe
file changes using a lightweight diff format. This is more efficient than
full-file rewrites and produces cleaner, more reviewable edits.

The patch format supports:
- Adding new files
- Deleting files
- Updating files with contextual hunks
- Moving/renaming files

=head1 PATCH FORMAT

    *** Begin Patch
    *** Add File: path/to/new_file.py
    +line 1
    +line 2
    *** Update File: path/to/existing.py
    @@ context line from file
    -old line to remove
    +new line to add
     unchanged context line
    *** Delete File: path/to/obsolete.py
    *** End Patch

=cut

sub new {
    my ($class, %opts) = @_;
    
    my $self = $class->SUPER::new(
        name => 'apply_patch',
        description => 'Apply a patch to create, modify, or delete files using a lightweight diff format.',
        supported_operations => [qw(apply)],
        %opts,
    );
    
    $self->{base_dir} = $opts{base_dir} || '.';
    
    return $self;
}

=head2 get_tool_definition

Return the tool definition for the API (OpenAI function-calling format).

=cut

sub get_tool_definition {
    return {
        name => 'apply_patch',
        description => 'Apply a patch to create, modify, or delete files. Uses a lightweight diff format that is more efficient than full file rewrites. Each patch can contain multiple file operations. Prefer this over file_operations write_file/replace_string for multi-file changes.',
        parameters => {
            type => 'object',
            required => ['patch'],
            properties => {
                patch => {
                    type => 'string',
                    description => 'The patch text. Format:

*** Begin Patch
*** Add File: <path>
+new line content
*** Update File: <path>
@@ context line (a unique line near the change)
-old line to remove
+new line to add
 unchanged context line
*** Delete File: <path>
*** End Patch

Rules:
- New lines start with +
- Removed lines start with -
- Context (unchanged) lines start with space
- @@ anchors help locate the change position
- Multiple @@ sections per file for non-adjacent changes',
                },
            },
        },
    };
}

=head2 route_operation($operation, $params, $context)

Route to the appropriate operation handler.

=cut

sub route_operation {
    my ($self, $operation, $params, $context) = @_;
    
    if ($operation eq 'apply') {
        return $self->_do_apply($params, $context);
    }
    
    return $self->operation_error("Unknown operation: $operation. Available: apply");
}

=head2 execute

Override base execute to auto-inject operation='apply' since this tool
has only one operation and the AI will call it without specifying one.

=cut

sub execute {
    my ($self, $params, $context) = @_;
    
    # Auto-inject operation if not provided (AI calls apply_patch with just 'patch')
    $params->{operation} //= 'apply';
    
    return $self->SUPER::execute($params, $context);
}

=head2 _do_apply(\%params, $context)

Execute the apply_patch tool.

Arguments:
- params: Hashref with 'patch' key containing the patch text
- context: Execution context (session, etc.)

Returns: JSON-encoded result hashref

=cut

sub _do_apply {
    my ($self, $params, $context) = @_;
    
    my $patch_text = $params->{patch} || $params->{patchText} || '';
    
    unless ($patch_text && length($patch_text) > 0) {
        return {
            success => 0,
            error => 'patch parameter is required',
            action_description => 'apply_patch failed: no patch provided',
        };
    }
    
    # Parse the patch
    my ($hunks, $parse_error) = $self->_parse_patch($patch_text);
    
    if ($parse_error) {
        return {
            success => 0,
            error => "Patch parse error: $parse_error",
            action_description => "apply_patch failed: $parse_error",
        };
    }
    
    if (!$hunks || !@$hunks) {
        return {
            success => 0,
            error => 'No file operations found in patch',
            action_description => 'apply_patch failed: empty patch',
        };
    }
    
    # Apply each hunk
    my @results;
    my @errors;
    my $files_modified = 0;
    my $files_created = 0;
    my $files_deleted = 0;
    
    for my $hunk (@$hunks) {
        my $result = $self->_apply_hunk($hunk);
        push @results, $result;
        
        if ($result->{success}) {
            if ($result->{type} eq 'add') { $files_created++ }
            elsif ($result->{type} eq 'delete') { $files_deleted++ }
            elsif ($result->{type} eq 'update') { $files_modified++ }
        } else {
            push @errors, "$result->{path}: $result->{error}";
        }
    }
    
    # Build summary
    my @parts;
    push @parts, "$files_created created" if $files_created;
    push @parts, "$files_modified modified" if $files_modified;
    push @parts, "$files_deleted deleted" if $files_deleted;
    my $summary = join(', ', @parts) || 'no changes';
    
    if (@errors) {
        return {
            success => 0,
            error => "Patch partially applied. Errors: " . join('; ', @errors),
            action_description => "apply_patch: $summary (with " . scalar(@errors) . " error(s))",
            output => encode_json({ results => \@results }),
        };
    }
    
    return {
        success => 1,
        action_description => "apply_patch: $summary",
        output => encode_json({
            results => \@results,
            files_created => $files_created,
            files_modified => $files_modified,
            files_deleted => $files_deleted,
        }),
    };
}

=head2 _parse_patch($text)

Parse patch text into an array of hunk operations.

Returns: ($hunks_arrayref, $error_string)
Where each hunk is: { type => 'add'|'update'|'delete', path => '...', ... }

=cut

sub _parse_patch {
    my ($self, $text) = @_;
    
    # Normalize line endings
    $text =~ s/\r\n/\n/g;
    $text =~ s/\r/\n/g;
    
    my @lines = split /\n/, $text;
    my @hunks;
    
    # Find patch boundaries
    my $in_patch = 0;
    my $i = 0;
    
    # Skip to *** Begin Patch
    while ($i < @lines) {
        if ($lines[$i] =~ /^\*\*\*\s*Begin\s+Patch\s*$/i) {
            $in_patch = 1;
            $i++;
            last;
        }
        $i++;
    }
    
    unless ($in_patch) {
        # Be lenient - if no Begin/End markers, treat entire text as patch content
        $i = 0;
        $in_patch = 1;
    }
    
    while ($i < @lines && $in_patch) {
        my $line = $lines[$i];
        
        # End of patch
        if ($line =~ /^\*\*\*\s*End\s+Patch\s*$/i) {
            last;
        }
        
        # Add File
        if ($line =~ /^\*\*\*\s*Add\s+File:\s*(.+)$/i) {
            my $path = $1;
            $path =~ s/^\s+|\s+$//g;
            $i++;
            
            my @content_lines;
            while ($i < @lines) {
                last if $lines[$i] =~ /^\*\*\*\s+(Add|Update|Delete|Move|End)\s/i;
                my $content_line = $lines[$i];
                # Remove leading + (patch format)
                $content_line =~ s/^\+//;
                push @content_lines, $content_line;
                $i++;
            }
            
            push @hunks, {
                type => 'add',
                path => $path,
                content => join("\n", @content_lines),
            };
            next;
        }
        
        # Delete File
        if ($line =~ /^\*\*\*\s*Delete\s+File:\s*(.+)$/i) {
            my $path = $1;
            $path =~ s/^\s+|\s+$//g;
            
            push @hunks, {
                type => 'delete',
                path => $path,
            };
            $i++;
            next;
        }
        
        # Update File
        if ($line =~ /^\*\*\*\s*Update\s+File:\s*(.+)$/i) {
            my $path = $1;
            $path =~ s/^\s+|\s+$//g;
            $i++;
            
            # Check for move directive
            my $move_path;
            if ($i < @lines && $lines[$i] =~ /^\*\*\*\s*Move\s+to:\s*(.+)$/i) {
                $move_path = $1;
                $move_path =~ s/^\s+|\s+$//g;
                $i++;
            }
            
            # Parse chunks (context + changes)
            my @chunks;
            my $current_chunk;
            
            while ($i < @lines) {
                last if $lines[$i] =~ /^\*\*\*\s+(Add|Update|Delete|End)\s/i;
                
                my $cl = $lines[$i];
                
                # Context anchor line (@@)
                if ($cl =~ /^@@\s*(.*)$/) {
                    # Start new chunk with context
                    if ($current_chunk) {
                        push @chunks, $current_chunk;
                    }
                    $current_chunk = {
                        context => $1,
                        old_lines => [],
                        new_lines => [],
                    };
                    $i++;
                    next;
                }
                
                # Ensure we have a chunk
                unless ($current_chunk) {
                    $current_chunk = {
                        context => undef,
                        old_lines => [],
                        new_lines => [],
                    };
                }
                
                # Removed line
                if ($cl =~ /^-(.*)$/) {
                    push @{$current_chunk->{old_lines}}, $1;
                    $i++;
                    next;
                }
                
                # Added line
                if ($cl =~ /^\+(.*)$/) {
                    push @{$current_chunk->{new_lines}}, $1;
                    $i++;
                    next;
                }
                
                # Context (unchanged) line (starts with space or is empty)
                if ($cl =~ /^ (.*)$/ || $cl eq '') {
                    my $ctx = ($cl eq '') ? '' : $1;
                    push @{$current_chunk->{old_lines}}, $ctx;
                    push @{$current_chunk->{new_lines}}, $ctx;
                    $i++;
                    next;
                }
                
                # Unrecognized line - treat as context
                push @{$current_chunk->{old_lines}}, $cl;
                push @{$current_chunk->{new_lines}}, $cl;
                $i++;
            }
            
            if ($current_chunk) {
                push @chunks, $current_chunk;
            }
            
            push @hunks, {
                type => 'update',
                path => $path,
                move_path => $move_path,
                chunks => \@chunks,
            };
            next;
        }
        
        # Skip empty or unrecognized lines
        $i++;
    }
    
    return (\@hunks, undef);
}

=head2 _apply_hunk($hunk)

Apply a single hunk (file operation).

Returns: Hashref with success, type, path, and optionally error.

=cut

sub _apply_hunk {
    my ($self, $hunk) = @_;
    
    my $type = $hunk->{type};
    my $path = $hunk->{path};
    my $full_path = File::Spec->rel2abs($path, $self->{base_dir});
    
    if ($type eq 'add') {
        return $self->_apply_add($full_path, $path, $hunk->{content});
    }
    elsif ($type eq 'delete') {
        return $self->_apply_delete($full_path, $path);
    }
    elsif ($type eq 'update') {
        return $self->_apply_update($full_path, $path, $hunk);
    }
    
    return { success => 0, type => $type, path => $path, error => "Unknown hunk type: $type" };
}

sub _apply_add {
    my ($self, $full_path, $rel_path, $content) = @_;
    
    # Create directory if needed
    my $dir = dirname($full_path);
    unless (-d $dir) {
        eval { make_path($dir) };
        if ($@) {
            return { success => 0, type => 'add', path => $rel_path, error => "Cannot create directory: $@" };
        }
    }
    
    # Ensure trailing newline
    $content .= "\n" unless $content =~ /\n$/;
    
    # Write file
    eval {
        open my $fh, '>:encoding(UTF-8)', $full_path
            or die "Cannot write: $!";
        print $fh $content;
        close $fh;
    };
    
    if ($@) {
        return { success => 0, type => 'add', path => $rel_path, error => "Write failed: $@" };
    }
    
    return { success => 1, type => 'add', path => $rel_path };
}

sub _apply_delete {
    my ($self, $full_path, $rel_path) = @_;
    
    unless (-e $full_path) {
        return { success => 0, type => 'delete', path => $rel_path, error => "File not found" };
    }
    
    if (unlink $full_path) {
        return { success => 1, type => 'delete', path => $rel_path };
    }
    
    return { success => 0, type => 'delete', path => $rel_path, error => "Delete failed: $!" };
}

sub _apply_update {
    my ($self, $full_path, $rel_path, $hunk) = @_;
    
    unless (-f $full_path) {
        return { success => 0, type => 'update', path => $rel_path, error => "File not found" };
    }
    
    # Read current content
    my $content;
    eval {
        open my $fh, '<:encoding(UTF-8)', $full_path
            or die "Cannot read: $!";
        $content = do { local $/; <$fh> };
        close $fh;
    };
    
    if ($@) {
        return { success => 0, type => 'update', path => $rel_path, error => "Read failed: $@" };
    }
    
    my @lines = split /\n/, $content, -1;
    
    # Apply each chunk
    my $offset = 0;  # Track line offset from previous chunk applications
    
    for my $chunk (@{$hunk->{chunks}}) {
        my $context = $chunk->{context};
        my @old = @{$chunk->{old_lines} || []};
        my @new = @{$chunk->{new_lines} || []};
        
        # Find where this chunk applies
        my $match_pos = $self->_find_chunk_position(\@lines, $context, \@old, $offset);
        
        if (!defined $match_pos) {
            # Fuzzy match: try without leading/trailing whitespace
            $match_pos = $self->_find_chunk_position_fuzzy(\@lines, $context, \@old, $offset);
        }
        
        if (!defined $match_pos) {
            return {
                success => 0,
                type => 'update',
                path => $rel_path,
                error => "Cannot find match position for chunk" . 
                         ($context ? " (context: '$context')" : ''),
            };
        }
        
        # Apply the replacement
        my $old_count = scalar @old;
        splice @lines, $match_pos, $old_count, @new;
        
        # Update offset for next chunk
        $offset = $match_pos + scalar(@new);
    }
    
    # Handle move/rename
    if ($hunk->{move_path}) {
        my $new_full = File::Spec->rel2abs($hunk->{move_path}, $self->{base_dir});
        my $new_dir = dirname($new_full);
        eval { make_path($new_dir) } unless -d $new_dir;
        
        # Write to new location
        my $new_content = join("\n", @lines);
        eval {
            open my $fh, '>:encoding(UTF-8)', $new_full
                or die "Cannot write: $!";
            print $fh $new_content;
            close $fh;
        };
        
        if ($@) {
            return { success => 0, type => 'update', path => $rel_path, error => "Move failed: $@" };
        }
        
        # Delete original
        unlink $full_path;
        
        return { success => 1, type => 'update', path => $rel_path, moved_to => $hunk->{move_path} };
    }
    
    # Write updated content back
    my $new_content = join("\n", @lines);
    eval {
        # Atomic write via temp file
        my $temp = $full_path . '.clio_tmp';
        open my $fh, '>:encoding(UTF-8)', $temp
            or die "Cannot write temp: $!";
        print $fh $new_content;
        close $fh;
        rename $temp, $full_path
            or die "Cannot rename: $!";
    };
    
    if ($@) {
        return { success => 0, type => 'update', path => $rel_path, error => "Write failed: $@" };
    }
    
    return { success => 1, type => 'update', path => $rel_path };
}

=head2 _find_chunk_position(\@lines, $context, \@old_lines, $start_offset)

Find the position in the file where a chunk's old_lines match.
Uses context line as an anchor if provided.

Returns: Line index where old_lines start, or undef if not found.

=cut

sub _find_chunk_position {
    my ($self, $lines, $context, $old_lines, $start_offset) = @_;
    
    $start_offset //= 0;
    
    # If we have old_lines, search for exact match
    if ($old_lines && @$old_lines) {
        my $pattern_len = scalar @$old_lines;
        
        # If we have a context anchor, search near it first
        my $search_start = $start_offset;
        if ($context && defined $context && length($context) > 0) {
            # Find the context line
            for my $i ($start_offset .. $#$lines) {
                my $trimmed = $lines->[$i];
                $trimmed =~ s/^\s+|\s+$//g;
                my $ctx_trimmed = $context;
                $ctx_trimmed =~ s/^\s+|\s+$//g;
                
                if ($trimmed eq $ctx_trimmed) {
                    # Found context - look for old_lines starting after it
                    $search_start = $i + 1;
                    
                    # But first check if old_lines start AT the context line
                    if ($self->_lines_match($lines, $i, $old_lines)) {
                        return $i;
                    }
                    last;
                }
            }
        }
        
        # Search for exact match of old_lines
        for my $i ($search_start .. ($#$lines - $pattern_len + 1)) {
            if ($self->_lines_match($lines, $i, $old_lines)) {
                return $i;
            }
        }
        
        # Retry from start of file if we started with offset
        if ($search_start > 0) {
            for my $i (0 .. ($search_start - 1)) {
                if ($self->_lines_match($lines, $i, $old_lines)) {
                    return $i;
                }
            }
        }
    }
    
    # If only context and no old_lines, find the context line
    if ($context && (!$old_lines || !@$old_lines)) {
        for my $i ($start_offset .. $#$lines) {
            my $trimmed = $lines->[$i];
            $trimmed =~ s/^\s+|\s+$//g;
            my $ctx_trimmed = $context;
            $ctx_trimmed =~ s/^\s+|\s+$//g;
            
            if ($trimmed eq $ctx_trimmed) {
                return $i;
            }
        }
    }
    
    return undef;
}

=head2 _find_chunk_position_fuzzy

Fuzzy variant that ignores whitespace differences.

=cut

sub _find_chunk_position_fuzzy {
    my ($self, $lines, $context, $old_lines, $start_offset) = @_;
    
    $start_offset //= 0;
    return undef unless $old_lines && @$old_lines;
    
    my $pattern_len = scalar @$old_lines;
    
    for my $i ($start_offset .. ($#$lines - $pattern_len + 1)) {
        my $match = 1;
        for my $j (0 .. $#$old_lines) {
            my $file_line = $lines->[$i + $j] // '';
            my $patch_line = $old_lines->[$j] // '';
            
            # Normalize whitespace
            $file_line =~ s/^\s+|\s+$//g;
            $patch_line =~ s/^\s+|\s+$//g;
            
            unless ($file_line eq $patch_line) {
                $match = 0;
                last;
            }
        }
        return $i if $match;
    }
    
    return undef;
}

=head2 _lines_match(\@file_lines, $start_pos, \@pattern_lines)

Check if pattern_lines match file_lines starting at start_pos.

=cut

sub _lines_match {
    my ($self, $file_lines, $start, $pattern) = @_;
    
    return 0 if $start + scalar(@$pattern) - 1 > $#$file_lines;
    
    for my $j (0 .. $#$pattern) {
        my $file_line = $file_lines->[$start + $j] // '';
        my $pat_line = $pattern->[$j] // '';
        
        return 0 unless $file_line eq $pat_line;
    }
    
    return 1;
}

1;

__END__

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

GPL-3.0-only

=cut
