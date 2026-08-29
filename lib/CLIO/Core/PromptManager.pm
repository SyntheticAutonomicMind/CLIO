# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Core::PromptManager;

use strict;
use warnings;
use utf8;
use CLIO::Core::Logger qw(log_error log_debug log_warning log_info);
use CLIO::Util::ConfigPath qw(get_config_file);
use CLIO::Util::TextSanitizer qw(sanitize_text);
use CLIO::Util::AtomicWrite qw(atomic_write);
use Carp qw(croak);
use CLIO::Util::JSON qw(encode_json decode_json);
use File::Spec;
use File::Path qw(make_path);
use File::Basename qw(dirname);
use Cwd qw(getcwd);

=head1 NAME

CLIO::Core::PromptManager - Manage AI system prompts

=head1 DESCRIPTION

CLIO's system prompt management allows users to switch between different
AI system prompts, create custom variants, and edit prompts. System prompts 
define the AI's behavior, personality, and tool usage patterns.

CRITICAL DISTINCTION:
- System prompts (this module) = AI behavior/personality/tool usage
- Skills (SkillManager) = User task templates with variable substitution

=head1 SYNOPSIS

    my $pm = CLIO::Core::PromptManager->new(debug => 1);
    
    # Get current system prompt (includes custom instructions)
    my $prompt = $pm->get_system_prompt();
    
    # List available prompts
    my $prompts = $pm->list_prompts();
    # { builtin => ['default'], custom => ['minimal', 'verbose'] }
    
    # Switch to different prompt
    $pm->set_active_prompt('minimal');
    
    # Create new custom prompt
    $pm->save_prompt('my-custom', $content);

=cut

=head2 new

Create a new PromptManager instance.

Arguments:
- debug: Enable debug output (optional)
- prompts_dir: Path to system prompts directory (optional)

Returns: PromptManager instance

=cut

sub new {
    my ($class, %opts) = @_;
    
    my $prompts_dir = $opts{prompts_dir} || 
        get_config_file('system-prompts');
    
    my $self = {
        debug => $opts{debug} || 0,
        skip_custom => $opts{skip_custom} || 0,
        enable_subagents => $opts{enable_subagents} // 1,
        prompts_dir => $prompts_dir,
        custom_dir => File::Spec->catfile($prompts_dir, 'custom'),
        metadata_file => File::Spec->catfile($prompts_dir, 'metadata.json'),
        metadata => {},
        custom_instructions_cache => undef,
        model_class => undef,
    };
    
    bless $self, $class;
    
    # Ensure directories exist ONLY if custom prompts are being used
    # Don't create directories just for reading the default prompt
    
    # Load metadata only if it exists
    $self->_load_metadata();
    
    # DO NOT create default prompt file - use embedded prompt instead
    # File is only created when user explicitly edits/saves
    
    return $self;
}

=head2 get_system_prompt

Get the currently active system prompt text (STABLE PORTION ONLY).

Dynamic sections (LTM patterns, loaded skills, OpenSpec context) are NOT
included here - they are returned separately by get_dynamic_context() for
injection into the user message to preserve prompt cache stability.

Includes: base prompt, custom instructions, plugin instructions,
puppeteer topology.

Returns: System prompt string (stable)

=cut

sub get_system_prompt {
    my ($self, $session) = @_;
    
    # Get active prompt name from metadata (only if metadata was loaded)
    # Note: prompt_override is handled by PromptBuilder via modifying metadata
    my $active = $self->{metadata}->{active_prompt} || 'default';
    
    log_debug('PromptManager', "Getting system prompt: $active");
    
    my $prompt;
    
    # Handle special embedded prompts first (before checking for files)
    if ($active eq 'chat') {
        # Chat mode uses embedded conversational prompt
        log_debug('PromptManager', "Using embedded chat prompt (conversational mode)");
        $prompt = $self->_get_chat_prompt_content();
    }
    # If active prompt is 'default' and no file exists, use embedded default
    elsif ($active eq 'default') {
        my $default_file = File::Spec->catfile($self->{prompts_dir}, 'default.md');
        if (-f $default_file) {
            # User has customized the default prompt - use file
            $prompt = $self->_read_prompt_file($active);
        } else {
            # No customization - use embedded default
            log_debug('PromptManager', "Using embedded default prompt (no file created)");
            $prompt = $self->_get_default_prompt_content();
        }
    } else {
        # Non-default prompt - must read from file
        $prompt = $self->_read_prompt_file($active);
    }
    
    unless ($prompt) {
        log_error('PromptManager', "Failed to load active prompt '$active', falling back to embedded default");
        $prompt = $self->_get_default_prompt_content();
    }
    
    # LTM patterns are now injected via get_dynamic_context() into the user message
    # to preserve prompt cache stability across turns.
    
    # Append custom instructions if they exist (unless --no-custom-instructions flag set)
    if (!$self->{skip_custom}) {
        my $custom = $self->_load_custom_instructions();
        if ($custom) {
            log_debug('PromptManager', "Appending custom instructions (" . length($custom) . " bytes)");
            
            # Sanitize UTF-8 emojis to prevent JSON encoding issues
            $custom = sanitize_text($custom);
            
            $prompt .= "\n\n<customInstructions>\n";
            $prompt .= $custom;
            $prompt .= "\n</customInstructions>\n";
        } else {
            log_debug('PromptManager', "No custom instructions found (no .clio/instructions.md or AGENTS.md)");
        }
    } elsif ($self->{debug}) {
        log_debug('PromptManager', "Skipping custom instructions (--no-custom-instructions flag)");
    }
    
    # Loaded skills are now injected via get_dynamic_context() into the user message
    # to preserve prompt cache stability across turns.
    
    # OpenSpec context is now injected via get_dynamic_context() into the user message
    # to preserve prompt cache stability across turns.
    
    # Inject plugin instructions if any plugins are loaded
    eval {
        require CLIO::Core::PluginManager;
        my $pm = CLIO::Core::PluginManager->instance();
        if ($pm) {
            my $plugin_instructions = $pm->get_all_instructions();
            if ($plugin_instructions && length($plugin_instructions) > 0) {
                $prompt .= "\n\n<pluginInstructions>\n";
                $prompt .= $plugin_instructions;
                $prompt .= "\n</pluginInstructions>\n";
                log_debug('PromptManager', "Injected plugin instructions (" . length($plugin_instructions) . " bytes)");
            }
        }
    };
    log_debug('PromptManager', "Plugin instructions check: $@") if $@;
    
    # Inject puppeteer topology if submodules or .clio/-enabled child projects exist
    eval {
        require CLIO::Protocols::Puppeteer;
        my $pup = CLIO::Protocols::Puppeteer->new(root => '.');
        my $topology = $pup->detect_topology();
        if ($topology->{count} > 0) {
            my $summary = $pup->project_summary();
            $prompt .= "\n\n<puppeteerTopology>\n";
            $prompt .= $summary;
            $prompt .= "\n</puppeteerTopology>\n";
            log_info('PromptManager', "Injected puppeteer topology: %d projects", $topology->{count});
        }
    };
    log_debug('PromptManager', "Puppeteer topology check: $@") if $@;
    
    return $prompt;
}

=head2 get_dynamic_context

Get dynamic context sections for injection into the user message (AFTER
cache breakpoints). These sections change between turns and would
invalidate the prompt cache if included in the system prompt.

Includes: LTM patterns, loaded skills, OpenSpec context.

Arguments:
- $session: Session object (required for LTM and loaded skills)

Returns: Dynamic context string, or empty string if nothing to inject

=cut

sub get_dynamic_context {
    my ($self, $session) = @_;

    my @sections;

    # LTM patterns (from session)
    if ($session) {
        my $ltm_section = $self->_format_ltm_patterns($session);
        if ($ltm_section) {
            push @sections, $ltm_section;
            log_debug('PromptManager', "Dynamic context: LTM patterns (" . length($ltm_section) . " chars)");
        }

        # Loaded skills
        if ($session->{loaded_skills} && @{$session->{loaded_skills}}) {
            my @loaded = @{$session->{loaded_skills}};
            log_debug('PromptManager', "Dynamic context: " . scalar(@loaded) . " loaded skill(s)");

            for my $skill (@loaded) {
                my $name = $skill->{name} || 'unknown';
                my $content = $skill->{content} || '';
                next unless length($content) > 0;

                my $skill_block = "\n\n<loadedSkill name=\"$name\">\n";
                $skill_block .= $content;
                $skill_block .= "\n</loadedSkill>\n";
                push @sections, $skill_block;

                log_debug('PromptManager', "Dynamic context: loaded skill '$name' (" . length($content) . " bytes)");
            }
        }
    }

    # OpenSpec context
    eval {
        require CLIO::Spec::Manager;
        # Anchor to the project root (directory containing .clio/) instead
        # of the current working directory. CWD can change but the spec
        # file location must be stable so the agent has access to project
        # specs across sessions.
        require CLIO::Util::PathResolver;
        require Cwd;
        my $clio_dir = CLIO::Util::PathResolver::find_clio_dir(Cwd::getcwd());
        my $spec_mgr = CLIO::Spec::Manager->new(project_root => $clio_dir);
        if ($spec_mgr->is_initialized()) {
            my $spec_context = $spec_mgr->get_spec_context();
            if ($spec_context && length($spec_context) > 0) {
                my $spec_block = "\n\n<openSpecContext>\n";
                $spec_block .= $spec_context;
                $spec_block .= "</openSpecContext>\n";
                push @sections, $spec_block;
                log_debug('PromptManager', "Dynamic context: OpenSpec (" . length($spec_context) . " bytes)");
            }
        }
    };
    log_debug('PromptManager', "Dynamic context OpenSpec check: $@") if $@;

    return '' unless @sections;

    my $dynamic = join('', @sections);
    log_debug('PromptManager', "Dynamic context total: " . length($dynamic) . " chars");
    return $dynamic;
}

=head2 list_prompts

List all available system prompts (builtin and custom).

Returns: Hashref with structure:
{
    builtin => ['default'],
    custom => ['minimal', 'verbose', ...]
}

=cut

sub list_prompts {
    my ($self) = @_;
    
    my @builtin = ('default', 'chat');
    my @custom = ();
    
    # Find custom prompts
    if (-d $self->{custom_dir}) {
        opendir(my $dh, $self->{custom_dir}) or do {
            log_error('PromptManager', "Cannot read custom prompts dir: $!");
            return { builtin => \@builtin, custom => \@custom };
        };
        
        @custom = grep { 
            /\.md$/ && -f File::Spec->catfile($self->{custom_dir}, $_) 
        } readdir($dh);
        closedir($dh);
        
        # Remove .md extension
        @custom = map { s/\.md$//r } @custom;
    }
    
    return {
        builtin => \@builtin,
        custom => \@custom
    };
}

=head2 set_active_prompt

Switch to a different system prompt.

Arguments:
- $name: Name of prompt to activate

Returns: Hashref with structure:
{ success => 1 } or { success => 0, error => "..." }

=cut

sub set_active_prompt {
    my ($self, $name) = @_;
    
    unless ($name) {
        return { success => 0, error => "Prompt name is required" };
    }
    
    # Check if prompt exists
    my $prompts = $self->list_prompts();
    my @all_prompts = (@{$prompts->{builtin}}, @{$prompts->{custom}});
    
    unless (grep { $_ eq $name } @all_prompts) {
        return { 
            success => 0, 
            error => "Prompt '$name' not found. Use /prompt list to see available prompts." 
        };
    }
    
    # Update metadata
    $self->{metadata}->{active_prompt} = $name;
    $self->_save_metadata();
    
    log_debug('PromptManager', "Switched to prompt: $name");
    
    return { success => 1 };
}

=head2 save_prompt

Save content as a new custom prompt.

Arguments:
- $name: Name for the new prompt
- $content: Prompt text content

Returns: Hashref with structure:
{ success => 1 } or { success => 0, error => "..." }

=cut

sub save_prompt {
    my ($self, $name, $content) = @_;
    
    unless ($name) {
        return { success => 0, error => "Prompt name is required" };
    }
    
    unless ($content) {
        return { success => 0, error => "Prompt content is required" };
    }
    
    # Validate name (no special chars, not 'default')
    if ($name eq 'default') {
        return { 
            success => 0, 
            error => "Cannot override builtin prompt 'default'. Choose a different name." 
        };
    }
    
    if ($name !~ /^[a-zA-Z0-9_-]+$/) {
        return { 
            success => 0, 
            error => "Invalid prompt name. Use only letters, numbers, hyphens, and underscores." 
        };
    }
    
    # Ensure directories exist before saving
    $self->_ensure_directories();
    
    # Save to custom directory
    my $file = File::Spec->catfile($self->{custom_dir}, "$name.md");
    
    eval {
        $self->_write_prompt_file($file, $content);
        
        # Update metadata
        $self->{metadata}->{prompts}->{$name} = {
            name => $name,
            description => "Custom system prompt",
            type => 'custom',
            readonly => 0,
            created => $self->_current_timestamp(),
            modified => $self->_current_timestamp(),
        };
        $self->_save_metadata();
    };
    
    if ($@) {
        return { success => 0, error => "Failed to save prompt: $@" };
    }
    
    log_debug('PromptManager', "Saved custom prompt: $name");
    
    return { success => 1 };
}

=head2 edit_prompt

Open a system prompt in user's $EDITOR.

Arguments:
- $name: Name of prompt to edit (creates new if doesn't exist)

Returns: Hashref with structure:
{ success => 1, modified => 1/0 } or { success => 0, error => "..." }

=cut

sub edit_prompt {
    my ($self, $name) = @_;
    
    unless ($name) {
        return { success => 0, error => "Prompt name is required" };
    }
    
    # Cannot edit builtin prompts
    if ($name eq 'default') {
        return { 
            success => 0, 
            error => "Cannot edit builtin prompt 'default'. Use 'save' to create a custom variant." 
        };
    }
    
    # Validate name
    if ($name !~ /^[a-zA-Z0-9_-]+$/) {
        return { 
            success => 0, 
            error => "Invalid prompt name. Use only letters, numbers, hyphens, and underscores." 
        };
    }
    
    # Determine file path
    my $file = File::Spec->catfile($self->{custom_dir}, "$name.md");
    
    # If doesn't exist, create template
    unless (-f $file) {
        my $template = $self->_create_prompt_template();
        eval {
            $self->_write_prompt_file($file, $template);
        };
        if ($@) {
            return { success => 0, error => "Failed to create template: $@" };
        }
    }
    
    # Get editor
    my $editor = $ENV{EDITOR} || $ENV{VISUAL} || 'vi';
    
    # Get modification time before edit
    my $mtime_before = (stat($file))[9] || 0;
    
    # Open in editor
    system($editor, $file);
    
    if ($? != 0) {
        return { success => 0, error => "Editor exited with error" };
    }
    
    # Check if modified
    my $mtime_after = (stat($file))[9] || 0;
    my $modified = ($mtime_after != $mtime_before) ? 1 : 0;
    
    # Update metadata if this is a new prompt
    if ($modified && !exists $self->{metadata}->{prompts}->{$name}) {
        $self->{metadata}->{prompts}->{$name} = {
            name => $name,
            description => "Custom system prompt",
            type => 'custom',
            readonly => 0,
            created => $self->_current_timestamp(),
            modified => $self->_current_timestamp(),
        };
        $self->_save_metadata();
    } elsif ($modified) {
        # Update modified timestamp
        $self->{metadata}->{prompts}->{$name}->{modified} = $self->_current_timestamp();
        $self->_save_metadata();
    }
    
    log_debug('PromptManager', "Edited prompt: $name (modified: $modified)");
    
    return { success => 1, modified => $modified };
}

=head2 delete_prompt

Delete a custom prompt.

Arguments:
- $name: Name of prompt to delete

Returns: Hashref with structure:
{ success => 1 } or { success => 0, error => "..." }

=cut

sub delete_prompt {
    my ($self, $name) = @_;
    
    unless ($name) {
        return { success => 0, error => "Prompt name is required" };
    }
    
    # Cannot delete builtin prompts
    if ($name eq 'default') {
        return { 
            success => 0, 
            error => "Cannot delete builtin prompt 'default'." 
        };
    }
    
    # Check if exists
    my $file = File::Spec->catfile($self->{custom_dir}, "$name.md");
    unless (-f $file) {
        return { success => 0, error => "Prompt '$name' not found." };
    }
    
    # Delete file
    unlink($file) or do {
        return { success => 0, error => "Failed to delete prompt file: $!" };
    };
    
    # Remove from metadata
    delete $self->{metadata}->{prompts}->{$name};
    
    # If this was active, switch to default
    if ($self->{metadata}->{active_prompt} eq $name) {
        $self->{metadata}->{active_prompt} = 'default';
    }
    
    $self->_save_metadata();
    
    log_debug('PromptManager', "Deleted prompt: $name");
    
    return { success => 1 };
}

=head2 reset_to_default

Reset to default builtin prompt.

Returns: Hashref with structure:
{ success => 1 } or { success => 0, error => "..." }

=cut

sub reset_to_default {
    my ($self) = @_;
    
    $self->{metadata}->{active_prompt} = 'default';
    $self->_save_metadata();
    
    log_debug('PromptManager', "Reset to default prompt");
    
    return { success => 1 };
}

# âââââââââââââââââââââââââââââââââââââââââââââââââââ
# INTERNAL METHODS
# âââââââââââââââââââââââââââââââââââââââââââââââââââ

=head2 _ensure_directories

Ensure prompts directories exist.

=cut

sub _ensure_directories {
    my ($self) = @_;
    
    for my $dir ($self->{prompts_dir}, $self->{custom_dir}) {
        unless (-d $dir) {
            make_path($dir) or do {
                croak "Cannot create prompt directory $dir: $!";
            };
            log_debug('PromptManager', "Created directory: $dir");
        }
    }
}

=head2 _load_custom_instructions

Load custom instructions from .clio/instructions.md.
Caches result for performance.

Returns: Custom instructions text or undef

=cut

sub _load_custom_instructions {
    my ($self) = @_;

    # Return cached value if available
    return $self->{custom_instructions_cache}
        if defined $self->{custom_instructions_cache};

    # Try to load from .clio/instructions.md
    require CLIO::Core::InstructionsReader;
    my $reader = CLIO::Core::InstructionsReader->new(debug => $self->{debug});
    # Pass model_class so XS-class models skip AGENTS.md. This is the
    # context-window-class aware budget for the custom instructions
    # section. See lib/CLIO/Core/ModelBudget.pm and
    # docs/SPECS/MODEL_BUDGETS.md for the full budget table.
    my $custom = $reader->read_instructions(undef,
        model_class => $self->{model_class});

    # Cache result (even if undef)
    $self->{custom_instructions_cache} = $custom;

    return $custom;
}

=head2 set_model_class

Set the model class for budget allocation. XS-class models will skip
AGENTS.md via _load_custom_instructions. Callers should pass the
class from CLIO::Core::ModelBudget::model_class().

Arguments:
    $class - 'XS', 'S', 'M', 'L', 'XL', or undef to clear

=cut

sub set_model_class {
    my ($self, $class) = @_;
    $self->{model_class} = $class;
    # Invalidate the cached instructions so the next load reflects the
    # new class. This is critical: if the class changes mid-session
    # (e.g. user switches from cloud to local), we must re-read with
    # the new skip_agents_md setting.
    undef $self->{custom_instructions_cache};
    return 1;
}

=head2 _read_prompt_file

Read a prompt file by name.

Arguments:
- $name: Prompt name (without .md extension)

Returns: Prompt content or undef on error

=cut

sub _read_prompt_file {
    my ($self, $name) = @_;
    
    # Try builtin first
    my $file = File::Spec->catfile($self->{prompts_dir}, "$name.md");
    
    # If not builtin, try custom
    unless (-f $file) {
        $file = File::Spec->catfile($self->{custom_dir}, "$name.md");
    }
    
    unless (-f $file) {
        log_error('PromptManager', "Prompt file not found: $name");
        return undef;
    }
    
    # Read file
    open(my $fh, '<:encoding(UTF-8)', $file) or do {
        log_error('PromptManager', "Cannot read $file: $!");
        return undef;
    };
    
    my $content = do { local $/; <$fh> };
    close($fh);
    
    return $content;
}

=head2 _write_prompt_file

Write content to a prompt file.

Arguments:
- $file: Full path to file
- $content: Content to write

=cut

sub _write_prompt_file {
    my ($self, $file, $content) = @_;
    
    # Ensure parent directory exists
    my $dir = dirname($file);
    unless (-d $dir) {
        make_path($dir) or croak "Cannot create directory $dir: $!";
    }
    
    # Write atomically to prevent corruption on process kill
    atomic_write($file, $content, mode => 0644, encoding => 'UTF-8')
        or croak "Cannot write to $file: $!";
    
    log_debug('PromptManager', "Wrote prompt file: $file");
}

=head2 _load_metadata

Load metadata.json.

=cut

sub _load_metadata {
    my ($self) = @_;
    
    if (-f $self->{metadata_file}) {
        open(my $fh, '<:encoding(UTF-8)', $self->{metadata_file}) or do {
            log_error('PromptManager', "Cannot read metadata: $!");
            return;
        };
        
        my $json = do { local $/; <$fh> };
        close($fh);
        
        eval {
            $self->{metadata} = decode_json($json);
        };
        if ($@) {
            log_error('PromptManager', "Invalid metadata JSON: $@");
            $self->{metadata} = {};
        }
    } else {
        # Initialize empty metadata
        $self->{metadata} = {
            active_prompt => 'default',
            prompts => {}
        };
    }
}

=head2 _save_metadata

Save metadata.json.

=cut

sub _save_metadata {
    my ($self) = @_;
    
    my $json = encode_json($self->{metadata});
    
    # Write atomically to prevent corruption on process kill
    atomic_write($self->{metadata_file}, $json, mode => 0600)
        or do {
            log_error('PromptManager', "Cannot write metadata: $!");
            return;
        };
    
    log_debug('PromptManager', "Saved metadata");
}

=head2 _current_timestamp

Get current timestamp in ISO 8601 format.

Returns: Timestamp string

=cut

sub _current_timestamp {
    my ($self) = @_;
    
    my ($sec, $min, $hour, $mday, $mon, $year) = gmtime(time);
    return sprintf("%04d-%02d-%02dT%02d:%02d:%02dZ",
        $year + 1900, $mon + 1, $mday, $hour, $min, $sec);
}

=head2 _create_prompt_template

Create a template for new custom prompts.

Returns: Template string

=cut

sub _create_prompt_template {
    my ($self) = @_;
    
    return <<'END_TEMPLATE';
# Custom System Prompt

You are CLIO, an intelligent AI coding assistant.

[Edit this prompt to customize AI behavior]

## Tool Usage

[Describe how to use tools]

## Response Style

[Describe desired response format and style]

## Capabilities

[List what the AI should focus on]
END_TEMPLATE
}

=head2 _get_manager_instructions

Get multi-agent coordination instructions for manager role (primary agents).

Returns: Markdown text with manager responsibilities

=cut

sub _get_manager_instructions {
    my ($self) = @_;
    
    return <<'MANAGER_END';
## Multi-Agent Coordination (Manager Role)

**When you spawn sub-agents, YOU ARE THE MANAGER, NOT THE WORKER.**

**Manager responsibilities:**
- Spawn sub-agents with clear, specific tasks
- Monitor their progress via `agent_operations(operation: "inbox")`
- Answer their questions via `agent_operations(operation: "send")`
- Validate their completed work

**CRITICAL: Do NOT do the sub-agents' work!**

| Wrong | Right |
|-------|-------|
| Spawn agent, then immediately write the file yourself | Spawn agent, wait for completion, verify result |
| Check if agent created file, create it yourself if missing | Check inbox for agent messages, give agent time to work |
| Assume agent failed without checking | Poll inbox, check agent status, read agent logs |

**Manager workflow:**
1. Spawn agents with specific tasks (oneshot by default; use persistent=true for interactive agents)
2. Wait for agents: `agent_operations(operation: "wait")` blocks until events arrive
3. Check inbox for completion/question messages
4. If questions, reply with `agent_operations(operation: "send")`
5. When complete, verify results (read files, run tests)
6. Report to user

**Waiting for agents:**
Sub-agents are separate processes that take time to complete. After spawning:
- Use `agent_operations(operation: "wait")` to block until agent activity occurs
- Use `agent_operations(operation: "list")` to check status
- Poll `agent_operations(operation: "inbox")` for messages
- Read agent logs if needed: `/tmp/clio-agent-<id>.log`
- Allow 15-60 seconds for agents to complete their work
MANAGER_END
}

=head2 _get_subagent_instructions

Get instructions for sub-agent autonomous mode (spawned agents).

Returns: Markdown text with sub-agent operational guidelines

=cut

sub _get_subagent_instructions {
    my ($self) = @_;
    
    return <<'SUBAGENT_END';
## Sub-Agent Autonomous Mode

You are running as a sub-agent in a multi-agent workflow. Your messages go to the manager agent (or user), not directly to the user.

### Checkpoint Protocol - Modified for Sub-Agents

Use `interact` for genuine questions, blockers, and completion reports. The manager may take time to respond - be patient.

- Use it for genuine questions only the manager/user can answer
- Blocked and need guidance after trying alternatives
- Multiple valid approaches and you need direction
- Task complete and reporting results

**Do NOT use interact for:**

- Questions you can answer yourself
- Minor implementation details (make decisions autonomously)
- Permission for every small change (you already have authority)

### Modified Workflow

1. **Receive Task** - Your initial task comes from spawn command
2. **Investigate** - Read code, understand context (no checkpoint needed)
3. **Implement** - Make changes to complete your task (autonomous)
4. **Verify** - Test your changes work correctly
5. **Report** - Send completion message via interact when done

### Decision Making Authority

You have FULL authority for your assigned task:
- Choose implementation approaches without asking
- Make code changes autonomously
- Fix bugs discovered along the way
- Iterate through errors until resolved
- Use tools freely (except blocked ones: remote_execution, spawning more sub-agents)

**Only ask for help when:**
- You've tried multiple approaches and all failed
- You need information only the manager/user has
- You're genuinely uncertain about direction

### All Standard CLIO Rules Apply

- Investigation-first approach
- Code style conventions
- Error recovery patterns (3-attempt rule)
- Complete ownership of your scope
- Testing requirements
- Quality standards

### If Blocked

1. **Ethics violation:** Refuse via interact, explain, stop
2. **Missing info:** Make reasonable inference, proceed, document assumption
3. **Errors:** Debug, try alternatives, iterate 3 times before asking
4. **Genuinely stuck:** Report via interact with what you tried
SUBAGENT_END
}

=head2 _get_puppeteer_child_instructions($project_name)

Get additional instructions for an agent running as a puppeteer-delegated child.
This agent is working in a specific project directory with that project's full context.

=cut

sub _get_puppeteer_child_instructions {
    my ($self, $project_name) = @_;
    
    return <<"PUPPETEER_CHILD";

## Puppeteer Delegation Context

You are running as a **delegated agent** for the **$project_name** project.

A primary orchestrator agent has delegated a specific task to you. You are running
inside this project's directory with full access to its .clio/ context, LTM,
instructions, and memory. Use this project's conventions and patterns.

**Key behaviors:**
- You own the scope of work within this project
- Follow this project's coding conventions (from .clio/instructions.md and LTM)
- Commit changes within this project's repository
- Report results to the orchestrator via interact when complete
- Do not modify files outside this project directory
PUPPETEER_CHILD
}

=head2 _get_chat_prompt_content

Get the chat mode system prompt (conversational AI like SAM).

Returns: Chat prompt content

=cut

sub _get_chat_prompt_content {
    my ($self) = @_;
    
    my $agent_name = $ENV{CLIO_AGENT_NAME} || 'CLIO';
    my $agent_subtitle = $ENV{CLIO_AGENT_SUBTITLE} || 'Command Line Intelligent Operator';
    
    return <<"END_CHAT_PROMPT";
# $agent_name System Prompt

You are $agent_name ($agent_subtitle), a friendly and helpful AI assistant.

## Core Identity

When asked for your name, you must respond with "$agent_name".

**YOU ARE AN ASSISTANT** - This defines your operational model:

- You help with questions, discussions, research, and general tasks
- You engage naturally and conversationally
- You take action when useful - use tools for research and tasks
- You stop only when the user's question is answered or task is complete

---

You are a conversational AI assistant, ready to help with questions, discussions,
research, and general tasks. You engage naturally and helpfully.

## Operational Modes

### Conversational Mode
**When:** User is asking questions, discussing topics, exploring ideas

**Approach:**
- Understand the question thoroughly
- Gather information using tools if needed (web search, file access)
- Provide clear, comprehensive answers with context
- Engage naturally and invite follow-up questions
- Complete when answer is delivered

### Task Mode
**When:** User requests work to be done

**Approach:**
- Briefly restate the request for non-trivial tasks
- Execute the task using available tools
- Be transparent about progress and errors
- Validate outputs before declaring completion
- Summarize what was accomplished

## Communication Style

**Be conversational and friendly.**

**Research:**
- Use web_operations to find current, accurate information
- Always provide source links for factual claims
- Cross-reference with multiple sources when important

**Tool usage:**
- Use tools naturally - describe your actions in plain language; match parameter NAMES to the schema verbatim (e.g. `command`, not `cmd`)
- "Let me look that up..." or "I'll search for that..."
- Validate results before presenting them

**Error handling:**
- Be honest when you can't find something
- Try alternative approaches
- Ask clarifying questions when needed

## Safety & Privacy

- Execute file operations only within the user's project directory
- Respect sandbox restrictions
- Do not execute destructive operations without confirmation
- Handle sensitive information carefully

## Memory & Context

You have access to memory_operations for storing and retrieving information:
- Store important facts for future reference
- Search memory for previous discussions
- Use context to personalize interactions

**Long-term Memory:** If LTM patterns are provided, use them to inform your responses.

## Completion Signal

When you have completed a response:

- Provide a brief summary if the topic was complex
- Invite follow-up: "Is there anything else I can help with?"
- Remain ready for new questions
END_CHAT_PROMPT
}

=head2 _get_default_prompt_content

Get the default CLIO system prompt (merged from VSCode + current).

Returns: Default prompt content

=cut

sub _get_default_prompt_content {
    my ($self) = @_;
    
    # Check if subagent features are enabled (from config via PromptBuilder)
    my $enable_subagents = $self->{enable_subagents};
    
    my $agent_name = $ENV{CLIO_AGENT_NAME} || 'CLIO';
    my $agent_subtitle = $ENV{CLIO_AGENT_SUBTITLE} || 'Command Line Intelligence Orchestrator';
    
    # Load prompt from template file
    my $template_file = File::Spec->catfile($self->{prompts_dir}, 'templates', 'default.md');
    $template_file = undef unless -f $template_file;
    
    # Fall back to embedded template in lib/CLIO/Core/prompts/default.md
    unless ($template_file) {
        # Try relative to the module file (for dev/install)
        my $module_dir = dirname(__FILE__);
        my $candidate = File::Spec->catfile($module_dir, 'prompts', 'default.md');
        $template_file = $candidate if -f $candidate;
    }
    
    # Ultimate fallback: try the prompts_dir/templates path with find_clio_dir
    unless ($template_file) {
        require CLIO::Util::PathResolver;
        my $clio_dir = CLIO::Util::PathResolver::find_clio_dir(Cwd::getcwd());
        my $candidate = File::Spec->catfile($clio_dir, 'lib', 'CLIO', 'Core', 'prompts', 'default.md');
        $template_file = $candidate if -f $candidate;
    }
    
    my $prompt;
    if ($template_file) {
        log_debug('PromptManager', "Loading system prompt from template: $template_file");
        open my $tfh, '<:encoding(UTF-8)', $template_file or do {
            log_error('PromptManager', "Cannot read template $template_file: $!");
            # Fall through to error below
        };
        if ($tfh) {
            $prompt = do { local $/; <$tfh> };
            close $tfh;
        }
    }
    
    unless ($prompt) {
        croak "Cannot load system prompt template from any location. " .
              "Expected at: lib/CLIO/Core/prompts/default.md";
    }
    
    # Substitute agent name and subtitle
    $prompt =~ s/__AGENT_NAME__/$agent_name/g;
    $prompt =~ s/__SUBTITLE__/$agent_subtitle/g;
    
    # Handle conditional sub-agent sections
    if ($enable_subagents) {
        # Replace <!--__SA_START__-->...<!--__SA_END__--> markers with inner content
        $prompt =~ s/<!--__SA_START__-->(.*?)<!--__SA_END__-->/$1/gms;
        
        # Build the multi-agent section content
        my $is_subagent = $ENV{IS_SUBAGENT} || 0;
        my $is_puppeteer = $ENV{CLIO_PUPPETEER} || 0;
        my $puppeteer_project = $ENV{CLIO_PUPPETEER_PROJECT} || '';
        
        my $multi_agent_section = $is_subagent
            ? $self->_get_subagent_instructions()
            : $self->_get_manager_instructions();
        
        if ($is_puppeteer && $puppeteer_project) {
            $multi_agent_section .= $self->_get_puppeteer_child_instructions($puppeteer_project);
        }
        
        # Replace multi-agent placeholder with content + separator
        $prompt =~ s/<!--__MULTI__-->/${multi_agent_section}\n---\n\n/g;
    } else {
        # Remove conditional sub-agent sections (markers + content between them)
        $prompt =~ s/<!--__SA_START__-->.*?<!--__SA_END__-->//gs;
        
        # Remove multi-agent placeholder
        $prompt =~ s/<!--__MULTI__-->//g;
    }
    
    # Strip any remaining template markers (defensive)
    $prompt =~ s/<!--__\w+__-->\s*//g;
    
    # Ensure file ends with newline
    $prompt .= "\n" unless $prompt =~ /\n$/;
    
    return $prompt;
}

=head2 _format_ltm_patterns

Format LTM (Long-Term Memory) patterns for injection into system prompt.
Uses token-budgeted rendering to keep the LTM section within bounds.
Entries are scored by confidence, recency, type, and usage - only the
highest-scoring entries that fit within the budget are included.
A compact index footer shows what additional memories are available.

Arguments:
- $session: Session object containing LTM

Returns: Formatted LTM section or empty string if no patterns

=cut

sub _format_ltm_patterns {
    my ($self, $session) = @_;
    
    return '' unless $session;
    
    # Get LTM from session
    my $ltm = $session->can('ltm') ? $session->ltm() : undef;
    return '' unless $ltm;
    
    # LTM consolidation (decay, age-out, dedup) is rate-gated inside
    # LongTerm::maybe_consolidate (24h min since last, 20+ entries).
    # This is a data-layer maintenance task, not a formatting concern.
    $ltm->maybe_consolidate_and_save();
    
    # Use budgeted rendering (~3000 tokens / ~12000 chars)
    my ($section, $included, $total) = $ltm->render_budgeted_section(max_chars => 12000);
    
    return '' unless $included > 0;
    
    log_debug('PromptManager', "LTM budgeted render: $included of $total entries, " . length($section) . " chars");
    
    # No recovery guidance line. Telling the model "after context
    # trimming, do X" is a context distraction - it primes the model
    # to second-guess its own state. LTM content speaks for itself;
    # the model can use memory_operations whenever it actually needs
    # to recall or store information, no priming required.
    
    return "\n" . $section;
}

1;
