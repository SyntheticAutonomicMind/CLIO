# CLIO Memory Architecture

**How CLIO remembers, learns, and maintains continuity across sessions.**

---

## Overview

CLIO has a three-tier memory system designed to give AI agents the ability to learn and improve over time, maintain context during long sessions, and recover gracefully when context windows overflow.

Unlike most AI assistants that start fresh every conversation, CLIO accumulates project-specific knowledge that persists indefinitely. An agent working on your codebase today benefits from everything learned in previous sessions - discovered patterns, solved problems, and established conventions.

```text
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

### Active Task Tracking

The `# Active task` line in the dynamic userContext is the model's current-focus signal. CLIO derives it from the most recent active session goal (reversed iteration of `session_goals`), with a YaRN fallback to the most recent substantive user message from history when no goals are set. Short acknowledgements like "proceed" or "yes" do not promote into a new goal - the length guard lives upstream in the goal-recording path, so `_active_task_text` can trust that what is in `session_goals` is the current focus.

This is deliberately the **opposite** rule from the trim-preservation anchor (which freezes the first substantive user message to keep long-task history visible). The active task label is meant to track *what the user is working on right now* so the model does not treat a brand-new request as scope creep against the first thing the user asked for.

### Session Recovery

After aggressive context trimming, the AI might otherwise "forget" what it was working on. YaRN compression plus the recovery injection system means the AI gets:

1. A merged summary of everything dropped (accumulated across trim cycles)
2. The active task label (most recent active goal - what is being worked on NOW)
3. The current todo/task state
4. Recent git activity (commits, working tree status)

With YaRN compression plus the recovery injection system, CLIO agents maintain continuity through context trimming. The system provides:
1. A merged summary of everything dropped (accumulated across trim cycles)
2. The active task label (most recent active goal - what is being worked on NOW)
3. The current todo/task state
4. Recent git activity (commits, working tree status)

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

```text
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

### Corroboration Gate (Trust Tiers)

LTM entries have a trust tier system to defend against memory poisoning attacks. Every entry is tagged with a tier:

| Tier | Badge | Description |
|------|-------|-------------|
| **Unverified** | `[UNVERIFIED]` | Single-source entry, not yet corroborated. Heavy score penalty (0.3x), fast decay (30-day age-out), low confidence floor (0.7). |
| **Trusted** | `[TRUSTED]` | Corroborated by ≥2 independent sources (distinct agent:session pairs) OR manually promoted after verified outcome. Full score weight, normal decay (90-day age-out), standard confidence floor (0.5). |

**Identity and source tracking.**

Every corroboration is stamped with a `source_agent` and `source_session` joined as `agent:session` (e.g. `main:sess_abc123`). CLIO sets these automatically at startup so the source key is meaningful rather than collapsing to `unknown:unknown`:

- `clio` (top-level process) sets `CLIO_AGENT_ID=main` and `CLIO_SESSION_ID=<session uuid>` after the session is created or loaded. A fresh `./clio --new` session therefore has a distinct `agent:session` key from a previous session, so cross-session corroboration works.
- `SubAgent.pm` (spawned sub-agents) sets `CLIO_AGENT_ID=<broker agent_id>` and `CLIO_SESSION_ID=<session uuid>`, giving each sub-agent its own identity distinct from the parent's `main`.
- The `memory_operations` tool and the `/memory corroborate` slash command both fall back to the active session's `session_id` and `agent_id` from context if the env vars are unset, so external scripts and tests still get a usable identity rather than silently disabling promotion.

`corroboration_sources` is the dedup key list on every LTM entry. Corroborations from the same `agent:session` pair never double-count, which is the sybil-resistance mechanism: a single agent cannot self-promote its own entries within a session.

**How corroboration works:**

```text
# Agent independently verifies an existing memory.
# Identity is auto-resolved from env vars / session context.
# Override only when simulating a different agent (eg, tests):
memory_operations(operation: "add_corroboration",
    search_text: "Config uses YAML not JSON",
    source_agent: "agent-123",
    source_session: "session-456")

# After 2+ independent corroborations, entry auto-promotes to TRUSTED.
# Same source re-corroborating returns already_corroborated=1 (no double-count).
```

**When promotion happens automatically:**

- A parent + child agent corroborate the same entry (different `agent_id`).
- Two sessions of the same agent corroborate the same entry (different `session_id`).
- Two distinct top-level sessions corroborate the same entry across the user's day.

**When promotion does NOT happen automatically:**

- A single session re-corroborates (dedup silently drops it; the response carries `already_corroborated=1`).
- The agent:session pair cannot be resolved at all (env vars unset AND context lookup fails). This is the failure mode the `test_ltm_corroboration.pl` regression test pins down - in this case every corroboration collapses to `unknown:unknown` and the threshold can never be reached. Use the `/memory promote <search_text>` override or restart the session to recover.

**Trust but verify:** `[UNVERIFIED]` entries (especially procedural patterns like "always do X") should be validated before acting on them. Use `add_corroboration` when you independently confirm a memory, or `/memory promote <search_text>` after a verified successful outcome. The `/memory tier <search_text>` command shows the current tier, the corroboration count, and the recorded sources so you can audit why an entry is or isn't promoted.

### Pruning

Old or low-confidence entries are cleaned up to keep LTM focused:

```text
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

```text
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

Cross-session recall lets agents search through **all previous session transcripts** for relevant context. Knowledge isn't limited to what's in LTM - anything discussed in any previous session is searchable.

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

```text
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

### The Role-Based History Pipeline

The history the model sees is built by three layers:

```text
Layer 1: PromptBuilder
  Loads the active system prompt (default.md or chat.md), inserts the
  dynamic tools section, the installed-skills catalog, and the user
  profile section. Plugin instructions and the puppeteer topology are
  appended if present. This is the [0] cache-stable prefix anchor.

Layer 2: ContextBuilder (the projection)
  Walks the role-based history, picks the anchor turn (first
  substantive user message, >=50 chars) and the 1-2 most recent
  complete turns, scores LTM entries against the current request,
  collapses identical-tool-call continuation turns, and renders the
  structured fields (active task, active todos, unresolved state,
  relevant memory, environment, context files) into a projection
  hashref.

Layer 3: WorkflowOrchestrator
  Pushes system_prompt, then anchor+recent as role-based messages,
  then renders the projection's dynamic fields as one trailing
  system message (the dynamic userContext), then appends the
  current user_input. The result is the messages array sent to
  the API.
```

### Two Trim Layers (not three)

```text
Stage 1: Proactive Trim (before API call, every iteration after the first)
  WorkflowOrchestrator calls validate_and_truncate on @messages
  when iteration > 1.
  trim_with_noise_dropping strips reasoning_content (DeepSeek,
  Anthropic native, OpenAI o-series, MiniMax reasoning_details,
  Anthropic reasoning_blocks) from old assistant messages first -
  the model produced it once and doesn't need to see it again.
  Then _role_based_tail_walk drops oldest messages while protecting
  the system_prompt, dynamic userContext, current user_input,
  and tool_call/tool_result pairs.

Stage 2: Reactive Trim (after API token_limit_exceeded)
  validate_and_truncate on the oversized @messages, same code path
  as the proactive trim. Single-pass; the proactive trim keeps the
  array trim enough that reactive drops are small.

There is no third "validation" stage. The earlier design had a
separate stage that XML-parsed the messageHistory block, but the
role-based history refactor made that obsolete - the trim path is
generic over the messages array and works for any provider's wire
format.
```

### Compression (Compressed Tail)

When `ContextBuilder::_select_turns` drops turns that don't fit
the budget, the dropped turns are summarized into a `# Earlier
work` section that appears at the top of the dynamic userContext
system message.

The current implementation concatenates user/assistant text from
each dropped turn (`User: <200 chars>. Assistant: <200 chars>.`
joined with ` / `). It is NOT YaRN-compressed prose. For long
sessions dominated by short continuation turns this section can
be mostly noise - see `scratch/optimize.md` "What gets dropped"
for the design intent. A real compression pass (YaRN's
`_compress_dropped_for_recovery`) is planned.

### Anchor Recovery

When `state->{history}` has been trimmed past the original
substantive user message, `ContextBuilder::_select_turns` falls
back to `YaRN::recover_substantive_task`, which walks the durable
YaRN thread (never trimmed) and returns the oldest substantive
user message. The recovered text is sanitized and synthesized into
a one-message synthetic anchor turn so the model still sees the
original task even after extreme state trimming.

### Token Estimation

**Module:** `lib/CLIO/Memory/TokenEstimator.pm`

Token estimation uses a character-to-token ratio that starts at a conservative default and **learns from actual API responses**. Each streaming response with real usage data updates the ratio, making estimates more accurate over time.

The learned ratio is critical - an inaccurate ratio means proactive trimming either fires too aggressively (wasting context) or too late (causing API rejections).

### What Gets Preserved During Trimming

When messages must be dropped, CLIO prioritizes keeping:

1. **System prompt** (`messages[0]`) — never dropped; protects the cache-stable prefix anchor.
2. **Anchor turn** — the first substantive user message, even if it pushes the budget over. If it does, the proactive trim yields and the reactive trim fires.
3. **Dynamic userContext system message** — never dropped. The model needs the active task, todos, and relevant memory references regardless of how aggressive the trim is. Without this protection, long sessions lose the model's current focus when budget pressure hits.
4. **Current turn's user input** — never dropped. The model has to know what the user just asked.
5. **Recent tool exchanges** — newest first within the recent-turn range.
6. **Tool call/result pairs** — kept together, never orphaned.

Note on task continuity: the **anchor turn** is the first substantive user message, kept verbatim so long-task history survives trimming. This is independent of the **active task label** above, which tracks the most recent active goal and is meant to be live. The anchor protects history; the active task label signals current focus. The two rules are intentionally different - long sessions with multiple task transitions keep the original task visible in the anchor while the active task label moves to whatever the user is working on right now.

---

## Data Layout

All memory data is stored in the `.clio/` directory within the project root:

```text
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
| `/memory corroborate <search_text>` | Add corroboration to an LTM entry (auto-promotes to TRUSTED at 2+ distinct agent:session pairs) |
| `/memory promote <search_text>` | Manually promote an entry to TRUSTED tier (unconditional override; use after verified outcome) |
| `/memory tier <search_text>` | Show the trust tier, corroboration count, and recorded sources of an LTM entry |

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

### Preserved in Compressed Form

Messages trimmed from the active context are preserved in YaRN threads and session history. While the original detail is compressed into summaries, the compressed record remains available on disk and can be searched via recall_sessions.

### Accumulated Knowledge

When an agent discovers something about your codebase - a coding convention, a bug fix pattern, a module relationship - it stores it in LTM. Future sessions can benefit from that accumulated knowledge, reducing redundant investigation.

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
