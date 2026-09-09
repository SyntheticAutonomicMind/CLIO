# context_compare.pl

Side-by-side comparison of the four message arrays CLIO could send to a
model from a single session JSON. Surfaces subtle context-management
divergences between the four code paths that produce the model's
context.

## What it does

CLIO has four distinct code paths that can produce the message array
sent to the model. They are NOT equivalent, and the differences are
where the bulk of context-management bugs live:

1. **pre-trim rebuild** — what `_build_turn_context` produces when we
   rebuild on resume and there's plenty of room. Fresh system prompt +
   `load_conversation_history()` + `strip_messages_noise()` +
   `ContextBuilder::build_projection()` (anchor turn + recent window +
   YaRN-compressed tail) + dynamic `userContext` + current user input.

2. **post-trim rebuild** — same as (1) but then run through
   `MessageValidator::validate_and_truncate` with the model's actual
   context window. Shows what gets dropped and what gets YaRN-summarized
   into a `<thread_summary>`.

3. **fast-resume (cached payload)** — the `last_api_payload` array
   verbatim, with a drift-check report (provider / tools_signature /
   context_window match). This is what would actually be sent if the
   fast-path succeeds. **This is NOT equivalent to a rebuild** — the
   cache preserves every tool call and result from the previous turn,
   while a rebuild aggressively projects history into anchor + recent
   window + YaRN-compressed tail. The drift check only catches
   provider/tools/window drift, not content drift.

4. **rebuild (forced)** — same as (1) but called out separately so
   the side-by-side makes the fast-path's role explicit. Identical
   to (1) in this tool; the label is for clarity in the output.

## Usage

```bash
# Single-session comparison (default text output)
tools/context_compare.pl .clio/sessions/<sid>.json

# Suppress the header banner
tools/context_compare.pl <session> --quiet

# Show only the divergence report (skip per-message dumps)
tools/context_compare.pl <session> --diff-only

# Force a smaller context window (drives scenarios 2-4 into trim)
tools/context_compare.pl <session> --budget=8000

# Simulate a different provider for the drift check
tools/context_compare.pl <session> --provider=anthropic

# Inspect a specific message range in a specific scenario
tools/context_compare.pl <session> --messages=pre-trim:0-50
tools/context_compare.pl <session> --messages=fast-resume:1895-1905

# JSON output (for CI / regression tests)
tools/context_compare.pl <session> --json

# Two-session diff (regression test: before vs after a code change)
tools/context_compare.pl <session_before>.json <session_after>.json
tools/context_compare.pl <a>.json <b>.json --json
```

## Output

### Text mode (default)

For each scenario, a tree view with:

- Section breakdown (system_prompt, context_files, dialog, summary,
  user_context, user_input) with counts and estimated tokens.
- Notes (warnings, drift status, dropped messages, compressed tail).
- Per-message dump (default: first 10 + last 5 for large arrays, or
  use `--messages=SCOPE:RANGE` to inspect a specific range).

Then a **DIVERGENCE REPORT** with:

- Pairwise structural diffs (added/removed/reorder %) across all four
  pairs that matter (rebuild vs cache, rebuild before/after trim, etc.)
- Token budget per scenario.
- **Red flags** — explicit warnings when fast-resume diverges from
  rebuild, when post-trim drops messages, and when the drift check
  fails.

### JSON mode

Same data, machine-readable. Two-session mode emits a top-level
`scenario_diffs` array suitable for diffing in CI:

```json
{
  "mode": "two-session",
  "session_a": "...",
  "session_b": "...",
  "scenario_diffs": [
    { "scenario": "pre-trim", "a_messages": 322, "b_messages": 793,
      "common": 220, "added": 430, "removed": 272, "reorder_pct": "99.40" },
    ...
  ]
}
```

## What it surfaces (real findings from this tool)

The tool was developed against 5 sessions ranging from 2 messages to
2124 messages. Initial runs surfaced:

- **fast-resume vs rebuild divergence** — The cached `last_api_payload`
  preserves the verbatim tool-call/tool-result history of the last
  turn, while a rebuild aggressively trims older turns into a
  YaRN-compressed tail. On a 1900-message session, fast-resume
  produces 1901 messages / 479K tokens vs rebuild's 322 messages /
  111K tokens. The drift check passes (provider + tools + window all
  match) but the content diverges by ~4x.

- **Cached payload missing the fresh system prompt** — `last_api_payload`
  starts with `role=assistant` (no system prompt at index 0). The
  rebuild path always prepends a fresh system prompt. The fast-path
  intentionally does not (the system prompt is shared from the
  per-iteration refresh), but the consequence is that the model sees
  a different system_prompt content between the two paths.

- **`userContext` ordering** — The rebuild path pushes the dynamic
  userContext at the END of the messages array (after user_input).
  The cached fast-resume payload has the dynamic userContext MIDDLE
  (between system_prompt and the dialog). This affects cache stability
  and where the model attends.

- **Drift check is metadata-only** — It catches provider / tools /
  context_window changes, but not content drift caused by a
  ContextBuilder change between the cached payload's snapshot and the
  current rebuild. If a future commit changes how turns are selected
  or how YaRN compresses, the fast-path will silently send the OLD
  format while the rebuild path sends the NEW format.

## How it works

The tool re-runs CLIO's actual pipeline against the session JSON:

- `CLIO::Core::PromptBuilder->build_system_prompt()` for the system
  prompt.
- `CLIO::Core::ConversationManager::load_conversation_history()` for
  the dialog (with orphan repair).
- `CLIO::Core::ConversationManager::strip_messages_noise()` for
  reasoning_content stripping.
- `CLIO::Core::ContextBuilder::build_projection()` for the relevance-
  aware anchor / recent / compressed-tail selection.
- `CLIO::Core::MessageHistory::messages_to_prose_dynamic()` for the
  dynamic userContext prose.
- `CLIO::Core::API::MessageValidator::validate_and_truncate()` for
  the post-trim variant.

For fast-resume, the tool uses the cached `last_api_payload` directly
and replicates the four-condition drift check from
`WorkflowOrchestrator::_try_resume_from_payload`. No live API call
is made — this is offline analysis.

A minimal `StubSession` object provides the duck-typed interface
(`state`, `get_conversation_history`, `can`, `id`, etc.) that the
modules expect. No full `Session::Manager` is instantiated.

## When to use

- **Investigating a context-management bug** — "The model is looping /
  hallucinating / losing track on resume." Run this on the affected
  session and compare scenarios to see exactly what the model sees in
  each path.

- **Regression testing context-management changes** — Save the session
  JSON before a change. Make the change. Save the new session JSON.
  Run the two-session diff to see what changed in the rebuilt message
  array.

- **Auditing the fast-path cache** — Run on a session whose
  `last_api_payload` is suspiciously large or missing a system
  prompt. The fast-resume scenario shows what the cache would actually
  send on resume.

- **Verifying the drift check** — Pass `--provider=other` or
  `--budget=1000` to simulate a drift condition. The fast-resume
  scenario's `drift_status` and `drift_reasons` will surface the
  reason fast-path would be skipped.

## Limitations

- The tool reads the session JSON. It does NOT reproduce every
  pre-flight state (MCP server connectivity, plugin tool registration,
  broker coordination, file vault state). The drift check therefore
  cannot catch every reason the fast-path would be skipped in
  production. Treat the drift check as "would the fast-path fire
  given the session's saved metadata" — not "would the fast-path
  fire right now in this process."

- `get_conversation_history()` returns whatever the session JSON
  contains. If the session was edited by hand or corrupted, the
  rebuild scenarios reflect that.

- The post-trim scenario uses a token budget = `int(ctx_window * 0.75)`.
  This matches the formula in `MessageValidator` when no
  `trim_threshold` is given. Use `--budget=N` to override.

- The tool is read-only. It never writes to the session.

- The tool's "user_input used for rebuild" defaults to the LAST user
  message in the history. This is the closest proxy to "what a user
  just sent" without knowing the next turn's input. It means the
  rebuild scenarios include the same user message twice (once from
  `load_conversation_history`, once as the new turn's input). This
  is a real divergence surface — if the model is meant to see
  exactly the same user input twice, the rebuild path is doing what
  it should; if it isn't, you've found a bug.

## See also

- `tools/context_inspector.pl` — quick view of the stored `history`
  and `last_api_payload`. Complements this tool: use `context_inspector`
  to spot a problem, then `context_compare` to dig into it.
- `tools/trim_dryrun.pl` — simulates the trim path at various
  budgets without rebuilding the full pipeline.
- `tools/prompt_layout.pl` — section breakdown of one stored
  payload, no pipeline run.
- `tools/prompt_diff.pl` — diff two stored payloads, no pipeline run.
