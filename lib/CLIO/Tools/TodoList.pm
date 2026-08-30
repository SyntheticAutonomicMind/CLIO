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
use CLIO::UI::Terminal qw(ui_char);

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

REQUIRES the 'operation' parameter on every call. The 'description' field is REQUIRED on every todo item.

OPERATIONS (which parameter each operation needs):
-  read:    no params beyond operation
-  write:   REQUIRES 'todoList' (full array, replaces existing list)
-  update:  REQUIRES 'todoUpdates' (NOT todoList - array of {id, ...changes})
-  add:     REQUIRES 'newTodos' (NOT todoList - array of new todos to append)

COMMON MISTAKE: Sending todo content in the wrong field. The 'update' operation needs
'todoUpdates' (array of {id, status, ...}). The 'write' operation needs 'todoList'
(array of full todos). They are NOT interchangeable.

STATUS VALUES: not-started, pending (alias for not-started), in-progress (MAX 1 at a time), completed, blocked

WORKFLOW: Create list with write -> mark first in-progress -> do work -> mark completed -> mark next in-progress -> repeat.

RULES:
- Create todos FIRST before updating them
- Mark each complete IMMEDIATELY after finishing (don't batch)
- Max 1 todo in-progress at a time
- Call update to change status (system cannot infer from text)

QUICK EXAMPLE:
{"operation": "write", "todoList": [{"title": "Fix bug", "description": "...", "status": "not-started"}]}
{"operation": "update", "todoUpdates": [{"id": 1, "status": "in-progress"}]}
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
    
    # Build the structured output. _render_status_counts and
    # _render_todo_row use ui_char() so markers fall back through
    # Unicode -> CP437 -> ASCII instead of hardcoding emoji.
    my $output = "Todo list: " . scalar(@$todos) . " items\n\n";
    $output .= $self->_render_status_counts(@$todos);
    $output .= "\n";

    if (@{[ grep { ($_->{status} // "") eq "in-progress" } @$todos ]}) {
        $output .= "IN PROGRESS:\n";
        for my $todo (@{[ grep { ($_->{status} // "") eq "in-progress" } @$todos ]}) {
            $output .= $self->_render_todo_row($todo, "in_progress");
            $output .= "     $todo->{description}\n" if $todo->{description};
        }
        $output .= "\n";
    }

    if (@{[ grep { ($_->{status} // "") eq "not-started" } @$todos ]}) {
        $output .= "NOT STARTED:\n";
        for my $todo (@{[ grep { ($_->{status} // "") eq "not-started" } @$todos ]}) {
            $output .= $self->_render_todo_row($todo, "not_started");
        }
        $output .= "\n";
    }

    if (@{[ grep { ($_->{status} // "") eq "completed" } @$todos ]}) {
        $output .= "COMPLETED:\n";
        for my $todo (@{[ grep { ($_->{status} // "") eq "completed" } @$todos ]}) {
            $output .= $self->_render_todo_row($todo, "completed");
        }
        $output .= "\n";
    }

    if (@{[ grep { ($_->{status} // "") eq "blocked" } @$todos ]}) {
        $output .= "BLOCKED:\n";
        for my $todo (@{[ grep { ($_->{status} // "") eq "blocked" } @$todos ]}) {
            $output .= $self->_render_todo_row($todo, "blocked");
            $output .= "     Reason: $todo->{blockedReason}\n" if $todo->{blockedReason};
        }
        $output .= "\n";
    }

    my @counts = $self->_count_statuses(@$todos);
    my $summary = "@{[ scalar @$todos ]} items: $counts[0] done, $counts[1] in progress, $counts[2] pending";
    my $action_desc = "reading todo list ($summary)";

    return $self->success_result($output, action_description => $action_desc, todos => $todos);
}

=head2 _render_status_counts(@todos)

Render a one-line-per-status count block. Uses ui_char() so the markers
fall back through Unicode -> CP437 -> ASCII. No hardcoded emoji, no
mixed conventions - every status row gets a consistent column-aligned
prefix.

Arguments:
    @todos - Array of todo hashes (each must have 'status' key)

Returns: Multi-line string with status counts.

=cut

sub _render_status_counts {
    my ($self, @todos) = @_;
    my ($completed, $in_progress, $not_started, $blocked) = $self->_count_statuses(@todos);

    my $check   = ui_char('check');
    my $info    = ui_char('info');
    my $warn    = ui_char('cross_mark');
    my $pending = '   ';  # No character defined for not-started; aligned-space prefix.

    my $out = '';
    $out .= sprintf("   %s Completed:   %d\n", $check,   $completed);
    $out .= sprintf("   %s In Progress: %d\n", $info,    $in_progress);
    $out .= sprintf("   %s Not Started: %d\n", $pending, $not_started);
    $out .= sprintf("   %s Blocked:     %d\n", $warn,    $blocked) if $blocked;
    return $out;
}

=head2 _count_statuses(@todos)

Tally todos by status. Returns (completed, in_progress, not_started, blocked).

=cut

sub _count_statuses {
    my ($self, @todos) = @_;
    my $completed   = scalar grep { ($_->{status} // '') eq 'completed' }    @todos;
    my $in_progress = scalar grep { ($_->{status} // '') eq 'in-progress' }  @todos;
    my $not_started = scalar grep { ($_->{status} // '') eq 'not-started' }  @todos;
    my $blocked     = scalar grep { ($_->{status} // '') eq 'blocked' }      @todos;
    return ($completed, $in_progress, $not_started, $blocked);
}

=head2 _render_todo_row($todo, $status_marker)

Render a single todo row using the project's standard marker convention.
Marker is one of: 'completed', 'in_progress', 'not_started', 'blocked'.
Priority, if set, is appended in brackets.

=cut

sub _render_todo_row {
    my ($self, $todo, $status_marker) = @_;

    my %markers = (
        completed   => ui_char('check'),
        in_progress => ui_char('info'),
        not_started => '   ',  # Aligned-space; no glyph defined for pending.
        blocked     => ui_char('cross_mark'),
    );
    my $marker = $markers{$status_marker} // '   ';

    my $priority = $todo->{priority} ? " [$todo->{priority}]" : '';
    return sprintf("   %s #%d: %s%s\n", $marker, $todo->{id}, $todo->{title}, $priority);
}

=head2 _all_completed_message(@todos)

Returns a celebration-style line if every todo is completed, undef
otherwise. Centralized so handle_write / handle_update / handle_read
all show the same signal.

=cut

sub _all_completed_message {
    my ($self, @todos) = @_;
    my ($completed, $in_progress, $not_started, $blocked) = $self->_count_statuses(@todos);
    return unless @todos && $completed == scalar(@todos);
    return "All " . scalar(@todos) . " tasks completed.\n";
}

sub handle_write {
    my ($self, $params, $session_id) = @_;
    
    unless ($params->{todoList}) {
        return $self->error_result("Missing required parameter: todoList (for the write operation, an array of todos to create)");
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

    my $output = "Todo list updated: $total items\n\n";

    if ($existing_completed > 0) {
        $output .= "PREVIOUS STATE: $existing_completed completed\n\n";
    }

    $output .= "NEW STATE:\n";
    $output .= $self->_render_status_counts(@$todo_list);
    $output .= "\n";

    my @in_progress = grep { ($_->{status} // '') eq 'in-progress' } @$todo_list;
    my @not_started = grep { ($_->{status} // '') eq 'not-started' } @$todo_list;
    if (@in_progress) {
        $output .= "Now working on: " . join(", ", map { $_->{title} } @in_progress) . "\n";
    }
    elsif (@not_started) {
        $output .= "Todo list ready. " . scalar(@not_started) . " item(s) not started.\n";
    }

    if (my $msg = $self->_all_completed_message(@$todo_list)) {
        $output .= "\n$msg";
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
        return $self->error_result("Missing required parameter: todoUpdates (for the update operation, an array of {id, ...fields} objects to change - NOT todoList)");
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
            $output .= "   $update\n";
        }
        $output .= "\n";
    }
    
    if (@{$result->{failed}}) {
        $output .= "FAILED UPDATES:\n";
        foreach my $failure (@{$result->{failed}}) {
            $output .= "   $failure\n";
        }
        $output .= "\n";
    }
    
    # Show current state
    my $todos = $store->read();

    $output .= "CURRENT STATE:\n";
    $output .= $self->_render_status_counts(@$todos);
    my @with_summary = grep { defined $_->{taskSummary} && length $_->{taskSummary} > 0 } @$todos;
    if (@with_summary) {
        $output .= "   With task summary: " . scalar(@with_summary) . "\n";
    }

    if (my $msg = $self->_all_completed_message(@$todos)) {
        $output .= "\n$msg";
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

sub handle_add {
    my ($self, $params, $session_id) = @_;
    
    unless ($params->{newTodos}) {
        return $self->error_result("Missing required parameter: newTodos (for the add operation, an array of todos to append - NOT todoList)");
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
