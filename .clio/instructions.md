# CLIO Project Instructions

**Version:** 2.0  
**Date:** 2026-02-03  
**Purpose:** Project-specific methodology and workflow (technical reference in AGENTS.md)

---

## Project Methodology: The Unbroken Method

This project follows **The Unbroken Method** for human-AI collaboration. This isn't just project style—it's the core operational framework.

### The Seven Pillars

1. **Continuous Context** - Never break the conversation. Maintain momentum through checkpoints.
2. **Complete Ownership** - Own your scope completely (see Ownership Model below).
3. **Investigation First** - Read code before changing it. Verify through iteration.
4. **Root Cause Focus** - Fix problems, not symptoms.
5. **Complete Deliverables** - Push to actual limits before reporting blockers.
6. **Structured Handoffs** - Document everything for next session.
7. **Learning from Failure** - Document mistakes to prevent repeats.

---

## Collaboration Checkpoint Protocol

**Checkpoints are for coordination, not permission.**

After approval, you own the implementation.

| Checkpoint | When | Format |
|-----------|------|--------|
| **Session Start** | Multi-step work begins | "Based on your request to [X], here's my plan: 1) [step], 2) [step], 3) [step]. Proceed?" |
| **After Investigation** | Before making changes | "Found [X]. I'll change [Y]. Proceed?" |
| **After Implementation** | Before commit | "Completed [X]. Changes: [summary]. Ready to commit?" |
| **Session End** | Work complete or blocked | "Completed [list]. Next: [recommendations]." |

**Decision Tree:**

```
Is this investigation/reading?
  YES -> No checkpoint, just do it
  NO -> Is this changing code/config/files?
    YES -> Checkpoint required (show what you'll change)
    NO -> Is this following approved plan?
      YES -> No checkpoint, proceed
      NO -> Checkpoint if user input needed
```

**Common Mistakes:**

- Asking "Should I proceed?" AFTER already getting approval  
- Checkpointing investigation (reading is always OK)  
- Repeating the same question multiple times  
- Checkpoint major decisions, execute autonomously  

---

## Core Workflow

**Standard Development Cycle:**

```
1. Investigate (read code, search, understand context)
   -> Stop when you have ~70% confidence

2. Checkpoint (share findings, get approval)
   -> Present plan with specific changes

3. Implement (make changes, iterate on errors)
   -> Use tools until resolution

4. Test (verify results, check for regressions)
   -> Practical verification appropriate to scope

5. Commit (clear message, document changes)
   -> Show results before committing
```

**Iteration Model:**

- Errors provide information
- Adjust approach based on feedback
- Keep trying until solved or genuinely blocked
- Report only when exhausted all reasonable approaches

---

## Ownership Model

**Your Primary Scope:**

- The problem user explicitly asked you to solve
- Anything directly blocking that problem
- Obvious bugs in the same system/module you're working in

**Secondary Scope (Fix if Quick, Ask if Complex):**

- Related issues discovered while solving primary problem
- Same system, would improve the solution
- Quick wins (<30 min) that add value

**Out of Scope (Report & Ask):**

- Different systems/modules entirely
- Long-term refactoring tangents
- New feature requests outside stated goal
- Architectural decisions affecting other systems

**Decision Rule:**

| Situation | Action |
|-----------|--------|
| Same system + related issue + quick fix | Fix it |
| Different system + would be useful | Report it, ask priority |
| Scope creep that could distract | Flag and ask user |

**Default: Own your primary scope completely. Ask before expanding to secondary scope.**

---

## Session Handoff Procedures

**When ending a session, ALWAYS create handoff directory:**

```
ai-assisted/YYYYMMDD/HHMM/
├── CONTINUATION_PROMPT.md  [MANDATORY] - Next session's complete context
├── AGENT_PLAN.md           [MANDATORY] - Remaining priorities & blockers
├── CHANGELOG.md            [OPTIONAL]  - User-facing changes
└── NOTES.md                [OPTIONAL]  - Technical notes
```

**Format:**
- `YYYYMMDD` = Date (e.g., `20260203`)
- `HHMM` = Time in UTC (e.g., `0650` for 06:50)

### NEVER COMMIT Handoff Files

**[CRITICAL] Before every commit:**

```bash
# Verify no handoff files staged:
git status

# If ai-assisted/ appears:
git reset HEAD ai-assisted/

# Then commit only code/docs:
git add -A && git commit -m "type(scope): description"
```

**Why:** Handoff files contain internal session context and should NEVER be in public repository.

### CONTINUATION_PROMPT.md (Mandatory)

**Purpose:** Complete standalone context for next session to start immediately.

**Required Sections:**

1. **What Was Accomplished**
   - Completed tasks list
   - Code changes made
   - Tests run and results

2. **Current State**
   - Git activity (commits, branch status)
   - Files modified/created
   - Known issues or blockers

3. **What's Next**
   - Priority 1/2/3 tasks with specifics
   - Dependencies and blockers
   - Recommendations

4. **Key Discoveries & Lessons**
   - What you learned
   - Mistakes avoided
   - Patterns identified

5. **Context for Next Developer**
   - Architecture notes
   - Known limitations
   - Documentation updated

6. **Quick Reference: How to Resume**
   - Commands to run
   - Files to read
   - Starting points

**Principle:** This document must be so complete the next developer can START WORK immediately without investigation.

### AGENT_PLAN.md (Mandatory)

**Purpose:** Quick reference for next session's task breakdown.

**Required Sections:**

1. **Work Prioritization Matrix**
   - Priority, Task, Estimated Time, Status, Blocker

2. **Task Breakdown**
   - For each task: Status, Effort, Dependencies, What to do, Files involved, Success criteria

3. **Testing Requirements**
   - What needs testing
   - How to verify
   - Regression checks

4. **Known Blockers**
   - What's blocking progress
   - What's needed to unblock
   - Workarounds if any

---

## Quality Standards

**Code Quality:**

- Follow language-specific idioms and conventions
- Consider security, performance, maintainability
- Think about edge cases and error handling
- Document design decisions
- Test changes appropriately

**Response Quality:**

- Process and synthesize tool results (don't just dump raw output)
- Extract actionable insights
- Provide context and explanation
- Be concise but thorough
- Suggest external resources when helpful

**Communication:**

- Use markdown for structure and clarity
- Format code/filenames with backticks
- Use lists and headers for complex information
- Prefer unicode symbols over emoji
- Use @-code formatting for terminal emphasis (@BOLD@, @GREEN@, etc.)

---

## Anti-Patterns (What Not To Do)

| Anti-Pattern | Why It's Wrong | What To Do |
|--------------|----------------|------------|
| Describing instead of doing | Wastes time, user expects action | Use tools immediately |
| Analysis paralysis | Perfect understanding impossible | Investigate to ~70%, then act |
| Permission-seeking after approval | Breaks momentum | Checkpoint once, then execute |
| Scope creep without asking | Loses focus on primary goal | Stay in primary scope, ask to expand |
| Partial work without explanation | User doesn't know status | Report incomplete clearly |
| Committing handoff files | Pollutes repository | Always reset ai-assisted/ before commit |
| Giving up after few attempts | Problems are solvable with iteration | Exhaust approaches before reporting blocked |

---

## Project-Specific Conventions

**For technical details, see AGENTS.md:**
- Architecture overview
- Code style and patterns
- Module naming conventions
- Testing procedures
- Quick reference commands

**This document focuses on HOW TO WORK. AGENTS.md covers WHAT TO BUILD.**

---

## Remember

**The Unbroken Method Principles:**

1. Maintain continuous context through checkpoints
2. Own your scope completely
3. Investigate first, but don't over-investigate
4. Fix root causes, not symptoms
5. Deliver complete solutions
6. Document for seamless handoffs
7. Learn from failures, document patterns

**Every session builds on the last. Every handoff enables the next.**

---

*For universal agent behavior, see system prompt.*  
*For technical reference, see AGENTS.md.*
