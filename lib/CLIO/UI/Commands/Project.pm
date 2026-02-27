package CLIO::UI::Commands::Project;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Carp qw(croak);
use Cwd;

=head1 NAME

CLIO::UI::Commands::Project - Project initialization and design commands for CLIO

=head1 SYNOPSIS

  use CLIO::UI::Commands::Project;
  
  my $project_cmd = CLIO::UI::Commands::Project->new(
      chat => $chat_instance,
      debug => 0
  );
  
  # Handle /init command - returns prompt for AI execution
  my $prompt = $project_cmd->handle_init_command();
  
  # Handle /design command - returns prompt for AI execution
  my $prompt = $project_cmd->handle_design_command();

=head1 DESCRIPTION

Handles project-level commands that initiate AI-driven workflows:
- /init [--force] - Initialize CLIO for a project (AI analyzes codebase)
- /design [type] - Create or review Product Requirements Document (PRD)

These commands use the Skills system (SkillManager) for prompt templates,
making the prompts customizable and discoverable via /skills list.

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
sub writeline { shift->{chat}->writeline(@_) }

=head2 _get_skill_manager

Get or create the SkillManager instance.

=cut

sub _get_skill_manager {
    my ($self) = @_;
    
    require CLIO::Core::SkillManager;
    require File::Spec;
    
    my $session_file;
    if ($self->{chat}->{session} && $self->{chat}->{session}{session_id}) {
        $session_file = File::Spec->catfile(
            'sessions', 
            $self->{chat}->{session}{session_id}, 
            'skills.json'
        );
    }
    
    return CLIO::Core::SkillManager->new(
        debug => $self->{debug},
        session_skills_file => $session_file
    );
}

=head2 handle_init_command(@args)

Initialize CLIO for a project. Returns a prompt for AI to execute.

Uses the 'init' or 'init-with-prd' built-in skill from SkillManager.

=cut

sub handle_init_command {
    my ($self, @args) = @_;
    
    # Check if already initialized
    my $cwd = Cwd::getcwd() || $ENV{PWD} || '.';
    my $clio_dir = "$cwd/.clio";
    my $instructions_file = "$clio_dir/instructions.md";
    
    # Check for --force flag
    my $force = grep { $_ eq '--force' || $_ eq '-f' } @args;
    
    if (-f $instructions_file && !$force) {
        $self->display_system_message("Project already initialized!");
        $self->display_system_message("Found existing instructions at: .clio/instructions.md");
        $self->writeline("", markdown => 0);
        $self->display_system_message("To re-initialize, use:");
        $self->display_system_message("  /init --force");
        $self->writeline("", markdown => 0);
        return;
    }
    
    # If force flag and instructions exist, back them up
    if ($force && -f $instructions_file) {
        my $timestamp = time();
        my $backup_file = "$instructions_file.backup.$timestamp";
        rename($instructions_file, $backup_file);
        $self->display_system_message("Backed up existing instructions to:");
        $self->display_system_message("  .clio/instructions.md.backup.$timestamp");
        $self->writeline("", markdown => 0);
    }
    
    # Check for PRD
    my $prd_path = "$clio_dir/PRD.md";
    my $has_prd = -f $prd_path;
    
    # Ensure .gitignore is set up correctly for .clio/
    eval {
        require CLIO::Util::GitIgnore;
        if (CLIO::Util::GitIgnore::ensure_clio_ignored($cwd)) {
            $self->display_system_message("Updated .gitignore for .clio/ directory.");
        }
    };
    
    $self->display_system_message("Starting project initialization...");
    if ($has_prd) {
        $self->display_system_message("Found PRD - will incorporate into instructions.");
    }
    $self->display_system_message("CLIO will analyze your codebase and create custom instructions.");
    $self->writeline("", markdown => 0);
    
    # Use SkillManager to get the appropriate skill
    my $skill_mgr = $self->_get_skill_manager();
    my $skill_name = $has_prd ? 'init-with-prd' : 'init';
    
    my $result = $skill_mgr->execute_skill($skill_name, {});
    
    if ($result->{success}) {
        return $result->{rendered_prompt};
    } else {
        $self->display_error_message("Failed to load init skill: " . ($result->{error} || 'unknown error'));
        return;
    }
}

=head2 handle_design_command(@args)

Create or review Product Requirements Document (PRD). Returns a prompt for AI to execute.

Uses the 'design' or 'design-review' built-in skill from SkillManager.

=cut

sub handle_design_command {
    my ($self, @args) = @_;
    
    my $prd_path = '.clio/PRD.md';
    
    # Get SkillManager
    my $skill_mgr = $self->_get_skill_manager();
    
    # Check if PRD already exists
    if (-f $prd_path) {
        # Review mode
        $self->display_system_message("Entering PRD review mode...");
        $self->display_system_message("The Architect will analyze your existing PRD and discuss changes.");
        $self->writeline("", markdown => 0);
        
        my $result = $skill_mgr->execute_skill('design-review', {});
        
        if ($result->{success}) {
            return $result->{rendered_prompt};
        } else {
            $self->display_error_message("Failed to load design-review skill: " . ($result->{error} || 'unknown error'));
            return;
        }
    } else {
        # Create mode
        my $type = $args[0] || 'app';
        $self->display_system_message("Starting PRD creation for a '$type' project...");
        $self->display_system_message("The Architect will guide you through the design process.");
        $self->writeline("", markdown => 0);
        
        my $result = $skill_mgr->execute_skill('design', {});
        
        if ($result->{success}) {
            return $result->{rendered_prompt};
        } else {
            $self->display_error_message("Failed to load design skill: " . ($result->{error} || 'unknown error'));
            return;
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
