# AGENTS.md

**Version:** 3.0  
**Date:** 2026-04-01  
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
    +-- FileOperations (18 operations)
    +-- VersionControl (git + worktrees)
    +-- TerminalOperations (shell exec)
    +-- Memory (store/recall/LTM)
    +-- TodoOperations (task management)
    +-- WebOperations (search/fetch)
    +-- CodeIntelligence (search/analyze)
    +-- UserCollaboration (checkpoints)
    +-- ApplyPatch (diff-based editing)
    +-- RemoteExecution (SSH + parallel)
    +-- SubAgentOperations (multi-agent)
    +-- MCPBridge (external tool servers)
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
| `lib/CLIO/Core/` | System core (APIs, workflow, config) |
| `lib/CLIO/Core/API/` | APIManager sub-modules (ResponseHandler, MessageValidator, etc.) |
| `lib/CLIO/Tools/` | AI-callable tools |
| `lib/CLIO/UI/` | Terminal UI (Chat, Markdown, Theme, Commands) |
| `lib/CLIO/Session/` | Session management |
| `lib/CLIO/Memory/` | Context/memory system (YaRN, TokenEstimator) |
| `lib/CLIO/Profile/` | User personality profile (Analyzer, Manager) |
| `lib/CLIO/Protocols/` | Complex workflows (Architect, Editor) |
| `lib/CLIO/Providers/` | Direct API providers (Anthropic, Google) |
| `lib/CLIO/Coordination/` | Multi-agent coordination (Broker, Client) |
| `lib/CLIO/MCP/` | Model Context Protocol (servers, transports, OAuth) |
| `lib/CLIO/Security/` | Auth/authz |
| `lib/CLIO/Logging/` | Structured logging |
| `lib/CLIO/Compat/` | Compatibility layers (Terminal) |
| `lib/CLIO/Util/` | Utilities (PathResolver, TextSanitizer, JSON, YAML) |
| `lib/CLIO/Spec/` | OpenSpec integration |
| `docs/` | User/dev documentation |
| `tests/unit/` | Single module tests |
| `tests/integration/` | Cross-module tests |

**Key Files:**

- `clio` - Main executable
- `lib/CLIO/Core/WorkflowOrchestrator.pm` - Tool orchestration (3,544 lines)
- `lib/CLIO/Core/APIManager.pm` - AI provider integration (3,450 lines)
- `lib/CLIO/UI/Chat.pm` - Terminal interface (2,998 lines)
- `lib/CLIO/Core/ToolExecutor.pm` - Tool invocation (1,051 lines)
- `lib/CLIO/Tools/FileOperations.pm` - File system operations

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
| `CLIO::Core::` | System core | APIManager, WorkflowOrchestrator, ToolExecutor |
| `CLIO::Core::API::` | APIManager sub-modules | ResponseHandler, MessageValidator, StreamProcessor |
| `CLIO::Tools::` | AI-callable tools | FileOperations, VersionControl, TerminalOperations |
| `CLIO::UI::` | Terminal interface | Chat, Markdown, Theme, ToolOutputFormatter |
| `CLIO::UI::Commands::` | Slash command handlers | API, Session, Config, Project |
| `CLIO::Session::` | Session management | Manager, State, TodoStore, ToolResultStore |
| `CLIO::Memory::` | Context/memory | ShortTerm, LongTerm, YaRN, TokenEstimator |
| `CLIO::Providers::` | Direct API providers | Anthropic, Google, Base |
| `CLIO::Coordination::` | Multi-agent coordination | Broker, Client |
| `CLIO::MCP::` | Model Context Protocol | Manager, Client, Transport::Stdio, Auth::OAuth |
| `CLIO::Profile::` | User profiling | Analyzer, Manager |
| `CLIO::Protocols::` | Complex workflows | Architect, Editor, Validate |
| `CLIO::Security::` | Auth/authz | Auth, Authz, Manager |
| `CLIO::Logging::` | Structured logging | Logger |
| `CLIO::Util::` | Utilities | PathResolver, TextSanitizer, JSONRepair, JSON, YAML |
| `CLIO::Spec::` | OpenSpec integration | Manager (spec lifecycle management) |
| `CLIO::Compat::` | Compatibility | Terminal (ReadKey, ReadMode) |

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

## Documentation

### What Needs Documentation

| Change Type | Required Documentation |
|-------------|------------------------|
| New feature | POD + update docs/ARCHITECTURE.md |
| API change | Update POD + docs/USER_GUIDE.md |
| User-facing | Update docs/USER_GUIDE.md |
| Design decision | Add to PROJECT_DECISIONS.md |
| Known issue | Update KNOWN_ISSUES.md |

### Documentation Files

| File | Purpose | Audience |
|------|---------|----------|
| `README.md` | Project overview | Everyone |
| `docs/ARCHITECTURE.md` | System design | Developers |
| `docs/USER_GUIDE.md` | How to use | Users |
| `docs/DEVELOPER_GUIDE.md` | How to extend | Contributors |
| `.clio/instructions.md` | Project methodology | AI agents |
| `AGENTS.md` | Technical reference | AI agents |

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
| Commit without testing | Breaks builds, wastes time | Test syntax, run integration tests |
| Use bare `die` in modules | Crashes AI loop ungracefully | Use `croak` from Carp, with eval for error handling |
| Create giant modules (>1000 lines) | Hard to maintain and understand | Split into focused, cohesive modules |
| Create summary docs in root | Clutters repository, wrong location | Use scratch/ for working documents |
| Skip collaboration checkpoints | Violates Unbroken Method | Use user_collaboration at key decision points |
| Technical jargon in action_desc | Users don't care about implementation details | Use user-focused descriptions |

**Technical jargon example:**
- WRONG: `"searching codebase (hybrid keyword+symbols)"` 
- RIGHT: `"searching codebase for 'X' (N matches)"`

The `action_description` appears in user-facing tool output. Keep it simple and focused on results, not implementation.

**Remember:** If you find yourself doing any of these, STOP and do it correctly.

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
