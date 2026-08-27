# CLIO Context Analysis Tools

**Version:** 1.0
**Date:** 2026-08-27
**Status:** Implemented

Six tools for diagnosing agent-restart, trim, and LCP-cache issues
in CLIO sessions. All read-only (none modify session files unless
documented).

---

## Tools Overview

| Tool | Purpose | Use case |
|------|---------|----------|
| `tools/context_inspector.pl` | Per-message role/content/tool layout | "What did the model see at turn N?" |
| `tools/prompt_layout.pl` | Section-level token distribution (6 sections) | "How big is each prompt section?" |
| `tools/prompt_diff.pl` | Diff two payloads (added/removed/cache impact) | "What changed between turn N and turn N+1?" |
| `tools/trim_dryrun.pl` | Dry-run trim at various budgets | "What would be dropped at budget X?" |
| `tools/session_stats.pl` | Aggregate stats across sessions | "Is the trim rate climbing this week?" |
| `tools/cache_health.pl` | Per-turn cache hit ratio estimate | "Did the LCP cache collapse?" |

---

## tools/context_inspector.pl

Inspect a single session JSON. Shows role distribution, per-message
preview, and diagnostic warnings.

```bash
# Default: role counts + warnings + per-message preview
perl tools/context_inspector.pl .clio/sessions/<id>.json

# Just the summary
perl tools/context_inspector.pl <id>.json --summary

# Find assistant restart indicators
perl tools/context_inspector.pl <id>.json --restarts

# Find TOOL ERROR responses
perl tools/context_inspector.pl <id>.json --errors

# Show a specific message range
perl tools/context_inspector.pl <id>.json --messages=10-20
```

Implemented in `ai-assisted/20260826/2205/` session (commit 0d4abe8c).

---

## tools/prompt_layout.pl

Visual tree view of a session's prompt structure with token counts per
section. Implements the canonical 6-section layout from
`docs/SPECS/PROMPT_PIPELINE.md`.

```bash
# Default view
perl -I./lib tools/prompt_layout.pl <session.json>

# Show XS-class budget comparison
perl -I./lib tools/prompt_layout.pl <session.json> --model-class=XS

# Auto-detect class from max_tokens
perl -I./lib tools/prompt_layout.pl <session.json>  # (auto)

# JSON output for scripting
perl -I./lib tools/prompt_layout.pl <session.json> --json
```

Sample output:

```
Section              Count    Tokens       %
------------------------------------------------------------------------------
system_prompt            1      8329   98.2%  #######################################
context_files            0         0    0.0%
dialog                   3       151    1.8%
summary                  0         0    0.0%
user_context             0         0    0.0%
user_input               0         0    0.0%
------------------------------------------------------------------------------
TOTAL                    4      8480  100.0%
```

---

## tools/prompt_diff.pl

Diff two session JSONs (or a session and its `last_api_payload`). Reports
added/removed messages, LCP cache impact, and summary delta.

```bash
# Diff two sessions
perl -I./lib tools/prompt_diff.pl <session_a.json> <session_b.json>

# Optional flags
perl -I./lib tools/prompt_diff.pl --a=<file_a> --b=<file_b>
```

Sample output:

```
==============================================================================
PROMPT DIFF
==============================================================================
A: session_a.json (4 messages)
B: session_b.json (45 messages)

Common: 2
Added (in B, not in A): 38 (+36581 tokens)
Removed (in A, not in B): 2 (-131 tokens)

Cache impact (rough estimate):
  Total B tokens: 46360
  Changed tokens: 36712 (79.2% of B)
  Note: structural reordering (deinterleave/reinterleave cycle) changes
  byte positions even when content is the same, breaking the LCP cache hash.
```

---

## tools/trim_dryrun.pl

Dry-run trim on a session JSON at various budget levels. Does NOT
modify the session file.

```bash
# Default budgets: 4000, 8000, 12000, 24000
perl -I./lib tools/trim_dryrun.pl <session.json>

# Custom budgets
perl -I./lib tools/trim_dryrun.pl <session.json> --budgets=1000,2000,4000

# JSON output
perl -I./lib tools/trim_dryrun.pl <session.json> --budgets=8000,24000 --json
```

Sample output:

```
==============================================================================
TRIM DRYRUN - session.json
==============================================================================
Input messages: 45

Budget           Input      Kept   Dropped  Detail
------------------------------------------------------------------------------
8000                45         1        44  44 msgs dropped (assistant=15, system=9, tool=21)
16000               45         1        44  44 msgs dropped (assistant=15, system=9, tool=21)
24000               45         1        44  44 msgs dropped (assistant=15, system=9, tool=21)
```

---

## tools/session_stats.pl

Aggregate statistics across all sessions in `.clio/sessions/`.

```bash
# Default: analyze all sessions
perl -I./lib tools/session_stats.pl

# Limit to first N sessions
perl -I./lib tools/session_stats.pl --limit=10

# JSON output
perl -I./lib tools/session_stats.pl --json
```

Sample output:

```
==============================================================================
SESSION STATS - .clio/sessions
==============================================================================
Sessions analyzed: 5
Total messages: 58 (avg 11.6/session)

Tool calls: 22
Tool errors: 0 (rate: 0.0%)
Trim events: 7 (rate: 12.07%)
Restart indicators: 0 (rate: 0.00%)

Tool call frequency:
  file_operations                    21
  todo_operations                     1
```

---

## Diagnostic Workflows

### "Agent restarted mid-session"

1. `tools/context_inspector.pl <id>.json --restarts` - find the
   restart indicator positions.
2. `tools/context_inspector.pl <id>.json --errors` - check for TOOL
   ERROR bursts before each restart.
3. `tools/prompt_diff.pl <id>.json <previous_id>.json` - see what
   changed structurally between snapshots.
4. If the diff shows tool_calls/tool_results reordered, the deinterleave
   cycle is back (commit 4a8cf26c should have prevented this).

### "First tool call exhausts context"

1. `tools/prompt_layout.pl <id>.json --model-class=XS` - see if the
   system_prompt + AGENTS.md + tools schema exceeds the model's budget.
2. `tools/session_stats.pl --limit=10` - check the model's class
   distribution. If most sessions are M/L but a few crash on first call,
   the crash is on a small-context model.
3. Verify AGENTS.md is in the budget table (XS skips it entirely).

### "Trim rate climbing"

1. `tools/session_stats.pl` - check `trim_rate` over the last N
   sessions.
2. `tools/trim_dryrun.pl <id>.json --budgets=4000,8000,12000,24000`
   on a representative session - see what gets dropped at each
   budget.
3. If Tier 4 (errors + acks) is not being dropped first, the
   trim priority order fix (commit 51e293f4) may have regressed.

### "LCP cache collapsed mid-session"

1. `tools/prompt_diff.pl <id>.json <previous_id>.json` - high
   `Changed tokens %` (>50%) suggests structural change.
2. Check the diff output for "structural reordering" notes.
3. `tools/prompt_layout.pl <id>.json` - verify the summary is at the
   END (not the middle) and `context_files` is preserved at [1].

---

## Test Coverage

Each tool is verified by running it against:
- `tests/integration/test_session_export.pl` - synthetic session with
  all 6 sections populated.
- `tests/unit/test_trim_priority_order.pl` - synthetic session with
  Tier 4 error/empty/ack units for trim_dryrun verification.
- `.clio/sessions/<real_id>.json` - real session data with mixed
  user/assistant/tool/system messages.