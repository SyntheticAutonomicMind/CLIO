# AGENTS.md

**Version:** 3.2
**Date:** 2026-06-28
**Purpose:** Technical reference for CLIO development (methodology in .clio/instructions.md)

---

## Project Overview

**CLIO** (Command Line Intelligence Orchestrator) is an AI-powered development assistant built in Perl.

- **Language:** Perl 5.32+
- **Architecture:** Tool-calling AI assistant with terminal UI
- **Philosophy:** The Unbroken Method (see .clio/instructions.md)

---

## Quick Setup

```bash
# Install dependencies
# Run CLIO (no dependencies to install - pure core Perl)
./clio --new

# Debug mode
./clio --debug --new

# Quick test
./clio --input "test query" --exit
```

---

## Architecture

```
User Input
    |
    v
Terminal UI (Chat.pm)
    |
    v
AI Agent (APIManager -> Provider)
    |
    v
Tool Selection (WorkflowOrchestrator)
    |
    v
Tool Execution (ToolExecutor)
    |
    +-- file_operations (read, write, search, edit)
    +-- version_control (git, worktrees, diff)
    +-- terminal_operations (shell exec)
    +-- memory_operations (store, recall, LTM)
    +-- todo_operations (task management)
    +-- web_operations (fetch, search)
    +-- code_intelligence (usages, history)
    +-- interact (checkpoints)
    +-- apply_patch (diff-based editing)
    +-- remote_execution (SSH + parallel) [conditional]
    +-- agent_operations (multi-agent) [conditional]
    +-- skill_operations (skill management) [conditional]
    +-- MCPBridge (MCP server tools) [dynamic]
    +-- PluginBridge (plugin tools) [dynamic]
    |
    v
Result Processing
    |
    v
Markdown Rendering (Markdown.pm)
    |
    v
Terminal Output (with color/theme)
```

---

## Directory Structure

| Path | Purpose |
|------|---------|
| `lib/CLIO.pm` | Root package loader |
| `lib/CLIO/Update.pm` | Self-update flow |
| `lib/CLIO/Core/` | System core (APIs, workflow, config, prompts, diagnostics) |
| `lib/CLIO/Core/API/` | APIManager sub-modules (ResponseHandler, MessageValidator, ErrorHandler, PayloadSanitizer) |
| `lib/CLIO/Core/SkillRepository.pm` | Skill repository configuration and management |
| `lib/CLIO/Core/RepositoryLoader.pm` | Load skills from cached Git repositories |
| `lib/CLIO/Code/` | Code intelligence primitives (TreeSitter) |
| `lib/CLIO/Test/` | Test infrastructure (MockAPI) |
| `lib/CLIO/Tools/` | AI-callable tools (16 modules) |
| `lib/CLIO/UI/` | Terminal UI (Chat, Markdown, Theme, Commands, Multiplexer) |
| `lib/CLIO/UI/Commands/` | Slash command handlers (23 command modules across multiple categories) |
| `lib/CLIO/UI/Multiplexer/` | Terminal multiplexer support |
| `lib/CLIO/Session/` | Session management (Manager, State, FileVault, Lock, Export, TodoStore, ToolResultStore) |
| `lib/CLIO/Memory/` | Context/memory system (YaRN, TokenEstimator, ShortTerm, LongTerm) |
| `lib/CLIO/Profile/` | User personality profile (Analyzer, Manager) |
| `lib/CLIO/Protocols/` | Complex workflows (Puppeteer) |
| `lib/CLIO/Providers/` | Direct API providers (Anthropic, Google, NVIDIA, Base, DeepSeek, MiniMax, Z.AI, OpenRouter, Ollama Cloud, GitHub Copilot, SAM, llama.cpp, LM Studio) |
| `lib/CLIO/Coordination/` | Multi-agent coordination (Broker, Client, SubAgent) |
| `lib/CLIO/MCP/` | Model Context Protocol (Manager, Client, Transport::HTTP, Transport::Stdio, Auth::OAuth) |
| `lib/CLIO/Security/` | Auth/authz (Auth, Authz, AuthorizationRelay, CommandAnalyzer, InvisibleCharFilter, PathAuthorizer, SecretRedactor) |
| `lib/CLIO/Logging/` | Structured logging (Logger, ProcessStats, ToolLogger) |
| `lib/CLIO/Compat/` | Compatibility layers (Terminal, HTTP) |
| `lib/CLIO/Util/` | Utilities (PathResolver, TextSanitizer, JSON, JSONRepair, YAML, ImageAttachment, ImageDisplay, ConfigPath, AtomicWrite, RateLimit, GitIgnore, AnthropicXMLParser, CABundle, Curl, InputHelpers, Proxy, UUID) |
| `lib/CLIO/Spec/` | OpenSpec integration (Manager) |
| `lib/CLIO/Core/model-data/` | Unified model capability JSON files (models.json, provider-defaults.json, heuristics.json, provider-mapping.json) |
| `docs/` | User/dev documentation |
| `styles/` | Terminal color styles (26 themes: dark, light, retro, cyberpunk, monokai, etc.) |
| `themes/` | UI themes (compact, console, default, verbose) |
| `tools/` | Repo-local tooling (assess_codebase.pl, ASSESSMENT_METHODOLOGY.md) |
| `tests/unit/` | Single module tests |
| `tests/integration/` | Cross-module tests (e2e, subagent, broker) |
| `tests/manual/` | Manual test scripts |
| `tests/performance/` | Long-running performance tests |
| `tests/benchmark.pl` | Performance benchmark suite |
| `tests/run_all_tests.pl` | Test runner |
| `reference/` | Vendored reference projects (aider, opencode, MiniMax-CLI, etc.) |
| `terminal-bench/` | Terminal-Bench evaluation harness (clio_tb_agent.py) |
| `tb-results/` | Terminal-Bench run results (CSV summaries) |
| `runs/` | Per-run artifacts |
| `sessions/` | Long-lived session storage |
| `ai-assisted/` | Session handoff notes (YYYYMMDD/HHMM/ folders) |
| `scripts/` | Release scripts |
| `examples/` | Example projects (currently empty placeholder) |
| `scratch/` | Gitignored working docs (analysis, plans, audits) |

**Key Files:**

- `clio` - Main executable
- `lib/CLIO/Core/WorkflowOrchestrator.pm` - Tool orchestration
- `lib/CLIO/Core/APIManager.pm` - AI provider integration
- `lib/CLIO/UI/Chat.pm` - Terminal interface
- `lib/CLIO/Core/ToolExecutor.pm` - Tool invocation
- `lib/CLIO/Tools/FileOperations.pm` - File system operations (17 ops)
- `lib/CLIO/Tools/Registry.pm` - Tool registration
- `lib/CLIO/Core/PluginManager.pm` - Plugin lifecycle
- `lib/CLIO/Core/PromptBuilder.pm` - Prompt construction
- `lib/CLIO/Core/PromptManager.pm` - Prompt template storage
- `lib/CLIO/Core/ModelDataLoader.pm` - Unified model capability data loader
- `lib/CLIO/Core/model-data/models.json` - Primary model capability database
- `lib/CLIO/Core/model-data/provider-defaults.json` - Provider fallback defaults
- `lib/CLIO/Core/model-data/heuristics.json` - Pattern-based fallback rules
- `lib/CLIO/Core/model-data/provider-mapping.json` - Provider-to-model ID mappings

## Image Support

CLIO supports multimodal image upload and display:

**Upload (User -> Model):**
- `lib/CLIO/Util/ImageAttachment.pm` - Reads, validates, base64-encodes image files
- `lib/CLIO/UI/Chat.pm` - Parses `@path/to/image.png` syntax from user input
- `lib/CLIO/Core/WorkflowOrchestrator.pm` - Builds multimodal messages with array-format content
- `lib/CLIO/Core/APIManager.pm` - Handles arrayref content in Chat Completions and Responses API payloads

**Display (Model -> User):**
- `lib/CLIO/Util/ImageDisplay.pm` - Displays images inline via kitty/iTerm protocols, or saves to file
- `lib/CLIO/UI/Terminal.pm` - Detects terminal image protocol support (kitty, iTerm, sixel)

**Token Estimation:**
- `lib/CLIO/Memory/TokenEstimator.pm` - Estimates tokens for multimodal content (85 tokens per image)

**Message Handling:**
- `lib/CLIO/Core/ConversationManager.pm` - Handles arrayref content in message merging and truncation

**Investigate, don't assume:** Use `git log --oneline -20`, `find lib -name "*.pm"`, read actual code.

---

## Cache-Stable Summary Slot (CSSS)

The proactive trim in `MessageValidator` regenerates a `thread_summary` whenever it drops messages. Without CSSS, every trim changes the summary text - which invalidates llama.cpp's prompt cache for everything after the summary position in the prompt. This causes the agent to reprocess the full conversation on every trim cycle (huge CPU cost for local inference at ~400 tok/s).

**How CSSS works:**

1. After the first trim, the summary's current token count becomes the **locked slot size**.
2. The slot is bounded by `MIN_CSSS_SLOT_TOKENS` (8K) and `MAX_CSSS_SLOT_TOKENS` (12K) to prevent starvation (slot too small to hold captured state) and unbounded growth.
3. The slot can grow proactively: if the amount of content dropped in a trim exceeds 1.5x the current slot size, the slot is grown to absorb more tokens. This prevents aggressive trims from forcing the summary into hard-truncation and silently dropping captured state.
4. On every subsequent trim, `YaRN::compress_messages` is called with `target_tokens => $slot_size`.
5. `_fit_summary_to_target` (in `YaRN.pm`) adjusts the summary to fit:
   - Too big: drops sections in least-critical-first order (tool_counts, decisions, files, commits, collab, user_requests), then hard-truncates as a last resort. The `Current task` line is always preserved (extracted before truncation and prepended after).
   - Too small: pads with a deterministic HTML comment (`<!-- csss:padding:xxxxx -->`) so byte-identical padding regenerates across calls.
6. The summary is placed at the **end** of the conversation (after recent messages), so even summary content changes only invalidate the summary tokens themselves.

**Slot bounds:**

- `MIN_CSSS_SLOT_TOKENS` (8192) in `lib/CLIO/Core/Defaults.pm` - prevents the first-trim slot from being too small to hold captured state
- `MAX_CSSS_SLOT_TOKENS` (12000) in `lib/CLIO/Core/Defaults.pm` - hard ceiling on slot growth; one 25% step at a time
- `DEFAULT_POST_TRIM_FLOOR` (24000) in `lib/CLIO/Core/Defaults.pm` - minimum tokens kept verbatim after trimming (compromise between 32K conservative and 12K aggressive)

**Combined with summary-at-end ordering:**
- Recent messages stay at constant positions across trims
- Cache hit on system prompt + recent messages; only the small summary slot is reprocessed

**Tool-output reserve optimization:**

`compute_prompt_budget($caps, tools => $tools)` automatically caps the output reserve at `DEFAULT_TOOL_OUTPUT_RESERVE` (8K) when the model supports tools and tools are present in the request. Tool-calling responses rarely exceed a few hundred tokens; reserving the full `max_output_tokens` (often 32K) wastes ~24K of prompt budget. This is a per-request check, so non-tool workflows use the full reserve.

**Configuration:**

- `DEFAULT_TOOL_OUTPUT_RESERVE` in `lib/CLIO/Core/Defaults.pm` (default 8192) - adjust if your tool calls regularly exceed this
- No user-facing config; the optimization is automatic for any tool-calling model

**Diagnostics:**

```
[DEBUG][MessageValidator] CSSS: locking summary slot to 3500 tokens (existing summary)
[DEBUG][YaRN] CSSS: padded summary to 3506 tokens (target: 3500)
[DEBUG][MessageValidator] CSSS: cache impact ~50/83000 tokens invalidated (summary slot)
```

**Tests:** `tests/unit/test_cache_stable_summary.pl` covers CSSS lock behavior, summary-at-end ordering, tool-reserve capping, and YaRN fit behavior.

**Session resume and trim recovery:**

When resuming a session, the orchestrator reuses the last API payload from `state->{last_api_payload}` (the exact `@messages` array last sent to the provider). If the saved payload is smaller than `MIN_CSSS_SLOT_TOKENS` and contains a `thread_summary` (indicating it was trimmed), the orchestrator falls back to a full history rebuild instead of reusing the truncated payload. This prevents the agent from resuming with an empty or near-empty context after aggressive trim.

---

## Model Selection

**Use MiniMax M3 for all sub-agents:**
```
agent_operations(operation: "spawn", task: "...", working_dir: "./CLIO", model: "minimax/MiniMax-M3")
```

MiniMax-M3 via MiniMax is the recommended default for all standard tasks: investigation, QA, implementation, code review, refactoring, documentation.

---

## Code Style

**Perl Conventions:**

- Perl 5.32+ with `use strict; use warnings; use utf8;`
- **UTF-8 encoding** for all files
- **4 spaces** indentation (never tabs)
- **POD documentation** for all modules
- **Minimal CPAN deps** (prefer core Perl)

**Module Template:**

```perl
package CLIO::Module::Name;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

=head1 NAME

CLIO::Module::Name - Brief description

=head1 DESCRIPTION

Detailed description of module purpose and behavior

=head1 SYNOPSIS

    use CLIO::Module::Name;
    
    my $obj = CLIO::Module::Name->new();
    $obj->method();

=cut

# Implementation...

1;  # MANDATORY: End every .pm file with 1;
```

**Debug Logging:**

```perl
use CLIO::Core::Logger qw(log_debug log_info log_warning log_error);

# Logger functions handle level-checking internally:
log_debug('ModuleName', 'detailed message');
log_info('ModuleName', 'informational message');
log_warning('ModuleName', 'something unexpected');
log_error('ModuleName', 'something failed: %s', $error);
```

---

## Module Naming Conventions

| Prefix | Purpose | Examples |
|--------|---------|----------|
| `CLIO::Core::` | System core | APIManager, WorkflowOrchestrator, ToolExecutor, Config, PromptManager, ModelCapabilitiesManager, ModelDataLoader |
| `CLIO::Core::API::` | APIManager sub-modules | ResponseHandler, MessageValidator, ErrorHandler, PayloadSanitizer |
| `CLIO::Tools::` | AI-callable tools | FileOperations, VersionControl, TerminalOperations, MemoryOperations, Interact, ApplyPatch, CodeIntelligence, RemoteExecution, SubAgentOperations, TodoList, WebOperations, SkillOperations, MCPBridge, PluginBridge, Registry, Tool |
| `CLIO::UI::` | Terminal interface | Chat, Markdown, Theme, ANSI, CommandHandler, DiffRenderer, Display, HostProtocol, Multiplexer, PaginationManager, ProgressSpinner, StreamingController, Terminal, ToolOutputFormatter |
| `CLIO::UI::Commands::` | Slash command handlers | AI, API, Billing, Config, Context, Device, File, Git, Log, Memory, Mux, Profile, Project, Prompt, Session, Skills, Spec, Stats, SubAgent, System, Todo, Update |
| `CLIO::Session::` | Session management | Manager, State, FileVault, Lock, Export, TodoStore, ToolResultStore |
| `CLIO::Memory::` | Context/memory | ShortTerm, LongTerm, YaRN, TokenEstimator |
| `CLIO::Providers::` | Provider registry + native providers | Anthropic, Google, NVIDIA, Base (15 providers configured in Providers.pm) |
| `CLIO::Coordination::` | Multi-agent coordination | Broker, Client, SubAgent |
| `CLIO::MCP::` | Model Context Protocol | Manager, Client, Transport::Stdio, Transport::HTTP, Auth::OAuth |
| `CLIO::Profile::` | User profiling | Analyzer, Manager |
| `CLIO::Protocols::` | Complex workflows | Puppeteer |
| `CLIO::Security::` | Auth/authz | Auth, Authz, AuthorizationRelay, CommandAnalyzer, InvisibleCharFilter, PathAuthorizer, SecretRedactor |
| `CLIO::Logging::` | Structured logging | Logger, ProcessStats, ToolLogger |
| `CLIO::Compat::` | Compatibility | Terminal (ReadKey, ReadMode), HTTP |
| `CLIO::Util::` | Utilities | PathResolver, TextSanitizer, JSONRepair, JSON, YAML, ImageAttachment, ImageDisplay, ConfigPath, AtomicWrite, RateLimit, GitIgnore, AnthropicXMLParser, CABundle, Curl, InputHelpers, Proxy, UUID |
| `CLIO::Spec::` | OpenSpec integration | Manager (spec lifecycle management) |
| `CLIO::Code::` | Code intelligence | TreeSitter |
| `CLIO::Test::` | Test infrastructure | MockAPI |

---

## Testing

**Before Committing:**

```bash
# 1. Syntax check specific module
perl -I./lib -c lib/CLIO/Core/MyModule.pm

# 2. All syntax checks
find lib -name "*.pm" -exec perl -I./lib -c {} \;

# 3. Run unit test
perl -I./lib tests/unit/test_mymodule.pl

# 4. Run all unit tests for a component
cd tests/unit && for t in test_<component>*.pl; do perl -I../../lib $t; done

# 5. Integration test
./clio --debug --input "test your change" --exit

# 6. Check for errors
./clio --input "complex test" --debug --exit 2>&1 | grep ERROR
```

**Test Locations:**

- `tests/unit/` - Single module tests
- `tests/integration/` - Cross-module tests

**Test Requirements:**

1. **Syntax must pass** - All changed .pm files must pass `perl -c`
2. **Unit tests must exist** - New features require new tests
3. **Tests must pass** - Exit code 0 required
4. **Integration testing** - Complex features need end-to-end verification

**New Feature Checklist:**

1. Create: `tests/unit/test_your_feature.pl`
2. Run: `perl -I./lib tests/unit/test_your_feature.pl`
3. Verify exit code 0
4. Include in commit


### Detecting Uninitialized-Value Warnings (Whole Codebase)

CLIO enables `use warnings;` per module template, but a warning only fires when the offending code path is actually executed at runtime. The unit suite can pass on a code path that's never exercised, and a regression can ship (e.g. typing `/` at the prompt used to emit `Use of uninitialized value within @parts in lc at CommandHandler.pm line 257` because no test exercised the slash-only input).

Use `tests/run_strict_tests.pl` to re-run every test under `perl -W` and surface uninitialized-value (and other) warnings:

```bash
# Run all tests/unit/*.pl under -W
perl tests/run_strict_tests.pl

# Run a single test
perl tests/run_strict_tests.pl tests/unit/test_command_handler.pl

# Run under warnings FATAL=>'all' (any warning aborts the test)
perl tests/run_strict_tests.pl --fatal tests/unit/test_command_handler.pl

# Quiet mode (only print failing tests)
perl tests/run_strict_tests.pl --quiet

# Also flag "Subroutine ... redefined" warnings (off by default because
# test scaffolding stubs CLIO::Compat::Terminal::GetTerminalSize and
# Chat display methods).
perl tests/run_strict_tests.pl --strict-redefine
```

The harness categorises warnings by source. CLIO warnings (paths containing `lib/CLIO/`) fail the run with a non-zero exit. Vendor warnings (perl core `/System/Library/Perl/`, CPAN) are reported as informational only - they are real Perl quirks (e.g. `File::Spec::Unix::_cached_tmpdir` warns about undef env-var caches) that CLIO cannot fix and should not block the run.

When adding a test for a code path that you suspect might emit a warning, capture warnings via `$SIG{__WARN__}` and assert zero uninit warnings fired (see `tests/unit/test_command_handler.pl` for the pattern).

### Adding Operation-Name Aliases to Tools

When an LLM sends a tool call with a natural-language operation name that isn't in the canonical set (e.g. `list_directory` instead of `list_dir`), the tool returns `Unknown operation: ... Did you mean: list_dir?` and the call fails. The `dispatch_table` design in `lib/CLIO/Tools/Tool.pm:138-144` already supports aliases: "Aliases are supported by mapping multiple keys to the same method."

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
- Skip aliases that could be confused with another operation (e.g. `read` could mean `read_file` or `read_tool_result`; pick the most common).
- Short Unix-style names (`mv`, `mkdir`, `rm`) are good aliases when the canonical name is verbose.
- Adding to `supported_operations` puts the alias in the JSON schema enum, so well-behaved LLMs learn about it from the system prompt. The `_suggest_operation` helper in `Tool.pm:161` also uses this list to produce "Did you mean" hints.


---

## Commit Format

```
type(scope): brief description

Problem: What was broken/incomplete
Solution: How you fixed it
Testing: How you verified the fix
```

**Types:** `feat`, `fix`, `refactor`, `docs`, `test`, `chore`

**Example:**

```bash
git add -A
git commit -m "fix(session): implement atomic writes

Problem: Session saves could corrupt on process kill
Solution: Added temp file + atomic rename pattern
Testing: Syntax checks passed, integration tests verified"
```

**Pre-Commit Checklist:**

-  `perl -c` passes on all changed .pm files
-  POD documentation updated if API changed
-  Commit message explains WHAT and WHY
-  No `TODO`/`FIXME` comments (finish the work)
-  Test coverage for new code
-  No handoff files in `ai-assisted/` staged

---

## Development Tools

**Terminal Testing:**

```bash
# Start debug session
./clio --debug --new

# Test specific input
./clio --input "read lib/CLIO/Core/Config.pm" --exit

# Syntax check all
find lib -name "*.pm" -exec perl -I./lib -c {} \;

# Search codebase
git grep "function_name" lib/

# Git operations
git status
git log --oneline -20
git diff
```

**Useful Commands:**

```bash
# File count by directory
find lib/CLIO/Core -name "*.pm" | wc -l
find lib/CLIO/Tools -name "*.pm" | wc -l

# Module sizes
ls -lh lib/CLIO/*/*.pm

# Find large modules
find lib -name "*.pm" -exec wc -l {} \; | sort -rn | head -20

# Recent changes
git log --oneline --since="1 week ago"
```

---

## Common Patterns

**Error Handling:**

```perl
use Carp qw(croak);

# Tool execution
eval {
    # Potentially failing operation
};
if ($@) {
    # Handle error with croak (not bare die)
    return error_result("Operation failed: $@");
}
```

**JSON Encoding:**

```perl
use CLIO::Util::JSON qw(encode_json decode_json);

# Auto-selects fastest available: JSON::XS > Cpanel::JSON::XS > JSON::PP
my $json = encode_json($data);

my $decoded = eval { decode_json($json) };
if ($@) {
    # Handle parse error
}
```

**File I/O:**

```perl
# Always specify UTF-8
open my $fh, '<:encoding(UTF-8)', $file or die "Cannot read: $!";
my $content = do { local $/; <$fh> };
close $fh;

# Atomic writes (prevents corruption)
my $temp = $file . '.tmp';
open my $fh, '>:encoding(UTF-8)', $temp or die;
print $fh $content;
close $fh;
rename $temp, $file or die;  # Atomic on Unix
```

---

## Documentation Standards

### Writing User-Facing Docs (README.md, USER_GUIDE.md, INSTALLATION.md)

**Tone:** Direct and concise. No corporate fluff.

- WRONG: "It might be helpful if you could potentially try running the command with the debug flag to see if that provides any additional information that could help diagnose the issue."
- RIGHT: "Run `--debug` to see diagnostic output."

**Active voice:** "CLIO reads the file" not "The file will be read by CLIO"

**Address user directly:** "Configure your API key" not "Users should configure their API keys"

**Code blocks:** Always specify language for syntax highlighting:
```markdown
```bash
./clio --new
```

```perl
my $config = CLIO::Core::Config->new();
```
```

**Examples:** Show both command AND expected output

**Terminology (use consistently):**

| Use This | Not This |
|----------|----------|
| API key | api key, API-key, api_key |
| API provider | provider, api provider |
| slash command | command, CLIO command |
| configuration | config, settings |
| file path | filepath, file-path |
| session | conversation, chat |
| terminal | console, command line |

---

### Writing Module Documentation (POD)

Every `.pm` file needs POD with these sections:

```perl
=head1 NAME

CLIO::Module::Name - Brief one-line description

=head1 SYNOPSIS

    use CLIO::Module::Name;
    
    my $obj = CLIO::Module::Name->new();
    $obj->method();

=head1 DESCRIPTION

Detailed description of module purpose and behavior.
What it does, why it exists, and how it fits in the architecture.

=head1 METHODS

=cut

=head2 method_name

What the method does.

Arguments:
    $arg1 - Description (required)
    $arg2 - Description (optional, default: undef)

Returns:
    What it returns and its structure

Example:
    my $result = $obj->method_name($arg1);

=cut

sub method_name {
    # ...
}
```

**Internal methods** (not part of public API):
```perl
=head2 _internal_method (Internal)

Do not call directly. Internal implementation detail.

=cut

sub _internal_method {
    # ...
}
```

---

### UI/UX Patterns (Chat.pm, Themes, Commands)

**Three-color rule for structured output:**
- DIM (chrome) - Bullets, arrows, separators
- ASSISTANT (names) - Headers, tool names
- DATA (content) - Values, descriptions

**Always use `colorize()`** - never hardcode ANSI codes:
```perl
# CORRECT
print $ui->colorize($text, 'DATA');

# WRONG - hardcoded ANSI
my $red = "\e[91m";
```

**Theme tokens for slash commands:**

| Token | Purpose | Default Color |
|-------|---------|---------------|
| `success_message` | Success | Green |
| `error_message` | Errors | Red |
| `warning_message` | Warnings | Yellow |
| `info_message` | Info | Cyan |
| `command_header` | Section headers | Bold Cyan |
| `command_label` | Key labels | Cyan |
| `command_value` | Values | White |

**Command headers use borders (70 chars):**
```perl
$self->display_command_header("SECTION NAME");
# ══════════════════════════════════════════════════════════════════════
# SECTION NAME
# ══════════════════════════════════════════════════════════════════════
```

**Slash commands:** Extend `CLIO::UI::Commands::Base`, use display helpers:
```perl
$self->display_key_value($label, $value);
$self->display_success_message("Done");
$self->display_error_message("Failed: $error");
```

---

### What Needs Documentation

| Change Type | Required Documentation |
|-------------|------------------------|
| New feature | POD + update AGENTS.md directory structure |
| API change | Update POD + update relevant user-facing doc |
| User-facing | Update USER_GUIDE.md or relevant feature doc |
| Module rename/move | Update AGENTS.md + ARCHITECTURE.md |

### Documentation Files

| File | Purpose |
|------|---------|
| `README.md` | Project overview |
| `docs/USER_GUIDE.md` | How to use CLIO |
| `docs/FEATURES.md` | Complete feature reference |
| `docs/ARCHITECTURE.md` | System design |
| `docs/STYLE_QUICKREF.md` | UI styling quick reference |
| `.clio/instructions.md` | Project methodology (Unbroken Method) |
| `AGENTS.md` | This file - technical reference |

**Full references for detailed guidance:**
- `docs/DOCUMENTATION_GUIDE.md` - User-facing writing style
- `docs/DEVELOPER_DOCUMENTATION_GUIDE.md` - POD templates and examples
- `docs/STYLE_GUIDE.md` - UI/UX patterns
- `docs/COMMAND_OUTPUT_STANDARDS.md` - Slash command patterns

---

### Keeping Documentation Current

When changing code, update docs accordingly:

1. **New tool/feature** - Add to FEATURES.md, update AGENTS.md tools list
2. **API behavior change** - Update relevant user guide section
3. **New module** - Add POD, update ARCHITECTURE.md module table
4. **UI changes** - Update STYLE_QUICKREF.md if needed

**Rule:** Full rewrite, never changelog patches. If a section needs updating, rewrite the entire section completely.

**Test your docs:** Run `clio --input "read docs/YOUR_FILE.md" --exit` to verify rendering.

---

### Working Documents (scratch/)

**Purpose:** The `scratch/` directory is your gitignored workspace for investigation, analysis, and planning documents.

**Use scratch/ for:**
- Code health assessments (`scratch/CODEBASE_REVIEW.md`)
- Refactoring roadmaps (`scratch/ACTION_PLAN.md`)
- Investigation summaries
- Analysis documents  
- Working notes
- Planning documents

**NEVER create these in project root** - they clutter the repository and violate project protocols.

**Why scratch/ exists:**
- Gitignored (won't be committed)
- Persistent across sessions (unlike ai-assisted/ handoffs)
- Shareable workspace for investigation findings
- Clear separation from committed documentation

**Pattern:**
```
Investigation findings -> scratch/ANALYSIS.md (not committed)
Session handoffs -> ai-assisted/YYYYMMDD/HHMM/ (not committed)
Permanent knowledge -> Detailed commit message (committed)
```

---

## Anti-Patterns (What NOT To Do)

**CRITICAL:** These are common mistakes that harm code quality and project workflow.

| Anti-Pattern | Why It's Wrong | What To Do |
|--------------|----------------|------------|
| Skip syntax check before commit | Causes silent failures in production | Run `perl -c` on all changed files |
| Use `print STDERR` for logging | Bypasses log level control | Use `log_debug()`, `log_info()`, `log_warning()`, `log_error()` |
| Label bugs as "out of scope" | Violates Complete Ownership principle | Fix bugs you find in your scope |
| Leave `TODO` comments in code | Creates technical debt, incomplete work | Finish implementation before committing |
| Assume code behavior | Causes bugs, breaks things | Read the code, investigate first |
| Create duplicate utility code | Re-implements existing solutions, creates inconsistency | Search codebase for existing implementations before writing new code |
| Commit without testing | Breaks builds, wastes time | Test syntax, run integration tests |
| Use bare `die` in modules | Crashes AI loop ungracefully | Use `croak` from Carp, with eval for error handling |
| Create giant modules (>1000 lines) | Hard to maintain and understand | Split into focused, cohesive modules |
| Create summary docs in root | Clutters repository, wrong location | Use scratch/ for working documents |
| Skip collaboration checkpoints | Violates Unbroken Method | Use interact at key decision points |
| Technical jargon in action_desc | Users don't care about implementation details | Use user-focused descriptions |
| Negative framing in user-facing messages | "This is not X" or "Retrying won't help" assumes the user has a mental model we haven't given them | State what IS true and what to do. Tell the user what action to take, not what this isn't |
| Changelog-style comments in code | Git history explains why; comments should describe what | Write comments for current state, not history |

**Technical jargon example:**
- WRONG: `"searching codebase (hybrid keyword+symbols)"` 
- RIGHT: `"searching codebase for 'X' (N matches)"`

The `action_description` appears in user-facing tool output. Keep it simple and focused on results, not implementation.

**Remember:** If you find yourself doing any of these, STOP and do it correctly.

---

## Maintenance Routines

These are recurring tasks that must be performed periodically to keep CLIO's
static data current. When starting a session, check if any of these are due.

### Model Capability Maps

Several providers don't return model metadata from their APIs, so CLIO maintains
static capability maps in `ModelCapabilitiesManager.pm`. These drift as providers
add and remove models.

**Providers with static maps:**

| Provider | Method | File Location | Last Updated |
|----------|--------|---------------|-------------|
| NVIDIA NIM | `_fetch_nvidia_capabilities` + `_nvidia_model_heuristics` | `lib/CLIO/Core/ModelCapabilitiesManager.pm` ~line 647 | 2026-06-11 |
| Z.AI | `_fetch_zai_capabilities` | Same file ~line 1412 | Check date |
| MiniMax | `_fetch_minimax_capabilities` | Same file ~line 1531 | Check date |
| DeepSeek | `_fetch_deepseek_capabilities` | Same file ~line 1626 | 2026-06-30 |

**How to update:**

1. Check the provider's model listing page:
   - NVIDIA NIM: https://build.nvidia.com/explore/discover
   - Z.AI: https://open.bigmodel.cn/dev/api/normal-model/glm-4
   - MiniMax: https://platform.minimaxi.com/document/Models
2. Cross-reference with OpenRouter's `/api/v1/models` endpoint (returns context_window and max_output_tokens)
3. Add new models to the static map with accurate context_window and max_output_tokens
4. Update heuristic patterns if new model families appear
5. Remove models that are no longer listed on the provider's site
6. Run the MCM test to verify all entries resolve:
   ```bash
   perl -I./lib -e '
     use CLIO::Core::ModelCapabilitiesManager;
     my $mcm = CLIO::Core::ModelCapabilitiesManager->new();
     my $caps = $mcm->get_capabilities("nvidia", "deepseek-ai/deepseek-v4-flash");
     print "ctx=$caps->{context_window} out=$caps->{max_output_tokens}\n";
   '
   ```
7. Update the "Last Updated" date in the table above

**When to update:**
- When a user reports a model showing "-" for context/output in `/api models`
- When a new model family appears (e.g., a new Llama or DeepSeek generation)
- Periodically (roughly monthly) as part of routine maintenance
- When adding a new provider that lacks API metadata

### Provider Defaults

Provider-level defaults in `lib/CLIO/Providers.pm` and `lib/CLIO/Core/Defaults.pm`
should be reviewed when:
- A provider changes their default model
- Context window norms shift (e.g., 128K becomes the new minimum)
- New providers are added

### Provider Rate Limit Guards

CLIO handles rate limiting differently per provider because each API has its own
conventions. This section documents the guard patterns currently implemented.

**Provider-specific behavior:**

| Provider | Limit Type | Detection | Retry | Throttle Learning |
|----------|-----------|-----------|-------|-------------------|
| OpenAI | RPM/TPM headers | `x-ratelimit-*` headers + 429 status | Retry-After header | Yes |
| Anthropic | RPM/ITPM/OTPM | 429 + `anthropic-ratelimit-{input,output}-tokens-*` headers | Retry-After header + RFC 3339 reset | Yes (token-bucket) |
| Google Gemini | RPM/TPM/RPD | 429 `RESOURCE_EXHAUSTED`, 503 `UNAVAILABLE` | Default 60s | Yes |
| NVIDIA NIM | Worker concurrency (no headers) | SSE `ResourceExhausted` / `Worker.*limit` mid-stream | 30s | Yes |
| GitHub Copilot | AI credits | Custom quota headers + semantic codes | Varies | Yes |
| MiniMax | RPM (tokens) | `authorized_error` + HTTP code | Default | No |
| Z.AI | RPM/Concurrency/Usage | Codes 1302/1303/1305 (retry), 1308/1310 (non-retry) | 3-30s | No |
| OpenRouter | Credit + RPM | `X-RateLimit-*` headers + 402/429 | Header | Yes |
| Ollama Cloud | RPM | HTTP 429/502 | Default | No |
| DeepSeek | **Concurrency** (not RPM) | HTTP 429 when exceeded | Default | No |

**DeepSeek concurrency limits:**

DeepSeek uses hard concurrency limits (not RPM) per their docs at
https://api-docs.deepseek.com/quick_start/rate_limit:
- `deepseek-v4-pro`: 500 concurrent connections per account
- `deepseek-v4-flash`: 2500 concurrent connections per account

These are configured via `model_concurrency` in `Providers.pm` and applied at
APIManager startup via `configure_rate_limiter()`. The RateLimiter's
`acquire($provider, $model)` checks both provider and model-specific limits.

**NVIDIA NIM SSE error chunk handling:**

NVIDIA NIM returns mid-stream SSE error chunks when upstream capacity is hit:
```json
data: {"error": {"code": 500, "message": "ResourceExhausted: Worker local total request limit reached (74/32)", "type": "server_error"}}
```

These are captured in `$ss->{_sse_error}` (OpenAI-compatible path) or
`$ns{_sse_error}` (native streaming path) and surfaced as `error_type: rate_limit`
with 30s `retry_after`. The pattern matches:
- `ResourceExhausted|Worker.*limit|quota|too many requests` in message
- Generic 5xx codes in SSE stream (also triggers throttle learning)

**Z.AI error codes:**

Z.AI returns structured error codes in the response body:
- `1302` - High concurrency → retry 3s
- `1303` - High frequency → retry 5s
- `1305` - General rate limit → retry 30s
- `1308` - Usage limit (5-hour reset) → non-retryable, parse reset time
- `1310` - Weekly/Monthly limit → non-retryable, parse reset time

**Native streaming SSE error stashing:**

For native streaming providers (Anthropic, Google, NVIDIA-native), SSE error
events from the provider's `parse_stream_event` are stashed in `$ns{_sse_error}`
instead of `croak`-ing. The HTTP layer wraps callbacks in `eval` which would
silently swallow `croak` exceptions. After the streaming loop completes, the
stashed error is surfaced as a proper retryable result.

**Anthropic ITPM/OTPM/RPM awareness (added 2026-07-22):**

Anthropic enforces three separate per-model per-minute caps (per
https://docs.anthropic.com/en/api/rate-limits):

- **RPM** - requests per minute
- **ITPM** - input tokens per minute. For most Claude models, only uncached
  input tokens count (cached reads do NOT count toward ITPM). What counts:
  `input_tokens + cache_creation_input_tokens`. The 250K ITPM per-minute
  bucket is the one most often hit by large conversations when prompt
  caching is off.
- **OTPM** - output tokens per minute

These are token-bucket caps that continuously refill (NOT fixed-window resets).
CLIO handles them via three coordinated layers:

1. **Header parsing** (`API/ResponseHandler.process_rate_limit_headers`):
   recognises `anthropic-ratelimit-{requests,tokens,input-tokens,output-tokens}-{limit,remaining,reset}`.
   `*-reset` values are RFC 3339 timestamps - parse them with
   `Util::RateLimit::parse_anthropic_reset_timestamp` (handles `Z` and
   `+HH:MM`/`-HHMM` offset variants).

2. **Snapshot learning** (`APIManager._apply_anthropic_rate_limit_headers`):
   on every successful response and every 429, stashes the latest bucket
   state per model under `$self->{_anthropic_rate_limits}{$model}` and seeds
   the learned ITPM ceiling from `anthropic-ratelimit-input-tokens-limit`
   (lower-only policy mirrors `_model_throttle_learn`).

3. **Token-bucket preflight** (`APIManager._model_input_token_throttle_check`):
   before each request, estimates pending input tokens with
   `TokenEstimator::estimate_messages_tokens` and returns a delay in
   seconds if `(used_in_last_60s + pending) / limit >= 0.70`. Token-bucket
   refill math: `gap / (limit / 60)` per second until the reset moment.
   Two layers, max() wins:
   - Snapshot: precise against API-reported remaining capacity.
   - Learned: fallback when no snapshot or it's older than 90s.
   At `ratio >= 1.0` the delay is `effective_reset + 1` (waits for the
   bucket to refill). `effective_reset` adjusts the snapshot's
   `reset_in` for time elapsed since `observed_at` so we don't wait
   longer than the bucket actually needs to refill.

Real input token counts (`usage.prompt_tokens` + `cache_creation_input_tokens`)
flow back into the sliding window via `_model_input_token_throttle_record`
after each native streaming response. CLIO configures prompt caching
(`cache_control: ephemeral` on system prompt + last tool), so every
session's first request and any request after the 5-min cache TTL
incur `cache_creation_input_tokens` that count toward ITPM - those
must be included in the recorded amount or the throttle silently
under-counts. The `parse_stream_event` handler in
`Providers/Anthropic.pm` extracts `cache_creation_input_tokens` from
the SSE `message_start.usage` event and it is accumulated in
`usage_tracking{cache_creation_input_tokens}` alongside `input_tokens`.

4. **Cross-agent ITPM coordination** (`Broker._calculate_api_token_delay`,
   `Broker.handle_report_api_tokens`): when an APIManager has a
   `broker_client` (i.e. it is a sub-agent or the parent of sub-agents),
   the broker maintains a per-model sliding window aggregated across
   every connected agent. Each agent reports its actual input tokens
   (incl. cache creation) after every response via `report_api_tokens`,
   and on `release_api_slot` the agent forwards Anthropic headers
   (`anthropic_rate_limit_info`) so the broker's per-model snapshot
   stays in sync. Slot requests now carry `model` + `pending_tokens`
   so the broker can return an ITPM-aware delay even when no other
   agent has reported yet. Without this layer, parent + N sub-agents
   each consume their own ITPM budget independently and can
   collectively blow `UserByModelByMinuteUncachedInputTokens` while
   no single agent exceeds the limit. Two-layer logic (snapshot +
   learned) mirrors the per-agent `_model_input_token_throttle_check`
   but with broker-wide visibility.

Code paths:
- `lib/CLIO/Util/RateLimit.pm` - friendly-type mapping + RFC 3339 parser
- `lib/CLIO/Core/API/ResponseHandler.pm` - `process_rate_limit_headers` extension,
  `set_last_request_model` / `release_broker_slot` Anthropic forwarding
- `lib/CLIO/Core/APIManager.pm` - `_apply_anthropic_rate_limit_headers`,
  `_model_input_token_throttle_{record,check}`, `_learn_input_token_limit`,
  `report_api_tokens` + `_pending_*_for_broker` plumbing
- `lib/CLIO/Providers/Anthropic.pm` - `parse_stream_event` extracts
  `cache_creation_input_tokens`
- `lib/CLIO/Coordination/Broker.pm` - `_calculate_api_token_delay`,
  `handle_report_api_tokens`, `_apply_api_token_headers`,
  `handle_request_api_slot` ITPM gating
- `lib/CLIO/Coordination/Client.pm` - `report_api_tokens`,
  `request_api_slot($id, model=>, pending_tokens=)`,
  `release_api_slot(anthropic_rate_limit_info =>)`
- `lib/CLIO/Core/Diagnostics.pm` - `display_rate_limit_info` Anthropic branches

Anthropic rate-limit error codes mapped to user-friendly names:
- `RateLimitReached` -> "Anthropic rate limit"
- `UserByModelByMinuteUncachedInputTokens` -> "Anthropic uncached input token limit (ITPM)"
- `UserByModelByMinuteUncachedOutputTokens` -> "Anthropic uncached output token limit (OTPM)"
- `UserByModelByMinuteInputTokens` -> "Anthropic input token limit (ITPM)"
- `UserByModelByMinuteOutputTokens` -> "Anthropic output token limit (OTPM)"
- `UserByModelByMinuteRequests` -> "Anthropic request rate limit (RPM)"

Tests:
- `tests/unit/test_anthropic_rate_limit.pl` - header parsing + friendly codes
- `tests/unit/test_anthropic_input_token_throttle.pl` - snapshot/learn layers,
  stale reset_in adjustment, cache_creation extraction
- `tests/unit/test_broker.pl` - cross-agent ITPM aggregation, snapshot/header
  forwarding, slot gating with model+pending_tokens

---

## Quick Reference

**Syntax Check:**
```bash
perl -I./lib -c lib/CLIO/Module.pm
```

**Run Test:**
```bash
perl -I./lib tests/unit/test_feature.pl
```

**Debug Session:**
```bash
./clio --debug --new
```

**Quick Test:**
```bash
./clio --input "your test query" --exit
```

**Search Code:**
```bash
git grep "pattern" lib/
```

**Git Operations:**
```bash
git status
git diff
git log --oneline -10
git add -A && git commit -m "type(scope): description"
```

---

## Prompt Pipeline Protocol

Every API request CLIO sends follows a fixed seven-slot layout. The goal is LCP (Longest Common Prefix) cache stability across turns — keep the cached prefix as long as possible so providers like llama.cpp, Anthropic, and OpenAI can reuse KV cache instead of reprocessing the full prompt.

**The seven slots, in order:**

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

- Sections [0..2] are the **stable anchor** — only invalidate when tools change, summary regenerates, or context files change.
- Section [5] is the **dynamic anchor** — changes every minute (date/time cache). When it changes, only [5] onwards is reprocessed. The dialog and tool_results at [3..4] stay cached.
- Section [6] is always fresh.

**Why this layout works for LCP:**

The most common invalidation events are: user sends new turn (user_input changes), date ticks over (user_context changes), and dialog grows (tool execution adds results). The layout positions all three events at the END of the prompt, so the LCP breaks as late as possible. When only the date ticks, [0..4] stay cached — that's ~99% of the prompt unchanged.

**System messages are NOT merged.** `ConversationManager::enforce_message_alternation` excludes `role=system` from its merge rule. Each section [0], [1], [2], [5] is its own message. Merging them would couple cache lifetimes: any section's regeneration would invalidate the whole merged system prompt. Providers that need concatenation (Anthropic) do so at the wire-format layer.

**Resume fast path preserves LCP.** `Session::State::last_api_payload` captures the conversation state at end of turn. On resume, `_try_resume_from_payload` returns the snapshot verbatim with fresh [5] and [6] appended. The snapshot must equal what `load_conversation_history` would return from session history — otherwise the fast path and rebuild path diverge and the LCP breaks.

**Snapshot timing matters.** `_capture_api_payload` runs at end of turn (success path + iteration-limit exit), not before tool execution. Capturing before tool execution produces a stale pre-tool snapshot that diverges from session history — the bug CachyLLama reported on 2026-08-18.

**Trim policy:**

- [0], [1], [5], [6] — NEVER trimmed (anchors + active request)
- [2] — trimmed with dialog budget walk
- [3] — primary trim target (oldest dialog dropped first)
- [4] — secondary trim target (oldest tool_results dropped first)

The deinterleaved layout puts tool_results at the END specifically so they get dropped before dialog when budget is tight. Tool results are the most expendable — the agent can re-call the tool.

**Provider adaptations:**

- **Anthropic**: concatenates all `role=system` messages into one `system` field with `cache_control: {type: 'ephemeral'}`. Per-section cache control is a future enhancement.
- **OpenAI**: sends system messages as separate items. Supports per-message `cache_control`.
- **llama.cpp**: sets `prompt_stable_prefix_tokens` = sum of [0..2] tokens so the slot match covers the stable anchor.

Full spec: [`docs/SPECS/PROMPT_PIPELINE.md`](docs/SPECS/PROMPT_PIPELINE.md).

**Tests covering the protocol:**

- `tests/unit/test_cache_stable_layout.pl` — trim produces the cache-stable message ordering
- `tests/unit/test_cache_stable_summary.pl` — CSSS slot lock behavior
- `tests/unit/test_session_cached_payload.pl` — snapshot roundtrip + strip-and-replace on resume
- `tests/unit/test_conversation_manager_multimodal.pl` — system messages stay separate (no merge)
- `tests/integration/test_session_resume_cached_payload.pl` — end-to-end resume flow

Any change to message ordering, role assignment, or trim policy must update these tests.

---

*For project methodology and workflow, see .clio/instructions.md*
*For universal agent behavior, see system prompt*
