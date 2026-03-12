# CLIO Memory Architecture

**How CLIO remembers, learns, and maintains continuity across sessions.**

---

## Overview

CLIO has a three-tier memory system designed to give AI agents the ability to learn and improve over time, maintain context during long sessions, and recover gracefully when context windows overflow.

Unlike most AI assistants that start fresh every conversation, CLIO accumulates project-specific knowledge that persists indefinitely. An agent working on your codebase today benefits from everything learned in previous sessions - discovered patterns, solved problems, and established conventions.

```
                       CLIO Memory Architecture

 Within a Session                    Across Sessions
 ==================                  ==================

 Short-Term Memory (STM)             Long-Term Memory (LTM)
 - Sliding window of recent          - Discoveries about the codebase
   messages                          - Problem-solution pairs
 - Working context for the AI        - Code patterns and conventions
 - Auto-pruned when full             - Persisted in .clio/ltm.json

 YaRN Threads                        Session-Level Store
 - Full conversation archive          - Key-value pairs in .clio/memory/
 - Compression for recovery          - Investigation notes, checkpoints
 - Never loses messages              - Available via recall_sessions
```

---

## Short-Term Memory

**Module:** `lib/CLIO/Memory/ShortTerm.pm`

Short-Term Memory is the sliding window of recent messages that forms the AI's working context for the current turn. It holds the most recent conversation history used when building the API request.

### How It Works

1. Every message (user, assistant, tool call, tool result) is added to STM
2. When STM exceeds its configured maximum size, oldest messages are pruned
3. The pruned messages aren't lost - they're preserved in YaRN threads and session history

### Key Characteristics

- **Fixed-size FIFO** - Oldest messages are dropped first when the window is full
- **Defensive normalization** - Handles legacy formats, strips conversation markup, validates message structure
- **Embedded in session files** - STM state is saved as part of the session JSON, allowing seamless session resume

STM is not something users interact with directly. It operates transparently as part of the context management pipeline.

---

## YaRN (Yet another Recurrence Navigation)

**Module:** `lib/CLIO/Memory/YaRN.pm`

YaRN is CLIO's conversation archival and compression system. While STM keeps a sliding window, YaRN keeps **everything** - the complete conversation history for each session, organized into threads.

### Why YaRN Matters

When context trimming drops messages from the active window (because the AI's context limit is approaching), those messages aren't lost. YaRN preserves them. More importantly, YaRN can **compress** dropped messages into concise summaries that capture the essential information:

- What the user asked
- What files were read and modified
- What git commits were made
- What decisions were reached through collaboration
- What tools were used and how often

### Compression

When the context window needs trimming, `compress_messages()` takes the messages about to be dropped and extracts:

| Category | What's Extracted |
|----------|-----------------|
| **User requests** | The last N user messages (truncated to ~300 chars each) |
| **Current task** | Most recent user message - the active work being done |
| **Git commits** | Commit hashes and messages from tool output |
| **Files touched** | File paths from tool call arguments (path, new_path, old_path) |
| **Key decisions** | Collaboration exchanges (question + user response) |
| **Tool usage** | Counts of each tool type used |

The result is a single system message wrapped in `<thread_summary>` tags that gets injected into the trimmed context. Critically, the `<thread_summary>` is **preserved across multiple trim cycles** - each new compression merges with the previous summary, building an accumulating record of the entire session.

### Seamless Recovery

After context trimming, CLIO agents continue working without announcing that context was lost. The thread_summary provides enough continuity that no recovery stumbling is needed:

- No "I've recovered context" announcements
- No re-reading handoff documents
- No asking the user what to do next
- Just continuing work as if nothing changed

The recovery injection includes neutral language ("Older conversation history has been summarized") rather than disruption signals, and explicitly instructs the agent to keep working.

### Session Recovery

After aggressive context trimming, the AI might otherwise "forget" what it was working on. YaRN compression plus the recovery injection system means the AI gets:

1. A merged summary of everything dropped (accumulated across trim cycles)
2. The current task anchor (most recent user message - what was being worked on NOW, not at session start)
3. The current todo/task state
4. Recent git activity (commits, working tree status)

This is why CLIO agents can work for hours on complex tasks across multiple topic transitions without losing track of their current objectives. In long sessions where early work is long done and the agent has moved through several task transitions, the original session-start message is intentionally NOT re-injected - it's stale and misleading. The thread_summary already captures it. The most recent user message represents the actual current work.

---

## Long-Term Memory (LTM)

**Module:** `lib/CLIO/Memory/LongTerm.pm`  
**Storage:** `.clio/ltm.json` (per project)

Long-Term Memory is CLIO's project-level knowledge base. It persists across all sessions and accumulates knowledge about your specific codebase and workflows.

### What Gets Stored

| Type | Purpose | Example |
|------|---------|---------|
| **Discoveries** | Facts about the codebase | "CLIO uses CLIO::Util::JSON for all JSON encoding" |
| **Solutions** | Problem-fix pairs | "If streaming 400 errors occur, increase retry budget to 20" |
| **Patterns** | Coding conventions | "Always use atomic writes (temp + rename) for session files" |

Each entry includes:
- **Confidence score** (0.0-1.0) - Higher scores indicate well-verified knowledge
- **Timestamps** - When first discovered and last confirmed
- **Examples** - File paths demonstrating the pattern
- **Application count** - How many times a solution has been used

### Automatic Prompt Injection

At the start of every session, LTM entries are formatted and injected into the system prompt by `PromptManager`. The AI sees all accumulated project knowledge before you even ask your first question.

The injection includes:
- **Key Discoveries** - Up to 15 high-confidence facts, newest first
- **Problem Solutions** - Up to 15 error/solution pairs with application counts
- **Code Patterns** - Up to 10 verified patterns with example file paths

This means an agent starting a new session already knows: what coding conventions your project uses, what bugs have been fixed before and how, and what patterns to follow. No re-discovery needed.

LTM injection can be disabled with `--no-ltm` or `--incognito` flags for sessions where you want a clean slate.

### How Agents Learn

During a session, the AI adds new entries via the `memory_operations` tool:

```
# Discover a fact about the codebase
memory_operations(operation: "add_discovery", fact: "Config uses YAML not JSON", confidence: 0.9)

# Record a problem and its solution
memory_operations(operation: "add_solution",
    error: "Session save fails with permission denied",
    solution: "Check .clio/ directory ownership, must match current user",
    examples: ["lib/CLIO/Session/State.pm"])

# Document a coding pattern
memory_operations(operation: "add_pattern",
    pattern: "All file writes use atomic temp+rename pattern",
    confidence: 0.95,
    examples: ["lib/CLIO/Memory/LongTerm.pm", "lib/CLIO/Session/State.pm"])
```

Agents are instructed to add LTM entries when they discover something significant - a new pattern, a bug fix that could recur, or a fact about the codebase structure. This happens organically during normal work sessions.

### Pruning

Old or low-confidence entries are cleaned up to keep LTM focused:

```
memory_operations(operation: "prune_ltm", max_age_days: 90, min_confidence: 0.3)
memory_operations(operation: "ltm_stats")  # Check current LTM size
```

### Atomic Persistence

LTM saves are atomic: data is written to a temporary file (with PID suffix to handle concurrent agents) and then renamed to the target path. This prevents corruption if a process is killed mid-write.

---

## Session-Level Store

**Module:** `lib/CLIO/Tools/MemoryOperations.pm`  
**Storage:** `.clio/memory/<key>.json`

The session-level store is a simple key-value system for temporary notes, investigation findings, and working data. Unlike LTM (which accumulates project knowledge), the session store is for per-task scratch data that an agent needs to reference during a session.

### How Agents Use It

Agents store working notes during complex investigations:

```
# Store investigation findings
memory_operations(operation: "store",
    key: "auth_bug_analysis",
    content: "Root cause: token refresh uses return inside eval, loses result")

# Retrieve later in the session
memory_operations(operation: "retrieve", key: "auth_bug_analysis")

# Search across all stored memories
memory_operations(operation: "search", query: "token refresh")

# List everything stored
memory_operations(operation: "list")
```

### Operations

| Operation | Description |
|-----------|-------------|
| `store` | Write a key-value pair to `.clio/memory/` |
| `retrieve` | Read a stored value by key |
| `search` | Find memories matching a keyword |
| `list` | List all stored memory keys |
| `delete` | Remove a stored memory |

The session-level store is also used for automatic checkpoints. Before context trimming events, CLIO writes a `session_progress.md` checkpoint that includes the current task state, recent tool calls, and iteration count. After recovery, agents can retrieve this checkpoint to understand where they were.

---

## Cross-Session Recall

**Operation:** `memory_operations(operation: "recall_sessions")`

Cross-session recall lets agents search through **all previous session transcripts** for relevant context. This is one of CLIO's most powerful memory features - it means knowledge isn't limited to what's in LTM. Anything discussed in any previous session is searchable.

### How It Works

1. CLIO reads all session files from `.clio/sessions/`, sorted newest-first
2. For each session (up to `max_sessions`), it loads the message history
3. Messages are scored against the search query using:
   - **Exact match boost** (+3) - Query appears verbatim in the message
   - **Keyword scoring** (+1 per keyword) - Individual words from the query found
   - **Density bonus** (+1.5) - High ratio of matching keywords to total content
   - **Title relevance** (+0.5) - Session name matches the query
4. Top results are returned with preview text

### Agent Usage

Agents use recall_sessions in several situations:

```
# After context trimming - recover lost information
memory_operations(operation: "recall_sessions",
    query: "authentication refactor approach",
    max_sessions: 10,
    max_results: 5)

# Before starting work - check if similar work was done
memory_operations(operation: "recall_sessions",
    query: "worktree implementation")

# Understanding past decisions
memory_operations(operation: "recall_sessions",
    query: "why we chose atomic writes")
```

### After Context Recovery

When aggressive context trimming occurs, the recovery injection system tells agents to use `recall_sessions` to fill in gaps rather than re-reading handoff documentation. This is more efficient because recall_sessions returns targeted, relevant excerpts rather than entire documents.

---

## Context Management Pipeline

These memory components work together in a coordinated pipeline to keep the AI effective during long sessions.

### The Token Budget Challenge

AI models have a fixed context window (e.g., 128K tokens for Claude Sonnet, 200K for Claude Opus). A long session with many tool calls can easily exceed this. CLIO's context management prevents overflow without losing critical information.

### Three-Stage Trimming

```
Stage 1: Proactive Trim (before API call, every iteration)
  WorkflowOrchestrator checks messages against 75% of context window
  If over: MessageValidator drops oldest message units (budget-walk newest to oldest)
  Dropped messages -> YaRN compression -> thread_summary injected
  thread_summary is preserved and merged across successive trim cycles

Stage 2: Validation Trim (just before sending to API)
  Final check against effective token limit
  Smart unit-based truncation (keeps tool call/result pairs together)
  Post-trim target: 50% of max prompt tokens

Stage 3: Reactive Trim (after API rejection)
  If API returns token_limit_exceeded despite proactive trim:
  Progressive reduction across up to 3 retry attempts (50% -> 25% -> minimal)
  Each retry injects recovery context (YaRN summary + todo state + git activity)
  Most recent user message preserved as the current task anchor
```

### Token Estimation

**Module:** `lib/CLIO/Memory/TokenEstimator.pm`

Token estimation uses a character-to-token ratio that starts at a conservative default and **learns from actual API responses**. Each streaming response with real usage data updates the ratio, making estimates more accurate over time.

The learned ratio is critical - an inaccurate ratio means proactive trimming either fires too aggressively (wasting context) or too late (causing API rejections).

### What Gets Preserved During Trimming

When messages must be dropped, CLIO prioritizes keeping:

1. **System prompt** - Always preserved
2. **Most recent user message** - The current task anchor (newest user message, not the session-start message)
3. **Recent messages** - Most recent conversation context (budget-walked newest to oldest)
4. **Tool call/result pairs** - Kept together to avoid orphaned results
5. **Thread summary** - Compressed history of dropped messages, injected before the conversation

---

## Data Layout

All memory data is stored in the `.clio/` directory within the project root:

```
.clio/
  ltm.json                          # Long-Term Memory (project knowledge)
  memory/
    session_progress.md             # Checkpoint written before trim events
    <key>.json                      # Session-level key-value pairs
  sessions/
    <session-id>.json               # Full session state (history, STM, YaRN, billing)
```

### Session File Format

Each session JSON file contains:

| Field | Content |
|-------|---------|
| `history` | Complete message array (all roles) |
| `stm` | Short-term memory state |
| `yarn` | YaRN thread archive |
| `billing` | Token usage records per request |
| `working_directory` | Where the session was started |
| `session_name` | Human-readable session name |
| `created_at` | Session creation timestamp |

### LTM File Format

The `.clio/ltm.json` file contains:

```json
{
  "patterns": {
    "discoveries": [...],
    "problem_solutions": [...],
    "code_patterns": [...],
    "workflows": [...],
    "failures": [...],
    "context_rules": [...]
  },
  "metadata": {
    "created": "timestamp",
    "last_updated": "timestamp",
    "version": "1.0"
  }
}
```

---

## User Commands

### Memory Commands

| Command | What It Does |
|---------|-------------|
| `/memory list` | Show stored session memories |
| `/memory search <query>` | Search memory by keyword |
| `/memory stats` | LTM statistics (entry counts, ages) |
| `/memory prune` | Clean up old/low-confidence LTM entries |

### Session Commands

| Command | What It Does |
|---------|-------------|
| `/session show` | Current session info and usage |
| `/session list` | All saved sessions |
| `/session switch <id>` | Resume a previous session |
| `/session trim` | Manually trim context |
| `/session export <path>` | Export session to self-contained HTML |

---

## Design Principles

### Nothing Is Lost

Messages trimmed from the active context are preserved in YaRN threads and session history. The full conversation is always available on disk, even when the AI can only "see" a window of it.

### Learn Once, Remember Always

When an agent discovers something about your codebase - a coding convention, a bug fix pattern, a module relationship - it stores it in LTM. Every future session benefits from that knowledge without re-discovery.

### Graceful Degradation

When context limits are hit, CLIO doesn't crash or lose track. It compresses what was lost into a summary, preserves the most important context, and injects recovery information. The AI continues working with reduced but coherent context.

### Atomic Writes

All persistent storage (LTM, sessions, memory) uses atomic write patterns (temp file + rename) to prevent corruption from process kills or concurrent access. LTM writes use PID-suffixed temp files to handle multiple agents working in the same project.

---

## How Agents Use Memory in Practice

The memory system isn't just infrastructure - it's actively used by agents throughout their work. Here's how the pieces come together in a typical session:

### Session Start

1. **LTM injection** - All project knowledge is loaded into the system prompt
2. The agent sees discoveries, solutions, and patterns before you type anything
3. If resuming a session, YaRN threads and STM are restored from the session file

### During Work

1. **Tool calls** - Every file read, command executed, and search performed is recorded in STM, YaRN, and session history
2. **Investigation notes** - Agents store findings in the session-level store for reference later
3. **Learning** - When agents discover new patterns or solve novel problems, they add entries to LTM
4. **Todo tracking** - Task state is maintained through the todo_operations tool, providing structure that survives context trims

### When Context Gets Full

1. **Proactive trim** fires when approaching 75% of the model's context window
2. Oldest messages are compressed via YaRN into a summary
3. The summary is injected as a system message so the AI knows what was dropped
4. A progress checkpoint is written to `.clio/memory/session_progress.md`

### After Context Recovery

The recovery injection tells the agent:
1. Check LTM patterns already in the system prompt
2. Use `recall_sessions` to search past sessions for specific information
3. Retrieve the `session_progress` checkpoint for task state
4. Use git log and todo state to understand current progress
5. **Do NOT** read handoff documentation (which would waste the newly freed context space)

### Between Sessions

1. LTM persists with all accumulated knowledge
2. Session files contain the complete conversation archive
3. Session-level memories in `.clio/memory/` remain available
4. Next session gets all LTM entries injected automatically

---

## Privacy and Control

### Incognito Mode

Running CLIO with `--incognito` disables all memory persistence:
- No LTM injection into prompts
- No session saving
- No memory writes
- No user profile injection

### No-LTM Mode

Running with `--no-ltm` skips just the LTM injection while keeping session persistence. Useful when you want a fresh perspective without accumulated assumptions.

### Data Location

All memory data lives in the project's `.clio/` directory (gitignored by default). Nothing is sent to external services - memory is purely local. The only data that leaves your machine is the conversation context sent to the AI provider for each API call.
