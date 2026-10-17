---
name: session-handoff
description: "When ending a session, create handoff notes in ai-assisted/YYYYMMDD/HHMM/"
---

# Session Handoff Procedures

**When ending a session, ALWAYS create handoff directory:**

```
ai-assisted/YYYYMMDD/HHMM/
├── CONTINUATION_PROMPT.md  [MANDATORY] - Next session's complete context
├── AGENT_PLAN.md           [MANDATORY] - Remaining priorities & blockers
└── NOTES.md                [OPTIONAL]  - Technical notes
```

**Format:**
- `YYYYMMDD` = Date (e.g., `20260203`)
- `HHMM` = Time in UTC (e.g., `0650` for 06:50)

### NEVER COMMIT Handoff Files

**Before every commit:**

```bash
# Verify no handoff files staged:
git status

# If ai-assisted/ appears:
git reset HEAD ai-assisted/

# Then commit only code/docs:
git add -A && git commit -m "type(scope): description"
```

**Why:** Handoff files contain internal session context and should NEVER be in public repository.

### CONTINUATION_PROMPT.md

**Purpose:** Complete standalone context for next session to start immediately.

**Required Sections:**

1. **What Was Accomplished** - Completed tasks, code changes, test results
2. **Current State** - Git activity, files modified, known issues
3. **What's Next** - Priority 1/2/3 tasks, dependencies, blockers
4. **Key Discoveries & Lessons** - What you learned, patterns identified
5. **Context for Next Developer** - Architecture notes, limitations
6. **Quick Reference: How to Resume** - Commands, files, starting points

**Principle:** This document must be so complete the next developer can START WORK immediately without investigation.

### AGENT_PLAN.md

**Purpose:** Quick reference for next session's task breakdown.

**Required Sections:**

1. **Work Prioritization Matrix** - Priority, Task, Estimated Time, Status, Blocker
2. **Task Breakdown** - Status, Effort, Dependencies, What to do, Files, Success criteria
3. **Testing Requirements** - What needs testing, how to verify, regression checks
4. **Known Blockers** - What's blocking, what's needed, workarounds
