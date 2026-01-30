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
        session => $args{session},
        debug => $args{debug} // 0,
    };
    
    bless $self, $class;
    return $self;
}

# Delegate display methods to chat
sub display_system_message { shift->{chat}->display_system_message(@_) }
sub display_error_message { shift->{chat}->display_error_message(@_) }

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
    else {
        $self->display_error_message("Unknown action: $action");
        print "\n";
        print "Usage:\n";
        print "  /skills add <name> \"<text>\"  - Add custom skill\n";
        print "  /skills list                  - List all skills\n";
        print "  /skills use <name> [file]     - Execute skill\n";
        print "  /skills show <name>           - Display skill\n";
        print "  /skills delete <name>         - Delete skill\n";
    }
    
    return;
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

List all available skills.

=cut

sub _list_skills {
    my ($self, $sm) = @_;
    
    my $skills = $sm->list_skills();
    
    print "\n";
    print "-" x 55, "\n";
    print "CUSTOM SKILLS\n";
    print "-" x 55, "\n";
    
    if (@{$skills->{custom}}) {
        for my $name (sort @{$skills->{custom}}) {
            my $s = $sm->get_skill($name);
            printf "  %-20s %s\n", $name, $s->{description};
        }
    } else {
        print "  (none)\n";
    }
    
    print "\n";
    print "BUILT-IN SKILLS (read-only)\n";
    print "-" x 55, "\n";
    
    for my $name (sort @{$skills->{builtin}}) {
        my $s = $sm->get_skill($name);
        printf "  %-20s %s\n", $name, $s->{description};
    }
    
    print "\n";
    printf "Total: %d custom, %d built-in\n", 
        scalar(@{$skills->{custom}}),
        scalar(@{$skills->{builtin}});
    print "\n";
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

Display skill details.

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
    
    print "\n";
    print "-" x 55, "\n";
    print "SKILL: $name\n";
    print "-" x 55, "\n";
    print "\n";
    print $skill->{prompt}, "\n";
    print "\n";
    print "-" x 55, "\n";
    print "Variables: ", join(", ", @{$skill->{variables}}), "\n";
    print "Type: $skill->{type}\n";
    if ($skill->{created}) {
        print "Created: ", scalar(localtime($skill->{created})), "\n";
    }
    if ($skill->{modified}) {
        print "Modified: ", scalar(localtime($skill->{modified})), "\n";
    }
    print "\n";
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
