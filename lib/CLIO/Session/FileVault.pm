package CLIO::Session::FileVault;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use File::Spec;
use File::Path qw(make_path remove_tree);
use File::Copy qw(copy);
use File::Basename qw(dirname);
use JSON::PP qw(encode_json decode_json);
use Cwd qw(getcwd abs_path);
use CLIO::Core::Logger qw(should_log log_debug);

=head1 NAME

CLIO::Session::FileVault - Targeted file backup for undo/revert

=head1 DESCRIPTION

Provides undo capability by backing up only the files CLIO actually modifies,
rather than snapshotting the entire work tree. This approach:

- Works everywhere (no git dependency, no work tree size limits)
- Is instant (copies only touched files, not the whole tree)
- Is lightweight (stores only what changed)
- Requires no safety guards (works from home dir, project dir, anywhere)

Each AI turn gets a unique turn ID. Before CLIO modifies a file, the original
content is backed up to .clio/vault/<turn_id>/. Only the FIRST backup per file
per turn is kept - subsequent modifications to the same file in the same turn
don't overwrite the original pre-turn state.

=head1 SYNOPSIS

    my $vault = CLIO::Session::FileVault->new(
        work_tree => '/path/to/project',
    );

    # Start a new turn
    my $turn_id = $vault->start_turn("user prompt text");

    # Before modifying a file
    $vault->capture_before($path, $turn_id);

    # Record a newly created file (no pre-existing content)
    $vault->record_creation($path, $turn_id);

    # Record a file deletion (backs up content before delete)
    $vault->record_deletion($path, $turn_id);

    # Record a rename
    $vault->record_rename($old_path, $new_path, $turn_id);

    # Undo an entire turn
    my $result = $vault->undo_turn($turn_id);

    # List changed files for a turn
    my $changes = $vault->changed_files($turn_id);

    # Get a diff for a turn
    my $diff = $vault->diff($turn_id);

=cut

# Maximum turns to keep in the vault before pruning oldest
use constant MAX_TURNS => 20;

# Maximum total vault size in bytes before cleanup (50MB)
use constant MAX_VAULT_SIZE => 50 * 1024 * 1024;

sub new {
    my ($class, %args) = @_;

    my $work_tree = $args{work_tree} || getcwd();
    my $vault_dir = File::Spec->catdir($work_tree, '.clio', 'vault');

    my $self = {
        work_tree  => $work_tree,
        vault_dir  => $vault_dir,
        debug      => $args{debug} || 0,
        turn_count => 0,
        # Track which files have been captured this turn to avoid overwriting
        # the original backup when the same file is modified multiple times
        _captured  => {},  # { turn_id => { relative_path => 1 } }
    };

    bless $self, $class;

    # Ensure vault directory exists
    unless (-d $vault_dir) {
        make_path($vault_dir);
        log_debug('FileVault', "Created vault directory: $vault_dir");
    }

    return $self;
}

=head2 is_available

FileVault is always available - no external dependencies required.

Returns: 1 always.

=cut

sub is_available {
    return 1;
}

=head2 start_turn($user_input)

Begin a new turn, creating a turn directory in the vault.

Arguments:
- $user_input: The user's prompt text (for reference in the manifest)

Returns: Turn ID string (e.g., "turn_0001")

=cut

sub start_turn {
    my ($self, $user_input) = @_;

    $self->{turn_count}++;
    my $turn_id = sprintf("turn_%04d", $self->{turn_count});

    my $turn_dir = File::Spec->catdir($self->{vault_dir}, $turn_id);
    make_path($turn_dir);

    my $files_dir = File::Spec->catdir($turn_dir, 'files');
    make_path($files_dir);

    # Write initial manifest
    my $manifest = {
        turn_id    => $turn_id,
        timestamp  => time(),
        user_input => defined $user_input ? substr($user_input, 0, 200) : '',
        operations => [],
    };

    $self->_write_manifest($turn_id, $manifest);

    # Reset per-turn capture tracking
    $self->{_captured}{$turn_id} = {};

    log_debug('FileVault', "Started turn: $turn_id");

    # Prune old turns if we exceed the limit
    $self->_prune_old_turns();

    return $turn_id;
}

=head2 capture_before($path, $turn_id)

Back up a file before it's modified. Call this BEFORE writing to the file.
If the same file has already been captured for this turn, this is a no-op
(preserving the original pre-turn state).

Arguments:
- $path: Path to the file about to be modified (absolute or relative)
- $turn_id: Current turn ID from start_turn()

Returns: 1 if captured, 0 if already captured or file doesn't exist

=cut

sub capture_before {
    my ($self, $path, $turn_id) = @_;

    return 0 unless $path && $turn_id;

    my $rel_path = $self->_relative_path($path);
    return 0 unless defined $rel_path;

    # Already captured this file for this turn - keep the original
    if ($self->{_captured}{$turn_id} && $self->{_captured}{$turn_id}{$rel_path}) {
        log_debug('FileVault', "Already captured $rel_path for $turn_id, skipping");
        return 0;
    }

    my $abs_path = File::Spec->rel2abs($path, $self->{work_tree});

    # File must exist to capture
    unless (-f $abs_path) {
        log_debug('FileVault', "File does not exist, cannot capture: $abs_path");
        return 0;
    }

    # Copy the file to vault
    my $vault_file = $self->_vault_file_path($turn_id, $rel_path);
    my $vault_file_dir = dirname($vault_file);
    make_path($vault_file_dir) unless -d $vault_file_dir;

    eval {
        copy($abs_path, $vault_file) or die "Copy failed: $!";
    };
    if ($@) {
        log_debug('FileVault', "Failed to capture $rel_path: $@");
        return 0;
    }

    # Mark as captured
    $self->{_captured}{$turn_id} ||= {};
    $self->{_captured}{$turn_id}{$rel_path} = 1;

    # Record in manifest
    $self->_add_operation($turn_id, {
        type => 'modify',
        path => $rel_path,
        timestamp => time(),
    });

    log_debug('FileVault', "Captured $rel_path for $turn_id");
    return 1;
}

=head2 record_creation($path, $turn_id)

Record that a new file was created by CLIO. No backup is needed since the
file didn't exist before, but we need to know to delete it on undo.

If the file DID already exist (e.g., overwriting), this automatically falls
back to capture_before() behavior to preserve the original content.

Arguments:
- $path: Path to the newly created file
- $turn_id: Current turn ID

Returns: 1 on success

=cut

sub record_creation {
    my ($self, $path, $turn_id) = @_;

    return 0 unless $path && $turn_id;

    my $rel_path = $self->_relative_path($path);
    return 0 unless defined $rel_path;

    # Already tracked this file for this turn
    if ($self->{_captured}{$turn_id} && $self->{_captured}{$turn_id}{$rel_path}) {
        log_debug('FileVault', "Already tracked $rel_path for $turn_id, skipping");
        return 0;
    }

    # Mark as captured
    $self->{_captured}{$turn_id} ||= {};
    $self->{_captured}{$turn_id}{$rel_path} = 1;

    # Record in manifest as creation (undo = delete)
    $self->_add_operation($turn_id, {
        type => 'create',
        path => $rel_path,
        timestamp => time(),
    });

    log_debug('FileVault', "Recorded creation of $rel_path for $turn_id");
    return 1;
}

=head2 record_deletion($path, $turn_id)

Back up a file before deletion. The backup allows undo to restore it.

Arguments:
- $path: Path to the file about to be deleted
- $turn_id: Current turn ID

Returns: 1 if backed up, 0 on failure

=cut

sub record_deletion {
    my ($self, $path, $turn_id) = @_;

    return 0 unless $path && $turn_id;

    my $rel_path = $self->_relative_path($path);
    return 0 unless defined $rel_path;

    my $abs_path = File::Spec->rel2abs($path, $self->{work_tree});

    # Back up the file before deletion (if it exists and hasn't been captured)
    if (-f $abs_path && !($self->{_captured}{$turn_id} && $self->{_captured}{$turn_id}{$rel_path})) {
        my $vault_file = $self->_vault_file_path($turn_id, $rel_path);
        my $vault_file_dir = dirname($vault_file);
        make_path($vault_file_dir) unless -d $vault_file_dir;

        eval {
            copy($abs_path, $vault_file) or die "Copy failed: $!";
        };
        if ($@) {
            log_debug('FileVault', "Failed to back up before deletion: $@");
            return 0;
        }
    }

    # Mark as captured
    $self->{_captured}{$turn_id} ||= {};
    $self->{_captured}{$turn_id}{$rel_path} = 1;

    # Record in manifest
    $self->_add_operation($turn_id, {
        type => 'delete',
        path => $rel_path,
        timestamp => time(),
    });

    log_debug('FileVault', "Recorded deletion of $rel_path for $turn_id");
    return 1;
}

=head2 record_rename($old_path, $new_path, $turn_id)

Record a file rename. Backs up the original file so undo can restore it.

Arguments:
- $old_path: Original file path
- $new_path: New file path after rename
- $turn_id: Current turn ID

Returns: 1 on success

=cut

sub record_rename {
    my ($self, $old_path, $new_path, $turn_id) = @_;

    return 0 unless $old_path && $new_path && $turn_id;

    my $old_rel = $self->_relative_path($old_path);
    my $new_rel = $self->_relative_path($new_path);
    return 0 unless defined $old_rel && defined $new_rel;

    my $old_abs = File::Spec->rel2abs($old_path, $self->{work_tree});

    # Back up the original file if it exists and hasn't been captured
    if (-f $old_abs && !($self->{_captured}{$turn_id} && $self->{_captured}{$turn_id}{$old_rel})) {
        my $vault_file = $self->_vault_file_path($turn_id, $old_rel);
        my $vault_file_dir = dirname($vault_file);
        make_path($vault_file_dir) unless -d $vault_file_dir;

        eval {
            copy($old_abs, $vault_file) or die "Copy failed: $!";
        };
        if ($@) {
            log_debug('FileVault', "Failed to back up before rename: $@");
            # Continue anyway - we can still record the rename
        }
    }

    # Mark both paths as captured
    $self->{_captured}{$turn_id} ||= {};
    $self->{_captured}{$turn_id}{$old_rel} = 1;
    $self->{_captured}{$turn_id}{$new_rel} = 1;

    # Record in manifest
    $self->_add_operation($turn_id, {
        type         => 'rename',
        path         => $new_rel,
        original_path => $old_rel,
        timestamp    => time(),
    });

    log_debug('FileVault', "Recorded rename of $old_rel -> $new_rel for $turn_id");
    return 1;
}

=head2 undo_turn($turn_id)

Revert all file changes from a specific turn.

For each operation in the manifest (processed in reverse order):
- modify: restore the backed-up original content
- create: delete the created file
- delete: restore the backed-up file
- rename: rename back and restore original content

Arguments:
- $turn_id: Turn ID to undo

Returns: Hashref with:
- success: 1 if all operations succeeded
- reverted: Number of files reverted
- errors: Arrayref of error messages (if any)
- files: Arrayref of affected file paths

=cut

sub undo_turn {
    my ($self, $turn_id) = @_;

    my $manifest = $self->_read_manifest($turn_id);
    unless ($manifest) {
        return {
            success  => 0,
            reverted => 0,
            errors   => ["No manifest found for turn $turn_id"],
            files    => [],
        };
    }

    my @operations = @{$manifest->{operations} || []};
    unless (@operations) {
        return {
            success  => 1,
            reverted => 0,
            errors   => [],
            files    => [],
        };
    }

    my $reverted = 0;
    my @errors;
    my @files;

    # Process operations in reverse order for correct undo semantics
    for my $op (reverse @operations) {
        my $type = $op->{type};
        my $rel_path = $op->{path};
        my $abs_path = File::Spec->catfile($self->{work_tree}, $rel_path);

        push @files, $rel_path;

        if ($type eq 'modify') {
            # Restore original content from vault
            my $vault_file = $self->_vault_file_path($turn_id, $rel_path);
            if (-f $vault_file) {
                eval {
                    my $target_dir = dirname($abs_path);
                    make_path($target_dir) unless -d $target_dir;
                    copy($vault_file, $abs_path) or die "Restore failed: $!";
                };
                if ($@) {
                    push @errors, "Failed to restore $rel_path: $@";
                } else {
                    $reverted++;
                    log_debug('FileVault', "Restored $rel_path from vault");
                }
            } else {
                push @errors, "Vault backup missing for $rel_path";
            }
        }
        elsif ($type eq 'create') {
            # Delete the created file
            if (-f $abs_path) {
                if (unlink $abs_path) {
                    $reverted++;
                    log_debug('FileVault', "Deleted created file: $rel_path");
                    # Clean up empty parent directories
                    $self->_cleanup_empty_dirs(dirname($abs_path));
                } else {
                    push @errors, "Failed to delete $rel_path: $!";
                }
            } else {
                # File already gone, count as success
                $reverted++;
            }
        }
        elsif ($type eq 'delete') {
            # Restore the deleted file from vault
            my $vault_file = $self->_vault_file_path($turn_id, $rel_path);
            if (-f $vault_file) {
                eval {
                    my $target_dir = dirname($abs_path);
                    make_path($target_dir) unless -d $target_dir;
                    copy($vault_file, $abs_path) or die "Restore failed: $!";
                };
                if ($@) {
                    push @errors, "Failed to restore deleted $rel_path: $@";
                } else {
                    $reverted++;
                    log_debug('FileVault', "Restored deleted file: $rel_path");
                }
            } else {
                push @errors, "Vault backup missing for deleted $rel_path";
            }
        }
        elsif ($type eq 'rename') {
            # Rename back to original path
            my $original_rel = $op->{original_path};
            my $original_abs = File::Spec->catfile($self->{work_tree}, $original_rel);

            # First, restore original content if we have a backup
            my $vault_file = $self->_vault_file_path($turn_id, $original_rel);
            if (-f $vault_file) {
                eval {
                    my $target_dir = dirname($original_abs);
                    make_path($target_dir) unless -d $target_dir;
                    copy($vault_file, $original_abs) or die "Restore failed: $!";
                };
                if ($@) {
                    push @errors, "Failed to restore $original_rel: $@";
                    next;
                }
            }
            elsif (-f $abs_path) {
                # No vault backup, just rename back
                eval {
                    my $target_dir = dirname($original_abs);
                    make_path($target_dir) unless -d $target_dir;
                    rename($abs_path, $original_abs) or die "Rename failed: $!";
                };
                if ($@) {
                    push @errors, "Failed to rename $rel_path back to $original_rel: $@";
                    next;
                }
            }

            # Delete the new-path file if it still exists and we restored from vault
            if (-f $abs_path && -f $original_abs && $abs_path ne $original_abs) {
                unlink $abs_path;
            }

            $reverted++;
            log_debug('FileVault', "Reversed rename: $rel_path -> $original_rel");
            push @files, $original_rel;
        }
    }

    # Deduplicate file list
    my %seen;
    @files = grep { !$seen{$_}++ } @files;

    return {
        success  => (@errors == 0) ? 1 : 0,
        reverted => $reverted,
        errors   => \@errors,
        files    => \@files,
    };
}

=head2 changed_files($turn_id)

Get list of files changed during a specific turn.

Arguments:
- $turn_id: Turn ID to check

Returns: Hashref with:
- turn_id: The turn ID
- files: Arrayref of changed file paths (relative)
- operations: Arrayref of operation records

=cut

sub changed_files {
    my ($self, $turn_id) = @_;

    my $manifest = $self->_read_manifest($turn_id);
    unless ($manifest) {
        return { turn_id => $turn_id, files => [], operations => [] };
    }

    my @files;
    my %seen;
    for my $op (@{$manifest->{operations} || []}) {
        push @files, $op->{path} unless $seen{$op->{path}}++;
        if ($op->{original_path} && !$seen{$op->{original_path}}++) {
            push @files, $op->{original_path};
        }
    }

    return {
        turn_id    => $turn_id,
        files      => \@files,
        operations => $manifest->{operations} || [],
    };
}

=head2 diff($turn_id)

Generate a unified diff showing changes made during a turn.
Compares vault (original) files against current file state.

Arguments:
- $turn_id: Turn ID to diff

Returns: Diff string (unified format), or empty string if no changes.

=cut

sub diff {
    my ($self, $turn_id) = @_;

    my $manifest = $self->_read_manifest($turn_id);
    return '' unless $manifest;

    my @diff_parts;

    for my $op (@{$manifest->{operations} || []}) {
        my $type = $op->{type};
        my $rel_path = $op->{path};
        my $abs_path = File::Spec->catfile($self->{work_tree}, $rel_path);
        my $vault_file = $self->_vault_file_path($turn_id, $rel_path);

        if ($type eq 'modify') {
            # Diff vault (original) vs current
            if (-f $vault_file && -f $abs_path) {
                my $d = $self->_file_diff($vault_file, $abs_path, "a/$rel_path", "b/$rel_path");
                push @diff_parts, $d if $d;
            }
        }
        elsif ($type eq 'create') {
            # Show entire file as added
            if (-f $abs_path) {
                my $content = $self->_read_file_content($abs_path);
                if (defined $content && length($content) > 0) {
                    my @lines = split(/\n/, $content, -1);
                    my $line_count = scalar @lines;
                    my $header = "--- /dev/null\n+++ b/$rel_path\n\@\@ -0,0 +1,$line_count \@\@\n";
                    $header .= join("\n", map { "+$_" } @lines);
                    push @diff_parts, $header;
                }
            }
        }
        elsif ($type eq 'delete') {
            # Show entire original file as removed
            if (-f $vault_file) {
                my $content = $self->_read_file_content($vault_file);
                if (defined $content && length($content) > 0) {
                    my @lines = split(/\n/, $content, -1);
                    my $line_count = scalar @lines;
                    my $header = "--- a/$rel_path\n+++ /dev/null\n\@\@ -1,$line_count +0,0 \@\@\n";
                    $header .= join("\n", map { "-$_" } @lines);
                    push @diff_parts, $header;
                }
            }
        }
        elsif ($type eq 'rename') {
            my $original_rel = $op->{original_path};
            my $vault_original = $self->_vault_file_path($turn_id, $original_rel);
            push @diff_parts, "rename from $original_rel\nrename to $rel_path";
            # If content also changed, show diff
            if (-f $vault_original && -f $abs_path) {
                my $d = $self->_file_diff($vault_original, $abs_path, "a/$original_rel", "b/$rel_path");
                push @diff_parts, $d if $d;
            }
        }
    }

    return join("\n", @diff_parts);
}

=head2 get_turn_history

Get list of all turns in the vault with metadata.

Returns: Arrayref of turn info hashrefs, newest first.

=cut

sub get_turn_history {
    my ($self) = @_;

    my $vault_dir = $self->{vault_dir};
    return [] unless -d $vault_dir;

    my @turns;
    opendir my $dh, $vault_dir or return [];
    while (my $entry = readdir $dh) {
        next unless $entry =~ /^turn_\d+$/;
        my $manifest = $self->_read_manifest($entry);
        if ($manifest) {
            push @turns, {
                turn_id    => $entry,
                timestamp  => $manifest->{timestamp},
                user_input => $manifest->{user_input},
                file_count => scalar(@{$manifest->{operations} || []}),
            };
        }
    }
    closedir $dh;

    # Sort by turn number descending (newest first)
    @turns = sort { $b->{turn_id} cmp $a->{turn_id} } @turns;

    return \@turns;
}

=head2 cleanup($max_age_days)

Remove old vault data.

Arguments:
- $max_age_days: Remove turns older than this (default: 7)

=cut

sub cleanup {
    my ($self, $max_age_days) = @_;
    $max_age_days //= 7;

    my $cutoff = time() - ($max_age_days * 86400);
    my $removed = 0;

    my $vault_dir = $self->{vault_dir};
    return unless -d $vault_dir;

    opendir my $dh, $vault_dir or return;
    while (my $entry = readdir $dh) {
        next unless $entry =~ /^turn_\d+$/;
        my $manifest = $self->_read_manifest($entry);
        if ($manifest && $manifest->{timestamp} && $manifest->{timestamp} < $cutoff) {
            my $turn_dir = File::Spec->catdir($vault_dir, $entry);
            remove_tree($turn_dir);
            $removed++;
            log_debug('FileVault', "Cleaned up old turn: $entry");
        }
    }
    closedir $dh;

    log_debug('FileVault', "Cleanup complete: removed $removed old turns") if $removed;
}

=head2 has_turn($turn_id)

Check if a turn exists in the vault.

=cut

sub has_turn {
    my ($self, $turn_id) = @_;
    return 0 unless $turn_id;
    my $turn_dir = File::Spec->catdir($self->{vault_dir}, $turn_id);
    return -d $turn_dir ? 1 : 0;
}

=head2 remove_turn($turn_id)

Remove a turn from the vault (e.g., after successful undo).

=cut

sub remove_turn {
    my ($self, $turn_id) = @_;
    return 0 unless $turn_id;
    my $turn_dir = File::Spec->catdir($self->{vault_dir}, $turn_id);
    if (-d $turn_dir) {
        remove_tree($turn_dir);
        delete $self->{_captured}{$turn_id};
        log_debug('FileVault', "Removed turn: $turn_id");
        return 1;
    }
    return 0;
}

# ===== PRIVATE METHODS =====

=head2 _relative_path($path)

Convert an absolute or relative path to a path relative to the work tree.

=cut

sub _relative_path {
    my ($self, $path) = @_;
    return undef unless defined $path;

    my $abs = File::Spec->rel2abs($path, $self->{work_tree});
    my $work = $self->{work_tree};

    # Ensure work_tree ends without slash for consistent prefix removal
    $work =~ s{/+$}{};

    if ($abs =~ /^\Q$work\E\/(.+)$/) {
        return $1;
    }

    # Path is outside work tree - use as-is if relative
    if (!File::Spec->file_name_is_absolute($path)) {
        return $path;
    }

    log_debug('FileVault', "Path outside work tree: $path");
    return undef;
}

=head2 _vault_file_path($turn_id, $rel_path)

Get the vault backup path for a file.

=cut

sub _vault_file_path {
    my ($self, $turn_id, $rel_path) = @_;
    return File::Spec->catfile($self->{vault_dir}, $turn_id, 'files', $rel_path);
}

=head2 _write_manifest($turn_id, $manifest)

Write a turn manifest to disk.

=cut

sub _write_manifest {
    my ($self, $turn_id, $manifest) = @_;

    my $manifest_file = File::Spec->catfile($self->{vault_dir}, $turn_id, 'manifest.json');
    eval {
        open my $fh, '>:encoding(UTF-8)', $manifest_file or die "Cannot write manifest: $!";
        print $fh encode_json($manifest);
        close $fh;
    };
    if ($@) {
        log_debug('FileVault', "Failed to write manifest for $turn_id: $@");
        return 0;
    }
    return 1;
}

=head2 _read_manifest($turn_id)

Read a turn manifest from disk.

=cut

sub _read_manifest {
    my ($self, $turn_id) = @_;

    my $manifest_file = File::Spec->catfile($self->{vault_dir}, $turn_id, 'manifest.json');
    return undef unless -f $manifest_file;

    my $content;
    eval {
        open my $fh, '<:encoding(UTF-8)', $manifest_file or die "Cannot read manifest: $!";
        local $/;
        $content = <$fh>;
        close $fh;
    };
    return undef if $@;

    my $manifest = eval { decode_json($content) };
    return undef if $@;

    return $manifest;
}

=head2 _add_operation($turn_id, $op)

Append an operation to a turn's manifest.

=cut

sub _add_operation {
    my ($self, $turn_id, $op) = @_;

    my $manifest = $self->_read_manifest($turn_id);
    return 0 unless $manifest;

    push @{$manifest->{operations}}, $op;
    return $self->_write_manifest($turn_id, $manifest);
}

=head2 _file_diff($file_a, $file_b, $label_a, $label_b)

Generate a unified diff between two files using the system diff command.

=cut

sub _file_diff {
    my ($self, $file_a, $file_b, $label_a, $label_b) = @_;

    # Use system diff for proper unified diff output
    my $cmd = sprintf('diff -u --label %s --label %s %s %s 2>/dev/null',
        _shell_quote($label_a),
        _shell_quote($label_b),
        _shell_quote($file_a),
        _shell_quote($file_b),
    );

    my $output = `$cmd`;
    # diff returns exit 1 when files differ (that's success for us)
    return $output if defined $output && length($output) > 0;
    return '';
}

=head2 _read_file_content($path)

Read file content safely.

=cut

sub _read_file_content {
    my ($self, $path) = @_;
    my $content;
    eval {
        open my $fh, '<:raw', $path or die "Cannot read: $!";
        local $/;
        $content = <$fh>;
        close $fh;
    };
    return $content;
}

=head2 _cleanup_empty_dirs($dir)

Remove empty directories up the tree (stops at work_tree).

=cut

sub _cleanup_empty_dirs {
    my ($self, $dir) = @_;

    my $work = $self->{work_tree};
    $work =~ s{/+$}{};

    while ($dir && $dir ne $work && length($dir) > length($work)) {
        # Check if directory is empty
        opendir my $dh, $dir or last;
        my @entries = grep { $_ ne '.' && $_ ne '..' } readdir($dh);
        closedir $dh;

        last if @entries;  # Not empty

        rmdir $dir or last;
        log_debug('FileVault', "Removed empty directory: $dir");
        $dir = dirname($dir);
    }
}

=head2 _prune_old_turns

Remove oldest turns if we exceed MAX_TURNS.

=cut

sub _prune_old_turns {
    my ($self) = @_;

    my $vault_dir = $self->{vault_dir};
    return unless -d $vault_dir;

    opendir my $dh, $vault_dir or return;
    my @turns = sort grep { /^turn_\d+$/ } readdir($dh);
    closedir $dh;

    while (@turns > MAX_TURNS) {
        my $oldest = shift @turns;
        my $turn_dir = File::Spec->catdir($vault_dir, $oldest);
        remove_tree($turn_dir);
        delete $self->{_captured}{$oldest};
        log_debug('FileVault', "Pruned old turn: $oldest");
    }
}

# Shell-safe quoting
sub _shell_quote {
    my ($str) = @_;
    $str =~ s/'/'\\''/g;
    return "'$str'";
}

1;

__END__

=head1 LIMITATIONS

=over 4

=item * File changes made by terminal_operations (shell commands) are not tracked.
Undo covers file operations performed through CLIO's file tools (FileOperations,
ApplyPatch), not arbitrary shell commands.

=item * Binary files are backed up as-is but diff output may not be meaningful.

=item * Vault storage is bounded by MAX_TURNS (20) to prevent unbounded growth.

=back

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

GPL-3.0-only

=cut
