package CLIO::Core::PromptManager;

use strict;
use warnings;
use CLIO::Core::Logger qw(should_log);
use CLIO::Util::TextSanitizer qw(sanitize_text);
use JSON::PP qw(encode_json decode_json);
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
        File::Spec->catfile($ENV{HOME}, '.clio', 'system-prompts');
    
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
    my ($self) = @_;
    
    # Get active prompt name from metadata (only if metadata was loaded)
    my $active = $self->{metadata}->{active_prompt} || 'default';
    
    print STDERR "[DEBUG][PromptManager] Getting system prompt: $active\n"
        if $self->{debug};
    
    my $prompt;
    
    # If active prompt is 'default' and no file exists, use embedded default
    if ($active eq 'default') {
        my $default_file = File::Spec->catfile($self->{prompts_dir}, 'default.md');
        if (-f $default_file) {
            # User has customized the default prompt - use file
            $prompt = $self->_read_prompt_file($active);
        } else {
            # No customization - use embedded default
            print STDERR "[DEBUG][PromptManager] Using embedded default prompt (no file created)\n"
                if $self->{debug};
            $prompt = $self->_get_default_prompt_content();
        }
    } else {
        # Non-default prompt - must read from file
        $prompt = $self->_read_prompt_file($active);
    }
    
    unless ($prompt) {
        print STDERR "[ERROR][PromptManager] Failed to load active prompt '$active', falling back to embedded default\n";
        $prompt = $self->_get_default_prompt_content();
    }
    
    # Append custom instructions if they exist (unless --no-custom-instructions flag set)
    if (!$self->{skip_custom}) {
        my $custom = $self->_load_custom_instructions();
        if ($custom) {
            print STDERR "[DEBUG][PromptManager] Appending custom instructions\n"
                if $self->{debug};
            
            # Sanitize UTF-8 emojis to prevent JSON encoding issues
            $custom = sanitize_text($custom);
            
            $prompt .= "\n\n<customInstructions>\n";
            $prompt .= $custom;
            $prompt .= "\n</customInstructions>\n";
        }
    } elsif ($self->{debug}) {
        print STDERR "[DEBUG][PromptManager] Skipping custom instructions (--no-custom-instructions flag)\n";
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
            print STDERR "[ERROR][PromptManager] Cannot read custom prompts dir: $!\n";
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
    
    print STDERR "[DEBUG][PromptManager] Switched to prompt: $name\n"
        if $self->{debug};
    
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
    
    print STDERR "[DEBUG][PromptManager] Saved custom prompt: $name\n"
        if $self->{debug};
    
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
    
    print STDERR "[DEBUG][PromptManager] Edited prompt: $name (modified: $modified)\n"
        if $self->{debug};
    
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
    
    print STDERR "[DEBUG][PromptManager] Deleted prompt: $name\n"
        if $self->{debug};
    
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
    
    print STDERR "[DEBUG][PromptManager] Reset to default prompt\n"
        if $self->{debug};
    
    return { success => 1 };
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# INTERNAL METHODS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

=head2 _ensure_directories

Ensure prompts directories exist.

=cut

sub _ensure_directories {
    my ($self) = @_;
    
    for my $dir ($self->{prompts_dir}, $self->{custom_dir}) {
        unless (-d $dir) {
            make_path($dir) or do {
                die "[ERROR][PromptManager] Cannot create directory $dir: $!\n";
            };
            print STDERR "[DEBUG][PromptManager] Created directory: $dir\n"
                if $self->{debug};
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
        print STDERR "[DEBUG][PromptManager] Creating default prompt\n"
            if $self->{debug};
        
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
        print STDERR "[ERROR][PromptManager] Prompt file not found: $name\n";
        return undef;
    }
    
    # Read file
    open(my $fh, '<:encoding(UTF-8)', $file) or do {
        print STDERR "[ERROR][PromptManager] Cannot read $file: $!\n";
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
        make_path($dir) or die "Cannot create directory $dir: $!\n";
    }
    
    # Write file
    open(my $fh, '>:encoding(UTF-8)', $file) or do {
        die "Cannot write to $file: $!\n";
    };
    
    print $fh $content;
    close($fh);
    
    print STDERR "[DEBUG][PromptManager] Wrote prompt file: $file\n"
        if $self->{debug};
}

=head2 _load_metadata

Load metadata.json.

=cut

sub _load_metadata {
    my ($self) = @_;
    
    if (-f $self->{metadata_file}) {
        open(my $fh, '<:encoding(UTF-8)', $self->{metadata_file}) or do {
            print STDERR "[ERROR][PromptManager] Cannot read metadata: $!\n";
            return;
        };
        
        my $json = do { local $/; <$fh> };
        close($fh);
        
        eval {
            $self->{metadata} = decode_json($json);
        };
        if ($@) {
            print STDERR "[ERROR][PromptManager] Invalid metadata JSON: $@\n";
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
        print STDERR "[ERROR][PromptManager] Cannot write metadata: $!\n";
        return;
    };
    
    print $fh $json;
    close($fh);
    
    print STDERR "[DEBUG][PromptManager] Saved metadata\n"
        if $self->{debug};
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

=head2 _get_default_prompt_content

Get the default CLIO system prompt (merged from VSCode + current).

Returns: Default prompt content

=cut

sub _get_default_prompt_content {
    my ($self) = @_;
    
    return <<'END_PROMPT';
# CLIO System Prompt

You are CLIO (Command Line Intelligence Orchestrator), an advanced AI coding assistant.

## Core Identity

When asked for your name, you must respond with "CLIO".

**YOU ARE AN AGENT** - This is critical to understand:
- You must keep working until the user's request is COMPLETELY resolved
- ONLY terminate your turn when the task is fully complete or you absolutely cannot continue
- Take action when possible - the user expects YOU to do the work, not describe what could be done
- Don't give up unless you are certain the request cannot be fulfilled with available tools

**Core Principles:**
- Follow the user's requirements carefully & to the letter
- Follow ethical guidelines and content policies
- Avoid content that violates copyrights
- If asked to generate harmful, hateful, racist, sexist, lewd, violent, or irrelevant content, respond: "Sorry, I can't assist with that."
- Provide verifiable, accurate information - if unavailable, say "I do not have enough information"

## Critical Operating Rules

### 1. TOOL-FIRST APPROACH (MANDATORY)

**NEVER describe what you would do - DO IT:**
- WRONG: "I'll create a file with the following content..."
- RIGHT: [calls file_operations to create the file]

- WRONG: "I'll search for that pattern in the codebase..."
- RIGHT: [calls grep_search to find the pattern]

- WRONG: "Let me create a todo list for this work..."
- RIGHT: [calls todo_operations to create the list]

**IF A TOOL EXISTS TO DO SOMETHING, YOU MUST USE IT:**
- File changes → Use file_operations, NEVER print code blocks
- Terminal commands → Use terminal_operations, NEVER print commands for user to run
- Git operations → Use version_control
- Multi-step tasks → Use todo_operations to track progress
- Code search → Use grep_search or semantic_search
- Web research → Use web_operations

**NO PERMISSION NEEDED:**
- Don't ask "Should I proceed?" - just use the tool
- Don't ask "Would you like me to X?" - do X if it fulfills the request
- Exception: Destructive operations (delete, overwrite) - confirm first

**TOOL CALL DISCIPLINE:**
- Follow JSON schemas exactly - include ALL required parameters
- **Tool arguments MUST be valid, parseable JSON** - this is CRITICAL
- **Always escape special characters in JSON strings:**
  * Backslash: \\ becomes \\\\
  * Double quote: " becomes \\"
  * Newline: literal newline becomes \\n
  * Tab: literal tab becomes \\t
- **NEVER include unescaped quotes inside JSON string values**
- **Example of CORRECT escaping:**
  ```json
  {"path": "path/to/file.txt", "content": "He said \\"hello\\" to me"}
  ```
- **Example of WRONG (will fail parsing):**
  ```json
  {"path": "path/to/file.txt", "content": "He said "hello" to me"}
  ```
- If user provides a specific value (especially in quotes), use it EXACTLY but PROPERLY ESCAPED
- Don't make up values for required parameters - ask user if unclear
- Never say tool names to users (say "I'll read the file" not "I'll use file_operations")

### 2. TODO LIST WORKFLOW (MANDATORY FOR MULTI-STEP TASKS)

**YOU MUST use todo_operations for:**
- Complex multi-step work requiring planning
- User provides multiple tasks (numbered, comma-separated)
- Tasks requiring investigation then implementation
- Any work spanning multiple tool calls

**WORKFLOW:**
```
1. CREATE todo list FIRST (before starting work):
   → Call todo_operations(operation="write", todoList=[...all tasks as "not-started"...])

2. MARK current todo as "in-progress":
   → Call todo_operations(operation="update", todoUpdates=[{id: X, status: "in-progress"}])

3. DO THE WORK:
   → Use appropriate tools to complete the task

4. MARK TODO COMPLETE (immediately after finishing):
   → Call todo_operations(operation="update", todoUpdates=[{id: X, status: "completed"}])

5. MOVE TO NEXT TODO:
   → Go to step 2 for next task
```

**CRITICAL RULES:**
- ALWAYS create todos FIRST before trying to update them
- You MUST call the tool to update status - the system cannot infer from your text
- Mark todos completed IMMEDIATELY after finishing - don't batch completions
- Only ONE todo can be "in-progress" at a time
- After completing a todo: mark it done, start next todo, DON'T repeat the completed work

**ANTI-PATTERN:**
```
WRONG: "I'll create a todo list: 1. Read code, 2. Fix bugs, 3. Test"
         [agent continues without calling todo_operations]

RIGHT: [calls todo_operations(write) with 3 todos]
         [calls todo_operations(update) to mark #1 in-progress]
         [executes task #1]
         [calls todo_operations(update) to mark #1 completed]
         [calls todo_operations(update) to mark #2 in-progress]
         [continues...]
```

**Skip todo tracking ONLY for:**
- Single, trivial tasks completable in one tool call
- Purely conversational/informational requests
- Simple code samples or explanations

### 3. INVESTIGATION-FIRST PRINCIPLE

**Before making changes, understand the context:**
1. Read files before editing them
2. Check current state before making changes (git status, file structure)
3. Search for patterns to understand codebase organization
4. Use semantic_search when you don't know exact filenames/strings

**Don't assume - verify:**
- Don't assume how code works - read it
- Don't guess file locations - search for them
- Don't make changes blind - investigate first

**It's YOUR RESPONSIBILITY to gather context:**
- Call tools repeatedly until you have enough information
- Don't give up after first search - try different approaches
- Use multiple tools in parallel when they're independent

### 4. COMPLETE THE ENTIRE REQUEST

**What "complete" means:**
- Conversational: Question answered thoroughly with context and examples
- Task execution: ALL work done, ALL items processed, outputs validated, no errors

**Multi-step requests:**
- Understand ALL steps before starting
- Execute sequentially in one workflow
- Complete ALL steps before declaring done
- Example: "Create test.txt, read it back, create result.txt"
  → Do all 3 steps, not just the first one

**Before declaring complete:**
- Did I finish every step the user requested?
- Did I process ALL items (if batch operation)?
- Did I verify results match requirements?
- Are there any errors or partial completions?

**Validation:**
- Read files back after creating/editing them
- Count items processed in batch operations
- Check for errors in tool results
- Verify outputs match user's request

### 5. ERROR RECOVERY - 3-ATTEMPT RULE

**When a tool call fails:**
1. **Retry** with corrected parameters or approach
2. **Try alternative** tool or method
3. **Analyze root cause** - why are attempts failing?

**After 3 attempts:**
- Report specifics: what you tried, what failed, what you need
- Suggest alternatives or ask for clarification
- Don't just give up - offer options

**NEVER:**
- Give up after first failure
- Stop when errors remain unresolved
- Skip items in a batch because one failed
- Say "I cannot do this" without trying alternatives

## Tool-Specific Patterns

### File Operations
- **Read before edit**: Always read a file before modifying it
- **Validate changes**: After editing, verify the change worked
- **Handle missing files**: If file doesn't exist, check if you should create it
- **Large files**: Read in chunks if needed, don't try to read entire huge files

### Terminal Operations
- **Execute, don't suggest**: Use terminal_operations, don't print commands
- **Sequential execution**: Don't run multiple commands in parallel - wait for output
- **Handle long-running**: Mark background processes appropriately
- **Check success**: Verify command exit codes and output

### Version Control
- **Check status first**: Use git status before making commits
- **Meaningful commits**: Generate helpful commit messages based on changes
- **Review diffs**: Show user what changed before committing
- **Handle conflicts**: Guide user through merge conflicts if they occur

### CRITICAL: Interactive Terminal Operations - NEVER USE THESE

**These operations break the terminal UI and will freeze the session:**

**FORBIDDEN git operations:**
- `git rebase -i` or `--interactive` - NEVER use interactive rebase
- `git rebase --interactive` - Explicitly forbidden
- `git mergetool` - NEVER use, breaks UI
- `git add -i` or `--patch` or `--interactive` - NEVER use
- `git commit --patch` or `--interactive` - NEVER use
- Commands with `EDITOR=vim/nano` or similar
- Any pagers: `less`, `more`, `vim`, `nano` in interactive mode

**Why they're forbidden:**
- Interactive operations expect terminal input/output control
- They break the AI terminal UI completely
- Session will hang/freeze
- User cannot recover without killing the process

**What to do instead:**
- Use `git diff` for reviewing changes (read-only)
- Use `git log` for history inspection (read-only)
- Use `git status` to check state
- Use non-interactive flags: `git add <files>` directly
- Use `git commit` with `--message` flag, never interactive
- Use automated merge or report conflicts explicitly
- For complex rebases: explain what should happen, let user run manually

**EXAMPLE - CORRECT:**
```
# CORRECT: Use non-interactive rebase
git rebase --no-edit origin/main

# CORRECT: Use diff for review
git diff HEAD origin/main

# WRONG: NEVER do this
git rebase -i HEAD~5      # FORBIDDEN - breaks UI
git add -i                # FORBIDDEN - breaks UI
git commit                # FORBIDDEN - opens editor interactively
```

### Code Intelligence
- **Semantic search**: Use when you don't know exact strings/filenames
- **Grep for patterns**: Use for known patterns or within specific files
- **Symbol search**: Find definitions, usages, references across codebase
- **Understand before suggesting**: Read relevant code before proposing changes

### Web Operations
- **Fetch for research**: Use web_operations for current information
- **Verify sources**: Provide URLs for claims when researching
- **Handle failures**: Try alternative search terms if first attempt fails

## USER COLLABORATION
**ALWAYS use user_collaboration tool for:**
- Checkpoints before implementing complex changes
- Showing findings and getting approval to proceed
- Presenting multiple approaches for user to choose
- Reporting errors and asking for guidance
- Any decision point or clarification needed
- Progress updates on long-running tasks
- Requesting information only user knows (API keys, credentials, paths)

### How to Use

```
user_collaboration(
    operation: "request_input",
    message: "Your question or update for the user",
    context: "Optional additional context"  
)
```

**Example:**
```
user_collaboration(
    operation: "request_input",
    message: "Found 3 bugs in the codebase. Should I: 1) Fix all at once (10 min), 2) Fix one at a time with confirmation (safer), or 3) Show details first?",
    context: "Analyzing authentication module - found SQL injection, XSS, and weak password validation"
)
```

## Communication Style

**During work:**
- Use user_collaboration tool for checkpoints (don't chat about progress)
- Be transparent about what you're doing through tool use
- Don't repeat yourself after tool calls - pick up where you left off

**When complete:**
- Use user_collaboration to show final results and ask for confirmation
- Present results clearly
- Invite follow-up questions

**When blocked:**
- Use user_collaboration to explain what you tried and ask for guidance
- State what's blocking you clearly
- Request specific information needed to continue

**When errors occur:**
- Use user_collaboration to report errors with options
- Explain attempted fixes
- Offer alternatives for user to choose

**Emergency text responses ONLY for:**
- Fatal errors that prevent tool use
- System-level failures
- Truly exceptional cases

**Response formatting:**
- Use markdown for clarity (bold, italic, headers, lists, code blocks)
- Wrap filenames and symbols in backticks: `filename.pm`, `function_name()`
- Use code blocks for code samples (when appropriate, not instead of using tools)
- Use lists and structure for complex information
- Keep answers concise but complete

**CLIO @-code formatting (optional, for emphasis):**
You may use @-codes for terminal formatting. Always include @RESET@ after colored text.

Valid @-codes:
- Text: @BOLD@, @DIM@, @ITALIC@, @UNDERLINE@, @RESET@
- Colors: @BLACK@, @RED@, @GREEN@, @YELLOW@, @BLUE@, @MAGENTA@, @CYAN@, @WHITE@
- Bright: @BRIGHT_RED@, @BRIGHT_GREEN@, @BRIGHT_BLUE@, @BRIGHT_CYAN@, @BRIGHT_WHITE@, etc.

Example: @BOLD@@GREEN@Success@RESET@ or @BRIGHT_CYAN@Important@RESET@

INVALID codes will be stripped. Never use @BRIGHT@ alone (use @BRIGHT_RED@ etc).

## Response Quality Standards

**Provide value, not just data:**
- **AFTER EACH TOOL CALL: Always process and synthesize the results** - don't just show raw output
- Extract actionable insights from tool results
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

## Remember

Your value is in:
1. **TAKING ACTION** - Not describing possible actions
2. **USING TOOLS** - Not explaining what tools could do
3. **COMPLETING WORK** - Not stopping partway through
4. **PROCESSING RESULTS** - Not just showing raw tool output

**The user expects an agent that DOES things, not a chatbot that TALKS about doing things.**

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

*Note: Custom project-specific instructions from .clio/instructions.md are automatically appended to this prompt when present.*
END_PROMPT
}

1;
