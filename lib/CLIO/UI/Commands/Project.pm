package CLIO::UI::Commands::Project;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Carp qw(croak);
use Cwd;
use CLIO::Core::Logger qw(should_log);

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

These commands return prompts to be sent to the AI for execution.

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

=head2 handle_init_command(@args)

Initialize CLIO for a project. Returns a prompt for AI to execute.

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
        print "\n";
        $self->display_system_message("To re-initialize, use:");
        $self->display_system_message("  /init --force");
        print "\n";
        return;
    }
    
    # If force flag and instructions exist, back them up
    if ($force && -f $instructions_file) {
        my $timestamp = time();
        my $backup_file = "$instructions_file.backup.$timestamp";
        rename($instructions_file, $backup_file);
        $self->display_system_message("Backed up existing instructions to:");
        $self->display_system_message("  .clio/instructions.md.backup.$timestamp");
        print "\n";
    }
    
    # Check for PRD
    my $prd_path = "$clio_dir/PRD.md";
    my $has_prd = -f $prd_path;
    
    $self->display_system_message("Starting project initialization...");
    if ($has_prd) {
        $self->display_system_message("Found PRD - will incorporate into instructions.");
    }
    $self->display_system_message("CLIO will analyze your codebase and create custom instructions.");
    print "\n";
    
    return $self->_build_init_prompt($has_prd);
}

=head2 _build_init_prompt($has_prd)

Build the initialization prompt for the AI.

=cut

sub _build_init_prompt {
    my ($self, $has_prd) = @_;
    
    my $prompt = <<'INIT_PROMPT';
I need you to initialize CLIO for this project. This is a comprehensive setup task that involves analyzing the codebase and creating custom project instructions.
INIT_PROMPT

    if ($has_prd) {
        $prompt .= <<'PRD_SECTION';

**IMPORTANT: This project has a PRD at `.clio/PRD.md`**

When creating `.clio/instructions.md`, you MUST:
1. Read `.clio/PRD.md` first using file_operations
2. Extract key information from the PRD
3. Incorporate this information into the instructions
PRD_SECTION
    }
    
    $prompt .= <<'INIT_REST';

## Your Tasks:

### 1. Fetch CLIO's Core Methodology
Fetch these reference documents:
- CLIO's instructions template: https://raw.githubusercontent.com/SyntheticAutonomicMind/CLIO/main/.clio/instructions.md
- The Unbroken Method: https://raw.githubusercontent.com/SyntheticAutonomicMind/CLIO/main/ai-assisted/THE_UNBROKEN_METHOD.md

### 2. Analyze This Codebase
Do a thorough analysis of this project:
- Programming language(s), frameworks, libraries
- Project structure and architecture
- Existing tests, CI/CD, documentation
- Code style patterns and conventions

### 3. Create Custom Project Instructions
Create a `.clio/instructions.md` file tailored for THIS project, based on The Unbroken Method principles but customized for the specific needs.

### 4. Set Up .gitignore
Ensure `.gitignore` includes CLIO-specific entries.

### 5. Initialize or Update Git
Initialize git if needed, or add/commit the .clio/ directory.

### 6. Report What You Did
Provide a summary of the project analysis and setup completed.

Begin now - use your tools to complete all these tasks.
INIT_REST

    return $prompt;
}

=head2 handle_design_command(@args)

Create or review Product Requirements Document (PRD). Returns a prompt for AI to execute.

=cut

sub handle_design_command {
    my ($self, @args) = @_;
    
    my $prd_path = '.clio/PRD.md';
    
    # Check if PRD already exists
    if (-f $prd_path) {
        # Review mode
        $self->display_system_message("Entering PRD review mode...");
        $self->display_system_message("The Architect will analyze your existing PRD and discuss changes.");
        print "\n";
        return $self->_build_review_prompt();
    } else {
        # Create mode
        my $type = $args[0] || 'app';
        $self->display_system_message("Starting PRD creation for a '$type' project...");
        $self->display_system_message("The Architect will guide you through the design process.");
        print "\n";
        return $self->_build_design_prompt($type);
    }
}

=head2 _build_review_prompt()

Build the PRD review prompt.

=cut

sub _build_review_prompt {
    my ($self) = @_;
    
    return <<'REVIEW_PROMPT';
You are acting as an **Application Architect** reviewing the user's existing PRD through the **user_collaboration protocol**.

## CRITICAL: Use user_collaboration Tool

**ALL questions and interactions MUST use the user_collaboration tool.** Do NOT ask questions in your regular responses.

## Your Role

You are reviewing the project design with fresh eyes, helping the user:
- Identify gaps or inconsistencies
- Suggest improvements based on best practices
- Challenge assumptions that may no longer be valid
- Ensure the architecture still serves the project goals
- Update the PRD to reflect new insights

## Approach

### 1. Load and Analyze
Read `.clio/PRD.md` using file_operations and analyze it critically.

### 2. Present Findings
Use user_collaboration to show the user your analysis and ask: "What's changed since this PRD was written?"

### 3. Collaborative Review
Based on their response, use user_collaboration for conversational review.

### 4. Document Changes
If any updates are needed, update `.clio/PRD.md` with the changes and create a changelog entry.

Begin by reading the existing PRD.
REVIEW_PROMPT
}

=head2 _build_design_prompt($type)

Build the PRD creation prompt.

=cut

sub _build_design_prompt {
    my ($self, $type) = @_;
    
    my $prompt = <<'DESIGN_PROMPT';
You are acting as an **Application Architect** guiding the user through creating a Product Requirements Document (PRD).

## CRITICAL: Use user_collaboration Tool

**ALL questions and interactions MUST use the user_collaboration tool.**

## Your Role

Help the user define and document their project:
- Understand their vision and goals
- Make technical architecture decisions together
- Document requirements clearly
- Create a comprehensive PRD

## Approach

Use user_collaboration to gather information through conversational questions:

1. **Vision:** "What problem does this project solve? Who is it for?"
2. **Features:** "What are the core features? What's MVP vs. future?"
3. **Technical:** "Any constraints? Preferred technologies? Deployment target?"
4. **Architecture:** Based on their answers, propose architecture options
5. **Details:** Dive into specific sections as needed

## Output

After gathering sufficient information, create `.clio/PRD.md` with:
- Project Overview
- Goals & Requirements
- Technical Architecture
- Feature Specifications
- Development Phases
- Testing Strategy

Begin by asking about their project vision.
DESIGN_PROMPT

    return $prompt;
}

1;

__END__

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

Same as CLIO.

=cut
