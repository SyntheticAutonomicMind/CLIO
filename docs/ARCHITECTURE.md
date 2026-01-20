# CLIO Architecture

**Current Status:** Pre-release (Jan 2026)  
**Implementation:** 85% complete (core features working, advanced features partial)

---

## Quick Overview

CLIO is a **terminal-first AI code assistant** built in Perl. It integrates AI models (GitHub Copilot, OpenAI, etc.) with local tools (file operations, git, terminal) to help developers work more effectively.

**Core concept:** User types → CLIO thinks → CLIO uses tools → Results displayed

```
User Input
   ↓
Terminal UI (Chat.pm)
   ↓
AI Agent (SimpleAIAgent.pm)
   ↓
Tool Selection & Execution
   ├── File Operations (FileOperations.pm)
   ├── Git (VersionControl.pm)
   ├── Terminal (TerminalOperations.pm)
   ├── Memory (MemoryOperations.pm)
   └── Other tools...
   ↓
Response Processing
   ↓
Markdown Rendering (Markdown.pm)
   ↓
Terminal Output
```

---

## System Components

### 1. User Interface Layer
**Files:** `lib/CLIO/UI/`

| Component | File | Purpose | Status |
|-----------|------|---------|--------|
| Terminal UI | `Chat.pm` (150KB) | Main interaction loop, streaming output | ✅ Complete |
| Markdown Renderer | `Markdown.pm` | Convert markdown to ANSI | ✅ Complete |
| Color/ANSI | `ANSI.pm` | ANSI escape sequences | ✅ Complete |
| Themes | `Theme.pm` | Color themes and styling | ⚠️ Mostly done (415 hardcoded prints bypass system) |

**How it works:**
1. User types message
2. Chat.pm sends to AI
3. Stream responses back to terminal
4. Markdown rendering converts formatting
5. Apply theme colors

### 2. Core AI & Workflow
**Files:** `lib/CLIO/Core/`

| Component | File | Purpose | Status |
|-----------|------|---------|--------|
| API Manager | `APIManager.pm` (70KB) | AI provider integration | ✅ Complete |
| Simple AI Agent | `SimpleAIAgent.pm` | Handles AI requests/responses | ✅ Complete |
| Workflow Orchestrator | `WorkflowOrchestrator.pm` | Complex multi-step workflows | ⚠️ Partial |
| Tool Executor | `ToolExecutor.pm` | Invokes tools | ✅ Complete |
| Prompt Manager | `PromptManager.pm` (823 lines) | System prompts + custom instructions | ✅ Complete |
| Instructions Reader | `InstructionsReader.pm` | Reads `.clio/instructions.md` | ✅ Complete |
| Config | `Config.pm` | API keys, provider selection | ✅ Complete |
| ReadLine | `ReadLine.pm` | Command history & editing | ✅ Complete |

**How it works:**
1. APIManager connects to AI provider (GitHub Copilot, OpenAI, etc.)
2. WorkflowOrchestrator manages complex interactions
3. PromptManager provides system prompt + custom instructions
4. ToolExecutor invokes selected tools
5. Results processed and returned

### 3. Tool System
**Files:** `lib/CLIO/Tools/`

| Tool | File | Operations | Status |
|------|------|-----------|--------|
| File Operations | `FileOperations.pm` (52KB) | read, write, search, create, delete, rename, etc. | ✅ Complete |
| Version Control | `VersionControl.pm` | git status, log, diff, commit, branch, push, pull | ✅ Complete |
| Terminal | `TerminalOperations.pm` | exec - run shell commands | ✅ Complete |
| Memory | `MemoryOperations.pm` | store, retrieve, search, list, delete | ✅ Complete |
| Todo | `TodoList.pm` (19KB) | create, update, complete, list, track tasks | ✅ Complete |
| Code Intelligence | `CodeIntelligence.pm` | list_usages - find symbol references | ⚠️ Partial |
| Web | `WebOperations.pm` | fetch_url, search_web | ✅ Complete |
| User Collaboration | `UserCollaboration.pm` | request_input - checkpoint prompts | ✅ Complete |

**Architecture:**
- Base class: `Tool.pm` (abstract interface)
- Each tool extends Tool.pm
- Registry.pm manages tool registration
- ToolExecutor.pm invokes them

### 4. Session Management
**Files:** `lib/CLIO/Session/`

| Component | File | Purpose | Status |
|-----------|------|---------|--------|
| Session Manager | `Manager.pm` | Create/load/resume sessions | ✅ Complete |
| Session State | `State.pm` | Conversation history, metadata | ✅ Complete |
| Todo Store | `TodoStore.pm` | Persist todos across sessions | ✅ Complete |
| Tool Result Store | `ToolResultStore.pm` | Cache tool results for large output | ✅ Complete |

**How it works:**
1. New session: Create `sessions/UUID.json`
2. Each message appended to conversation history
3. Sessions persist on disk (in `sessions/` directory)
4. Resume: Load session from disk, continue conversation

### 5. Memory System
**Files:** `lib/CLIO/Memory/`

| Component | File | Purpose | Status |
|-----------|------|---------|--------|
| Short-Term | `ShortTerm.pm` | Session context | ⚠️ Partial |
| Long-Term | `LongTerm.pm` | Persistent storage | ⚠️ Partial |
| YaRN | `YaRN.pm` | Conversation threading | ✅ Core done |
| Token Estimator | `TokenEstimator.pm` | Count tokens for context | ✅ Complete |

**Status:** Basic implementation works, optimization needed for large projects.

### 6. Code Analysis
**Files:** `lib/CLIO/Code/`

| Component | File | Purpose | Status |
|-----------|------|---------|--------|
| Tree-sitter | `TreeSitter.pm` | Parse code into AST | ⚠️ Parser available, limited use |
| Symbols | `Symbols.pm` | Extract function/class names | ⚠️ Basic extraction |
| Relations | `Relations.pm` | Map symbol relationships | ⚠️ Partial |

**Status:** Foundation present, not heavily used yet.

### 7. Security
**Files:** `lib/CLIO/Security/`

| Component | File | Purpose | Status |
|-----------|------|---------|--------|
| Auth | `Auth.pm` | GitHub OAuth, token storage | ✅ Complete |
| Authz | `Authz.pm` | Check file access permissions | ✅ Complete |
| Path Authorizer | `PathAuthorizer.pm` | Control file access | ✅ Complete |
| Manager | `Manager.pm` | Overall security | ✅ Complete |

**How it works:**
1. User runs `/login` → GitHub device flow
2. Token stored securely in `~/.clio/`
3. File operations check PathAuthorizer
4. Audit logging of all operations

### 8. Logging & Monitoring
**Files:** `lib/CLIO/Logging/`, `lib/CLIO/Core/`

| Component | File | Purpose | Status |
|-----------|------|---------|--------|
| Logger | `Core/Logger.pm` | Debug/trace output | ✅ Complete |
| Tool Logger | `Logging/ToolLogger.pm` | Log tool operations | ✅ Complete |
| Performance Monitor | `Core/PerformanceMonitor.pm` | Track timing | ⚠️ Partial |

**How it works:**
- Debug mode: `clio --debug`
- Output goes to STDERR with `[DEBUG]`, `[ERROR]`, `[TRACE]` prefixes
- Tool operations logged via ToolLogger

### 9. Protocol System
**Files:** `lib/CLIO/Protocols/`

| Protocol | File | Purpose | Status |
|----------|------|---------|--------|
| Architect | `Architect.pm` (24KB) | Problem-solving design | ✅ Complete |
| Editor | `Editor.pm` (25KB) | Code modification format | ✅ Complete |
| Validate | `Validate.pm` (18KB) | Code validation | ✅ Complete |
| Tree-sitter | `TreeSit.pm` (22KB) | AST integration | ⚠️ Partial |
| RepoMap | `RepoMap.pm` (26KB) | Repository mapping | ⚠️ Partial |
| Recall | `Recall.pm` | Memory recall | ✅ Basic |
| Handler | `Handler.pm` | Protocol base class | ✅ Complete |
| Manager | `Manager.pm` | Protocol registry | ✅ Complete |

**How it works:**
1. AI returns natural language protocol commands
2. ProtocolIntegration.pm parses them
3. Manager looks up protocol handler
4. Handler executes the protocol
5. Results sent back to AI

---

## Data Flow

### Typical Interaction

```
┌─────────────────────────────────────────────────────────────────┐
│ 1. User Input (Chat.pm)                                         │
│    User: "Please read config.py and explain what it does"       │
└─────────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────────┐
│ 2. AI Processing (APIManager → AI Provider)                     │
│    - Load system prompt (PromptManager)                          │
│    - Inject custom instructions (.clio/instructions.md)         │
│    - Send to GitHub Copilot/OpenAI/etc.                         │
│    - Get response with tool calls                               │
└─────────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────────┐
│ 3. Tool Selection (ToolCallExtractor)                           │
│    - AI might request: "FILE_OPERATION: read config.py"        │
│    - Parse and validate tool call                               │
└─────────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────────┐
│ 4. Tool Execution (ToolExecutor)                                │
│    - Invoke FileOperations.pm:read('config.py')                 │
│    - Tool performs operation on real filesystem                 │
│    - Return results                                             │
└─────────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────────┐
│ 5. Response Processing                                          │
│    - Build response with tool results                           │
│    - Stream back to AI for analysis/explanation                 │
│    - Or display results to user                                 │
└─────────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────────┐
│ 6. Display (Markdown.pm + Theme.pm)                             │
│    - Convert markdown formatting to ANSI                        │
│    - Apply theme colors                                         │
│    - Stream to terminal                                         │
└─────────────────────────────────────────────────────────────────┘
                            ↓
                   ┌─────────────────┐
                   │ User sees response
                   └─────────────────┘
```

### Session Persistence

```
User Action
    ↓
Add to Session.State.conversation
    ↓
Save sessions/UUID.json
    ↓
User resumes later
    ↓
Load sessions/UUID.json
    ↓
Conversation history restored
    ↓
Continue from where left off
```

---

## Entry Points

### `clio` Script (Main Executable)
```perl
#!/usr/bin/env perl
1. Load required modules
2. Parse command-line arguments (--new, --resume, --debug, etc.)
3. Initialize configuration
4. Create/load session
5. Instantiate Chat.pm UI
6. Start interactive loop
```

### `clio --new`
- Start fresh session
- Create new `sessions/UUID.json`
- Begin conversation

### `clio --resume`
- Find most recent session
- Load conversation history
- Resume from where left off

### `clio --input "text" --exit`
- Non-interactive mode
- Process input and exit immediately
- Used for scripting/automation

---

## Configuration

### Locations
- **API Keys:** `~/.clio/config.json`
- **Sessions:** `./sessions/` (project directory)
- **Custom Instructions:** `./.clio/instructions.md` (project directory)
- **System Prompts:** `~/.clio/system-prompts/` (user home)

### Setup Process
```bash
clio --new           # First run
: /login            # Authorize with GitHub Copilot
: /config show      # View config
: /api provider     # Check current provider
```

---

## Dependencies

### Required (Perl Core)
- `strict`, `warnings` (language features)
- `JSON::PP` (JSON parsing)
- `HTTP::Tiny` (HTTP requests, built-in)
- `File::Spec` (cross-platform paths)
- `File::Temp` (temporary files)
- `Cwd` (working directory)
- `FindBin` (script location)
- Plus many other core modules

### Optional
- `Term::ReadLine` (command history)
- System `git` (version control)
- System `perl` (for script execution)

### NOT Used
- ❌ CPAN modules (intentional design choice)
- ❌ External npm/pip packages
- ❌ Build tools like Make or Gradle

---

## Testing

### Test Framework
- `lib/CLIO/Test/Framework.pm` - Test utilities
- `tests/run_all_tests.pl` - Test runner
- `tests/**/*.t` - Individual test files

### Current Coverage
- ✅ Encoding tests: 171/171 PASS
- ✅ CLI tests: 9/9 PASS
- ⚠️ Tool operations: Basic coverage
- ⚠️ Integration: Spot checks only

### Run Tests
```bash
./tests/run_all_tests.pl --all
```

---

## Performance Considerations

### Speed
- Direct tool invocation (no remote API for file ops)
- Streaming responses from AI (no wait for full response)
- Token counting for efficient context usage

### Memory
- Session data in `sessions/` (JSON files)
- In-memory conversation history
- Token estimator helps avoid OOM

### Scalability
- Not designed for 1000s of projects
- Designed for individual developer workflows
- Can handle large codebases (>1GB)

---

## Limitations & Future Work

### Known Limitations
1. **Hardcoded prints** - 415 debug statements bypass theme system
2. **Code analysis** - Tree-sitter integration limited
3. **Memory optimization** - Caching could be smarter
4. **Tab completion** - Only basic support
5. **IDE plugins** - None yet

### Future Improvements
- [📋] IDE integrations (VSCode, Vim)
- [📋] Advanced code analysis
- [📋] Machine learning for smarter suggestions
- [📋] Community protocol handlers
- [📋] Performance profiling & optimization

---

## Module Organization

```
lib/CLIO/
├── UI/                      # Terminal interface
│   ├── Chat.pm             # Main interactive loop
│   ├── Markdown.pm         # Markdown to ANSI
│   ├── ANSI.pm             # Color codes
│   └── Theme.pm            # Color themes
├── Core/                   # Core AI functionality
│   ├── APIManager.pm       # AI provider integration
│   ├── SimpleAIAgent.pm    # AI request/response
│   ├── PromptManager.pm    # System prompts
│   ├── InstructionsReader.pm # Custom instructions
│   ├── WorkflowOrchestrator.pm # Multi-step workflows
│   ├── ToolExecutor.pm     # Tool invocation
│   ├── Config.pm           # Configuration
│   └── ... (10+ other core modules)
├── Tools/                  # Tool implementations
│   ├── FileOperations.pm   # File I/O
│   ├── VersionControl.pm   # Git
│   ├── TerminalOperations.pm # Shell execution
│   ├── Memory.pm           # Memory operations
│   ├── TodoList.pm         # Todo tracking
│   └── ... (other tools)
├── Session/                # Session management
│   ├── Manager.pm          # Session CRUD
│   ├── State.pm            # Conversation state
│   ├── TodoStore.pm        # Todo persistence
│   └── ToolResultStore.pm  # Result caching
├── Memory/                 # Memory systems
│   ├── ShortTerm.pm        # Session context
│   ├── LongTerm.pm         # Persistent storage
│   ├── YaRN.pm             # Conversation threading
│   └── TokenEstimator.pm   # Token counting
├── Code/                   # Code analysis
│   ├── TreeSitter.pm       # AST parsing
│   ├── Symbols.pm          # Symbol extraction
│   └── Relations.pm        # Symbol relationships
├── Protocols/              # Protocol handlers
│   ├── Manager.pm          # Protocol registry
│   ├── Architect.pm        # Design protocol
│   ├── Editor.pm           # Code editing protocol
│   └── ... (other protocols)
├── Security/               # Security & auth
│   ├── Auth.pm             # OAuth
│   ├── Authz.pm            # Authorization
│   └── PathAuthorizer.pm   # File access control
└── ... (other modules)
```

---

## For Developers

### Getting Started
1. **Read:** `docs/CUSTOM_INSTRUCTIONS.md` - How projects customize CLIO
2. **Read:** `docs/FEATURE_COMPLETENESS.md` - What's complete vs partial
3. **Check:** `ai-assisted/THE_UNBROKEN_METHOD.md` - Development methodology
4. **Explore:** Individual module POD docs

### Understanding Code
- Start with `clio` script entry point
- Follow to `Chat.pm` for UI loop
- Check `SimpleAIAgent.pm` for AI interaction
- See `ToolExecutor.pm` for tool invocation

### Adding Features
1. Follow The Unbroken Method (see ai-assisted/)
2. Check FEATURE_COMPLETENESS.md for status
3. Implement in appropriate module
4. Add tests
5. Update relevant docs

### Common Tasks
- **Fix bug:** Find module → Read code → Fix → Test → Commit
- **Add tool:** Create `lib/CLIO/Tools/MyTool.pm` → Register in main script
- **Add protocol:** Create `lib/CLIO/Protocols/MyProtocol.pm` → Register in Manager
- **Update UI:** Modify `lib/CLIO/UI/Chat.pm` or `Theme.pm`

---

## Summary

CLIO is a **well-architected, modular system** with:
- ✅ Clear separation of concerns
- ✅ Extensible tool and protocol systems
- ✅ Persistent session management
- ✅ Custom instructions per-project
- ✅ Professional terminal UI
- ⚠️ Some advanced features partially complete
- 📋 Room for optimization and expansion

The codebase is **designed for clarity and maintainability**, making it straightforward to understand, extend, and improve.
