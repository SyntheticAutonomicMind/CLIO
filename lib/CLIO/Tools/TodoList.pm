# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Tools::TodoList;

use strict;
use warnings;
use utf8;
use CLIO::Core::Logger qw(log_debug);
use feature 'say';
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
- write: Create/replace entire list (requires todoList array)
- update: Partial updates (requires todoUpdates array)
- add: Append new todos to existing list (requires newTodos array)

**STATUS VALUES:**
- not-started: Todo not yet begun
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
-  write: Create/replace entire list (requires todoList array)
-  update: Change status of existing todos (requires todoUpdates array)
-  add: Append new todos to existing list (requires newTodos array)

STATUS VALUES: not-started, in-progress (MAX 1 at a time), completed, blocked

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
    
    return {
        todoList => {
            type => "array",
            description => "[REQUIRED for write] Complete array of all todos. IDs will be auto-assigned if creating new list.",
            items => {
                type => "object",
                properties => {
                    id => {
                        type => "integer",
                        description => "[REQUIRED] Unique ID (sequential numbers from 1).",
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
                        enum => ["not-started", "in-progress", "completed", "blocked"],
                        description => "[REQUIRED] Status: not-started, in-progress, completed, blocked.",
                    },
                    priority => {
                        type => "string",
                        enum => ["low", "medium", "high", "critical"],
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
                required => ["id", "title", "description", "status"],
            },
        },
        newTodos => {
            type => "array",
            description => "[REQUIRED for add] New todos to add. IDs will be auto-assigned.",
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
                        enum => ["not-started", "in-progress", "completed", "blocked"],
                        description => "[OPTIONAL] Status. Default: not-started.",
                    },
                    priority => {
                        type => "string",
                        enum => ["low", "medium", "high", "critical"],
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
                        description => "[REQUIRED] ID of todo to update.",
                    },
                    status => {
                        type => "string",
                        enum => ["not-started", "in-progress", "completed", "blocked"],
                        description => "[OPTIONAL] New status.",
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
                        enum => ["low", "medium", "high", "critical"],
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
    my @completed = grep { $_->{status} eq 'completed' } @$todos;
    my @in_progress = grep { $_->{status} eq 'in-progress' } @$todos;
    my @not_started = grep { $_->{status} eq 'not-started' } @$todos;
    my @blocked = grep { $_->{status} eq 'blocked' } @$todos;
    
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
    
    my $store = CLIO::Session::TodoStore->new(
        session_id => $session_id,
        debug => $self->{debug},
        sessions_dir => '.clio/sessions',
    );
    
    # Get existing stats for comparison
    my $existing_todos = $store->read();
    my $existing_completed = scalar(grep { $_->{status} eq 'completed' } @$existing_todos);
    
    my ($success, $error) = $store->write($todo_list);
    
    unless ($success) {
        return $self->error_result($error);
    }
    
    my $total = scalar(@$todo_list);
    my @completed = grep { $_->{status} eq 'completed' } @$todo_list;
    my @in_progress = grep { $_->{status} eq 'in-progress' } @$todo_list;
    my @not_started = grep { $_->{status} eq 'not-started' } @$todo_list;
    
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
    my @completed = grep { $_->{status} eq 'completed' } @$todos;
    my @in_progress = grep { $_->{status} eq 'in-progress' } @$todos;
    my @not_started = grep { $_->{status} eq 'not-started' } @$todos;
    
    $output .= "CURRENT STATE:\n";
    $output .= "  ✓ Completed: " . scalar(@completed) . "\n";
    $output .= "  🔄 In Progress: " . scalar(@in_progress) . "\n";
    $output .= "  [ ] Not Started: " . scalar(@not_started) . "\n";
    
    if (scalar(@completed) == scalar(@$todos) && @$todos > 0) {
        $output .= "\n🎉 All tasks completed!\n";
    }
    
    # Build detailed action description showing what changed
    my @action_details;
    foreach my $update (@$updates) {
        my $todo_id = $update->{id};
        # Find the actual todo to get its title
        my ($todo) = grep { $_->{id} == $todo_id } @$todos;
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

sub handle_add {
    my ($self, $params, $session_id) = @_;
    
    unless ($params->{newTodos}) {
        return $self->error_result("'add' operation requires 'newTodos' parameter");
    }
    
    my $new_todos = $params->{newTodos};
    
    unless (ref $new_todos eq 'ARRAY') {
        return $self->error_result("'newTodos' must be an array");
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
