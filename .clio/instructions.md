# CLIO Project Instructions - COMPREHENSIVE HANDOFF

**Project:** CLIO - Command Line Intelligence Orchestrator  
**Language:** Perl 5.32+  
**Architecture:** Tool-calling AI assistant with terminal UI  

---

## CRITICAL: READ FIRST BEFORE ANY WORK

### The Unbroken Method (Core Principles)

This project follows **The Unbroken Method** for human-AI collaboration. This isn't just project style—it's the core operational framework.

**The Seven Pillars:**

1. **Continuous Context** - Never break the conversation. Maintain momentum through collaboration checkpoints.
2. **Complete Ownership** - If you find a bug, fix it. No "out of scope."
3. **Investigation First** - Read code before changing it. Never assume.
4. **Root Cause Focus** - Fix problems, not symptoms.
5. **Complete Deliverables** - No partial solutions. Finish what you start.
6. **Structured Handoffs** - Document everything for the next session.
7. **Learning from Failure** - Document mistakes to prevent repeats.

**If you skip this, you will violate the project's core methodology.**

### Collaboration Checkpoint Discipline

**Use collaboration tool at EVERY key decision point:**

| Checkpoint | When | Purpose |
|-----------|------|---------|
| Session Start | Always | Confirm context & plan |
| After Investigation | Before implementation | Share findings, get approval |
| After Implementation | Before commit | Show results, get OK |
| Session End | When work complete | Summary & handoff |

**[FAIL]** Create documentation/implementations alone  
**[OK]** Investigate freely, but checkpoint before committing changes

---

## Quick Start for NEW DEVELOPERS

### Before Touching Code

1. **Understand the system:**
   ```bash
   cat docs/ARCHITECTURE.md        # System design
   cat scratch/CODEBASE_REVIEW.md  # Current state assessment
   ```

2. **Know the standards:**
   - All modules: `use strict; use warnings; use utf8;`
   - All modules end with: `1;`
   - All modules have POD documentation
   - Syntax check before commit: `perl -I./lib -c lib/CLIO/Path/To/Module.pm`

3. **Use the toolchain:**
   ```bash
   ./clio --debug --new              # Start with debug mode (interactive, use a timeout)
   /clio --input "test" --debug --exit  # Quick test
   git status                         # Always check before work
   ```

### Core Workflow

```
1. Read code first (investigation)
2. Use collaboration tool (get approval)
3. Make changes (implementation)
4. Test thoroughly (verify)
5. Commit with clear message (handoff)
```

---

## Key Directories & Files

### Core Files
| File | Purpose | Size |
|------|---------|------|
| `clio` | Main executable (tool calling loop) | 17 KB |
| `lib/CLIO/Core/WorkflowOrchestrator.pm` | AI tool orchestration | 45 KB |
| `lib/CLIO/Core/ToolExecutor.pm` | Tool invocation routing | 23 KB |
| `lib/CLIO/Core/APIManager.pm` | AI provider integration | **83 KB** ⚠️ |
| `lib/CLIO/UI/Chat.pm` | Terminal interface | **158 KB** ⚠️ |
| `lib/CLIO/Tools/FileOperations.pm` | File system operations | 52 KB |
| `lib/CLIO/Session/Manager.pm` | Session persistence | 6 KB |

### Directories
| Path | Purpose | Status |
|------|---------|--------|
| `lib/CLIO/Core/` | System core (APIs, workflow, config) | [OK] Complete |
| `lib/CLIO/Tools/` | AI-callable tools (17 operations) | [OK] Complete |
| `lib/CLIO/UI/` | Terminal UI (Chat, Markdown, Theme) | [WARN] Needs refactor |
| `lib/CLIO/Session/` | Session management | [OK] Complete |
| `lib/CLIO/Memory/` | Context/memory system | [WARN] Incomplete |
| `lib/CLIO/Protocols/` | Complex workflows | [?] Needs audit |
| `lib/CLIO/Security/` | Auth/authz | [OK] Complete |
| `docs/` | User/dev documentation | [OK] Good |
| `tests/` | Unit & integration tests | [WARN] 30% coverage |

---

## Architecture Overview

```
User Input
    ↓
Terminal UI (Chat.pm)
    ↓
AI Agent (APIManager → AI Provider)
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

---

## Code Standards: MANDATORY

### Every Module Must Have
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

### Debug Logging: CONSISTENT PATTERN
```perl
# [CORRECT] Always guard debug output:
use CLIO::Core::Logger qw(should_log log_debug);

if (should_log('DEBUG')) {
    print STDERR "[DEBUG][ModuleName] message\n";
}
# Or better:
log_debug('ModuleName', 'message');

# [FAIL] Never:
print STDERR "debug message";              # Not guarded
warn "message";                             # Goes to STDERR uncontrolled
my $x = "debugging";  # Silent debug        # Not visible
```

### Syntax Check Before Commit
```bash
# MANDATORY before any commit:
perl -I./lib -c lib/CLIO/Path/To/Module.pm

# Check all at once:
find lib -name "*.pm" -exec perl -I./lib -c {} \;
```

---

## Testing Requirements

### Before Committing Changes
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

### Test File Location
- `tests/unit/` - Single module tests
- `tests/integration/` - Cross-module tests

### New Feature = New Test
If you add a tool or change a protocol:
1. Create test file: `tests/unit/test_your_feature.pl`
2. Run it: `perl -I./lib tests/unit/test_your_feature.pl`
3. Include it in commit

---

## Commit Workflow

### Commit Message Format
```bash
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

### Before Committing: Checklist
- [ ] `perl -c` passes on all changed .pm files
- [ ] No bare `die` statements (use error handlers)
- [ ] No hardcoded `print`/`warn` without checking `should_log()`
- [ ] POD documentation updated if API changed
- [ ] Commit message explains WHAT and WHY
- [ ] No `TODO`/`FIXME` comments (finish the work!)
- [ ] Test coverage for new code

---

## Anti-Patterns: NEVER DO THESE

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

---

## Development Tools & Commands

### Terminal Testing
```bash
# Start new session with debug (interactive, use a timeout)
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

### Common Tasks
```bash
# See what changed
git diff lib/CLIO/Core/MyModule.pm

# Review before commit
git diff --cached

# Stage specific files
git add lib/CLIO/Core/MyModule.pm

# Commit with message file
cat > /tmp/msg.txt << 'EOF'
fix(module): problem solved

Problem: X
Solution: Y
EOF
git commit -F /tmp/msg.txt

# See commit history
git log --oneline lib/CLIO/Core/MyModule.pm | head -10
```

---

## Module System

### Naming Convention
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

### Creating New Tools
```perl
# 1. Create file: lib/CLIO/Tools/MyTool.pm
package CLIO::Tools::MyTool;
use parent 'CLIO::Tools::Tool';

sub new {
    my ($class, %opts) = @_;
    return $class->SUPER::new(
        name => 'my_tool',
        description => 'What this tool does',
        %opts
    );
}

sub execute {
    my ($self, $params, $context) = @_;
    # Implement tool operation
    return { success => 1, result => $data };
}

1;

# 2. Register in Tools/Registry.pm
# 3. Add POD documentation
# 4. Create tests in tests/unit/
# 5. Commit with clear message
```

---

## Session Handoff Procedures (MANDATORY)

### CRITICAL: Session Handoff Directory Structure

When ending a session, **ALWAYS** create a properly structured handoff directory:

```
ai-assisted/YYYYMMDD/HHMM/
├── CONTINUATION_PROMPT.md  [MANDATORY] - Next session's complete context
├── AGENT_PLAN.md           [MANDATORY] - Remaining priorities & blockers
├── CHANGELOG.md            [OPTIONAL]  - User-facing changes (if applicable)
└── NOTES.md                [OPTIONAL]  - Additional technical notes
```

**Format Details:**
- `YYYYMMDD` = Date (e.g., `20250109`)
- `HHMM` = Time in UTC (e.g., `1430` for 2:30 PM)
- Example: `ai-assisted/20250109/1430/`

### NEVER COMMIT Handoff Files

**[CRITICAL] BEFORE EVERY COMMIT:**

```bash
# ALWAYS verify no handoff files are staged:
git status

# If any `ai-assisted/` files appear:
git reset HEAD ai-assisted/

# Then commit only actual code/docs:
git add -A && git commit -m "type(scope): description"
```

**Why:** Handoff documentation contains internal session context, work notes, and continuation details that should NEVER be in the public repository. This is a HARD REQUIREMENT.

### CONTINUATION_PROMPT.md (MANDATORY)

**Purpose:** Provides complete standalone context for the next session to start immediately without investigation.

**Structure:**
```markdown
# Session Continuation Prompt

**Session ID:** [UUID or date/time]
**Date:** [YYYY-MM-DD HH:MM UTC]
**Status:** [Active/Completed/Blocked]

## What Was Accomplished

- [Completed task 1]
- [Completed task 2]
- [Completed task 3]

## Current State

### Code Changes
- [Files modified with brief description of changes]
- [New modules created]
- [Configuration updates]

### Test Results
- [What was tested and results]
- [Known test status: passing/failing/not-run]

### Recent Git Activity
```bash
[Include last 5-10 commits showing recent work]
```

## What's Next (Next Session)

### Priority 1: [High Priority Task]
- [Specific work to do]
- [Files to modify]
- [Expected outcome]
- [Dependencies: none/[other tasks]]

### Priority 2: [Medium Priority Task]
- [Specific work to do]
- [Related code: lib/CLIO/Module.pm]
- [Testing needed: [types]]

### Priority 3: [Lower Priority Task]
- [Can wait if higher priorities need attention]
- [Good for follow-up if time permits]

## Key Discoveries & Lessons Learned

### What Worked Well
- [Methodology or approach that was effective]
- [Code pattern that proved useful]
- [Testing strategy that caught issues]

### What Was Tricky
- [Areas that required investigation]
- [Edge cases discovered]
- [Unexpected behavior found]
- [How they were resolved]

### Anti-Patterns Identified
- [Patterns to avoid in related code]
- [Common mistakes observed]
- [Root causes of issues found]

## Context for Next Developer

### Architecture Notes
- [Key modules: their roles]
- [Data flow for implemented features]
- [Critical algorithms or patterns used]

### Known Issues & Blockers
- [Issues that remain unresolved (if any)]
- [Blockers: none OR [specific blockers]]
- [External dependencies or approvals needed]

### Documentation Updated
- [docs/FILE.md - What was changed]
- [New specs added]
- [Installation guide updated]

### Testing Checklist for Next Session
```
- [ ] Syntax check: perl -c lib/CLIO/...
- [ ] Unit tests: perl -I./lib tests/unit/...
- [ ] Integration: ./clio --debug --input "test" --exit
- [ ] Manual verification: [describe]
```

## Complete File List

Files modified this session:
- `lib/CLIO/Core/Module.pm` - [change description]
- `lib/CLIO/Tools/Operation.pm` - [change description]
- `docs/SPEC.md` - [change description]

New files created:
- `lib/CLIO/New/Module.pm` - [purpose]
- `tests/unit/test_feature.pl` - [test coverage]

## Quick Reference: How to Resume

```bash
# 1. Read this file for context
cat ai-assisted/YYYYMMDD/HHMM/CONTINUATION_PROMPT.md

# 2. Check file status
git status
git diff HEAD~5

# 3. Review next steps
cat ai-assisted/YYYYMMDD/HHMM/AGENT_PLAN.md

# 4. Start work on Priority 1
[Begin implementing Priority 1 from above]
```

## Questions for Next Developer

**If you get stuck:**
- Review the "Key Discoveries" section above
- Check git log for recent commits and their messages
- Look at tests to understand expected behavior
- Search for similar patterns: `git grep "pattern" lib/`

**If something doesn't work:**
- Compare current code with git history: `git diff HEAD~3`
- Check if tests pass: `perl -I./lib tests/unit/test_file.pl`
- Verify syntax: `perl -c lib/CLIO/Module.pm`
- Try debug mode: `./clio --debug`
```

**Minimum Content:** Even if session was short, include all sections above. No section left empty—explicitly state "None" or "Not applicable" if nothing applies.

**Key Principle:** This document must be so complete that the next developer can read it and START WORK immediately without investigation. It's not a summary—it's a complete transfer of context.

### AGENT_PLAN.md (MANDATORY)

**Purpose:** Quick reference for the next session's task breakdown and priorities.

**Structure:**
```markdown
# Agent Work Plan

## Work Prioritization Matrix

### Immediate (Next Session - Session Priority)
```
Priority | Task | Estimated Time | Status | Blocker
---------|------|-----------------|--------|--------
1 | [Task name] | 30 min | not-started | none
2 | [Task name] | 1 hour | not-started | blocked by Priority 1
3 | [Task name] | 45 min | not-started | none
```

## Task Breakdown

### Task 1: [High Priority Task]
**Status:** Not Started / In Progress / Blocked  
**Effort:** [15 min / 1 hour / etc]  
**Depends On:** None / [other tasks]

**What to do:**
1. [Specific step 1]
2. [Specific step 2]
3. [Verification step]

**Files involved:**
- `lib/CLIO/Module.pm` - Primary change
- `tests/unit/test_module.pl` - Tests
- `docs/SPEC.md` - Documentation

**Success criteria:**
- [Testable objective 1]
- [Testable objective 2]
- Syntax check passes: `perl -c lib/CLIO/Module.pm`

**Related code to study:**
- `lib/CLIO/Similar/Module.pm` - Similar pattern here
- Patterns: `git grep "pattern_to_search" lib/`

---

### Task 2: [Medium Priority Task]
[Same structure as Task 1]

---

### Task 3: [Lower Priority Task]
[Same structure as Task 1]

## Known Blockers & Dependencies

- **Blocker A:** [Description] → Resolution: [how to unblock]
- **Dependency B:** [Description] → Status: [waiting/available]

## Testing Requirements

```bash
# Mandatory before commit:
perl -I./lib -c lib/CLIO/Module.pm          # Syntax
perl -I./lib tests/unit/test_feature.pl     # Unit tests
./clio --debug --input "test" --exit        # Integration test
```

## Code Quality Checklist

Before committing each task:
- [ ] Syntax passes (`perl -c`)
- [ ] Tests pass (if applicable)
- [ ] No bare `die` statements
- [ ] No unguarded debug output
- [ ] POD documentation complete
- [ ] Commit message follows standards
- [ ] No `TODO`/`FIXME` comments (finish the work!)
```

**Format:** Clear, scannable table format for quick reference by the next developer.

### CHANGELOG.md (OPTIONAL)

**Purpose:** User-facing summary of changes (if this session included user-visible changes).

**Use ONLY if:** This session included features, bug fixes, or changes users should know about.

**Structure:**
```markdown
# Changelog - Session YYYYMMDD/HHMM

## New Features
- [Feature name] - [Brief description of what it does]
- [Feature name] - [User-facing benefit]

## Bug Fixes
- [Bug fixed] - [How it affected users + how it's fixed]
- [Bug fixed] - [Specific scenario now works]

## Improvements
- [Performance improvement] - [Metrics if applicable]
- [UX improvement] - [How user experience is better]

## Known Issues
- [If any new issues found during work, document them here]

## Breaking Changes
- [If any existing functionality changed in incompatible way]

## Migration Guide (if breaking changes)
```bash
# If breaking changes exist:
[How users should migrate]
```

## Installation Notes
- [Any setup steps needed]
- [Configuration changes]
- [Dependencies]

## Testing
- [ ] Feature works as documented
- [ ] No regressions in existing features
- [ ] Manual QA complete
```

**Note:** Keep this brief and user-focused. Technical details go in AGENT_PLAN.md.

### NOTES.md (OPTIONAL)

**Purpose:** Additional technical notes that don't fit other files.

**Use for:**
- Deep technical analysis that's useful for reference
- Debugging notes and discoveries
- Performance analysis
- Architecture discussions that weren't documented elsewhere
- Lessons learned specific to implementation

**Structure:** Free-form, but organized by topic.

### Creating Handoff at Session End

**Workflow:**
```bash
# 1. Create the handoff directory with current date/time
mkdir -p ai-assisted/$(date +%Y%m%d)/$(date +%H%M)

# 2. Create the three handoff files:
touch ai-assisted/$(date +%Y%m%d)/$(date +%H%M)/CONTINUATION_PROMPT.md
touch ai-assisted/$(date +%Y%m%d)/$(date +%H%M)/AGENT_PLAN.md
touch ai-assisted/$(date +%Y%m%d)/$(date +%H%M)/CHANGELOG.md  # if user-visible changes

# 3. Fill in each file with complete information
# [Use templates above]

# 4. VERIFY: Do NOT commit these files
git status  # Should NOT show ai-assisted/ in staged files

# 5. Commit actual work (code/docs only, NOT handoff):
git add -A
git status  # Verify ai-assisted/ is NOT in staged
git commit -m "type(scope): description"

# 6. Handoff directory is now ready for next session
ls -la ai-assisted/$(date +%Y%m%d)/$(date +%H%M)/
```

### Reading Handoff in Next Session

**First steps when resuming:**
```bash
# 1. Find latest handoff
ls -lt ai-assisted/*/  # Find most recent YYYYMMDD/HHMM

# 2. Read the continuation prompt for full context
cat ai-assisted/LATEST_DATE_TIME/CONTINUATION_PROMPT.md

# 3. Review the work plan
cat ai-assisted/LATEST_DATE_TIME/AGENT_PLAN.md

# 4. Check git history
git log --oneline -10

# 5. Verify current state
git status

# 6. Start work on Priority 1
[Begin implementing based on AGENT_PLAN.md]
```

### Session Persistence (Technical)

- Sessions saved to: `.clio/sessions/UUID/`
- Each session has: `state.json` + `tool_results/`
- Sessions persist across restarts
- Resume with: `./clio --resume`
- Handoff directories provide HIGH-LEVEL context for humans
- Session files provide LOW-LEVEL state for the AI system

---

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

---

## Quality Standards

### Code Review Checklist
Before submitting code:
- [ ] Syntax passes (`perl -c`)
- [ ] POD documentation complete
- [ ] Follows module naming conventions
- [ ] No bare `die` (use error handlers)
- [ ] No unguarded debug output
- [ ] No `TODO`/`FIXME` comments
- [ ] Tests included/updated
- [ ] Commit message explains changes
- [ ] No CPAN dependencies added
- [ ] Code is readable & maintainable

### Performance Considerations
- Token counting: Cache results for same input
- Large files: Stream instead of loading all
- API calls: Implement exponential backoff retry
- UI rendering: Buffer markdown before output

---

## Remember

**The Unbroken Method is not optional—it's the operating system of this project.**

- Read code before changing it
- Test before committing
- Own every bug you find
- Finish what you start
- Document for the next developer
- Use collaboration checkpoints
- Complete ownership, not "out of scope"

**Every change is an opportunity to improve code quality and understanding.**
