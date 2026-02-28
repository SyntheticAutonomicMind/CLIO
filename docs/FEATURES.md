# CLIO Feature Guide

**The complete guide to everything CLIO can do.**

CLIO is a terminal-native AI coding assistant built in Perl. It uses less than 100MB of RAM, runs on everything from a RISC-V single-board computer to a full workstation, and requires zero external runtime dependencies beyond Perl and standard Unix tools.

This guide covers every feature, how the components work together, and how to get the most out of CLIO.

---

## Table of Contents

1. [The AI Agent](#1-the-ai-agent)
2. [Tools](#2-tools)
3. [AI Providers](#3-ai-providers)
4. [Session Management](#4-session-management)
5. [Memory System](#5-memory-system)
6. [Context Management](#6-context-management)
7. [Slash Commands](#7-slash-commands)
8. [Hashtag Context Injection](#8-hashtag-context-injection)
9. [Custom Instructions](#9-custom-instructions)
10. [Skills System](#10-skills-system)
11. [Multi-Agent Coordination](#11-multi-agent-coordination)
12. [Remote Execution](#12-remote-execution)
13. [MCP Integration](#13-mcp-integration)
14. [Security](#14-security)
15. [Themes and Styles](#15-themes-and-styles)
16. [Protocols](#16-protocols)
17. [Undo System](#17-undo-system)
18. [Billing and Usage Tracking](#18-billing-and-usage-tracking)
19. [How It All Comes Together](#19-how-it-all-comes-together)

---

## 1. The AI Agent

At its core, CLIO is an autonomous AI agent. You give it a task - "fix the bug in login.pm", "add tests for the parser", "refactor the database module" - and it works through it end-to-end. It reads code, makes changes, runs tests, commits results, and iterates on errors until the job is done.

### How the Agent Works

When you type a message, CLIO sends it to an AI model along with:
- A **system prompt** that defines CLIO's behavior and capabilities
- Your **conversation history** (what you've discussed so far)
- **Tool definitions** describing what CLIO can do (read files, run commands, etc.)
- **Custom instructions** from your project (if configured)
- **Long-term memory** (discoveries and patterns from previous sessions)

The AI responds with either a text message or **tool calls** - requests to perform actions. CLIO executes each tool call, feeds the results back to the AI, and the cycle continues until the AI has a complete answer.

```
You type a message
    |
    v
CLIO builds context (system prompt + history + tools + memory)
    |
    v
AI decides what to do
    |
    +--> Text response --> Displayed to you
    |
    +--> Tool calls --> CLIO executes them
                            |
                            v
                        Results sent back to AI
                            |
                            v
                        AI decides next step (more tools, or respond)
```

A single request might involve dozens of tool calls - reading files, searching code, making edits, running tests - all handled autonomously.

### Streaming Output

Responses stream in real-time, token by token. You see the AI "thinking" as it types. Tool operations show live action descriptions so you know exactly what's happening.

### Iteration and Error Recovery

When something goes wrong - a syntax error, a failed test, an unexpected file structure - CLIO doesn't stop. It reads the error, adjusts its approach, and tries again. This continues for up to 500 iterations per request (configurable), ensuring complex tasks can be completed without manual intervention.

---

## 2. Tools

Tools are CLIO's hands and eyes. They let the AI interact with your filesystem, terminal, version control, and more. CLIO has 13 built-in tools with over 70 operations between them.

### File Operations

The most-used tool. 17 operations for working with files:

| Operation | What It Does |
|-----------|-------------|
| `read_file` | Read a file's content (with optional line range) |
| `write_file` | Overwrite an existing file |
| `create_file` | Create a new file |
| `append_file` | Add content to the end of a file |
| `replace_string` | Find and replace text in a file |
| `multi_replace_string` | Batch replacements across multiple files |
| `insert_at_line` | Insert content at a specific line number |
| `delete_file` | Delete a file or directory |
| `rename_file` | Move or rename a file |
| `create_directory` | Create a directory (with parents) |
| `list_dir` | List directory contents (optionally recursive) |
| `file_exists` | Check if a file or directory exists |
| `get_file_info` | Get file metadata (size, type, modified time) |
| `get_errors` | Get compilation/lint errors for a Perl file |
| `file_search` | Find files matching a glob pattern |
| `grep_search` | Search file contents with text or regex |
| `semantic_search` | Hybrid keyword + symbol search across the codebase |

**Semantic search** is particularly powerful - it understands code structure. Asking "where is authentication implemented" will find relevant files even if they don't contain the word "authentication."

### Version Control (Git)

A dedicated git tool with 10 operations - not just "run git via shell" but structured operations with proper output parsing:

| Operation | What It Does |
|-----------|-------------|
| `status` | Repository status and changes |
| `log` | Commit history |
| `diff` | Differences between commits or working tree |
| `branch` | List, create, switch, or delete branches |
| `commit` | Create commits with messages |
| `push` | Push to remote |
| `pull` | Pull from remote |
| `blame` | File annotation/blame |
| `stash` | Save, list, apply, or drop stashed changes |
| `tag` | List, create, or delete tags |

### Terminal Operations

Execute shell commands with safety validation and timeout protection. CLIO can run build commands, test suites, linters, or any other shell command your workflow requires.

Commands are validated before execution. Output is captured and returned to the AI for analysis.

### Apply Patch

A lightweight diff-based tool for efficient multi-file changes. Instead of rewriting entire files, CLIO can apply surgical patches:

```
*** Update File: lib/auth.pm
@@ sub validate_token
-    return 0 if !$token;
+    return 0 if !$token || length($token) < 10;
```

This is more efficient than full file rewrites and produces cleaner diffs.

### Code Intelligence

Two specialized operations for understanding code:

- **list_usages** - Find all references to a symbol across the codebase
- **search_history** - Semantic search through git commit messages (e.g., "when did we fix the login bug?")

### Web Operations

- **fetch_url** - Retrieve content from any URL
- **search_web** - Web search via SerpAPI or DuckDuckGo

Useful for looking up documentation, checking API references, or researching solutions.

### Memory Operations

Store and recall information within and across sessions. See the [Memory System](#5-memory-system) section for details.

### Todo Operations

Track multi-step tasks with status, priorities, and dependencies. See [Session Management](#4-session-management).

### User Collaboration

A structured way for the AI to ask you questions or present options during a task. Instead of stopping work entirely, CLIO can checkpoint its progress, ask a specific question, and continue based on your answer.

### Sub-Agent Operations

Spawn additional AI agents to work in parallel. See [Multi-Agent Coordination](#11-multi-agent-coordination).

### Remote Execution

Run CLIO on remote machines via SSH. See [Remote Execution](#12-remote-execution).

### MCP Bridge

Connect to external tool servers via the Model Context Protocol. See [MCP Integration](#13-mcp-integration).

---

## 3. AI Providers

CLIO supports 9 AI providers out of the box. Switch between them at any time - even mid-session.

| Provider | Type | Authentication |
|----------|------|---------------|
| **GitHub Copilot** | Cloud | GitHub OAuth (device flow) |
| **OpenAI** | Cloud | API key |
| **Anthropic** | Cloud | API key |
| **Google Gemini** | Cloud | API key |
| **DeepSeek** | Cloud | API key |
| **OpenRouter** | Cloud | API key |
| **llama.cpp** | Local | None |
| **LM Studio** | Local | None |
| **SAM** | Local | API key (optional) |

### Switching Providers

```
/api set provider openai
/api set key sk-your-key-here
/config save
```

Or within a conversation:
```
/api provider github_copilot
```

### GitHub Copilot Setup

GitHub Copilot is the recommended provider. Authentication uses a secure device flow:

```
/api login
```

This opens a browser for GitHub authorization. Once authenticated, tokens are managed automatically - including refresh when they expire.

### Model Selection

Each provider offers multiple models. CLIO automatically queries available models:

```
/api models              # List available models
/api set model gpt-4.1   # Switch to a specific model
```

### Local Models

For complete privacy, use local providers (llama.cpp, LM Studio, SAM). Your data never leaves your machine. Local models work with smaller context windows, so CLIO automatically adjusts its trimming thresholds.

---

## 4. Session Management

Every conversation in CLIO is a **session**. Sessions persist to disk automatically, so you can close CLIO and pick up exactly where you left off.

### Session Basics

```bash
clio --new              # Start a new session
clio --resume           # Resume the most recent session
clio --session <id>     # Resume a specific session
```

### Session Commands

| Command | What It Does |
|---------|-------------|
| `/session list` | Show all saved sessions |
| `/session switch <id>` | Switch to a different session |
| `/session rename <name>` | Give the current session a friendly name |
| `/session delete <id>` | Delete a session |
| `/session info` | Show current session details |
| `/session export` | Export session data |

### What's Saved

Sessions persist:
- Complete conversation history (every message, tool call, and result)
- Todo list state
- Session metadata (creation time, model used, message count)

### Session State Repair

If a session file gets corrupted (e.g., from a crash), CLIO automatically detects and repairs common issues like orphaned tool calls, malformed JSON, and inconsistent message ordering.

### Todo Tracking

The AI uses todo lists to track progress on multi-step tasks:

```
/todo                    # Show current todo list
/todo add "Fix tests"    # Add a task manually
```

Todos have statuses (not-started, in-progress, completed, blocked), priorities (low/medium/high/critical), and descriptions. The AI updates them as it works.

---

## 5. Memory System

CLIO has a three-tier memory system that gives it continuity across sessions.

### Short-Term Memory

Key-value storage within a session. The AI stores temporary notes, investigation findings, and working data:

```
# AI calls internally:
memory_operations(operation: "store", key: "auth_bug_root_cause", content: "Missing null check in token validation")
memory_operations(operation: "retrieve", key: "auth_bug_root_cause")
```

### Long-Term Memory (LTM)

Persistent knowledge that survives across sessions. Three types:

| Type | Purpose | Example |
|------|---------|---------|
| **Discoveries** | Facts about the codebase | "Config files are stored in ~/.clio/" |
| **Solutions** | Problem-fix pairs | "If JSON parse fails, check for BOM characters" |
| **Patterns** | Coding conventions | "Always use atomic writes for session files" |

LTM entries have confidence scores (0.0-1.0) that increase when patterns are confirmed and decrease with age. Low-confidence entries are automatically pruned.

**Every new session starts with your project's LTM automatically injected** into the system prompt. This means the AI remembers what it learned last time without you having to explain it again.

### Cross-Session Recall

Search through previous session transcripts:

```
# AI calls internally:
memory_operations(operation: "recall_sessions", query: "authentication refactor")
```

This finds relevant conversations from past sessions, even if the current session has no direct context.

### Memory Commands

```
/memory list             # Show stored memories
/memory search <query>   # Search memory
/memory stats            # LTM statistics
/memory prune            # Clean up old/low-confidence entries
```

---

## 6. Context Management

CLIO manages a limited context window (the amount of conversation the AI can "see" at once). This is critical for long sessions.

### Three-Layer Trimming

1. **Proactive trimming** - Before each API call, CLIO estimates token usage and trims older messages if approaching 58% of the model's context window. This preserves the most recent and most important messages.

2. **Validation trimming** - Just before sending to the API, messages are validated for token limits with smart unit-based truncation. Dropped messages are compressed into a summary.

3. **Reactive trimming** - If the API returns a token limit error despite proactive trimming, CLIO progressively trims (50%, then 25%, then minimal) and creates a compressed summary of what was dropped, including the current task state.

### What Gets Preserved

When trimming is needed, CLIO prioritizes:
- **System prompt** (always kept)
- **First user message** (the original task - scored at maximum importance)
- **Recent messages** (most recent context)
- **Tool call/result pairs** (kept together to avoid orphans)
- **High-importance messages** (those containing error, bug, fix, critical keywords)

### Context Recovery

When aggressive trimming occurs, CLIO injects a recovery context that includes:
- A summary of dropped messages (user requests, tool operations, key events)
- The current todo/task state (what the AI was working on)
- The most recent user requests from the dropped portion

This prevents the AI from losing track of what it was doing during long sessions.

### Token Estimation

CLIO estimates token counts using a learned character-to-token ratio that calibrates itself against actual API responses over time.

---

## 7. Slash Commands

CLIO has 40+ slash commands organized by category. Type `/help` for the full list.

### Core Commands

| Command | Description |
|---------|-------------|
| `/help` | Show all commands |
| `/exit` | Exit CLIO |
| `/clear` | Clear the screen |
| `/reset` | Reset terminal to known-good state |
| `/debug` | Toggle debug mode |
| `/shell` | Open an interactive shell |
| `/multi-line` | Enter multi-line input mode |

### AI-Powered Commands

These send structured prompts to the AI:

| Command | Description |
|---------|-------------|
| `/explain <file>` | Explain what a file does |
| `/review <file>` | Code review a file |
| `/test <file>` | Generate tests for a file |
| `/fix <file>` | Fix issues in a file |
| `/doc <file>` | Generate documentation for a file |

### Provider Commands

| Command | Description |
|---------|-------------|
| `/api login` | Authenticate with GitHub Copilot |
| `/api logout` | Remove authentication |
| `/api set provider <name>` | Switch AI provider |
| `/api set model <name>` | Switch AI model |
| `/api set key <key>` | Set API key |
| `/api models` | List available models |
| `/api status` | Show current provider status |

### Session Commands

| Command | Description |
|---------|-------------|
| `/session list` | List all sessions |
| `/session switch <id>` | Switch session |
| `/session rename <name>` | Rename session |
| `/session delete <id>` | Delete session |
| `/session info` | Current session info |

### Configuration

| Command | Description |
|---------|-------------|
| `/config` | Show current configuration |
| `/config set <key> <value>` | Set a config value |
| `/config save` | Save config to disk |
| `/theme <name>` | Switch color theme |
| `/style <name>` | Switch UI style |
| `/loglevel <level>` | Set logging level |

### Git Commands

| Command | Description |
|---------|-------------|
| `/git status` | Repository status |
| `/git diff` | Show changes |
| `/git log` | Commit history |
| `/git commit <message>` | Create a commit |

### Project Commands

| Command | Description |
|---------|-------------|
| `/init` | Initialize project instructions |
| `/design` | Start a design/PRD session |
| `/skills` | Manage reusable prompt templates |

### Other Commands

| Command | Description |
|---------|-------------|
| `/todo` | View/manage todo list |
| `/billing` | Token usage and costs |
| `/memory` | Memory system management |
| `/context` | Context window info |
| `/stats` | Session statistics |
| `/undo` | Revert last AI changes |
| `/update` | Check for CLIO updates |
| `/log` | View session log |
| `/device` | Manage remote devices |
| `/agent` | Multi-agent commands |
| `/mcp` | MCP server management |
| `/prompt` | View/edit system prompt |
| `/performance` | Performance stats |

---

## 8. Hashtag Context Injection

Hashtags let you inject file contents, directory structures, or other context directly into your messages.

### Available Hashtags

| Hashtag | What It Does | Example |
|---------|-------------|---------|
| `#file:path` | Inject a file's contents | `Explain #file:lib/auth.pm` |
| `#folder:path` | Inject a directory listing | `What's in #folder:lib/` |
| `#codebase` | Inject the full repository structure | `Review #codebase for issues` |
| `#selection` | Inject current text selection | `Fix #selection` |
| `#terminalLastCommand` | Inject last terminal command output | `Explain #terminalLastCommand` |
| `#terminalSelection` | Inject terminal selection | `What does #terminalSelection mean?` |

### Token Budgeting

Hashtag context is subject to a 32,000-token budget. If you inject a very large file or codebase, CLIO automatically truncates to fit within the budget while preserving the most important content.

### How It Works

When you type `Explain #file:lib/auth.pm`, CLIO:
1. Parses the hashtag from your message
2. Reads the file content
3. Injects it as context alongside your message
4. Sends both to the AI

The AI sees the full file content in its context and can reference it directly.

---

## 9. Custom Instructions

Every project can have custom instructions that tell CLIO how to work with that specific codebase.

### Two Instruction Sources

1. **`.clio/instructions.md`** - CLIO-specific instructions
2. **`AGENTS.md`** - Universal AI agent instructions (works with Cursor, Copilot, etc.)

Both are automatically loaded when you start a session in that directory. They're merged and injected into the system prompt.

### What to Put in Instructions

- Code style preferences (indentation, naming conventions)
- Testing requirements (frameworks, coverage expectations)
- Project architecture notes
- Workflow preferences (commit message format, branch strategy)
- Technology constraints (language version, dependency policies)

### Setup

```bash
mkdir -p .clio
cat > .clio/instructions.md << 'EOF'
# Project Instructions

## Code Style
- Use 4 spaces for indentation
- Follow PEP 8 naming conventions

## Testing
- All new code must have tests
- Run `pytest` before committing

## Commit Format
- Use conventional commits: type(scope): description
EOF
```

Or use the `/init` command to have the AI generate instructions based on your codebase analysis.

---

## 10. Skills System

Skills are reusable prompt templates. Instead of typing the same complex instructions repeatedly, save them as skills and invoke them by name.

### Managing Skills

```
/skills list             # Show all skills
/skills add              # Create a new skill
/skills delete <name>    # Remove a skill
/skills run <name>       # Execute a skill
```

### Variable Substitution

Skills support variables that get replaced at execution time:

```markdown
# Skill: code-review
Review {{file}} for:
- Security vulnerabilities
- Performance issues
- Code style violations

Provide fixes for each issue found.
```

When you run `/skills run code-review`, CLIO prompts you for `{{file}}` and substitutes your answer.

### Built-in vs Custom

Skills are stored per-project in `.clio/skills/`. You can share them across teams by committing the skills directory.

---

## 11. Multi-Agent Coordination

CLIO can spawn sub-agents - independent AI processes that work in parallel on different tasks.

### How It Works

```
You: Spawn two agents - one to write tests for auth.pm and one to update the documentation

CLIO spawns:
  Agent 1: Writing tests for auth.pm
  Agent 2: Updating documentation

Both work simultaneously, sending progress messages back to your session.
```

### Coordination Features

Sub-agents aren't just independent processes - they coordinate:

- **File locks** prevent two agents from editing the same file simultaneously
- **Git locks** serialize commit operations to prevent conflicts
- **API rate limiting** is shared across all agents to stay within provider limits
- **Message bus** lets agents communicate (questions, status updates, completions)

### Agent Commands

```
/agent list              # Show running agents
/agent status <id>       # Detailed agent info
/agent send <id> <msg>   # Send guidance to an agent
/agent kill <id>          # Terminate an agent
/agent killall           # Terminate all agents
```

### Agent Lifecycle

1. Main session spawns agents with specific tasks
2. Each agent runs as a separate process with its own AI session
3. Agents poll an inbox for messages and send updates back
4. When complete, agents report results
5. Main session verifies the work

---

## 12. Remote Execution

CLIO can SSH into remote machines, deploy itself, run an AI task, and return the results.

### Basic Usage

The AI handles this automatically when you ask it to work on remote systems:

```
You: Check disk usage on staging-server and clean up old logs

CLIO:
  1. SSHs into staging-server
  2. Copies itself to the remote machine
  3. Runs the task with a remote AI agent
  4. Returns the results
  5. Cleans up after itself
```

### Device Registry

Register named devices for quick access:

```
/device add staging user@staging.example.com
/device add prod user@prod.example.com
/device list
```

### Device Groups

Group devices for parallel execution:

```
/group create webservers staging prod
```

Now you can run tasks across all web servers simultaneously:

```
You: Check the nginx config on all webservers
```

### Parallel Execution

The `execute_parallel` operation runs the same task on multiple devices at once and aggregates results.

### Security

- API keys are passed as environment variables, never written to disk on remote systems
- CLIO is cleaned up from remote systems after execution by default
- SSH key authentication is supported

---

## 13. MCP Integration

The [Model Context Protocol](https://modelcontextprotocol.io) (MCP) lets CLIO connect to external tool servers. This extends CLIO's capabilities beyond its built-in tools.

### What MCP Provides

MCP servers can offer:
- Database access tools
- API integration tools
- Specialized analysis tools
- Custom workflow tools

### Configuration

Add MCP servers to `.clio/mcp.json`:

```json
{
  "mcpServers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/path/to/files"]
    }
  }
}
```

### Management Commands

```
/mcp status              # Show connected MCP servers
/mcp add <name> <cmd>    # Add a new MCP server
/mcp remove <name>       # Remove an MCP server
```

### How It Works

CLIO connects to MCP servers via stdio or HTTP transport. Tools from MCP servers are automatically discovered and made available to the AI as `mcp_<server>_<tool>`. The AI can use them just like built-in tools.

---

## 14. Security

### Path Authorization

CLIO sandboxes file operations to the working directory by default. The AI can't read or write files outside your project unless explicitly allowed.

Configuration options:
- **Sandbox mode** - Strict restriction to working directory
- **Auto-approve** - Allow all paths (default for convenience)
- **Per-path rules** - Allow or deny specific paths

See [docs/SANDBOX.md](SANDBOX.md) for details.

### Secret Redaction

CLIO automatically detects and redacts sensitive information from tool output before it's displayed or sent to AI providers. The `SecretRedactor` intercepts all tool results at the `ToolExecutor` level, so secrets are caught regardless of which tool produced them.

#### Redaction Levels

| Level | PII | Private Keys | DB Passwords | API Keys | Tokens |
|-------|-----|-------------|-------------|----------|--------|
| **strict** | Redact | Redact | Redact | Redact | Redact |
| **standard** | Redact | Redact | Redact | Redact | Redact |
| **api_permissive** | Redact | Redact | Redact | Allow | Allow |
| **pii** (default) | Redact | - | - | - | - |
| **off** | - | - | - | - | - |

- **strict / standard** - Redact everything: PII, cryptographic material, API keys, and tokens. Recommended for most use cases.
- **api_permissive** - Allow API keys and tokens through (useful when the AI legitimately needs to work with them), but still redact PII and cryptographic material.
- **pii** (default) - Only redact personally identifiable information: SSN, credit cards, phone numbers, email addresses, UK National Insurance numbers.
- **off** - No redaction. Use with caution.

#### What's Detected

Four pattern categories, each with multiple specific patterns:

- **PII** - Email addresses, US Social Security numbers, US phone numbers, credit card numbers, UK National Insurance numbers
- **Cryptographic material** - PEM-encoded private keys (RSA, DSA, EC, OpenSSH), database connection strings with passwords (PostgreSQL, MySQL, MongoDB, Redis, ODBC), password assignments
- **API keys** - AWS access keys and secrets, GitHub tokens (PAT, OAuth, fine-grained), Stripe keys, Google Cloud API keys, OpenAI keys, Anthropic keys, Slack tokens/webhooks, Discord tokens/webhooks, Twilio SIDs, and generic key/secret assignment patterns
- **Tokens** - JWT tokens, Bearer authorization headers, Basic auth headers

#### Configuration

```
/config set redact_level standard    # Redact everything
/config set redact_level pii         # Only PII (default)
/config set redact_level off         # Disable redaction
```

A built-in whitelist prevents false positives on common safe values like `localhost`, `127.0.0.1`, `true`, `false`, `example`, `test`, etc.

### Authentication

GitHub Copilot uses a secure OAuth device flow. Tokens are stored locally in `~/.clio/github_tokens.json` and refreshed automatically when they expire.

For API key providers, keys are stored in CLIO's config file. Use environment variables for CI/CD environments.

### Role-Based Access

CLIO supports roles (admin, user, guest) with configurable permissions and an audit log of security-relevant actions.

---

## 15. Themes and Styles

CLIO separates **color** (themes) from **layout** (styles), giving you full control over appearance.

### Themes (Colors)

4 built-in themes:

| Theme | Description |
|-------|-------------|
| `default` | Balanced colors for dark terminals |
| `compact` | Minimal color use |
| `verbose` | Rich, detailed color coding |
| `console` | Classic console look |

```
/theme default
/theme compact
```

### Styles (Layout + Colors)

25 built-in styles that control both colors and UI formatting:

| Style | Description |
|-------|-------------|
| `default` | Standard CLIO appearance |
| `dark` | Dark mode optimized |
| `light` | Light terminal optimized |
| `matrix` | Green-on-black hacker aesthetic |
| `dracula` | Popular dark color scheme |
| `nord` | Arctic blue palette |
| `monokai` | Classic code editor colors |
| `solarized-dark` | Ethan Schoonover's dark palette |
| `solarized-light` | Ethan Schoonover's light palette |
| `synthwave` | Retro 80s neon |
| `cyberpunk` | Neon pink and cyan |
| `ocean` | Deep blue tones |
| `forest` | Green nature tones |
| `amber-terminal` | Classic amber monochrome |
| `green-screen` | Phosphor green CRT |
| `vt100` | 1970s terminal emulation |
| `commodore-64` | Commodore 64 blue |
| `apple-ii` | Apple II green |
| `dos-blue` | DOS edit blue |
| `bbs-bright` | BBS bright colors |
| `retro-rainbow` | Rainbow ANSI art |
| `greyscale` | Monochrome grayscale |
| `slate` | Subdued gray-blue |
| `photon` | Clean, modern |
| `console` | Simple console |

```
/style dracula
/style matrix
```

### Markdown Rendering

CLIO renders markdown in the terminal with full support for:
- **Headers** (with color-coded levels)
- **Bold**, *italic*, ~~strikethrough~~, `inline code`
- Code blocks with language labels
- Tables with alignment
- Ordered and unordered lists (nested)
- Blockquotes
- Horizontal rules
- Mathematical formulas (LaTeX rendering in terminal)
- Links and references

---

## 16. Protocols

Protocols are higher-level analysis frameworks that combine multiple tools for specific tasks. They're used internally by the AI and through custom instructions.

| Protocol | Purpose |
|----------|---------|
| **Architect** | Problem analysis and solution design - breaks down problems, proposes architectures |
| **Editor** | Precise code modification - targeted edits with context awareness |
| **Validate** | Comprehensive validation - syntax checking, style compliance, security scanning |
| **RepoMap** | Repository structure analysis - builds a map of your codebase |
| **Recall** | Historical context retrieval - finds relevant past work |

Protocols are invoked automatically when the AI determines they're needed, or can be triggered through natural language requests.

---

## 17. Undo System

CLIO automatically tracks every file change made by the AI agent, giving you instant undo capability at any time.

### How It Works

Before the AI modifies any file through its tools (file operations, apply_patch), CLIO silently backs up the original content. These backups are targeted - only the specific files being changed are captured, making undo fast and lightweight regardless of project size.

### Commands

```
/undo              # Revert all file changes from the last AI turn
/undo list         # Show recent turns with file change counts
/undo diff         # Preview what would be reverted (unified diff)
```

### What's Covered

The undo system tracks changes made through CLIO's file tools:
- **File writes** - `write_file`, `create_file`, `append_file`
- **Text edits** - `replace_string`, `multi_replace_string`, `insert_at_line`
- **File management** - `delete_file`, `rename_file`
- **Patches** - `apply_patch` (create, update, delete operations)

### What's Not Covered

Changes made by **shell commands** (`terminal_operations`) are not tracked. If the AI runs a shell command that modifies files (e.g., `sed`, `mv`, `rm`), those changes cannot be undone with `/undo`. Use version control (`git`) for those cases.

### Key Behaviors

- **Per-turn granularity** - Each AI response is one "turn". `/undo` reverts everything from the last turn.
- **Multi-undo** - You can undo multiple turns in sequence (up to 20 recent turns).
- **Safe for repeated edits** - If the AI modifies the same file multiple times in one turn, undo restores the original pre-turn state, not an intermediate version.
- **Always available** - Unlike the previous git-based system, undo works from any directory (home, project, anywhere) with no dependencies.

---

## 18. Billing and Usage Tracking

CLIO tracks token usage and costs across providers:

```
/billing           # Show current billing summary
/billing detail    # Detailed breakdown
/billing reset     # Reset counters
```

For GitHub Copilot, CLIO tracks premium request quotas and warns when approaching limits. It shows:
- Total tokens used (input and output)
- Cost estimates per provider
- Premium request counts
- Model-specific multipliers

---

## 19. How It All Comes Together

CLIO's power comes from how these components integrate. Here's what happens during a typical session:

### Starting a Session

1. You run `clio --new` or `clio --resume`
2. CLIO loads your **configuration** (provider, model, preferences)
3. **Custom instructions** are read from `.clio/instructions.md` and `AGENTS.md`
4. **Long-term memory** is loaded and injected into the system prompt
5. **Session history** is restored (if resuming)
6. **MCP servers** are connected (if configured)
7. The terminal UI initializes with your chosen **theme** and **style**

### Processing a Request

1. You type a message (possibly with **hashtags** for context injection)
2. CLIO builds the full message array: system prompt + LTM + instructions + history + your message
3. **Context management** ensures the message fits within the model's token limit
4. The request is sent to your configured **AI provider**
5. The AI responds with text and/or **tool calls**
6. **Tools** are executed (file operations, git commands, searches, etc.)
7. Results are fed back to the AI
8. Steps 5-7 repeat until the AI has a complete answer
9. The response is rendered through the **markdown engine** with your theme
10. The full exchange is saved to the **session**

### During Long Sessions

- **Context trimming** keeps the conversation within token limits
- **Compression** preserves a summary of trimmed messages
- **Task recovery** injects current todo state if trimming is aggressive
- **Memory** stores important discoveries for future sessions
- **File backups** protect your files with automatic undo capability

### Across Sessions

- **Sessions** persist your full conversation history
- **Long-term memory** carries forward discoveries, solutions, and patterns
- **Cross-session recall** lets the AI search previous sessions for context
- **Skills** give you reusable workflows
- **Custom instructions** ensure consistent behavior

### Across Machines

- **Remote execution** lets CLIO work on distant servers
- **Device registry** tracks your fleet
- **Parallel execution** scales to multiple machines
- **MCP** extends capabilities through external tools

The result is an AI assistant that gets smarter with every session, works autonomously on complex tasks, and adapts to your project's specific needs - all from your terminal, using less than 100MB of RAM.

---

## Quick Reference

### Essential Shortcuts

| Action | Command |
|--------|---------|
| Start new session | `clio --new` |
| Resume last session | `clio --resume` |
| Get help | `/help` |
| Switch provider | `/api set provider <name>` |
| Switch model | `/api set model <name>` |
| Change appearance | `/style <name>` |
| Undo AI changes | `/undo` |
| Check costs | `/billing` |
| Exit | `/exit` |

### Key Hashtags

| Hashtag | Use When |
|---------|----------|
| `#file:path` | You want the AI to see a specific file |
| `#codebase` | You want the AI to understand your project structure |
| `#folder:path` | You want the AI to see what's in a directory |

### Getting Started

1. Install CLIO (see [INSTALLATION.md](INSTALLATION.md))
2. Run `clio --new`
3. Type `/api login` to authenticate with GitHub Copilot
4. Start asking CLIO to do things!

---

**For technical details:**
- [Architecture](ARCHITECTURE.md) - System design internals
- [Developer Guide](DEVELOPER_GUIDE.md) - Contributing to CLIO
- [User Guide](USER_GUIDE.md) - Detailed usage instructions
