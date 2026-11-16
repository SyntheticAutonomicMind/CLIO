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

**Storage Location**: .clio/sessions/<session_id>/todos.json

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
6. Incoming updates, adds, and writes may only set known fields

=cut

# Fields a todo record may carry. Incoming data may only set these; an
# unrecognized name is rejected instead of copied into the record.
#
# The alternative - copying every key the caller sent - is worse than
# useless: a model that invents a field (blockedReasonReason, "blockedReason "
# with a trailing space, descriptionX) gets a successful result, the intended
# change never happens, and nothing anywhere records that the call was wrong.
# That is how a blocked todo keeps reporting "has no blockedReason" while the
# model believes it supplied one.
my %TODO_FIELDS = map { $_ => 1 } qw(
    id title description status priority progress dependencies
    blockedReason taskSummary createdAt updatedAt
);

# Fields an update may not set. The id selects the record; the timestamps are
# owned by the store.
my %UPDATE_LOCKED_FIELDS = map { $_ => 1 } qw(id createdAt updatedAt);

# What an update caller may set, derived from the two tables above so the
# two never drift apart.
my %UPDATE_FIELDS = map { $_ => 1 } grep { !$UPDATE_LOCKED_FIELDS{$_} } keys %TODO_FIELDS;

# What an update caller may SEND. 'id' selects the record, so it is accepted
# (and must not be reported as unrecognized) even though it is never applied.
my %UPDATE_ACCEPTED_FIELDS = (%UPDATE_FIELDS, id => 1);

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
        sessions_dir => $opts{sessions_dir} || do { require CLIO::Util::PathResolver; CLIO::Util::PathResolver::get_sessions_dir(); },
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

=head2 _unknown_field_errors (Internal)

Report fields an incoming todo or update may not set.

Arguments:
- $item  - Hashref supplied by the caller
- $allowed - Hashref of field name => 1
- $label - How to name the item in the error ('Todo #4', 'New todo #2')

Returns: List of error strings (empty when every field is known)

The message names the offending fields, the allowed set, and - when a field
name contains characters a field name cannot have - the most likely cause.
A quoted or space-suffixed field name is the signature of a value that was
parsed as a key, which is what a stray quote in the arguments JSON produces.
The model cannot see its own mangled payload any other way: the arguments
parse as valid JSON, so no layer between the model and the tool reports it.

=cut

sub _unknown_field_errors {
    my ($self, $item, $allowed, $label) = @_;

    my @unknown = sort grep { !$allowed->{$_} } keys %$item;
    return () unless @unknown;

    my $shown = join(', ', map { "'" . _clip($_, 60) . "'" } @unknown);
    my $valid = join(', ', sort keys %$allowed);

    my @errors = ("$label has unrecognized field(s): $shown. "
        . "Allowed fields: $valid. An unrecognized name is not applied - "
        . "check the spelling against the schema.");

    my @malformed = grep { $_ !~ /^[A-Za-z_][A-Za-z0-9_]*$/ } @unknown;
    if (@malformed) {
        push @errors, "$label has field name(s) that are not valid identifiers "
            . "(" . join(', ', map { "'" . _clip($_, 60) . "'" } @malformed) . "). "
            . "A field name contains a quote, bracket, or trailing space, which "
            . "means the arguments JSON was malformed: a value was parsed as a "
            . "key. Re-send the call with valid JSON.";
    }

    return @errors;
}

# Trim a string for inclusion in an error message. Field names that arrive
# mangled can be hundreds of characters long; the first 60 identify the
# problem without pasting a whole paragraph of JSON into the transcript.
sub _clip {
    my ($text, $max) = @_;
    $text = '' unless defined $text;
    return $text if length($text) <= $max;
    return substr($text, 0, $max) . '...';
}

=head2 _describe_shape (Internal)

Name the shape of a malformed list entry so the error says what arrived
instead of dying on it. A model that sends todoUpdates as an array of
strings reaches the store as data it cannot dereference; the old code
died, and the eval above it turned that into a stack-trace-flavoured
message with no fix in it.

Arguments: $value
Returns: description string ('a string', 'an array', 'null', ...)

=cut

sub _describe_shape {
    my ($value) = @_;
    return 'null' unless defined $value;
    my $ref = ref $value;
    return 'an object' if $ref eq 'HASH';
    return 'an array'  if $ref eq 'ARRAY';
    return "a $ref reference" if $ref;
    return 'an empty string' unless length $value;
    return 'a string';
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
        # Read as raw bytes: decode_json expects UTF-8 bytes, not
        # Perl's internal character strings.
        open my $fh, '<:raw', $file or croak "Cannot read todos file: $!";
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

    # Same rule as update/add: only known fields may be stored. A write
    # replaces the whole list, so an invented field here would persist for
    # the rest of the session.
    my @field_errors;
    for my $i (0 .. $#$todos) {
        my $todo = $todos->[$i];
        unless (ref($todo) eq 'HASH') {
            push @field_errors, "Entry " . ($i + 1) . " of todoList is "
                . _describe_shape($todo) . ", not an object. Each todo must be an "
                . "object with at least 'title' and 'description'";
            next;
        }
        my $label = _is_valid_id($todo->{id}) ? "Todo #$todo->{id}" : 'New todo #' . ($i + 1);
        push @field_errors, $self->_unknown_field_errors($todo, \%TODO_FIELDS, $label);
    }
    if (@field_errors) {
        return (0, "Todo list validation failed:\n" . join("\n", map { "  - $_" } @field_errors));
    }
    
    # Auto-assign IDs to todos that don't have them
    my $max_id = 0;
    foreach my $todo (@$todos) {
        $max_id = $todo->{id} if _is_valid_id($todo->{id}) && $todo->{id} > $max_id;
    }
    foreach my $todo (@$todos) {
        unless (_is_valid_id($todo->{id})) {
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

    unless (ref($updates) eq 'ARRAY') {
        return (0, "Update validation failed:\n  - 'todoUpdates' must be an array of "
            . "{id, ...fields} objects, not " . _describe_shape($updates));
    }

    # Reject malformed entries and unrecognized fields BEFORE anything is
    # applied, so a rejected update cannot leave a partly-modified list behind
    # and no invented field ever reaches the stored record.
    my @field_errors;
    for my $i (0 .. $#$updates) {
        my $update = $updates->[$i];
        unless (ref($update) eq 'HASH') {
            push @field_errors, "Entry " . ($i + 1) . " of todoUpdates is "
                . _describe_shape($update) . ", not an object. Each entry must be an "
                . "object such as {\"id\": 4, \"status\": \"blocked\", "
                . "\"blockedReason\": \"why\"}";
            next;
        }
        my $label = defined $update->{id} ? "Todo #$update->{id}" : 'An update';
        push @field_errors, $self->_unknown_field_errors($update, \%UPDATE_ACCEPTED_FIELDS, $label);
    }
    if (@field_errors) {
        return (0, "Update validation failed:\n" . join("\n", map { "  - $_" } @field_errors));
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
            if (_is_valid_id($todo->{id}) && $todo->{id} == $todo_id) {
                # Apply updates
                foreach my $key (keys %$update) {
                    # Unreachable after the field check above; kept so a
                    # future caller cannot copy a locked or unknown field
                    # into the record by bypassing that check.
                    next if $UPDATE_LOCKED_FIELDS{$key};
                    next unless $UPDATE_FIELDS{$key};
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

    # Only known fields may be appended. Rejected before anything is
    # assigned an id or merged with the existing list.
    my @field_errors;
    for my $i (0 .. $#$new_todos) {
        my $todo = $new_todos->[$i];
        unless (ref($todo) eq 'HASH') {
            push @field_errors, "Entry " . ($i + 1) . " of newTodos is "
                . _describe_shape($todo) . ", not an object. Each todo must be an "
                . "object with at least 'title' and 'description'";
            next;
        }
        push @field_errors, $self->_unknown_field_errors($todo, \%TODO_FIELDS, 'New todo #' . ($i + 1));
    }
    if (@field_errors) {
        return (0, "Add validation failed:\n" . join("\n", map { "  - $_" } @field_errors));
    }
    
    # Read existing todos
    my $existing = $self->read();
    
    # Find highest existing ID
    my $max_id = 0;
    foreach my $todo (@$existing) {
        $max_id = $todo->{id} if _is_valid_id($todo->{id}) && $todo->{id} > $max_id;
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
        
        # Blocked status requires reason. The received field names are echoed
        # because the usual cause is a field the caller did send under a name
        # the parser mangled - the error is the only place that name is
        # visible, and without it the caller can only guess at the spelling.
        if (defined $todo->{status} && $todo->{status} eq 'blocked' && !$todo->{blockedReason}) {
            my $received = join(', ', map { _clip($_, 40) } sort keys %$todo);
            push @errors, "Todo #$id is blocked but has no blockedReason "
                . "(received fields: $received; a todo with status='blocked' needs "
                . "a 'blockedReason' string)";
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

# Returns true iff $id is a positive integer (the documented shape of
# todo ids per docs/MEMORY.md and the existing validator). Used to
# guard numeric comparisons on $todo->{id} so a corrupt or out-of-shape
# record (e.g. an id of "5b" or undef) does not trigger
# "Argument isn't numeric in numeric gt" warnings from Perl.
sub _is_valid_id {
    my ($id) = @_;
    return 0 unless defined $id;
    return 0 unless $id =~ /^\d+$/;
    return 0 if $id + 0 > 2147483647;  # avoid overflow surprises on 32-bit
    return 1;
}

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
    
    # encode_json_pretty produces UTF-8 bytes; no encoding layer needed
    # (it would double-encode non-ASCII characters).
    atomic_write($file, $json);
    
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
