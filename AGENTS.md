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
    +-- file_operations (17 operations)
    +-- version_control (git + worktrees)
    +-- terminal_operations (shell exec)
    +-- memory_operations (store/recall/LTM)
    +-- todo_operations (task management)
    +-- web_operations (search/fetch)
    +-- code_intelligence (search/analyze)
    +-- interact (checkpoints)
    +-- apply_patch (diff-based editing)
    +-- remote_execution (SSH + parallel) [requires: enable_remote config]
    +-- agent_operations (multi-agent) [requires: enable_subagents config]
    +-- MCPBridge (infrastructure: dynamically exposes MCP server tools)
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
| `lib/CLIO/UI/Commands/` | Slash command handlers (18 commands across multiple categories) |
| `lib/CLIO/UI/Multiplexer/` | Terminal multiplexer support |
| `lib/CLIO/Session/` | Session management (Manager, State, FileVault, Lock, Export, TodoStore, ToolResultStore) |
| `lib/CLIO/Memory/` | Context/memory system (YaRN, TokenEstimator, ShortTerm, LongTerm) |
| `lib/CLIO/Profile/` | User personality profile (Analyzer, Manager) |
| `lib/CLIO/Protocols/` | Complex workflows (Puppeteer) |
| `lib/CLIO/Providers/` | Direct API providers (Anthropic, Google, NVIDIA, Base) |
| `lib/CLIO/Coordination/` | Multi-agent coordination (Broker, Client, SubAgent) |
| `lib/CLIO/MCP/` | Model Context Protocol (Manager, Client, Transport::HTTP, Transport::Stdio, Auth::OAuth) |
| `lib/CLIO/Security/` | Auth/authz (Auth, Authz, AuthorizationRelay, CommandAnalyzer, InvisibleCharFilter, PathAuthorizer, SecretRedactor) |
| `lib/CLIO/Logging/` | Structured logging (Logger, ProcessStats, ToolLogger) |
| `lib/CLIO/Compat/` | Compatibility layers (Terminal, HTTP) |
| `lib/CLIO/Util/` | Utilities (PathResolver, TextSanitizer, JSON, JSONRepair, YAML, ImageAttachment, ImageDisplay, ConfigPath, AtomicWrite, RateLimit, GitIgnore, AnthropicXMLParser, CABundle, Curl, InputHelpers, Proxy, UUID) |
| `lib/CLIO/Spec/` | OpenSpec integration (Manager) |
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
| `CLIO::Core::` | System core | APIManager, WorkflowOrchestrator, ToolExecutor, Config, PromptManager, ModelCapabilitiesManager |
| `CLIO::Core::API::` | APIManager sub-modules | ResponseHandler, MessageValidator, ErrorHandler, PayloadSanitizer |
| `CLIO::Tools::` | AI-callable tools | FileOperations, VersionControl, TerminalOperations, MemoryOperations, Interact, ApplyPatch, CodeIntelligence, RemoteExecution, SubAgentOperations, TodoList, WebOperations, SkillOperations, MCPBridge, PluginBridge, Registry, Tool |
| `CLIO::UI::` | Terminal interface | Chat, Markdown, Theme, ANSI, CommandHandler, DiffRenderer, Display, HostProtocol, Multiplexer, PaginationManager, ProgressSpinner, StreamingController, Terminal, ToolOutputFormatter |
| `CLIO::UI::Commands::` | Slash command handlers | AI, API, Billing, Config, Context, Device, File, Git, Log, Memory, Mux, Profile, Project, Prompt, Session, Skills, Spec, Stats |
| `CLIO::Session::` | Session management | Manager, State, FileVault, Lock, Export, TodoStore, ToolResultStore |
| `CLIO::Memory::` | Context/memory | ShortTerm, LongTerm, YaRN, TokenEstimator |
| `CLIO::Providers::` | Direct API providers | Anthropic, Google, NVIDIA, Base |
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
| Anthropic | RPM/ITPM/OTPM | 429 `rate_limit_error`, 529 `overloaded_error` | Retry-After header | Yes |
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

*For project methodology and workflow, see .clio/instructions.md*  
*For universal agent behavior, see system prompt*
