# Analysis: Why Agents Are Avoiding user_collaboration Tool

## The Problem

Agents are not using the user_collaboration tool for checkpoints as required by THE_UNBROKEN_METHOD.md. They're implementing changes without getting approval first.

## Root Cause

The commit **b6828cd** ("refactor(prompts): transform from defensive to affirmative framing") removed MANDATORY checkpoint language and replaced it with softer guidance.

### What Was Removed (CRITICAL)

#### 1. MANDATORY Checkpoint Table

**BEFORE (Working):**
```markdown
**CRITICAL: Use user_collaboration tool at these checkpoints:**

| Checkpoint | When | MANDATORY |
|-----------|------|-----------|
| **Session Start** | Multi-step work OR recovering from handoff | YES - Present plan BEFORE starting |
| **After Investigation** | Before making any code/config changes | YES - Get approval first |
| **Before Commit** | After implementation complete | YES - Show results |
| **Session End** | Work complete or blocked | YES - Summary & handoff |
```

**AFTER (Broken):**
```markdown
**CHECKPOINT WHEN:**

1. **Session Start** (multi-step work)
   - Present plan: "Based on your request to [X], here's my plan: 1) [step], 2) [step]. Proceed?"
   - Wait for approval
   - Then execute autonomously
```

**Problem:** Removed "MANDATORY" column and explicit "YES" requirements. Changed from imperative to suggestive.

#### 2. Session Start Checkpoint Protocol

**BEFORE (Working):**
```markdown
**Session Start Checkpoint (MANDATORY):**
1. When user provides multi-step request OR you're recovering a previous session
2. STOP - do NOT start implementation yet
3. Call user_collaboration with your plan:
   - "Based on your request to [X], here's my plan:"
   - "1) [investigation step], 2) [implementation step], 3) [verification step]"
   - "Proceed with this approach?"
4. WAIT for user response
5. ONLY THEN begin work
```

**AFTER (Broken):**
```markdown
1. **Session Start** (multi-step work)
   - Present plan: "Based on your request to [X], here's my plan: 1) [step], 2) [step]. Proceed?"
   - Wait for approval
   - Then execute autonomously
```

**Problem:** 
- Removed numbered step-by-step protocol
- Removed "STOP - do NOT start implementation yet"
- Removed explicit "ONLY THEN begin work"
- Changed from directive commands to description

#### 3. After Investigation Checkpoint

**BEFORE (Working):**
```markdown
**After Investigation Checkpoint (MANDATORY):**
1. You've read files, searched code, understood the context
2. STOP - do NOT start making changes yet
3. Call user_collaboration with findings:
   - "Here's what I found: [summary]"
   - "I'll make these changes: [specific files + what will change]"
   - "Proceed?"
4. WAIT for user response
5. ONLY THEN make changes
```

**AFTER (Broken):**
```markdown
2. **After Investigation** (before implementation)
   - Share findings: "Found [X]. I'll change [Y]. Proceed?"
   - Wait for input
   - Then implement
```

**Problem:**
- Removed explicit step numbers
- Removed "STOP - do NOT start making changes yet"
- Removed detail about what to include in checkpoint
- Changed from protocol to suggestion

#### 4. Concrete Examples

**BEFORE (Working):**
```markdown
**Example - CORRECT Workflow:**
User: "Recover the previous session and continue the work"

Agent: [reads handoff files]
       [calls user_collaboration]:
         "I found your previous session working on SAM-website CSS.
          Based on the handoff, here's my plan:
          1) Revert the unwanted modern neutral CSS changes
          2) Add logo support to original dark gradient style
          3) Verify changes don't break layout
          Proceed with this approach?"
       
User: "Yes, go ahead"

Agent: [NOW starts making changes]

**Example - WRONG (what happened in bug.txt):**
Agent: [reads handoff files]
       [creates todo list]
       [immediately starts reverting CSS]  <- VIOLATED CHECKPOINT
       [makes changes without approval]     <- VIOLATED CHECKPOINT
```

**AFTER (Broken):**
- Completely removed concrete examples
- No "CORRECT" vs "WRONG" comparisons
- No demonstration of actual tool call

**Problem:** Without examples, agents don't see how to actually use the tool.

#### 5. Permission Language

**BEFORE (Working):**
```markdown
**PERMISSION REQUIRED (use user_collaboration):**
- Session start with multi-step work - present plan first
- Before making ANY code/config/file changes - show what you'll change
- Before destructive operations (delete, overwrite existing files)
- Before git commits - show what changed
```

**AFTER (Broken):**
```markdown
**CHECKPOINTS ARE FOR COORDINATION, NOT PERMISSION.**

After checkpoint approval, you own the work.
```

**Problem:**
- Contradictory framing: "not permission" but you must checkpoint
- Removed explicit list of when checkpoints are required
- Changed from "PERMISSION REQUIRED" to "coordination"
- Agents interpret "not permission" as "optional"

#### 6. Complete Request vs Checkpoint Discipline

**BEFORE (Working):**
```markdown
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
```

**AFTER (Broken):**
- Completely removed
- No guidance on balancing autonomy with checkpoints

**Problem:** Agents now interpret "you are an agent" + "work autonomously" as "skip checkpoints and just implement"

## What THE_UNBROKEN_METHOD.md Says

The methodology document is clear about collaboration:

```markdown
### Pillar 1: Continuous Context

Within a session:
- Use a collaboration tool (script, macro, or protocol) that creates checkpoints
- Share findings, propose approaches, and get confirmation before major work
- The AI stays in the same context rather than you responding and breaking flow
```

And:

```markdown
The collaboration tool is the heart of The Unbroken Method. It's what maintains continuous context within a session.

**Requirements:**
- Pauses AI execution for human input
- Displays context clearly
- Captures human response
- Enables continuation
```

## The Mismatch

| THE_UNBROKEN_METHOD.md | Current System Prompt | Result |
|-------------------------|----------------------|--------|
| "Use a collaboration tool" | "CHECKPOINT WHEN:" (optional tone) | Agents skip it |
| "Get confirmation before major work" | "After approval, you own the work" | Agents don't get approval |
| "Pauses AI execution for human input" | "Work autonomously" | Agents don't pause |
| "Share findings, propose approaches" | Removed concrete examples | Agents don't know how |

## The Fix Required

### 1. Restore MANDATORY Language

- Add back "MANDATORY" column in checkpoint table
- Use "MUST" instead of "should" or implied suggestions
- Explicit "YES" requirements for each checkpoint type

### 2. Restore Step-by-Step Protocols

- Numbered steps for each checkpoint type
- Explicit "STOP" commands before implementation
- Clear "ONLY THEN" language for what happens after approval

### 3. Restore Concrete Examples

- Add back CORRECT vs WRONG examples
- Show actual user_collaboration tool calls
- Demonstrate the checkpoint -> approval -> work flow

### 4. Fix Permission Framing

- Change "CHECKPOINTS ARE FOR COORDINATION, NOT PERMISSION" 
- To: "CHECKPOINTS ARE MANDATORY COORDINATION POINTS"
- Restore the list of when checkpoints are REQUIRED

### 5. Restore Complete vs Checkpoint Balance

- Add back the section on "Complete does NOT mean skip checkpoints"
- Include WRONG and RIGHT examples
- Emphasize: checkpointing is PART of completing the request correctly

### 6. Align with THE_UNBROKEN_METHOD.md

- Emphasize that collaboration tool is "the heart" of the method
- State that continuous context requires checkpoints
- Make it clear this is not optional

## Why "Affirmative Framing" Failed

The refactor tried to move from "defensive" (don't do X) to "affirmative" (do Y), but in doing so:

1. **Lost Clarity:** "MANDATORY" became "when" 
2. **Lost Urgency:** "STOP" became implied
3. **Lost Examples:** Removed CORRECT vs WRONG demonstrations
4. **Lost Balance:** Removed guidance on balancing autonomy with checkpoints
5. **Created Confusion:** "Not permission" made agents think checkpoints are optional

**The fix isn't to be more defensive - it's to be MORE DIRECTIVE while staying affirmative:**

- Not: "Don't skip checkpoints" (defensive)
- Not: "Checkpoint when needed" (vague)
- **YES: "CALL user_collaboration at session start. Present your plan. Wait for approval. THEN begin work."** (directive + affirmative)

## Summary

The refactor commit removed the forcing mechanisms that made agents use the collaboration tool:

-  Removed "MANDATORY" markers
-  Removed numbered step protocols with "STOP" commands  
-  Removed concrete CORRECT vs WRONG examples
-  Removed explicit permission requirements list
-  Removed balance guidance (complete != skip checkpoints)
-  Changed tone from directive to suggestive

Result: Agents now work autonomously without checkpoints, violating THE_UNBROKEN_METHOD's core principle that collaboration tool is "the heart" of the methodology.

**Fix:** Restore the mandatory checkpoint discipline while keeping affirmative tone where appropriate.
