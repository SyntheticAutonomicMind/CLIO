# CLIO Prompt Pipeline Protocol

**Version:** 1.0
**Date:** 2026-08-18
**Status:** Implemented

The Prompt Pipeline Protocol defines the byte-exact layout of every API
request CLIO sends. The goal is cache stability — keep the LCP (Longest
Common Prefix) as long as possible across turns so providers like
llama.cpp, Anthropic, and OpenAI can reuse their KV cache instead of
reprocessing the full prompt every turn.

---------------------------------------------------

## Canonical Layout

Every API request is an ordered array of six distinct **sections**.
Position is significant. Sections at the same position use the same
cache lifetime; sections at different positions have independent cache
lifetimes.

```
[0] system_prompt      Static (built once per session; includes tools schema)
[1] context_files      User-added files (stable until /context add|remove)
[2] dialog             user / assistant alternating, tool_results interleaved
[3] summary            CSSS slot; grows organically up to MAX_CSSR_SLOT_TOKENS, at END
[4] user_context       Dynamic (date/time, working dir, LTM, session goals)
[5] user_input         Current turn's raw user input (no prefix)
```

Sections [0] through [1] are the **stable anchor** — changes here
invalidate everything from that section onwards. Section [4] is the
**dynamic anchor** — changes here invalidate [4] onwards but [0..3]
stay cached. Section [5] is always fresh and invalidates only itself.

The positions are not literal message-array indices — the dialog at [2]
can be empty (turn 1, no history), or many messages. What matters is
**section ordering** and **relative position of dynamic content**.

Key design decision: with unit-based trim (no deinterleave),
tool_calls and their tool_results stay together in their natural
interleaved order throughout the pipeline. This means:
- No deinterleave/reinterleave cycle on trim (the old pipeline protocol
  tried separating tool_results to the END and reinterleaving them back,
  which caused structural reordering that broke LCP cache stability).
- The LCP prefix extends through sys + context_files + dialog + tools
  because byte positions only change when units are actually dropped,
  not when they are shuffled.
- The summary at END (position [3]) means the LCP break is at a
  well-defined boundary — after all live context, before the static
  summary. The summary grows organically up to a MAX_CSSR_SLOT_TOKENS
  ceiling; when it grows, only the summary position onward is
  invalidated.

---------------------------------------------------

## Section Lifecycle

| [0] system_prompt | Session start | Tools change | Session |
| [1] context_files | After user /context | User adds/removes file | Until change |
| [2] dialog | After history load | Trim drops oldest | Newest-only |
| [3] summary | After trim | Drop oldest, grow up to ceiling | CSSS ceiling (MAX)
| [4] user_context | Every turn | Date ticks, LTM changes | ~1 minute |
| [5] user_input | Every turn | Always | One turn |

`built when` and `recomputed when` describe when the orchestrator
generates or regenerates the section's content. `Cache lifetime`
describes the time window during which the section's bytes are stable.

The pipeline layout makes each section independently cacheable. When a
section's bytes change, only that section and everything after it
needs to be reprocessed by the model.

---------------------------------------------------

## Message Roles

All sections are encoded as messages in the OpenAI Chat Completions
`messages` array. Role assignments:

| Section | Role |
|---------|------|
| [0] system_prompt | `system` |
| [1] context_files | `system` (wraps `[CONTEXT FILES]...`) |
| [2] dialog | alternating `user` / `assistant`, plus `tool` for results |
| [3] summary | `system` (wraps `<thread_summary>...</thread_summary>`) |
| [4] user_context | `system` (wraps `<userContext>` / `<dynamicContext>` / `<sessionGoals>`) |
| [5] user_input | `user` |

All four `system` sections ([0], [1], [2], [5]) must remain **separate
messages** — not merged into one. `enforce_message_alternation`
excludes `system` from its merge rule precisely to preserve these
section boundaries. Merging would couple their caches: any section's
regeneration would invalidate the whole merged system prompt.

Providers that concatenate system messages (Anthropic's
`_separate_system_prompt`, for example) do so at the wire-format layer.
Internal layout keeps them separate.

---------------------------------------------------

## Trim Policy

Trim policy walks the message array and drops content to fit the
context budget. Each section has a fixed trim priority:

- **[0] system_prompt** — NEVER trimmed. The LCP anchor.
- **[1] context_files** — NEVER trimmed. Stable until /context change.
- **[2] dialog** — Primary trim target. Walk from newest, drop
  oldest units when budget exceeded. Tool call/result pairs are always
  kept together (never split) — each assistant+tool_call_result unit is
  either fully retained or fully dropped. This preserves the natural
  interleaved ordering so the LCP cache stays stable.
- **[3] summary** — NEVER trimmed. CSSS slot, bounded by MAX_CSSR_SLOT_TOKENS ceiling (grows organically, no padding).
- **[4] user_context** — NEVER trimmed. It's small and dynamic; not
  a budget concern. The validator preserves user_context system messages
  at any position (msg[1], msg[N-2], etc.) so the chat template's
  `<system>...</system>` block stays in the prefix region across trims.
  Dropping it would change the rendered prompt's leading tokens and
  break llama.cpp's LCP cache (the CachyLLama full re-prompt bug observed
  2026-08-18, where a 5-minute per-task reprocess loop was traced back
  to the validator silently dropping user_context at msg[1]).
- **[5] user_input** — NEVER trimmed. Active request.

`trim_conversation_for_api` (ConversationManager.pm) and
`validate_and_truncate` (API/MessageValidator.pm) implement this
policy. The proactive trim in MessageValidator also generates a new
`<thread_summary>` message when content is dropped — that becomes the
new section [1].

CSSS (Cache-Stable Summary Slot) bounds the summary token budget
across trims. The summary is placed at the END of the conversation so
that LCP cache invalidation from a size change only hits the summary
position onward - the preserved dialog prefix stays cached.

The summary grows organically with dropped content up to
`MAX_CSSR_SLOT_TOKENS` (12000). When dropped content exceeds 1.5x
the current slot, the slot grows before compression to absorb the
dropped tokens without hard-truncating captured state. Earlier
versions padded undersized summaries with an
`<!-- csss:padding:xxxxx -->` block of x's to lock the byte size;
this was removed (2026-08-27) because the padding was visible to the
model as a massive artifact.

Slot bounds:

- `MAX_CSSR_SLOT_TOKENS` (12000) - hard ceiling on summary size
- `MIN_CSSR_SLOT_TOKENS` (8192) - resume fast-path gate
- `DEFAULT_POST_TRIM_FLOOR` (24000) - minimum tokens kept verbatim

Proactive growth: if a single trim drops more than 1.5x the current
slot, the slot grows before compression to absorb the dropped tokens
without hard-truncating captured state.

---------------------------------------------------

## Snapshot Semantics

The orchestrator snapshots the conversation state at **end of turn**
so the resume fast path produces byte-identical output to a fresh
rebuild. The snapshot contract:

> **The snapshot must equal what `load_conversation_history` would
> return after rebuilding from session history.**

This guarantees the resume fast path (`_try_resume_from_payload`) and
the rebuild path produce identical prompts, keeping the LCP cache hit.

### Capture Point

`_capture_api_payload` runs at **two exit points** of `process_input`:

1. **Success path** — after the final assistant text is saved to
   session history and all tool_results are merged into `@messages`.
2. **Iteration-limit exit** — if `max_iterations` is reached but
   progress was made during the turn.

The error path does NOT capture (we want to retry from the state
before the error, not the partial state after).

### What Goes In The Snapshot

The snapshot includes all messages that were in `@messages` at end of
turn (after stripping ephemeral continuation nudges and orphan tool_calls
in `_capture_api_payload`). For a turn that ran tools and produced a
final assistant response, that means the snapshot includes:

- [0] system_prompt
- [1] context_files (if any)
- [2] dialog (with tool_results naturally interleaved, final assistant
  response appended)
- [3] summary (if any, placed at END by the trim)
- [4] user_context
- [5] user_input

The snapshot is a faithful copy — with unit-based trim (no deinterleave),
there is no structural reordering to undo. Continuation nudges are
stripped (not persisted to session history), and orphan tool_calls are
stripped (API safety), but tool_calls/results that are properly paired
stay in their natural interleaved order.

### Resume Fast Path

`_try_resume_from_payload` returns the snapshot verbatim when:

1. Provider matches current provider
2. Tools signature matches current tools
3. Context window is large enough (or trims if smaller)

If the snapshot is valid, the fast path:

1. Replaces stale `user_context` in-place (the snapshot always has
   exactly one user_context at the [-2] position, which is replaced
   with fresh content)
2. Appends fresh `user_input` (current turn's raw input)
3. Returns the resulting message array

This keeps [0..3] (the stable anchor + dialog) byte-identical across
resume turns — the LCP match survives the resume. The only change is
the user_context content at [-2] (dynamic, expected to change every
minute) and the new user_input at [-1] (fresh).

If the snapshot exceeds the current model's budget, `validate_and_truncate`
runs with the same drift-aware threshold as the proactive trim, so the
fast path and rebuild path produce identical output when the snapshot is
valid and the session history hasn't drifted.

1. Loads session history via `load_conversation_history`
2. Pre-flight trims via `trim_conversation_for_api` (using same drift-aware
   threshold as the proactive trim)
3. Pushes section [4] (fresh user_context)
4. Pushes section [5] (current user_input)

The two paths converge to the same prompt when the snapshot is valid
and the session history hasn't drifted.

---------------------------------------------------

## Provider Wire Formats

Different providers handle the message array differently. The pipeline
protocol preserves the sections in the internal representation; each
provider adapts to its wire format at the boundary. Cache-specific
adaptations (cache_control markers, prompt_stable_prefix_tokens) are
documented in [Provider Cache Adaptations](#provider-cache-adaptations)
below.

### Anthropic (`lib/CLIO/Providers/Anthropic.pm`)

Anthropic's Messages API has a top-level `system` field that is an
array of `{type: "text", text: ...}` blocks. `convert_request` extracts
all `role=system` messages from our array and concatenates them into
the `system` field. Cache control is set on the block entry — see
the Provider Cache Adaptations section.

### OpenAI Chat Completions (`lib/CLIO/Providers/Base.pm` and per-provider subclasses)

OpenAI's `messages` array accepts multiple `role=system` messages.
CLIO sends them as separate messages. Providers that support
`cache_control` get a marker placed on the last leading system
message in `APIManager::_build_payload`.

### llama.cpp (`lib/CLIO/Providers/SAM.pm`, llama.cpp, LM Studio)

llama.cpp's `prompt_stable_prefix_tokens` field tells the server how
many leading tokens form a stable prefix. CLIO computes this as the
sum of leading system message tokens (typically the [0..2] stable
anchor). Set in `APIManager::_build_payload` for `llama_user_id_supported`
providers.

### OpenAI Responses API

OpenAI Responses supports `prompt_cache_key` for explicit cache keys.
The pipeline protocol uses `(session_id, model, tools_signature)` as
the cache key.

### Google Gemini

Gemini uses `cachedContent` for prompt caching. Future enhancement:
per-section cache references using the same pipeline protocol
abstractions.

---------------------------------------------------

## Backwards Compatibility

Older CLIO sessions (and older snapshots) may have:

- user_context prepended to user_input (single user message with the
  full dynamic block as prefix)
- context_files as `role=user` instead of `role=system`
- last_api_payload captured before tool execution (missing tool_results)

The resume fast path handles these gracefully:

- **Old user_context in user_input**: the trailing user_input message
  has `<userContext>` tag in its content. The strip-and-replace logic
  detects this via content pattern (`<(?:userContext|dynamicContext|sessionGoals)>`)
  and pops it as if it were a separate user_context message.

- **Old context_files as role=user**: the resume path preserves them
  as-is (the content is still valid; the role doesn't break anything).

- **Old snapshot missing tool_results**: the snapshot will have fewer
  messages than session history, but the rebuild path produces the
  same prompt. If the snapshot doesn't have the tool_results the
  current session has, the resume returns a "stale" payload — but
  that's only a problem when the user resumes a session mid-tool-flow,
  which is rare.

New sessions automatically use the new layout. No migration script is
required — the resume fast path handles both old and new formats.

---------------------------------------------------

## Cache Invalidation: Worked Example

Imagine three turns of a session, with the user asking the model to
read a file (tool call) and explain what it contains:

```
TURN 1 N (just before user message N arrives)
[0] system_prompt          (token positions 0..8000)
[1] context_files          (positions 8000..12000)
[2] dialog (old turns)     (positions 12000..50000)
[3] summary                (positions 50000..54000)  <- CSSS slot (stable)
[4] user_context_N         (positions 50000..50100)  <- dynamic
[5] user_input_N           (positions 50100..50200)  <- fresh
```
LCP match from TURN N-1: [0..50100] all identical. Cache hit through
`50100`. Tokens 50100+ reprocessed (the user_input).

```
TURN N+1 (1 minute later — date/time changed)
[0] system_prompt          (positions 0..8000)
[1] context_files          (positions 8000..12000)
[2] dialog (one more turn) (positions 12000..50500)  <- grew
[3] summary                (positions 50500..54500)  <- CSSS (stable)
[4] user_context_N+1       (positions 50500..50600)  <- changed
[5] user_input_N+1         (positions 50600..50700)  <- fresh
```
LCP match from TURN N: [0..50500] identical (system, context_files,
dialog up to before summary, summary). Cache hit through `50500`.
Tokens 50500+ reprocessed (user_context changed, plus new user_input).

That's 50500 / 50700 = 99.6% cache hit. Only 200 tokens (user_context
+ user_input) are reprocessed. llama.cpp at ~400 tok/s spends 0.5
seconds on the new content instead of 127 seconds on the full prompt.

Without the pipeline protocol, user_context was prepended to every
user message, so changing the date invalidated EVERY user message in
the dialog. LCP would break at the most recent user message deep in
the conversation, and the cache hit would be much smaller.

---------------------------------------------------

## Testing

The pipeline protocol is covered by:

- `tests/unit/test_cache_stable_layout.pl` — validates that trim
  produces the cache-stable message ordering.
- `tests/unit/test_cache_stable_summary.pl` — CSSS slot behavior + no-padding assertion.
- `tests/unit/test_session_cached_payload.pl` — snapshot roundtrip
  and the resume fast path's strip-and-replace logic.
- `tests/unit/test_conversation_manager_multimodal.pl` — system
  messages stay separate (don't merge) per pipeline protocol.
- `tests/unit/test_conversation_manager.pl` — context_files injected
  as role=system.
- `tests/integration/test_session_resume_cached_payload.pl` — end-to-end
  resume flow with a real provider.

- `tests/unit/test_user_context_anchor.pl` — regression test for the
  user_context-at-any-position trim fix (preserves the chat template
  `<system>` block in the prefix region across trims).
- `tests/unit/test_strip_non_trailing_user_context.pl` — verifies
  `_strip_non_trailing_user_context` only removes duplicates.

Adding new tests: any change to message ordering, role assignment, or
trim policy must update these tests (and may need new subtests).

---------------------------------------------------

## Snapshot Section Signatures

Each captured snapshot includes a `section_signatures` field in
`last_api_metadata`: a hashref mapping each pipeline section to its
SHA256 digest. Sections that don't exist in the snapshot (e.g. no
summary yet, no context files) are omitted.

```perl
$state->last_api_metadata->{section_signatures} = {
    system_prompt => 'sha256...',
    summary       => 'sha256...',
    context_files => 'sha256...',
    dialog        => 'sha256...',
    tool_results  => 'sha256...',
    user_context  => 'sha256...',
    user_input    => 'sha256...',
};
```

`WorkflowOrchestrator::_compute_section_signatures` walks the messages
array and classifies each message into a section by content patterns:

- **system_prompt**: position 0, role=system, no tag
- **summary**: role=system, content has `<thread_summary>` tag
- **context_files**: role=system, content has `[CONTEXT FILES]` tag
- **dialog**: alternating user/assistant messages
- **tool_results**: role=tool messages (with `tool_call_id`)
- **user_context**: role=system, content has `<userContext>` /
  `<dynamicContext>` / `<sessionGoals>` tag
- **user_input**: the LAST role=user message

Computed by `CLIO::Core::WorkflowOrchestrator::_compute_section_signatures`
and stored by `_capture_api_payload`. Accessed via
`CLIO::Session::State::section_signatures`.

### Use Case

Future consumers can compare signatures between turns to detect per-
section drift:

```perl
my $stored = $state->section_signatures;
# ... after rebuild ...
if (($stored->{system_prompt} // '') ne ($current->{system_prompt} // '')) {
    # Tools changed - need fresh system prompt
}
```

Today the resume fast path uses only the full payload hash; signatures
are defensive metadata for selective rebuild (a future optimization).

---------------------------------------------------

## Provider Cache Adaptations

Different providers support different prompt caching mechanisms. The
pipeline protocol's stable anchor [0..1] (system_prompt + context_files)
is the natural cache region across all of them. The CSSS summary at
position [3] (END of dialog) is outside the leading stable prefix, so
CSSS regeneration only invalidates the summary slot tokens — not the
stable anchor.

### OpenAI Chat Completions (`cache_control` marker)

Providers that support OpenAI prompt caching receive a `cache_control`
marker on the FIRST leading system message (the system prompt itself).
This anchors the cache to [0] so the system prompt stays cached across
turns even when context_files or user_context are regenerated.
Anchoring on the LAST system message would invalidate the cache on
every context_files or user_context change, since those are volatile
sections in the pipeline layout.

Providers marked `supports_cache_control => 1` in `lib/CLIO/Providers.pm`:

- `openai` (gpt-4o, gpt-4o-mini, o1, o3, o4-mini)
- `openrouter` (passthrough to upstream)
- `github_copilot` (passthrough to underlying Claude/GPT)
- `nvidia` (NIM OpenAI-compat endpoint)

Marker placement is in `APIManager::_build_payload`. The marker is added
to the message in-place before JSON encoding.

### Anthropic (concatenated `system[]` block)

Anthropic's Messages API takes system instructions as a top-level
`system` field, not as messages. `Anthropic::build_request` extracts
all `role=system` messages from the array, concatenates them into one
`system[]` block, and sets `cache_control: {type: 'ephemeral'}` on the
entry. Per-section cache_control within the system block is a future
enhancement.

### llama.cpp (`prompt_stable_prefix_tokens`)

For local inference servers (llama.cpp, LM Studio, SAM), the cache
matching is done server-side via `prompt_stable_prefix_tokens`.
`APIManager::_build_payload` computes this as the sum of leading
system message tokens (system_prompt + context_files, excluding
user_context) and includes it in the payload. The server uses this
to reject any slot whose stored prompt doesn't share the leading
prefix — a match check that survives trimming.

Providers marked `llama_user_id_supported => 1` in `lib/CLIO/Providers.pm`:

- `sam`, `llama_cpp`, `lm_studio`, `nvidia` (in some configurations)

### Google Gemini

Gemini uses `cachedContent` for prompt caching. Future enhancement:
per-section `cachedContent` references. The pipeline protocol's
section structure maps cleanly to this when implemented.

### Cache Stability Impact

| Provider | Cache region | Mechanism |
|----------|--------------|-----------|
| OpenAI Chat Completions | [0..N] system messages | `cache_control` marker on first leading system |
| Anthropic | Whole `system[]` block | `cache_control: ephemeral` on the block entry |
| llama.cpp | [0..M] tokens (M = leading system tokens) | `prompt_stable_prefix_tokens` field |
| Google Gemini | (future) per-section `cachedContent` | TBD |

The pipeline protocol's stable anchor layout means all four cache
strategies anchor to the same byte region: [0..1] in pipeline order,
which is the system_prompt + context_files messages.

---------------------------------------------------

## Future Work

- **Per-section partial rebuild**: `section_signatures` enables
  detecting which sections drifted between turns. The resume fast path
  could selectively rebuild only the drifted sections (vs. the
  current all-or-nothing fallback).
- **Per-section Anthropic cache_control**: place cache_control on each
  system message within the concatenated `system[]` block, so each
  section gets its own cache lifetime.
- **Google Gemini cachedContent**: per-section cache references using
  the same section abstractions.
- **Section [2] dedup**: when multiple context files have the same
  path, deduplicate before injection.

---------------------------------------------------

## File Map

The pipeline protocol is implemented across:

| File | Role |
|------|------|
| `lib/CLIO/Core/ConversationManager.pm` | `load_conversation_history`, `trim_conversation_for_api`, `enforce_message_alternation`, `inject_context_files` |
| `lib/CLIO/Core/API/MessageValidator.pm` | `validate_and_truncate` (proactive + reactive trim, CSSS slot ceiling) |
| `lib/CLIO/Core/WorkflowOrchestrator.pm` | `_build_turn_context` (assembles all sections), `_capture_api_payload` (snapshot), `_try_resume_from_payload` (resume fast path) |
| `lib/CLIO/Core/PromptBuilder.pm` | `build_system_prompt` (section [0]), `get_user_context` (section [5]) |
| `lib/CLIO/Session/State.pm` | `set_last_api_payload` / `last_api_payload` / `last_api_metadata` (snapshot storage) |
| `lib/CLIO/Providers/Anthropic.pm` | `_separate_system_prompt` (Anthropic adaptation) |
| `lib/CLIO/Providers/Base.pm` | `convert_messages` (per-provider message format) |