package CLIO::UI::Commands::Skills;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Carp qw(croak);
use File::Spec;
use CLIO::Core::Logger qw(should_log);

=head1 NAME

CLIO::UI::Commands::Skills - Custom skill management commands for CLIO

=head1 SYNOPSIS

  use CLIO::UI::Commands::Skills;
  
  my $skills_cmd = CLIO::UI::Commands::Skills->new(
      chat => $chat_instance,
      session => $session,
      debug => 0
  );
  
  # Handle /skills commands
  $skills_cmd->handle_skills_command('list');
  $skills_cmd->handle_skills_command('add', 'myskill', 'prompt text');

=head1 DESCRIPTION

Handles custom skill management commands including:
- /skills list - List all custom and built-in skills
- /skills add <name> "<text>" - Add a custom skill
- /skills use <name> [file] - Execute a skill
- /skills show <name> - Display skill details
- /skills delete <name> - Delete a custom skill

Extracted from Chat.pm to improve maintainability.

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        chat => $args{chat} || croak "chat instance required",
        debug => $args{debug} // 0,
    };
    
    # Assign object references separately (hash literal assignment bug workaround)
    $self->{session} = $args{session};
    
    bless $self, $class;
    return $self;
}

# Delegate display methods to chat
sub display_system_message { shift->{chat}->display_system_message(@_) }
sub display_error_message { shift->{chat}->display_error_message(@_) }
sub writeline { shift->{chat}->writeline(@_) }
sub display_command_header { shift->{chat}->display_command_header(@_) }
sub display_section_header { shift->{chat}->display_section_header(@_) }
sub display_key_value { shift->{chat}->display_key_value(@_) }
sub display_list_item { shift->{chat}->display_list_item(@_) }
sub colorize { shift->{chat}->colorize(@_) }
sub render_markdown { shift->{chat}->render_markdown(@_) }

=head2 _get_skill_manager()

Get or create the SkillManager instance.

=cut

sub _get_skill_manager {
    my ($self) = @_;
    
    require CLIO::Core::SkillManager;
    return CLIO::Core::SkillManager->new(
        debug => $self->{debug},
        session_skills_file => $self->{session} ? 
            File::Spec->catfile('sessions', $self->{session}{session_id}, 'skills.json') : 
            undef
    );
}

=head2 handle_skills_command(@args)

Main handler for /skills commands.

=cut

sub handle_skills_command {
    my ($self, @args) = @_;
    
    my $action = shift @args || 'list';
    my $sm = $self->_get_skill_manager();
    
    if ($action eq 'add') {
        return $self->_add_skill($sm, @args);
    }
    elsif ($action eq 'list' || $action eq 'ls') {
        $self->_list_skills($sm);
    }
    elsif ($action eq 'use' || $action eq 'exec') {
        return $self->_use_skill($sm, @args);
    }
    elsif ($action eq 'show') {
        $self->_show_skill($sm, @args);
    }
    elsif ($action eq 'delete' || $action eq 'rm') {
        $self->_delete_skill($sm, @args);
    }
    elsif ($action eq 'help') {
        $self->_show_help();
    }
    else {
        $self->display_error_message("Unknown action: $action");
        $self->_show_help();
    }
    
    return;
}

=head2 _show_help()

Display skills command help.

=cut

sub _show_help {
    my ($self) = @_;
    
    $self->display_command_header("SKILLS HELP");
    
    $self->display_section_header("COMMANDS");
    $self->display_key_value("/skills", "List all skills", 30);
    $self->display_key_value("/skills list", "List all skills", 30);
    $self->display_key_value("/skills add <name> \"<text>\"", "Add custom skill", 30);
    $self->display_key_value("/skills use <name> [file]", "Execute skill", 30);
    $self->display_key_value("/skills show <name>", "Display skill details", 30);
    $self->display_key_value("/skills delete <name>", "Delete custom skill", 30);
    $self->writeline("", markdown => 0);
}

=head2 _add_skill($sm, @args)

Add a new custom skill.

=cut

sub _add_skill {
    my ($self, $sm, @args) = @_;
    
    my $name = shift @args;
    my $skill_text = join(' ', @args);
    
    unless ($name && $skill_text) {
        $self->display_error_message("Usage: /skills add <name> \"<skill text>\"");
        return;
    }
    
    # Remove quotes if present
    $skill_text =~ s/^["']//;
    $skill_text =~ s/["']$//;
    
    my $result = $sm->add_skill($name, $skill_text);
    
    if ($result->{success}) {
        $self->display_system_message("Added skill '$name'");
    } else {
        $self->display_error_message($result->{error});
    }
}

=head2 _list_skills($sm)

List all available skills with modern formatting.

=cut

sub _list_skills {
    my ($self, $sm) = @_;
    
    my $skills = $sm->list_skills();
    
    $self->display_command_header("SKILLS");
    
    # Custom skills section
    $self->display_section_header("CUSTOM SKILLS");
    
    if (@{$skills->{custom}}) {
        for my $name (sort @{$skills->{custom}}) {
            my $s = $sm->get_skill($name);
            my $desc = $s->{description} || '(no description)';
            $self->display_key_value($name, $desc, 25);
        }
    } else {
        $self->writeline("  " . $self->colorize("(none)", 'DIM'), markdown => 0);
    }
    $self->writeline("", markdown => 0);
    
    # Built-in skills section
    $self->display_section_header("BUILT-IN SKILLS");
    
    for my $name (sort @{$skills->{builtin}}) {
        my $s = $sm->get_skill($name);
        my $desc = $s->{description} || '(no description)';
        $self->display_key_value($name, $desc, 25);
    }
    $self->writeline("", markdown => 0);
    
    # Summary
    my $custom_count = scalar(@{$skills->{custom}});
    my $builtin_count = scalar(@{$skills->{builtin}});
    my $total = $custom_count + $builtin_count;
    
    my $summary = $self->colorize("Total: ", 'LABEL') .
                  $self->colorize("$custom_count", 'DATA') . " custom, " .
                  $self->colorize("$builtin_count", 'DATA') . " built-in" .
                  " (" . $self->colorize("$total", 'SUCCESS') . " total)";
    $self->writeline($summary, markdown => 0);
    $self->writeline("", markdown => 0);
}

=head2 _use_skill($sm, @args)

Execute a skill and return prompt for AI.

=cut

sub _use_skill {
    my ($self, $sm, @args) = @_;
    
    my $name = shift @args;
    my $file = join(' ', @args);
    
    unless ($name) {
        $self->display_error_message("Usage: /skills use <name> [file]");
        return;
    }
    
    # Build context
    my $context = $self->_build_skill_context($file);
    
    # Execute skill
    my $result = $sm->execute_skill($name, $context);
    
    if ($result->{success}) {
        # Return prompt to be sent to AI
        return (1, $result->{rendered_prompt});
    } else {
        $self->display_error_message($result->{error});
    }
}

=head2 _build_skill_context($file)

Build context hash for skill execution.

=cut

sub _build_skill_context {
    my ($self, $file) = @_;
    
    my $context = {};
    
    if ($file && -f $file) {
        open my $fh, '<', $file;
        $context->{code} = do { local $/; <$fh> };
        close $fh;
        $context->{file} = $file;
    }
    
    # Add session context if available
    if ($self->{session} && $self->{session}{state}) {
        my $history = $self->{session}{state}->get_history();
        if ($history && @$history) {
            # Get last few messages as context
            my $recent = @$history > 5 ? [@$history[-5..-1]] : $history;
            $context->{recent_context} = join("\n", map { 
                ($_->{role} || 'user') . ": " . ($_->{content} || '')
            } @$recent);
        }
    }
    
    return $context;
}

=head2 _show_skill($sm, @args)

Display skill details with modern formatting.

=cut

sub _show_skill {
    my ($self, $sm, @args) = @_;
    
    my $name = shift @args;
    
    unless ($name) {
        $self->display_error_message("Usage: /skills show <name>");
        return;
    }
    
    my $skill = $sm->get_skill($name);
    unless ($skill) {
        $self->display_error_message("Skill '$name' not found");
        return;
    }
    
    $self->display_command_header("SKILL: " . uc($name));
    
    # Metadata section
    $self->display_section_header("DETAILS");
    $self->display_key_value("Name", $name);
    $self->display_key_value("Type", $skill->{type} || 'custom');
    $self->display_key_value("Description", $skill->{description} || '(none)');
    
    if ($skill->{variables} && @{$skill->{variables}}) {
        $self->display_key_value("Variables", join(", ", @{$skill->{variables}}));
    }
    
    if ($skill->{created}) {
        $self->display_key_value("Created", scalar(localtime($skill->{created})));
    }
    if ($skill->{modified}) {
        $self->display_key_value("Modified", scalar(localtime($skill->{modified})));
    }
    $self->writeline("", markdown => 0);
    
    # Prompt section
    $self->display_section_header("PROMPT TEMPLATE");
    $self->writeline("", markdown => 0);
    
    # Render through markdown pipeline for proper formatting
    my $rendered = $self->render_markdown($skill->{prompt});
    if (defined $rendered) {
        for my $line (split /\n/, $rendered) {
            $self->writeline($line, markdown => 0);  # Already rendered
        }
    }
    
    $self->writeline("", markdown => 0);
}

=head2 _delete_skill($sm, @args)

Delete a custom skill.

=cut

sub _delete_skill {
    my ($self, $sm, @args) = @_;
    
    my $name = shift @args;
    
    unless ($name) {
        $self->display_error_message("Usage: /skills delete <name>");
        return;
    }
    
    print "Are you sure you want to delete skill '$name'? (yes/no): ";
    my $confirm = <STDIN>;
    chomp $confirm;
    
    unless ($confirm eq 'yes') {
        $self->display_system_message("Deletion cancelled");
        return;
    }
    
    my $result = $sm->delete_skill($name);
    
    if ($result->{success}) {
        $self->display_system_message("Deleted skill '$name'");
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