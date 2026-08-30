# CLIO Trim Priority Order

**Version:** 1.0
**Date:** 2026-08-27
**Status:** Implemented
**Related:** [`PROMPT_PIPELINE.md`](./PROMPT_PIPELINE.md) - section layout,
trim policy, and CSSS slot.

The Trim Priority Order is a defended, documented ranking of what
survives a context budget trim. Every unit in the message array is
classified into one of six tiers. The budget walk drops units in
strict tier order: Tier 4 first, then Tier 3, then Tier 2 — but only
after every Tier 4 unit has been dropped and the budget still
overflows.

Without a documented priority order, every trim is heuristic
guesswork and we end up chasing symptoms (mid-session agent restart,
context loss, schema dumps pushing out task work) instead of a
stable contract.

---

## Tier Overview

| Tier | Name | Trimmable? | Reasoning |
|------|------|-----------|-----------|
| 0 | PRESERVED REGARDLESS | NEVER | Required for correctness or cache stability. |
| 1 | ROTATING SUMMARY | NEVER (within slot) | CSSS slot. Captures dropped state. |
| 2 | HIGH-VALUE DIALOG | NEVER within current task | Current task description, recent intent. |
| 3 | MEDIUM-VALUE DIALOG | YES, oldest first | Assistant reasoning, consumed tool_results. |
| 4 | LOW-VALUE / FIRST TO DROP | YES, FIRST | Errors, acks, empty turns, already-consumed reads. |
| 5 | CSSS SUMMARY CANDIDATES | Compressed into summary | Dropped tier 3/4 content captured before drop. |

---

## Tier 0 - PRESERVED REGARDLESS

**Members:** system_prompt [0], context_files [1], user_input [5].

**Why preserved:**

- **system_prompt** is the LCP cache anchor. Trimming it changes the
  prompt byte prefix and invalidates the LCP cache for the entire
  session. The cost of re-prompting is non-trivial for local inference
  servers (CachyLLama: ~63 seconds for the full CLIO system prompt).

- **context_files** are user-curated. Dropping them silently is a bug
  - the user added the file expecting the model to see it. Drop must
  be explicit, never silent.

- **user_input** is the current turn. Trimming it would either lose
  the request entirely or send a truncated version, both of which
  break the round-trip.

**Detection:** `_extract_preserved_units` finds `system_msg` at
position [0] and `preserved_general_system` / `preserved_user_contexts`
for context_files and trailing anchors at [1]. These are emitted to
the output verbatim, never participating in the budget walk.

---

## Tier 1 - ROTATING SUMMARY

**Members:** thread_summary [3] (CSSS slot).

**Why preserved:** The thread_summary is the only mechanism that
captures the state of dropped Tier 3/4 units. Dropping the summary
itself is not "preservation" - it's catastrophic context loss.

**Lifecycle:** The summary grows organically (the slot is a ceiling,
not a lock) up to `MAX_CSSS_SLOT_TOKENS` (12K). When dropped content
exceeds 1.5x the current slot, it grows by 1.5x (capped at MAX)
before compression to absorb dropped tokens without hard-truncating
captured state. Earlier versions locked the slot with padding to a
fixed MIN_CSSS_SLOT_TOKENS floor; this was removed in 2026-08-27
because the padding was visible to the model as a massive artifact.

**Detection:** `_extract_preserved_units` performs a second-pass
reverse walk looking for the trailing `<thread_summary>` system
message. When found, marks the unit with `is_trailing_summary` so the
budget walk skips it (it's emitted at the END separately).

---

## Tier 2 - HIGH-VALUE DIALOG

**Members:** The most recent user message, the most recent assistant
turn containing the active task, and any tool_results whose
`tool_call_id` matches the most recent assistant tool_calls.

**Why preserved within current task:** The model needs to know what
the user asked for. Dropping the user's most recent task description
in a long autonomous tool loop leaves the model with no anchor -
assistant+tool pairs alone don't say what's being worked on.

**Detection:**
- The last user message (the model just used it; dropping it loses
  the task context).
- The most recent assistant message (current reasoning).
- Tool_results paired with the most recent assistant tool_calls
  (causally linked to the current task).

**Implementation:** `_extract_preserved_units` finds
`$last_user_unit` by walking for the newest user-role message. The
budget walk includes the most recent N units unconditionally (where
N is the floor: 5 units, ~last few minutes of dialog).

---

## Tier 3 - MEDIUM-VALUE DIALOG

**Members:** Older assistant+tool_result units with substantive content
(non-empty assistant reasoning, tool_results that haven't been
"consumed" yet by a later assistant turn).

**Detection:** Units without `has_tool_error`,
`has_empty_assistant`, `is_acknowledgement`, or
`is_successful_read_to_written_path` markers (Tier 4). All other
non-error units default to Tier 3.

**Drop order:** Oldest first within Tier 3.

---

## Tier 4 - LOW-VALUE / FIRST TO DROP

**Members (dropped FIRST before Tier 3):**

1. **Tool results with error/stop markers.**
   - `TOOL ERROR`, `ERROR:`, or `STOP:` prefix.
   - Already implemented in commit 0cb9cc30.
   - Marker: `has_tool_error`.

2. **Empty assistant messages.**
   - `content` is empty or whitespace-only, no `tool_calls`.
   - Marker: `has_empty_assistant`.

3. **Acknowledgement assistant messages.**
   - `content` is < 50 characters, no `tool_calls`, no `reasoning_content`.
   - Examples: "OK", "Got it", "Let me try".
   - Marker: `is_acknowledgement`.

4. **Successful read tool_results whose file path was later written.**
   - Heuristic: the tool_result content contains a file path that
     appears in a later assistant message's tool_calls as a write
     target (`write_file` / `apply_patch` / `create_file` operations
     targeting the same path).
   - These reads are the model's intermediate exploration; once the
     write succeeds, the read content is redundant.
   - Marker: `is_successful_read_to_written_path`.

**Drop order:** All Tier 4 units drop before any Tier 3 unit is
considered. Within Tier 4, drop oldest first.

---

## Tier 5 - CSSS SUMMARY CANDIDATES

**Members:** Dropped Tier 3/4 content captured before drop.

**Implementation:** When a unit is dropped from the conversation, its
messages are accumulated in `@dropped_units` and passed to
`_compress_dropped`. The compressed output becomes the new
`thread_summary` (Tier 1), bounded by the CSSS slot size.

This tier is a transformation, not a unit: there's no "Tier 5 unit"
in the conversation. Tier 5 captures the state of dropped Tier 3/4
content before it's removed.

---

## Budget Walk Algorithm

The budget walk proceeds in passes. Each pass walks the units from
newest to oldest within a tier, includes them if budget allows, and
defers overflow to the next pass.

```
Pass 1: Tier 4 (oldest first within tier)
  - Walk @tier4_units oldest -> newest.
  - Include if budget allows.
  - Mark as @dropped_units if not included (Tier 5 capture).
  - Stop when no Tier 4 units remain or budget is full.

Pass 2: Tier 3 (oldest first)
  - Walk @tier3_units oldest -> newest.
  - Include if budget allows.
  - Mark as @dropped_units if not included.
  - Stop when budget is full.

Pass 3: Tier 2 (only if budget STILL overflows after Pass 1+2)
  - Walk @tier2_units oldest -> newest, NEVER dropping the most
    recent N units (where N = MAX_PRESERVED_HIGH_VALUE).
  - Include if budget allows.
  - Mark as @dropped_units if not included.
```

After all passes, `@dropped_units` is compressed into the new
`thread_summary` via `_compress_dropped`, fitting within the CSSS
slot.

---

## Constants

| Name | Value | Purpose |
|------|-------|---------|
| `MAX_CSSS_SLOT_TOKENS` | 12000 | CSSS slot size ceiling (hard cap). |
| `MIN_CSSS_SLOT_TOKENS` | 8192 | Resume fast-path gate (payload size check). |
| `DEFAULT_POST_TRIM_FLOOR` | 24000 | Minimum tokens retained verbatim. |
| `MAX_PRESERVED_HIGH_VALUE` | 5 | Tier 2 units always preserved. |
| `ACK_THRESHOLD_CHARS` | 50 | Tier 4 acknowledgement length cap. |

Defined in `lib/CLIO/Core/Defaults.pm`.

---

## Markers

Each unit in `@units` carries zero or more marker fields set during
`_group_into_units`:

| Marker | Type | Meaning |
|--------|------|---------|
| `has_tool_error` | bool | Unit contains a TOOL ERROR/ERROR:/STOP: tool_result. |
| `has_empty_assistant` | bool | Assistant message is empty/whitespace, no tool_calls. |
| `is_acknowledgement` | bool | Assistant content < 50 chars, no tool_calls, no reasoning. |
| `is_successful_read_to_written_path` | bool | Read result consumed by a later write to same path. |
| `is_trailing_summary` | bool | Unit is the trailing thread_summary (CSSS slot). |
| `is_orphan_tool_result` | bool | Tool result with no matching tool_call. |

Each marker flags the unit as belonging to a specific drop tier.
A unit may carry multiple markers; the highest-priority tier wins.

---

## Trade-offs

**Conservative drop.** Tier 4 is dropped aggressively, but Tier 3 is
walked oldest-first within the tier. We never drop the most recent N
Tier 2 units. The risk of over-aggressive trim is context loss; the
risk of under-aggressive trim is context overflow. The tier system
makes the trade-off explicit and reproducible.

**Heuristic markers.** `is_successful_read_to_written_path` requires
cross-referencing the file path in tool_results with later
tool_calls. This is a heuristic - false positives (the model reads
a file before writing a DIFFERENT file of the same name in a
subsequent turn) are possible but rare. False negatives (missing a
consumption that would benefit from dropping) are cheap. Heuristic
skews toward false negatives for safety.

**Empty assistant detection.** Whitespace-only content is dropped.
This catches "OK", "Let me try", and trailing-newline artifacts.
Real assistant content with meaningful reasoning is preserved even
if short.

**Acknowledgement threshold.** 50 chars is a heuristic. "Yes, I'll
do that now." (28 chars) is dropped; "I see, the issue is that we
need to fix the regex first." (60 chars) is preserved. The threshold
is tunable in `Defaults.pm`.

---

## Diagnostics

When `CLIO_TRIM_DIAG=1` is set, `validate_and_truncate` writes a
diagnostic file to `/tmp/clio_trim_validator_<ts>_<pid>.log` with:

- Unit count by tier
- Tokens dropped per tier
- Which units were dropped and why
- CSSS slot target and actual summary token count

Use `tools/context_inspector.pl <session_id> --restarts` to find
sessions where the trim dropped too aggressively.

---

## Test Coverage

| Test | Coverage |
|------|----------|
| `tests/unit/test_trim_error_priority.pl` | Tier 4 error/STOP: trim first. |
| `tests/unit/test_trim_priority_order.pl` | All six tiers, tight budget, verify drop order. |
| `tests/unit/test_trim_priority_regression.pl` | Real session, verify Tier 0/1/2 across trim cycles. |

---

## Future Work

- **Tier 4 "successful read to written path"** detection has a known
  false-positive class: when a file is read, the contents are
  embedded, then the model writes a DIFFERENT file, the read is
  incorrectly flagged. Future: scope by turn range (only flag reads
  in the same 10-turn window as the write).
- **Tier 4 "long empty assistant turns with reasoning_content".**
  Reasoning content is currently preserved; if reasoning exceeds 5K
  tokens, it could be compressed into the summary instead. Future:
  add `is_long_reasoning` marker.
- **Tier 2 floor.** `MAX_PRESERVED_HIGH_VALUE` (5 units) is
  conservative. Future: model-class-aware (S-class uses 3, XL uses 8).