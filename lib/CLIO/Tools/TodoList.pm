# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Tools::TodoList;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
use CLIO::Core::Logger qw(log_debug);
use parent 'CLIO::Tools::Tool';
use CLIO::Session::TodoStore;

=head1 NAME

CLIO::Tools::TodoList - Todo list management tool

=head1 DESCRIPTION

Manage structured todo lists to track progress and plan tasks.
Based on SAM's TodoOperationsTool pattern.

**WORKFLOW - FOLLOW EXACTLY:**

STEP 1 - CREATE THE LIST (first time only):
→ Call: write operation with todoList array (all marked "not-started")

STEP 2 - MARK ONE TODO IN-PROGRESS:
→ Call: update operation with id + status="in-progress"
→ Only ONE todo can be in-progress at a time

STEP 3 - DO THE WORK:
→ Execute the task using appropriate tools

STEP 4 - MARK TODO COMPLETE:
→ Call: update operation with id + status="completed"
→ Do this IMMEDIATELY after finishing each todo

STEP 5 - REPEAT:
→ Go back to STEP 2 for next todo

**OPERATIONS:**
- read: Get current todo list
- write: Create/replace entire list (requires todoList array, IDs auto-assigned)
- update: Partial updates (requires todoUpdates array)
- add: Append new todos to existing list (requires newTodos array, IDs auto-assigned)

**STATUS VALUES:**
- not-started: Todo not yet begun (alias: pending)
- in-progress: Currently working (max 1 at a time)
- completed: Fully finished
- blocked: Blocked on external dependency

=cut

sub new {
    my ($class, %opts) = @_;
    
    return $class->SUPER::new(
        name => 'todo_operations',
        description => <<'EOF',
Manage a structured todo list to track progress and plan tasks.

**MANDATORY** for multi-step tasks. Skip only for single trivial tasks or conversational questions.

OPERATIONS:
-  read: Get current todo list
-  write: Create/replace entire list (requires todoList array, IDs auto-assigned if omitted)
-  update: Change status of existing todos (requires todoUpdates array)
-  add: Append new todos to existing list (requires newTodos array, IDs auto-assigned)

STATUS VALUES: not-started, pending (alias for not-started), in-progress (MAX 1 at a time), completed, blocked

WORKFLOW: Create list with write -> mark first in-progress -> do work -> mark completed -> mark next in-progress -> repeat.

RULES:
- Create todos FIRST before updating them
- Mark each complete IMMEDIATELY after finishing (don't batch)
- Max 1 todo in-progress at a time
- Call update to change status (system cannot infer from text)
EOF
        supported_operations => [qw(read write update add)],
        debug => $opts{debug} || 0,
    );
}

sub dispatch_table {
    return {
        read   => '_dispatch_read',
        write  => '_dispatch_write',
        update => '_dispatch_update',
        add    => '_dispatch_add',
    };
}

# Dispatch wrappers adapt the standard ($params, $context) signature
# to TodoList's ($session_id) / ($params, $session_id) methods

sub _dispatch_read {
    my ($self, $params, $context) = @_;
    my $session_id = $self->_session_id($context);
    return $self->handle_read($session_id);
}

sub _dispatch_write {
    my ($self, $params, $context) = @_;
    my $session_id = $self->_session_id($context);
    return $self->handle_write($params, $session_id);
}

sub _dispatch_update {
    my ($self, $params, $context) = @_;
    my $session_id = $self->_session_id($context);
    return $self->handle_update($params, $session_id);
}

sub _dispatch_add {
    my ($self, $params, $context) = @_;
    my $session_id = $self->_session_id($context);
    return $self->handle_add($params, $session_id);
}

sub _session_id {
    my ($self, $context) = @_;
    return $context->{session}{session_id} || $context->{session_id} || 'default';
}

sub get_additional_parameters {
    my ($self) = @_;
    
    # Shared enum arrays (safe to reuse)
    my $status_enum = ["not-started", "pending", "in-progress", "completed", "blocked"];
    my $priority_enum = ["low", "medium", "high", "critical"];
    
    return {
        todoList => {
            type => "array",
            description => "[REQUIRED for write - full list replacement] Complete array of all todos. IDs auto-assigned if omitted. Use write to create or replace entire list; use add to append.",
            items => {
                type => "object",
                properties => {
                    id => {
                        type => "integer",
                        description => "[OPTIONAL] Unique ID. Auto-assigned if omitted (sequential from 1).",
                    },
                    title => {
                        type => "string",
                        description => "[REQUIRED] Todo label (3-7 words).",
                    },
                    description => {
                        type => "string",
                        description => "[REQUIRED] Context, requirements, file paths, etc.",
                    },
                    status => {
                        type => "string",
                        enum => $status_enum,
                        description => "[REQUIRED] Status. 'pending' is an alias for 'not-started'.",
                    },
                    priority => {
                        type => "string",
                        enum => $priority_enum,
                        description => "[OPTIONAL] Priority level.",
                    },
                    dependencies => {
                        type => "array",
                        items => { type => "integer" },
                        description => "[OPTIONAL] Array of todo IDs this task depends on.",
                    },
                    progress => {
                        type => "number",
                        description => "[OPTIONAL] Progress 0.0-1.0 as decimal.",
                    },
                    blockedReason => {
                        type => "string",
                        description => "[REQUIRED if status=blocked] Reason why task is blocked.",
                    },
                },
                required => ["title", "description", "status"],
            },
        },
        newTodos => {
            type => "array",
            description => "[REQUIRED for add - append to list] New todos to append to existing list. IDs auto-assigned if omitted. Use write to replace entire list; use add to append.",
            items => {
                type => "object",
                properties => {
                    title => {
                        type => "string",
                        description => "[REQUIRED] Todo label (3-7 words).",
                    },
                    description => {
                        type => "string",
                        description => "[REQUIRED] Context, requirements, file paths, etc.",
                    },
                    status => {
                        type => "string",
                        enum => $status_enum,
                        description => "[OPTIONAL] Status. Default: not-started. 'pending' is an alias for 'not-started'.",
                    },
                    priority => {
                        type => "string",
                        enum => $priority_enum,
                        description => "[OPTIONAL] Priority level.",
                    },
                },
                required => ["title", "description"],
            },
        },
        todoUpdates => {
            type => "array",
            description => "[REQUIRED for update] Array of {id, ...fields to change} objects.",
            items => {
                type => "object",
                properties => {
                    id => {
                        type => "integer",
                        description => "[REQUIRED] ID of todo to update. Must be a positive integer (1, 2, 3...). IDs are auto-assigned when creating todos with the write operation.",
                    },
                    status => {
                        type => "string",
                        enum => $status_enum,
                        description => "[OPTIONAL] New status. 'pending' is an alias for 'not-started'.",
                    },
                    title => {
                        type => "string",
                        description => "[OPTIONAL] New title.",
                    },
                    description => {
                        type => "string",
                        description => "[OPTIONAL] New description.",
                    },
                    progress => {
                        type => "number",
                        description => "[OPTIONAL] New progress 0.0-1.0.",
                    },
                    priority => {
                        type => "string",
                        enum => $priority_enum,
                        description => "[OPTIONAL] New priority.",
                    },
                    blockedReason => {
                        type => "string",
                        description => "[OPTIONAL] Reason for blocked status.",
                    },
                },
                required => ["id"],
            },
        },
    };
}

# MARK: - Operation Handlers

sub handle_read {
    my ($self, $session_id) = @_;
    
    my $store = CLIO::Session::TodoStore->new(
        session_id => $session_id,
        debug => $self->{debug},
        sessions_dir => '.clio/sessions',
    );
    
    my $todos = $store->read();
    
    if (!@$todos) {
        return $self->success_result(
            "No todos yet. Create a todo list with the 'write' operation.",
            action_description => "reading todo list (empty)",
        );
    }
    
    # Generate summary
    my $total = scalar(@$todos);
    my @completed = grep { defined $_->{status} && $_->{status} eq 'completed' } @$todos;
    my @in_progress = grep { defined $_->{status} && $_->{status} eq 'in-progress' } @$todos;
    my @not_started = grep { defined $_->{status} && $_->{status} eq 'not-started' } @$todos;
    my @blocked = grep { defined $_->{status} && $_->{status} eq 'blocked' } @$todos;

    my $output = "Todo list: $total items\n\n";
    $output .= "STATUS SUMMARY:\n";
    $output .= "  ✓ Completed: " . scalar(@completed) . "\n";
    $output .= "  🔄 In Progress: " . scalar(@in_progress) . "\n";
    $output .= "  [ ] Not Started: " . scalar(@not_started) . "\n";
    $output .= "  ⚠️ Blocked: " . scalar(@blocked) . "\n" if @blocked;
    $output .= "\n";
    
    # List todos by status
    if (@in_progress) {
        $output .= "IN PROGRESS:\n";
        foreach my $todo (@in_progress) {
            $output .= "  🔄 #$todo->{id}: $todo->{title}\n";
            $output .= "     $todo->{description}\n";
        }
        $output .= "\n";
    }
    
    if (@not_started) {
        $output .= "NOT STARTED:\n";
        foreach my $todo (@not_started) {
            my $priority = $todo->{priority} ? " [$todo->{priority}]" : "";
            $output .= "  [ ] #$todo->{id}: $todo->{title}$priority\n";
        }
        $output .= "\n";
    }
    
    if (@completed) {
        $output .= "COMPLETED:\n";
        foreach my $todo (@completed) {
            $output .= "  ✓ #$todo->{id}: $todo->{title}\n";
        }
        $output .= "\n";
    }
    
    if (@blocked) {
        $output .= "BLOCKED:\n";
        foreach my $todo (@blocked) {
            $output .= "  ⚠️ #$todo->{id}: $todo->{title}\n";
            $output .= "     Reason: $todo->{blockedReason}\n";
        }
        $output .= "\n";
    }
    
    my $summary = "$total items: " . scalar(@completed) . " done, " . 
                  scalar(@in_progress) . " in progress, " . scalar(@not_started) . " pending";
    my $action_desc = "reading todo list ($summary)";
    
    return $self->success_result($output, action_description => $action_desc, todos => $todos);
}

sub handle_write {
    my ($self, $params, $session_id) = @_;
    
    unless ($params->{todoList}) {
        return $self->error_result("'write' operation requires 'todoList' parameter");
    }
    
    my $todo_list = $params->{todoList};
    
    unless (ref $todo_list eq 'ARRAY') {
        return $self->error_result("'todoList' must be an array");
    }

    # Pre-validate required fields before sending to store
    for my $i (0 .. $#$todo_list) {
        my $todo = $todo_list->[$i];
        my $num = $i + 1;
        my @missing;
        push @missing, 'title' unless $todo->{title};
        push @missing, 'description' unless $todo->{description};
        push @missing, 'status' unless $todo->{status};
        if (@missing) {
            my $got = join(", ", sort keys %$todo) || "(empty)";
            return $self->error_result(
                "todoList item #$num is missing required field(s): " .
                join(", ", @missing) . ". " .
                "Got fields: $got. " .
                "Each todoList item MUST have 'title', 'description', and 'status'."
            );
        }
    }
    
    my $store = CLIO::Session::TodoStore->new(
        session_id => $session_id,
        debug => $self->{debug},
        sessions_dir => '.clio/sessions',
    );
    
    # Get existing stats for comparison
    my $existing_todos = $store->read();
    my $existing_completed = scalar(grep { defined $_->{status} && $_->{status} eq 'completed' } @$existing_todos);
    
    my ($success, $error) = $store->write($todo_list);
    
    unless ($success) {
        return $self->error_result($error);
    }
    
    my $total = scalar(@$todo_list);
    my @completed = grep { defined $_->{status} && $_->{status} eq 'completed' } @$todo_list;
    my @in_progress = grep { defined $_->{status} && $_->{status} eq 'in-progress' } @$todo_list;
    my @not_started = grep { defined $_->{status} && $_->{status} eq 'not-started' } @$todo_list;

    my $output = "Todo list updated: $total items\n\n";
    
    if ($existing_completed > 0) {
        $output .= "PREVIOUS STATE: $existing_completed completed\n";
    }
    
    $output .= "NEW STATE:\n";
    $output .= "  ✓ Completed: " . scalar(@completed) . "\n";
    $output .= "  🔄 In Progress: " . scalar(@in_progress) . "\n";
    $output .= "  [ ] Not Started: " . scalar(@not_started) . "\n\n";
    
    if (@in_progress) {
        $output .= "Now working on: " . join(", ", map { $_->{title} } @in_progress) . "\n";
    }
    elsif (@not_started) {
        $output .= "Todo list ready. " . scalar(@not_started) . " item(s) not started.\n";
    }
    
    if (scalar(@completed) == $total && $total > 0) {
        $output .= "\n🎉 All tasks completed!\n";
    }
    
    # Build specific action description
    my $action_desc;
    if ($total == 0) {
        $action_desc = "writing empty todo list";
    } elsif (@in_progress) {
        my $first_task = $in_progress[0]->{title};
        $action_desc = "writing todo list with $total items, starting: $first_task";
    } elsif (@not_started) {
        my $first_task = $not_started[0]->{title};
        $action_desc = "writing todo list with $total items: $first_task" . ($total > 1 ? ", ..." : "");
    } else {
        $action_desc = "writing todo list ($total items)";
    }
    
    return $self->success_result($output, action_description => $action_desc);
}

sub handle_update {
    my ($self, $params, $session_id) = @_;
    
    unless ($params->{todoUpdates}) {
        return $self->error_result("'update' operation requires 'todoUpdates' parameter");
    }
    
    my $updates = $params->{todoUpdates};
    
    unless (ref $updates eq 'ARRAY') {
        return $self->error_result("'todoUpdates' must be an array");
    }
    
    my $store = CLIO::Session::TodoStore->new(
        session_id => $session_id,
        debug => $self->{debug},
        sessions_dir => '.clio/sessions',
    );
    
    # Detect status transitions BEFORE applying updates so we can capture
    # the previous status for each todo. This drives task boundary emission
    # AND task-summary compression: any-not-started->in-progress opens a
    # new task block; in-progress->completed closes it (and we compress
    # the dialog that belongs to that task into the todo's taskSummary).
    my $existing_todos = $store->read();
    my %prev_status = map {
        defined $_->{id} ? ($_->{id} => $_->{status} // 'not-started') : ()
    } @$existing_todos;

    # Lazy require the Session manager so unit tests that bypass the
    # normal dispatch don't crash here.
    my $session_mgr;
    eval { require CLIO::Session::Manager; };
    if (!$@) {
        $session_mgr = CLIO::Session::Manager->new(
            session_id => $session_id,
            sessions_dir => '.clio/sessions',
            debug => $self->{debug},
        );
    }

    my ($success, $result) = $store->update($updates);

    unless ($success) {
        return $self->error_result($result);
    }
    
    my $output = "Todo updates applied: $result->{summary}\n\n";
    
    if (@{$result->{applied}}) {
        $output .= "UPDATES APPLIED:\n";
        foreach my $update (@{$result->{applied}}) {
            $output .= "  ✓ $update\n";
        }
        $output .= "\n";
    }
    
    if (@{$result->{failed}}) {
        $output .= "FAILED UPDATES:\n";
        foreach my $failure (@{$result->{failed}}) {
            $output .= "  ✗ $failure\n";
        }
        $output .= "\n";
    }
    
    # Show current state
    my $todos = $store->read();
    my @completed = grep { defined $_->{status} && $_->{status} eq 'completed' } @$todos;
    my @in_progress = grep { defined $_->{status} && $_->{status} eq 'in-progress' } @$todos;
    my @not_started = grep { defined $_->{status} && $_->{status} eq 'not-started' } @$todos;

    $output .= "CURRENT STATE:\n";
    $output .= "  ✓ Completed: " . scalar(@completed) . "\n";
    $output .= "  🔄 In Progress: " . scalar(@in_progress) . "\n";
    $output .= "  [ ] Not Started: " . scalar(@not_started) . "\n";
    my @with_summary = grep { defined $_->{taskSummary} && length $_->{taskSummary} > 0 } @$todos;
    if (@with_summary) {
        $output .= "   With task summary: " . scalar(@with_summary) . "\n";
    }

    if (scalar(@completed) == scalar(@$todos) && @$todos > 0) {
        $output .= "\n All tasks completed!\n";
    }

    # Surface captured task summaries so the user can see the compressed
    # history of completed todos without grepping through raw dialog.
    if (@with_summary) {
        $output .= "\nTASK SUMMARIES (compressed context for completed todos):\n";
        for my $todo (sort { ($a->{completedAt} || 0) <=> ($b->{completedAt} || 0) } @with_summary) {
            $output .= "\n  #$todo->{id}: $todo->{title}\n";
            my $summary = $todo->{taskSummary} || '';
            if (length($summary) > 500) {
                $summary = substr($summary, 0, 500) . '...';
            }
            $output .= "    " . $summary . "\n";
        }
    }

    # When a todo is being completed, compress the dialog that belongs to
    # its task and persist the result as taskSummary. This is the seam
    # between the TodoStore and YaRN compression - the todo lifecycle
    # drives when summaries are produced.
    my @completing_now;
    for my $update (@$updates) {
        next unless ($update->{status} // '') eq 'completed';
        next unless defined $update->{id};
        my $prev = $prev_status{$update->{id}} // 'not-started';
        next unless $prev eq 'in-progress';
        push @completing_now, $update->{id};
    }

    if (@completing_now) {
        # Acquire history. session_mgr is built earlier; if it's undef
        # (e.g. a test that doesn't load Session::Manager), we just skip
        # the compression step. This is non-fatal.
        if ($session_mgr && $session_mgr->can('get_conversation_history')) {
            my $history = $session_mgr->get_conversation_history();
            if ($history && @$history) {
                my $task_summaries = $self->_compress_completed_tasks(
                    $history, \@completing_now, $todos,
                );
                # task_summaries is { todo_id => summary_string }
                for my $todo_id (@completing_now) {
                    next unless $task_summaries && $task_summaries->{$todo_id};
                    my ($todo) = grep { defined $_->{id} && $_->{id} == $todo_id } @$todos;
                    next unless $todo;
                    my $summary = $task_summaries->{$todo_id};
                    my ($ok, $err) = $store->update([{
                        id => $todo_id,
                        taskSummary => $summary,
                        completedAt => time(),
                    }]);
                    if ($ok) {
                        log_debug('TodoList', "Persisted taskSummary for todo #$todo_id (" .
                            length($summary) . " chars)");
                    } else {
                        log_warning('TodoList', "Failed to persist taskSummary for todo #$todo_id: $err");
                    }
                }
            }
        } else {
            log_debug('TodoList', "Skipping task summary compression - session manager not available");
        }
    }

    # Build detailed action description showing what changed
    my @action_details;
    foreach my $update (@$updates) {
        my $todo_id = $update->{id};
        # Skip updates without valid todo_id
        unless (defined $todo_id) {
            push @action_details, "update with missing todo id skipped";
            next;
        }
        # Validate that todo_id is a positive integer
        unless ($todo_id =~ /^\d+$/ && $todo_id > 0) {
            push @action_details, "update with invalid todo id '$todo_id' skipped";
            next;
        }
        # Find the actual todo to get its title
        my ($todo) = grep { defined $_->{id} && $_->{id} == $todo_id } @$todos;
        my $title = $todo ? $todo->{title} : "unknown";
        
        # Determine what changed
        if ($update->{status}) {
            if ($update->{status} eq 'completed') {
                push @action_details, "marked #$todo_id '$title' as completed";
            } elsif ($update->{status} eq 'in-progress') {
                push @action_details, "started #$todo_id '$title'";
            } elsif ($update->{status} eq 'not-started') {
                push @action_details, "reset #$todo_id '$title' to not-started";
            } elsif ($update->{status} eq 'blocked') {
                push @action_details, "blocked #$todo_id '$title'";
            } else {
                push @action_details, "updated #$todo_id '$title' status to $update->{status}";
            }
        } else {
            push @action_details, "updated #$todo_id '$title'";
        }
    }
    
    my $action_desc = @action_details == 1 
        ? $action_details[0]
        : "updating todos: " . join(", ", @action_details);
    
    return $self->success_result($output, action_description => $action_desc);
}

=head2 _compress_completed_tasks($history, \@completing_ids, \@todos)

For each todo that just transitioned to 'completed', compress the dialog
that belongs to its task and return a hashref mapping todo_id to a
summary string suitable for storage as taskSummary.

The compression strategy: walk the dialog and split it into per-task
fragments using <task_boundary> markers (the same mechanism YaRN uses
internally). For each completed todo, find the messages between its
opening and closing <task_boundary> tags and compress them with YaRN.

Returns: { todo_id => summary_string }

=cut

sub _compress_completed_tasks {
    my ($self, $history, $completing_ids, $todos) = @_;

    return undef unless $history && @$history;
    return {} unless $completing_ids && @$completing_ids;

    require CLIO::Memory::YaRN;

    # Map task_boundary_id -> todo_id so we can attach the right summary.
    # TodoList::handle_update emits boundaries with id="task-<todo_id>-<ts>".
    my %boundary_to_todo;
    for my $todo (@$todos) {
        next unless $todo->{taskBoundaryId};
        $boundary_to_todo{$todo->{taskBoundaryId}} = $todo->{id};
    }

    # Walk history and group messages by task_boundary_id.
    # The first <task_boundary ...> starts the bucket. Messages that come
    # before any boundary go into '_pre_task' (we don't summarize those -
    # they're the original user request and should remain verbatim).
    my %fragments;   # todo_id_or_unknown => [messages...]
    my $current_bid = '_pre_task';
    my $last_closing_tid;  # The todo whose task just ended.

    for my $msg (@$history) {
        my $content = $msg->{content} // '';
        my $role    = $msg->{role}    // '';

        # Track task boundaries. Closing boundaries close the active bucket
        # and capture its owner (the todo that just completed).
        if ($role eq 'system' && $content =~ /<task_boundary\b([^>]*?)\/?>/) {
            my $attrs = $1;
            my $bid   = '_unknown';
            my $bstatus = 'active';
            if ($attrs =~ /\bid="([^"]*)"/)     { $bid = $1; }
            if ($attrs =~ /\bstatus="([^"]*)"/) { $bstatus = $1; }

            if ($bstatus eq 'completed' && $boundary_to_todo{$bid}) {
                $last_closing_tid = $boundary_to_todo{$bid};
                # Map the bucket by its boundary id, which we keyed on
                # when the active boundary was emitted.
                $current_bid = $bid;
                # Don't reset to '_pre_task' - subsequent messages still
                # belong to the just-completed task until something else
                # opens. The next <task_boundary> (active) will switch.
                next;
            }
            elsif ($bstatus eq 'active') {
                $current_bid = $bid;
                $last_closing_tid = undef;
                next;
            }
        }

        # Skip task_boundary system messages themselves (they're metadata,
        # not dialog content).
        next if $role eq 'system' && $content =~ /<task_boundary/;

        # Otherwise append to the current bucket.
        push @{$fragments{$current_bid}}, $msg;
    }

    my $yarn = CLIO::Memory::YaRN->new(debug => $self->{debug});
    my %summaries;

    for my $todo_id (@$completing_ids) {
        # Find the bucket that ended when this todo was completed.
        # Look up the todo's boundary_id; the fragment is keyed by that id.
        my ($todo) = grep { defined $_->{id} && $_->{id} == $todo_id } @$todos;
        next unless $todo;
        my $bid = $todo->{taskBoundaryId};
        next unless $bid && $fragments{$bid};

        my $messages = $fragments{$bid};
        my $compressed = $yarn->compress_messages($messages);
        next unless $compressed && $compressed->{content};
        $summaries{$todo_id} = $compressed->{content};
    }

    return \%summaries;
}

sub handle_add {
    my ($self, $params, $session_id) = @_;
    
    unless ($params->{newTodos}) {
        return $self->error_result("'add' operation requires 'newTodos' parameter");
    }
    
    my $new_todos = $params->{newTodos};
    
    unless (ref $new_todos eq 'ARRAY') {
        return $self->error_result("'newTodos' must be an array");
    }

    # Pre-validate required fields before sending to store
    # This gives the model a clearer error than the generic validation
    for my $i (0 .. $#$new_todos) {
        my $todo = $new_todos->[$i];
        my $num = $i + 1;
        my @missing;
        push @missing, 'title' unless $todo->{title};
        push @missing, 'description' unless $todo->{description};
        if (@missing) {
            my $got = join(", ", sort keys %$todo) || "(empty)";
            return $self->error_result(
                "newTodos item #$num is missing required field(s): " .
                join(", ", @missing) . ". " .
                "Got fields: $got. " .
                "Each newTodos item MUST have 'title' (3-7 word label) and 'description' (details/context)."
            );
        }
        # Remove id if present - add() auto-assigns IDs
        delete $todo->{id};
    }
    
    my $store = CLIO::Session::TodoStore->new(
        session_id => $session_id,
        debug => $self->{debug},
        sessions_dir => '.clio/sessions',
    );
    
    my ($success, $error) = $store->add($new_todos);
    
    unless ($success) {
        return $self->error_result($error);
    }
    
    my $count = scalar(@$new_todos);
    my $output = "Added $count new todo(s) to list\n\n";
    
    $output .= "NEW TODOS:\n";
    foreach my $todo (@$new_todos) {
        my $priority = $todo->{priority} ? " [$todo->{priority}]" : "";
        $output .= "  [ ] #$todo->{id}: $todo->{title}$priority\n";
    }
    
    # Build specific action description with todo titles
    my $action_desc;
    if ($count == 1) {
        $action_desc = "adding todo: " . $new_todos->[0]->{title};
    } elsif ($count == 2) {
        $action_desc = "adding todos: " . join(", ", map { $_->{title} } @$new_todos);
    } else {
        # For 3+ todos, just show count
        my @titles = map { $_->{title} } @$new_todos[0..1];
        $action_desc = "adding $count todos: " . join(", ", @titles) . ", ...";
    }
    
    return $self->success_result($output, action_description => $action_desc);
}

1;
