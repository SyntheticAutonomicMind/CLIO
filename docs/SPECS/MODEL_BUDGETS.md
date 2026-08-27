# CLIO Context-Window-Class Model Budgets

**Version:** 1.0
**Date:** 2026-08-27
**Status:** Implemented
**Related:** [`PROMPT_PIPELINE.md`](./PROMPT_PIPELINE.md) - section layout,
[`TRIM_PRIORITY.md`](./TRIM_PRIORITY.md) - what survives a trim.

The model budget system classifies each model's context window into a
class (XS/S/M/L/XL) and returns a budget allocation table for the
prompt sections. This lets CLIO work on small local models (32K or less)
where the full system prompt + AGENTS.md + LTM + tools schema + dialog
would exhaust context on the first tool call.

---

## Class Boundaries

| Class | Context Window | Examples |
|-------|---------------|----------|
| XS    | <= 32K        | 4K-8K quantized, very small local |
| S     | 32K-64K       | CachyLLama llama.cpp UD-Q5_K_XL, small local |
| M     | 64K-128K      | Default for most cloud models with reported context |
| L     | 128K-256K     | Claude Sonnet, GPT-4.1 |
| XL    | > 256K        | MiniMax M3 (1M), Gemini 2.5, DeepSeek-V4 |

Detection: `CLIO::Core::ModelBudget::model_class($context_window)`.

---

## Budget Tables

Each entry maps a prompt section to a token budget. `-1` means
"unlimited (use the actual size)". `0` means "skip this section
entirely".

### XS (<= 32K)

| Section | Budget | Reason |
|---------|--------|--------|
| system_prompt | -1 | REQUIRED for behavior |
| context_files | -1 | user-curated |
| instructions_md | -1 | REQUIRED for behavior |
| agents_md | 0 | SKIP entirely |
| ltm | 0 | SKIP entirely |
| session_goals | 200 | truncated |
| tools_schema | 6000 | filter to essentials |
| csss_slot | 2000 | smaller slot |
| dialog | 8000 | hard cap |

A 32K XS session has roughly:

- system_prompt: ~14K (compressed)
- instructions.md: ~5K
- agents_md: 0 (skipped)
- LTM: 0 (skipped)
- session_goals: 200
- tools_schema: 6K (filtered)
- CSSS slot: 2K
- dialog: 8K hard cap

Total: ~35K of budget for prompt, with ~24K of headroom for the model's
own output. First tool call fits comfortably; no immediate trim.

### S (32K-64K)

| Section | Budget | Reason |
|---------|--------|--------|
| system_prompt | -1 | REQUIRED |
| context_files | -1 | user-curated |
| instructions_md | -1 | REQUIRED |
| agents_md | 5000 | truncated to first 5K |
| ltm | 2000 | top 3 most-recent entries |
| session_goals | -1 | full |
| tools_schema | 12000 | filter to essentials |
| csss_slot | 4000 | smaller slot |
| dialog | 16000 | hard cap |

### M (64K-128K)

| Section | Budget | Reason |
|---------|--------|--------|
| system_prompt | -1 | REQUIRED |
| context_files | -1 | user-curated |
| instructions_md | -1 | REQUIRED |
| agents_md | 15000 | full + buffer |
| ltm | 6000 | top 6-8 most-recent |
| session_goals | -1 | full |
| tools_schema | -1 | all tools |
| csss_slot | 8000 | CSSS default |
| dialog | -1 | no hard cap |

### L (128K-256K)

| Section | Budget | Reason |
|---------|--------|--------|
| system_prompt | -1 | REQUIRED |
| context_files | -1 | user-curated |
| instructions_md | -1 | REQUIRED |
| agents_md | -1 | full |
| ltm | 10000 | top ~10 most-recent |
| session_goals | -1 | full |
| tools_schema | -1 | all |
| csss_slot | 8000 | CSSS default |
| dialog | -1 | no hard cap |

### XL (> 256K)

| Section | Budget | Reason |
|---------|--------|--------|
| system_prompt | -1 | REQUIRED |
| context_files | -1 | user-curated |
| instructions_md | -1 | REQUIRED |
| agents_md | -1 | full |
| ltm | -1 | full |
| session_goals | -1 | full |
| tools_schema | -1 | all |
| csss_slot | 8000 | CSSS default |
| dialog | -1 | no hard cap |

---

## Implementation

`lib/CLIO/Core/ModelBudget.pm` provides:

- `model_class($context_window)` - returns the class name.
- `budget_for($class)` - returns the budget table for a class.
- `effective_budget($context_window, $section)` - convenience.
- `apply_budget_to_payload($budget, $section, $content)` - truncate
  content to fit, or return undef to skip.

XS-class integration:

- `lib/CLIO/Core/InstructionsReader.pm` accepts `model_class` opt. For
  XS class, skips AGENTS.md and replaces it with a one-line pointer
  (`<agentsMdPointer>AGENTS.md exists; see /repo/AGENTS.md for full
  reference.</agentsMdPointer>`).
- `lib/CLIO/Core/PromptManager.pm` exposes `set_model_class($class)`,
  invalidating the custom-instructions cache when class changes.
- `lib/CLIO/Core/PromptBuilder.pm` accepts `model_class` opt and
  propagates to PromptManager.
- `lib/CLIO/Core/WorkflowOrchestrator.pm` computes the class from
  MCM-reported context_window and passes it to PromptBuilder.

---

## Why AGENTS.md Specifically

AGENTS.md is the largest optional content in the prompt. A typical
project's AGENTS.md is 10K-15K tokens (CLIO's is ~15K). On a 32K
context model:

- system_prompt + instructions.md: ~19K
- AGENTS.md: ~15K (would consume the remaining budget)
- dialog: 0

This forces the model to immediately exhaust context on the first
user message. Skipping AGENTS.md entirely is the only way to make XS
sessions viable. The pointer preserves awareness ("AGENTS.md exists")
without paying the token cost.

---

## Why LTM Specifically

LTM (Long-Term Memory) is the second-largest optional content. A
typical session accumulates 5K-10K tokens of LTM patterns. For S-class
models we truncate to the top 3 most-recent entries (~2K tokens) -
recent patterns are most likely to be relevant. For XS we skip entirely
because the cost of any LTM dwarfs the benefit.

---

## Future Work

- **Tools schema filtering.** The XS budget caps tools_schema at 6K
  but doesn't yet implement the actual filtering. Future: enumerate
  registered tools and pick the N most-essential for XS/S budgets.
- **LTM importance-weighted truncation.** Currently truncates by
  recency. Future: importance score (use count, recency) to keep the
  most-useful patterns regardless of recency.
- **Per-section budgets in APIManager.** Currently only AGENTS.md is
  wired. Future: apply `apply_budget_to_payload` to the system prompt
  itself, the tools schema, and the LTM section.
- **Live test on CachyLLama.** The full XS-class path has not been
  validated on a real 32K model. Need to confirm the prompt fits and
  the model produces usable output.

---

## Test Coverage

| Test | Coverage |
|------|----------|
| `tests/unit/test_model_budget.pl` | Class boundaries, budget table values, apply_budget_to_payload, XS AGENTS.md skip, PromptManager cache invalidation. |