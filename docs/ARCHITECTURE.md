# CLIO Architecture

**Last Updated:** January 2025

---------------------------------------------------

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

---------------------------------------------------

## System Components

### 1. User Interface Layer
**Files:** `lib/CLIO/UI/`

| Component | File | Purpose |
|-----------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------|
| Terminal UI | `Chat.pm` | Main interaction loop, streaming output |
| Markdown Renderer | `Markdown.pm` | Convert markdown to ANSI |
| Color/ANSI | `ANSI.pm` | ANSI escape sequences |
| Themes | `Theme.pm` | Color themes and styling |

**How it works:**
1. User types message
2. Chat.pm sends to AI
3. Stream responses back to terminal
4. Markdown rendering converts formatting
5. Apply theme colors

### 2. Core AI & Workflow
**Files:** `lib/CLIO/Core/`

| Component | File | Purpose |
|-----------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------|
| API Manager | `APIManager.pm` | AI provider integration |
| Simple AI Agent | `SimpleAIAgent.pm` | Handles AI requests/responses |
| AI Agent | `AIAgent.pm` | Advanced AI agent capabilities |
| Workflow Orchestrator | `WorkflowOrchestrator.pm` | Complex multi-step workflows |
| Task Orchestrator | `TaskOrchestrator.pm` | Task management and orchestration |
| Tool Executor | `ToolExecutor.pm` | Invokes tools |
| Tool Call Extractor | `ToolCallExtractor.pm` | Extract tool calls from AI responses |
| Prompt Manager | `PromptManager.pm` | System prompts + custom instructions |
| Instructions Reader | `InstructionsReader.pm` | Reads `.clio/instructions.md` |
| Protocol Integration | `ProtocolIntegration.pm` | Integrate protocol handlers |
| Config | `Config.pm` | API keys, provider selection |
| ReadLine | `ReadLine.pm` | Command history & editing |
| Command Parser | `CommandParser.pm` | Parse user commands |
| Editor | `Editor.pm` | Core editing functionality |
| Hashtag Parser | `HashtagParser.pm` | Parse hashtag commands |
| Tab Completion | `TabCompletion.pm` | Tab completion support |
| Skill Manager | `SkillManager.pm` | Manage AI skills |
| GitHub Auth | `GitHubAuth.pm` | GitHub OAuth authentication |
| GitHub Copilot Models API | `GitHubCopilotModelsAPI.pm` | Access GitHub Copilot models |
| Performance Monitor | `PerformanceMonitor.pm` | Track performance metrics |
| Logger | `Logger.pm` | Debug and trace output |

**How it works:**
1. APIManager connects to AI provider (GitHub Copilot, OpenAI, etc.)
2. WorkflowOrchestrator manages complex interactions
3. PromptManager provides system prompt + custom instructions
4. ToolExecutor invokes selected tools
5. Results processed and returned

### 3. Tool System
**Files:** `lib/CLIO/Tools/`

| Tool | File | Operations |
|------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| File Operations | `FileOperations.pm` | read, write, search, create, delete, rename, etc. |
| Version Control | `VersionControl.pm` | git status, log, diff, commit, branch, push, pull |
| Terminal | `TerminalOperations.pm` | exec - run shell commands |
| Memory | `MemoryOperations.pm` | store, retrieve, search, list, delete |
| Todo | `TodoList.pm` | create, update, complete, list, track tasks |
| Code Intelligence | `CodeIntelligence.pm` | list_usages - find symbol references |
| Web | `WebOperations.pm` | fetch_url, search_web |
| User Collaboration | `UserCollaboration.pm` | request_input - checkpoint prompts |
| Result Storage | `ResultStorage.pm` | Store and retrieve tool results |
| Base Tool | `Tool.pm` | Abstract base class for all tools |
| Registry | `Registry.pm` | Tool registration and lookup |

**Architecture:**
- Base class: `Tool.pm` provides abstract interface
- Each tool extends Tool.pm and implements execute()
- `Registry.pm` maintains tool registry and handles lookup
- `ToolExecutor.pm` (in Core) invokes tools and manages execution
- `ResultStorage.pm` caches large tool outputs for efficiency

### 4. Session Management
**Files:** `lib/CLIO/Session/`

| Component | File | Purpose |
|-----------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------|
| Session Manager | `Manager.pm` | Create/load/resume sessions |
| Session State | `State.pm` | Conversation history, metadata |
| Todo Store | `TodoStore.pm` | Persist todos across sessions |
| Tool Result Store | `ToolResultStore.pm` | Cache tool results for large output |

**How it works:**
1. New session: Create `sessions/UUID.json`
2. Each message appended to conversation history
3. Sessions persist on disk (in `sessions/` directory)
4. Resume: Load session from disk, continue conversation

### 5. Memory System
**Files:** `lib/CLIO/Memory/`

| Component | File | Purpose |
|-----------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------|
| Short-Term | `ShortTerm.pm` | Session context |
| Long-Term | `LongTerm.pm` | Persistent storage |
| YaRN | `YaRN.pm` | Conversation threading |
| Token Estimator | `TokenEstimator.pm` | Count tokens for context |

**How it works:**
- Short-term memory maintains current session context
- Long-term memory provides persistent storage across sessions
- YaRN manages conversation threading and context windows
- Token estimator prevents context overflow

### 6. Code Analysis
**Files:** `lib/CLIO/Code/`

| Component | File | Purpose |
|-----------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------|
| Tree-sitter | `TreeSitter.pm` | Parse code into AST |
| Symbols | `Symbols.pm` | Extract function/class names |
| Relations | `Relations.pm` | Map symbol relationships |

**How it works:**
- TreeSitter parses source code into abstract syntax trees
- Symbols extracts function/class/variable definitions
- Relations maps dependencies and call graphs

### 7. Security
**Files:** `lib/CLIO/Security/`

| Component | File | Purpose |
|-----------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------|
| Auth | `Auth.pm` | GitHub OAuth, token storage |
| Authz | `Authz.pm` | Check file access permissions |
| Path Authorizer | `PathAuthorizer.pm` | Control file access |
| Manager | `Manager.pm` | Overall security |

**How it works:**
1. User runs `/login` → GitHub device flow
2. Token stored securely in `~/.clio/`
3. File operations check PathAuthorizer
4. Audit logging of all operations

### 8. Logging & Monitoring
**Files:** `lib/CLIO/Logging/`, `lib/CLIO/Core/`

| Component | File | Purpose |
|-----------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------|
| Logger | `Core/Logger.pm` | Debug/trace output |
| Tool Logger | `Logging/ToolLogger.pm` | Log tool operations |
| Performance Monitor | `Core/PerformanceMonitor.pm` | Track timing |

**How it works:**
- Debug mode: `clio --debug`
- Output goes to STDERR with `[DEBUG]`, `[ERROR]`, `[TRACE]` prefixes
- Tool operations logged via ToolLogger

### 9. Protocol System
**Files:** `lib/CLIO/Protocols/`

| Protocol | File | Purpose |
|----------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------|
| Architect | `Architect.pm` | Problem-solving design |
| Editor | `Editor.pm` | Code modification format |
| Validate | `Validate.pm` | Code validation |
| Tree-sitter | `TreeSit.pm` | AST integration |
| RepoMap | `RepoMap.pm` | Repository mapping |
| Recall | `Recall.pm` | Memory recall |
| Model | `Model.pm` | AI model management protocol |
| Handler | `Handler.pm` | Protocol base class |
| Manager | `Manager.pm` | Protocol registry |

**How it works:**
1. AI returns natural language protocol commands
2. ProtocolIntegration.pm parses them
3. Manager looks up protocol handler
4. Handler executes the protocol
5. Results sent back to AI

---------------------------------------------------

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

---------------------------------------------------

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

---------------------------------------------------

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

---------------------------------------------------

## Dependencies

### Required (Perl Core Only)
- `strict`, `warnings` (language features)
- `JSON::PP` (JSON parsing, core since 5.14)
- `HTTP::Tiny` (HTTP requests, core since 5.14)
- `MIME::Base64` (base64 encoding, core since 5.8)
- `Digest::SHA` (SHA hashing, core since 5.10)
- `File::Spec` (cross-platform paths, core)
- `File::Path` (directory operations, core)
- `File::Temp` (temporary files, core)
- `File::Find` (file tree traversal, core)
- `File::Basename` (path manipulation, core)
- `Time::HiRes` (high-resolution timers, core since 5.8)
- `POSIX` (POSIX functions, core)
- `Cwd` (working directory, core)
- Plus other core modules

### Optional (Non-Core, Graceful Degradation)
- `Text::Diff` (diff visualization - has fallback if not installed)

### External Tools Required
- System `git` (for version control operations)
- System `perl` 5.20+ (for script execution)

### NOT Used
- ❌ CPAN modules (except optional Text::Diff with fallback)
- ❌ External npm/pip packages  
- ❌ Build tools like Make or Gradle
- ❌ Term::ReadLine (not required, uses basic readline if missing)

---------------------------------------------------

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

---------------------------------------------------

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

---------------------------------------------------

## Architectural Considerations

### Design Principles
1. **Modularity** - Each component has a single, well-defined responsibility
2. **Extensibility** - Tools and protocols can be added without modifying core
3. **Separation of Concerns** - UI, AI, tools, and storage are independent layers
4. **Graceful Degradation** - Optional features fail safely (e.g., Text::Diff)

### Extension Points
- **Tools**: Create new tool in `lib/CLIO/Tools/`, register in Registry
- **Protocols**: Create protocol handler in `lib/CLIO/Protocols/`, extend Handler.pm
- **UI Themes**: Add theme file in `themes/`, define color scheme
- **AI Providers**: Add provider logic in Core/APIManager.pm

---------------------------------------------------

## Module Organization

```
lib/CLIO/
├── Providers.pm             # AI provider registry (SAM, GitHub Copilot, etc.)
├── UI/                      # Terminal interface
│   ├── Chat.pm              # Main interactive loop
│   ├── Markdown.pm          # Markdown to ANSI
│   ├── ANSI.pm              # Color codes
│   └── Theme.pm             # Color themes
├── Core/                    # Core AI functionality
│   ├── APIManager.pm        # AI provider integration
│   ├── SimpleAIAgent.pm     # AI request/response
│   ├── AIAgent.pm           # Advanced AI agent
│   ├── PromptManager.pm     # System prompts
│   ├── InstructionsReader.pm # Custom instructions
│   ├── WorkflowOrchestrator.pm # Multi-step workflows
│   ├── TaskOrchestrator.pm  # Task orchestration
│   ├── ToolExecutor.pm      # Tool invocation
│   ├── ToolCallExtractor.pm # Extract tool calls
│   ├── ProtocolIntegration.pm # Protocol integration
│   ├── Config.pm            # Configuration
│   ├── ReadLine.pm          # Command history
│   ├── CommandParser.pm     # Command parsing
│   ├── Editor.pm            # Core editing
│   ├── HashtagParser.pm     # Hashtag commands
│   ├── TabCompletion.pm     # Tab completion
│   ├── SkillManager.pm      # AI skills
│   ├── GitHubAuth.pm        # OAuth
│   ├── GitHubCopilotModelsAPI.pm # Copilot models
│   ├── PerformanceMonitor.pm # Performance tracking
│   └── Logger.pm            # Logging
├── Tools/                   # Tool implementations
│   ├── Tool.pm              # Base class
│   ├── Registry.pm          # Tool registry
│   ├── ResultStorage.pm     # Result caching
│   ├── FileOperations.pm    # File I/O
│   ├── VersionControl.pm    # Git
│   ├── TerminalOperations.pm # Shell execution
│   ├── MemoryOperations.pm  # Memory operations
│   ├── TodoList.pm          # Todo tracking
│   ├── CodeIntelligence.pm  # Code analysis
│   ├── UserCollaboration.pm # User checkpoints
│   └── WebOperations.pm     # Web operations
├── Session/                 # Session management
│   ├── Manager.pm           # Session CRUD
│   ├── State.pm             # Conversation state
│   ├── TodoStore.pm         # Todo persistence
│   └── ToolResultStore.pm   # Result caching
├── Memory/                  # Memory systems
│   ├── ShortTerm.pm         # Session context
│   ├── LongTerm.pm          # Persistent storage
│   ├── YaRN.pm              # Conversation threading
│   └── TokenEstimator.pm    # Token counting
├── Code/                    # Code analysis
│   ├── TreeSitter.pm        # AST parsing
│   ├── Symbols.pm           # Symbol extraction
│   └── Relations.pm         # Symbol relationships
├── Protocols/               # Protocol handlers
│   ├── Manager.pm           # Protocol registry
│   ├── Handler.pm           # Base class
│   ├── Architect.pm         # Design protocol
│   ├── Editor.pm            # Code editing protocol
│   ├── Validate.pm          # Validation protocol
│   ├── TreeSit.pm           # Tree-sitter protocol
│   ├── RepoMap.pm           # Repository mapping
│   ├── Recall.pm            # Memory recall
│   └── Model.pm             # Model management
├── Security/                # Security & auth
│   ├── Auth.pm              # OAuth
│   ├── Authz.pm             # Authorization
│   ├── PathAuthorizer.pm    # File access control
│   └── Manager.pm           # Security manager
├── Logging/                 # Logging system
│   └── ToolLogger.pm        # Tool operation logging
├── Test/                    # Testing framework
│   └── Framework.pm         # Test utilities
├── Util/                    # Utility modules
│   ├── PathResolver.pm      # Path resolution
│   ├── TextSanitizer.pm     # Text sanitization
│   └── ... (other utilities)
├── NaturalLanguage/         # NL processing
│   └── ... (NL modules)
└── Compat/                  # Compatibility layer
    └── ... (compatibility modules)
```

---------------------------------------------------

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

---------------------------------------------------

## Summary

CLIO follows a **layered architecture** with clear separation of concerns:

```
┌─────────────────────────────────┐
│   User Interface Layer       │  (UI/)
├─────────────────────────────────┤
│   AI & Workflow Layer        │  (Core/)
├─────────────────────────────────┤
│   Tool Execution Layer       │  (Tools/)
├─────────────────────────────────┤
│   Storage & Persistence      │  (Session/, Memory/)
└─────────────────────────────────┘
```

**Key Architectural Features:**
- **Plugin-based tool system** - Tools register dynamically
- **Protocol-driven AI interaction** - Structured AI communication
- **Persistent session state** - Conversation history survives restarts
- **Zero external dependencies** - Runs with Perl core modules only
- **Modular design** - Each component can evolve independently

The architecture prioritizes **clarity, maintainability, and extensibility** - making it straightforward for developers to understand the codebase and add new capabilities.
