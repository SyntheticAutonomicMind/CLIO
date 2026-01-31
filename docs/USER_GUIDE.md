# CLIO User Guide

**Complete guide to using CLIO (Command Line Intelligence Orchestrator)**

---------------------------------------------------

## Table of Contents

1. [Introduction](#introduction)
2. [Installation](#installation)
3. [Getting Started](#getting-started)
4. [Core Concepts](#core-concepts)
5. [Available Tools](#available-tools)
6. [Usage Examples](#usage-examples)
7. [Configuration](#configuration)
8. [Customization](#customization)
9. [Skills](#skills)
10. [Tips & Best Practices](#tips--best-practices)
11. [Troubleshooting](#troubleshooting)
12. [FAQ](#faq)

---------------------------------------------------

## Introduction

### What is CLIO?

CLIO is a terminal-based AI code assistant that brings powerful AI capabilities directly into your command-line workflow. Unlike browser-based tools, CLIO integrates with your filesystem, version control, and terminal environment to provide intelligent assistance without leaving your terminal.

### Why Choose CLIO?

**Terminal-Native**: Works entirely in your terminal—no browser tabs, no GUI overhead. If you live in the terminal, CLIO fits naturally into your workflow.

**Tool-Powered**: CLIO doesn't hallucinate file contents or command output. It uses real tools to read files, execute commands, and interact with your system.

**Action Transparency**: Every operation shows exactly what it's doing. You always know what files CLIO is reading, what commands it's executing, and what changes it's making.

**Persistent Context**: Conversations are saved automatically with full history. Resume any session exactly where you left off, even after days or weeks.

**Professional Output**: Beautiful markdown rendering in the terminal with syntax highlighting, tables, lists, and proper formatting.

### What Can CLIO Do?

- **Code Understanding**: Read and analyze code, explain functions, trace logic
- **File Operations**: Read, write, search, edit files across your project
- **Version Control**: Git operations (status, diff, commit, branch, merge)
- **Command Execution**: Run terminal commands and scripts
- **Code Refactoring**: Restructure code with intelligent changes
- **Documentation**: Generate docs, write README files, create comments
- **Research**: Fetch web content, analyze documentation
- **Task Management**: Create and manage todo lists
- **Memory**: Store and recall information across sessions

---------------------------------------------------

## Installation

### Prerequisites

**System Requirements:**
- macOS 10.14+ or Linux (any modern distribution)
- Perl 5.20 or higher
- Git (for version control operations)
- ANSI-compatible terminal emulator

**AI Provider Requirements:**
- GitHub Copilot subscription + API token, OR
- Qwen API key

### Installation Steps

**1. Clone the Repository**

```bash
git clone https://github.com/fewtarius/clio.git
cd clio
```

**2. Run the Installer**

```bash
sudo ./install.sh
```

The installer will:
- Install CLIO executable to `/usr/local/bin/clio`
- Set up library files in `/usr/local/lib/clio/`
- Create configuration directories
- Set proper permissions

**3. Verify Installation**

```bash
clio --help
```

You should see:
```
CLIO - Command Line Intelligence Orchestrator
AI-Powered Development Assistant

USAGE:
    clio [OPTIONS]
...
```

### Configuration

**GitHub Copilot Setup** (Default - Recommended)

No environment variables needed! Just start CLIO and login:

```bash
./clio
: /login
# Follow browser prompts to authorize with GitHub
# Tokens are saved automatically to ~/.clio/github_tokens.json
```

**Alternative Provider Setup**

Use `/api` commands interactively:

```bash
./clio
: /api provider openai
: /api key YOUR_OPENAI_API_KEY
: /api model gpt-4o
: /config save  # Save to ~/.clio/config.json
```

**Optional Environment Variables**

```bash
# Set custom session directory
export CLIO_SESSION_DIR="$HOME/.clio/sessions"
```

**Debug Output**

Use the `--debug` flag to enable debug output: `clio --debug --new`

**Note:** API keys and providers are configured with `/api` commands, not environment variables.

### Getting Your GitHub Copilot Token

1. Open VS Code or your GitHub Copilot-enabled editor
2. Access the Copilot settings
3. Generate an API token
4. Copy and set as `GITHUB_COPILOT_TOKEN`

---------------------------------------------------

## Getting Started

### Your First Session

**Start CLIO:**

```bash
clio --new
```

You'll see the welcome banner:
```
------------------------------------------━━
CLIO - Command Line Intelligence Orchestrator
Session ID: sess_20260118_143052
You are connected to gpt-4o
Press "?" for a list of commands.
------------------------------------------━━

YOU: 
```

**Try a simple command:**

```
YOU: Please list the files in this directory

SYSTEM: [file_operations] - listing ./ (15 files, 8 directories)

CLIO: I can see you have several files and directories here:

**Directories:**
- lib/ (source code modules)
- docs/ (documentation)
- scripts/ (utility scripts)
- sessions/ (saved conversations)

**Files:**
- clio (main executable)
- README.md (project documentation)
- install.sh (installation script)
...
```

**Ask CLIO to read a file:**

```
YOU: Show me the contents of README.md

SYSTEM: [file_operations] - Reading ./README.md (466 lines)

CLIO: Here's the README.md file:

# CLIO - Command Line Intelligence Orchestrator

**An AI code assistant that works in your terminal...**
...
```

**Make a code change:**

```
YOU: In lib/CLIO/Core/Main.pm, change the timeout from 30 to 60 seconds

SYSTEM: [file_operations] - Reading lib/CLIO/Core/Main.pm
SYSTEM: [file_operations] - Replacing string in lib/CLIO/Core/Main.pm

CLIO: I've updated the timeout in Main.pm from 30 to 60 seconds:

[Shows diff of the change]
```

**End your session:**

Type `exit` or press `Ctrl+D` to end the session. Your conversation history is automatically saved.

### Resuming Sessions

**Resume your most recent session:**

```bash
clio --resume
```

**List available sessions:**

```bash
ls sessions/
```

Output:
```
sess_20260118_143052.json
sess_20260118_150234.json
sess_20260118_163421.json
```

**Resume a specific session:**

```bash
clio --resume sess_20260118_143052
```

Your entire conversation history, including all tool operations and responses, will be restored exactly as you left it.

---------------------------------------------------

## Core Concepts

### Sessions

Every CLIO conversation is a **session**. Sessions are:

- **Persistent**: Automatically saved to `sessions/` directory
- **Resumable**: Pick up exactly where you left off
- **Complete**: Include full conversation history and tool operations
- **Timestamped**: Named with creation date/time (e.g., `sess_20260118_143052`)

**Session Storage:**
Sessions are stored as JSON files in `sessions/` directory:
```json
{
  "id": "sess_20260118_143052",
  "created_at": "2026-01-18T14:30:52Z",
  "conversation": [...],
  "model": "gpt-4o",
  "state": {...}
}
```

### Tools

CLIO interacts with your system through **tools**. When you ask CLIO to do something, it selects appropriate tools and executes them.

**Tool Categories:**
- **File Operations**: Read, write, search, edit files
- **Version Control**: Git operations
- **Terminal**: Execute commands
- **Memory**: Store and recall information
- **Todo Lists**: Task management
- **Web**: Fetch web content

**Tool Transparency:**
Every tool operation shows an action description:
```
SYSTEM: [file_operations] - Reading ./src/main.c (247 lines)
SYSTEM: [git] - Executing git status in ./
SYSTEM: [terminal] - Executing: find lib -name "*.pm" | wc -l
```

### Action Descriptions

Action descriptions tell you **exactly** what CLIO is doing:

```
SYSTEM: [file_operations] - Reading ./config.yaml (45 lines)
SYSTEM: [file_operations] - Writing ./config.yaml (47 lines)
SYSTEM: [git] - Creating branch feature/new-feature
SYSTEM: [terminal] - Executing: perl -c lib/CLIO/Core/Main.pm
```

This transparency means:
- No surprise file modifications
- No hidden command execution
- Complete visibility into CLIO's actions
- Easy auditing of what changed

### Markdown Rendering

CLIO renders responses as formatted markdown in your terminal:

**Headers:**
```
# Large Header
## Medium Header
### Small Header
```

**Code Blocks:**
````
```perl
sub hello {
    print "Hello, world!\n";
}
```
````

**Lists:**
```
- Item 1
- Item 2
  - Nested item
```

**Tables:**
```
| Column 1 | Column 2 |
|----------------------------------------------------------------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------|
| Data 1   | Data 2   |
```

**Emphasis:**
```
**Bold text**
*Italic text*
`Inline code`
```

All of these render beautifully in your terminal with proper colors, indentation, and formatting.

### Memory System

CLIO can **remember** information across sessions:

**Store information:**
```
YOU: Remember that our production API endpoint is https://api.example.com/v2
```

**Recall later (even in a different session):**
```
YOU: What's our production API endpoint?

CLIO: Your production API endpoint is https://api.example.com/v2 
(stored on 2026-01-18)
```

**Search memories:**
```
YOU: What do I know about database configuration?

CLIO: I found 3 memories related to database configuration:
1. Database host: db.example.com (stored 2026-01-15)
2. Database name: production_db (stored 2026-01-15)
3. Connection pool size: 20 (stored 2026-01-16)
```

---------------------------------------------------

## Available Tools

### File Operations

**read_file** - Read file contents
```
YOU: Show me the contents of src/auth.pm
```

**write_file** - Create or overwrite a file
```
YOU: Create a new file called test.txt with the content "Hello, world!"
```

**create_file** - Create a new file with content
```
YOU: Create a Python script that prints the Fibonacci sequence
```

**delete_file** - Delete a file or directory
```
YOU: Delete the temp/ directory
```

**rename_file / move_file** - Rename or move files
```
YOU: Rename config.yaml to config.yaml.backup
```

**list_dir** - List directory contents
```
YOU: What files are in the lib/ directory?
```

**file_search** - Find files by name pattern
```
YOU: Find all Perl modules in the project
```

**grep_search** - Search file contents for patterns
```
YOU: Search for all TODO comments in the codebase
```

**semantic_search** - Natural language code search
```
YOU: Find functions that handle authentication
```

**replace_string** - Find and replace in files
```
YOU: In config.yaml, replace the port number 8080 with 9000
```

**get_errors** - Get compilation or linting errors
```
YOU: Check for syntax errors in all Perl modules
```

**get_file_info** - Get file metadata
```
YOU: What's the size and modification date of README.md?
```

**file_exists** - Check if file exists
```
YOU: Does config.yaml exist?
```

### Version Control (Git)

**git_status** - Show working tree status
```
YOU: What's the current git status?
```

**git_diff** - Show changes
```
YOU: Show me what changed in the last commit
YOU: What are my uncommitted changes?
```

**git_log** - Show commit history
```
YOU: Show me the last 10 commits
YOU: Show commits from the last week
```

**git_commit** - Create a commit
```
YOU: Commit all changes with message "Fix authentication bug"
```

**git_push** - Push changes to remote
```
YOU: Push my commits to origin
```

**git_pull** - Pull changes from remote
```
YOU: Pull the latest changes from main branch
```

**git_branch** - Branch operations
```
YOU: Create a new branch called feature/new-login
YOU: List all branches
```

**git_checkout** - Switch branches or restore files
```
YOU: Switch to the main branch
YOU: Restore the file config.yaml from the last commit
```

**git_merge** - Merge branches
```
YOU: Merge the feature/new-login branch into main
```

**git_reset** - Reset changes
```
YOU: Undo the last commit but keep the changes
```

### Terminal Operations

**execute_command** - Run a shell command
```
YOU: Run the test suite
YOU: Count the lines of code in all Perl files
YOU: Show me the current disk usage
```

**get_terminal_output** - Get output from a previous command
```
YOU: What was the output of the last command?
```

### Memory Operations

**store_memory** - Store information
```
YOU: Remember that the database password is in /etc/secrets/db.conf
```

**retrieve_memory** - Recall specific information
```
YOU: What did I store about the database password?
```

**search_memory** - Search stored memories
```
YOU: Find all information about API endpoints
```

**list_memories** - List all stored memories
```
YOU: Show me everything you remember
```

**delete_memory** - Forget stored information
```
YOU: Forget the information about the old API endpoint
```

**Long-Term Memory (LTM) Management:**
```
/memory stats    # Show LTM statistics (entry counts, timestamps)
/memory prune    # Remove old/low-confidence entries (default 90 days)
/memory prune 30 # Remove entries older than 30 days
```

### Todo List Operations

**manage_todo_list** - Create and manage tasks
```
YOU: Create a todo list for this refactoring project
YOU: Mark task 3 as complete
YOU: Show me all remaining tasks
YOU: Add a new task to implement caching
```

### Web Operations

**fetch_webpage** - Fetch and analyze web content
```
YOU: Fetch the documentation from https://docs.example.com/api
YOU: Summarize the content of https://blog.example.com/article
```

---------------------------------------------------

## Usage Examples

### Example 1: Project Design & Setup

**Starting a new project with `/design`:**

```
YOU: /design

CLIO: Let's design your application together. Tell me about your project 
      idea - what problem are you trying to solve?

YOU: I want to build a markdown-based personal wiki that runs in the terminal

CLIO: A terminal-based markdown wiki - interesting! Let's explore the 
      architecture...
      
      First, let's understand the requirements:
      - Will this be single-user or multi-user?
      - Do you need search functionality?
      - Should it support linking between pages?
      - Any special markdown extensions needed?

YOU: Single user, yes to search and linking. I'd like to support task lists.

CLIO: Perfect. For a terminal markdown wiki with those features, I'm thinking:
      
      **Architecture Pattern:** File-based storage with indexed search
      - Pro: Simple, version-controllable with git
      - Con: Search requires indexing
      
      Have you considered using a database instead? Or are you committed 
      to plain files?

YOU: Plain files for sure - I want git integration

CLIO: Smart choice. That gives you version history for free. Here's what I'm 
      thinking for the stack:
      
      **Technology:**
      - Perl 5.32+ (matches your terminal preferences)
      - Text::Markdown::Discount (fast markdown parsing)
      - Search::Elasticsearch or Lucy for full-text search
      - Git integration via Git::Repository
      
      **Architecture:**
      ```
      wiki/
        pages/           # Markdown files
        .index/          # Search index
        .git/            # Version history
      ```
      
      **Components:**
      - Page Manager: CRUD for markdown files
      - Link Parser: Extract [[WikiLinks]]
      - Search Engine: Index and query
      - Git Handler: Auto-commit on save
      - Terminal UI: Browse, edit, search
      
      What do you think? Any concerns with this approach?

YOU: Looks good, but I'm worried about search performance with lots of pages

CLIO: Valid concern. Let me suggest two options:
      
      **Option 1: Lucy (lightweight, pure Perl)**
      - Pro: No external dependencies, fast enough for <10k pages
      - Con: Slower than Elasticsearch for large wikis
      
      **Option 2: ripgrep + fzf (external tools)**
      - Pro: Blazing fast, no index needed
      - Con: External dependencies, less structured queries
      
      For a personal wiki, ripgrep might be perfect. Thoughts?

YOU: Let's go with ripgrep for simplicity

CLIO: Perfect! I'll document that decision. Creating your PRD now...

SYSTEM: [file_operations] - Writing .clio/PRD.md

CLIO: I've created a comprehensive PRD at `.clio/PRD.md` with:
      
      **Project: TermWiki**
      - Purpose: Terminal-based personal wiki with git version control
      - Architecture: File-based storage + ripgrep search
      - Stack: Perl, Text::Markdown::Discount, ripgrep, Git
      - Components: 5 main modules documented
      - MVP Features: Create/edit/delete pages, wiki links, search, git auto-commit
      - Phase 2: Tag system, templates, export to HTML
      
      Would you like to initialize the project? (Type '/init')

YOU: /init

SYSTEM: [web_operations] - Fetching CLIO methodology docs
SYSTEM: [file_operations] - Reading .clio/PRD.md
SYSTEM: [file_operations] - Writing .clio/instructions.md

CLIO: Project initialized! I've created custom instructions that include:
      
      **From Your PRD:**
      - Project purpose and architecture
      - Technology stack (Perl + ripgrep)
      - Testing strategy (unit + integration tests)
      - Development workflow (TDD with git auto-commit)
      
      **CLIO Methodology:**
      - The Unbroken Method principles
      - Collaboration checkpoints
      - Code quality standards
      
      Ready to start building! Try: "Create the Page Manager module"
```

**Later, updating the design:**

```
YOU: /design

SYSTEM: [file_operations] - Reading .clio/PRD.md

CLIO: I found your TermWiki PRD (last updated 5 days ago).
      
      **Current Design:**
      - Markdown wiki with file-based storage
      - ripgrep search
      - Git version control
      - 5 MVP features defined
      
      What's changed? New requirements? Technical insights? Scope adjustments?

YOU: I want to add a web interface for viewing (not editing)

CLIO: Interesting - a read-only web view. This changes the architecture 
      significantly. Let's think through the implications...
      
      **Two Approaches:**
      
      1. **Static Site Generation**
         - Generate HTML from markdown on save
         - Serve with any web server
         - Pro: Simple, fast, no runtime
         - Con: Manual publish step
         
      2. **Live Web Server**
         - Perl web server (Mojolicious/Dancer)
         - Renders markdown on-the-fly
         - Pro: Always current, dynamic search
         - Con: Needs to run continuously
         
      For a personal wiki, I'd lean toward static generation. Thoughts?

YOU: Static generation sounds perfect

CLIO: Great! Updating your PRD...
      
      **Changes:**
      - Added Phase 2 feature: HTML export & static site generation
      - New component: SiteBuilder module
      - Updated dependencies: Template::Toolkit for HTML templates
      - New milestone: Web viewer (after MVP)
      
      Your architecture has evolved - consider running '/init --force' to 
      update project instructions with this new component.

YOU: /init --force

SYSTEM: [file_operations] - Backing up .clio/instructions.md
SYSTEM: [file_operations] - Reading .clio/PRD.md
SYSTEM: [file_operations] - Writing .clio/instructions.md

CLIO: Instructions updated! Now includes:
      - SiteBuilder module architecture
      - HTML generation workflow
      - Static site deployment strategy
      
      Ready to implement the web export feature.
```

### Example 2: Code Exploration

**Understanding a new codebase:**

```
YOU: I'm new to this project. Can you give me an overview of the codebase structure?

SYSTEM: [file_operations] - listing ./ (15 files, 8 directories)
SYSTEM: [file_operations] - Reading ./README.md
SYSTEM: [file_operations] - listing ./lib

CLIO: Here's an overview of the codebase:

**Project Structure:**
This is CLIO, a Perl-based AI code assistant. The structure is:

- `lib/CLIO/` - Core implementation
  - `Core/` - Main system components (AIAgent, APIManager, etc.)
  - `Tools/` - Tool implementations (FileOperations, VersionControl, etc.)
  - `UI/` - Terminal user interface (SimpleChat, Theme, ANSI)
  - `Session/` - Session management
  
- `scripts/` - Utility scripts
- `sessions/` - Saved conversation sessions
- `docs/` - User-facing documentation
- `docs-internal/` - Development specifications

**Key Components:**
- `clio` - Main executable (entry point)
- `lib/CLIO/Core/SimpleAIAgent.pm` - AI agent implementation
- `lib/CLIO/UI/SimpleChat.pm` - Chat interface
- `lib/CLIO/Tools/Registry.pm` - Tool management

Would you like me to explain any specific component in detail?
```

### Example 3: Refactoring Code

**Improving error handling:**

```
YOU: Find all database query functions and add try-catch error handling

SYSTEM: [file_operations] - Searching for pattern "query|execute" in ./lib
SYSTEM: [file_operations] - Reading lib/CLIO/Database/Connection.pm
SYSTEM: [file_operations] - Replacing string in lib/CLIO/Database/Connection.pm

CLIO: I found 8 database query functions and added comprehensive error 
handling to all of them. Here's an example of the changes:

**Before:**
```perl
sub get_user {
    my ($self, $user_id) = @_;
    my $sth = $dbh->prepare("SELECT * FROM users WHERE id = ?");
    $sth->execute($user_id);
    return $sth->fetchrow_hashref;
}
```

**After:**
```perl
sub get_user {
    my ($self, $user_id) = @_;
    
    eval {
        my $sth = $dbh->prepare("SELECT * FROM users WHERE id = ?");
        $sth->execute($user_id);
        return $sth->fetchrow_hashref;
    };
    
    if ($@) {
        print STDERR "[ERROR][Database] Failed to get user $user_id: $@\n";
        return undef;
    }
}
```

All 8 functions now have:
- eval blocks to catch exceptions
- Error logging to STDERR
- Graceful failure with undef return
```

### Example 3: Git Workflow

**Feature branch workflow:**

```
YOU: Create a new feature branch, add logging to the APIManager, and commit the changes

SYSTEM: [git] - Creating branch feature/add-api-logging
SYSTEM: [git] - Switching to feature/add-api-logging
SYSTEM: [file_operations] - Reading lib/CLIO/Core/APIManager.pm
SYSTEM: [file_operations] - Replacing string in lib/CLIO/Core/APIManager.pm (5 changes)
SYSTEM: [git] - Staging lib/CLIO/Core/APIManager.pm
SYSTEM: [git] - Committing with message "feat(api): add comprehensive logging"

CLIO: Done! I've created the feature/add-api-logging branch, added logging 
at key points in APIManager, and committed the changes.

**What was added:**
- Request initiation logging (endpoint + parameters)
- Response status and timing
- Error logging with full context
- Token usage tracking

**Commit details:**
```
commit a1b2c3d4
Author: CLIO <clio@example.com>
Date:   Sat Jan 18 14:30:52 2026

    feat(api): add comprehensive logging
    
    Added logging to APIManager for debugging and monitoring:
    - Request tracking
    - Response metrics
    - Error context
    - Token usage
```

The branch is ready for review or testing.
```

### Example 4: Documentation Generation

**Creating comprehensive documentation:**

```
YOU: Create API documentation for all public methods in lib/CLIO/Tools/FileOperations.pm

SYSTEM: [file_operations] - Reading lib/CLIO/Tools/FileOperations.pm
SYSTEM: [file_operations] - Creating docs/API/FileOperations.md

CLIO: I've created comprehensive API documentation for FileOperations:

**docs/API/FileOperations.md** (165 lines)

The documentation includes:

**For each method:**
- Method signature
- Purpose and description
- Parameters (with types and defaults)
- Return values
- Usage examples
- Error handling

**Methods documented:**
- read_file
- write_file
- create_file
- delete_file
- list_dir
- file_search
- grep_search
- replace_string
...and 9 more

**Format:**
Markdown with code examples, tables for parameters, and practical usage scenarios.

Would you like me to generate similar documentation for other modules?
```

### Example 5: Multi-Step Analysis

**Security audit:**

```
YOU: Analyze the codebase for potential security issues: SQL injection, command injection, and insecure file operations

SYSTEM: [file_operations] - Searching for SQL patterns
SYSTEM: [file_operations] - Reading lib/CLIO/Database/*.pm (3 files)
SYSTEM: [file_operations] - Searching for exec/system patterns
SYSTEM: [file_operations] - Reading lib/CLIO/Tools/TerminalOperations.pm
SYSTEM: [file_operations] - Searching for file operation patterns
SYSTEM: [file_operations] - Reading lib/CLIO/Tools/FileOperations.pm

CLIO: Security audit complete. Here's what I found:

**SQL Injection: ✅ SAFE**
All database queries use parameterized statements via prepare/execute.
No string concatenation in SQL found.

**Command Injection: ⚠️ NEEDS ATTENTION**
Found 3 instances where user input is passed to exec without sanitization:

1. lib/CLIO/Tools/TerminalOperations.pm:145
   - `system($user_command)` with no input validation
   - **Risk:** High - arbitrary command execution
   - **Fix:** Use IPC::Run or validate input against whitelist

**File Operations: ✅ MOSTLY SAFE**
File operations use Path::Class and validated paths.
One minor issue:

1. lib/CLIO/Tools/FileOperations.pm:89
   - Symbolic link following not disabled
   - **Risk:** Low - potential directory traversal
   - **Fix:** Add -T check or use File::Spec->no_upwards

**Recommendations:**
1. **URGENT:** Fix command injection in TerminalOperations.pm
2. Add input validation for all user-controlled paths
3. Consider adding AppArmor/SELinux profiles for additional protection

Would you like me to implement these fixes?
```

### Example 6: Research and Analysis

**Investigating a framework:**

```
YOU: Fetch the FastAPI documentation and explain how to create a REST API endpoint

SYSTEM: [web] - Fetching https://fastapi.tiangolo.com/tutorial/first-steps/
SYSTEM: [web] - Fetching https://fastapi.tiangolo.com/tutorial/path-params/

CLIO: Based on the FastAPI documentation, here's how to create a REST API endpoint:

**Basic Endpoint:**
```python
from fastapi import FastAPI

app = FastAPI()

@app.get("/")
def read_root():
    return {"message": "Hello World"}
```

**With Path Parameters:**
```python
@app.get("/items/{item_id}")
def read_item(item_id: int, q: str = None):
    return {"item_id": item_id, "query": q}
```

**Key Concepts:**

1. **Decorator-based routing:** Use @app.get(), @app.post(), etc.
2. **Automatic validation:** Path and query parameters are type-checked
3. **JSON responses:** Return dicts/objects, FastAPI handles serialization
4. **Documentation:** Auto-generated OpenAPI/Swagger docs at /docs

**Running the server:**
```bash
uvicorn main:app --reload
```

**Path Parameters vs Query Parameters:**
- Path: `/items/5` - Required, part of URL path
- Query: `/items?q=search` - Optional, key=value after ?

Want me to create a complete example FastAPI application for you?
```

---------------------------------------------------

## Configuration

### Interactive Configuration (Recommended)

CLIO is designed to be configured **interactively** using slash commands:

**GitHub Copilot (Default):**

```bash
./clio
: /login
# Browser opens → Authorize → Done!
```

**Other Providers:**

```bash
./clio
: /api provider openai         # Set provider
: /api key YOUR_API_KEY         # Set API key
: /api model gpt-4o             # Set model (optional)
: /config save                  # Save to config file
```

**Available `/api` commands:**

```bash
/api providers                  # List all available providers
/api provider <name>            # Set current provider
/api key <key>                  # Set API key for current provider
/api model <model>              # Set model
/api models                     # List available models
```

**Available `/config` commands:**

```bash
/config show                    # Show current configuration
/config save                    # Save to ~/.clio/config.json
/config save session            # Save to current session only
```

### Debug Output (Advanced)

For advanced users, debug output can be enabled:

```bash
# Enable debug output via command-line flag
clio --debug --new

# Or with any clio command
clio --debug --resume
```

**Note:** The `--debug` flag sets `CLIO_LOG_LEVEL=DEBUG` internally.

**Session Configuration:**

```bash
# Custom session storage directory
export CLIO_SESSION_DIR="$HOME/.clio/sessions"

# Session auto-save interval (seconds)
export CLIO_AUTOSAVE_INTERVAL=60
```

**Tool Configuration:**

```bash
# Disable specific tool categories (comma-separated)
export CLIO_DISABLE_TOOLS="web,terminal"

# Enable experimental tools
export CLIO_EXPERIMENTAL=1
```

### Configuration File

CLIO can also be configured via a config file at `~/.clio/config.yaml`:

```yaml
# ~/.clio/config.yaml

ai_provider: github_copilot
model: gpt-4o

session:
  directory: ~/.clio/sessions
  autosave_interval: 60

tools:
  enabled:
    - file_operations
    - version_control
    - terminal
    - memory
    - todo
    - web
  
logging:
  level: info
  file: ~/.clio/logs/clio.log

ui:
  theme: photon
  markdown: true
  colors: true
```

**Note:** Environment variables take precedence over config file settings.

---------------------------------------------------

## Customization

### Color Styles

**Styles** control the **colors** used in CLIO's terminal output. Change styles to match your terminal's color scheme or personal preference.

**Available Commands:**

```bash
: /style list          # Show all available styles
: /style show          # Display current style name
: /style set <name>    # Switch to a different style
: /style save <name>   # Save current colors as new custom style
```

**Built-in Styles:**

| Style | Description |
|-------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `default` | Bright colors on dark background |
| `photon` | Retro BBS-inspired (cyan/magenta/green) |
| `dark` | Subdued colors for dark terminals |
| `light` | High contrast for light backgrounds |
| `slate` | Professional blue/grey retro theme |
| **Retro/Vintage** | |
| `green-screen` | Classic phosphor terminal (bright green) |
| `amber-terminal` | Warm amber CRT glow |
| `bbs-bright` | Classic BBS bright cyan |
| `retro-rainbow` | PhotonBBS multi-color palette |
| `dos-blue` | MS-DOS blue/white palette |
| `commodore-64` | Commodore 64 light blue |
| `apple-ii` | Apple II green/white |
| `vt100` | DEC VT100 terminal professional |

**Example:**

```bash
# List available styles
: /style list
Available styles:
  - default
  - photon
  - dark
  - light

# Switch to photon style
: /style set photon
Style changed to: photon

# Show current style
: /style show
Current style: photon
```

**Creating Custom Styles:**

Styles are defined in `~/.clio/styles/` directory using a simple `key=value` format:

```bash
# ~/.clio/styles/my_style.style
name=my_style

# User interaction colors
user_prompt=@BRIGHT_GREEN@
user_text=@BRIGHT_YELLOW@

# Agent colors
agent_label=@BRIGHT_BLUE@
agent_text=@WHITE@

# System messages
system_message=@BRIGHT_MAGENTA@
error_message=@BRIGHT_RED@
```

See [`styles/README.md`](../styles/README.md) for complete style file format and available color codes.

### Output Themes

**Themes** control the **structure and format** of CLIO's output. Change themes to adjust how much information is displayed.

**Available Commands:**

```bash
: /theme list          # Show all available themes
: /theme show          # Display current theme name
: /theme set <name>    # Switch to a different theme
: /theme save <name>   # Save current templates as new theme
```

**Built-in Themes:**

| Theme | Description |
|-------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `default` | Standard output with all elements visible |
| `compact` | Minimal output, fewer labels |
| `verbose` | Detailed output with extra context |

**Example:**

```bash
# Switch to compact theme for less visual noise
: /theme set compact
Theme changed to: compact

# Switch back to default
: /theme set default
```

**Creating Custom Themes:**

Themes are defined in `~/.clio/themes/` directory using template format with placeholders:

```bash
# ~/.clio/themes/my_theme.theme
name=my_theme

# Prompts
user_prompt_format={style.user_prompt}> @RESET@
agent_prefix={style.agent_label}AI: @RESET@

# Banner
banner_line1={style.banner}CLIO@RESET@
```

Themes use placeholders:
- `{style.key}` - Replaced with color codes from current style
- `{var.key}` - Replaced with runtime values (session_id, model, etc.)

See [`themes/README.md`](../themes/README.md) for complete theme file format and available placeholders.

---------------------------------------------------

## Skills

Skills are specialized prompt templates that give CLIO expertise in specific tasks. They provide structured instructions for common workflows like code review, testing, and documentation.

### Viewing Available Skills

```bash
: /skills                    # List all skills (built-in and custom)
: /skills show <name>        # Display skill details
```

**Built-in Skills:**
| Skill | Description |
|-------|-------------|
| `explain` | Explain selected code |
| `review` | Review code for issues |
| `test` | Generate comprehensive tests |
| `fix` | Propose fixes for problems |
| `doc` | Generate documentation |
| `design` | Create a Product Requirements Document (PRD) |
| `init` | Initialize CLIO for a project |

### Using Skills

```bash
: /skills use explain lib/MyModule.pm     # Explain code in a file
: /skills use review src/auth.py          # Review code for issues
: /skills use test controllers/user.rb    # Generate tests
```

### Skills Catalog

CLIO includes a curated skills catalog you can browse and install:

```bash
: /skills search              # Browse all available skills
: /skills search perl         # Search for specific skills
: /skills install <name>      # Install a skill
```

**Installing Skills:**
1. Run `/skills search` to see available skills
2. Run `/skills install <name>` to preview and install
3. Review the skill content before confirming installation
4. Use with `/skills use <name>`

### Custom Skills

Create your own skills:

```bash
: /skills add my-skill "Review code for ${lang} best practices: ${code}"
```



### System Prompts

System prompts define CLIO's base behavior and personality. You can customize them per project.

**Viewing Prompts:**
```bash
: /prompt                    # Show prompt status
: /prompt show               # Display full active prompt
: /prompt list               # List all available prompts
```

**Switching Prompts:**
```bash
: /prompt set <name>         # Switch to named prompt
: /prompt reset              # Reset to default
```

**Custom Prompts:**
```bash
: /prompt edit <name>        # Edit in $EDITOR
: /prompt save <name>        # Save current as new
: /prompt delete <name>      # Delete custom prompt
```

**Per-Project Instructions:**
Create `.clio/instructions.md` in your project root. This content is automatically appended to the system prompt when working in that directory.

Variables in `${brackets}` are replaced when the skill is executed.

---------------------------------------------------

## Tips & Best Practices

### Effective Prompting

**Be Specific:**
```
❌ "Fix the code"
✅ "In auth.pm, add input validation to the login function to prevent SQL injection"
```

**Provide Context:**
```
❌ "Update the config"
✅ "In config.yaml, change the database connection pool size from 10 to 20 to handle increased load"
```

**Multi-Step Requests:**
```
✅ "Create a new branch called feature/api-v2, refactor the API endpoints in lib/API.pm to use FastAPI instead of Flask, and commit the changes"
```

CLIO handles multi-step workflows naturally. Don't break them down unless you need to review intermediate steps.

### Using Sessions Effectively

**Name Your Sessions Mentally:**
As you work, think of each session as having a purpose:
- "Refactoring auth module session"
- "Bug investigation session"
- "Documentation writing session"

While CLIO doesn't have custom session names (they're timestamped), mentally organizing your sessions helps you remember which one to resume.

**Resume Recent Work:**
```bash
# Quick resume (most recent)
clio --resume

# Resume specific date/time
clio --resume sess_20260118_143052
```

**Clean Up Old Sessions:**
```bash
# Sessions are in sessions/ directory
ls -lt sessions/ | head -20  # See recent sessions
rm sessions/sess_2026011*.json  # Delete old sessions
```

### Managing Complex Tasks

**Use Todo Lists:**
```
YOU: Create a todo list for this refactoring project with these tasks:
1. Read and understand current authentication flow
2. Design new JWT-based auth system
3. Implement token generation and validation
4. Update all API endpoints to use new auth
5. Write tests for auth system
6. Update documentation

...

YOU: Mark task 1 as complete

...

YOU: What's next on the list?
```

**Break Down Large Changes:**
For complex refactoring, ask CLIO to show you the plan first:
```
YOU: I want to refactor the database layer to use an ORM. Show me a plan for how to do this without breaking existing code.

[CLIO provides plan]

YOU: Good, let's implement step 1 first.
```

### Code Review with CLIO

**Before Committing:**
```
YOU: Review my changes before I commit. Look for:
- Potential bugs
- Security issues
- Code style violations
- Missing error handling

SYSTEM: [git] - Executing git diff
SYSTEM: [file_operations] - Reading modified files

CLIO: I reviewed your changes. Here's what I found:

**Potential Issues:**
1. auth.pm:45 - Missing error handling for database connection failure
2. api.pm:123 - Race condition in session creation (not thread-safe)

**Code Style:**
1. Inconsistent indentation in auth.pm (mix of tabs and spaces)
2. Missing POD documentation for new subroutines

**Security:**
1. ✅ Input validation present
2. ✅ SQL injection protected (parameterized queries)
3. ⚠️ Consider adding rate limiting to login endpoint

**Recommendation:** Fix the error handling and race condition before committing.
```

### Debugging with CLIO

**Trace Execution:**
```
YOU: Help me debug why the authentication is failing. Trace the code execution from login endpoint to database query.

SYSTEM: [file_operations] - Reading lib/API/Auth.pm
SYSTEM: [file_operations] - Reading lib/Database/Users.pm
SYSTEM: [file_operations] - Reading lib/Session/Manager.pm

CLIO: Here's the execution flow and where the issue likely is:

1. **API/Auth.pm:login()** (line 45)
   - Receives username/password from request
   - Validates input format ✅
   - Calls Database::Users->authenticate()

2. **Database/Users.pm:authenticate()** (line 89)
   - Queries database for user
   - **❌ ISSUE:** Password comparison uses `eq` instead of secure compare
   - Returns user object if match

3. **Session/Manager.pm:create_session()** (line 156)
   - Creates new session
   - Stores in session table
   - Returns session token

**The Problem:**
Line 89 in Database/Users.pm uses simple string comparison (`eq`) which is:
1. Vulnerable to timing attacks
2. Not comparing hashed passwords properly

**The Fix:**
Use Digest::SHA and constant-time comparison.

Would you like me to implement the fix?
```

### Keyboard Shortcuts

**In Chat:**
- `Ctrl+D` or type `exit` - End session
- `Ctrl+C` - Cancel current AI response
- `?` - Show help (when implemented)
- `Up/Down Arrow` - History navigation (terminal-dependent)

**Command Line:**
```bash
# Quick access
alias c='clio --resume'     # Resume last session
alias cn='clio --new'        # New session
alias cd='clio --debug'      # Debug mode
```

### Terminal Tips

**Use a Good Terminal Emulator:**
- **macOS:** iTerm2 (better than default Terminal.app)
- **Linux:** GNOME Terminal, Konsole, Alacritty
- **Windows:** Windows Terminal with WSL

**Terminal Settings:**
- Enable 256-color support for best markdown rendering
- Use a monospace font with good Unicode support (FiraCode, JetBrains Mono)
- Set scroll back buffer to at least 10,000 lines

**Tmux/Screen Integration:**
CLIO works great in tmux or screen for persistent sessions:
```bash
# In tmux
tmux new -s clio
clio --resume

# Detach: Ctrl+B, D
# Reattach: tmux attach -t clio
```

---------------------------------------------------

## Troubleshooting

### Installation Issues

**Problem: "perl: command not found"**

Perl is not installed or not in PATH.

**Solution:**
```bash
# macOS
brew install perl

# Ubuntu/Debian
sudo apt-get install perl

# Verify
perl --version
```

**Problem: "Can't locate CLIO/Core/Main.pm"**

Library path not set correctly.

**Solution:**
```bash
# Reinstall to ensure paths are set
sudo ./install.sh

# Or set PERL5LIB manually
export PERL5LIB=/usr/local/lib/clio/lib:$PERL5LIB
```

**Problem: "Permission denied"**

Installation requires sudo for system directories.

**Solution:**
```bash
sudo ./install.sh
```

### API/Token Issues

**Problem: "API authentication failed"**

GitHub Copilot authentication failed or not configured.

**Solution:**
```bash
# Start CLIO and login
./clio
: /login
# Follow browser prompts

# Or check if you have saved tokens
ls ~/.clio/github_tokens.json

# For other providers, use /api commands
: /api provider openai
: /api key YOUR_KEY
: /config save
```

**Problem: "Rate limit exceeded"**

Too many API requests in short time.

**Solution:**
Wait a few minutes, or use a different AI provider if available.

### Session Issues

**Problem: "Session file corrupt"**

Session JSON file is malformed.

**Solution:**
```bash
# Check session file
cat sessions/sess_20260118_143052.json | python -m json.tool

# If corrupt, delete and start new
rm sessions/sess_20260118_143052.json
clio --new
```

**Problem: "Cannot resume session"**

Session ID doesn't exist.

**Solution:**
```bash
# List available sessions
ls sessions/

# Resume with correct ID
clio --resume sess_YYYYMMDD_HHMMSS
```

### Output/Display Issues

**Problem: "Garbled output / weird characters"**

Terminal doesn't support ANSI codes or UTF-8.

**Solution:**
```bash
# Check terminal type
echo $TERM

# Should be xterm-256color or similar
# If not, set it:
export TERM=xterm-256color

# Verify UTF-8
locale | grep UTF-8

# If not UTF-8:
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
```

**Problem: "No colors in output"**

ANSI colors disabled or not supported.

**Solution:**
- Use a better terminal emulator (see Tips section)
- Check if colors are disabled: `export CLIO_NO_COLOR=0`
- Try different theme: Edit `~/.clio/config.yaml`

### Performance Issues

**Problem: "CLIO is slow to respond"**

Network latency to AI provider API.

**Solution:**
- Check internet connection
- Try different AI provider
- Use `--debug` to see where time is spent

**Problem: "High memory usage"**

Large session history or file operations.

**Solution:**
```bash
# Start new session to clear memory
clio --new

# Or clean up old sessions
rm sessions/sess_2025*.json  # Delete old sessions
```

### Tool Issues

**Problem: "File operation failed"**

Permission denied or file doesn't exist.

**Solution:**
Check file permissions and paths. CLIO runs with your user privileges:
```bash
# Check permissions
ls -la /path/to/file

# If permission issue, fix it:
chmod 644 /path/to/file
```

**Problem: "Git operation failed"**

Not in a git repository or git not installed.

**Solution:**
```bash
# Verify git is installed
git --version

# Verify you're in a git repo
git status

# If not, initialize:
git init
```

---------------------------------------------------

## FAQ

### General Questions

**Q: Is CLIO free?**

A: CLIO itself is open-source and free (GPL v3). However, you need an AI provider subscription (GitHub Copilot or Qwen) which have their own pricing.

**Q: Does CLIO work offline?**

A: No, CLIO requires an internet connection to communicate with AI provider APIs. However, session data is stored locally.

**Q: Can I use CLIO with ChatGPT/Claude directly?**

A: Not currently. CLIO supports GitHub Copilot (which provides access to GPT-4o and Claude 3.5) and Qwen. Support for other providers may be added in the future.

**Q: Is CLIO safe to use with sensitive code?**

A: CLIO only sends context to the AI provider that's necessary for the current request. However, this means code snippets and file contents are sent to third-party APIs. Review your organization's policies before using with proprietary code.

### Feature Questions

**Q: Can CLIO write entire applications for me?**

A: CLIO is a tool to *assist* development, not replace it. It can:
- Generate boilerplate code
- Refactor existing code
- Write documentation
- Debug issues
- Answer questions

But you should review all changes and understand what CLIO does.

**Q: Does CLIO learn from my code?**

A: Not within CLIO itself. The AI providers (GitHub Copilot, Qwen) may use interactions for improvement depending on their policies. CLIO's memory system stores information you explicitly ask it to remember.

**Q: Can CLIO work with multiple programming languages?**

A: Yes! CLIO works with any text-based files and languages. It has been tested with Perl, Python, JavaScript, Ruby, Go, C, C++, Java, and many others.

**Q: Can multiple people share sessions?**

A: Not directly. Sessions are stored as local JSON files. However, you could share session files between machines manually, though this isn't officially supported.

### Technical Questions

**Q: What AI models does CLIO use?**

A: Through GitHub Copilot: GPT-4o, Claude 3.5 Sonnet, and o1 models. Through Qwen: Qwen-coder models.

**Q: How much does API usage cost?**

A: This depends on your AI provider subscription:
- GitHub Copilot: ~$10-20/month (individual/business)
- Qwen: Pay-as-you-go pricing

CLIO itself doesn't add any costs.

**Q: Can I add custom tools to CLIO?**

A: Yes! See [docs/DEVELOPER_GUIDE.md](DEVELOPER_GUIDE.md) for information on extending CLIO with custom tools.

**Q: Does CLIO support Windows?**

A: CLIO should work on Windows with WSL (Windows Subsystem for Linux) or Cygwin, but it's primarily developed and tested on macOS and Linux.

### Workflow Questions

**Q: Should I use CLIO or a GUI AI assistant?**

A: Use CLIO if:
- You prefer terminal workflows
- You want file/git/terminal integration
- You value session persistence
- You want transparent tool execution

Use GUI assistant if:
- You prefer visual interfaces
- You primarily need conversation, not tool integration

**Q: Can I use CLIO for non-coding tasks?**

A: Yes! CLIO can:
- Write documentation
- Research topics (web fetch)
- Manage todos
- Store notes (memory system)
- Analyze text files

**Q: How do I switch between AI providers?**

A: Use `/api` commands:
```bash
# Switch to OpenAI
: /api provider openai
: /api key YOUR_OPENAI_KEY
: /config save

# Switch to DeepSeek
: /api provider deepseek
: /api key YOUR_DEEPSEEK_KEY
: /config save

# Switch back to GitHub Copilot
: /api provider github_copilot
# (uses saved token from /login)
unset GITHUB_COPILOT_TOKEN
```

CLIO automatically detects which provider to use based on available credentials.

---------------------------------------------------

## Next Steps

**Explore More:**
- [Developer Guide](DEVELOPER_GUIDE.md) - Learn to extend CLIO
- [Architecture](SPECS/ARCHITECTURE.md) - Understand how CLIO works
- [Tools Reference](SPECS/TOOLS.md) - Complete tool documentation

**Get Help:**
- [GitHub Issues](https://github.com/fewtarius/clio/issues)
- [GitHub Discussions](https://github.com/fewtarius/clio/discussions)

**Contribute:**
See [DEVELOPER_GUIDE.md](DEVELOPER_GUIDE.md) for contribution guidelines.

---------------------------------------------------

**Happy coding with CLIO!**
