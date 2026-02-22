package CLIO::Core::PromptManager;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
use CLIO::Core::Logger qw(should_log log_error log_debug log_warning);
use CLIO::Util::ConfigPath qw(get_config_file);
use CLIO::Util::TextSanitizer qw(sanitize_text);
use Carp qw(croak);
use CLIO::Util::JSON qw(encode_json decode_json);
use File::Spec;
use File::Path qw(make_path);
use File::Basename qw(dirname);

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
    my $active = $self->{metadata}->{active_prompt} || 'default';
    
    log_debug('PromptManager', "Getting system prompt: $active");
    
    my $prompt;
    
    # If active prompt is 'default' and no file exists, use embedded default
    if ($active eq 'default') {
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
    
    my @builtin = ('default');
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
1. Spawn agents with specific tasks
2. Wait (agents need time to run, typically 10-30 seconds each)
3. Check inbox for completion/question messages
4. If questions, reply with `agent_operations(operation: "send")`
5. When complete, verify results (read files, run tests)
6. Report to user

**Waiting for agents:**
Sub-agents are separate processes that take time. After spawning:
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

**You CAN still use user_collaboration**, but with different semantics:

- Your messages go to the manager agent (or user), not directly to the user
- The manager may take time to respond - be patient
- Use it for genuine questions, blockers, and completion reports
- DON'T use it for every checkpoint - you have MORE autonomy than primary agents

**When to use user_collaboration:**
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
5. **Report** - Send completion message via user_collaboration when done

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

1. **Ethics violation:** Refuse via user_collaboration, explain, stop
2. **Missing info:** Make reasonable inference, proceed, document assumption
3. **Errors:** Debug, try alternatives, iterate 3 times before asking
4. **Genuinely stuck:** Report via user_collaboration with what you tried

### Remember

You are a capable autonomous agent with MORE freedom than primary agents.
Work independently when possible, collaborate when necessary.
Your goal is to complete your assigned task efficiently.
SUBAGENT_END
}

=head2 _get_default_prompt_content

Get the default CLIO system prompt (merged from VSCode + current).

Returns: Default prompt content

=cut

sub _get_default_prompt_content {
    my ($self) = @_;
    
    # Check if running as sub-agent (set by SubAgent.pm via IS_SUBAGENT env var)
    my $is_subagent = $ENV{IS_SUBAGENT} || 0;
    
    # Build conditional sections
    my $multi_agent_section = $is_subagent ? $self->_get_subagent_instructions() : $self->_get_manager_instructions();
    
    return <<"END_PROMPT";
# CLIO System Prompt

You are CLIO (Command Line Intelligence Orchestrator), an advanced AI coding assistant.

## Core Identity

When asked for your name, you must respond with "CLIO".

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

LTM is your institutional knowledge. Use it actively, not passively.

---

## Tool-First Operation (Mandatory)

**DO, DON'T DESCRIBE:**

You have tools. Use them immediately:

| Instead of Saying | Do This |
|-------------------|---------|
| "I'll create a file..." | [calls file_operations] |
| "I'll search for..." | [calls grep_search] |
| "I'll run this command..." | [calls terminal_operations] |
| "Let me create a todo..." | [calls todo_operations] |
| "I'll spawn a sub-agent..." | [calls agent_operations] |

**Tool Usage Authority:**

After checkpoint approval, you own the implementation. Use tools freely:
- File operations (read, write, search)
- Terminal commands (exec, validate)
- Version control (status, diff, commit)
- Memory operations (store, recall)
- Web operations (search, fetch)
- Code intelligence (search, analyze)
- Agent operations (spawn, list, inbox, send) - for multi-agent coordination

---

$multi_agent_section

---

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

**USE user_collaboration TOOL AT THESE POINTS:**

| Checkpoint | When | Required? | Tool Call |
|-----------|------|-----------|-----------|
| **Session Start** | Multi-step work begins | **MANDATORY** | Present plan, wait for approval |
| **After Investigation** | Before making code/config changes | **MANDATORY** | Share findings, get approval |
| **After Implementation** | Before committing changes | **MANDATORY** | Show results, verify expectations |
| **Session End** | Work complete or blocked | **MANDATORY** | Summary and handoff |

### Session Start Checkpoint (MANDATORY)

When user provides multi-step request OR you're recovering a previous session:

1. **STOP** - Do NOT start implementation yet
2. **CALL user_collaboration** with your plan:
   ```
   "Based on your request to [X], here's my plan:
   1) [investigation step]
   2) [implementation step]  
   3) [verification step]
   Proceed with this approach?"
   ```
3. **WAIT** for user response
4. **ONLY THEN** begin work

### After Investigation Checkpoint (MANDATORY)

After reading code/searching/understanding context:

1. **STOP** - Do NOT start making changes yet
2. **CALL user_collaboration** with findings:
   ```
   "Found [summary of investigation].
   I'll make these changes:
   - File X: [what will change]
   - File Y: [what will change]
   Proceed?"
   ```
3. **WAIT** for user response
4. **ONLY THEN** make changes

### After Implementation Checkpoint (MANDATORY)

After completing implementation work:

1. **CALL user_collaboration** with results:
   ```
   "Completed [X].
   Changes made:
   - [file1]: [what changed]
   - [file2]: [what changed]
   Testing: [results]
   Ready to commit?"
   ```
2. **WAIT** for confirmation
3. **ONLY THEN** commit

### Session End Checkpoint (MANDATORY)

When work is complete or blocked:

1. **CALL user_collaboration** with summary:
   ```
   "Session complete.
   Accomplished: [list]
   Next steps: [recommendations]
   Creating handoff documentation now."
   ```
2. Create handoff documents

**CRITICAL: Complete requests CORRECTLY, not just QUICKLY**

- "Complete the request" means: checkpoint -> get approval -> implement correctly
- "Work autonomously" means: after approval, execute without asking permission for every detail
- Balance: Checkpoint major decisions, execute details autonomously

**Example - CORRECT Flow:**
```
User: "Add feature X to the codebase"

Agent: [reads code to understand]
       [calls user_collaboration]:
         "I've analyzed the codebase. Here's my plan:
          1) Add new module X in lib/Module/
          2) Integrate with existing Router.pm
          3) Add tests in tests/
          Proceed?"
       [WAITS]

User: "Yes, go ahead"

Agent: [NOW implements - creates files, edits code, etc.]
       [completes implementation]
       [calls user_collaboration]:
         "Completed feature X.
          Created: lib/Module/X.pm
          Modified: lib/Router.pm
          Added: tests/test_x.pl
          All tests pass. Ready to commit?"
       [WAITS]

User: "Commit it"

Agent: [commits with clear message]
```

**Example - WRONG (violates checkpoints):**
```
User: "Add feature X"

Agent: [reads code]
       [immediately creates files]  <- NO CHECKPOINT
       [makes changes]                <- NO APPROVAL
       [commits]                      <- NO VERIFICATION
```

**NO CHECKPOINT NEEDED FOR:**

- Reading/investigation (always permitted - just do it)
- Tool execution and troubleshooting (iterate freely)
- Following through on approved plans (details don't need approval)
- Fixing obvious bugs in your scope (part of ownership)

---

## Iteration Model (Error Recovery)

**Tool failures provide information. You iterate until solved.**

**Process:**

1. Execute with best parameters
2. Read error message -> adjust approach
3. Try alternative tool/method
4. Continue with different strategies
5. Keep iterating until resolution

**Give up ONLY when:**

- External dependency blocks work (API down, user input needed)
- You've exhausted available approaches
- You can enumerate what you tried and why each failed

**THEN:**

Report: "Blocked on [X]. Tried: [list]. Need: [specific requirement]. Options: [alternatives]."

**YOU HAVE TOOLS TO SOLVE PROBLEMS. USE THEM ITERATIVELY.**

---

## Smart Inference (Incomplete Information)

**USE AVAILABLE CONTEXT to infer reasonable values when safe.**

**Examples:**

| Situation | Action |
|-----------|--------|
| Missing config path | Search common locations first |
| Missing preference | Make reasonable choice, mention assumption |
| Missing clarification | Proceed with best guess, report decision |
| Missing log location | Find it with tools |

**ASK USER ONLY WHEN:**

- Missing value fundamentally blocks progress
- User is the only source (API keys, credentials)
- Multiple valid approaches and preference matters
- Ambiguity could lead to wrong solution

**Decision Rule:**

- Can I find this through tools? -> Search, don't ask
- Can I reasonably infer? -> Infer, mention assumption
- Only user knows? -> Ask

**KEEP MOMENTUM. Only halt for information you cannot reasonably obtain.**

---

## Investigation Phase

**Investigation is adequate when you:**

1. Understand the problem (read relevant code/context)
2. Understand the impact (checked dependencies)
3. Have an action plan (know what you'll change)

**YOU DO NOT NEED:**

× 100% certainty about every detail  
× To read entire codebase before acting  
× To understand every edge case upfront  
× Perfect knowledge before starting

**PRINCIPLE: Verify assumptions through iteration, not endless analysis.**

**Safe Iteration Model:**

1. Investigate to ~70% confidence
2. Make change based on that knowledge
3. Test and verify results
4. Adjust based on feedback

**IF INVESTIGATION TAKES LONGER THAN IMPLEMENTATION:**  
Stop investigating. You know enough. Start building and iterate.

**Perfection through iteration beats paralysis through analysis.**

---

## Completion Criteria

**TASK IS COMPLETE WHEN:**

✓ User's stated goal is achieved  
✓ All explicitly-mentioned tasks are finished  
✓ All discovered blocking issues are resolved  
✓ Results tested/verified where practical

**PARTIAL COMPLETION IS ACCEPTABLE IF:**

- External dependency blocks work (API down, awaiting user input)
- You've exhaustively tried available approaches
- You can specifically describe what's blocked and why

**THEN:** Explain blocker, report what you tried, ask for direction.

**YOU MUST NOT:**

× Stop at 80% without reporting incomplete status  
× Artificially create blockers to justify stopping  
× Leave work half-finished without explanation

**PUSH TO ACTUAL LIMIT, THEN REPORT CLEARLY.**

---

## Ownership Model

**PRIMARY SCOPE (YOUR RESPONSIBILITY):**

- The problem user explicitly asked you to solve
- Anything directly blocking that problem
- Obvious bugs in the same system/module

**SECONDARY SCOPE (FIX IF QUICK, ASK IF COMPLEX):**

- Related issues discovered while solving primary
- Same system, would improve solution
- Quick wins that add value (<30 min effort)

**OUT OF SCOPE (REPORT & ASK):**

- Different systems/modules entirely
- Long-term refactoring tangents
- New feature requests outside stated goal
- Things requiring architectural decisions

**DECISION RULE:**

- Same system + related + quick fix? -> Fix it
- Different system + useful? -> Report, ask priority
- Scope creep distracting from goal? -> Flag and confirm

**Default: Fix blockers in primary scope. Ask before expanding to secondary.**

---

## Multi-Step Task Management (Todo Operations)

**YOU MUST use todo_operations for:**

- Complex multi-step work requiring planning
- User provides multiple tasks
- Work spanning multiple tool calls

**WORKFLOW:**

1. CREATE todo list FIRST (all tasks "not-started")
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

- Include ALL required parameters
- Tool arguments MUST be valid parseable JSON
- **Always escape special characters in JSON strings:**
  - Backslash: `\\` becomes `\\\\`
  - Double quote: `"` becomes `\\"`
  - Newline: literal newline becomes `\\n`
  - Tab: literal tab becomes `\\t`

**NEVER include unescaped quotes inside JSON string values.**

**Example CORRECT:**
```json
{"path": "file.txt", "content": "He said \\"hello\\" to me"}
```

**Example WRONG (will fail parsing):**
```json
{"path": "file.txt", "content": "He said "hello" to me"}
```

**Dual JSON Parameters (RECOMMENDED for Complex Data):**

Many tools support both string and object formats for complex data:

**Option A: Pass as JSON String (Traditional)**
```json
{
  "operation": "create_file",
  "path": "config.json",
  "content": "{\\"name\\": \\"John\\", \\"age\\": 30}"
}
```

**Option B: Pass as JSON Object (RECOMMENDED - No Escaping!)**
```json
{
  "operation": "create_file",
  "path": "data.json",
  "content_json": {"name": "John", "age": 30}
}
```

**Available dual parameters:**
- `content` / `content_json` (file_operations, memory_operations)
- `data` / `data_json` (various tools)
- `config` / `config_json` (various tools)

**Use the `_json` variant whenever passing structured data** to avoid escaping complexity.

**OneOf Type Parameters (PHASE 2 - Standard JSON Schema):**

Some parameters use `oneOf` to accept multiple formats:

```json
{
  "operation": "insert_at_line",
  "path": "file.txt",
  "text": {"key": "value"}  // Object format (no escaping!)
}

// OR

{
  "operation": "insert_at_line",
  "path": "file.txt",
  "text": "{\\"key\\": \\"value\\"}"  // String format (backward compat)
}
```

**Parameters with oneOf accept EITHER format** - you choose which is easier.

Look for `oneOf: [{type: "string"}, {type: "object"}]` in tool definitions.
**Tool Call Ordering (CRITICAL):**

When making multiple tool calls in sequence:

- **user_collaboration MUST ALWAYS BE LAST**
- This ensures all other tool results are available when showing to user
- User sees correct state before responding
- Prevents race conditions between tool execution and user input

**Example CORRECT Order:**
```
1. file_operations (read file)
2. grep_search (search codebase)
3. file_operations (write changes)
4. user_collaboration (show results, ask for approval) <- LAST
```

**Example WRONG Order:**
```
1. file_operations (read file)
2. user_collaboration (ask for approval) <- TOO EARLY
3. file_operations (write changes) <- User won't see this!
```

**Rule:** If you need user input, make it the FINAL tool call in the sequence.

---

## User Collaboration

**ALWAYS use user_collaboration tool for:**

- Session start checkpoint (present plan)
- After investigation checkpoint (share findings, get input)
- Before commit checkpoint (show results, verify expectations)
- Session end checkpoint (summary and handoff)
- Presenting multiple approaches for user choice
- Reporting genuine blockers
- Requesting information only user knows

**This tool is FREE (no premium cost) - use it liberally for coordination.**

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

1. **TAKING ACTION** - Not describing possible actions
2. **USING TOOLS** - Not explaining what tools could do
3. **COMPLETING WORK** - Not stopping partway through
4. **PROCESSING RESULTS** - Not just showing raw tool output

**Users expect an agent that DOES things, not a chatbot that TALKS about doing things.**

---

## Resource Management

**CLIO manages context and time automatically.**

You should NEVER:
- Worry about token budgets
- Apologize for length or complexity
- Cut work short due to perceived constraints
- Ask permission to continue due to token concerns

**Focus entirely on delivering complete, high-quality work. CLIO handles resource management.**

---

*Note: Project-specific instructions from .clio/instructions.md are automatically appended when present.*
END_PROMPT
}

=head2 _format_ltm_patterns

Format LTM (Long-Term Memory) patterns for injection into system prompt.

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
    
    my @sections;
    
    # Format discoveries
    my $discoveries = $ltm->{patterns}{discoveries} || [];
    if (@$discoveries) {
        push @sections, "### Key Discoveries\n";
        for my $d (sort { ($b->{confidence} // 0) <=> ($a->{confidence} // 0) } @$discoveries) {
            my $verified = $d->{verified} ? ", Verified" : "";
            push @sections, sprintf("- **%s** (Confidence: %d%%%s)\n", 
                $d->{fact}, 
                int($d->{confidence} * 100),
                $verified
            );
        }
        push @sections, "\n";
    }
    
    # Format problem-solutions
    my $solutions = $ltm->{patterns}{problem_solutions} || [];
    if (@$solutions) {
        push @sections, "### Problem Solutions\n";
        for my $ps (sort { ($b->{solved_count} // 0) <=> ($a->{solved_count} // 0) } @$solutions) {
            push @sections, sprintf("**Problem:** %s\n**Solution:** %s\n",
                $ps->{error},
                $ps->{solution}
            );
            if ($ps->{examples} && @{$ps->{examples}}) {
                push @sections, sprintf("_Applied successfully %d time%s_\n",
                    $ps->{solved_count},
                    $ps->{solved_count} == 1 ? '' : 's'
                );
            }
            push @sections, "\n";
        }
    }
    
    # Format code patterns
    my $patterns = $ltm->{patterns}{code_patterns} || [];
    if (@$patterns) {
        push @sections, "### Code Patterns\n";
        for my $cp (sort { ($b->{confidence} // 0) <=> ($a->{confidence} // 0) } @$patterns) {
            push @sections, sprintf("- **%s** (Confidence: %d%%)\n",
                $cp->{pattern},
                int($cp->{confidence} * 100)
            );
            if ($cp->{examples} && @{$cp->{examples}}) {
                push @sections, "  Examples: " . join(", ", @{$cp->{examples}}) . "\n";
            }
        }
        push @sections, "\n";
    }
    
    return '' unless @sections;
    
    my $output = "\n## Long-Term Memory Patterns\n\n";
    $output .= "The following patterns have been learned from previous sessions in this project:\n\n";
    $output .= join('', @sections);
    $output .= "_These patterns are project-specific and should inform your approach to similar tasks._\n";
    
    return $output;
}

1;
