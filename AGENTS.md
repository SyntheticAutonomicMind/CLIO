# AGENTS.md

**Version:** 3.3
**Date:** 2026-09-10
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
# Run CLIO (no dependencies - pure core Perl)
./clio --new

# Debug mode
./clio --debug --new

# Quick test
./clio --input "test query" --exit
```

---

## Architecture

```
User Input -> Terminal UI (Chat.pm, SessionReplay) -> AI Agent (APIManager -> Provider)
  -> Tool Selection (WorkflowOrchestrator) -> Tool Execution (ToolExecutor)
  -> Result Processing -> Markdown (Markdown.pm) -> Terminal Output
```

Tools: file_operations, version_control, terminal_operations, memory_operations,
todo_operations, web_operations, code_intelligence, interact, apply_patch,
remote_execution, agent_operations, skill_operations [conditional],
MCPBridge [dynamic], PluginBridge [dynamic]

---

## Directory Structure

| Path | Purpose |
|------|---------|
| `lib/CLIO.pm` | Root package loader |
| `lib/CLIO/Update.pm` | Self-update flow |
| `lib/CLIO/Core/` | System core (APIs, workflow, config, prompts, diagnostics) |
| `lib/CLIO/Core/API/` | APIManager sub-modules (ResponseHandler, MessageValidator, ErrorHandler, PayloadSanitizer) |
| `lib/CLIO/Core/SkillRepository.pm` | Skill repository configuration and management |
| `lib/CLIO/Core/SkillManager.pm` | Skill catalog, scopes, and freeform skill creation (`auto_create_skills`) |
| `lib/CLIO/Core/RepositoryLoader.pm` | Load skills from cached Git repositories |
| `lib/CLIO/Code/` | Code intelligence primitives (TreeSitter) |
| `lib/CLIO/Test/` | Test infrastructure (MockAPI) |
| `lib/CLIO/Tools/` | AI-callable tools (16 modules) |
| `lib/CLIO/UI/` | Terminal UI (Chat, Markdown, Theme, Commands, SessionReplay, Multiplexer) |
| `lib/CLIO/UI/Commands/` | Slash command handlers (23 command modules across multiple categories, plus SessionReplay integration) |
| `lib/CLIO/UI/Multiplexer/` | Terminal multiplexer support |
| `lib/CLIO/Session/` | Session management (Manager, State, FileVault, Lock, Export, TodoStore, ToolResultStore) |
| `lib/CLIO/Memory/` | Context/memory system (YaRN, TokenEstimator, ShortTerm, LongTerm) |
| `lib/CLIO/Profile/` | User personality profile (Analyzer, Manager) |
| `lib/CLIO/Protocols/` | Complex workflows (Puppeteer) |
| `lib/CLIO/Providers/` | Direct API providers (Anthropic, Google, NVIDIA, Base, DeepSeek, MiniMax, Z.A.I, OpenRouter, OrcaRouter, KiloCode, Ollama Cloud, GitHub Copilot, SAM, llama.cpp, LM Studio) |
| `lib/CLIO/Coordination/` | Multi-agent coordination (Broker, Client, SubAgent) |
| `lib/CLIO/MCP/` | Model Context Protocol (Manager, Client, Transport::HTTP, Transport::Stdio, Auth::OAuth) |
| `lib/CLIO/Logging/` | Structured logging (Logger, ProcessStats, ToolLogger) |
| `lib/CLIO/Compat/` | Compatibility layers (Terminal, HTTP) |
| `lib/CLIO/Util/` | Utilities (PathResolver, TextSanitizer, JSON, JSONRepair, YAML, ImageAttachment, ImageDisplay, ConfigPath, AtomicWrite, RateLimit, GitIgnore, AnthropicXMLParser, CABundle, Curl, InputHelpers, Proxy, UUID) |
| `lib/CLIO/Spec/` | OpenSpec integration (Manager) |
| `lib/CLIO/Core/model-data/` | Unified model capability JSON files (models.json, provider-defaults.json, heuristics.json, provider-mapping.json) |
| `docs/` | User/dev documentation |
| `docs/templates/` | Generic AGENTS.md / instructions.md templates used by `/init` |
| `styles/` | Terminal color styles (26 themes: dark, light, retro, cyberpunk, monokai, etc.) |
| `themes/` | UI themes (compact, console, default, verbose) |
| `tools/` | Repo-local tooling (assess_codebase.pl, cache_health.pl, context_inspector.pl, prompt_diff.pl, session_stats.pl, trim_dryrun.pl, etc.) |
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
- `lib/CLIO/Core/WorkflowOrchestrator.pm` - Tool orchestration, message array construction, role-based history push
- `lib/CLIO/Core/APIManager.pm` - AI provider integration
- `lib/CLIO/UI/Chat.pm` - Terminal interface
- `lib/CLIO/UI/SessionReplay.pm` - Session history visual replay renderer
- `lib/CLIO/Core/ToolExecutor.pm` - Tool invocation
- `lib/CLIO/Tools/FileOperations.pm` - File system operations (17 ops)
- `lib/CLIO/Tools/Registry.pm` - Tool registration
- `lib/CLIO/Core/PluginManager.pm` - Plugin lifecycle
- `lib/CLIO/Core/PromptBuilder.pm` - Prompt construction (system prompt, the cache-stable [0])
- `lib/CLIO/Core/PromptManager.pm` - Prompt template storage
- `lib/CLIO/Core/ContextBuilder.pm` - Per-request projection: anchor turn + recent turns + LTM relevance + cross-turn dedup
- `lib/CLIO/Core/MessageHistory.pm` - Prose renderer for the dynamic userContext system message
- `lib/CLIO/Core/ConversationManager.pm` - History loading + role-based tail walk + reasoning-content stripping
- `lib/CLIO/Core/API/MessageValidator.pm` - `_role_based_tail_walk` (proactive/reactive trim); protects system_prompt, dynamic userContext, current user_input, tool_call/tool_result pairs
- `lib/CLIO/Core/ModelDataLoader.pm` - Unified model capability data loader
- `lib/CLIO/Core/ModelCapabilitiesManager.pm` - Model capability discovery + static maps
- `lib/CLIO/Core/model-data/models.json` - Primary model capability database
- `lib/CLIO/Core/model-data/provider-defaults.json` - Provider fallback defaults
- `lib/CLIO/Core/model-data/heuristics.json` - Pattern-based fallback rules
- `lib/CLIO/Core/model-data/provider-mapping.json` - Provider-to-model ID mappings

## Image Support

CLIO supports multimodal image upload and display:

**Upload (User -> Model):** ImageAttachment.pm (read, validate, base64-encode),
Chat.pm parses `@path/to/image.png`, WorkflowOrchestrator builds array-format
multimodal content, APIManager handles arrayref content in payloads.

**Display (Model -> User):** ImageDisplay.pm renders via kitty/iTerm/sixel protocols,
Terminal.pm detects terminal image support.

**Token Estimation:** TokenEstimator.pm (85 tokens per image)

**Message Handling:** ConversationManager handles arrayref content in merging/truncation

**Investigate, don't assume:** Use `git log --oneline -20`, `find lib -name "*.pm"`, read actual code.

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

=head1 SYNOPSIS

    use CLIO::Module::Name;
    my $obj = CLIO::Module::Name->new();
    $obj->method();

=cut

# Implementation...
1;  # MANDATORY: End every .pm file with 1;
```

**Logging levels:**

| Level | Use | Examples |
|-------|-----|---------|
| DEBUG | Operational details (vast majority) | trim details, token budgets, state transitions, tool dispatch |
| INFO | Reserved — no current use | Notable events (model routing, provider auto-selection) |
| WARNING | Something wrong AND not handled | Errors that crash without retry/reroute/fallback |
| ERROR | Unrecoverable failures | Process or user must intervene |

If the system handles the condition (retry, reroute, fallback), use `log_debug`, not `log_warning`.

```bash
# Set log level:
/config set log_level DEBUG     # persisted
/loglevel DEBUG                  # immediate + persisted
./clio --debug --new            # session only
```

---

## Module Naming Conventions

| Prefix | Purpose | Examples |
|--------|---------|----------|
| `CLIO::Core::` | System core | APIManager, WorkflowOrchestrator, ToolExecutor, Config, PromptManager, ContextBuilder, MessageHistory, ConversationManager |
| `CLIO::Core::API::` | API sub-modules | ResponseHandler, MessageValidator, ErrorHandler, PayloadSanitizer |
| `CLIO::Tools::` | AI-callable tools | FileOperations, VersionControl, TerminalOperations, MemoryOperations, Interact, ApplyPatch, CodeIntelligence, RemoteExecution, SubAgentOperations, TodoList, WebOperations, SkillOperations, MCPBridge, PluginBridge, Registry, Tool |
| `CLIO::UI::` | Terminal interface | Chat, Markdown, Theme, ANSI, CommandHandler, DiffRenderer, Display, HostProtocol, Multiplexer, PaginationManager, ProgressSpinner, StreamingController, Terminal, ToolOutputFormatter |
| `CLIO::UI::Commands::` | Slash command handlers | AI, API, Billing, Config, Context, Device, File, Git, Log, Memory, Mux, Profile, Project, Prompt, Session, Skills, Spec, Stats, SubAgent, System, Todo, Update |
| `CLIO::Session::` | Session management | Manager, State, FileVault, Lock, Export, TodoStore, ToolResultStore |
| `CLIO::Memory::` | Context/memory | ShortTerm, LongTerm, YaRN, TokenEstimator |
| `CLIO::Providers::` | Provider registry + native providers | Anthropic, Google, NVIDIA, Base, DeepSeek, MiniMax, Z.A.I, OpenRouter, OrcaRouter, KiloCode, Ollama Cloud, GitHub Copilot, SAM, llama.cpp, LM Studio (18 providers in Providers.pm) |
| `CLIO::Coordination::` | Multi-agent | Broker, Client, SubAgent |
| `CLIO::MCP::` | Model Context Protocol | Manager, Client, Transport::Stdio, Transport::HTTP, Auth::OAuth |
| `CLIO::Profile::` | User profiling | Analyzer, Manager |
| `CLIO::Protocols::` | Complex workflows | Puppeteer |
| `CLIO::Security::` | Auth/authz | Auth, Authz, AuthorizationRelay, CommandAnalyzer, InvisibleCharFilter, PathAuthorizer, SecretRedactor |
| `CLIO::Logging::` | Structured logging | Logger, ProcessStats, ToolLogger |
| `CLIO::Compat::` | Compatibility | Terminal (ReadKey, ReadMode), HTTP |
| `CLIO::Util::` | Utilities | PathResolver, TextSanitizer, JSON, JSONRepair, YAML, ImageAttachment, ImageDisplay, ConfigPath, AtomicWrite, RateLimit, GitIgnore, AnthropicXMLParser, CABundle, Curl, InputHelpers, Proxy, UUID |
| `CLIO::Code::` | Code intelligence | TreeSitter |
| `CLIO::Spec::` | OpenSpec integration | Manager |
| `CLIO::Test::` | Test infrastructure | MockAPI |

---

## Testing

```bash
# Syntax check specific module
perl -I./lib -c lib/CLIO/Core/MyModule.pm

# All syntax checks
find lib -name "*.pm" -exec perl -I./lib -c {} \;

# Run unit test
perl -I./lib tests/unit/test_mymodule.pl

# Run all unit tests for a component
cd tests/unit && for t in test_<component>*.pl; do perl -I../../lib $t; done

# Integration test
./clio --debug --input "test your change" --exit

# Check for errors
./clio --input "complex test" --debug --exit 2>&1 | grep ERROR
```

**Test Locations:** `tests/unit/` (single module), `tests/integration/` (cross-module)

**Test Requirements:** Syntax must pass, unit tests must exist, tests must pass (exit 0), complex features need e2e verification.

**Strict mode warnings:** Use `perl tests/run_strict_tests.pl` to catch uninitialized-value warnings across all unit tests. CLIO-originated warnings fail the run; vendor warnings are informational only. Use `$SIG{__WARN__}` capture pattern in tests for suspected paths (see `test_command_handler.pl`).

---

## Commit Format

```
type(scope): brief description

Problem: What was broken/incomplete
Solution: How you fixed it
Testing: How you verified the fix
```

**Types:** `feat`, `fix`, `refactor`, `docs`, `test`, `chore`

**Pre-Commit Checklist:**

- `perl -c` passes on all changed .pm files
- POD documentation updated if API changed
- Commit message explains WHAT and WHY
- No `TODO`/`FIXME` comments
- Test coverage for new code
- No handoff files in `ai-assisted/` staged

**Git operations:**

```bash
git status
git diff
git log --oneline -20
git add -A && git commit -m "type(scope): description"
```

---

## Common Patterns

**Error Handling:**

```perl
use Carp qw(croak);
eval { /* operation */ };
if ($@) {
    return error_result("Operation failed: $@");
}
```

**JSON Encoding:**

```perl
use CLIO::Util::JSON qw(encode_json decode_json);
my $json = encode_json($data);  # Auto-selects JSON::XS > Cpanel::JSON::XS > JSON::PP
my $decoded = eval { decode_json($json) };
if ($@) { /* handle parse error */ }
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

### User-Facing Docs (README.md, USER_GUIDE.md, INSTALLATION.md)

**Tone:** Direct, concise, no corporate fluff. Active voice. Address user as "you".

### Module Documentation (POD)

Every `.pm` file needs:

```perl
=head1 NAME

CLIO::Module::Name - Brief one-line description

=head1 DESCRIPTION

Detailed description of module purpose and behavior.

=head1 METHODS

=cut

=head2 method_name

Arguments: $arg1 (required), $arg2 (optional, default: undef)
Returns: What it returns and its structure
Example: my $result = $obj->method_name($arg1)

=cut

# Internal methods (not public API):
=head2 _internal_method (Internal)
Do not call directly. Internal implementation detail.
=cut
```

### UI/UX Patterns

**Three-color rule for structured output:**
- DIM (chrome) - bullets, arrows, separators
- ASSISTANT (names) - headers, tool names
- DATA (content) - values, descriptions

**Always use `colorize()`** — never hardcode ANSI codes.

**Theme tokens for slash commands:** success_message (green), error_message (red),
warning_message (yellow), info_message (cyan), command_header (bold cyan),
command_label (cyan), command_value (white).

**Command headers:** 70-char `═` borders via `display_command_header()`.

**Slash commands:** Extend `CLIO::UI::Commands::Base`, use display helpers:
`$self->display_key_value($label, $value)`, `$self->display_success_message()`, `$self->display_error_message()`.

### Terminology (use consistently)

| Use This | Not This |
|----------|----------|
| API key | api key, API-key, api_key |
| API provider | provider, api provider |
| slash command | command, CLIO command |
| configuration | config, settings |
| file path | filepath, file-path |
| session | conversation, chat |
| terminal | console, command line |

### Documentation Files

| File | Purpose |
|------|---------|
| `README.md` | Project overview |
| `docs/USER_GUIDE.md` | How to use CLIO |
| `docs/FEATURES.md` | Complete feature reference |
| `docs/ARCHITECTURE.md` | System design |
| `docs/STYLE_QUICKREF.md` | UI styling quick reference |
| `docs/templates/` | AGENTS.md / instructions.md templates |
| `.clio/instructions.md` | Project methodology (Unbroken Method) |
| `AGENTS.md` | Technical reference (this file) |

**Rule:** Full rewrite, never changelog patches. Test docs: `clio --input "read docs/YOUR_FILE.md" --exit`.

---

## Anti-Patterns (What NOT To Do)

| Anti-Pattern | What To Do |
|--------------|------------|
| Skip `perl -c` before commit | Run syntax check on all changed files |
| Use `print STDERR` for logging | Use `log_debug()` / `log_error()` etc. |
| Label bugs as "out of scope" | Fix bugs you find |
| Leave `TODO` comments in code | Finish implementation before committing |
| Assume code behavior | Read the code, investigate first |
| Create duplicate utility code | Search codebase for existing implementations first |
| Commit without testing | Test syntax, run integration tests |
| Use bare `die` in modules | Use `croak` from Carp with eval |
| Create giant modules (>1000 lines) | Split into focused modules |
| Create summary docs in root | Use `scratch/` for working documents |
| Skip collaboration checkpoints | Use interact at key decision points |
| Technical jargon in action_desc | Use user-focused descriptions |
| Negative framing in messages | State what IS true and what to do |
| Changelog-style comments in code | Write comments for current state |
| Surface warnings for handled conditions | If the code handles it, use `log_debug` |
| Log operational noise at INFO | Demote to `log_debug` |
| Provide useless stats to the model | Include only actionable work product |
| Leak framework narration to the model | Inject work product only |

---

## No Fallbacks (Unless Required)

CLIO always rebuilds sessions and manages resume state internally. No backwards-compatibility shims:

- Don't add deprecated key handlers — update all call sites
- Don't add format migrations — discard old sessions, not migrate
- Don't add alias layers — move all callers
- Don't add fallback defaults for missing data — surface the error

If a fallback is genuinely unavoidable, fix at the source (normalize the response) rather than adding a compatibility shim.

---

## Maintenance Routines

Check these periodically when starting a session:

### Model Capability Maps

Static maps in `ModelCapabilitiesManager.pm` drift as providers add/remove models.

| Provider | Method | Last Updated |
|----------|--------|-------------|
| NVIDIA NIM | `_fetch_nvidia_capabilities` | 2026-06-11 |
| Z.A.I | `_fetch_zai_capabilities` | Check date |
| MiniMax | `_fetch_minimax_capabilities` | Check date |
| DeepSeek | `_fetch_deepseek_capabilities` | 2026-06-30 |

**Update procedure:** Check provider model listing. Cross-reference with OpenRouter's `/api/v1/models`. Add new models with accurate `context_window` + `max_output_tokens`. Remove removed models. Update heuristic patterns. Verify all entries resolve:
```bash
perl -I./lib -e 'use CLIO::Core::ModelCapabilitiesManager; my $mcm = CLIO::Core::ModelCapabilitiesManager->new(); my $caps = $mcm->get_capabilities("nvidia", "deepseek-ai/deepseek-v4-flash"); print "ctx=$caps->{context_window} out=$caps->{max_output_tokens}\n";'
```

**When to update:** User reports model showing "-" for context/output, new model family appears, or periodically (monthly).

### Provider Defaults

Review `lib/CLIO/Providers.pm` + `lib/CLIO/Core/Defaults.pm` when:
- Provider changes default model
- Context window norms shift
- New providers added

### Provider Rate Limit Guards

| Provider | Limit Type | Detection | Retry |
|----------|-----------|-----------|-------|
| OpenAI | RPM/TPM | `x-ratelimit-*` headers + 429 | Retry-After |
| Anthropic | RPM/ITPM/OTPM | 429 + `anthropic-ratelimit-*` headers | Retry-After + RFC 3339 |
| Google Gemini | RPM/TPM/RPD | 429 `RESOURCE_EXHAUSTED`, 503 | Default 60s |
| NVIDIA NIM | Worker concurrency | SSE `ResourceExhausted` mid-stream | 30s |
| GitHub Copilot | AI credits | Custom quota headers | Varies |
| MiniMax | RPM (tokens) | `authorized_error` + HTTP code | Default |
| Z.A.I | RPM/Concurrency/Usage | Codes 1302/1303/1305 (retry), 1308/1310 (non-retry) | 3-30s |
| OpenRouter | Credit + RPM | `X-RateLimit-*` + 402/429 | Header |
| DeepSeek | **Concurrency** (not RPM) | HTTP 429 | Default |

**DeepSeek concurrency:** `deepseek-v4-pro`: 500 concurrent, `deepseek-v4-flash`: 2500 concurrent (per provider docs).

**Key code paths:** `Util/RateLimit.pm`, `Core/API/ResponseHandler.pm`, `Core/APIManager.pm` (`_model_input_token_throttle_check/record`, `report_api_tokens`), `Providers/Anthropic.pm` (`cache_creation_input_tokens` from SSE), `Coordination/Broker.pm` (cross-agent ITPM).

Tests: `test_anthropic_rate_limit.pl`, `test_anthropic_input_token_throttle.pl`, `test_broker.pl`

---

## Quick Reference

```bash
# Syntax check
perl -I./lib -c lib/CLIO/Core/MyModule.pm

# Run all syntax checks
find lib -name "*.pm" -exec perl -I./lib -c {} \;

# Run unit test
perl -I./lib tests/unit/test_feature.pl

# Debug session
./clio --debug --new

# Quick test
./clio --input "test query" --exit

# Search codebase
git grep "function_name" lib/

# Git operations
git status; git diff; git log --oneline -10
git add -A && git commit -m "type(scope): description"
```

---

*For project methodology and workflow, see .clio/instructions.md*
*For universal agent behavior, see system prompt*
