package CLIO::UI::Commands::Prompt;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Carp qw(croak);
use CLIO::Core::Logger qw(should_log);

=head1 NAME

CLIO::UI::Commands::Prompt - System prompt management commands for CLIO

=head1 SYNOPSIS

  use CLIO::UI::Commands::Prompt;
  
  my $prompt_cmd = CLIO::UI::Commands::Prompt->new(
      chat => $chat_instance,
      debug => 0
  );
  
  # Handle /prompt commands
  $prompt_cmd->handle_prompt_command('show');
  $prompt_cmd->handle_prompt_command('list');

=head1 DESCRIPTION

Handles system prompt management commands including:
- /prompt show - Display current system prompt
- /prompt list - List available prompts
- /prompt set <name> - Switch to named prompt
- /prompt edit <name> - Edit prompt in $EDITOR
- /prompt save <name> - Save current prompt as new
- /prompt delete <name> - Delete custom prompt
- /prompt reset - Reset to default

Extracted from Chat.pm to improve maintainability.

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        chat => $args{chat} || croak "chat instance required",
        debug => $args{debug} // 0,
    };
    
    bless $self, $class;
    return $self;
}

# Delegate display methods to chat
sub display_system_message { shift->{chat}->display_system_message(@_) }
sub display_error_message { shift->{chat}->display_error_message(@_) }
sub colorize { shift->{chat}->colorize(@_) }
sub writeline { shift->{chat}->writeline(@_) }
sub refresh_terminal_size { shift->{chat}->refresh_terminal_size() }

=head2 _get_prompt_manager()

Get or create the PromptManager instance.

=cut

sub _get_prompt_manager {
    my ($self) = @_;
    
    require CLIO::Core::PromptManager;
    return CLIO::Core::PromptManager->new(debug => $self->{debug});
}

=head2 handle_prompt_command(@args)

Main handler for /prompt commands.

=cut

sub handle_prompt_command {
    my ($self, @args) = @_;
    
    my $pm = $self->_get_prompt_manager();
    my $action = shift @args || 'show';
    
    if ($action eq 'show') {
        $self->_show_prompt($pm);
    }
    elsif ($action eq 'list' || $action eq 'ls') {
        $self->_list_prompts($pm);
    }
    elsif ($action eq 'set') {
        $self->_set_prompt($pm, @args);
    }
    elsif ($action eq 'reset') {
        $self->_reset_prompt($pm);
    }
    elsif ($action eq 'edit') {
        $self->_edit_prompt($pm, @args);
    }
    elsif ($action eq 'save') {
        $self->_save_prompt($pm, @args);
    }
    elsif ($action eq 'delete' || $action eq 'rm') {
        $self->_delete_prompt($pm, @args);
    }
    else {
        $self->display_error_message("Unknown action: $action");
        $self->_show_help();
    }
    
    return;
}

=head2 _show_prompt($pm)

Display the current system prompt with pagination.

=cut

sub _show_prompt {
    my ($self, $pm) = @_;
    
    my $prompt = $pm->get_system_prompt();
    
    $self->refresh_terminal_size();
    
    # Reset pagination state on chat
    $self->{chat}{line_count} = 0;
    $self->{chat}{pages} = [];
    $self->{chat}{current_page} = [];
    $self->{chat}{page_index} = 0;
    
    my @header = (
        "",
        "-" x 55,
        "ACTIVE SYSTEM PROMPT",
        "-" x 55,
        ""
    );
    
    my @lines = split /\n/, $prompt;
    my $total_lines = scalar @lines;
    
    for my $line (@header) {
        last unless $self->writeline($line);
    }
    
    for my $line (@lines) {
        last unless $self->writeline($line);
    }
    
    my @footer = (
        "",
        "-" x 55,
        "Total: $total_lines lines",
        "Type: " . ($pm->{metadata}->{active_prompt} || 'default'),
        ""
    );
    
    for my $line (@footer) {
        last unless $self->writeline($line);
    }
    
    $self->{chat}{line_count} = 0;
}

=head2 _list_prompts($pm)

List all available prompts.

=cut

sub _list_prompts {
    my ($self, $pm) = @_;
    
    my $prompts = $pm->list_prompts();
    my $active = $pm->{metadata}->{active_prompt} || 'default';
    
    print "\n";
    print "SYSTEM PROMPTS\n";
    print "-" x 55, "\n";
    print "\n";
    print "BUILTIN (read-only):\n";
    for my $name (@{$prompts->{builtin}}) {
        my $marker = ($name eq $active) ? " (ACTIVE)" : "";
        printf "  %-20s%s\n", $name, $self->colorize($marker, 'PROMPT');
    }
    
    if (@{$prompts->{custom}}) {
        print "\nCUSTOM:\n";
        for my $name (@{$prompts->{custom}}) {
            my $marker = ($name eq $active) ? " (ACTIVE)" : "";
            printf "  %-20s%s\n", $name, $self->colorize($marker, 'PROMPT');
        }
    } else {
        print "\nNo custom prompts yet.\n";
        print "Use " . $self->colorize('/prompt edit <name>', 'PROMPT') . " to create one.\n";
    }
    
    print "\n";
    printf "Total: %d builtin, %d custom\n", 
        scalar @{$prompts->{builtin}}, 
        scalar @{$prompts->{custom}};
    print "\n";
}

=head2 _set_prompt($pm, @args)

Switch to a named prompt.

=cut

sub _set_prompt {
    my ($self, $pm, @args) = @_;
    
    my $name = shift @args;
    unless ($name) {
        $self->display_error_message("Usage: /prompt set <name>");
        return;
    }
    
    my $result = $pm->set_active_prompt($name);
    if ($result->{success}) {
        $self->display_system_message("Switched to system prompt '$name'");
        $self->display_system_message("This will apply to future messages in this session.");
    } else {
        $self->display_error_message($result->{error});
    }
}

=head2 _reset_prompt($pm)

Reset to default prompt.

=cut

sub _reset_prompt {
    my ($self, $pm) = @_;
    
    my $result = $pm->reset_to_default();
    if ($result->{success}) {
        $self->display_system_message("Reset to default system prompt");
    } else {
        $self->display_error_message($result->{error});
    }
}

=head2 _edit_prompt($pm, @args)

Edit a prompt in $EDITOR.

=cut

sub _edit_prompt {
    my ($self, $pm, @args) = @_;
    
    my $name = shift @args;
    unless ($name) {
        $self->display_error_message("Usage: /prompt edit <name>");
        return;
    }
    
    $self->display_system_message("Opening '$name' in \$EDITOR...");
    my $result = $pm->edit_prompt($name);
    
    if ($result->{success}) {
        if ($result->{modified}) {
            $self->display_system_message("System prompt '$name' saved.");
            $self->display_system_message("Use " . $self->colorize("/prompt set $name", 'PROMPT') . " to activate.");
        } else {
            $self->display_system_message("No changes made to '$name'.");
        }
    } else {
        $self->display_error_message($result->{error});
    }
}

=head2 _save_prompt($pm, @args)

Save current prompt as a new named prompt.

=cut

sub _save_prompt {
    my ($self, $pm, @args) = @_;
    
    my $name = shift @args;
    unless ($name) {
        $self->display_error_message("Usage: /prompt save <name>");
        return;
    }
    
    my $current = $pm->get_system_prompt();
    
    my $result = $pm->save_prompt($name, $current);
    if ($result->{success}) {
        $self->display_system_message("Saved current system prompt as '$name'");
        $self->display_system_message("Use " . $self->colorize("/prompt set $name", 'PROMPT') . " to activate later.");
    } else {
        $self->display_error_message($result->{error});
    }
}

=head2 _delete_prompt($pm, @args)

Delete a custom prompt.

=cut

sub _delete_prompt {
    my ($self, $pm, @args) = @_;
    
    my $name = shift @args;
    unless ($name) {
        $self->display_error_message("Usage: /prompt delete <name>");
        return;
    }
    
    print "Are you sure you want to delete prompt '$name'? (yes/no): ";
    my $confirm = <STDIN>;
    chomp($confirm);
    
    unless ($confirm =~ /^y(es)?$/i) {
        $self->display_system_message("Deletion cancelled.");
        return;
    }
    
    my $result = $pm->delete_prompt($name);
    if ($result->{success}) {
        $self->display_system_message("Deleted prompt '$name'.");
    } else {
        $self->display_error_message($result->{error});
    }
}

=head2 _show_help()

Display help for prompt commands.

=cut

sub _show_help {
    my ($self) = @_;
    
    print "\n";
    print "Usage:\n";
    print "  /prompt show              - Display current system prompt\n";
    print "  /prompt list              - List available prompts\n";
    print "  /prompt set <name>        - Switch to named prompt\n";
    print "  /prompt edit <name>       - Edit prompt in \$EDITOR\n";
    print "  /prompt save <name>       - Save current as new\n";
    print "  /prompt delete <name>     - Delete custom prompt\n";
    print "  /prompt reset             - Reset to default\n";
}

1;

__END__

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

Same as CLIO.

=cut
