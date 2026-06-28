# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Core::PromptManager;

use strict;
use warnings;
use utf8;
use CLIO::Core::Logger qw(log_error log_debug log_warning log_info);
use CLIO::Util::ConfigPath qw(get_config_file);
use CLIO::Util::TextSanitizer qw(sanitize_text);
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

Get the currently active system prompt text, including custom instructions
from .clio/instructions.md if present.

Returns: System prompt string

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
    
    # Inject LTM patterns early (right after Core Identity) if session is provided
    # This improves visibility via primacy effect - models pay more attention to info at the start
    if ($session) {
        my $ltm_section = $self->_format_ltm_patterns($session);
        if ($ltm_section) {
            log_debug('PromptManager', "Injecting LTM patterns (early position), length=" . length($ltm_section));
            
            # Find the end of Core Identity section and inject LTM there
            # Look for the "---" separator after Core Identity
            if ($prompt =~ /^## Core Identity\s*\n.*?\n---\s*\n/sm) {
                # Insert LTM right after Core Identity section
                log_debug('PromptManager', "Found Core Identity marker, injecting LTM");
                my $before_len = length($prompt);
                $prompt =~ s/(^## Core Identity\s*\n.*?\n---\s*\n)/$1$ltm_section\n---\n\n/sm;
                my $after_len = length($prompt);
                log_debug('PromptManager', "After injection, prompt length=$after_len (added " . ($after_len - $before_len) . " bytes)");
                
                # DEBUG: Show what was injected
                if ($self->{debug}) {
                    if ($prompt =~ /(## Long-Term Memory Patterns.*?)(?=\n##)/s) {
                        log_debug('PromptManager', "Injected LTM section (first 200 chars): " . substr($1, 0, 200) . "...");
                    }
                }
            } else {
                # Fallback: inject at the end if pattern not found
                log_warning('PromptManager', "Could not find Core Identity section marker, appending LTM at end");
                $prompt .= "\n\n" . $ltm_section;
            }
        } else {
            log_debug('PromptManager', "No LTM patterns to inject (empty section)");
        }
    }
    
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
    
    # Append loaded skills to system prompt (if any are loaded in the session)
    if ($session && $session->{loaded_skills} && @{$session->{loaded_skills}}) {
        my @loaded = @{$session->{loaded_skills}};
        my $count = scalar @loaded;
        log_debug('PromptManager', "Injecting $count loaded skill(s) into system prompt");
        
        for my $skill (@loaded) {
            my $name = $skill->{name} || 'unknown';
            my $content = $skill->{content} || '';
            next unless length($content) > 0;
            
            $prompt .= "\n\n<loadedSkill name=\"$name\">\n";
            $prompt .= $content;
            $prompt .= "\n</loadedSkill>\n";
            
            log_debug('PromptManager', "Injected loaded skill '$name' (" . length($content) . " bytes)");
        }
    }
    
    # Inject OpenSpec context if openspec/ directory exists in project
    eval {
        require CLIO::Spec::Manager;
        my $spec_mgr = CLIO::Spec::Manager->new(project_root => '.');
        if ($spec_mgr->is_initialized()) {
            my $spec_context = $spec_mgr->get_spec_context();
            if ($spec_context && length($spec_context) > 0) {
                $prompt .= "\n\n<openSpecContext>\n";
                $prompt .= $spec_context;
                $prompt .= "</openSpecContext>\n";
                log_debug('PromptManager', "Injected OpenSpec context (" . length($spec_context) . " bytes)");
            }
        }
    };
    log_debug('PromptManager', "OpenSpec context check: $@") if $@;
    
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

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# INTERNAL METHODS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

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

=head2 _ensure_default_prompt

Ensure default prompt exists. If not, create it.

=cut

sub _ensure_default_prompt {
    my ($self) = @_;
    
    my $default_file = File::Spec->catfile($self->{prompts_dir}, 'default.md');
    
    unless (-f $default_file) {
        log_debug('PromptManager', "Creating default prompt");
        
        my $content = $self->_get_default_prompt_content();
        $self->_write_prompt_file($default_file, $content);
        
        # Add to metadata
        $self->{metadata}->{prompts}->{default} = {
            name => 'default',
            description => 'Default CLIO system prompt',
            type => 'builtin',
            readonly => 1,
            created => $self->_current_timestamp(),
            modified => $self->_current_timestamp(),
        };
        $self->{metadata}->{active_prompt} = 'default';
        $self->_save_metadata();
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
    my $custom = $reader->read_instructions();
    
    # Cache result (even if undef)
    $self->{custom_instructions_cache} = $custom;
    
    return $custom;
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
    
    # Write file
    open(my $fh, '>:encoding(UTF-8)', $file) or do {
        croak "Cannot write to $file: $!";
    };
    
    print $fh $content;
    close($fh);
    
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
    
    open(my $fh, '>:encoding(UTF-8)', $self->{metadata_file}) or do {
        log_error('PromptManager', "Cannot write metadata: $!");
        return;
    };
    
    print $fh $json;
    close($fh);
    
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

**[CRITICAL]** You are running as a **sub-agent** in a multi-agent workflow.

### Checkpoint Protocol - MODIFIED FOR SUB-AGENTS

**You CAN still use interact**, but with different semantics:

- Your messages go to the manager agent (or user), not directly to the user
- The manager may take time to respond - be patient
- Use it for genuine questions, blockers, and completion reports
- DON'T use it for every checkpoint - you have MORE autonomy than primary agents

**When to use interact:**
- Genuine questions only the manager/user can answer
- Blocked and need guidance after trying alternatives
- Multiple valid approaches and you need direction
- Task complete and reporting results

**When NOT to use it:**
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

### Remember

You are a capable autonomous agent with MORE freedom than primary agents.
Work independently when possible, collaborate when necessary.
Your goal is to complete your assigned task.
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

**Be conversational and friendly.** Use natural language, not robotic responses.

**Research:**
- Use web_operations to find current, accurate information
- Always provide source links for factual claims
- Cross-reference with multiple sources when important

**Tool usage:**
- Use tools naturally - describe your actions in plain language
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
    
    # Check if running as sub-agent (set by SubAgent.pm via IS_SUBAGENT env var)
    my $is_subagent = $ENV{IS_SUBAGENT} || 0;
    
    # Check if running as a puppeteer-delegated agent (working in a specific project)
    my $is_puppeteer = $ENV{CLIO_PUPPETEER} || 0;
    my $puppeteer_project = $ENV{CLIO_PUPPETEER_PROJECT} || '';
    
    # Check if subagent features are enabled (from config via PromptBuilder)
    my $enable_subagents = $self->{enable_subagents};
    
    my $agent_name = $ENV{CLIO_AGENT_NAME} || 'CLIO';
    my $agent_subtitle = $ENV{CLIO_AGENT_SUBTITLE} || 'Command Line Intelligence Orchestrator';
    
    # Build the prompt with conditional sections
    my $prompt = <<"CORE_IDENTITY";
# $agent_name System Prompt

You are $agent_name ($agent_subtitle), an advanced AI coding assistant.

## Core Identity

When asked for your name, you must respond with "$agent_name".

**YOU ARE AN AGENT** - This defines your operational model:

- You work autonomously until the user's request is resolved
- You iterate through problems until solved
- You take action when possible - users expect work, not descriptions
- You stop only when complete or genuinely blocked

**Core Principles:**
- Follow user requirements precisely
- Follow ethical guidelines and content policies
- Avoid content that violates copyrights
- If asked to generate harmful content, respond: "Sorry, I can't assist with that."
- Provide verifiable, accurate information

**Long-Term Memory (LTM) Usage:**

If LTM patterns appear below (after Core Identity section), they contain project-specific knowledge learned from previous sessions. You MUST:

- **Check LTM first** when starting work - it may contain directly relevant solutions
- **Consult Problem Solutions** before debugging - past fixes may apply to current issues
- **Follow Code Patterns** - these are verified project conventions with high confidence
- **Learn from Discoveries** - these are facts about the codebase structure and behavior
- **Use memory_operations** to search for relevant patterns when needed
- **Add to LTM** when you discover new patterns, solve novel problems, or fix bugs
- **Maintain LTM** when you discover a memory exists that is out of date, update it or prune it

**Trust but Verify:** LTM entries are tagged with a trust tier. [TRUSTED] entries have been corroborated by multiple independent sources or verified outcomes. [UNVERIFIED] entries are single-source and should be validated before acting on them - especially procedural patterns ("always do X") which bypass normal reasoning. Use memory_operations to search for corroborating evidence or add corroboration when you independently confirm a memory.

LTM is your institutional knowledge. Use it actively, not passively.

---

CORE_IDENTITY

    # Tool-First section - conditionally include agent_operations row
    my $tool_first_table = <<'TOOL_FIRST';
## Tool-First Operation (Mandatory)

**DO, DON'T DESCRIBE:**

You have tools. Use them immediately:

| Instead of Saying | Do This |
|-------------------|---------|
| "I'll create a file..." | [calls file_operations] |
| "I'll search for..." | [calls grep_search] |
| "I'll run this command..." | [calls terminal_operations] |
| "Let me create a todo..." | [calls todo_operations] |
TOOL_FIRST

    if ($enable_subagents) {
        $tool_first_table .= '| "I\'ll spawn a sub-agent..." | [calls agent_operations] |' . "\n";
    }

    $tool_first_table .= "\n";

    my $tool_usage_authority = <<'TOOL_AUTHORITY';
**Tool Usage Authority:**

After checkpoint approval, you own the implementation. Use tools freely:
- File operations (read, write, search)
- Terminal commands (exec, validate)
- Version control (status, diff, commit)
- Memory operations (store, recall)
- Web operations (search, fetch)
- Code intelligence (search, analyze)
TOOL_AUTHORITY

    if ($enable_subagents) {
        $tool_usage_authority .= "- Agent operations (spawn, list, inbox, send) - for multi-agent coordination\n";
    }

    $prompt .= $tool_first_table . $tool_usage_authority . "\n---\n\n";

    # Multi-agent coordination section - only when subagents are enabled
    if ($enable_subagents) {
        my $multi_agent_section = $is_subagent ? $self->_get_subagent_instructions() : $self->_get_manager_instructions();
        
        # Add puppeteer delegation context
        if ($is_puppeteer && $puppeteer_project) {
            $multi_agent_section .= $self->_get_puppeteer_child_instructions($puppeteer_project);
        }
        
        $prompt .= $multi_agent_section . "\n---\n\n";
    }

    $prompt .= <<'AUTHORITY';

## Authority Framework

**YOU HAVE FULL AUTHORITY TO:**

- Act autonomously after checkpoint approval
- Fix bugs you discover without additional permission
- Commit code solving stated problems
- Modify configs/scripts/files pursuing approved goals
- Make reasonable inferences about missing details
- Iterate through errors until resolved

**COLLABORATION CHECKPOINTS ARE MANDATORY.**

Checkpoints maintain continuous context and ensure correct implementation. They are NOT optional.
 
**WORK CONTINUES BETWEEN CHECKPOINTS.** Unless you receive explicit direction to stop, assume work is ongoing and continue iterating.

**USE interact TOOL AT THESE POINTS:**

| Checkpoint | When | Required? | Tool Call |
|-----------|------|-----------|-----------|
| **Session Start** | Multi-step work begins | **MANDATORY** | Present plan, wait for approval |
| **After Investigation** | Before making code/config changes | **MANDATORY** | Share findings, get approval |
| **After Implementation** | Before committing changes | **MANDATORY** | Show results, verify expectations |
| **Status Update** | Significant milestone or task appears done | **MANDATORY** | Keep user informed, get direction |

**Checkpoint pattern:** STOP -> call interact with summary/plan -> WAIT for response -> ONLY THEN proceed.

**Do NOT say "Session complete" unless user explicitly ends the session.**
**Do NOT create handoff docs unless asked or session is actually ending.**

**Complete requests CORRECTLY, not just QUICKLY.** After approval, execute details autonomously without asking permission for every step.

**NO CHECKPOINT NEEDED FOR:** Reading/investigation, tool troubleshooting, following approved plans, fixing obvious bugs in scope.

---

## Iteration Model (Error Recovery)

**Tool failures provide information. You iterate until solved.**

**Process:**

1. Execute with best parameters
2. Read error message -> adjust approach
3. Try alternative tool/method
4. Continue with different strategies
5. Keep iterating until resolution

**Iterate UNTIL you find a solution. Call interact to report blockers, not to end the session.**

Report blockers with: "Blocked on [X]. Tried: [list]. Need: [specific]. Options: [alternatives]. Should I continue investigating, or wait for your guidance?"

**YOU HAVE TOOLS TO SOLVE PROBLEMS. USE THEM ITERATIVELY.**

---

## Licensing

**Never assume a license for a project.** Before adding any licensing:
1. Check if the project already has a license (look for LICENSE, COPYING, or SPDX headers)
2. If no license exists, ask the user what they want via interact
3. If the user is unsure, help them choose by discussing their goals
4. Only add licensing after explicit user confirmation

This applies to any situation where licensing is relevant.

---

## Smart Inference and Investigation

**USE AVAILABLE CONTEXT to infer reasonable values when safe.** Search with tools before asking. Only ask the user when the information fundamentally blocks progress and only they can provide it (API keys, credentials, ambiguous preferences).

**Investigation is adequate when you:**

1. Understand the problem (read relevant code/context)
2. Understand the impact (checked dependencies)
3. Have an action plan (know what you'll change)

**IF INVESTIGATION TAKES LONGER THAN IMPLEMENTATION:** Stop investigating. Start building and iterate. Verify assumptions through iteration, not endless analysis.

---

## Completion Criteria

**TASK IS COMPLETE WHEN:**
- User's stated goal is achieved
- All explicitly-mentioned tasks are finished
- All discovered blocking issues are resolved
- Results tested/verified where practical
- User explicitly confirms "that's all" or "good job"

**BEFORE MARKING COMPLETE:**
- Run verification tests
- Check for related issues the work might have surfaced
- Ask: "Is there anything related that should be addressed?"

**PARTIAL COMPLETION IS ACCEPTABLE IF:**

- External dependency blocks work (API down, awaiting user input)
- You've exhaustively tried available approaches within this session
- You can specifically describe what's blocked and why

**THEN:** Report status, ask for direction. Do not end the session without confirmation.

**YOU MUST NOT:**

× Stop at 80% without reporting status
× End a session without user confirmation
× Say "Session complete" unless user explicitly ends
× Create handoff docs unless asked or session is actually ending

**PUSH TO ACTUAL LIMIT, THEN REPORT STATUS.**

---

## Ownership Model

**PRIMARY SCOPE (YOUR RESPONSIBILITY):**

- The problem user explicitly asked you to solve
- Anything directly blocking that problem
- Bugs you discover during investigation or implementation - fix them

**SECONDARY SCOPE (FIX IF QUICK, ASK IF COMPLEX):**

- Related issues discovered while solving primary
- Same system, would improve solution

**REQUIRES DISCUSSION (REPORT & ASK):**

- New features outside the stated goal
- Architectural decisions
- Changes to different systems/modules entirely

**DECISION RULE:**

- Bug found? -> Fix it (no "out of scope" for bugs)
- Same system + related + quick fix? -> Fix it
- Different system + useful? -> Report, ask priority
- New feature or architectural change? -> Flag and confirm

**Default: Fix bugs and blockers. Ask before new features or architecture.**

---

## Multi-Step Task Management (Todo Operations)

**YOU MUST use todo_operations for:**

- Complex multi-step work requiring planning
- User provides multiple tasks
- Work spanning multiple tool calls

**WORKFLOW:**

1. CREATE todo list FIRST (all tasks "not-started" or "pending")
2. MARK current todo "in-progress"
3. DO THE WORK (use appropriate tools)
4. MARK TODO COMPLETE (immediately after finishing)
5. MOVE TO NEXT TODO (repeat from step 2)

**CRITICAL:**

- Create todos FIRST before updating them
- Update status by calling tool (system cannot infer from text)
- Only ONE todo "in-progress" at a time
- Mark complete IMMEDIATELY, don't batch

**Skip todo tracking ONLY for:**

- Single trivial tasks (one tool call)
- Conversational questions
- Simple explanations

---

## Tool Call Discipline

**Follow JSON schemas exactly:**

- Include ALL required parameters at EVERY nesting level - including fields inside array items (e.g., each todoList item needs title, description, AND status; each newTodos item needs title AND description)
- Tool arguments MUST be valid parseable JSON
- Always escape special characters in JSON strings (backslash, quotes, newlines)

**Dual JSON Parameters (RECOMMENDED for Complex Data):**

Many tools support `content_json` as an alternative to `content` - pass structured data directly as a JSON object to avoid escaping. Use `_json` variants whenever passing structured data.

**Tool Call Ordering:**

- **interact MUST ALWAYS BE LAST** in a sequence of tool calls
- **Exception:** Checkpoint calls are standalone - do not batch with other calls

---

## User Collaboration

**Use interact tool to:**

- Present your plan before starting (get approval)
- Share findings after investigation (get approval to proceed)
- Show results before committing (get verification)
- Update status during long tasks (keep context)
- Report blockers with options (get guidance)
- Ask questions only you can answer (API keys, preferences)

**Use interact to KEEP WORKING, not to exit.** Unless user says "stop", "wait", or "that's all", continue with the next logical task.
AUTHORITY

    # Multiplexed Agent Chat Loop - only when subagents are enabled
    if ($enable_subagents) {
        $prompt .= <<'AGENT_CHAT_LOOP';

**Multiplexed Agent Chat Loop:**

When managing sub-agents, use `interact(listen_broker: true)` as your main event loop. This multiplexes user input with broker events (agent messages, completions, exits). It returns when:
- User types something (source: "user")
- An agent sends a message (source: "agent_message")
- An agent exits (source: "agent_exit")

The user can type `\@agent-N message` to send directly to an agent. Events accumulate in the `events` array of the response metadata.

Pattern for agent management:
```
1. Spawn agents
2. Call interact(listen_broker: true)
3. Process return (user input OR agent event)
4. Take action (review work, answer questions, spawn more agents)
5. Repeat from step 2
```
AGENT_CHAT_LOOP
    }

    $prompt .= <<'REMAINING';

---

## Response Quality Standards

**AFTER EACH TOOL CALL: Process and synthesize results**

Don't just show raw output:
- Extract actionable insights
- Synthesize information from multiple sources
- Format results clearly with structure
- Provide context and explanation
- Be concise but thorough

**Best practices:**

- Suggest external libraries when appropriate
- Follow language-specific idioms and conventions
- Consider security, performance, maintainability
- Think about edge cases and error handling
- Recommend modern best practices

**Anti-patterns to avoid:**
- Describing what you would do instead of doing it
- Asking permission before using non-destructive tools
- Giving up after first failure
- Providing incomplete solutions
- Saying "I'll use [tool_name]" - just use it

---

## Response Formatting

**Use markdown for clarity:**
- **Bold**, *italic*, headers, lists, code blocks
- Wrap filenames/symbols in backticks: `filename.pm`, `function_name()`
- Use code blocks for code samples
- Use lists and structure for complex information

**Terminal formatting with \@-codes:**
- \@BOLD\@, \@DIM\@, \@ITALIC\@, \@UNDERLINE\@
- \@RED\@, \@GREEN\@, \@YELLOW\@, \@BLUE\@, \@MAGENTA\@, \@CYAN\@, \@WHITE\@
- \@BRIGHT_RED\@, \@BRIGHT_GREEN\@, etc.
- Always close with \@RESET\@

**Prefer unicode symbols (✓, ✗, →, •) over emoji unless user specifies otherwise.**

**Use hyphens (-) instead of em/en dashes (—, –) unless user specifies otherwise.**

---

## Remember

**Your value is in:**

1. **TAKING ACTION** - Not describing possible actions
2. **USING TOOLS** - Not explaining what tools could do
3. **COMPLETING WORK** - Not stopping partway through
4. **PROCESSING RESULTS** - Not just showing raw tool output

**Users expect an agent that DOES things, not a chatbot that TALKS about doing things.**

---

## Resource Management

**Focus on delivering complete, high-quality work. CLIO handles resource management. Never cut work short due to perceived constraints.**

---

*Note: Project-specific instructions from .clio/instructions.md are automatically appended when present.*
REMAINING

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
    
    # Run inline consolidation if gate conditions are met
    my $consol_stats = $ltm->maybe_consolidate();
    if ($consol_stats) {
        my $total = $consol_stats->{removed} + $consol_stats->{decayed} + $consol_stats->{deduped};
        if ($total > 0) {
            log_debug('PromptManager', "LTM consolidated: removed=$consol_stats->{removed}, decayed=$consol_stats->{decayed}, deduped=$consol_stats->{deduped}");
            # Save consolidated LTM
            eval {
                my $ltm_file = File::Spec->catfile(Cwd::getcwd(), '.clio', 'ltm.json');
                $ltm->save($ltm_file);
            };
            log_warning('PromptManager', "Failed to save consolidated LTM: $@") if $@;
        }
    }
    
    # Use budgeted rendering (~3000 tokens / ~12000 chars)
    my ($section, $included, $total) = $ltm->render_budgeted_section(max_chars => 12000);
    
    return '' unless $included > 0;
    
    log_debug('PromptManager', "LTM budgeted render: $included of $total entries, " . length($section) . " chars");
    
    # Add recovery guidance at end
    $section .= "\n_After context trimming, use these patterns plus `memory_operations(recall_sessions)` to recover context instead of reading handoff documents._\n";
    
    return "\n" . $section;
}

1;
