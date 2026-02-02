package CLIO::Tools::TodoList;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
use CLIO::Core::Logger qw(should_log);
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
Manage a structured todo list to track progress and plan tasks throughout your work session.

**THIS IS A MANDATORY TOOL** - You MUST use it for multi-step tasks, not just "can use" or "should use".

═══════════════════════════════════════════════════════════════

MANDATORY USAGE - When You MUST Use This Tool:
✓ User provides multiple tasks (numbered, comma-separated, or listed)
✓ Complex work requiring investigation then implementation
✓ Tasks spanning multiple tool calls or file operations
✓ User says "do X, then Y, then Z"
✓ Breaking down larger requests into logical steps

Skip ONLY for:
✗ Single, trivial tasks (one tool call)
✗ Purely conversational questions
✗ Simple explanations

═══════════════════════════════════════════════════════════════

CORRECT WORKFLOW (Follow Exactly):

STEP 1 - CREATE THE LIST (Do This FIRST, Before Any Work):
→ Call: write operation with todoList array
→ Set first task as "in-progress" 
→ Set remaining tasks as "not-started"
→ Example: todoList: [{id:1, title:"Read code", status:"in-progress"}, {id:2, title:"Fix bug", status:"not-started"}]

STEP 2 - DO THE WORK:
→ Use appropriate tools (file_operations, terminal_operations, etc.)
→ Complete the current in-progress task

STEP 3 - MARK COMPLETE (Immediately After Finishing):
→ Call: update operation with status="completed" for finished todo
→ Example: todoUpdates: [{id:1, status:"completed"}]

STEP 4 - START NEXT TODO:
→ Call: update operation with status="in-progress" for next todo
→ Example: todoUpdates: [{id:2, status:"in-progress"}]

STEP 5 - REPEAT:
→ Go back to STEP 2 until all todos completed

═══════════════════════════════════════════════════════════════

ANTI-PATTERNS (What NOT To Do):

✗ NEVER say "I'll create a todo list..." without calling this tool
✗ NEVER describe todos in text without creating them in the system
✗ NEVER try to update todos that don't exist yet (create first!)
✗ NEVER batch completions - mark each complete immediately after finishing
✗ NEVER have multiple todos "in-progress" (max 1 at a time)
✗ NEVER forget to call update - the system cannot infer status from your text

═══════════════════════════════════════════════════════════════

EXAMPLE - User says: "Create test.txt, read it back, create result.txt"

CORRECT APPROACH:
1. [Call todo_operations write with 3 todos, first as "in-progress"]
2. [Call file_operations to create test.txt]
3. [Call todo_operations update to mark todo #1 "completed"]
4. [Call todo_operations update to mark todo #2 "in-progress"]
5. [Call file_operations to read test.txt]
6. [Call todo_operations update to mark todo #2 "completed"]
7. [Call todo_operations update to mark todo #3 "in-progress"]
8. [Call file_operations to create result.txt]
9. [Call todo_operations update to mark todo #3 "completed"]

WRONG APPROACH:
"I'll create a todo list for this work:
1. Create test.txt
2. Read it back
3. Create result.txt

Let's get started..." 
[Then does nothing - NO TOOL CALLS!]

═══════════════════════════════════════════════════════════════

STATUS VALUES:
-  not-started: Todo not yet begun
-  in-progress: Currently working (MAX 1 at a time)
-  completed: Fully finished with no blockers
-  blocked: Cannot proceed (awaiting user input or external dependency)

OPERATIONS:
-  read: Get current todo list for this session
-  write: Create/replace entire list (requires todoList array)
-  update: Change status of existing todos (requires todoUpdates array)
-  add: Append new todos to existing list (requires newTodos array)

REMEMBER: This tool makes your work visible to the user. They can see your progress. Use it!
EOF
        supported_operations => [qw(read write update add)],
        debug => $opts{debug} || 0,
    );
}

sub route_operation {
    my ($self, $operation, $params, $context) = @_;
    
    my $start_time = time();
    
    # Get session_id from context
    my $session_id = $context->{session}{session_id} || $context->{session_id} || 'default';
    
    print STDERR "[DEBUG][TodoList] Operation: $operation for session: $session_id\n" if should_log('DEBUG');
    
    my $result;
    if ($operation eq 'read') {
        $result = $self->handle_read($session_id);
    }
    elsif ($operation eq 'write') {
        $result = $self->handle_write($params, $session_id);
    }
    elsif ($operation eq 'update') {
        $result = $self->handle_update($params, $session_id);
    }
    elsif ($operation eq 'add') {
        $result = $self->handle_add($params, $session_id);
    }
    else {
        $result = $self->operation_error("Unknown operation: $operation");
    }
    
    my $execution_time = time() - $start_time;
    print STDERR "[DEBUG][TodoList] Operation $operation completed in ${execution_time}s\n" if should_log('DEBUG');
    
    return $result;
}

sub get_additional_parameters {
    my ($self) = @_;
    
    return {
        todoList => {
            type => "array",
            description => "Complete array of all todos (required for write operation)",
            items => {
                type => "object",
                properties => {
                    id => {
                        type => "integer",
                        description => "Unique ID (sequential numbers from 1)",
                    },
                    title => {
                        type => "string",
                        description => "Todo label (3-7 words)",
                    },
                    description => {
                        type => "string",
                        description => "Context, requirements, file paths, etc.",
                    },
                    status => {
                        type => "string",
                        enum => ["not-started", "in-progress", "completed", "blocked"],
                        description => "not-started | in-progress (max 1) | completed | blocked",
                    },
                    priority => {
                        type => "string",
                        enum => ["low", "medium", "high", "critical"],
                        description => "Priority level (optional)",
                    },
                    dependencies => {
                        type => "array",
                        items => { type => "integer" },
                        description => "Array of todo IDs this task depends on (optional)",
                    },
                    progress => {
                        type => "number",
                        description => "Progress 0.0-1.0 as decimal (optional)",
                    },
                    blockedReason => {
                        type => "string",
                        description => "Reason why task is blocked (required if status=blocked)",
                    },
                },
                required => ["id", "title", "description", "status"],
            },
        },
        newTodos => {
            type => "array",
            description => "New todos to add (required for add operation). IDs will be auto-assigned.",
            items => {
                type => "object",
                properties => {
                    title => {
                        type => "string",
                        description => "Todo label (3-7 words)",
                    },
                    description => {
                        type => "string",
                        description => "Context, requirements, file paths, etc.",
                    },
                    status => {
                        type => "string",
                        enum => ["not-started", "in-progress", "completed", "blocked"],
                        description => "Status (default: not-started)",
                    },
                    priority => {
                        type => "string",
                        enum => ["low", "medium", "high", "critical"],
                        description => "Priority level (optional)",
                    },
                },
                required => ["title", "description"],
            },
        },
        todoUpdates => {
            type => "array",
            description => "Partial todo updates (required for update operation). Array of updates where each has 'id' (required) + fields to change.",
            items => {
                type => "object",
                properties => {
                    id => {
                        type => "integer",
                        description => "ID of todo to update (required)",
                    },
                    status => {
                        type => "string",
                        enum => ["not-started", "in-progress", "completed", "blocked"],
                        description => "New status",
                    },
                    title => {
                        type => "string",
                        description => "New title",
                    },
                    description => {
                        type => "string",
                        description => "New description",
                    },
                    progress => {
                        type => "number",
                        description => "New progress 0.0-1.0",
                    },
                    priority => {
                        type => "string",
                        enum => ["low", "medium", "high", "critical"],
                        description => "New priority",
                    },
                    blockedReason => {
                        type => "string",
                        description => "Reason for blocked status",
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
