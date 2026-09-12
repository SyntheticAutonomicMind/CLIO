# Prompt Engineering Antipatterns

**Version:** 1.0
**Date:** 2026-09-12
**Purpose:** Catalog antipatterns in model-facing prompt construction that cause
unintended model behavior. Each entry includes a description, the harm it
causes, and the correct pattern.

---

## 1. Imperative Framing in LTM Instructions

**What:** Framing LTM (Long-Term Memory) entries as things the model
"MUST" do (e.g., "Check LTM first when starting work", "Follow Code
Patterns") rather than reference material to consult.

**Harm:** The model treats LTM entries as directives to execute rather
than patterns to inform its approach. When an LTM code-pattern entry
contains verbatim protocol instructions ("before responding to any user
request, ALWAYS (1) run git status --short"), the model follows them as
literal commands.

**Correct pattern:** Use passive or consultative language: "Use LTM
patterns to inform your approach to similar tasks." Present LTM as a
reference knowledge base, not a task list.

**Evidence:** July 25 saved prompt (/Users/andrew/prompt.md) contained
the same "You MUST" LTM instructions and functioned correctly — because
the LTM was rendered as a structured knowledge base, not flat bullets.

---

## 2. Flat-Bullet Rendering of Reference Knowledge

**What:** Rendering knowledge-base entries as flat bullet lists under a
label like "Relevant context from previous sessions:" instead of as a
structured reference (section headers, type grouping, confidence
indicators, framing text).

**Harm:** Flat bullets read as a task list of things to do, not a
reference to consult. The model treats each bullet as an action item.

**Correct pattern:** Use structured knowledge-base rendering:
- Section header (e.g., "## Long-Term Memory")
- Type grouping (e.g., "### Code Patterns", "### Problem Solutions")
- Confidence indicators (e.g., "(Confidence: 95%)")
- Framing text ("These are reference patterns, not current instructions")

---

## 3. Keyword-Overlap Scoring with Double-Counting

**What:** Scoring LTM entries by keyword overlap with both `current_input`
and `active_task`, when `active_task` falls back to `current_input` (for
inputs >= 50 chars with no active session goal). The same keyword overlap
is counted twice: 3x (input) + 2x (task) = 5x instead of 3x.

**Harm:** Entries with even 1 matching keyword (e.g., "this", "with")
score >= 5.5, easily passing the relevance threshold of 5. This causes
unrelated LTM entries to be injected into the model's context.

**Correct pattern:** When `active_task` equals `current_input`, skip the
task-keyword overlap (or use a lower weight) to avoid inflation.

---

## 4. Protocol Instructions in LTM Data

**What:** Storing verbatim protocol instructions in LTM entries (code
patterns) that contain actionable directives like "ALWAYS (1) run
git status --short" or "before responding to any user request".

**Harm:** When these entries are injected into the model's context
(even as "reference" material), the model follows them as literal
commands. The old system-prompt wording ("every session") persists in
LTM even after the wording is fixed in `.clio/instructions.md`.

**Correct pattern:** Sanitize protocol invocation phrases from LTM
entries before injection. Use drop phrases to catch patterns like
"before responding to any user request, ALWAYS..." and
"Failure mode this prevents:".

---

## 5. Framework Narration in Model-Facing Prompts

**What:** Including parentheticals or labels that explain the framework's
internal mechanisms (e.g., "(user context, not system prompt)",
"(framework narration)", "(checkpoints, tool-first, ownership, etc.)")
in prompts sent to the model.

**Harm:** These tell the model "this is framework-managed content,"
causing it to second-guess or over-analyze the context. The model
becomes uncertain about its own state.

**Correct pattern:** Present all content as work product only. Do not
label content with framework metadata. Let the content speak for itself.

---

## 6. User Context Merged into User Message

**What:** Placing dynamic user context (LTM, session goals, environment
info) directly into the user message (role=user) instead of as a
separate system message.

**Harm:** Content placed in a user message is perceived by the model as
instructions from the user, not as system-level context. LTM entries
injecting protocol instructions into the user message read as user
commands to execute.

**Correct pattern:** Keep framework context (LTM, session goals,
environment info) in role=system messages, separate from the user's
actual input. Use XML wrappers or clear headers to delimit sections
within system messages.

---

## 7. Excessive Imperative Directives

**What:** Sending 500+ lines of system prompt with numerous "MUST",
"MANDATORY", "CRITICAL", "DO NOT" directives that prime the model to
pattern-match on the most salient instructions rather than reason about
the task.

**Harm:** The model's attention is drawn to the loudest directives,
causing it to over-focus on protocol compliance rather than task
completion. The volume itself causes directive fatigue.

**Correct pattern:** Reserve "MUST" for safety and security directives
only. Use "Should" or "Consider" for behavioral and workflow guidance.
Keep the system prompt focused on essential behavior, not exhaustive
procedure.

---

## 8. Stale LTM Data with Old Wording

**What:** When `.clio/instructions.md` or the system prompt is updated
to fix ambiguous wording (e.g., "every session" -> "first turn only"),
the LTM entries created from previous sessions still contain the old
wording. The sanitizer does not catch these because they are
user-generated content, not framework narration.

**Harm:** The old wording persists in LTM entries and is re-injected
into new sessions, causing the model to follow outdated instructions.

**Correct pattern:** When fixing wording in `.clio/instructions.md` or
`default.md`, audit LTM entries for the old phrasing and either update
or remove them. The sanitizer should catch protocol instruction phrases
as a defense-in-depth measure.
