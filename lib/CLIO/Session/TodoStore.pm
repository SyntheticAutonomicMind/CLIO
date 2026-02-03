package CLIO::Session::TodoStore;

use strict;
use warnings;
use CLIO::Core::Logger qw(should_log);
use feature 'say';
use File::Path qw(make_path);
use File::Spec;
use JSON::PP;

=head1 NAME

CLIO::Session::TodoStore - Per-session todo list storage backend

=head1 DESCRIPTION

Manages persistence and validation of todo lists for sessions.
Based on SAM's TodoManager pattern.

**Storage Location**: sessions/<session_id>/todos.json

**Todo Item Structure**:
- id: Integer (sequential, starts at 1)
- title: String (3-7 words, concise label)
- description: String (detailed context, requirements, file paths)
- status: String (not-started | in-progress | completed | blocked)
- priority: String (low | medium | high | critical) - optional
- dependencies: Array of todo IDs - optional
- progress: Number 0.0-1.0 - optional
- blockedReason: String - required if status=blocked
- createdAt: Timestamp
- updatedAt: Timestamp

**Validation Rules**:
1. Only ONE todo can be in-progress at a time
2. Circular dependencies are not allowed
3. Dependencies must reference existing todo IDs
4. Blocked status requires blockedReason
5. Progress must be in range 0.0-1.0

=cut

=head2 new

Constructor.

Arguments:
- session_id: Session ID for this todo store

Returns: New TodoStore instance

=cut

sub new {
    my ($class, %opts) = @_;
    
    die "session_id required" unless $opts{session_id};
    
    my $self = {
        session_id => $opts{session_id},
        debug => $opts{debug} || 0,
        sessions_dir => $opts{sessions_dir} || 'sessions',
    };
    
    bless $self, $class;
    
    # Ensure session directory exists
    my $session_dir = $self->_session_dir();
    unless (-d $session_dir) {
        make_path($session_dir) or die "Cannot create session directory $session_dir: $!";
    }
    
    return $self;
}

=head2 read

Read current todo list for this session.

Returns: Arrayref of todo items (empty array if no todos exist)

=cut

sub read {
    my ($self) = @_;
    
    my $file = $self->_todos_file();
    
    unless (-e $file) {
        print STDERR "[DEBUG][TodoStore] No todos file exists: $file\n" if should_log('DEBUG');
        return [];
    }
    
    my $todos;
    eval {
        open my $fh, '<:encoding(UTF-8)', $file or die "Cannot read todos file: $!";
        local $/;
        my $json = <$fh>;
        close $fh;
        
        my $data = decode_json($json);
        $todos = $data->{todos} || [];
    };
    
    if ($@) {
        print STDERR "[ERROR][TodoStore] Failed to read todos: $@\n" if should_log('ERROR');
        return [];
    }
    
    return $todos;
}

=head2 write

Write complete todo list (replaces entire list).

Arguments:
- todos: Arrayref of todo items

Returns: (success_bool, error_message_or_undef)

=cut

sub write {
    my ($self, $todos) = @_;
    
    $todos ||= [];
    
    # Validate the todo list
    my $errors = $self->validate($todos);
    if (@$errors) {
        my $error_msg = "Todo list validation failed:\n" . join("\n", map { "  - $_" } @$errors);
        print STDERR "[ERROR][TodoStore] $error_msg\n" if should_log('ERROR');
        return (0, $error_msg);
    }
    
    # Add timestamps if not present
    my $now = time();
    foreach my $todo (@$todos) {
        $todo->{createdAt} ||= $now;
        $todo->{updatedAt} = $now;
    }
    
    # Save to disk
    eval {
        $self->_save($todos);
    };
    
    if ($@) {
        print STDERR "[ERROR][TodoStore] Failed to save todos: $@\n" if should_log('ERROR');
        return (0, "Failed to save todos: $@");
    }
    
    print STDERR "[DEBUG][TodoStore] Wrote " . scalar(@$todos) . " todos for session $self->{session_id}\n" if $self->{debug};
    return (1, undef);
}

=head2 update

Partial update of todo items.

Arguments:
- updates: Arrayref of update objects, each with:
  - id: Required - todo ID to update
  - Any other fields to change (status, title, description, progress, etc.)

Returns: (success_bool, error_message_or_undef)

=cut

sub update {
    my ($self, $updates) = @_;
    
    $updates ||= [];
    
    # Read existing todos
    my $todos = $self->read();
    
    if (!@$todos) {
        return (0, "No todo list exists. Create one first with write operation.");
    }
    
    # Apply each update
    my @applied;
    my @failed;
    
    foreach my $update (@$updates) {
        unless (defined $update->{id}) {
            push @failed, "Update missing 'id' field";
            next;
        }
        
        my $todo_id = $update->{id};
        my $found = 0;
        
        foreach my $todo (@$todos) {
            if ($todo->{id} == $todo_id) {
                # Apply updates
                foreach my $key (keys %$update) {
                    next if $key eq 'id';  # Don't update ID
                    next if $key eq 'createdAt';  # Don't update creation time
                    $todo->{$key} = $update->{$key};
                }
                $todo->{updatedAt} = time();
                push @applied, "Todo #$todo_id updated";
                $found = 1;
                last;
            }
        }
        
        push @failed, "Todo #$todo_id not found" unless $found;
    }
    
    # Validate updated list
    my $errors = $self->validate($todos);
    if (@$errors) {
        my $error_msg = "Update validation failed:\n" . join("\n", map { "  - $_" } @$errors);
        return (0, $error_msg);
    }
    
    # Save updated list
    eval {
        $self->_save($todos);
    };
    
    if ($@) {
        return (0, "Failed to save updated todos: $@");
    }
    
    my $summary = scalar(@applied) . " successful";
    $summary .= ", " . scalar(@failed) . " failed" if @failed;
    
    return (1, {
        summary => $summary,
        applied => \@applied,
        failed => \@failed,
    });
}

=head2 add

Add new todos to existing list.

Arguments:
- new_todos: Arrayref of todo objects (without IDs - will be auto-assigned)

Returns: (success_bool, error_message_or_undef)

=cut

sub add {
    my ($self, $new_todos) = @_;
    
    $new_todos ||= [];
    return (1, undef) unless @$new_todos;  # No-op if empty
    
    # Read existing todos
    my $existing = $self->read();
    
    # Find highest existing ID
    my $max_id = 0;
    foreach my $todo (@$existing) {
        $max_id = $todo->{id} if $todo->{id} > $max_id;
    }
    
    # Assign IDs to new todos
    my $now = time();
    foreach my $new_todo (@$new_todos) {
        $max_id++;
        $new_todo->{id} = $max_id;
        $new_todo->{status} ||= 'not-started';
        $new_todo->{createdAt} = $now;
        $new_todo->{updatedAt} = $now;
    }
    
    # Combine and validate
    my @all_todos = (@$existing, @$new_todos);
    
    my $errors = $self->validate(\@all_todos);
    if (@$errors) {
        my $error_msg = "Add validation failed:\n" . join("\n", map { "  - $_" } @$errors);
        return (0, $error_msg);
    }
    
    # Save combined list
    eval {
        $self->_save(\@all_todos);
    };
    
    if ($@) {
        return (0, "Failed to save todos: $@");
    }
    
    print STDERR "[DEBUG][TodoStore] Added " . scalar(@$new_todos) . " new todos\n" if $self->{debug};
    return (1, undef);
}

=head2 validate

Validate todo list for correctness.

Arguments:
- todos: Arrayref of todo items

Returns: Arrayref of error messages (empty if valid)

=cut

sub validate {
    my ($self, $todos) = @_;
    
    my @errors;
    
    return \@errors unless $todos && @$todos;
    
    # Build ID set for quick lookups
    my %todo_ids = map { $_->{id} => 1 } @$todos;
    
    # Count in-progress todos
    my @in_progress = grep { $_->{status} eq 'in-progress' } @$todos;
    if (@in_progress > 1) {
        push @errors, "Multiple todos marked as in-progress (only 1 allowed): " . 
            join(", ", map { "#$_->{id}" } @in_progress);
    }
    
    # Validate each todo
    foreach my $todo (@$todos) {
        my $id = $todo->{id};
        
        # Required fields
        unless (defined $id) {
            push @errors, "Todo missing 'id' field";
            next;
        }
        
        unless ($todo->{title}) {
            push @errors, "Todo #$id missing 'title' field";
        }
        
        unless ($todo->{description}) {
            push @errors, "Todo #$id missing 'description' field";
        }
        
        unless ($todo->{status}) {
            push @errors, "Todo #$id missing 'status' field";
        }
        
        # Status validation
        if ($todo->{status}) {
            unless ($todo->{status} =~ /^(not-started|in-progress|completed|blocked)$/) {
                push @errors, "Todo #$id has invalid status '$todo->{status}'";
            }
        }
        
        # Dependencies must exist
        if ($todo->{dependencies} && @{$todo->{dependencies}}) {
            foreach my $dep_id (@{$todo->{dependencies}}) {
                unless ($todo_ids{$dep_id}) {
                    push @errors, "Todo #$id depends on non-existent todo #$dep_id";
                }
            }
        }
        
        # Circular dependency detection
        if ($self->_has_circular_dependency($id, $todos)) {
            push @errors, "Todo #$id has circular dependency";
        }
        
        # Blocked status requires reason
        if ($todo->{status} eq 'blocked' && !$todo->{blockedReason}) {
            push @errors, "Todo #$id is blocked but has no blockedReason";
        }
        
        # Progress validation
        if (defined $todo->{progress}) {
            if ($todo->{progress} < 0.0 || $todo->{progress} > 1.0) {
                push @errors, "Todo #$id has invalid progress $todo->{progress} (must be 0.0-1.0)";
            }
        }
    }
    
    return \@errors;
}

# MARK: - Private Methods

sub _session_dir {
    my ($self) = @_;
    return File::Spec->catdir($self->{sessions_dir}, $self->{session_id});
}

sub _todos_file {
    my ($self) = @_;
    return File::Spec->catfile($self->_session_dir(), 'todos.json');
}

sub _save {
    my ($self, $todos) = @_;
    
    my $data = {
        session_id => $self->{session_id},
        todos => $todos,
        updatedAt => time(),
    };
    
    my $file = $self->_todos_file();
    my $json = JSON::PP->new->utf8->pretty->canonical->encode($data);
    
    # Atomic write: write to temp file, then rename
    # This prevents corruption if process is killed during write
    my $temp_file = $file . '.tmp';
    open my $fh, '>:encoding(UTF-8)', $temp_file or die "Cannot create temp todos file: $!";
    print $fh $json;
    close $fh;
    
    # Atomic rename (overwrites target file atomically on Unix)
    rename $temp_file, $file or die "Cannot save todos (rename failed): $!";
    
    print STDERR "[DEBUG][TodoStore] Saved to $file\n" if should_log('DEBUG');
}

sub _has_circular_dependency {
    my ($self, $todo_id, $todos, $visited) = @_;
    
    $visited ||= {};
    
    # If we've already visited this node, we found a cycle
    return 1 if $visited->{$todo_id};
    
    # Find the todo
    my ($todo) = grep { $_->{id} == $todo_id } @$todos;
    return 0 unless $todo;
    
    # If no dependencies, no cycle
    return 0 unless $todo->{dependencies} && @{$todo->{dependencies}};
    
    # Mark this node as visited
    $visited->{$todo_id} = 1;
    
    # Recursively check each dependency
    foreach my $dep_id (@{$todo->{dependencies}}) {
        if ($self->_has_circular_dependency($dep_id, $todos, {%$visited})) {
            return 1;
        }
    }
    
    return 0;
}

1;
