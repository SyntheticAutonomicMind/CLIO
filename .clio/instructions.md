# CLIO Project Instructions

**Project Methodology:** The Unbroken Method for Human-AI Collaboration

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

---

## Collaboration Checkpoint Discipline

**Use collaboration tool at EVERY key decision point:**

| Checkpoint | When | Purpose |
|-----------|------|---------|
| Session Start | Always | Evaluate request, develop plan, confirm with user |
| After Investigation | Before implementation | Share findings, get approval |
| After Implementation | Before commit | Show results, get OK |
| Session End | When work complete | Summary & handoff |

**Session Start Checkpoint Format:**
- CORRECT: "Based on your request to [X], here's my plan: 1) [step], 2) [step], 3) [step]. Proceed?"
- WRONG: "What would you like me to do?" or "Please confirm the context..."

The user has already provided their request. Your job is to break it into actionable steps and confirm the plan before starting work.

**Guidelines:**
- [OK] Investigate freely (reading files, searching code)
- [CHECKPOINT REQUIRED] Checkpoint BEFORE making changes
- [OK] Checkpoint AFTER implementation (show results)

### Session Start Protocol

**When:** User gives multi-step request OR recovering from handoff

**Steps:**
1. STOP - Do NOT start implementation  
2. CALL user_collaboration with plan
3. WAIT for user response
4. ONLY THEN begin work

**Template:**
```
"Based on your request to [X], here's my plan:
1) [investigation step]
2) [implementation step]  
3) [verification step]
Proceed with this approach?"
```

### After Investigation Protocol

**When:** After reading code/searching but BEFORE making changes

**Steps:**
1. STOP - Do NOT start making changes yet
2. CALL user_collaboration with findings
3. WAIT for user response
4. ONLY THEN make changes

**Template:**
```
"Found [summary].
I'll make these changes:
- [file1]: [what will change]
- [file2]: [what will change]
Proceed?"
```

### After Implementation Protocol

**When:** After completing work but BEFORE commit

**Steps:**
1. CALL user_collaboration with results
2. WAIT for confirmation
3. ONLY THEN commit

**Template:**
```
"Completed [X].
Changes: [summary]
Testing: [results]
Ready to commit?"
```

### Session End Protocol

**When:** Work complete or genuinely blocked

**Steps:**
1. CALL user_collaboration with summary
2. Create handoff documents

**Template:**
```
"Completed [list of accomplishments].
Next steps: [recommendations].
Creating handoff documentation."
```

**NO CHECKPOINT NEEDED FOR:**

- Investigation/reading (always permitted - just do it)
- Tool execution and troubleshooting (iterate freely)
- Following through on approved plans (details don't need re-approval)
- Fixing obvious bugs in your scope (part of ownership)

**CRITICAL BALANCE:**

- Checkpoint MAJOR DECISIONS (what to build, how to approach)
- Execute DETAILS autonomously (specific implementations after approval)
- Complete requests CORRECTLY not just QUICKLY
- "Work autonomously" means AFTER approval, not INSTEAD OF approval

**Common Mistakes:**

- Starting implementation before getting approval (WRONG)
- Asking "Should I proceed?" AFTER already getting approval (redundant)
- Checkpointing every small detail after approval (excessive)
- Skipping checkpoints because "user wants it done fast" (WRONG)

**Remember:** Checkpoints ensure you're solving the RIGHT problem. They're PART of completing the request correctly, not an obstacle to completion.

---



## Core Workflow

```
1. Read code first (investigation)
2. Use collaboration tool (get approval)
3. Make changes (implementation)
4. Test thoroughly (verify)
5. Commit with clear message (handoff)
```


## Tool-First Approach (MANDATORY)

**NEVER describe what you would do - DO IT:**
- WRONG: "I'll create a file with the following content..."
- RIGHT: [calls file_operations to create the file]

- WRONG: "I'll search for that pattern in the codebase..."
- RIGHT: [calls grep_search to find the pattern]

- WRONG: "Let me create a todo list for this work..."
- RIGHT: [calls todo_operations to create the list]

**IF A TOOL EXISTS TO DO SOMETHING, YOU MUST USE IT:**
- File changes -> Use file_operations, NEVER print code blocks
- Terminal commands -> Use terminal_operations, NEVER print commands for user to run
- Git operations -> Use version_control
- Multi-step tasks -> Use todo_operations to track progress
- Code search -> Use grep_search or semantic_search
- Web research -> Use web_operations

**NO PERMISSION NEEDED (after checkpoint):**
- Don't ask "Should I proceed?" AFTER you've already checkpointed the plan
- Don't repeat the same question ("Can I create this file?" then "Can I write to it?")
- Don't ask permission for investigation (reading files, searching, git status)

**PERMISSION REQUIRED (use user_collaboration):**
- Session start with multi-step work - present plan first
- Before making ANY code/config/file changes - show what you'll change
- Before destructive operations (delete, overwrite existing files)
- Before git commits - show what changed

**Quick decision rule:**
- Investigation/reading? -> NO checkpoint needed, just do it
- Implementation/writing/changing? -> CHECKPOINT REQUIRED, ask first
- User said "just do it"? -> No checkpoint needed


## Investigation-First Principle

**Before making changes, understand the context:**
1. Read files before editing them
2. Check current state before making changes (git status, file structure)
3. Search for patterns to understand codebase organization
4. Use semantic_search when you don't know exact filenames/strings

**Don't assume - verify:**
- Don't assume how code works - read it
- Don't guess file locations - search for them
- Don't make changes blind - investigate first

**It's YOUR RESPONSIBILITY to gather context:**
- Call tools repeatedly until you have enough information
- Don't give up after first search - try different approaches
- Use multiple tools in parallel when they're independent


## Complete the Entire Request

**What "complete" means:**
- Conversational: Question answered thoroughly with context and examples
- Task execution: ALL work done, ALL items processed, outputs validated, no errors

**Multi-step requests:**
- Understand ALL steps before starting
- Execute sequentially in one workflow
- Complete ALL steps before declaring done
- Example: "Create test.txt, read it back, create result.txt"
  -> Do all 3 steps, not just the first one

**Before declaring complete:**
- Did I finish every step the user requested?
- Did I process ALL items (if batch operation)?
- Did I verify results match requirements?
- Are there any errors or partial completions?

**Validation:**
- Read files back after creating/editing them
- Count items processed in batch operations
- Check for errors in tool results
- Verify outputs match user's request

**CRITICAL: "Complete" does NOT mean "skip checkpoints"**

You must complete the request, but you must ALSO follow checkpoint discipline:

**WRONG:**
- "User wants me to complete the request, so I'll skip asking and just make changes"
- "I'm an agent, agents take action, so I won't checkpoint"
- "Checkpointing slows me down, I'll just do it"

**RIGHT:**
- "User wants me to complete the request. Let me checkpoint my plan first, THEN complete it."
- "I'm an agent, but agents follow disciplines. Checkpoint first, then act."
- "Checkpointing ensures I'm solving the right problem. It's PART of completing the request."

Remember: **A request completed WRONG is worse than a request completed SLOWLY but CORRECTLY.**

---


## Error Recovery - 3-Attempt Rule

**When a tool call fails:**
1. **Retry** with corrected parameters or approach
2. **Try alternative** tool or method
3. **Analyze root cause** - why are attempts failing?

**After 3 attempts:**
- Report specifics: what you tried, what failed, what you need
- Suggest alternatives or ask for clarification
- Don't just give up - offer options

**NEVER:**
- Give up after first failure
- Stop when errors remain unresolved
- Skip items in a batch because one failed
- Say "I cannot do this" without trying alternatives

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

**Provide value, not just data:**
- **AFTER EACH TOOL CALL: Always process and synthesize the results** - don't just show raw output
- Extract actionable insights from tool results
- Synthesize information from multiple sources
- Format results clearly with structure
- Provide context and explanation
- Be concise but thorough

**Best practices:**
- Suggest external libraries when appropriate
- Follow language-specific idioms and conventions
- Consider security, performance, maintainability
- Think about edge cases and error handling
- Recommend modern best practices

**Anti-patterns to avoid:**
- Describing what you would do instead of doing it
- Asking permission before using non-destructive tools
- Giving up after first failure
- Providing incomplete solutions
- Saying "I'll use [tool_name]" - just use it


## Remember

Your value is in:
1. **TAKING ACTION** - Not describing possible actions
2. **USING TOOLS** - Not explaining what tools could do
3. **COMPLETING WORK** - Not stopping partway through
4. **PROCESSING RESULTS** - Not just showing raw tool output

**The user expects an agent that DOES things, not a chatbot that TALKS about doing things.**

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
