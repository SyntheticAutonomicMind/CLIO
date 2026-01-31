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
- /prompt - Show overview and help
- /prompt show - Display current system prompt (rendered)
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
sub display_command_header { shift->{chat}->display_command_header(@_) }
sub display_section_header { shift->{chat}->display_section_header(@_) }
sub display_key_value { shift->{chat}->display_key_value(@_) }
sub display_list_item { shift->{chat}->display_list_item(@_) }
sub colorize { shift->{chat}->colorize(@_) }
sub writeline { shift->{chat}->writeline(@_) }
sub refresh_terminal_size { shift->{chat}->refresh_terminal_size() }
sub render_markdown { shift->{chat}->render_markdown(@_) }

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
    my $action = shift @args;
    
    # Default action (no args) shows overview with help
    if (!defined $action || $action eq '' || $action eq 'help') {
        $self->_show_overview($pm);
    }
    elsif ($action eq 'show') {
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

=head2 _show_overview($pm)

Display prompt overview with current status and available commands.

=cut

sub _show_overview {
    my ($self, $pm) = @_;
    
    my $prompts = $pm->list_prompts();
    my $active = $pm->{metadata}->{active_prompt} || 'default';
    my $custom_count = scalar(@{$prompts->{custom}});
    my $builtin_count = scalar(@{$prompts->{builtin}});
    
    $self->display_command_header("SYSTEM PROMPT MANAGER");
    
    # Current status
    $self->display_section_header("CURRENT STATUS");
    $self->display_key_value("Active Prompt", $active, 20);
    $self->display_key_value("Available", "$builtin_count built-in, $custom_count custom", 20);
    $self->writeline("", markdown => 0);
    
    # Quick actions
    $self->display_section_header("COMMANDS");
    $self->display_key_value("/prompt show", "Display current system prompt", 25);
    $self->display_key_value("/prompt list", "List all available prompts", 25);
    $self->display_key_value("/prompt set <name>", "Switch to named prompt", 25);
    $self->display_key_value("/prompt edit <name>", "Edit prompt in \$EDITOR", 25);
    $self->display_key_value("/prompt save <name>", "Save current as new", 25);
    $self->display_key_value("/prompt delete <name>", "Delete custom prompt", 25);
    $self->display_key_value("/prompt reset", "Reset to default", 25);
    $self->writeline("", markdown => 0);
    
    # Tips
    $self->display_section_header("TIPS");
    $self->writeline("  " . $self->colorize("*", 'PROMPT') . " System prompts define AI behavior and personality", markdown => 0);
    $self->writeline("  " . $self->colorize("*", 'PROMPT') . " Custom instructions in " . $self->colorize(".clio/instructions.md", 'DATA') . " are auto-appended", markdown => 0);
    $self->writeline("  " . $self->colorize("*", 'PROMPT') . " Use " . $self->colorize("/prompt show", 'USER') . " to see the full active prompt", markdown => 0);
    $self->writeline("", markdown => 0);
}

=head2 _show_help()

Display help for prompt commands.

=cut

sub _show_help {
    my ($self) = @_;
    
    $self->display_command_header("PROMPT HELP");
    
    $self->display_section_header("COMMANDS");
    $self->display_key_value("/prompt", "Show overview and help", 25);
    $self->display_key_value("/prompt show", "Display current system prompt", 25);
    $self->display_key_value("/prompt list", "List available prompts", 25);
    $self->display_key_value("/prompt set <name>", "Switch to named prompt", 25);
    $self->display_key_value("/prompt edit <name>", "Edit prompt in \$EDITOR", 25);
    $self->display_key_value("/prompt save <name>", "Save current as new", 25);
    $self->display_key_value("/prompt delete <name>", "Delete custom prompt", 25);
    $self->display_key_value("/prompt reset", "Reset to default", 25);
    $self->writeline("", markdown => 0);
}

=head2 _show_prompt($pm)

Display the current system prompt with markdown rendering and pagination.

=cut

sub _show_prompt {
    my ($self, $pm) = @_;
    
    my $prompt = $pm->get_system_prompt();
    my $active = $pm->{metadata}->{active_prompt} || 'default';
    my $lines = () = $prompt =~ /\n/g;
    $lines++; # Count last line without newline
    
    $self->refresh_terminal_size();
    
    # Enable pagination for this command output
    $self->{chat}{pagination_enabled} = 1;
    $self->{chat}{line_count} = 0;
    $self->{chat}{pages} = [];
    $self->{chat}{current_page} = [];
    $self->{chat}{page_index} = 0;
    
    $self->display_command_header("ACTIVE SYSTEM PROMPT: " . uc($active));
    
    $self->display_section_header("METADATA");
    $self->display_key_value("Name", $active);
    $self->display_key_value("Lines", $lines);
    $self->display_key_value("Size", length($prompt) . " bytes");
    $self->writeline("", markdown => 0);  # Track blank line for pagination
    
    $self->display_section_header("CONTENT");
    $self->writeline("", markdown => 0);
    
    # Split into lines and use writeline for pagination with auto-markdown
    my @content_lines = split /\n/, $prompt;
    for my $line (@content_lines) {
        my $continue = $self->writeline($line);  # markdown => 1 by default
        last unless $continue;  # User pressed 'q' to quit
    }
    
    # Disable pagination after command completes
    $self->{chat}{pagination_enabled} = 0;
    $self->{chat}{line_count} = 0;
}

=head2 _list_prompts($pm)

List all available prompts with modern formatting.

=cut

sub _list_prompts {
    my ($self, $pm) = @_;
    
    my $prompts = $pm->list_prompts();
    my $active = $pm->{metadata}->{active_prompt} || 'default';
    
    $self->display_command_header("SYSTEM PROMPTS");
    
    # Built-in prompts
    $self->display_section_header("BUILT-IN");
    for my $name (@{$prompts->{builtin}}) {
        my $marker = ($name eq $active) ? " " . $self->colorize("(ACTIVE)", 'SUCCESS') : "";
        $self->display_key_value($name, "Built-in prompt$marker", 20);
    }
    $self->writeline("", markdown => 0);
    
    # Custom prompts
    $self->display_section_header("CUSTOM");
    if (@{$prompts->{custom}}) {
        for my $name (@{$prompts->{custom}}) {
            my $marker = ($name eq $active) ? " " . $self->colorize("(ACTIVE)", 'SUCCESS') : "";
            $self->display_key_value($name, "Custom prompt$marker", 20);
        }
    } else {
        $self->writeline("  " . $self->colorize("(none)", 'DIM'), markdown => 0);
        $self->writeline("  Use " . $self->colorize("/prompt edit <name>", 'USER') . " to create a custom prompt.", markdown => 0);
    }
    $self->writeline("", markdown => 0);
    
    # Summary
    my $custom_count = scalar(@{$prompts->{custom}});
    my $builtin_count = scalar(@{$prompts->{builtin}});
    my $total = $custom_count + $builtin_count;
    
    my $summary = $self->colorize("Total: ", 'LABEL');
    $summary .= $self->colorize("$builtin_count", 'DATA') . " built-in, ";
    $summary .= $self->colorize("$custom_count", 'DATA') . " custom";
    $summary .= " (" . $self->colorize("$total", 'SUCCESS') . " total)";
    $self->writeline($summary, markdown => 0);
    $self->writeline("", markdown => 0);
}

=head2 _set_prompt($pm, @args)

Switch to a named prompt.

=cut

sub _set_prompt {
    my ($self, $pm, @args) = @_;
    
    my $name = shift @args;
    unless ($name) {
        $self->display_error_message("Usage: /prompt set <name>");
        $self->display_system_message("Use " . $self->colorize("/prompt list", 'USER') . " to see available prompts.");
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
            $self->display_system_message("Use " . $self->colorize("/prompt set $name", 'USER') . " to activate.");
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
        $self->display_system_message("Use " . $self->colorize("/prompt set $name", 'USER') . " to activate later.");
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

1;

__END__

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

Same as CLIO.

=cut