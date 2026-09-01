# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Session::TodoStore;

use strict;
use warnings;
use utf8;
use CLIO::Core::Logger qw(log_debug);
use Carp qw(croak);
use File::Path qw(make_path);
use File::Spec;
use CLIO::Util::JSON qw(decode_json encode_json_pretty);
use CLIO::Util::AtomicWrite qw(atomic_write);


=head1 NAME

CLIO::Session::TodoStore - Per-session todo list storage backend

=head1 DESCRIPTION

Manages persistence and validation of todo lists for sessions.
Based on SAM's TodoManager pattern.

**Storage Location**: sessions/<session_id>/todos.json

**Todo Item Structure**:
- id: Integer (sequential, starts at 1, auto-assigned if omitted)
- title: String (3-7 words, concise label)
- description: String (detailed context, requirements, file paths)
- status: String (not-started | pending | in-progress | completed | blocked)
  - 'pending' is an alias for 'not-started', normalized on input
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
    
    croak "session_id required" unless $opts{session_id};
    
    my $self = {
        session_id => $opts{session_id},
        debug => $opts{debug} || 0,
        sessions_dir => $opts{sessions_dir} || 'sessions',
        # Invalidates any downstream caches (e.g. PromptBuilder's
        # user_context TTL cache) when a todo mutation lands. The model
        # must see its new todo state on the very next turn, not 60s
        # later. The callback is invoked with $self so subscribers can
        # identify which session mutated.
        _on_invalidate => undef,
    };
    
    bless $self, $class;
    
    # Ensure session directory exists with secure permissions
    my $session_dir = $self->_session_dir();
    unless (-d $session_dir) {
        make_path($session_dir, { mode => 0700 }) or croak "Cannot create session directory $session_dir: $!";
    }
    
    return $self;
}

=head2 set_invalidation_hook

Register a callback to fire after any successful mutation (write/add/
update). Used by PromptBuilder to clear its user_context cache so the
model sees the new todo state on the very next turn instead of waiting
out the 60s cache TTL.

Arguments:
- $callback: coderef, called as $callback->($self) after a mutation.
             Pass undef to clear.

Returns: undef.

=cut

sub set_invalidation_hook {
    my ($self, $callback) = @_;
    $self->{_on_invalidate} = $callback;
    return undef;
}

sub _fire_invalidation {
    my ($self) = @_;
    my $cb = $self->{_on_invalidate};
    return unless $cb && ref($cb) eq 'CODE';
    eval { $cb->($self); };
    if ($@) {
        log_debug('TodoStore', "Invalidation hook threw: $@");
    }
    return;
}

=head2 read

Read current todo list for this session.

Returns: Arrayref of todo items (empty array if no todos exist)

=cut

sub read {
    my ($self) = @_;
    
    my $file = $self->_todos_file();
    
    unless (-e $file) {
        log_debug('TodoStore', "No todos file exists: $file");
        return [];
    }
    
    my $todos;
    eval {
        open my $fh, '<:encoding(UTF-8)', $file or croak "Cannot read todos file: $!";
        local $/;
        my $json = <$fh>;
        close $fh;
        
        my $data = decode_json($json);
        $todos = $data->{todos} || [];
    };
    
    if ($@) {
        log_debug('TodoStore', "Failed to read todos: $@");
        return [];
    }
    
    return $todos;
}

=head2 write

Write complete todo list (replaces entire list).

IDs are auto-assigned to any todo items that don't have one.
The 'pending' status is normalized to 'not-started'.

Arguments:
- todos: Arrayref of todo items (id field optional, auto-assigned)

Returns: (success_bool, error_message_or_undef)

=cut

sub write {
    my ($self, $todos) = @_;
    
    $todos ||= [];
    
    # Auto-assign IDs to todos that don't have them
    my $max_id = 0;
    foreach my $todo (@$todos) {
        $max_id = $todo->{id} if defined $todo->{id} && $todo->{id} > $max_id;
    }
    foreach my $todo (@$todos) {
        unless (defined $todo->{id}) {
            $max_id++;
            $todo->{id} = $max_id;
        }
        # Normalize 'pending' to 'not-started'
        if (defined $todo->{status} && $todo->{status} eq 'pending') {
            $todo->{status} = 'not-started';
        }
        # Default status
        $todo->{status} ||= 'not-started';
    }
    
    # Validate the todo list
    my $errors = $self->validate($todos);
    if (@$errors) {
        my $error_msg = "Todo list validation failed:\n" . join("\n", map { "  - $_" } @$errors);
        log_debug('TodoStore', "$error_msg");
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
        log_debug('TodoStore', "Failed to save todos: $@");
        return (0, "Failed to save todos: $@");
    }
    
    log_debug('TodoStore', "Wrote " . scalar(@$todos) . " todos for session $self->{session_id}");
    $self->_fire_invalidation();
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
        
        # Validate that todo_id is a positive integer to prevent
        # "isn't numeric" warnings when comparing string IDs
        unless (defined $todo_id && $todo_id =~ /^\d+$/ && $todo_id > 0) {
            push @failed, "Invalid todo ID '$todo_id': must be a positive integer";
            next;
        }
        
        # Normalize 'pending' to 'not-started'
        if (defined $update->{status} && $update->{status} eq 'pending') {
            $update->{status} = 'not-started';
        }
        
        my $found = 0;
        
        foreach my $todo (@$todos) {
            if (defined $todo->{id} && $todo->{id} == $todo_id) {
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
    
    # If ALL updates failed, return error
    if (!@applied && @failed) {
        my $error_msg = "All updates failed:\n" . join("\n", map { "  - $_" } @failed);
        return (0, $error_msg);
    }
    
    $self->_fire_invalidation();
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
        # Normalize 'pending' to 'not-started'
        if (defined $new_todo->{status} && $new_todo->{status} eq 'pending') {
            $new_todo->{status} = 'not-started';
        }
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
    
    log_debug('TodoStore', "Added " . scalar(@$new_todos) . " new todos");
    $self->_fire_invalidation();
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
    my %todo_ids = map { defined $_->{id} ? ($_->{id} => 1) : () } @$todos;

    # Count in-progress todos
    my @in_progress = grep { defined $_->{status} && $_->{status} eq 'in-progress' } @$todos;
    if (@in_progress > 1) {
        push @errors, "Multiple todos marked as in-progress (only 1 allowed): " . 
            join(", ", map { defined $_->{id} ? "#$_->{id}" : "#(unknown)" } @in_progress);
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
            unless ($todo->{status} =~ /^(not-started|pending|in-progress|completed|blocked)$/) {
                push @errors, "Todo #$id has invalid status '$todo->{status}'";
            }
        }
        
        # Dependencies must exist
        # Defensive: dependencies may arrive as an arrayref, an integer
        # (single upstream task), a hashref (provider serialization),
        # or a CSV string. Reject anything that is not a non-empty
        # arrayref so we don't crash on @{} deref here.
        my $deps = $todo->{dependencies};
        if (defined $deps && ref($deps) ne 'ARRAY') {
            push @errors, "Todo #$id has invalid 'dependencies' field (expected array of todo IDs, got " .
                (ref($deps) || 'scalar') . ")";
        }
        elsif ($deps && @$deps) {
            foreach my $dep_id (@$deps) {
                unless (defined $dep_id && $todo_ids{$dep_id}) {
                    push @errors, "Todo #$id depends on non-existent todo #$dep_id";
                }
            }
        }
        
        # Circular dependency detection
        if ($self->_has_circular_dependency($id, $todos)) {
            push @errors, "Todo #$id has circular dependency";
        }
        
        # Blocked status requires reason
        if (defined $todo->{status} && $todo->{status} eq 'blocked' && !$todo->{blockedReason}) {
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
    my $json = encode_json_pretty($data);
    
    atomic_write($file, $json, encoding => 'UTF-8');
    
    log_debug('TodoStore', "Saved to $file");
}

sub _has_circular_dependency {
    my ($self, $todo_id, $todos, $visited) = @_;
    
    $visited ||= {};
    
    # Guard against non-numeric todo_id
    return 0 unless defined $todo_id && $todo_id =~ /^\d+$/;
    
    # If we've already visited this node, we found a cycle
    return 1 if $visited->{$todo_id};
    
    # Find the todo
    my ($todo) = grep { defined $_->{id} && $_->{id} == $todo_id } @$todos;
    return 0 unless $todo;
    
    # If no dependencies, no cycle
    # Guard against non-arrayref dependencies (e.g. CSV string from a
    # misbehaving provider). Same shape as the validate() guard above.
    return 0 unless $todo->{dependencies}
                && ref($todo->{dependencies}) eq 'ARRAY'
                && @{$todo->{dependencies}};

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
