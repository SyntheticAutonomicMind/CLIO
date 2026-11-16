# Context Management

Everything CLIO sends to a model in one request: what it is, where it is
built, how big it is allowed to get, and what happens when it does not
fit.

This document is the reference for the context pipeline. If a number
here disagrees with the code, the code is right and this file is a bug.

---

## 1. What a request contains

A Chat Completions request carries four things:

```text
payload
  model          model identifier
  messages       the conversation array
  tools          tool definitions (the callable surface)
  max_tokens     output cap for this response
```

Plus sampling parameters only when explicitly configured.

### The messages array

```text
[0]      system            system prompt
[1..N]   user/assistant/tool   project history, role-based
[N+1]    user              dynamic user context + current user input
[N+2..]  assistant/tool    this turn's exchanges
```

- `[0]` is rebuilt every turn by `PromptBuilder::build_system_prompt`.
  Content is cache-stable: only the inputs (base prompt, loaded skills,
  user profile, plugin instructions, topology) change it.
- `[1..N]` is the projection produced by
  `ContextBuilder::build_projection`. It is role-based messages, not
  prose: the model sees tool_call/tool_result pairs in native wire
  format.
- `[N+1]` is one user message. The dynamic user context (active todos,
  compressed tail, context files, working directory, date, language) is
  prepended to the current input, not pushed as a separate system
  message. A mid-array system message breaks tool calling on
  OpenAI-compatible providers and breaks llama.cpp's Jinja templates
  outright.
- `[N+2..]` grows within the turn as tools run.

The last message is always the current user request, which is what the
provider treats as the active turn. Both trim paths preserve that.

### What is not sent

Session history keeps fields for display and audit that must not reach
the wire. The payload builder clones every message and removes:

| Field | Why it is dropped |
|-------|-------------------|
| `reasoning_content` | The model's private thinking for a call that already happened. DeepSeek documents that it is rejected on input, and every provider bills it as prompt tokens. |
| tool_call bookkeeping (`_emitted_name`, `_parsed_args`, `_name_complete`, `_dispatch_name`, `_mangled_key`) | CLIO internals. `@INTERNAL_TOOL_CALL_KEYS` is the single list; the clone loop in `_build_payload` is the choke point. |
| `metadata`, `pre_action_description`, `action_description`, `expanded_content`, `suppressed_display` | Session and UI bookkeeping. |

`reasoning_details` is deliberately preserved: for Anthropic and Google
models reached through an OpenAI-compatible gateway it also carries the
signed reasoning blocks that tool-call continuity depends on.

---

## 2. The budget

One function computes the budget: `TokenEstimator::compute_prompt_budget`.

```text
prompt_budget = context_window
              - output_reserve
              - estimation_buffer

output_reserve  = min(model max_output_tokens, 131072)
estimation_buffer = min(8192 + 5% of context_window, 51200)
```

The output reserve uses the model's real output cap, clamped. A reserve
that fills the window is treated as missing (some providers publish their
context length in the output field); it falls back to
`min(16384, context_window / 2)`.

Then:

```text
tool_tokens     = sum over tool definitions of (json length / chars-per-token)
effective_limit = max(prompt_budget - tool_tokens, 1000)
trim_target     = effective_limit * 0.75   (CONTEXT_TRIM_TARGET)
```

Worked example, `deepseek/deepseek-v4.1-flash-1017` (1M context, 384k
reported output cap, clamped to 131072):

```text
context_window    1,048,576
output reserve      131,072
estimation buffer    51,200
prompt budget       866,304
tool schema         ~19,000  (52 callables)
effective limit    ~847,000
trim target        ~635,000
```

Nothing trims below 635k on that model. Any claim that CLIO "trims at
300k" on a 1M model is a measurement error, not a budget.

### Capability resolution

The context window comes from `ModelCapabilitiesManager::get_capabilities`:

1. provider-specific fetcher (Anthropic, Google, DeepSeek, NVIDIA,
   MiniMax, Z.A.I, GitHub Copilot)
2. OpenAI-compatible `/v1/models` (OpenRouter, OpenAI, Vercel, KiloCode,
   OrcaRouter, Ollama Cloud)
3. static JSON database (`core/model-data/models.json`)
4. heuristic patterns (`core/model-data/heuristics.json`)

For OpenAI-compatible listings, `context_length` and `context_window` are
read as the window; `max_tokens` is not. In a model listing `max_tokens`
is an output cap, and reading it as a window made 1M-context models look
like 8K models.

User overrides (`cap_context_window`, `cap_max_output`, `cap_max_prompt`)
cap the reported values; they never raise them.

---

## 3. What gets selected: the projection

`ContextBuilder::build_projection` decides which turns go into `[1..N]`
and what the rest are compressed into.

### Selection is budget-driven

```text
available = prompt_budget - reserved
            reserved = system prompt tokens + tool schema tokens
fill      = 0.70 * available     (RECENT_FILL_FRACTION)
low       = 0.55 * available     (RECENT_LOW_FRACTION)
min turns = 2                    (RECENT_MIN_TURNS)
```

- If every turn fits within `fill`, keep every turn.
- Otherwise drop from the oldest end until the total is below `low`.
- The last `min turns` always survive, whatever they cost.
- With no usable budget (< 200 tokens available), keep every turn and let
  the proactive validator enforce the limit.

The gap between `fill` and `low` is headroom. Filling to the threshold
that triggers a drop would make the next turn cross it again, and every
request would re-prefill the array. At 1M this is roughly 125k tokens of
headroom after a drop.

Selection is not a turn count. A turn is delimited by a user message, and
in an agentic session one turn can be hundreds of tool calls. Counting
turns either keeps far more than the budget allows or discards hundreds
of thousands of tokens while the window is mostly empty. Both happened in
practice; see section 7.

### Incomplete turns

Turns with no assistant or tool response are excluded from the recent
window: the last one is the current turn (delivered separately), earlier
ones are orphan messages from interrupted sessions and go to the
compressed set. This prevents consecutive user messages, which strict
providers reject.

### Repeated tool calls

Two collapses remove duplicates, and both leave a marker so the model can
see that the call repeated:

- **Cross-turn**: identical tool + args + result in adjacent turns where
  the later user message is a short continuation ("continue", "ok").
- **Within turn**: a run of identical exchanges inside one turn (the shape
  a tool loop produces). The last exchange is kept; the run length is
  recorded.

Rendered marker:

```text
[repeated call: this exact call ran 12 times in succession. The result
shown is from the last run; all 12 runs took effect.]
```

---

## 4. What gets compressed: the tail

Turns dropped by the projection are compressed by YaRN into one
`<thread_summary>` block, which is prepended to the current user message.

The tail cap scales with what it replaces:

```text
cap_tokens = max(0.5% of context_window, 10% of dropped estimate)
cap_tokens = min(cap_tokens, 4% of prompt_budget)
cap_chars  = cap_tokens * chars_per_token
```

A fixed cap regardless of volume is what made a 130k-token archive
compress into a 5k-token note while most of the budget was unused. Ten
percent is a deliberate trade: the tail is regenerated per turn and sits
in the last message, so it does not invalidate the cached prefix, but it
is still prompt tokens on every request.

YaRN's own summary cap for the trim paths (session and recovery) is 2.5%
of the context window, bounded to 4,000..60,000 characters.

The summary is deterministic: identical dropped turns and task produce
byte-identical output. The projection caches it by signature (including
the cap) so it is not regenerated on every iteration.

---

## 5. What gets trimmed: the validator

`MessageValidator::validate_and_truncate` runs before every API call.

```text
estimate = sum over messages of message tokens (content, tool_calls,
           reasoning, per-message overhead)
if estimate <= effective_limit: return (no trim)
otherwise: _role_based_tail_walk to trim_target
```

The walk:

1. Pins the system prompt, the first user message, every message
   containing `<thread_summary>`, and the last user message.
2. Walks newest to oldest, keeping whole tool_call/tool_result batches.
   If a batch does not fit, the whole batch is dropped so the model never
   sees a tool call without its result.
3. Stops at `trim_target`, not at the limit.
4. Compresses dropped messages into a `<thread_summary>` and folds it into
   the last user message. At most one thread summary exists in the array:
   the new one supersedes the old, whose state is carried through
   `previous_summary`.
5. Filters continuation-only user prompts that survived the walk.

Post-trim verification re-estimates the result and logs a warning if the
pinned set alone exceeds the limit. That case is not silently handed to
the provider.

### Reactive trim

If the provider still rejects the request for length,
`ErrorHandler::trim_for_token_limit` runs a three-tier trim (fit the
budget; keep the last 25%; keep the last two messages plus the current
input), each tier compressing what it drops. When the provider's error
names its real input limit, the retry budget is capped to that number.

---

## 6. Measurement

Every request records one entry in `state->{context_stats}` (bounded to
40 entries). The entry is built from the code that made the decisions, not
from a parallel estimate:

| Field | Source |
|-------|--------|
| `budget` | `MessageValidator::validate_and_truncate`, filled through `context_plan` |
| `budget.breakdown` | `TokenEstimator::estimate_messages_breakdown` on the array that will be serialized |
| `budget.payload_chars` | length of the encoded request body |
| `projection` | `ContextBuilder::build_projection` stats: turns kept and archived, tail size |
| `pre_api_trim` | the orchestrator's pre-call trim, when it fired |
| `usage_*` | the provider's reported prompt, completion, and cached tokens |

Three ways to read it:

```bash
# Live view of the last request's budget and composition
/context

# Per-request table from a session file
tools/context_trace.pl ~/.clio/projects/<uuid>/sessions/<id>.json

# Full dump of one trim decision
CLIO_TRIM_DIAG=1 ./clio --new
```

### Provider token counts are not all the same

`usage.prompt_tokens` in the response is the provider's own count of the
prompt. OpenRouter's generation endpoint additionally reports a normalized
`tokens_prompt` and a `native_tokens_prompt`; the native figure includes
provider cache accounting and moves independently of the actual prompt
size. Do not compare the two and conclude that context was trimmed.

Calibration: 1,125 characters of prose bill 281 prompt tokens (4.0
chars/token); a cold 135,491-character payload bills 41,999 tokens plus
about 4,200 for the tool schema.

The chars/token ratio is learned from real usage after each request. The
validator defaults to the estimator's ratio when no learned value exists,
so it never falls back to an optimistic constant.

---

## 7. How the design got here

| Date | Change | Effect |
|------|--------|--------|
| 2026-06-09 | Last simple state: unit-grouping trim, 50% post-trim target, standalone YaRN summaries | Coherent, if lossy |
| 2026-08-03 | Cross-cycle carryover, post-trim target widened to ~85%, framework narration in trim notices | Trims accumulate faster; model told about the framework |
| 2026-08-31 | Regex carryover fixes | Structural issues remain |
| 2026-09-04 | Role-based history pipeline: projection, `_role_based_tail_walk`, no compression in the proactive path | Proactive trim lost compression |
| 2026-10-17 | Fold thread_summary into the user message for all providers | Cache-stable prefix preserved across trims |
| 2026-11-04 | Collapse repeated tool exchanges | Long tool loops stop re-feeding 40 copies of the same call |
| 2026-11-06/11 | Clamp output reserves; treat a reserve that fills the window as missing | 1M models stopped reserving half their window for output |
| 2026-11-15 | Trim to a target (0.75) instead of to the limit | Trims stopped firing every few turns |
| 2026-11-15 | Strip tool_call bookkeeping from every payload | `_emitted_name` and friends no longer sent |
| 2026-11-15 | Budget-driven recent window; tail scales with volume; reasoning_content not echoed; `max_tokens` no longer read as a context window; validator ratio default fixed | See below |

### Defects found in this audit

Measured against real payloads captured from OpenRouter for sessions
`c9fbb04b` and `51b83880`.

1. **The recent window was a turn count (3/5/8/10), blind to token size.**
   On a 19-turn session, a new user message dropped 269 messages
   (452,395 characters, about 130k tokens) into a 9,885-character summary
   while roughly 700k tokens of budget were unused: 98% loss, performed
   for no reason. The same rule let a 4-turn session grow to 297k tokens
   inside "one turn" with nothing bounding it.
   Fixed: selection fills 70% of the available budget and drops to 55%,
   with a 2-turn floor.

2. **The compressed tail was capped at 0.5% of the window regardless of
   what it replaced.** A 130k-token archive became a 5k-token note.
   Fixed: max(0.5% of window, 10% of dropped), capped at 4% of the prompt
   budget.

3. **`reasoning_content` was echoed back within a turn.** History loaded
   from disk was stripped, but messages added during the current turn
   were not. One measured request carried 365,730 characters of stale
   thinking across 188 assistant messages, about 120k tokens.
   Fixed: the payload builder drops it for every assistant message.

4. **`max_tokens` from a model listing was read as a context window.**
   For OpenAI-style listings that field is an output cap, so a 1M model
   could resolve to an 8K window. Fixed.

5. **The validator defaulted the chars/token ratio to 2.5** while the
   estimator's documented default is 4.0. On the first request of every
   session the prompt was under-estimated by about 30%, the unsafe
   direction. Fixed: the validator defaults to the estimator's ratio.

6. **`token_estimate` in the projection was always 3.** The turn arrayrefs
   were pushed into the message list without flattening, and the estimator
   skips non-hash entries. Cosmetic until the stats needed it; fixed.

7. **Tool schema tokens were computed twice** (validator and any caller
   that needed the number) with the same formula. Now one function,
   `TokenEstimator::estimate_tools_tokens`.

Reported symptom that was not a defect: "trims at 300k on a 1M model".
The billing log records the provider's native prompt count, which includes
cache accounting; the actual prompts peaked near 245k tokens in one
session and 161k in another, and the drop at 19:12 was a cache artifact,
not a trim.

---

## 8. Known gaps

1. **Dead trim paths.** `ConversationManager::trim_conversation_for_api`
   and `trim_with_noise_dropping` have no production callers; the only
   budget authority is `MessageValidator`. `SAFE_CONTEXT_PERCENT` is
   defined and referenced only in comments. Removing them is safe but is
   an API change, so it is proposed rather than done.
2. **`reasoning_details` policy.** Preserved for signed-block continuity.
   For models that do not require signatures it is pure weight. A
   per-provider decision table would recover the tokens without risking
   tool continuity.
3. **Per-endpoint context limits.** OpenRouter routes a model to providers
   with different real limits. The listing's `top_provider.context_length`
   is used, but the router can pick a stricter endpoint. The reactive trim
   handles the resulting 400; a predictive cap would avoid it.
4. **Cache stability across projection drops.** A drop re-prefills
   everything after the drop point. The fill/low gap amortizes this, but
   the payload has no marker telling the provider which prefix survived.
5. **The skills `trim-pipeline-analysis` and `metadata-leak-detection`
   still describe the old five-path model and the turn-count window.**
   They are read-only to the agent; update or retire them.

---

## 9. Invariants

A change to any of this must keep these true:

1. Exactly one array is serialized, and the last message is the current
   user request.
2. One budget authority: `compute_prompt_budget`, one trim authority:
   `validate_and_truncate`. Nothing else decides what fits.
3. The validator never hands the provider a request it knows is over
   budget without logging it.
4. Tool calls and tool results are never separated.
5. Only one `<thread_summary>` exists in the array.
6. Nothing framework-internal is labeled in model-facing content.
7. Any context loss is recorded: what was dropped, how big it was, and how
   big its replacement is.
8. `context_stats` reflects the code's decisions, not a parallel estimate.
