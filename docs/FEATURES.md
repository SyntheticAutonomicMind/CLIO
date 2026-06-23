# CLIO Feature Guide

**The complete guide to everything CLIO can do.**

CLIO is a terminal-native AI coding tool. It can read code, edit files, run commands, use git, fetch information, remember project-specific knowledge, and work through tasks with you in the loop.

This guide covers every feature, how the components work together, and how to get the most out of CLIO.

If you are new to CLIO, the simple model is:

- you describe a task in plain English
- CLIO investigates the codebase and surrounding context
- CLIO uses tools to do work in the repository
- CLIO pauses when your judgment is needed
- CLIO verifies results and reports back

That makes CLIO useful for more than explanation. It can help with bug investigation, refactoring, documentation updates, test writing, repository exploration, remote diagnostics, and larger tasks split across sub-agents.

This document is the deep reference - the place to understand the detailed capabilities after the basic product model makes sense.

---

## Table of Contents

1. [The AI Agent](#1-the-ai-agent)
2. [Tools](#2-tools)
3. [AI Providers](#3-ai-providers)
4. [Session Management](#4-session-management)
5. [Memory System](#5-memory-system)
6. [User Profile](#6-user-profile)
7. [Context Management](#7-context-management)
8. [Slash Commands](#8-slash-commands)
9. [Hashtag Context Injection](#9-hashtag-context-injection)
10. [Custom Instructions](#10-custom-instructions)
11. [Skills System](#11-skills-system)
12. [Multi-Agent Coordination](#12-multi-agent-coordination)
13. [Remote Execution](#13-remote-execution)
14. [MCP Integration](#14-mcp-integration)
15. [Security](#15-security)
16. [Themes and Styles](#16-themes-and-styles)
18. [Undo System](#18-undo-system)
19. [Billing and Usage Tracking](#19-billing-and-usage-tracking)
20. [Host Application Protocol](#20-host-application-protocol)
21. [How It All Comes Together](#21-how-it-all-comes-together)
22. [OpenSpec Integration](#22-openspec-integration)

---

## 1. The AI Agent

At its core, CLIO is an autonomous AI agent. You give it a task - "fix the bug in login.pm", "add tests for the parser", "refactor the database module" - and it works through it end-to-end. It reads code, makes changes, runs tests, commits results, and iterates on errors until the job is done.

What makes this different from ordinary chat is that CLIO has structured tool access and a workflow built around investigation, execution, verification, and collaboration.

### How the Agent Works

When you type a message, CLIO sends it to an AI model along with:
- A **system prompt** that defines CLIO's behavior and capabilities
- Your **conversation history** (what you've discussed so far)
- **Tool definitions** describing what CLIO can do (read files, run commands, etc.)
- **Custom instructions** from your project (if configured)
- **Long-term memory** (discoveries and patterns from previous sessions)

The AI responds with either a text message or **tool calls** - requests to perform actions. CLIO executes each tool call, feeds the results back to the AI, and the cycle continues until the AI has a complete answer.

```text
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

### Thinking/Reasoning Display

When using models that support extended thinking (OpenAI reasoning, Google thoughts, OpenRouter reasoning, MiniMax M2), CLIO can display the model's internal reasoning process and control how deeply it reasons:

```text
/api set thinking on              # Enable thinking display
/api set thinking off             # Disable (default)
/api set thinking_effort low      # Fast, lightweight reasoning
/api set thinking_effort medium   # Balanced (default)
/api set thinking_effort high     # Deep, thorough reasoning
```

When enabled, reasoning content appears in a distinct visual style before the main response, giving you visibility into the model's thought process. Higher effort levels produce more thorough reasoning at the cost of speed and tokens.

### Sampling Parameters

CLIO uses conservative sampling defaults tuned for reliable tool use. When working with models that benefit from different settings (e.g. creative tasks, or providers like MiniMax that recommend higher temperature), you can override them:

```text
/api set temperature 1.0     # Override temperature (empty = provider default)
/api set top_p 0.95          # Override top_p
/api set top_k 40            # Override top_k
/api set temperature reset   # Revert to provider default
```

Overrides are saved globally and visible in `/api show`. Provider-recommended defaults (e.g. MiniMax's `temperature=1.0`) are applied automatically when no override is set - you only need to set these if you want to change from the provider recommendation.

### Capability Overrides

Each model reports its own capabilities (context window, max output, tool/vision/reasoning support). You can override any of these from the slash command line:

**Token caps** - reduce the model's reported value to save tokens:

```text
/api set context_window 128k        # Cap DeepSeek's 1M context to 128k
/api set context_window 256000      # Same, raw tokens
/api set max_output 16k             # Cap max output tokens
/api set max_prompt 200k            # Cap max prompt tokens
/api set context_window reset       # Clear cap, use model default
```

Token values accept `k` and `M` suffixes (`128k`, `1.5M`) as well as raw integers. Caps never increase a model's value - if your cap exceeds the model's max, the model default wins.

**Capability forces** - turn a capability on or off regardless of what the model reports:

```text
/api set tools on        # Force tool calling on
/api set tools off       # Force tool calling off (e.g. for pure chat)
/api set vision on       # Force vision support on
/api set reasoning off   # Force reasoning off (skip thinking parameters)
/api set tools auto      # Clear override, use model default
```

All overrides accept `--session` for session-only application:

```text
/api set context_window 256k --session  # Only this session
```

Caps and forces flow through to conversation trimming, `/context` display, `/api models --capabilities`, and tool/vision/reasoning detection - changing them takes effect immediately without restarting.

### Chat Mode

For conversational AI without file modifications, use chat mode:

```bash
clio --chat --new
```

Chat mode:
- Auto-enables sandbox mode for safety
- Restricts tools to: web, file read, memory, interact, todos
- Uses a lighter system prompt optimized for chat

This is useful for:
- Quick questions without modifying code
- Web searches and research
- Explaining concepts or debugging help

### Iteration and Error Recovery

When something goes wrong - a syntax error, a failed test, an unexpected file structure - CLIO doesn't stop. It reads the error, adjusts its approach, and tries again. In interactive mode CLIO has no iteration limit. In non-interactive mode (scripting, sub-agents) a default of 75 iterations applies. Both are configurable.

---

## 2. Tools

Tools are CLIO's hands and eyes. They let the AI interact with your filesystem, terminal, version control, and more. CLIO has 11 core tools (plus dynamic MCP and plugin bridges) with over 80 operations between them.

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

**Semantic search** understands code structure. Asking "where is authentication implemented" will find relevant files even if they don't contain the word "authentication."

### Version Control (Git)

A dedicated git tool with 11 operations - not just "run git via shell" but structured operations with proper output parsing:

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
| `worktree` | Manage git worktrees (list, add, remove) |

**Unified diff display:** When CLIO shows diffs (via `/status`, `/diff`, `git diff`, or the undo system), it renders them with syntax coloring - additions in green, deletions in red, context in dim, and hunk headers highlighted. This makes reviewing changes significantly easier in the terminal.

### Terminal Operations

Execute shell commands with safety validation and timeout protection. CLIO can run build commands, test suites, linters, or any other shell command your workflow requires.

Commands are validated before execution. CLIO shows the command text before running it, then executes using one of three modes:

- **Captured mode** (default) - Command runs in a subshell with output redirected to a log file. No pty is created, preventing terminal corruption. Safe for all non-interactive commands.
- **Passthrough mode** - User gets interactive TTY access (for SSH, editors, etc.). Output is captured via `tee`. CLIO suspends its input handling while the command owns the terminal, then restores terminal state cleanly.
- **Multiplexer pane** - When running inside tmux, GNU Screen, or Zellij, commands open in a new pane. Output is captured via log file while the pane stays live.

**Process safety:** Commands are spawned in their own process group (via `setpgid`). On ESC interrupt or timeout, CLIO sends SIGTERM to the entire group (killing shells, ssh connections, and any grandchild processes), then SIGKILL after 2 seconds if needed. This prevents orphaned processes accumulating in the background.

**Activity-based timeouts:** CLIO uses idle timeout detection rather than wall-clock timeouts. If a command is actively producing output (build logs, test results), it keeps running. Commands are only killed after the idle timeout (default 60 seconds) with no output. A hard ceiling (default 600 seconds, configurable via `CLIO_TERMINAL_MAX_TIMEOUT`) prevents infinite runs.

### Apply Patch

A lightweight diff-based tool for efficient multi-file changes. Instead of rewriting entire files, CLIO can apply surgical patches:

```text
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

Spawn additional AI agents to work in parallel. See [Multi-Agent Coordination](#12-multi-agent-coordination).

### Remote Execution

Run CLIO on remote machines via SSH. See [Remote Execution](#13-remote-execution).

### MCP Bridge

Connect to external tool servers via the Model Context Protocol. See [MCP Integration](#14-mcp-integration).

---

## 3. AI Providers

CLIO supports 15 AI providers out of the box. Switch between them at any time - even mid-session.

| Provider | Type | Authentication |
|----------|------|---------------|
| **GitHub Copilot** | Cloud | GitHub OAuth (device flow) |
| **Anthropic** | Cloud | API key |
| **OpenAI** | Cloud | API key |
| **Google Gemini** | Cloud | API key |
| **DeepSeek** | Cloud | API key |
| **OpenRouter** | Cloud | API key |
| **Ollama Cloud** | Cloud | API key |
| **MiniMax** | Cloud | API key |
| **MiniMax Token Plan** | Cloud | API key (usage-based) |
| **Z.AI** | Cloud | API key |
| **Z.AI Coding Plan** | Cloud | API key |
| **NVIDIA NIM** | Cloud | API key |
| **llama.cpp** | Local | None |
| **LM Studio** | Local | None |
| **SAM** | Local | API key (optional) |

### Switching Providers

```text
/api set provider openai
/api set key sk-your-key-here
/config save
```

See [PROVIDERS.md](PROVIDERS.md) for complete setup instructions for each provider.

Or within a conversation:
```text
/api provider github_copilot
```

### GitHub Copilot Setup

GitHub Copilot is supported as an optional provider. For the recommended option, use OpenRouter with MiniMax:

**Recommended: OpenRouter with MiniMax**
```text
/api provider openrouter
/api set key <your-openrouter-key>
```

**Optional: GitHub Copilot** (requires GitHub Copilot subscription)
```text
/api login
```

This opens a browser for GitHub authorization. Once authenticated, tokens are managed automatically - including refresh when they expire.

### Model Selection

Each provider offers multiple models. CLIO automatically queries available models:

```text
/api models              # List available models
/api set model <model-name>   # Switch to a specific model
```

### Model Aliases and Quick Switch

Create short aliases for frequently-used models:

```text
/api alias fast <model-name>    # Create alias 'fast'
/api alias                      # List all aliases
/model fast                     # Quick switch to 'fast' model (resolves alias)
/model <model-name>             # Quick switch to any model by name
/model                          # Show current model and aliases
```

The `/model` command is a shortcut for model switching that resolves aliases. It's faster than `/api set model` for frequent switches during a session.

### Local Models

For complete privacy, use local providers (llama.cpp, LM Studio, SAM). Your data never leaves your machine. Local models work with smaller context windows, so CLIO automatically adjusts its trimming thresholds.

### Proxy Support

CLIO supports routing all outbound requests (API calls, model listing, update checks) through an HTTP or SOCKS proxy. This is useful in corporate environments, restricted networks, or when routing through a VPN.

**Configure via command:**

```text
/config set http_proxy http://proxy.example.com:8080
```

**Configure via environment variable:**

```bash
export HTTPS_PROXY=http://proxy.example.com:8080
export HTTP_PROXY=http://proxy.example.com:8080
export ALL_PROXY=socks5://proxy.example.com:1080
```

**Supported proxy URL formats:**

| Format | Protocol |
|--------|----------|
| `http://host:port` | HTTP proxy |
| `https://host:port` | HTTPS proxy |
| `socks5://host:port` | SOCKS5 proxy (DNS resolved locally) |
| `socks5h://host:port` | SOCKS5 proxy (DNS resolved remotely) |
| `socks4://host:port` | SOCKS4 proxy |

**Precedence:** Config `http_proxy` > `HTTPS_PROXY` > `HTTP_PROXY` > `ALL_PROXY`. The config setting takes priority over environment variables.

### Vision and Image Support

CLIO supports sending images to vision-capable models. Attach images using the `@path` syntax:

```text
Describe what you see in @screenshot.png
Compare these two images: @before.png and @after.png
Analyze @"/path/with spaces/image.jpg"
```

When you attach an image, CLIO:
1. Reads and validates the image file
2. Converts it to base64 for the API
3. Sends it in the multimodal format the model expects
4. Stores a text description in session history (not the full image data)

Supported image formats: PNG, JPEG, GIF, WebP.

Vision support depends on the model. Most modern models (GPT-4o, Gemini 2.5, Claude 3.5, GLM-5.x) support images. CLIO automatically detects vision capability from the model's metadata and only sends images when the model supports them.

For terminals that support inline images (kitty, iTerm), CLIO can also display images received from the model inline. On other terminals, images are saved to `~/.clio/images/` and the path is shown.

---

## 4. Session Management

Every conversation in CLIO is a **session**. Sessions persist to disk automatically, so you can close CLIO and pick up exactly where you left off.

### Session Basics

```bash
clio --new              # Start a new session
clio --resume           # Resume the most recent session
clio --session <id>     # Resume a specific session
clio --sessions         # List all sessions from the command line
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

### AI Session Naming

When you start a conversation, CLIO automatically asks the AI to generate a short descriptive name (3-6 words) for the session based on your first message. This name appears in session lists and makes it easier to find past sessions. You can always rename a session manually with `/session rename <name>`.

### Session State Repair

If a session file gets corrupted (e.g., from a crash), CLIO automatically detects and repairs common issues like orphaned tool calls, malformed JSON, and inconsistent message ordering.

### Todo Tracking

The AI uses todo lists to track progress on multi-step tasks:

```text
/todo                    # Show current todo list
/todo add "Fix tests"    # Add a task manually
```

Todos have statuses (not-started/pending, in-progress, completed, blocked), priorities (low/medium/high/critical), and descriptions. The AI updates them as it works.

---

## 5. Memory System

CLIO has a three-tier memory system that gives it continuity across sessions. For the full technical deep-dive, see [Memory Architecture](MEMORY.md).

### Short-Term Memory

Key-value storage within a session. The AI stores temporary notes, investigation findings, and working data:

```text
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

```text
# AI calls internally:
memory_operations(operation: "recall_sessions", query: "authentication refactor")
```

This finds relevant conversations from past sessions, even if the current session has no direct context.

### Memory Commands

```text
/memory list             # Show stored memories
/memory search <query>   # Search memory
/memory stats            # LTM statistics
/memory prune            # Clean up old/low-confidence entries
```

---

## 6. User Profile

CLIO can learn your working style and personalize collaboration across all projects and sessions.

### How It Works

Your profile is stored at `~/.clio/profile.md` (global, never in any git repo) and is automatically injected into the system prompt of every session. It tells the AI how you communicate, what you prefer, and how to work with you effectively.

### Building Your Profile

Run `/profile build` after you've accumulated some session history (~10+ sessions). CLIO will:

1. Scan session history across all your projects
2. Extract communication patterns, preferences, and working style
3. Generate a draft profile
4. Walk through it with you for review and refinement
5. Save the result to `~/.clio/profile.md`

### Profile Commands

| Command | What It Does |
|---------|-------------|
| `/profile` | Show profile status |
| `/profile build` | Analyze sessions and build/refine profile (AI-assisted) |
| `/profile show` | Display current profile content |
| `/profile edit` | Open profile in your editor |
| `/profile clear` | Remove the profile |
| `/profile path` | Show the profile file location |

### What's in a Profile

A typical profile includes:
- **Communication style** - How you give feedback, approve work, and course-correct
- **Working style** - How you assign tasks, iterate, and provide context
- **Preferences** - Git workflow, code style, dependency philosophy
- **Technical focus** - Languages, platforms, and domains you work in

### Privacy

- Your profile lives at `~/.clio/profile.md` in your home directory
- It's never committed to any git repository
- It's skipped when running with `--incognito` mode
- You control exactly what's in it via `/profile edit`

---

## 7. Context Management

CLIO manages a limited context window (the amount of conversation the AI can "see" at once). This is critical for long sessions. For the full technical details, see [Memory Architecture](MEMORY.md).

### Three-Layer Trimming

1. **Proactive trimming** - Before each API call, CLIO estimates token usage and trims older messages if approaching 75% of the model's context window. This preserves the most recent and most important messages.

2. **Validation trimming** - Just before sending to the API, messages are validated for token limits with smart unit-based truncation. Dropped messages are compressed into a summary.

3. **Reactive trimming** - If the API returns a token limit error despite proactive trimming, CLIO progressively trims (50%, then 25%, then minimal) and creates a compressed summary of what was dropped, including the current task state.

### What Gets Preserved

When trimming is needed, CLIO prioritizes:
- **System prompt** (always kept)
- **Most recent user message** (the current task anchor - what you're working on NOW)
- **Thread summary** (compressed record of dropped messages, preserved across trim cycles)
- **Recent messages** (most recent context, budget-walked newest to oldest)
- **Tool call/result pairs** (kept together to avoid orphans)

**Note on task continuity:** CLIO preserves the **most recent** user message as the task anchor, not the session-start message. In long sessions with multiple task transitions, the original session-start message is stale and already captured in the thread summary. Preserving the most recent message keeps the AI focused on what you're working on now.

### Context Recovery

When aggressive trimming occurs, CLIO injects recovery context that includes:
- A thread summary of dropped messages (user requests, tool operations, key events)
- The current todo/task state (what the AI was working on)
- Recent git activity (commits, working tree status)

Context recovery is **seamless** - the AI continues working without announcing that trimming occurred. Thread summaries accumulate across trim cycles, building a running record of the full session history.

### Token Estimation

CLIO estimates token counts using a learned character-to-token ratio that calibrates itself against actual API responses over time.

---

## 8. Slash Commands

CLIO has 40+ slash commands organized by category. Type `/help` for the full list.

### Core Commands

| Command | Description |
|---------|-------------|
| `/help` | Show all commands |
| `/exit` | Exit CLIO |
| `/clear` | Clear the screen |
| `/reset` | Reset terminal to known-good state and kill orphaned child processes |
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
| `/api set thinking on\|off` | Toggle reasoning display |
| `/api set thinking_effort low\|medium\|high` | Set reasoning depth (default: medium) |
| `/api set temperature <value>` | Override sampling temperature |
| `/api set top_p <value>` | Override top_p sampling |
| `/api set top_k <value>` | Override top_k sampling |
| `/api models` | List available models |
| `/api status` | Show current provider status |
| `/api alias <name> <model>` | Create a model alias |
| `/api alias` | List all model aliases |
| `/api alias <name> --delete` | Remove a model alias |
| `/model <name>` | Quick model switch (resolves aliases) |
| `/model` | Show current model and aliases |

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
| `/loglevel <level>` | Set logging level (persists to config) |

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
| `/skills repo add <name> <url>` | Add a skill repository |
| `/skills repo list` | List configured repositories |
| `/spec` | OpenSpec spec-driven development |

### Other Commands

| Command | Description |
|---------|-------------|
| `/todo` | View/manage todo list |
| `/billing` | Token usage and costs |
| `/memory` | Memory system management |
| `/context` | Context window info |
| `/stats` | Memory and performance snapshot |
| `/stats history` | Per-iteration memory timeline |
| `/stats log [N]` | Raw log entries (last N, default 20) |
| `/undo` | Revert last AI changes |
| `/update` | Check for CLIO updates |
| `/log` | View session log |
| `/device` | Manage remote devices |
| `/subagent spawn <task>` | Spawn a sub-agent |
| `/subagent list` | List all sub-agents |
| `/subagent inbox` | View messages from sub-agents |
| `/subagent send <id> <msg>` | Send message to a sub-agent |
| `/mux status` | Show multiplexer status and managed panes |
| `/mux agent <id>` | Open a pane tailing an agent's log |
| `/mux close <id\|all>` | Close managed pane(s) |
| `/mux auto [on\|off]` | Toggle auto-pane on agent spawn |
| `/mcp` | MCP server management |
| `/prompt` | View/edit system prompt |
| `/profile build` | Analyze sessions and build user profile |
| `/profile show` | Display current profile |
| `/file read <path>` | Read and display a file |
| `/file edit <path>` | Open file in external editor |
| `/file list [path]` | List directory contents |

---

## 9. Hashtag Context Injection

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

## 10. Custom Instructions

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

```
## Code Style
- Use 4 spaces for indentation
- Follow PEP 8 naming conventions

## Testing
- All new code must have tests
- Run `pytest` before committing

## Commit Format
- Use conventional commits: type(scope): description
EOF
```text

Or use the `/init` command to have the AI generate instructions based on your codebase analysis.

```
---

## 11. Skills System

Skills are reusable prompt templates. Instead of typing the same complex instructions repeatedly, save them as skills and invoke them by name.

### Managing Skills

```text
/skills list                          # Show all skills grouped by scope
/skills list --scope=<scope>          # Filter list (user|project|session|freeform|repository|builtin)
/skills add <name> "text" [--scope=]  # Create a new skill (scope: user|project|session)
/skills delete <name>                 # Remove a skill
/skills use <name> [file]             # Execute a skill as a user message (with optional file context)
/skills show <name>                   # Display skill contents (includes scope and source file)
/skills load <name>                   # Load a skill into the system prompt (persistent for session)
/skills unload <name>                 # Remove a loaded skill from the system prompt
/skills loaded                        # Show currently loaded skills
/skills search [query]                # Search the skills catalog
/skills install <name> [--scope=]     # Install a skill from the catalog (default: project)
```

### Skill Scopes

Skills live in one of six scopes. The list and show commands surface the scope and the backing file so it is always clear where a skill is stored and what to edit.

| Scope | Source | Editable | Use for |
|-------|--------|----------|---------|
| `user` | `~/.clio/skills.json` | yes | Personal skills you want in every project |
| `project` | `<cwd>/.clio/skills.json` | yes | Skills tied to a single codebase, commit to the repo |
| `session` | `sessions/<id>/skills.json` | yes | Throwaway skills for the current session, cleared on exit |
| `freeform` | `<dir>/.clio/skills/<name>.md` | yes (edit the .md) | Long-form skills version controlled alongside code |
| `repository` | `~/.clio/skill-cache/<repo>/` | no (re-sync instead) | Skills pulled from a configured Git repository |
| `builtin` | bundled with CLIO | no | Read-only skills shipped with CLIO |

`/skills add` and `/skills install` accept a scope flag. The flag can be `--global`, `--user`, `--project`, `--session`, or `--scope=user|project|session`. When the flag is omitted, the skill lands in **project** if the current working directory contains a `.clio/` directory, otherwise **user**.

### Skill Repositories

Add external Git repositories as skill sources. Skills from all configured repositories are available alongside built-in and custom skills.

```text
/skills repo add <name> <url>    # Add a skill repository
/skills repo remove <name>       # Remove a repository and its cache
/skills repo list                 # List configured repositories
/skills repo sync [name]         # Sync all repos (or a specific one)
/skills repo enable <name>       # Enable a disabled repository
/skills repo disable <name>      # Disable without removing
```

Example - add the ComposioHQ skills collection:

```text
/skills repo add awesome https://github.com/ComposioHQ/awesome-claude-skills
```

CLIO clones the repository to a local cache (`~/.clio/skill-cache/`) and scans for `SKILL.md` files. Three repository layouts are supported:

| Layout | Structure | Example |
|--------|-----------|---------|
| Root-level | `repo/skill-name/SKILL.md` | ComposioHQ/awesome-claude-skills |
| Subdirectory | `repo/.github/skills/name/SKILL.md` | Claude Code default |
| Single skill | `repo/SKILL.md` | Individual skill repos |

Optional flags when adding a repository:

```text
/skills repo add my-skills https://github.com/user/skills --branch develop
/skills repo add nested https://github.com/user/skills --subpath .github/skills
```

Repository skills are read-only. They appear in `/skills list` under the "REPOSITORY SKILLS" section with their source repository shown. Custom skills override repository skills with the same name.

### Skill Loading vs Execution

Skills can be used in two ways:

- **Execute** (`/skills use <name>`) - Runs the skill as a one-shot user message to the AI
- **Load** (`/skills load <name>`) - Injects the skill into the system prompt for the rest of the session, giving the AI persistent instructions or persona

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

When you run `/skills use code-review`, CLIO prompts you for `{{file}}` and substitutes your answer.

### Skill Priority

When skills have the same name across sources, the priority order is:

1. **Session** skills (highest - current session only)
2. **Project** skills (`.clio/skills.json`)
3. **User** skills (`~/.clio/skills.json`)
4. **Freeform** skills (`.clio/skills/<name>.md`)
5. **Repository** skills (from configured Git repos)
6. **Built-in** skills (lowest - shipped with CLIO)

### Built-in vs Custom

Built-in skills are read-only and shipped with CLIO. Custom skills are JSON entries in either `~/.clio/skills.json` (user) or `<project>/.clio/skills.json` (project), with a third option of a `<dir>/.clio/skills/<name>.md` file for long-form content. Commit the project-level skills file to share skills with the rest of the team.

---

## 12. Multi-Agent Coordination

CLIO can spawn sub-agents - independent AI processes that work in parallel on different tasks. Agents coordinate through a broker, communicate via messages, and report status through OSC events when running inside a host application.

### How It Works

```text
You: Spawn two agents - one to write tests for auth.pm and one to update the documentation

CLIO spawns:
  Agent 1: Writing tests for auth.pm
  Agent 2: Updating documentation

Both work simultaneously, sending progress messages back to your session.
```

### Puppeteer Mode

When your working directory contains child projects (subdirectories with their own `.clio/` configurations), CLIO activates puppeteer mode. You can delegate work to any child project - each sub-agent loads the target project's instructions, LTM, and conventions automatically.

```text
You: Fix the authentication bug in the backend

CLIO (in ecosystem project):
  1. Detects backend as a child project with .clio/ context
  2. Spawns agent in backend/ directory
  3. Child agent loads backend's LTM and instructions
  4. Child agent investigates, fixes, tests
  5. Reports results back to primary session
```

This is useful for monorepos, multi-project ecosystems, and any setup where you manage several repositories that each have their own development conventions. See the full [Puppeteer Mode Guide](PUPPETEER_MODE.md) for setup instructions, model selection strategies, real-world examples, and troubleshooting.

### Coordination Features

Sub-agents aren't just independent processes - they coordinate:

- **File locks** prevent two agents from editing the same file simultaneously
- **Git locks** serialize commit operations to prevent conflicts
- **API rate limiting** is shared across all agents to stay within provider limits
- **Message bus** lets agents communicate (questions, status updates, completions)
- **Status relay** forwards agent state changes to the primary session and host apps
- **Authorization relay** routes security prompts from headless agents to the user

### Agent Commands

```text
/subagent list               # Show running agents
/subagent status <id>        # Detailed agent info
/subagent send <id> <msg>    # Send guidance to an agent
/subagent kill <id>           # Terminate an agent
/subagent killall            # Terminate all agents
/subagent inbox              # View messages from agents
/subagent projects           # List detected child projects
```

### Agent Lifecycle

1. Main session spawns agents with specific tasks
2. Each agent runs as a separate process with its own AI session
3. In Puppeteer mode, the agent starts in the target project's directory and loads its `.clio/` context
4. Agents poll an inbox for messages and send updates back
5. Status changes relay to the primary session and host apps via OSC events
6. When complete, agents report results
7. Main session verifies the work

---

## 13. Remote Execution

CLIO can SSH into remote machines, deploy itself, run an AI task, and return the results.

### Basic Usage

The AI handles this automatically when you ask it to work on remote systems:

```text
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

```text
/device add staging user@staging.example.com
/device add prod user@prod.example.com
/device list
```

### Device Groups

Group devices for parallel execution:

```text
/group create webservers staging prod
```

Now you can run tasks across all web servers simultaneously:

```text
You: Check the nginx config on all webservers
```

### Parallel Execution

The `execute_parallel` operation runs the same task on multiple devices at once and aggregates results.

### Auto-Populated Configuration

When executing remotely, CLIO automatically populates the remote agent's configuration from the current session:

- **Model** - Current session's model
- **API Provider** - Current session's provider
- **API Key** - Current session's API key (passed via `CLIO_API_KEY` environment variable, never written to disk)
- **API Base** - Current session's API base URL

The remote config.json contains only provider, model, and api_base (no secrets). The API key exists only in process memory on the remote system.

### Security

- API keys are passed as environment variables, never written to disk on remote systems
- CLIO is cleaned up from remote systems after execution by default
- SSH key authentication is supported

---

## 14. MCP Integration

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

```text
/mcp status              # Show connected MCP servers
/mcp add <name> <cmd>    # Add a new MCP server
/mcp remove <name>       # Remove an MCP server
```

### How It Works

CLIO connects to MCP servers via stdio or HTTP transport. Tools from MCP servers are automatically discovered and made available to the AI as `mcp_<server>_<tool>`. The AI can use them just like built-in tools.

---

## 15. Security

### Path Authorization

CLIO sandboxes file operations to the working directory by default. The AI can't read or write files outside your project unless explicitly allowed.

Configuration options:
- **Sandbox mode** - Blocks web/remote/agent/MCP access, restricts file operations to working directory
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

```text
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

### Invisible Character Defense

CLIO automatically detects and strips invisible Unicode characters from user input. This defends against prompt injection attacks that use zero-width characters, bidirectional text overrides, and other invisible Unicode sequences to hide malicious instructions.

When invisible characters are detected, CLIO reports which characters were found (by Unicode name), strips them from the input, and proceeds with the cleaned text. This protection applies to all user input before it reaches the AI.

---

## 16. Themes and Styles

CLIO separates **color** (themes) from **layout** (styles), giving you full control over appearance.

### Themes (Colors)

4 built-in themes:

| Theme | Description |
|-------|-------------|
| `default` | Balanced colors for dark terminals |
| `compact` | Minimal color use |
| `verbose` | Rich, detailed color coding |
| `console` | Classic console look |

```text
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

```text
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

## 18. Undo System

CLIO automatically tracks every file change made by the AI agent, giving you instant undo capability at any time.

### How It Works

Before the AI modifies any file through its tools (file operations, apply_patch), CLIO silently backs up the original content. These backups are targeted - only the specific files being changed are captured, making undo fast and lightweight regardless of project size.

### Commands

```text
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

## 19. Billing and Usage Tracking

CLIO tracks token usage and costs across providers:

```text
/billing           # Show current billing summary
/billing detail    # Detailed breakdown
/billing reset     # Reset counters
```

For GitHub Copilot, CLIO tracks AI Credit usage and warns when approaching limits. It shows:
- Total tokens used (input and output)
- Cost estimates per provider
- AI Credit usage (total_nano_aiu, token_details)
- Model-specific categories (powerful, versatile, lightweight)

### Z.AI Coding Plan

The Z.AI Coding Plan provides quota-based access (not API billing) with specific limits:

**Peak Hours:** 14:00-18:00 CST (UTC+8) - GLM-5.x models cost 3x quota; 2x off-peak.

**Quota Limits:** 80-1,600 prompts per 5 hours depending on plan tier.

**Models Included:** GLM-5.1, GLM-5-Turbo, GLM-4.7, GLM-4.5-Air (all included in plan).

CLIO handles rate limits automatically and displays human-readable reset times when limits are reached.

See [coding plan docs](https://docs.z.ai/devpack/overview) for details.

---

## 20. Host Application Protocol

When CLIO is embedded inside a GUI application, it emits structured events via OSC escape sequences that the host intercepts to drive native UI elements.

**Enable host protocol:**
```bash
export CLIO_HOST_PROTOCOL=1
```

### Core Events

| Event Type | Description |
|-----------|-------------|
| `status` | Agent state changes (thinking, streaming, tools, idle) |
| `tool` | Tool execution lifecycle (start/end with operation details) |
| `spinner` | Activity indicator events (start/stop) |
| `session` | Session metadata (ID, title, model) |
| `tokens` | Real-time token usage updates |
| `todo` | Todo list state changes |
| `title` | Conversation title updates |

### Agent Events

These events track sub-agent and remote execution lifecycle, enabling host apps to render agent hierarchies and real-time status.

| Event Type | Actions | Description |
|-----------|---------|-------------|
| `agent` | spawn, status, message, exit | Sub-agent lifecycle - spawned, state changes, inbox messages, termination |
| `remote` | start, progress, complete, error | Remote execution lifecycle on SSH targets |
| `tree` | (snapshot) | Full agent tree topology - emitted on any topology change so the host can render hierarchy |

### Agent Status Relay

When sub-agents run in Puppeteer mode (project-scoped child agents), their status changes are relayed back to the primary session through the coordination broker:

```text
Child Agent (working in SAM/)
  |-- HostProtocol detects broker relay mode
  |-- Status changes (thinking, tools, idle) sent to broker
  |
Primary Session
  |-- Polls broker for status updates
  |-- Re-emits as clio:agent status events
  |
Host Application (host GUI, etc.)
  |-- Receives clio:agent events
  |-- Renders agent hierarchy with live status
```

This works transparently - the child agent doesn't need `CLIO_HOST_PROTOCOL` set. The broker relay handles forwarding.

### Wire Format

Events are encoded as OSC 0 title-change sequences with a `clio:` prefix:

```text
\033]0;clio:<event_type>:<json_payload>\007
```

The host application's terminal title callback intercepts sequences starting with `clio:` and parses the JSON payload. Zero overhead when not in host mode - the module is a no-op when `CLIO_HOST_PROTOCOL` is unset.

---

## 21. How It All Comes Together

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

---

## 22. OpenSpec Integration

CLIO has native support for [OpenSpec](https://github.com/Fission-AI/OpenSpec), a spec-driven development framework that helps you and the AI agree on what to build before any code is written.

### What It Does

OpenSpec adds a lightweight spec layer to your project. Instead of jumping straight from idea to code, you create structured artifacts - a proposal (why), specs (what), design (how), and tasks (checklist) - then implement against them. This produces more predictable results because both you and the AI are aligned on the goal before writing starts.

CLIO's integration is file-format compatible with the OpenSpec Node.js CLI. You can use either tool interchangeably on the same project - they read and write the same `openspec/` directory structure.

### The Workflow

```text
/spec init               Set up openspec/ directory
    |
/spec propose <name>     Create a change + AI generates planning artifacts
    |
  (proposal.md -> specs/ -> design.md -> tasks.md)
    |
  Implement against tasks.md using normal CLIO workflow
    |
/spec archive <name>     Archive the completed change
```

### Commands

| Command | Description |
|---------|-------------|
| `/spec` | Show spec overview (specs + active changes) |
| `/spec init` | Initialize `openspec/` directory |
| `/spec list` | List all specs and active changes |
| `/spec show <domain>` | Display a spec's contents |
| `/spec new <name>` | Create a new change (directory scaffold only) |
| `/spec propose <name>` | Create change + AI generates all planning artifacts |
| `/spec status [name]` | Show which artifacts are done, ready, or blocked |
| `/spec tasks [name]` | Show tasks from `tasks.md` with completion status |
| `/spec archive <name>` | Archive a completed change |
| `/spec help` | Show command help |

### How `/spec propose` Works

The `/spec propose <name>` command is the quick-start path. It creates the change directory, then sends a structured prompt to the AI that instructs it to generate all planning artifacts (proposal, specs, design, tasks) using CLIO's file_operations tools. After the AI finishes, you review the artifacts and implement against them.

This is different from `/design`, which creates a single monolithic PRD at `.clio/PRD.md`. `/spec propose` creates multiple focused artifacts in `openspec/changes/<name>/`, following the OpenSpec structure where each document has a clear purpose and dependency chain.

### Directory Structure

```text
openspec/
  config.yaml              Project config (schema, context, rules)
  specs/                   Source of truth - how your system currently works
    auth/spec.md
    billing/spec.md
  changes/                 Proposed changes (one folder per change)
    add-dark-mode/
      .openspec.yaml       Change metadata
      proposal.md          Why: motivation and scope
      design.md            How: technical approach
      tasks.md             Checklist: implementation steps
      specs/               What: delta specs (added/modified/removed requirements)
        ui/spec.md
    archive/               Completed changes
      2026-03-05-fix-auth/
```

### System Prompt Integration

When CLIO detects an `openspec/` directory in the project root, it automatically injects spec context into the system prompt. The AI sees which specs exist, which changes are active, and their artifact completion status - so it can reference requirements during implementation without you having to explain them.

### When to Use What

| Scenario | Use |
|----------|-----|
| Quick PRD for a new project from scratch | `/design` |
| Structured change to an existing codebase | `/spec propose` |
| Team project with multiple parallel changes | `/spec new` per change |
| Need interop with OpenSpec Node CLI users | `/spec` (fully compatible) |

### Configuration

The `openspec/config.yaml` file lets you customize the experience:

```yaml
schema: spec-driven

context: |
  Tech stack: Perl 5.32+, core modules only
  Testing: TAP format, tests/unit/
  Style: 4 spaces, strict + warnings + utf8

rules:
  specs:
    - Use Given/When/Then format for scenarios
  design:
    - Document cross-platform considerations
  tasks:
    - Each task should be completable in one session
```

The `context` is injected into every artifact's creation instructions. The `rules` are per-artifact additional guidance.
- [User Guide](USER_GUIDE.md) - Detailed usage instructions
