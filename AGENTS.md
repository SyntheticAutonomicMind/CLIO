# AGENTS.md

## Project Overview

**CLIO** (Command Line Intelligence Orchestrator) is an AI-powered development assistant built in Perl.

- **Language:** Perl 5.32+
- **Architecture:** Tool-calling AI assistant with terminal UI
- **Philosophy:** The Unbroken Method for human-AI collaboration

## Setup Commands

- Install dependencies: `cpanm --installdeps .` (minimal CPAN deps, mostly core Perl)
- Run CLIO: `./clio --new`
- Run with debug: `./clio --debug --new`
- Quick test: `./clio --input "test query" --exit`

## Project Structure

### Core Files
| File | Purpose | Size |
|------|---------|------|
| `clio` | Main executable (tool calling loop) | 17 KB |
| `lib/CLIO/Core/WorkflowOrchestrator.pm` | AI tool orchestration | 45 KB |
| `lib/CLIO/Core/ToolExecutor.pm` | Tool invocation routing | 23 KB |
| `lib/CLIO/Core/APIManager.pm` | AI provider integration | 83 KB |
| `lib/CLIO/UI/Chat.pm` | Terminal interface | 158 KB |
| `lib/CLIO/Tools/FileOperations.pm` | File system operations | 52 KB |
| `lib/CLIO/Session/Manager.pm` | Session persistence | 6 KB |

### Directories
| Path | Purpose | Status |
|------|---------|--------|
| `lib/CLIO/Core/` | System core (APIs, workflow, config) | Complete |
| `lib/CLIO/Tools/` | AI-callable tools (17 operations) | Complete |
| `lib/CLIO/UI/` | Terminal UI (Chat, Markdown, Theme) | Needs refactor |
| `lib/CLIO/Session/` | Session management | Complete |
| `lib/CLIO/Memory/` | Context/memory system | Incomplete |
| `lib/CLIO/Protocols/` | Complex workflows | Needs audit |
| `lib/CLIO/Security/` | Auth/authz | Complete |
| `docs/` | User/dev documentation | Good |
| `tests/` | Unit & integration tests | 30% coverage |

## Architecture

```
User Input
    ↓
Terminal UI (Chat.pm)
    ↓
AI Agent (APIManager -> AI Provider)
    ↓
Tool Selection (WorkflowOrchestrator)
    ↓
Tool Execution (ToolExecutor)
    ├─ FileOperations (17 operations)
    ├─ VersionControl (git)
    ├─ TerminalOperations (shell exec)
    ├─ Memory (store/recall)
    ├─ TodoList (task management)
    └─ ...more tools
    ↓
Result Processing
    ↓
Markdown Rendering (Markdown.pm)
    ↓
Terminal Output (with color/theme)
```

## Code Style

- **Perl 5.32+** with strict and warnings always
- **UTF-8 encoding** for all files
- **4 spaces** for indentation (never tabs)
- **POD documentation** for all modules
- **No CPAN dependencies** unless absolutely necessary (use core Perl)

### Module Template

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
Example code showing how to use

=cut

# Implementation...

1;  # MANDATORY: End every .pm file with 1;
```

### Debug Logging Pattern

```perl
use CLIO::Core::Logger qw(should_log log_debug);

if (should_log('DEBUG')) {
    print STDERR "[DEBUG][ModuleName] message\n";
}
# Or better:
log_debug('ModuleName', 'message');
```

## Testing Instructions

### Before Committing
```bash
# 1. Syntax check all modified files
perl -I./lib -c lib/CLIO/Core/MyModule.pm

# 2. Run relevant unit tests
perl -I./lib tests/unit/test_mymodule.pl

# 3. Manual integration test
./clio --debug --input "test your change" --exit

# 4. Check for new errors
./clio --input "complex test" --debug --exit 2>&1 | grep ERROR
```

### Test Locations
- `tests/unit/` - Single module tests
- `tests/integration/` - Cross-module tests

### New Feature = New Test
If you add a tool or change a protocol:
1. Create test file: `tests/unit/test_your_feature.pl`
2. Run it: `perl -I./lib tests/unit/test_your_feature.pl`
3. Include it in commit

## PR Instructions

### Commit Message Format
```
type(scope): brief description

Problem: What was broken/incomplete
Solution: How you fixed it
Testing: How you verified the fix
```

**Types:** feat, fix, refactor, docs, test, chore

**Example:**
```bash
git add -A
git commit -m "fix(error-handling): wrap tool execution in try/catch

Problem: Tools could crash AI loop if execution failed
Solution: Added ErrorHandler module with eval wrapping
Testing: Verified malformed input doesn't crash loop"
```

### Before Committing Checklist
- [ ] `perl -c` passes on all changed .pm files
- [ ] No bare `die` statements (use error handlers)
- [ ] No hardcoded `print`/`warn` without checking `should_log()`
- [ ] POD documentation updated if API changed
- [ ] Commit message explains WHAT and WHY
- [ ] No `TODO`/`FIXME` comments (finish the work!)
- [ ] Test coverage for new code

## Development Tools

### Terminal Testing
```bash
# Start new session with debug
./clio --debug --new

# Test specific input
./clio --input "read lib/CLIO/Core/Config.pm" --exit

# Check for syntax errors
find lib -name "*.pm" -exec perl -I./lib -c {} \;

# Search codebase
git grep "function_name" lib/

# Check git status
git status
git log --oneline -10
```

### Module System

**Naming Convention:**
| Prefix | Purpose | Example |
|--------|---------|---------|
| `CLIO::Core::` | System core | APIManager, WorkflowOrchestrator |
| `CLIO::Tools::` | AI-callable operations | FileOperations, VersionControl |
| `CLIO::UI::` | Terminal interface | Chat, Markdown, Theme |
| `CLIO::Session::` | Session management | Manager, State, TodoStore |
| `CLIO::Memory::` | Context storage | ShortTerm, LongTerm, YaRN |
| `CLIO::Protocols::` | Complex workflows | Architect, Editor, Validate |
| `CLIO::Security::` | Auth/authz | Auth, Authz, Manager |
| `CLIO::Util::` | Utilities | PathResolver, TextSanitizer |

## Anti-Patterns (NEVER DO THESE)

| Anti-Pattern | Why | What To Do Instead |
|--------------|-----|-------------------|
| Skip syntax check before commit | Causes silent failures | `perl -c` every file |
| `print()` without `should_log()` check | Debug floods | Use Logger module |
| Label bugs as "out of scope" | Harms quality | Own the problem, fix it |
| `TODO` comments in final code | Technical debt | Finish the implementation |
| Assume code behavior without reading | Causes mistakes | Read the code, understand it |
| Commit without testing | Breaks builds | Test before committing |
| Bare `die` in tool execution | Crashes AI loop | Use error handlers |
| Giant modules (>100 lines) | Hard to maintain | Split into focused modules |
| Add UI clutter like `[TOOL]` displays | Noise without value | Tools are background - don't announce them |

## Documentation

### What Needs Documentation
1. **New features** - Add POD to module + update docs/
2. **API changes** - Update ARCHITECTURE.md
3. **User-facing changes** - Update USER_GUIDE.md
4. **Design decisions** - Add to PROJECT_DECISIONS.md
5. **Known issues** - Update KNOWN_ISSUES.md

### Documentation Files
| File | Purpose | Audience |
|------|---------|----------|
| `README.md` | Project overview | Everyone |
| `docs/ARCHITECTURE.md` | System design | Developers |
| `docs/USER_GUIDE.md` | How to use | Users |
| `docs/DEVELOPER_GUIDE.md` | How to extend | Contributors |
| `docs/CUSTOM_INSTRUCTIONS.md` | Project behavior | Projects using CLIO |
| `scratch/CODEBASE_REVIEW.md` | Code health assessment | Developers |
| `scratch/ACTION_PLAN.md` | Refactoring roadmap | Developers |

## Quick Reference

```bash
# Check syntax
perl -I./lib -c lib/CLIO/Module.pm

# Run test
perl -I./lib tests/unit/test_feature.pl

# Interactive debug session
./clio --debug --new

# Quick test
./clio --input "your test query" --exit

# Search code
git grep "pattern" lib/

# Git operations
git status
git diff
git add -A
git commit -m "type(scope): description"
```
