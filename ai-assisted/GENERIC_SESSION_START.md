# Generic Session Start - CLIO Development

**Purpose:** This document provides complete context for starting a brand new CLIO development session when no prior session context is available.

**Date:** January 15, 2026  
**Status:** Template for new contributors or fresh starts

---

## 🎯 YOUR FIRST ACTION

**MANDATORY:** Your very first tool call MUST be:

```bash
scripts/user_collaboration.sh "Session started.

✅ Read THE_UNBROKEN_METHOD.md: yes
✅ Read copilot-instructions: yes
📋 Continuation context: Generic session start (no prior context)
🎯 User request: [Waiting for user to describe tasks]

I am ready to collaborate on session requirements and tasks.

What would you like to work on today? Press Enter:"
```

**WAIT for user response.** They will describe what they need you to work on.

---

## 📋 SESSION INITIALIZATION CHECKLIST

Before starting work, complete these steps:

### 1. Read The Unbroken Method
```bash
cat ai-assisted/THE_UNBROKEN_METHOD.md
```

This is the foundational methodology. The Seven Pillars govern all work:
1. **Continuous Context** - Never break the conversation
2. **Complete Ownership** - Fix every bug you find
3. **Investigation First** - Understand before changing
4. **Root Cause Focus** - Fix problems, not symptoms
5. **Complete Deliverables** - No partial solutions
6. **Structured Handoffs** - Perfect context transfer
7. **Learning from Failure** - Document anti-patterns

### 2. Read Copilot Instructions
```bash
cat .github/copilot-instructions.md
```

This contains CLIO-specific development practices, critical rules, Perl standards, and workflow.

### 3. Check Recent Context
```bash
# Recent commits
git log --oneline -10

# Current status
git status

# Look for recent session handoffs
ls -lt ai-assisted/ | head -20

# Check for uncommitted work
git diff
```

### 4. Use Collaboration Tool (see YOUR FIRST ACTION above)

Wait for user to provide tasks and priorities.

---

## 📚 PROJECT CONTEXT

### What is CLIO?

CLIO is a Perl-based AI code assistant with terminal UI and Model Context Protocol (MCP) integration:

- **OpenAI-Compatible Tool Calling:** Uses WorkflowOrchestrator for autonomous tool use
- **Multi-Provider AI:** OpenAI, Anthropic, Google Gemini, DeepSeek, Qwen (DashScope)
- **Protocol Architecture:** Modular protocol handlers (FILE_OP, GIT, URL_FETCH, RAG, MEMORY)
- **Terminal UI:** Clean chat interface with ANSI colors, no box-drawing characters
- **Session Management:** Persistent conversation history with JSON storage
- **Code Intelligence:** Tree-sitter integration for symbol extraction and code analysis
- **Privacy-First:** Local session storage, API keys via environment

### Technology Stack

- **Language:** Perl 5.34+ (strict, warnings, utf8)
- **UI:** Terminal::ReadKey, ANSI color codes
- **Data:** JSON::PP, MIME::Base64
- **HTTP:** HTTP::Tiny, LWP::UserAgent
- **Testing:** Perl's built-in test framework
- **Target:** macOS, Linux, BSD (cross-platform)

### Architecture

```
┌─────────────────────────────────────────────────┐
│              CLIO System                 │
├─────────────────────────────────────────────────┤
│                                                 │
│  ┌──────────────┐         ┌──────────────┐     │
│  │  CleanChat   │◄───────►│ SimpleAI     │     │
│  │  (Terminal)  │         │   Agent      │     │
│  └──────────────┘         └──────┬───────┘     │
│                                  │             │
│                                  │             │
│  ┌──────────────┐         ┌─────▼─────────┐   │
│  │   Session    │◄───────►│  Workflow     │   │
│  │   Manager    │         │ Orchestrator  │   │
│  └──────────────┘         └──────┬────────┘   │
│                                  │             │
│                                  │             │
│  ┌──────────────┐         ┌─────▼─────────┐   │
│  │    Tool      │◄───────►│     API       │   │
│  │  Executor    │         │   Manager     │   │
│  └──────┬───────┘         └───────────────┘   │
│         │                                      │
│         │                                      │
│  ┌──────▼───────────────────────────────┐     │
│  │      Protocol Handlers               │     │
│  │  (FILE_OP, GIT, URL_FETCH, etc.)    │     │
│  └──────────────────────────────────────┘     │
│                                                │
└─────────────────────────────────────────────────┘
```

### Key Source Directories

```
lib/CA/
├── Core/                   # Core system components
│   ├── AIAgent.pm         # Base AI agent interface
│   ├── SimpleAIAgent.pm   # Simplified agent (delegates to Orchestrator)
│   ├── APIManager.pm      # Multi-provider API integration
│   ├── WorkflowOrchestrator.pm  # Tool calling workflow loop
│   ├── ToolExecutor.pm    # Tool call → protocol bridge
│   └── CommandParser.pm   # Command parsing
├── Protocols/             # Protocol handler implementations
│   ├── Manager.pm         # Protocol registry and routing
│   ├── FileOp.pm          # File operations (read/write/search/list)
│   ├── Git.pm             # Git operations (status/log/diff/commit)
│   ├── UrlFetch.pm        # URL fetching (GET/POST)
│   ├── RAG.pm             # Retrieval-augmented generation
│   └── Memory.pm          # Memory operations
├── Tools/                 # Tool definitions and utilities
│   ├── Registry.pm        # OpenAI-format tool definitions
│   └── ResultStorage.pm   # Large result persistence (>8KB)
├── UI/                    # Terminal UI components
│   ├── CleanChat.pm       # Main chat interface (THE ONLY UI)
│   └── deprecated/        # Old UI modules (DO NOT USE)
├── Session/               # Session management
│   └── Manager.pm         # Session persistence and history
├── Memory/                # Memory systems (future)
├── Code/                  # Code intelligence (future)
└── Security/              # Security features (future)

clio                # Main entry point script
```

---

## 🔧 ESSENTIAL COMMANDS

### Build & Test
```bash
# Syntax check main script
perl -c clio

# Syntax check specific module
perl -I./lib -c lib/CA/Core/WorkflowOrchestrator.pm

# Syntax check all modules
find lib -name "*.pm" -exec perl -I./lib -c {} \; 2>&1 | grep -E "(syntax|ERROR)"

# Run CLIO
./clio --new                    # Start new session
./clio --resume <session_id>    # Resume session
./clio --debug                  # Enable debug output
./clio --input "test" --exit    # One-shot test

# Test tool calling
COLLABORAIT_DEBUG=1 perl test_tool_calling.pl

# Test protocol directly
perl -I./lib -e 'use PC::Protocols::Manager; PC::Protocols::Manager->handle("[FILE_OP:action=read:path=README.md]")'
```

### Code Search
```bash
# Search for patterns
git grep "pattern" lib/

# Search specific file types
git grep "sub execute" lib/CA/Protocols/

# Search with context
git grep -n -C 3 "tool_calls" lib/
```

### Collaboration
```bash
# MANDATORY at key checkpoints
scripts/user_collaboration.sh "message"
```

### Git Workflow (SAM-STYLE - File-Based Commits)
```bash
# 1. Write commit message to file
cat > scratch/commit-msg.txt << 'EOF'
type(scope): brief description

Problem: What was broken or missing. Be specific about the issue.

Root Cause: Why the problem existed. The fundamental reason.

Solution:
1. What you changed
2. How it fixes the root cause
3. Any architectural impacts

Changes:
- file1.pm: What changed and why
- file2.pm: What changed and why

Testing:
✅ Syntax: PASS (perl -I./lib -c)
✅ Manual: What you tested
✅ Edge cases: What you verified

Impact: High-level summary of what this accomplishes.
EOF

# 2. Validate message
cat scratch/commit-msg.txt

# 3. Stage changes
git add -A

# 4. Verify staging
git status

# 5. Commit using file
git commit -F scratch/commit-msg.txt

# 6. Verify commit
git log --oneline -3
```

**CRITICAL:** NEVER use `git commit -m` - terminals corrupt multi-line messages!

---

## 📂 FILE LOCATIONS

| Purpose | Path | Example |
|---------|------|---------|
| Main script | `clio` | Entry point |
| Core modules | `lib/CA/Core/` | `lib/CA/Core/SimpleAIAgent.pm` |
| Protocol handlers | `lib/CA/Protocols/` | `lib/CA/Protocols/FileOp.pm` |
| UI modules | `lib/CA/UI/` | `lib/CA/UI/CleanChat.pm` |
| Sessions (runtime) | `sessions/` | `sessions/sess_*.json` |
| URL cache | `url_cache/` | `url_cache/*.json` |
| Temp files | `scratch/` | `scratch/commit-msg.txt` (gitignored) |
| Documentation | `docs/` | `docs/PROTOCOL_SPECIFICATION.md` |
| Specifications | Root | `SYSTEM_DESIGN.md`, `PROJECT_PLAN.md` |
| Session handoffs | `ai-assisted/YYYY-MM-DD/HHMM/` | `ai-assisted/2026-01-10/tool-calling-handoff/` |

---

## 📖 KEY DOCUMENTATION

Read these as needed for your work:

### Methodology & Process
- `ai-assisted/THE_UNBROKEN_METHOD.md` - **MUST READ** - Core methodology
- `.github/copilot-instructions.md` - **MUST READ** - Development practices

### Architecture & Design
- `SYSTEM_DESIGN.md` - Complete system architecture, module structure, data flows
- `PROJECT_PLAN.md` - Implementation phases, milestones, task dependencies

### Specifications (in `docs/`)
- `PROTOCOL_SPECIFICATION.md` - Protocol layers, handlers, error handling
- `API_INTEGRATION_SPEC.md` - Endpoints, auth, request/response formats
- `MEMORY_SYSTEM_SPEC.md` - Short-term, long-term, YaRN integration
- `CODE_INTELLIGENCE_SPEC.md` - Tree-sitter, symbol extraction, patterns
- `SESSION_MANAGEMENT_SPEC.md` - Session creation, history, persistence
- `ERROR_HANDLING_SPEC.md` - Error categories, recovery, logging
- `UI_SPECIFICATION.md` - Terminal UI, colors, formatting standards
- `SECURITY_SPECIFICATION.md` - Auth, authz, audit, data protection
- `TESTING_SPECIFICATION.md` - Unit tests, integration, coverage
- `DEVELOPMENT_WORKFLOW.md` - Development process and standards
- `DEPLOYMENT_SPECIFICATION.md` - Installation, configuration, updates

---

## 🚨 CRITICAL RULES

### Process
1. **Always use collaboration tool** at session start, before implementation, after testing, at session end
2. **Read code before changing it** - Investigation first (Pillar 3)
3. **Fix all bugs you find** - Complete ownership (Pillar 2)
4. **No partial solutions** - Complete deliverables (Pillar 5)
5. **NEVER commit ai-assisted/ files** - Handoff docs stay LOCAL ONLY
6. **Use file-based commits** - Write to scratch/commit-msg.txt, then `git commit -F`

### Code (Perl Standards)
1. **Use STDERR for debug/error** - `print STDERR "[DEBUG] message"`, NEVER `print()`
2. **Syntax check before commit** - `perl -I./lib -c <file>`
3. **No hardcoding** - Use configuration when available
4. **All modules end with `1;`** - Perl requirement
5. **Use strict, warnings, utf8** - Always at top of modules
6. **Protocol format** - `[PROTOCOL:action=X:param=<base64>]` with base64-encoded params
7. **Logging format** - `[LEVEL][Module] Message` (e.g., `[DEBUG][ToolExecutor] Executing tool`)
8. **NEVER use isBackground=true** - ALWAYS use `isBackground: false` in run_in_terminal

### Documentation
1. **Update specs when behavior changes** - Keep docs in sync with code
2. **Create handoffs in dated folders** - `ai-assisted/YYYY-MM-DD/HHMM/`
3. **Include complete context** - Next session should continue seamlessly
4. **POD documentation** - Use `=head1`, `=head2`, `=cut` for module docs

---

## ⚠️ ANTI-PATTERNS (DO NOT DO THESE)

### Process Violations
❌ Skip session start collaboration checkpoint  
❌ Label bugs as "out of scope" (fix them - Complete Ownership)  
❌ Create partial implementations ("TODO for later")  
❌ End session without collaboration tool + user approval  
❌ Use `git commit -m` (causes terminal corruption - use file-based)  
❌ Commit handoff docs to repository (ai-assisted/ stays local)  

### Code Violations
❌ Use `print()` for debugging instead of STDERR  
❌ Skip `perl -c` syntax checks before committing  
❌ Hardcode values when config/metadata is available  
❌ Use `isBackground=true` in run_in_terminal (causes silent failures)  
❌ Forget `1;` at end of Perl modules  
❌ Ignore wide character warnings or prototype mismatches  
❌ Mix tabs and spaces (use spaces only)  

### Documentation Violations
❌ Skip updating specs when behavior changes  
❌ Create handoffs without complete context  
❌ Leave documentation out of sync with code  

---

## 🎯 WORKFLOW PATTERN

For each task you work on:

1. **INVESTIGATE**
   - Read existing code: `cat lib/CA/Module.pm`
   - Search for patterns: `git grep "pattern" lib/`
   - Understand WHY it works this way
   - Test current behavior if applicable

2. **CHECKPOINT** (collaboration tool)
   - Share findings
   - Propose approach
   - WAIT for approval

3. **IMPLEMENT**
   - Make exact changes from approved plan
   - Follow Perl code standards

4. **TEST**
   - Syntax check: `perl -I./lib -c lib/CA/Module.pm`
   - Verify functionality: `./clio --debug`
   - Test edge cases

5. **CHECKPOINT** (collaboration tool)
   - Show test results
   - Confirm status
   - WAIT for approval

6. **COMMIT** (file-based workflow)
   - Write message to `scratch/commit-msg.txt`
   - Validate: `cat scratch/commit-msg.txt`
   - Stage: `git add -A`
   - Verify: `git status` (NO ai-assisted/ files!)
   - Commit: `git commit -F scratch/commit-msg.txt`

7. **CONTINUE**
   - Move to next task
   - Keep working until ALL issues resolved

---

## 🤝 COLLABORATION IS MANDATORY

You are working **WITH** a human partner, not **FOR** a human.

- Use `scripts/user_collaboration.sh` at all key points
- WAIT for user response at each checkpoint
- User may approve, request changes, or reject
- This is a conversation, not a command stream

**Every checkpoint is a conversation.**  
**Every checkpoint requires you to WAIT.**  
**Every checkpoint can be rejected - and that's OK.**

---

## 🎨 TOOL CALLING ARCHITECTURE (COMPLETED)

CLIO uses OpenAI-compatible tool calling via WorkflowOrchestrator.

**Flow:**
```
User Input → WorkflowOrchestrator → API with tools array
                                          ↓
                                    AI decides to use tools
                                          ↓
                                    tool_calls in response
                                          ↓
                                    ToolExecutor → Protocols
                                          ↓
                                    Results back to AI
                                          ↓
                                    AI processes and responds
                                          ↓
                                    Final answer to user
```

**Available Tools:**
- `file_operations` - Read, write, search, list files
- `git_operations` - Status, log, diff, commit, branch, etc.
- `url_fetch` - GET/POST URLs, fetch content
- `read_tool_result` - Retrieve large stored tool results in chunks

**Pattern matching is COMPLETELY REMOVED.** AI decides when to use tools.

---

## 📞 GETTING STARTED

**Your next step:**

1. Use the collaboration tool (see YOUR FIRST ACTION at top)
2. WAIT for user to describe tasks
3. Discuss approach with user via collaboration tool
4. Begin work using the WORKFLOW PATTERN above

**Remember:**
- Investigation first
- Checkpoint before implementation
- Test before commit
- Collaborate throughout
- File-based commits (scratch/commit-msg.txt → git commit -F)
- NEVER commit ai-assisted/ files

**The methodology works. Follow it exactly.**

Good luck! 🚀
