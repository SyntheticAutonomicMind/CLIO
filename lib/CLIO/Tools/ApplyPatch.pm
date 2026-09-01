# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Tools::ApplyPatch;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
use Carp qw(croak);
use File::Spec;
use File::Path qw(make_path);
use File::Basename qw(dirname);
use CLIO::Util::JSON qw(encode_json);
use CLIO::Util::PathResolver qw(strip_path_quotes);
use CLIO::Core::Logger qw(log_debug log_warning);
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
    my ($self) = @_;

    # Use the base class definition (which includes 'operation' parameter
    # with the enum of supported_operations and required => ['operation']),
    # then extend it with the 'patch' parameter. This ensures the AI sees
    # the operation field in the schema and is prompted to provide it,
    # rather than relying on the execute() override to auto-inject it.
    my $def = $self->SUPER::get_tool_definition();

    $def->{parameters}{required} = ["operation", "patch"];
    $def->{description} = 'Apply a patch to create, modify, or delete files. Uses a lightweight diff format that is more efficient than full file rewrites. Each patch can contain multiple file operations. Prefer this over file_operations write_file/replace_string for multi-file changes.';
    $def->{parameters}{properties}{patch} = {
        type => 'string',
        description => '[REQUIRED] The patch text. Format:

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
- Multiple @@ sections per file for non-adjacent changes

IMPORTANT: every line in a chunk MUST start with +, -, space, or @@.
Bare text lines (POD blocks like =head2/=cut, function signatures like
"sub foo {", or prose paragraphs) are silently dropped, which breaks
contiguous chunk matching and causes "Cannot find match position for
chunk" errors. When editing POD blocks or anything with mixed prose,
prefer file_operations.replace_string with exact old_string/new_string.
If you see "Unrecognized line in patch chunk" warnings, the chunk
format is wrong - reread this rule.',
    };

    return $def;
}

=head2 route_operation($operation, $params, $context)

Route to the appropriate operation handler.

=cut

sub dispatch_table {
    return {
        apply => '_do_apply',
    };
}

=head2 _do_apply

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
        # Use error_result() so tool_name is set for ToolErrorGuidance.
        # Phrasing matches the 'Missing required parameter: <name>' convention
        # so guidance categorizes this as 'missing_required'.
        return $self->error_result(
            'Missing required parameter: patch',
            action_description => 'apply_patch failed: no patch provided',
        );
    }
    
    # Parse the patch
    my ($hunks, $parse_error) = $self->_parse_patch($patch_text);
    
    if ($parse_error) {
        # Strip any caller-location that leaked from internal croaks in the
        # parser, then route through error_result() so tool_name is set.
        my $clean_err = $self->_clean_eval_error($parse_error);
        return $self->error_result(
            "Patch parse error: $clean_err",
            action_description => "apply_patch failed: $clean_err",
        );
    }
    
    if (!$hunks || !@$hunks) {
        # Phrase with 'Invalid' so ToolErrorGuidance's invalid_value regex
        # (/invalid/i) matches and the schema guidance fires, pointing at
        # the *** Add/Update/Delete File: directives the patch requires.
        return $self->error_result(
            "Invalid patch: no file operations found. Patch must contain at least one *** Add File:, *** Update File:, or *** Delete File: directive.",
            action_description => 'apply_patch failed: empty patch',
        );
    }
    
    # Apply each hunk
    my @results;
    my @errors;
    my $files_modified = 0;
    my $files_created = 0;
    my $files_deleted = 0;
    
    # Get vault from context for undo tracking
    my $vault = $context->{file_vault};
    my $turn_id = $context->{vault_turn_id};
    
    for my $hunk (@$hunks) {
        # Vault: capture files before modification for undo support
        if ($vault && $turn_id) {
            my $hunk_path = $hunk->{path};
            my $hunk_type = $hunk->{type};
            eval {
                if ($hunk_type eq 'update') {
                    $vault->capture_before($hunk_path, $turn_id);
                }
                elsif ($hunk_type eq 'add') {
                    $vault->record_creation($hunk_path, $turn_id);
                }
                elsif ($hunk_type eq 'delete') {
                    $vault->record_deletion($hunk_path, $turn_id);
                }
            };
            if ($@) {
                log_debug('ApplyPatch', "Vault capture failed (non-fatal): $@");
            }
        }
        
        # Allow ESC interrupt between hunks. Without this, a large patch
        # with many files blocks until every hunk finishes - the user
        # cannot break out of a multi-file patch mid-flight.
        if ($self->check_interrupt($context)) {
            log_debug('ApplyPatch', "User interrupt detected after " . scalar(@results) . " hunk(s); aborting remaining " . (scalar(@$hunks) - scalar(@results)) . " hunk(s)");
            return $self->success_result(
                encode_json({
                    results => \@results,
                    files_created => $files_created,
                    files_modified => $files_modified,
                    files_deleted => $files_deleted,
                    interrupted => 1,
                }),
                action_description => "apply_patch: aborted by user after " . scalar(@results) . " of " . scalar(@$hunks) . " hunk(s)",
            );
        }

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
        my $err_count = scalar(@errors);
        my $total = scalar(@$hunks);

        # If only one hunk failed, surface that hunk's error directly so
        # ToolErrorGuidance can categorize it (file_not_found, permission_denied,
        # edit_content_mismatch, etc.). The "partial apply" framing only makes
        # sense when some hunks actually succeeded.
        if ($err_count == $total && $err_count == 1) {
            my $failed = [grep { !$_->{success} } @results]->[0];
            return $self->error_result(
                $failed->{error},
                action_description => "apply_patch: $summary (with 1 error)",
                type => $failed->{type},
                path => $failed->{path},
                output => encode_json({ results => \@results }),
            );
        }

        # Multiple hunks with mixed success/failure: keep the partial-apply
        # framing. Per-hunk detail (already clean and category-matching) lives
        # in 'output' so the AI can see what succeeded and what failed.
        return $self->error_result(
            "Patch partially applied. $err_count of $total hunks failed. See per-hunk errors below.",
            action_description => "apply_patch: $summary (with $err_count error(s))",
            output => encode_json({ results => \@results }),
        );
    }
    
    return $self->success_result(
        encode_json({
            results => \@results,
            files_created => $files_created,
            files_modified => $files_modified,
            files_deleted => $files_deleted,
        }),
        action_description => "apply_patch: $summary",
    );
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
            my $path = strip_path_quotes($1);
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
            my $path = strip_path_quotes($1);
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
            my $path = strip_path_quotes($1);
            $path =~ s/^\s+|\s+$//g;
            $i++;
            
            # Check for move directive
            my $move_path;
            if ($i < @lines && $lines[$i] =~ /^\*\*\*\s*Move\s+to:\s*(.+)$/i) {
                $move_path = strip_path_quotes($1);
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
                
                # Unrecognized line - this may indicate malformed patch
                # Instead of silently treating as context, warn and skip
                log_debug('ApplyPatch', "Unrecognized line in patch chunk (not +, -, space, or @@): '$cl'");
                log_debug('ApplyPatch', "This line will be ignored. Check patch format for missing +/-/space prefixes.");
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
    
    # Validate parsed hunks - warn about empty/no-op chunks
    for my $hunk (@hunks) {
        if ($hunk->{type} eq 'update' && $hunk->{chunks}) {
            my @valid_chunks;
            for my $chunk (@{$hunk->{chunks}}) {
                my $has_old = $chunk->{old_lines} && @{$chunk->{old_lines}};
                my $has_new = $chunk->{new_lines} && @{$chunk->{new_lines}};
                if ($has_old || $has_new) {
                    push @valid_chunks, $chunk;
                } else {
                    log_debug('ApplyPatch', "Skipping empty chunk in update for $hunk->{path}");
                }
            }
            $hunk->{chunks} = \@valid_chunks;
            
            # If all chunks were empty, report error
            if (!@valid_chunks && !$hunk->{move_path}) {
                return (\@hunks, "Update for '$hunk->{path}' has no changes (no +/- lines found). Check patch format.");
            }
        }
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
    
    return $self->error_result(
        "Unknown hunk type: $type (expected add, update, or delete)",
        type => $type,
        path => $path,
    );
}

sub _apply_add {
    my ($self, $full_path, $rel_path, $content) = @_;
    
    # Create directory if needed
    my $dir = dirname($full_path);
    unless (-d $dir) {
        eval { make_path($dir) };
        if ($@) {
            # Strip croak caller-location from $@ so it doesn't leak the
            # internal executor file path. Underlying OS errors like
            # "Permission denied" still match ToolErrorGuidance's
            # permission_denied regex.
            return $self->error_result(
                "Cannot create directory for $rel_path: " . $self->_clean_eval_error($@),
                type => 'add',
                path => $rel_path,
            );
        }
    }
    
    # Ensure trailing newline
    $content .= "\n" unless $content =~ /\n$/;
    
    # Write file
    eval {
        open my $fh, '>:encoding(UTF-8)', $full_path
            or croak "Cannot write: $!";
        print $fh $content;
        close $fh;
    };
    
    if ($@) {
        return $self->error_result(
            "Write failed for $rel_path: " . $self->_clean_eval_error($@),
            type => 'add',
            path => $rel_path,
        );
    }
    
    return { success => 1, type => 'add', path => $rel_path };
}

sub _apply_delete {
    my ($self, $full_path, $rel_path) = @_;
    
    unless (-e $full_path) {
        # "File not found: <path>" matches ToolErrorGuidance's file_not_found
        # regex so the AI gets the dedicated guidance about path checks.
        return $self->error_result(
            "File not found: $rel_path",
            type => 'delete',
            path => $rel_path,
        );
    }
    
    if (unlink $full_path) {
        return { success => 1, type => 'delete', path => $rel_path };
    }
    
    return $self->error_result(
        "Delete failed for $rel_path: $!",
        type => 'delete',
        path => $rel_path,
    );
}

sub _apply_update {
    my ($self, $full_path, $rel_path, $hunk) = @_;
    
    unless (-f $full_path) {
        return $self->error_result(
            "File not found: $rel_path",
            type => 'update',
            path => $rel_path,
        );
    }
    
    # Read current content
    my $content;
    eval {
        open my $fh, '<:encoding(UTF-8)', $full_path
            or croak "Cannot read: $!";
        $content = do { local $/; <$fh> };
        close $fh;
    };
    
    if ($@) {
        return $self->error_result(
            "Read failed for $rel_path: " . $self->_clean_eval_error($@),
            type => 'update',
            path => $rel_path,
        );
    }
    
    my @lines = split /\n/, $content, -1;
    
    # Apply each chunk
    my $offset = 0;  # Track line offset from previous chunk applications

    for my $chunk (@{$hunk->{chunks}}) {
        # Allow ESC interrupt during multi-chunk file updates. A single
        # _apply_update with many chunks can take seconds on large files;
        # without polling the user waits for the whole file to finish.
        if ($self->check_interrupt()) {
            return $self->error_result(
                "apply_patch aborted by user during $rel_path update",
                type => 'update',
                path => $rel_path,
            );
        }

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
            # Retain "Cannot find match position for chunk" so ToolErrorGuidance
            # categorizes as edit_content_mismatch and shows the dedicated
            # guidance (read the file, find real text, retry with correct
            # old_lines that exactly match the file).
            return $self->error_result(
                "Cannot find match position for chunk" .
                ($context ? " (context: '$context')" : '') .
                "Read the file to see its actual content before retrying.",
                type => 'update',
                path => $rel_path,
            );
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
        
        # Write to new location (preserving original permissions)
        my @stat = stat($full_path);
        my $orig_mode = @stat ? ($stat[2] & 07777) : 0644;
        my $new_content = join("\n", @lines);
        eval {
            open my $fh, '>:encoding(UTF-8)', $new_full
                or croak "Cannot write: $!";
            print $fh $new_content;
            close $fh;
            chmod $orig_mode, $new_full;
        };
        
        if ($@) {
            return $self->error_result(
                "Move failed for $rel_path: " . $self->_clean_eval_error($@),
                type => 'update',
                path => $rel_path,
            );
        }
        
        # Delete original
        unlink $full_path;
        
        return { success => 1, type => 'update', path => $rel_path, moved_to => $hunk->{move_path} };
    }
    
    # Write updated content back
    my $new_content = join("\n", @lines);
    eval {
        # Preserve original file permissions
        my @stat = stat($full_path);
        my $orig_mode = @stat ? ($stat[2] & 07777) : 0644;
        
        # Atomic write via temp file
        my $temp = $full_path . '.clio_tmp';
        open my $fh, '>:encoding(UTF-8)', $temp
            or croak "Cannot write temp: $!";
        print $fh $new_content;
        close $fh;
        chmod $orig_mode, $temp;
        rename $temp, $full_path
            or croak "Cannot rename: $!";
    };
    
    if ($@) {
        return $self->error_result(
            "Write failed for $rel_path: " . $self->_clean_eval_error($@),
            type => 'update',
            path => $rel_path,
        );
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
    
    # If we have old_lines, search for match (try exact first, then fuzzy)
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
        
        # If exact match fails, try fuzzy match (whitespace-tolerant)
        for my $i ($search_start .. ($#$lines - $pattern_len + 1)) {
            if ($self->_lines_match_fuzzy($lines, $i, $old_lines)) {
                log_debug('ApplyPatch', "Fuzzy match found at line $i");
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
            # Also try fuzzy from start
            for my $i (0 .. ($search_start - 1)) {
                if ($self->_lines_match_fuzzy($lines, $i, $old_lines)) {
                    log_debug('ApplyPatch', "Fuzzy match found at line $i (retry from start)");
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

=head2 _lines_match_fuzzy(\@file_lines, $start_pos, \@pattern_lines)

Check if pattern_lines match file_lines starting at start_pos, ignoring whitespace differences.

=cut

sub _lines_match_fuzzy {
    my ($self, $file_lines, $start, $pattern) = @_;
    
    return 0 if $start + scalar(@$pattern) - 1 > $#$file_lines;
    
    for my $j (0 .. $#$pattern) {
        my $file_line = $file_lines->[$start + $j] // '';
        my $pat_line = $pattern->[$j] // '';
        
        # Normalize whitespace: trim and collapse multiple spaces
        $file_line =~ s/^\s+|\s+$//g;
        $file_line =~ s/\s+/ /g;
        $pat_line =~ s/^\s+|\s+$//g;
        $pat_line =~ s/\s+/ /g;
        
        return 0 unless $file_line eq $pat_line;
    }
    
    return 1;
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

=head2 _clean_eval_error (Internal)

_clean_eval_error() is inherited from CLIO::Tools::Tool (where the
POD documentation lives). All tools can call $self->_clean_eval_error($@)
to strip Carp/croak caller-location suffixes before forwarding to
error_result(). See CLIO::Tools::Tool for details.

1;

__END__

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

GPL-3.0-only

=cut

1;
