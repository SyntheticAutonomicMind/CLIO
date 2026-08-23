# CLIO Developer Guide

**Complete guide to extending and contributing to CLIO**

---------------------------------------------------

## Table of Contents

1. [Introduction](#introduction)
2. [Architecture Overview](#architecture-overview)
3. [Code Organization](#code-organization)
4. [Development Setup](#development-setup)
5. [Adding New Tools](#adding-new-tools)
6. [Adding New AI Providers](#adding-new-ai-providers)
7. [Testing](#testing)
8. [Unified Model Capability System](#unified-model-capability-system)
9. [Prompt Pipeline Protocol](#prompt-pipeline-protocol)
10. [Code Standards](#code-standards)
11. [Contribution Workflow](#contribution-workflow)

---------------------------------------------------

## Introduction

### Welcome!

CLIO is built with extensibility in mind. Whether you want to add new tools, integrate additional AI providers, or enhance existing features, this guide will help you contribute effectively.

### Prerequisites

Before contributing, you should be familiar with:

- **Perl**: Object-oriented Perl, modules, references
- **Terminal UI**: ANSI escape codes, terminal interaction
- **AI APIs**: REST APIs, JSON, streaming responses
- **Git**: Branching, commits, pull requests

### Development Philosophy

CLIO follows these principles:

1. **No CPAN Dependencies**: Use core Perl modules only
2. **Tool-Powered**: AI interacts through well-defined tools
3. **Action Transparency**: Every operation shows what it's doing
4. **Session Persistence**: State survives across restarts
5. **Professional UX**: Terminal UI should be polished and usable

---------------------------------------------------

## Architecture Overview

### High-Level Design

```mermaid
graph TD
    UI["User Interface<br/>Chat, Markdown, ANSI"]
    Agent["Core AI Agent<br/>WorkflowOrchestrator, APIManager"]
    Registry["Tool Registry<br/>Tool Executor"]
    Session["Session Manager<br/>Persistence"]
    Tools["Tools Layer<br/>FileOps | VersionControl | Terminal | Memory | etc."]
    
    UI --> Agent
    Agent --> Registry
    Agent --> Session
    Registry --> Tools
    
    style UI fill:#e1f5ff
    style Agent fill:#fff3e0
    style Registry fill:#e8f5e9
    style Session fill:#fce4ec
    style Tools fill:#f3e5f5
```

### Core Components

**1. WorkflowOrchestrator** (`lib/CLIO/Core/WorkflowOrchestrator.pm`)
- Main agent loop for interactive and non-interactive operation
- Orchestrates the full turn cycle: message building, API calls, tool execution
- Handles proactive context trimming before each API call
- Manages streaming responses and keypress interrupt detection

**2. APIManager** (`lib/CLIO/Core/APIManager.pm`)
- Abstracts AI provider APIs
- Handles authentication
- Manages streaming responses
- Error handling and retries

**3. Tool Registry** (`lib/CLIO/Tools/Registry.pm`)
- Registers all available tools
- Routes operations to appropriate tools
- Manages tool definitions for AI

**4. Session Manager** (`lib/CLIO/Session/*.pm`)
- Persists conversation history
- Manages session state
- Handles session resumption

**5. UI Components** (`lib/CLIO/UI/*.pm`)
- Chat: Chat interface and main interactive loop
- Markdown: Markdown rendering
- ANSI: ANSI escape code management
- Theme: Color schemes and templates
- Display: Display utilities
- ToolOutputFormatter: Tool output formatting

### Data Flow

**User Input Flow:**
```text
User Input -> Chat -> WorkflowOrchestrator -> APIManager -> AI Provider
                                     v
                              Tool Selection
                                     v
                             Tool Execution
                                     v
                            Result Collection
                                     v
                          AI Response Generation
                                     v
                            Markdown Rendering
                                     v
                              User Output
```

**Tool Execution Flow:**
```text
AI Request -> Tool Registry -> Route to Tool -> Execute Operation
                                                    v
                                              Return Result
                                                    v
                                           Action Description
                                                    v
                                            Back to AI Agent
```

---------------------------------------------------

## Code Organization

### Directory Structure

```text
clio/
  clio                      # Main executable
  install.sh                # Installation script
  check-deps                # Dependency checker
  lib/CLIO/                 # Core library
      Core/                 # Core components
          APIManager.pm     # AI provider integration, token management
          WorkflowOrchestrator.pm  # Main agent loop and tool orchestration
          SimpleAIAgent.pm  # Lightweight AI agent for internal tasks
          ToolExecutor.pm   # Tool invocation and secret redaction
          Config.pm         # Configuration management
          Logger.pm         # Logging utilities
          PromptManager.pm  # System prompt management
          PromptBuilder.pm  # Prompt construction utilities
          InstructionsReader.pm  # Custom instructions reader
          ConversationManager.pm  # Conversation history management
          ModelCapabilitiesManager.pm  # AI model capabilities
          ModelDataLoader.pm  # Unified model capability data loader
          ToolCallExtractor.pm  # Extract tool calls from AI responses
          ToolErrorGuidance.pm  # Contextual error recovery hints
          ErrorContext.pm   # Error taxonomy and structured context
          AgentLoop.pm      # Persistent agent execution loop
          DeviceRegistry.pm # Named devices for remote execution
          SkillManager.pm   # AI skill management
          SkillRepository.pm # Skill repository configuration
          RepositoryLoader.pm # Load skills from Git repos
          PerformanceMonitor.pm  # Performance tracking
          RateLimiter.pm    # API rate limiting
          PluginManager.pm  # Plugin system
          Defaults.pm       # Default configuration values
          API/              # API sub-modules
              MessageValidator.pm  # Message validation and proactive trimming
              ResponseHandler.pm   # AI provider response parsing
          ReadLine.pm  Editor.pm
          HashtagParser.pm  TabCompletion.pm
          GitHubAuth.pm  GitHubCopilotModelsAPI.pm  CopilotUserAPI.pm
      Tools/                # Tool implementations
          Tool.pm           # Base tool class
          Registry.pm       # Tool registry
          FileOperations.pm # File tools (17 operations)
          VersionControl.pm # Git tools (11 operations)
          TerminalOperations.pm
          MemoryOperations.pm
          TodoList.pm
          WebOperations.pm
          CodeIntelligence.pm   # Code analysis
          Interact.pm  # User interaction
          SubAgentOperations.pm # Multi-agent
          RemoteExecution.pm    # Remote SSH execution
          ApplyPatch.pm         # Patch application
          MCPBridge.pm          # MCP tool bridge
      UI/                   # User interface
          Chat.pm           # Chat interface
          Markdown.pm       # Markdown renderer
          ANSI.pm           # ANSI codes
          Theme.pm          # Theming system
          Display.pm        # Display utilities
          ToolOutputFormatter.pm  # Tool output formatting
          CommandHandler.pm # Slash command routing
          ProgressSpinner.pm  # Animated busy indicator
          Multiplexer.pm    # Multiplexer detection and pane management
          StreamingController.pm # Streaming response display and pagination
          PaginationManager.pm # Page-based output display
          DiffRenderer.pm   # Unified diff display with syntax coloring
          Terminal.pm       # Terminal capability detection
          HostProtocol.pm   # Structured protocol for GUI host apps
          Multiplexer/      # Multiplexer drivers
              Tmux.pm  Screen.pm  Zellij.pm
          Commands/         # Slash command handlers
              Base.pm       # Base class with display delegation for all command modules
              AI.pm  API.pm  Billing.pm  Config.pm  Context.pm
              Device.pm  File.pm  Git.pm  Log.pm  Memory.pm
              Mux.pm  Profile.pm  Project.pm  Prompt.pm
              Session.pm  Skills.pm  Spec.pm  Stats.pm
              SubAgent.pm  System.pm  Todo.pm  Update.pm
              API/          # API sub-command handlers
                  Auth.pm  Config.pm  Models.pm
      Session/              # Session management
          Manager.pm        # Session manager
          State.pm          # Session state
          TodoStore.pm      # Todo persistence
          ToolResultStore.pm # Large result storage
          FileVault.pm      # Targeted file backup for undo
          Export.pm         # Session export to HTML
          Lock.pm           # Session locking
      Coordination/         # Multi-agent coordination
          Broker.pm         # Coordination server (auto-exits after 5 min idle)
          Client.pm         # Broker connection API
          SubAgent.pm       # Process spawning
      Security/             # Auth/authz
          Auth.pm           # Authentication
          Authz.pm          # Authorization
          PathAuthorizer.pm # File access control
          Manager.pm        # Security management
          SecretRedactor.pm # PII/secret redaction
          InvisibleCharFilter.pm  # Invisible Unicode character defense
      Memory/               # Context/memory
          ShortTerm.pm      # Conversation context
          LongTerm.pm       # Persistent memory
          YaRN.pm           # Context windowing
          TokenEstimator.pm # Token counting
      Profile/              # User personality profile
          Analyzer.pm       # Session history analysis
          Manager.pm        # Profile storage and injection
      Providers/            # Native API providers
          Base.pm           # Provider base class
          Anthropic.pm      # Anthropic native API
          Google.pm         # Google Gemini native API
          NVIDIA.pm         # NVIDIA NIM native API
          # Other providers (DeepSeek, MiniMax, Z.AI, OpenRouter, Ollama Cloud,
          # GitHub Copilot, etc.) are configured in Providers.pm directly
      MCP/                  # Model Context Protocol
          Manager.pm        # MCP server management
          Client.pm         # MCP client
          Auth/OAuth.pm     # MCP OAuth 2.0 support
          Transport/Stdio.pm  Transport/HTTP.pm
      Code/                 # Code intelligence
          TreeSitter.pm     # Tree-sitter integration
          Symbols.pm        # Symbol extraction
          Relations.pm      # Code relations
      Logging/              # Logging system
          ToolLogger.pm     # Tool operation logging
          ProcessStats.pm   # Process statistics
      Util/                 # Utilities
          PathResolver.pm   # Path resolution and tilde expansion
          TextSanitizer.pm  # Text sanitization
          JSONRepair.pm     # JSON repair for malformed AI output
          JSON.pm           # JSON module selection (XS > PP fallback)
          GitIgnore.pm      # Auto-manage .clio/ in .gitignore
          InputHelpers.pm   # Terminal input utilities
          AnthropicXMLParser.pm  # XML-format tool call parser
          YAML.pm           # Lightweight YAML parser
          ConfigPath.pm     # Config path resolution
      Spec/                 # OpenSpec integration
          Manager.pm        # Spec lifecycle management
      Test/                 # Testing utilities
          MockAPI.pm        # Mock API for tests
      Compat/               # Compatibility layers
          HTTP.pm  Terminal.pm
  docs/                     # User documentation
  styles/                   # Color style files (26 themes)
  tests/                    # Test suites
  sessions/                 # Saved sessions (gitignored)
```

### Module Naming Conventions

- **Core modules**: `CLIO::Core::*` - System components
- **Tools**: `CLIO::Tools::*` - Tool implementations
- **UI**: `CLIO::UI::*` - User interface components
- **Session**: `CLIO::Session::*` - Session management
- **Coordination**: `CLIO::Coordination::*` - Multi-agent coordination
- **Security**: `CLIO::Security::*` - Authentication and authorization
- **Memory**: `CLIO::Memory::*` - Context and memory system
- **Providers**: `CLIO::Providers::*` - Native API provider modules
- **MCP**: `CLIO::MCP::*` - Model Context Protocol integration
- **Code**: `CLIO::Code::*` - Code intelligence and analysis
- **Util**: `CLIO::Util::*` - Utilities

### File Naming

- Perl modules: `CamelCase.pm` (e.g., `FileOperations.pm`)
- Scripts: `lowercase_underscore.sh`
- Documentation: `UPPERCASE.md` or `CamelCase.md`

---------------------------------------------------

## Development Setup

### Clone and Install

```bash
# Clone repository
git clone https://github.com/SyntheticAutonomicMind/CLIO.git
cd CLIO

# Install for development (user mode, no sudo)
./install.sh --user

# Or install system-wide
sudo ./install.sh
```

### Running from Source

**Without installing:**

```bash
# Run directly from source
perl -I lib clio --new

# With debug output
perl -I lib clio --debug --new
```

**With installed version:**

```bash
clio --debug
```

### Development Tools

**Syntax checking:**

```bash
# Check specific module
perl -I lib -c lib/CLIO/Tools/MyNewTool.pm

# Check all modules
find lib -name "*.pm" -exec perl -I lib -c {} \;
```

**Testing:**

```bash
# Run test suite
prove -I lib t/

# Manual testing
./clio --new
```

**Uninitialized-value detection:**

```bash
# Run all tests under perl -W to surface uninitialized warnings
perl tests/run_strict_tests.pl

# Run single test with warnings as fatal
perl tests/run_strict_tests.pl --fatal tests/unit/test_command_handler.pl

# Quiet mode (only show failures)
perl tests/run_strict_tests.pl --quiet
```

---------------------------------------------------

## Adding New Tools

### Tool Structure

Every tool inherits from `CLIO::Tools::Tool` and implements a standard interface.

### Step-by-Step: Create a New Tool

**1. Create the Tool Module**

Create `lib/CLIO/Tools/MyNewTool.pm`:

```perl
package CLIO::Tools::MyNewTool;

use strict;
use warnings;
use feature 'say';
use parent 'CLIO::Tools::Tool';

=head1 NAME

CLIO::Tools::MyNewTool - Brief description

=head1 DESCRIPTION

Detailed description of what this tool does and when to use it.

=cut

sub new {
    my ($class, %opts) = @_;
    
    return $class->SUPER::new(
        name => 'my_new_tool',
        description => 'What this tool does and when to use it',
        supported_operations => [qw(operation1 operation2)],
        debug => $opts{debug} || 0,
    );
}

sub route_operation {
    my ($self, $operation, $params, $context) = @_;
    
    if ($operation eq 'operation1') {
        return $self->handle_operation1($params, $context);
    }
    elsif ($operation eq 'operation2') {
        return $self->handle_operation2($params, $context);
    }
    else {
        return $self->operation_error("Unknown operation: $operation");
    }
}

sub get_additional_parameters {
    my ($self) = @_;
    
    return {
        param1 => {
            type => "string",
            description => "Description of parameter 1",
        },
        param2 => {
            type => "integer",
            description => "Description of parameter 2",
        },
    };
}

sub handle_operation1 {
    my ($self, $params, $context) = @_;
    
    # Extract parameters
    my $param1 = $params->{param1};
    
    # Validate
    unless ($param1) {
        return $self->operation_error("Missing required parameter: param1");
    }
    
    # Set action description (CRITICAL for UX)
    $self->set_action_description("Brief description of what this operation is doing");
    
    # Do the work
    my $result = "Result of operation1";
    
    # Return success
    return $self->operation_success($result);
}

sub handle_operation2 {
    my ($self, $params, $context) = @_;
    
    # Similar structure...
    $self->set_action_description("Operation 2 description");
    
    my $result = "Result of operation2";
    return $self->operation_success($result);
}

1;  # End of module MUST return true
```

**2. Register the Tool**

Edit `lib/CLIO/Tools/Registry.pm`:

```perl
use CLIO::Tools::MyNewTool;
```

Tool registration in WorkflowOrchestrator is data-driven. Add your tool to the `@tool_defs` array in `_register_default_tools()`:

```perl
# In WorkflowOrchestrator::_register_default_tools()
my @tool_defs = (
    # ... existing tools ...
    {
        name  => 'my_new_tool',
        class => 'CLIO::Tools::MyNewTool',
        args  => { debug => $self->{debug} },
    },
);
```

Tools listed here are automatically subject to `--enable`/`--disable` filtering. If a tool should only register when a specific config key is set (like `enable_remote` for RemoteExecution), add a `config_gate` key:

```perl
{
    name        => 'my_new_tool',
    class       => 'CLIO::Tools::MyNewTool',
    args        => { debug => $self->{debug} },
    config_gate => 'enable_my_tool',  # only registers if this config key is truthy
},
```

**3. Test Your Tool**

```bash
# Syntax check
perl -I lib -c lib/CLIO/Tools/MyNewTool.pm

# Test in CLIO
./clio --new

# In conversation:
YOU: Use my_new_tool with operation1 and param1="test value"
```

### Tool Best Practices

**Action Descriptions:**

Always set clear action descriptions:

```perl
$self->set_action_description("reading ./config.yaml (45 lines)");
$self->set_action_description("executing git status in ./");
$self->set_action_description("searching ./lib for pattern 'TODO'");
```

Format: `<verb>ing <target> (<additional context>)`

**Error Handling:**

```perl
eval {
    # Operation that might fail
};
if ($@) {
    my $error = $@;
    log_error('MyNewTool', "Operation failed: $error");
    return $self->operation_error($error);
}
```

**Parameter Validation:**

```perl
# Check required parameters
unless ($params->{required_param}) {
    return $self->operation_error("Missing required parameter: required_param");
}

# Validate types
unless ($params->{count} =~ /^\d+$/) {
    return $self->operation_error("Parameter 'count' must be an integer");
}

# Validate paths (for file operations)
use File::Spec;
my $safe_path = File::Spec->canonpath($params->{path});
```

**Return Values:**

```perl
# Success with result
return $self->operation_success($result_data);

# Success with message
return $self->operation_success($result_data, "Custom success message");

# Error
return $self->operation_error("Error message explaining what went wrong");
```

**Adding Operation-Name Aliases:**

When an LLM sends a tool call with a natural-language operation name that isn't in the canonical set (e.g., `list_directory` instead of `list_dir`), the tool returns `Unknown operation: ... Did you mean: list_dir?` and the call fails. The `dispatch_table` design in `lib/CLIO/Tools/Tool.pm:138-144` already supports aliases: "Aliases are supported by mapping multiple keys to the same method."

To add an alias to a tool:

1. Add the alias to `supported_operations` in the tool's `new()` method. This surfaces it in the JSON schema's `operation` enum and in error messages.
2. Add the alias as a key in `dispatch_table` that maps to the same method name as the canonical entry.

Example (in `lib/CLIO/Tools/FileOperations.pm`):

```perl
# supported_operations
supported_operations => [qw(
    read_file read          # read is an alias for read_file
    list_dir list_directory  # list_directory is an alias for list_dir
    ...
)],

# dispatch_table
sub dispatch_table {
    return {
        read_file      => 'read_file',
        read           => 'read_file',       # alias
        list_dir       => 'list_dir',
        list_directory => 'list_dir',        # alias
        ...
    };
}
```

Add tests under `tests/unit/test_<tool>_aliases.pl` that invoke each alias with realistic parameters and assert the dispatch produces the expected result. See `tests/unit/test_file_operations_aliases.pl` for the pattern.

Guidelines for choosing aliases:
- Prefer unambiguous mappings: a single alias should point to one operation.
- Skip aliases that could be confused with another operation (e.g., `read` could mean `read_file` or `read_tool_result`; pick the most common).
- Short Unix-style names (`mv`, `mkdir`, `rm`) are good aliases when the canonical name is verbose.
- Adding to `supported_operations` puts the alias in the JSON schema enum, so well-behaved LLMs learn about it from the system prompt.

---------------------------------------------------

## Adding New AI Providers

### Provider Architecture

CLIO's provider system is built into APIManager.pm. Each provider is defined by its configuration (endpoints, headers, payload format) rather than a separate class. The `_prepare_api_request` method builds provider-specific payloads, and `ResponseHandler.pm` parses responses.

**Key files to modify:**
- `lib/CLIO/Core/APIManager.pm` - Add provider config, endpoint logic
- `lib/CLIO/Core/API/ResponseHandler.pm` - Handle provider-specific response formats
- `lib/CLIO/Core/ModelCapabilitiesManager.pm` - Add model definitions and metadata
- `lib/CLIO/Core/Config.pm` - Add provider defaults (base URL, etc.)

**Step 1: Add provider config in Config.pm**

Add your provider to `_get_provider_defaults()`:

```perl
myprovider => {
    base_url => 'https://api.myprovider.com/v1',
    model => 'my-model-latest',
},
```

**Step 2: Add endpoint logic in APIManager**

In `_prepare_api_request()`, add a case for your provider to build the correct URL, headers, and payload format. Most providers follow the OpenAI chat completions format (`/chat/completions` endpoint with messages array).

**Step 3: Add model metadata in ModelCapabilitiesManager**

Define available models with their context windows and capabilities:

```perl
'my-model-latest' => {
    context_window => 128000,
    max_output_tokens => 16384,
    supports_tools => 1,
    supports_streaming => 1,
    reasoning_mode => 'effort',  # or 'enabled', 'adaptive', undef
},
```

**Step 4: Handle response quirks in ResponseHandler**

If the provider returns tool calls, reasoning content, or error codes differently from the OpenAI format, add handling in ResponseHandler.pm.

**Step 5: Add to PROVIDERS.md documentation**

**Reference implementation:** See the MiniMax provider for a recent example of adding a new provider with Token Plan billing, static model lists, and reasoning content support.

---------------------------------------------------

## Unified Model Capability System

Since commit `df34c34` (2026-08-03), CLIO maintains unified model capability data in JSON files instead of hardcoded maps:

| File | Purpose |
|------|---------|
| `lib/CLIO/Core/model-data/models.json` | Primary model capability database |
| `lib/CLIO/Core/model-data/provider-defaults.json` | Provider fallback defaults |
| `lib/CLIO/Core/model-data/heuristics.json` | Pattern-based fallback rules |
| `lib/CLIO/Core/model-data/provider-mapping.json` | Provider-to-model ID mappings |

**Key modules:**
- `ModelDataLoader.pm` - Loads and caches the JSON data
- `ModelCapabilitiesManager.pm` - Queries capabilities (with provider API fallback)
- `ModelDataTester.pm` - Test script for verifying model data

When adding new models or providers:
1. Add entries to `models.json` and `provider-mapping.json`
2. Run `perl -I./lib lib/CLIO/Core/ModelDataTester.pm <provider> <model>` to verify
3. The system automatically falls back to provider API `/models` endpoints, then heuristics, then provider defaults.

---------------------------------------------------

## Prompt Pipeline Protocol

Every API request CLIO sends follows a fixed seven-slot layout for LCP (Longest Common Prefix) cache stability:

```
[0] system_prompt      Static (built once per session; includes tools schema)
[1] summary            CSSS slot; regenerates within size budget
[2] context_files      User-added files (stable until /context add|remove)
[3] dialog             user / assistant alternating (chronological)
[4] tool_results       Deinterleaved to END; oldest first
[5] user_context       Dynamic (date/time, working dir, LTM, session goals)
[6] user_input         Current turn's raw user input (no prefix)
```

**Key invariants:**
- Sections [0..2] are the **stable anchor** - only invalidate when tools change, summary regenerates, or context files change
- Section [5] is the **dynamic anchor** - changes every minute (date/time cache). When it changes, only [5] onwards is reprocessed
- Section [6] is always fresh

**System messages are NOT merged.** `ConversationManager::enforce_message_alternation` excludes `role=system` from its merge rule. Each section [0], [1], [2], [5] is its own message.

**Trim policy:**
- [0], [1], [5], [6] - NEVER trimmed (anchors + active request)
- [2] - trimmed with dialog budget walk
- [3] - primary trim target (oldest dialog dropped first)
- [4] - secondary trim target (oldest tool_results dropped first)

Full specification: [`docs/SPECS/PROMPT_PIPELINE.md`](docs/SPECS/PROMPT_PIPELINE.md)

**Tests covering the protocol:**
- `tests/unit/test_cache_stable_layout.pl`
- `tests/unit/test_cache_stable_summary.pl`
- `tests/unit/test_session_cached_payload.pl`
- `tests/unit/test_conversation_manager_multimodal.pl`
- `tests/unit/test_conversation_manager.pl`
- `tests/unit/test_provider_cache_control.pl`
- `tests/integration/test_session_resume_cached_payload.pl`

Any change to message ordering, role assignment, trim policy, snapshot signatures, or provider cache adaptations must update these tests.

---------------------------------------------------

## Testing

### Manual Testing

**Basic functionality:**

```bash
# Test tool execution
echo "list files in current directory" | ./clio --new --exit

# Test session persistence
./clio --new
# Have a conversation
# Exit and resume
./clio --resume
```

**Edge cases:**

```bash
# Large files
echo "read a 10MB file" | ./clio --new --exit

# Invalid input
echo "read a file that doesn't exist" | ./clio --new --exit

# Complex operations
echo "search for TODO in all Perl files, create a summary" | ./clio --new --exit
```

### Automated Testing

**Unit tests** (`tests/unit/`):

```perl
# tests/unit/tools/file_operations.t
use Test::More tests => 5;
use CLIO::Tools::FileOperations;

my $tool = CLIO::Tools::FileOperations->new();

# Test read_file operation
my $result = $tool->route_operation('read_file', {
    path => 'test_file.txt',
    start_line => 1,
    end_line => 10,
}, {});

ok($result->{success}, 'read_file succeeds');
like($result->{data}, qr/content/, 'read_file returns content');

done_testing();
```

**Integration tests** (`tests/integration/`):

```perl
# tests/integration/session_persistence.t
use Test::More;
use CLIO::Session::Manager;

# Create session
my $mgr = CLIO::Session::Manager->new();
my $session = $mgr->create();

# Add conversation
$session->add_message({ role => 'user', content => 'test' });

# Save
$mgr->save($session);

# Load
my $loaded = $mgr->load($session->id());

is($loaded->id(), $session->id(), 'Session ID preserved');

done_testing();
```

**Running tests:**

```bash
# All unit tests
perl tests/run_all_tests.pl

# Single unit test
perl -I./lib tests/unit/test_file_operations.pl

# Integration tests
perl -I./lib tests/integration/test_collaborative_team.pl

# Performance benchmarks
perl -I./lib tests/benchmark.pl
```

---------------------------------------------------

## Code Standards

> **See Also:** [Developer Documentation Guide](DEVELOPER_DOCUMENTATION_GUIDE.md) for complete POD documentation standards, code commenting guidelines, and technical writing best practices.

### Perl Best Practices

**Module Structure:**

```perl
package CLIO::Module::Name;

use strict;
use warnings;
use feature 'say';

# POD documentation
=head1 NAME

CLIO::Module::Name - Brief description

=head1 DESCRIPTION

Detailed description.

=cut

# Code here

1;  # Module MUST return true
```

**Naming:**

```perl
# Variables: snake_case
my $file_path = "/path/to/file";
my $line_count = 0;

# Subroutines: snake_case
sub read_file { ... }
sub parse_response { ... }

# Packages: CamelCase
package CLIO::Core::AIAgent;

# Constants: UPPERCASE
use constant MAX_RETRIES => 3;
```

**Error Handling:**

```perl
# Use eval for exception handling
eval {
    # Code that might die
};
if ($@) {
    my $error = $@;
    log_error('MyModule', "Operation failed: $error");
    # handle error
}
```

**Logging:**

```perl
use CLIO::Core::Logger qw(log_debug log_info log_warning log_error should_log);

# Debug logging (only emitted when --debug flag is set)
log_debug('MyModule', 'Processing request');

# Info, warning, error logging
log_info('MyModule', 'Starting operation');
log_warning('MyModule', 'Retrying after failure');
log_error('MyModule', "Fatal: $@");

# Conditional guard (use when constructing an expensive message)
log_debug('MyModule', 'Details: ' . $detail) if should_log('DEBUG');
```

**No CPAN Dependencies:**

```perl
# [OK] Use core modules
use JSON::PP;      # Core since 5.14
use HTTP::Tiny;    # Core since 5.14
use File::Spec;    # Core

# [FAIL] Don't use CPAN modules
use Moo;           # Not core
use LWP::UserAgent # Not core
```

**Terminal and Process Safety:**

When spawning child processes (shell commands, ssh, compilers, etc.), always use process groups to ensure cleanup on timeout or interrupt:

```perl
# CORRECT: use process groups so kill() reaches all descendants
use POSIX qw(setpgid WNOHANG);

my $pid = fork();
if ($pid == 0) {
    # Child: create own process group
    setpgid(0, 0);
    exec($command) or die "exec failed: $!";
}

# Parent: kill the whole group on timeout/interrupt
kill('-TERM', $pid);   # SIGTERM to process group (negative = group)
sleep(2);
kill('-KILL', $pid) if kill(0, $pid);  # SIGKILL if still alive
waitpid($pid, WNOHANG);
```

**NEVER use `alarm()` or `local $SIG{ALRM}` in tool execution code.** Chat.pm's 1-second ALRM timer drives ESC interrupt detection. Clobbering it breaks keyboard responsiveness. For timeouts, use a fork+waitpid poll loop instead:

```perl
# CORRECT: poll loop with Time::HiRes (doesn't touch ALRM)
use Time::HiRes qw(time);
my $deadline = time() + $timeout;
while (1) {
    my $done = waitpid($pid, WNOHANG);
    last if $done;
    last if time() > $deadline;
    select(undef, undef, undef, 0.1);  # 100ms poll interval
}

# WRONG: destroys the ESC interrupt timer
local $SIG{ALRM} = sub { kill 'TERM', $pid };
alarm($timeout);
waitpid($pid, 0);
alarm(0);
```

### Documentation Standards

**POD for modules:**

```perl
=head1 NAME

CLIO::Tools::MyTool - Brief description

=head1 SYNOPSIS

    use CLIO::Tools::MyTool;
    
    my $tool = CLIO::Tools::MyTool->new();
    my $result = $tool->route_operation('op', $params, $context);

=head1 DESCRIPTION

Detailed description of the module.

=head2 method_name

Description of what this method does.

Arguments:
- $arg1: Description
- $arg2: Description

Returns: Description of return value

=cut
```

**Inline comments:**

```perl
# Explain WHY, not WHAT
# Bad:
my $count = 0;  # Initialize count to zero

# Good:
my $count = 0;  # Track number of failed retries for exponential backoff
```

---------------------------------------------------

## Contribution Workflow

### Before Contributing

1. **Read The Unbroken Method**: `cat ai-assisted/THE_UNBROKEN_METHOD.md`
2. **Check existing issues**: Search for related work
3. **Discuss major changes**: Open an issue first for large features
4. **Consider using CLIO**: CLIO is developed using CLIO itself. Using CLIO for your contributions helps you understand the tool from a user's perspective and ensures your changes work well in practice.

### Development Workflow

**1. Fork and Clone:**

```bash
# Fork on GitHub, then:
git clone https://github.com/YOUR_USERNAME/CLIO.git
cd CLIO
git remote add upstream https://github.com/SyntheticAutonomicMind/CLIO.git
```

**2. Create Feature Branch:**

```bash
git checkout -b feature/my-new-feature
```

**3. Make Changes:**

```bash
# Edit code
# Test changes
perl -I lib -c lib/CLIO/Tools/MyNewTool.pm
./clio --debug
```

**4. Commit:**

```bash
git add -A
git commit -m "feat(tools): add MyNewTool for X functionality

**Problem:**
[what was missing or broken]

**Solution:**
[how you fixed or built it]

**Testing:**
[OK] Syntax: PASS (perl -c)
[OK] Manual: [what you tested]
[OK] Edge cases: [what you verified]"
```

**Commit message format:**
```text
type(scope): brief description

**Problem:**
What was broken or missing

**Solution:**
How you fixed it

**Testing:**
What you tested
```

**Types:** feat, fix, refactor, docs, test, chore

**5. Push and PR:**

```bash
git push origin feature/my-new-feature
```

Then open a Pull Request on GitHub.

### Code Review

**Expect reviewers to check:**
- Code quality and style
- Test coverage
- Documentation completeness
- No CPAN dependencies
- Action descriptions present
- Error handling

**Be prepared to:**
- Answer questions about design decisions
- Make requested changes
- Add tests if missing
- Update documentation

---------------------------------------------------

## Resources

**Documentation:**
- `docs/SPECS/` - Technical specifications (Architecture, Tools)
- `docs/ARCHITECTURE.md` - Architecture overview
- `docs/ARCHITECTURE_REMOTE_EXECUTION.md` - Remote execution design spec
- `docs/COMMAND_OUTPUT_STANDARDS.md` - Command output styling standards
- `docs/DEVELOPER_DOCUMENTATION_GUIDE.md` - Developer documentation standards
- `docs/DOCUMENTATION_GUIDE.md` - User-facing documentation standards
- `docs/PERFORMANCE.md` - Performance benchmarks and optimization
- `docs/FORMULA_RENDERING.md` - Mathematical formula rendering
- `docs/STYLE_GUIDE.md` / `docs/STYLE_QUICKREF.md` - Color theme reference
- `docs/SPECS/PROMPT_PIPELINE.md` - Prompt pipeline protocol specification

**Code Examples:**
- `lib/CLIO/Tools/FileOperations.pm` - Comprehensive tool example
- `lib/CLIO/Tools/TodoList.pm` - State management example
- `lib/CLIO/UI/Markdown.pm` - UI component example

**Community:**
- [GitHub Issues](https://github.com/SyntheticAutonomicMind/CLIO/issues)
- [GitHub Discussions](https://github.com/SyntheticAutonomicMind/CLIO/discussions)

---------------------------------------------------

## Next Steps

1. **Set up your development environment**
2. **Read existing code** - Understand patterns
3. **Pick a small task** - Start with documentation or minor feature
4. **Ask questions** - Use GitHub Discussions
5. **Submit your first PR!**

**Welcome to CLIO development!**
