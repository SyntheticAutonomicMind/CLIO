package CLIO::UI::Commands::Todo;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Carp qw(croak);

=head1 NAME

CLIO::UI::Commands::Todo - Todo management commands for CLIO

=head1 SYNOPSIS

  use CLIO::UI::Commands::Todo;
  
  my $todo_cmd = CLIO::UI::Commands::Todo->new(
      chat => $chat_instance,
      session => $session,
      ai_agent => $ai_agent,
      debug => 0
  );
  
  # Handle /todo commands
  $todo_cmd->handle_todo_command('view');
  $todo_cmd->handle_todo_command('add', 'Task title | Task description');
  $todo_cmd->handle_todo_command('done', '1');

=head1 DESCRIPTION

Handles all todo-related commands including:
- /todo [view|list] - View current todo list
- /todo add <title> | <description> - Add a new todo
- /todo done <id> - Mark a todo as completed
- /todo clear - Clear all completed todos

Extracted from Chat.pm to improve maintainability.

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        chat => $args{chat} || croak "chat instance required",
        debug => $args{debug} // 0,
    };
    
    # Assign object references separately
    $self->{session} = $args{session};
    $self->{ai_agent} = $args{ai_agent};
    
    bless $self, $class;
    return $self;
}

# Delegate display methods to chat
sub display_system_message { shift->{chat}->display_system_message(@_) }
sub display_error_message { shift->{chat}->display_error_message(@_) }
sub writeline { shift->{chat}->writeline(@_) }

=head2 handle_todo_command(@args)

Main handler for /todo commands.

=cut

sub handle_todo_command {
    my ($self, @args) = @_;
    
    unless ($self->{ai_agent}) {
        $self->display_error_message("AI agent not available");
        return;
    }
    
    # Get orchestrator and tool registry
    my $orchestrator = $self->{ai_agent}{orchestrator};
    unless ($orchestrator && $orchestrator->{tool_registry}) {
        $self->display_error_message("Tool system not available");
        return;
    }
    
    my $todo_tool = $orchestrator->{tool_registry}->get_tool('todo_operations');
    unless ($todo_tool) {
        $self->display_error_message("Todo tool not registered");
        return;
    }
    
    # Parse subcommand
    my $subcmd = @args ? lc($args[0]) : 'view';
    
    if ($subcmd eq 'view' || $subcmd eq 'list' || $subcmd eq '' || $subcmd eq 'help') {
        $self->_view_todos($todo_tool);
    }
    elsif ($subcmd eq 'add' && @args >= 2) {
        $self->_add_todo($todo_tool, @args[1..$#args]);
    }
    elsif ($subcmd eq 'done' && @args >= 2) {
        $self->_complete_todo($todo_tool, $args[1]);
    }
    elsif ($subcmd eq 'clear') {
        $self->_clear_completed($todo_tool);
    }
    else {
        $self->display_error_message("Unknown todo command: $subcmd");
        $self->display_system_message("Usage: /todo [view|add|done|clear]");
    }
}

=head2 _view_todos($todo_tool)

View current todo list.

=cut

sub _view_todos {
    my ($self, $todo_tool) = @_;
    
    my $result = $todo_tool->execute(
        { operation => 'read' },
        { session => $self->{session}, ui => $self->{chat} }
    );
    
    if ($result->{success}) {
        for my $line (split /\n/, $result->{output}) {
            $self->writeline($line, markdown => 0);
        }
    } else {
        $self->display_error_message($result->{error});
    }
}

=head2 _add_todo($todo_tool, @args)

Add a new todo item.

=cut

sub _add_todo {
    my ($self, $todo_tool, @args) = @_;
    
    my $todo_text = join(' ', @args);
    my ($title, $description) = split /\s*\|\s*/, $todo_text, 2;
    
    unless ($title && $description) {
        $self->display_error_message("Usage: /todo add <title> | <description>");
        return;
    }
    
    my @new_todo = ({
        title => $title,
        description => $description,
        status => 'not-started',
    });
    
    my $result = $todo_tool->execute(
        { operation => 'add', newTodos => \@new_todo },
        { session => $self->{session}, ui => $self->{chat} }
    );
    
    if ($result->{success}) {
        $self->display_system_message("Todo added successfully");
        for my $line (split /\n/, $result->{output}) {
            $self->writeline($line, markdown => 0);
        }
    } else {
        $self->display_error_message($result->{error});
    }
}

=head2 _complete_todo($todo_tool, $todo_id)

Mark a todo as completed.

=cut

sub _complete_todo {
    my ($self, $todo_tool, $todo_id) = @_;
    
    unless ($todo_id =~ /^\d+$/) {
        $self->display_error_message("Invalid todo ID: $todo_id");
        return;
    }
    
    my $result = $todo_tool->execute(
        { operation => 'update', todoUpdates => [{ id => int($todo_id), status => 'completed' }] },
        { session => $self->{session}, ui => $self->{chat} }
    );
    
    if ($result->{success}) {
        $self->display_system_message("Todo #$todo_id marked as completed");
    } else {
        $self->display_error_message($result->{error});
    }
}

=head2 _clear_completed($todo_tool)

Clear all completed todos.

=cut

sub _clear_completed {
    my ($self, $todo_tool) = @_;
    
    my $read_result = $todo_tool->execute(
        { operation => 'read' },
        { session => $self->{session}, ui => $self->{chat} }
    );
    
    if ($read_result->{success} && $read_result->{todos}) {
        my @incomplete = grep { $_->{status} ne 'completed' } @{$read_result->{todos}};
        
        my $result = $todo_tool->execute(
            { operation => 'write', todoList => \@incomplete },
            { session => $self->{session}, ui => $self->{chat} }
        );
        
        if ($result->{success}) {
            $self->display_system_message("Cleared all completed todos");
        } else {
            $self->display_error_message($result->{error});
        }
    }
}

1;

__END__

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

Same as CLIO.

=cut
