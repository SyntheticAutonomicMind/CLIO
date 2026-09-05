# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Core::SkillManager;

use strict;
use warnings;
use utf8;
use CLIO::Core::Logger qw(log_debug);
use CLIO::Util::ConfigPath qw(get_config_file);
use CLIO::Util::JSON qw(encode_json decode_json safe_decode_json);
use File::Spec;
use File::Path qw(make_path);

=head1 NAME

CLIO::Core::SkillManager - Manage custom skills with variable substitution

=head1 DESCRIPTION

CLIO's prompt management system allows users to create, store, and use 
custom skills for common tasks. Supports variable substitution, JSON storage,
and user/project/session-level prompt hierarchies.

=head1 SYNOPSIS

    my $pm = CLIO::Core::SkillManager->new(
        debug => 1,
        session_skills_file => 'sessions/abc123/skills.json'
    );
    
    # Add custom skill
    $pm->add_skill('code-review', 'Review this code: ${code}');
    
    # Execute prompt with context
    my $result = $pm->execute_skill('code-review', { code => $code_content });
    print $result->{rendered_prompt};

=cut

# Built-in skills (read-only)
our %BUILTIN_PROMPTS = (
    explain => {
        name => 'explain',
        description => 'Explain selected code',
        prompt => 'Explain what this code does in clear, simple terms:

${code}',
        variables => ['code'],
        type => 'builtin',
        readonly => 1
    },
    review => {
        name => 'review',
        description => 'Review code for issues',
        prompt => 'Review this code for:
- Security issues
- Performance problems
- Best practices
- Edge cases

${code}',
        variables => ['code'],
        type => 'builtin',
        readonly => 1
    },
    test => {
        name => 'test',
        description => 'Generate comprehensive tests',
        prompt => 'Generate comprehensive tests for:

${code}

Use Test::More framework.
Include:
- Normal cases
- Edge cases
- Error handling
- Input validation',
        variables => ['code'],
        type => 'builtin',
        readonly => 1
    },
    fix => {
        name => 'fix',
        description => 'Propose fixes for problems',
        prompt => 'Analyze and fix problems in this code:

${code}

Problems detected:
${errors}

Provide:
1. Clear explanation of each problem
2. Proposed fix for each issue
3. Complete corrected code',
        variables => ['code', 'errors'],
        type => 'builtin',
        readonly => 1
    },
    doc => {
        name => 'doc',
        description => 'Generate documentation',
        prompt => 'Generate comprehensive documentation for:

${code}

Format: POD

Include:
- Module/function overview
- Parameter descriptions with types
- Return value documentation
- Usage examples
- Edge cases and error handling',
        variables => ['code'],
        type => 'builtin',
        readonly => 1
    },
    design => {
        name => 'design',
        description => 'Create a Product Requirements Document (PRD)',
        prompt => <<'DESIGN_PROMPT',
You are acting as an **Application Architect** guiding the user through creating a Product Requirements Document (PRD).

## CRITICAL: Use interact Tool

**ALL questions and interactions MUST use the interact tool.**

## CRITICAL: Licensing

**NEVER add a LICENSE file, license headers, or SPDX identifiers without explicit user confirmation.**
You MUST ask the user what license they want. If they're unsure, help them choose by discussing:
- Is this open source or proprietary?
- Do they want copyleft (GPL) or permissive (Apache, BSD)?
- Do they need patent protection (Apache 2.0)?
- Are there compatibility requirements with dependencies?

Document the chosen license in the PRD. Do NOT default to MIT or any other license.

## Your Role

Help the user define and document their project:
- Understand their vision and goals
- Make technical architecture decisions together
- Document requirements clearly
- Create a comprehensive PRD

## Approach

Use interact to gather information through conversational questions:

1. **Vision:** "What problem does this project solve? Who is it for?"
2. **Features:** "What are the core features? What's MVP vs. future?"
3. **Technical:** "Any constraints? Preferred technologies? Deployment target?"
4. **Licensing:** "What license do you want for this project?" (help them choose if unsure)
5. **Architecture:** Based on their answers, propose architecture options
6. **Details:** Dive into specific sections as needed

## Output

After gathering sufficient information, create `.clio/PRD.md` with:
- Project Overview
- Goals & Requirements
- Technical Architecture
- Feature Specifications
- Licensing (chosen license with rationale)
- Development Phases
- Testing Strategy

Begin by asking about their project vision.
DESIGN_PROMPT
        variables => [],
        type => 'builtin',
        readonly => 1
    },
    'design-review' => {
        name => 'design-review',
        description => 'Review existing PRD and suggest improvements',
        prompt => <<'REVIEW_PROMPT',
You are acting as an **Application Architect** reviewing the user's existing PRD through the **interact protocol**.

## CRITICAL: Use interact Tool

**ALL questions and interactions MUST use the interact tool.** Do NOT ask questions in your regular responses.

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
Use interact to show the user your analysis and ask: "What's changed since this PRD was written?"

### 3. Collaborative Review
Based on their response, use interact for conversational review.

### 4. Document Changes
If any updates are needed, update `.clio/PRD.md` with the changes and create a changelog entry.

Begin by reading the existing PRD.
REVIEW_PROMPT
        variables => [],
        type => 'builtin',
        readonly => 1
    },
    init => {
        name => 'init',
        description => 'Initialize CLIO for a project',
        prompt => <<'INIT_PROMPT',
I need you to initialize CLIO for this project. This is a comprehensive setup task that involves analyzing the codebase and creating custom project instructions.

## CRITICAL: Licensing

**Do NOT create LICENSE files, add license headers, or assume any license.**
If the project has no license, note it in your report but do not create one.
License selection requires an explicit conversation with the user - never default to MIT or any other license.

## Your Tasks:

### 1. Fetch CLIO's Template Documents

Fetch BOTH of these template files to use as schemas:

**A) Methodology template:**
https://raw.githubusercontent.com/SyntheticAutonomicMind/CLIO/main/docs/templates/instructions.md.template

This defines HOW agents work - The Unbroken Method, collaboration checkpoints, workflow protocols.

**B) Technical reference template:**
https://raw.githubusercontent.com/SyntheticAutonomicMind/CLIO/main/docs/templates/AGENTS.md.template

This defines WHAT technical knowledge agents need - setup commands, code style, testing, architecture.
The template is a generic schema with [PLACEHOLDER] tokens ready to fill in.

**CRITICAL - Understand the Separation:**
- `.clio/instructions.md` = Process/methodology (HOW to work)
- `AGENTS.md` = Technical reference (WHAT to build)
- **NO overlap** - methodology in one, technical details in the other

### 2. Analyze This Codebase

Do a thorough analysis of this project:
- Programming language(s), frameworks, libraries
- Project structure and architecture  
- Existing tests, CI/CD, documentation
- Code style patterns and conventions
- Build and test commands
- Common development workflows
- Entry points and key modules

### 3. Create Project Instructions

**A) `.clio/instructions.md`** - Methodology (HOW to work)

**DO:** Use the fetched instructions.md.template as-is UNLESS this project has specific workflow requirements
**DO NOT:** Put technical details here (commands, file paths, stack info) - those go in AGENTS.md
**CUSTOMIZE ONLY IF:** This project needs methodology adjustments (rare!)

Most projects should use the template unchanged.

**B) `AGENTS.md`** - Technical Reference (WHAT to build)

**DO:** Use the fetched AGENTS.md.template as a fill-in-the-blank schema
**DO:** Replace all [PLACEHOLDER] tokens with this project's technical details
**DO NOT:** Include methodology, checkpoints, or workflow protocols (those are in .clio/instructions.md)
**DO NOT:** Include any CLIO-specific content (modules, packages, provider references) - the template already has it removed

**Anti-Duplication Rules:**

- If it's about HOW to work (checkpoints, workflow, error handling) -> `.clio/instructions.md`
- If it's about WHAT to build (commands, syntax, architecture) -> `AGENTS.md`
- When in doubt: Technical = AGENTS.md, Process = instructions.md

### 4. Verify .gitignore

CLIO automatically manages .gitignore for the .clio/ directory on startup.
Verify that .gitignore contains these entries (add them if missing):
```
.clio/*
!.clio/instructions.md
```
This ignores all CLIO internals while keeping the project instructions committed.
Do NOT add individual .clio/ subdirectories - the wildcard handles everything.

### 5. Initialize or Update Git

Initialize git if needed, or add/commit the .clio/ directory and AGENTS.md.

### 6. Report What You Did

Provide a summary of:
- Project analysis findings
- What you put in `.clio/instructions.md` (used template as-is or customized?)
- Key sections of `AGENTS.md` you created (from template, with [PLACEHOLDER] tokens filled in)
- Setup completed

Begin now - use your tools to complete all these tasks.
INIT_PROMPT
        variables => [],
        type => 'builtin',
        readonly => 1
    },
    'init-with-prd' => {
        name => 'init-with-prd',
        description => 'Initialize CLIO for a project that has an existing PRD',
        prompt => <<'INIT_PRD_PROMPT',
I need you to initialize CLIO for this project. This is a comprehensive setup task that involves analyzing the codebase and creating custom project instructions.

**IMPORTANT: This project has a PRD at `.clio/PRD.md`**

## CRITICAL: Licensing

**Do NOT create LICENSE files, add license headers, or assume any license.**
If the project has no license, note it in your report but do not create one.
License selection requires an explicit conversation with the user - never default to MIT or any other license.

## Your Tasks:

### 1. Fetch CLIO's Template Documents

Fetch BOTH of these template files to use as schemas:

**A) Methodology template:**
https://raw.githubusercontent.com/SyntheticAutonomicMind/CLIO/main/docs/templates/instructions.md.template

This defines HOW agents work - The Unbroken Method, collaboration checkpoints, workflow protocols.

**B) Technical reference template:**
https://raw.githubusercontent.com/SyntheticAutonomicMind/CLIO/main/docs/templates/AGENTS.md.template

This defines WHAT technical knowledge agents need - setup commands, code style, testing, architecture.
The template is a generic schema with [PLACEHOLDER] tokens ready to fill in.

**CRITICAL - Understand the Separation:**
- `.clio/instructions.md` = Process/methodology (HOW to work)
- `AGENTS.md` = Technical reference (WHAT to build)
- **NO overlap** - methodology in one, technical details in the other

### 2. Read the PRD

Read `.clio/PRD.md` to understand the project goals and architecture decisions.

### 3. Analyze This Codebase

Do a thorough analysis of this project:
- Programming language(s), frameworks, libraries
- Project structure and architecture
- Existing tests, CI/CD, documentation
- Code style patterns and conventions
- Build and test commands
- Common development workflows
- Entry points and key modules

### 4. Create Project Instructions

**A) `.clio/instructions.md`** - Methodology (HOW to work)

**DO:** Use the fetched instructions.md.template as-is UNLESS this project has specific workflow requirements
**DO NOT:** Put technical details here (commands, file paths, stack info) - those go in AGENTS.md
**CUSTOMIZE ONLY IF:** PRD specifies unique agent workflow requirements (rare!)

Most projects should use the template unchanged.

**B) `AGENTS.md`** - Technical Reference (WHAT to build)

**DO:** Use the fetched AGENTS.md.template as a fill-in-the-blank schema
**DO:** Replace all [PLACEHOLDER] tokens with this project's technical details
**DO:** Incorporate relevant information from the PRD (architecture, design decisions)
**DO NOT:** Include methodology, checkpoints, or workflow protocols (those are in .clio/instructions.md)
**DO NOT:** Include any CLIO-specific content (modules, packages, provider references) - the template already has it removed

**Incorporate PRD information into the template where relevant:**
- **Project Overview** - Use description from PRD
- **Architecture** - Include architecture decisions from PRD

**Anti-Duplication Rules:**

- If it's about HOW to work (checkpoints, workflow, error handling) -> `.clio/instructions.md`
- If it's about WHAT to build (commands, syntax, architecture) -> `AGENTS.md`
- When in doubt: Technical = AGENTS.md, Process = instructions.md

### 5. Verify .gitignore

CLIO automatically manages .gitignore for the .clio/ directory on startup.
Verify that .gitignore contains these entries (add them if missing):
```
.clio/*
!.clio/instructions.md
```
This ignores all CLIO internals while keeping the project instructions committed.
Do NOT add individual .clio/ subdirectories - the wildcard handles everything.

### 6. Initialize or Update Git

Initialize git if needed, or add/commit the .clio/ directory and AGENTS.md.

### 7. Report What You Did

Provide a summary of:
- Project analysis findings
- Key information from PRD
- What you put in `.clio/instructions.md` (used template as-is or customized?)
- Key sections of `AGENTS.md` you created (from template, with [PLACEHOLDER] tokens filled in, plus PRD integration)
- Setup completed

Begin now - use your tools to complete all these tasks.
INIT_PRD_PROMPT
        variables => [],
        type => 'builtin',
        readonly => 1
    }
);

=head2 new

Create a new SkillManager instance.

Skill storage is organized in three writable scopes plus read-only sources:

=over 4

=item B<user>     - C<~/.clio/skills.json> and C<~/.clio/skills/*.md>

=item B<project>  - C<.clio/skills.json> and C<.clio/skills/*.md>

=item B<session>  - C<sessions/<id>/skills.json>

=item B<repository> - Git-cached SKILL.md files in C<~/.clio/skill-cache/>

=item B<builtin>  - Hardcoded prompts shipped with CLIO

=back

Paths can be overridden with environment variables for testing and isolation:
C<CLIO_USER_SKILLS>, C<CLIO_PROJECT_DIR> (skills.json lives at C<CLIO_PROJECT_DIR/.clio/skills.json>).

Arguments:
- debug: Enable debug output (optional)
- user_skills_file: Path to user-level skills.json (optional)
- project_skills_file: Path to project-level skills.json (optional)
- session_skills_file: Path to session-level skills.json (optional)

Returns: SkillManager instance

=cut

sub new {
    my ($class, %opts) = @_;
    
    # Environment overrides take precedence only when the caller has not
    # explicitly set the matching constructor argument. This keeps the
    # public API stable while still allowing tests and tooling to point
    # SkillManager at isolated directories.
    my $user_file = $opts{user_skills_file}
        || $ENV{CLIO_USER_SKILLS}
        || get_config_file('skills.json');

    my $project_file = $opts{project_skills_file};
    unless ($project_file) {
        my $project_dir = $ENV{CLIO_PROJECT_DIR} || File::Spec->curdir();
        $project_file = File::Spec->catfile($project_dir, '.clio', 'skills.json');
    }

    my $self = {
        debug => $opts{debug} || 0,
        user_skills_file => $user_file,
        project_skills_file => $project_file,
        freeform_user_dir => $opts{freeform_user_dir} ||
            File::Spec->catdir((File::Spec->splitpath($user_file))[1], 'skills'),
        freeform_project_dir => $opts{freeform_project_dir} ||
            File::Spec->catdir((File::Spec->splitpath($project_file))[1], 'skills'),
        session_skills_file => $opts{session_skills_file},
        skills => {},
        active_prompt => undef,
        repo_mgr => undef,
        repo_loader => undef,
    };
    
    bless $self, $class;
    $self->_load_skills();
    return $self;
}

=head2 _load_skills

Load skills from built-in definitions and JSON files.
Priority: Session > Project > User > Built-in

=cut

sub _load_skills {
    my ($self) = @_;
    
    # Built-in skills are the floor. They have scope 'builtin' and are
    # read-only - they cannot be deleted or overwritten.
    $self->{skills} = {};
    for my $name (keys %BUILTIN_PROMPTS) {
        my $skill = { %{$BUILTIN_PROMPTS{$name}} };
        $skill->{scope} = 'builtin';
        $skill->{_source_file} = undef;
        $skill->{readonly} = 1;
        $self->{skills}{$name} = $skill;
    }

    # Load repository skills (low-medium priority)
    $self->_load_repository_skills();

    # Load freeform .md skills (user then project, both editable in-place)
    $self->_load_freeform_skills($self->{freeform_user_dir}, 'user');
    $self->_load_freeform_skills($self->{freeform_project_dir}, 'project') if $self->_has_project_scope();

    # Load user skills (medium priority)
    if (-f $self->{user_skills_file}) {
        $self->_absorb_scoped_file($self->{user_skills_file}, 'user');
    }
    
    # Load project skills (high priority)
    if (-f $self->{project_skills_file}) {
        $self->_absorb_scoped_file($self->{project_skills_file}, 'project');
    }
    
    # Load session skills (highest priority)
    if ($self->{session_skills_file} && -f $self->{session_skills_file}) {
        $self->_absorb_scoped_file($self->{session_skills_file}, 'session');
    }
    
    log_debug('SkillManager', "Loaded " . scalar(keys %{$self->{skills}}) . " skills");
}

=head2 _has_project_scope

Return true when the project skills file is meaningfully different from the
user skills file. We skip the project layer when both paths resolve to the
same file (which happens when running outside of any project directory),
or when the project file would not land in a real C<./.clio/> of an
existing project root. The latter is what protects callers that pass
an explicit C<project_skills_file> for testing or tooling from having
their C<add_skill> defaults silently land in the wrong scope.

=cut

sub _has_project_scope {
    my ($self) = @_;

    my $user = $self->{user_skills_file};
    my $project = $self->{project_skills_file};
    return 0 unless $user && $project;
    return 0 if $user eq $project;

    # Require the canonical layout: project file ends in /.clio/skills.json.
    # This matches the path the SkillManager constructor produces and the
    # paths real project layouts use. Anything else is treated as "no
    # project context" so add_skill defaults stay safe.
    my $project_root = $project;
    $project_root =~ s|/\.clio/skills\.json\z||;
    return -d $project_root ? 1 : 0;
}

=head2 _absorb_scoped_file

Read a skills.json file and merge its entries into the in-memory skills
hash, tagging each entry with its scope and the path it came from. The
source file is recorded so subsequent _save_skills() calls can route
changes back to the correct location.

=cut

sub _absorb_scoped_file {
    my ($self, $file, $scope) = @_;

    my $skills = $self->_read_skills_file($file);
    for my $name (keys %$skills) {
        my $skill = { %{$skills->{$name}} };
        $skill->{scope} = $scope;
        $skill->{_source_file} = $file;
        # Mark all .json-backed custom skills as editable in their scope.
        $skill->{readonly} = 0;
        $skill->{type} = 'custom' unless $skill->{type};
        $self->{skills}{$name} = $skill;
    }
}

=head2 _load_freeform_skills

Scan a directory for freeform SKILL.md and <name>.md files. Each file
becomes a skill with type 'freeform' and scope 'user' or 'project'. The
file path is recorded as the source so the AI can refer back to it.

The user owns the .md file directly. CLIO reads it for the catalog and
exposes it via /skills show, but does not write back. To remove a
freeform skill, delete the file from disk.

=cut

sub _load_freeform_skills {
    my ($self, $dir, $scope) = @_;

    return unless $dir && -d $dir;

    opendir my $dh, $dir or return;
    my @entries = sort grep { $_ ne '.' && $_ ne '..' } readdir($dh);
    closedir $dh;

    for my $entry (@entries) {
        next unless $entry =~ /\.(md|skill)\z/i;

        my $path = File::Spec->catfile($dir, $entry);
        next unless -f $path;

        my $content = $self->_slurp($path);
        next unless defined $content && length $content;

        my ($name, $description) = $self->_parse_freeform_meta($content, $entry);
        my $skill = {
            name => $name,
            description => $description,
            prompt => $content,
            variables => [],
            type => 'freeform',
            scope => 'freeform',
            location => $scope,
            source => $path,
            _source_file => $path,
            readonly => 1,  # user edits the file directly
        };

        # Freeform skills lose to anything more specific with the same name.
        $self->{skills}{$name} = $skill
            unless $self->{skills}{$name};
    }
}

sub _slurp {
    my ($self, $path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or return undef;
    my $content = do { local $/; <$fh> };
    close $fh;
    return $content;
}

sub _parse_freeform_meta {
    my ($self, $content, $filename) = @_;

    my $name = $filename;
    $name =~ s/\.(md|skill)\z//i;
    $name = lc($name);
    $name =~ s/[^a-z0-9_-]+/-/g;
    $name =~ s/-+/-/g;
    $name =~ s/^-+//;
    $name =~ s/-+\z//;

    my $description = '';
    if ($content =~ /\A---\s*\n(.*?)\n---/s) {
        my $yaml = $1;
        if ($yaml =~ /^name:\s*(.+?)\s*$/m) {
            my $declared = $1;
            $declared =~ s/^["']//;
            $declared =~ s/["']$//;
            $name = $declared if length $declared;
        }
        if ($yaml =~ /^description:\s*(.+?)\s*$/m) {
            $description = $1;
            $description =~ s/^["']//;
            $description =~ s/["']$//;
        }
    }

    $description = '(freeform skill, edit the .md file directly)'
        unless length $description;

    return ($name, $description);
}

=head2 _load_repository_skills

Load skills from configured skill repositories.

=cut

sub _load_repository_skills {
    my ($self) = @_;
    
    eval {
        require CLIO::Core::SkillRepository;
        require CLIO::Core::RepositoryLoader;
    };
    if ($@) {
        log_debug('SkillManager', "Repository modules not available: $@");
        return;
    }
    
    $self->{repo_mgr} = CLIO::Core::SkillRepository->new(debug => $self->{debug});
    $self->{repo_loader} = CLIO::Core::RepositoryLoader->new(debug => $self->{debug});
    
    my $repo_skills = $self->{repo_loader}->load_all_skills($self->{repo_mgr});
    
    # Repository skills override built-in but are overridden by custom
    %{$self->{skills}} = (%{$self->{skills}}, %$repo_skills);
    
    my $count = scalar(keys %$repo_skills);
    log_debug('SkillManager', "Loaded $count repository skills") if $count;
}

=head2 get_repo_manager

Get the SkillRepository manager instance.

Returns: CLIO::Core::SkillRepository instance or undef

=cut

sub get_repo_manager {
    my ($self) = @_;
    return $self->{repo_mgr};
}

=head2 get_repo_loader

Get the RepositoryLoader instance.

Returns: CLIO::Core::RepositoryLoader instance or undef

=cut

sub get_repo_loader {
    my ($self) = @_;
    return $self->{repo_loader};
}

=head2 reload_repository_skills

Reload skills from all configured repositories.
Useful after adding/removing/syncing repositories.

=cut

sub reload_repository_skills {
    my ($self) = @_;
    
    # Remove existing repository skills
    for my $name (keys %{$self->{skills}}) {
        delete $self->{skills}{$name} if $self->{skills}{$name}{type} eq 'repository';
    }
    
    # Reload
    $self->_load_repository_skills();
    
    log_debug('SkillManager', "Reloaded repository skills, total: " . 
        scalar(keys %{$self->{skills}}));
}

=head2 _read_skills_file

Read and parse a skills.json file.

Arguments:
- $file: Path to JSON file

Returns: Hashref of skills

=cut

sub _read_skills_file {
    my ($self, $file) = @_;
    
    open my $fh, '<', $file or return {};
    my $json = do { local $/; <$fh> };
    close $fh;
    
    my $data = safe_decode_json($json);
    if ($@) {
        log_debug('SkillManager', "Failed to parse $file: $@");
        return {};
    }
    
    return {} unless $data && $data->{skills};
    
    return $data->{skills};
}

=head2 add_skill

Add a new custom skill.

Skills are written to the file matching their scope. The default scope is
'user' when no .clio/ directory exists in the current working directory,
otherwise 'project'. Pass C<scope =E<gt> 'user' | 'project' | 'session'>
explicitly to override.

Freeform skills cannot be added this way. Edit the .md file directly.

Arguments:
- $name: Skill name (alphanumeric, hyphens, underscores)
- $prompt_text: Skill template with ${variables}
- %opts: Optional parameters
    - description: Human-readable description
    - tags: Arrayref of tags
    - scope: 'user' (default), 'project', or 'session'

Returns: { success => 1, prompt => $prompt } or { success => 0, error => $msg }

=cut

sub add_skill {
    my ($self, $name, $prompt_text, %opts) = @_;
    
    # Validate name
    unless ($name =~ /^[a-zA-Z0-9_-]+$/) {
        return { 
            success => 0, 
            error => "Invalid prompt name (alphanumeric, hyphens, underscores only)" 
        };
    }
    
    # Check for builtin conflict
    if ($BUILTIN_PROMPTS{$name}) {
        return { 
            success => 0, 
            error => "Cannot override builtin prompt '$name'" 
        };
    }
    
    # Validate prompt text
    unless ($prompt_text) {
        return {
            success => 0,
            error => "Prompt text cannot be empty"
        };
    }
    
    # Resolve target scope. Default to project when a .clio directory is
    # present in the current working directory, otherwise user.
    my $scope = $opts{scope} // ($self->_has_project_scope() ? 'project' : 'user');
    unless ($scope =~ /^(user|project|session)$/) {
        return {
            success => 0,
            error => "Invalid scope '$scope' (use 'user', 'project', or 'session')"
        };
    }

    # Check for existing same-name skills that we shouldn't shadow.
    if (my $existing = $self->{skills}{$name}) {
        if (($existing->{scope} // '') eq 'builtin') {
            return { success => 0, error => "Cannot override builtin prompt '$name'" };
        }
        if (($existing->{scope} // '') eq 'repository') {
            return { success => 0, error => "Cannot shadow repository skill '$name' (disable the repository first)" };
        }
        if (($existing->{scope} // '') eq 'freeform') {
            return { success => 0, error => "Cannot shadow freeform skill '$name' (edit the .md file directly)" };
        }
    }

    # Extract variables from prompt
    my @variables = $self->_extract_variables($prompt_text);
    
    my $source_file = $self->_file_for_scope($scope);
    unless ($source_file) {
        return {
            success => 0,
            error => "No writable location for scope '$scope' (session_skills_file not configured)"
        };
    }

    my $prompt = {
        name => $name,
        description => $opts{description} || "Custom skill",
        prompt => $prompt_text,
        variables => \@variables,
        type => 'custom',
        scope => $scope,
        source => $source_file,
        _source_file => $source_file,
        readonly => 0,
        created => time(),
        modified => time(),
        usage_count => 0,
        tags => $opts{tags} || []
    };
    
    $self->{skills}{$name} = $prompt;
    $self->_save_skills();
    
    log_debug('SkillManager', "Added $scope prompt '$name' with variables: " . join(", ", @variables) . "");
    
    return { success => 1, prompt => $prompt };
}

=head2 delete_skill

Delete a custom skill. Routes the deletion to the file that owns the
skill. Built-in, repository, and freeform skills cannot be deleted this
way - those sources have their own lifecycle (uninstall CLIO, remove the
repository, delete the .md file).

Arguments:
- $name: Skill name

Returns: { success => 1 } or { success => 0, error => $msg }

=cut

sub delete_skill {
    my ($self, $name) = @_;
    
    my $skill = $self->{skills}{$name};
    unless ($skill) {
        return { 
            success => 0, 
            error => "Skill '$name' not found" 
        };
    }
    
    my $scope = $skill->{scope} // 'user';
    if ($scope eq 'builtin') {
        return { 
            success => 0, 
            error => "Cannot delete builtin prompt" 
        };
    }
    
    if ($scope eq 'repository') {
        return { 
            success => 0, 
            error => "Cannot delete repository skill. Remove the repository or disable it instead." 
        };
    }
    
    if ($scope eq 'freeform') {
        return {
            success => 0,
            error => "Cannot delete freeform skill '$name' (edit the .md file at: $skill->{source})"
        };
    }

    # If the user explicitly added a same-name skill to a higher-priority
    # scope (project shadows user), deleting the project entry should
    # restore the user version. We surface the original 'user' skill by
    # re-reading the user file. The /skills command handler does this for
    # us before calling delete_skill when needed.
    delete $self->{skills}{$name};
    $self->_save_skills();
    
    log_debug('SkillManager', "Deleted prompt '$name'");
    
    return { success => 1 };
}

=head2 get_skill

Retrieve a prompt by name.

Arguments:
- $name: Skill name

Returns: Skill hashref or undef if not found

=cut

sub get_skill {
    my ($self, $name) = @_;
    
    return $self->{skills}{$name};
}

=head2 list_skills

List all available skills, grouped by type and scope.

The 'by_scope' bucket is the modern grouping the UI and tool prefer:

    { builtin => [...], user => [...], project => [...], session => [...],
      repository => [...], freeform => [...] }

The legacy 'custom' / 'builtin' / 'repository' buckets are kept for
backwards compatibility and aggregate all .json-backed custom skills
(user + project + session + freeform) under 'custom'.

Returns: { custom => [...], builtin => [...], repository => [...],
           by_scope => { ... }, all => [...] }

=cut

sub list_skills {
    my ($self) = @_;

    my @custom = grep { ($self->{skills}{$_}{type} // '') eq 'custom' } keys %{$self->{skills}};
    my @builtin = grep { ($self->{skills}{$_}{type} // '') eq 'builtin' } keys %{$self->{skills}};
    my @repository = grep { ($self->{skills}{$_}{type} // '') eq 'repository' } keys %{$self->{skills}};

    my %by_scope = (
        builtin => [], user => [], project => [], session => [],
        repository => [], freeform => [],
    );
    for my $name (keys %{$self->{skills}}) {
        my $scope = $self->{skills}{$name}{scope} // 'user';
        push @{$by_scope{$scope} //= []}, $name;
    }

    return {
        custom => \@custom,
        builtin => \@builtin,
        repository => \@repository,
        by_scope => \%by_scope,
        all => [keys %{$self->{skills}}]
    };
}

=head2 list_skill_catalog

Return a compact catalog of all installed skills for injection into the
system prompt. Each entry exposes what the agent needs to decide whether
to load a skill: name, description, type, scope, source path, and
template variables.

Variables let the agent know what context to provide when invoking a skill.
Descriptions are truncated to keep the catalog compact.

Arguments:
- $max_description: Truncate description to this many chars (default: 200)
- $scope_filter: Optional arrayref of scopes to include (e.g. ['user','project'])
    Returns all scopes when omitted.

Returns: Arrayref of { name, description, type, scope, source, variables }

=cut

sub list_skill_catalog {
    my ($self, $max_description, $scope_filter) = @_;

    $max_description //= 200;
    my %allowed = $scope_filter ? map { $_ => 1 } @$scope_filter : ();

    my @catalog;
    for my $name (sort keys %{$self->{skills}}) {
        my $skill = $self->{skills}{$name};
        my $scope = $skill->{scope} // 'user';
        next if %allowed && !$allowed{$scope};
        my $desc = $skill->{description} || '';
        if (length($desc) > $max_description) {
            $desc = substr($desc, 0, $max_description - 3) . '...';
        }
        push @catalog, {
            name => $name,
            description => $desc,
            type => $skill->{type} || 'custom',
            scope => $scope,
            source => $skill->{source} || $skill->{_source_file},
            readonly => $skill->{readonly} ? 1 : 0,
            variables => $skill->{variables} || [],
        };
    }

    return \@catalog;
}

=head2 render_skill_content

Render a single skill's full content (after frontmatter stripping) so it
can be appended to a system prompt. Returns the content string, or empty
string if the skill is unknown.

Arguments:
- $name: Skill name

Returns: String (skill content with frontmatter removed) or ""

=cut

sub render_skill_content {
    my ($self, $name) = @_;

    my $skill = $self->get_skill($name);
    return '' unless $skill;

    my $content = $skill->{prompt} || '';
    $content = _strip_frontmatter($content);
    return $content;
}

=head2 get_skill_full

Get a skill with its full prompt content and metadata. Used by the
skill_operations tool's "load" operation. Does not mutate session state.
The returned hashref includes scope and source so the agent knows where
the skill lives and whether it can be modified.

Arguments:
- $name: Skill name

Returns: Skill hashref with prompt, metadata, scope, source, readonly, or undef if not found

=cut

sub get_skill_full {
    my ($self, $name) = @_;

    my $skill = $self->get_skill($name);
    return undef unless $skill;

    return {
        name => $skill->{name},
        description => $skill->{description} || '',
        prompt => $skill->{prompt} || '',
        variables => $skill->{variables} || [],
        type => $skill->{type} || 'custom',
        scope => $skill->{scope} // 'user',
        source => $skill->{source} || $skill->{_source_file},
        readonly => $skill->{readonly} ? 1 : 0,
    };
}

=head2 execute_skill

Execute a prompt by substituting variables with context values.

Arguments:
- $name: Skill name
- $context: Hashref of variable values

Returns: { success => 1, rendered_prompt => $text, prompt => $prompt } 
         or { success => 0, error => $msg }

=cut

sub execute_skill {
    my ($self, $name, $context) = @_;
    
    my $prompt = $self->get_skill($name);
    unless ($prompt) {
        return { 
            success => 0, 
            error => "Skill '$name' not found" 
        };
    }
    
    # Substitute variables
    my $rendered = $self->_substitute_variables($prompt->{prompt}, $context);
    
    # Update usage count for any skill whose backing store is a writable
    # .json file. Built-in, repository, and freeform skills are immutable
    # from the runtime's perspective.
    if (!$prompt->{readonly} && $prompt->{_source_file}) {
        $prompt->{usage_count}++;
        $prompt->{modified} = time();
        $self->_save_skills();
    }
    
    log_debug('SkillManager', "Executed prompt '$name'");
    
    return {
        success => 1,
        rendered_prompt => $rendered,
        prompt => $prompt
    };
}

=head2 load_skill

Load a skill into the session's system prompt. The skill content is merged
into the system prompt for the duration of the session.

Arguments:
- $name: Skill name
- $session_state: Session::State object (stores loaded_skills)

Returns: { success => 1 } or { success => 0, error => $msg }

=cut

sub load_skill {
    my ($self, $name, $session_state) = @_;
    
    unless ($session_state) {
        return { success => 0, error => "No session state available" };
    }
    
    my $skill = $self->get_skill($name);
    unless ($skill) {
        return { success => 0, error => "Skill '$name' not found" };
    }
    
    # Check if already loaded
    my $loaded = $session_state->{loaded_skills} || [];
    for my $ls (@$loaded) {
        if ($ls->{name} eq $name) {
            return { success => 0, error => "Skill '$name' is already loaded" };
        }
    }
    
    # Extract the skill content (strip frontmatter for cleaner prompt injection)
    my $content = $skill->{prompt} || '';
    $content = _strip_frontmatter($content);
    
    # Add to loaded skills
    push @{$session_state->{loaded_skills}}, {
        name => $name,
        description => $skill->{description} || '',
        content => $content,
        loaded_at => time(),
    };
    
    log_debug('SkillManager', "Loaded skill '$name' into session prompt (" . length($content) . " bytes)");
    
    return { success => 1 };
}

=head2 unload_skill

Remove a loaded skill from the session's system prompt.

Arguments:
- $name: Skill name
- $session_state: Session::State object

Returns: { success => 1 } or { success => 0, error => $msg }

=cut

sub unload_skill {
    my ($self, $name, $session_state) = @_;
    
    unless ($session_state) {
        return { success => 0, error => "No session state available" };
    }
    
    my $loaded = $session_state->{loaded_skills} || [];
    my $initial_count = scalar @$loaded;
    
    @{$session_state->{loaded_skills}} = grep { $_->{name} ne $name } @$loaded;
    
    my $removed = $initial_count - scalar(@{$session_state->{loaded_skills}});
    
    if ($removed > 0) {
        log_debug('SkillManager', "Unloaded skill '$name' from session prompt");
        return { success => 1 };
    }
    
    return { success => 0, error => "Skill '$name' is not currently loaded" };
}

=head2 get_loaded_skills

Get all skills currently loaded into the session's system prompt.

Arguments:
- $session_state: Session::State object

Returns: Arrayref of loaded skill records

=cut

sub get_loaded_skills {
    my ($self, $session_state) = @_;
    
    return [] unless $session_state;
    return $session_state->{loaded_skills} || [];
}

=head2 _strip_frontmatter

Remove YAML frontmatter from skill content for cleaner prompt injection.

=cut

sub _strip_frontmatter {
    my ($content) = @_;
    
    # Strip YAML frontmatter (--- ... ---)
    if ($content =~ /\A---\s*\n.*?\n---\s*\n(.*)\z/s) {
        return $1;
    }
    
    return $content;
}

=head2 _substitute_variables

Substitute ${variables} in template with context values.

Arguments:
- $template: Template string with ${var} placeholders
- $context: Hashref of variable values

Returns: String with variables substituted

=cut

sub _substitute_variables {
    my ($self, $template, $context) = @_;
    
    my $result = $template;
    $context ||= {};
    
    # Simple variable substitution: ${var}
    while ($result =~ /\$\{([a-zA-Z0-9_:]+)\}/) {
        my $var = $1;
        my $value = $context->{$var};
        
        # Handle undefined variables
        $value = '' unless defined $value;
        
        # Escape special regex characters in value
        my $escaped_var = quotemeta($var);
        $result =~ s/\$\{$escaped_var\}/$value/g;
    }
    
    return $result;
}

=head2 _extract_variables

Extract all ${variables} from a template.

Arguments:
- $template: Template string

Returns: Array of variable names (unique)

=cut

sub _extract_variables {
    my ($self, $template) = @_;
    
    my @vars = ();
    my %seen = ();
    
    while ($template =~ /\$\{([a-zA-Z0-9_:]+)\}/g) {
        my $var = $1;
        unless ($seen{$var}) {
            push @vars, $var;
            $seen{$var} = 1;
        }
    }
    
    return @vars;
}

=head2 _save_skills

Save custom skills to user-level JSON file.

=cut

sub _save_skills {
    my ($self) = @_;
    
    # Group skills by their backing file. Each scope has its own .json
    # file (user, project, session). Read-only sources (builtin,
    # repository, freeform) are excluded from writes because we never
    # own their backing store.
    my %by_file;
    for my $name (keys %{$self->{skills}}) {
        my $skill = $self->{skills}{$name};
        next if $skill->{readonly};
        next unless $skill->{_source_file};
        push @{$by_file{$skill->{_source_file}}}, $name;
    }

    my $total_written = 0;
    for my $file (keys %by_file) {
        my $skills_in_file = {};
        my $active_in_file = undef;
        for my $name (@{$by_file{$file}}) {
            my $skill = $self->{skills}{$name};
            # Strip internal-only fields before persisting.
            my $clean = { %$skill };
            delete $clean->{_source_file};
            $skills_in_file->{$name} = $clean;
            $active_in_file //= $name;
        }

        my $data = {
            version => '1.0',
            skills => $skills_in_file,
            active_prompt => $file eq $self->{user_skills_file} ? $self->{active_prompt} : undef,
            metadata => {
                last_updated => time(),
                total_prompts => scalar(keys %$skills_in_file)
            }
        };

        # Ensure directory exists.
        my ($volume, $dir, $name_part) = File::Spec->splitpath($file);
        my $full_dir = File::Spec->catpath($volume, $dir, '');
        make_path($full_dir) unless -d $full_dir;
    
        # Write JSON atomically: temp file then rename, so a crash
        # mid-write never leaves a half-truncated skills.json behind.
        my $tmp_file = "$file.tmp.$$";
        open my $fh, '>:encoding(UTF-8)', $tmp_file or do {
            log_debug('SkillManager', "Cannot write to $tmp_file: $!");
            next;
        };
        print $fh encode_json($data);
        close $fh or do {
            log_debug('SkillManager', "Cannot close $tmp_file: $!");
            next;
        };
        rename $tmp_file, $file or do {
            log_debug('SkillManager', "Cannot rename $tmp_file to $file: $!");
            next;
        };
    
        $total_written += scalar(keys %$skills_in_file);
        log_debug('SkillManager', "Saved " . scalar(keys %$skills_in_file) .
            " skills to $file");
    }
    
    if ($total_written == 0) {
        log_debug('SkillManager', "No writable skills to save");
    }
}

=head2 _file_for_scope

Resolve the on-disk file that backs a given scope. Returns undef for
the session scope when no session_skills_file is configured.

=cut

sub _file_for_scope {
    my ($self, $scope) = @_;

    return $self->{user_skills_file}    if $scope eq 'user';
    return $self->{project_skills_file} if $scope eq 'project';
    return $self->{session_skills_file} if $scope eq 'session' && $self->{session_skills_file};
    return undef;
}

=head2 scope_for_skill

Return the scope of a registered skill, or undef if the name is unknown.

=cut

sub scope_for_skill {
    my ($self, $name) = @_;
    my $skill = $self->{skills}{$name} or return undef;
    return $skill->{scope} // 'user';
}

=head2 source_for_skill

Return the on-disk file or path backing a skill. Built-in skills return
undef since they have no backing file.

=cut

sub source_for_skill {
    my ($self, $name) = @_;
    my $skill = $self->{skills}{$name} or return undef;
    return $skill->{source} || $skill->{_source_file};
}

=head2 reload

Drop the in-memory skill cache and re-read from disk. Useful after
editing a freeform .md file or after manually changing a skills.json.

=cut

sub reload {
    my ($self) = @_;
    $self->_load_skills();
    return 1;
}

1;

__END__

=head1 AUTHOR

Fewtarius

=head1 LICENSE

Copyright (c) 2026 CLIO Project

=cut

1;
