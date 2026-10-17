# CLIO Project Instructions

**Project Methodology:** The Unbroken Method for Human-AI Collaboration

## Session Start Protocol

This protocol runs once, at the very first turn of a session — when the message history is empty. On any later turn, the prior conversation is the context; continue working from there.

When the history is empty:

1. `git status --short` — see what is already modified in the working tree.
2. For any unstaged or staged files, `memory_operations(operation: "recall_sessions", query: "FILENAME")` to learn what was being done with them.
3. If a file is modified in the tree and you do not know why, it is part of THIS session's work until proven otherwise. Investigate before treating anything as out of scope.

**The ownership rule.** There is no "out of scope" for files that were already modified when the session opened. Unbroken Method Pillar 2 applies to all code in the tree, not just code the user explicitly mentions. Never label in-tree work as "pre-existing" or "not my responsibility" without explicit confirmation from the user and a concrete handoff plan.

**Why this exists.** The agent has a tendency to focus on the immediate user request and ignore surrounding state. That is how finished-but-uncommitted work gets orphaned, how regressions sneak in, and how the user ends up having to remind the agent that things are its responsibility. The protocol above forces a state survey at session start before any action.

## Checkpoint Tiers

**Tier 1 - Always pause and use interact:**
- Before making code/config changes (share findings, get go-ahead)
- Before committing changes (show results, verify expectations)
- When blocked (report with options, get guidance)

**Tier 2 - Proceed autonomously:**
- Reading code, running tests, investigating
- Following an approved plan without deviation
- Fixing obvious bugs discovered during investigation
- Tool troubleshooting and iteration through errors

**Tier 3 - No checkpoint needed:**
- Simple tool calls matching user intent directly
- Single-edit tasks that are clearly scoped
- Running verification commands
- Writing todos and updating their status

## The Unbroken Method

This project follows **The Unbroken Method** for human-AI collaboration. This is the core operational framework.

**The Seven Pillars:**

1. **Continuous Context** - Never break the conversation. Maintain momentum through collaboration checkpoints.
2. **Complete Ownership** - If you find a bug, fix it. No "out of scope."
3. **Investigation First** - Read code before changing it. Search for existing implementations before writing new code. Never assume or re-implement.
4. **Root Cause Focus** - Fix problems, not symptoms.
5. **Complete Deliverables** - No partial solutions. Finish what you start.
6. **Structured Handoffs** - Document everything for the next session.
7. **Learning from Failure** - Document mistakes to prevent repeats.

---

## Core Workflow

```
1. Read code first
2. Use collaboration tool
3. Make changes
4. Test thoroughly in conditions that match the target environment. A passing test on your machine is not a passing test everywhere.
5. Commit with clear message
```

---

## Session Handoff Procedures

When ending a session, create handoff notes in `ai-assisted/YYYYMMDD/HHMM/` with `CONTINUATION_PROMPT.md` and `AGENT_PLAN.md`. The full handoff procedure — directory format, the NEVER-COMMIT rule, required sections for each file, and the git staging checklist — is maintained as a reusable skill: load `session-handoff` with `/skill_operations load session-handoff`.

---

*For universal agent behavior, see the system prompt.*
*For technical reference, see AGENTS.md.*
