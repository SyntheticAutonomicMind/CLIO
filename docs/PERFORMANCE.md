# Performance

This document describes CLIO's performance characteristics and optimization strategies.

## Quick Summary

| Metric | Typical Value | Notes |
|--------|---------------|-------|
| Module load time | 70-100ms | 143 modules, lazy loading where possible |
| Tool execution (file ops) | 0.3-1ms | File I/O dominates |
| Session save | 1-2ms | Atomic write pattern |
| Session load | 20-25ms | Scales with history size |
| Baseline RSS | 50-80MB | Varies by platform |

## Running Benchmarks

```bash
# Basic benchmark
perl tests/benchmark.pl

# With more iterations for accuracy
perl tests/benchmark.pl --iterations 100

# Verbose output
perl tests/benchmark.pl --verbose
```

## Runtime Performance Monitoring

CLIO includes built-in performance monitoring via the `/stats` command:

```text
/stats
```

This displays:
- **RSS memory** - Current and baseline process memory (MB)
- **TTFT** - Time to first token (API response latency)
- **TPS** - Tokens per second (streaming throughput)
- **Token usage** - Input/output/total for the current session
- **Session duration** - Wall clock time

Use `/stats` periodically during long sessions to monitor resource consumption.

## JSON Performance

CLIO uses `CLIO::Util::JSON` for all JSON operations. This module automatically selects the fastest available encoder:

1. **JSON::XS** - C-based, ~10x faster than pure Perl (preferred)
2. **Cpanel::JSON::XS** - Alternative C-based encoder
3. **JSON::PP** - Pure Perl fallback (always available in Perl 5.14+)

No CPAN installation is required. CLIO detects what's available at runtime. For best performance, install JSON::XS:

```bash
cpan JSON::XS
```

## Caching

CLIO caches computed results that don't change during a session:

- **ANSI codes** - Terminal escape sequences (`_codes_cache`)
- **Theme colors** - Color lookup results (`_color_cache`)
- **Tool definitions** - API tool schemas (`_definitions_cache`)
- **Tools prompt** - System prompt tool section (`_tools_section_cache`)
- **Token estimates** - Message token counts (cached after first calculation)

Caches are invalidated when the underlying state changes (e.g., theme switch, tool registration).

## Context Window Management

CLIO manages the AI context window automatically using a **unified drift-aware walk** with the **Cache-Stable Summary Slot (CSSS)** for LCP cache stability.

### Unified Trim Strategy

The `MessageValidator` performs a single budget walk before each API call, using the capability-based prompt budget (`ctx_window - max_output_tokens - estimation_buffer`). The walk proceeds from newest to oldest, preserving messages until the budget is exhausted.

Key parameters:
- **Safe context threshold:** 68% of the model's max context (proactive trim trigger)
- **Post-trim floor:** 24,000 tokens minimum kept verbatim after trim
- **Estimation buffer:** 8,192 + 5% of context (capped at 51,200)

### CSSS (Cache-Stable Summary Slot)

The CSSS bounds the summary size across trim cycles to minimize LCP (Longest Common Prefix) cache invalidation with local inference providers (llama.cpp). Summaries grow organically up to `MAX_CSSR_SLOT_TOKENS` (12K) and are placed at the end of the prompt so only the summary position onward risks cache invalidation on growth.

### Prompt Budget Calculation

The prompt budget is computed per-request using `TokenEstimator::compute_prompt_budget($caps, tools => $tools)`:

```perl
$budget = $context_window - $max_output_tokens - $estimation_buffer
```

Where `estimation_buffer = 8192 + int($context_window * 0.05)` capped at 51200.

**Tool output reserve optimization:** When the model supports tools AND tools are present in the request, the output reserve is capped at `DEFAULT_TOOL_OUTPUT_RESERVE` (8192 tokens) instead of the model's full `max_output_tokens` (often 32K+). Tool-calling responses rarely exceed a few hundred tokens; reserving the full output cap wastes ~24K of prompt budget.

### What Gets Preserved

When trimming is needed, CLIO prioritizes (in order):
1. **System prompt** - NEVER trimmed (stable anchor [0])
2. **Summary (CSSS slot)** - NEVER trimmed (stable anchor [1])
3. **Context files** - Trimmed with dialog budget walk (stable anchor [2])
4. **Most recent user message** - The current task anchor (section [6])
5. **Thread summary** - Compressed record of dropped messages, preserved across trim cycles
6. **Recent messages** - Most recent context, budget-walked newest to oldest
7. **Tool call/result pairs** - Kept together to avoid orphans

The deinterleaved layout puts tool_results at the END specifically so they get dropped before dialog when budget is tight. Tool results are the most expendable - the agent can re-call the tool.

### Context Recovery

When aggressive trimming occurs, CLIO injects recovery context that includes:
- A thread summary of dropped messages (user requests, tool operations, key events)
- The current todo/task state (what the AI was working on)
- Recent git activity (commits, working tree status)

Context recovery is **transparent** - the AI continues working without announcing that trimming occurred. Thread summaries accumulate across trim cycles, building a running record of the full session history.

### Token Estimation

CLIO estimates token counts using a learned character-to-token ratio that calibrates itself against actual API responses over time. The `TokenEstimator` module learns the ratio from `usage` fields in API responses and applies it to future estimates.

### Resume Fast Path

The orchestrator captures the end-of-turn API payload (`last_api_payload`) for instant session resume. On resume:
1. Fresh `user_context` (date/time, working dir) and `user_input` are generated
2. The rest of the payload (sections [0..4]) is reused byte-identically
3. This keeps the LCP cache alive across `--resume` - no reprocessing of the stable anchor

If the saved payload is smaller than `MIN_CSSS_SLOT_TOKENS` (8192) and contains a `thread_summary`, the orchestrator falls back to a full history rebuild instead of reusing the truncated payload. This prevents resuming with an empty or near-empty context after aggressive trim.

## Memory Usage

CLIO's memory footprint depends on:
- Session history length (primary factor)
- Number of active tool results stored
- LTM (Long-Term Memory) database size
- Cached computed values

Typical baseline memory: 50-80MB
With large session (500+ messages): 150-300MB

Tool results over 8KB are stored to disk and referenced by ID, reducing in-memory pressure during API calls.

## Optimization Tips

### For Users

1. **Session size** - Large sessions (>1000 messages) may slow load time
   - Start new sessions for unrelated work (`--new`)
   - Context trimming handles long sessions automatically

2. **Debug mode** - Running with `--debug` increases overhead
   - Default log level is WARNING (minimal overhead)
   - Use `/loglevel debug` temporarily when troubleshooting
   - Use `/loglevel warning` to restore normal performance

3. **Model selection** - Response time varies significantly by model
   - Check TTFT and TPS via `/stats`
   - Smaller models respond faster for simple tasks

### For Developers

1. **Avoid reloading modules** - All modules are loaded once at startup
2. **Use session caching** - Session state is cached in memory
3. **Batch operations** - Use `multi_replace_string` instead of multiple single replaces
4. **Lazy loading** - Optional features load modules on demand
5. **Use Logger API** - `log_debug()` checks level internally, no guard needed

## Bottleneck Areas

Known performance considerations:

1. **API latency** - Network calls dominate total response time
   - CLIO adds <5ms overhead per API call
   - Total latency is 95%+ API provider response time
   - Rate limiting adds backoff delays (exponential, capped at 300s)

2. **Streaming** - True HTTP streaming via chunked transfer
   - First token appears as soon as the provider sends it
   - Rendering overhead is minimal (markdown processed per-chunk)

3. **Terminal operations** - Commands run in forked processes
   - Activity-based idle timeout (default 300s) prevents hangs
   - Process groups ensure clean cleanup on timeout

4. **Context trimming** - Runs every iteration after the first
   - Token estimation is fast (cached, heuristic-based)
   - Budget walk is O(n) over message count
   - Compression uses existing message content (no API call)

## Module Load Analysis

With 143 modules, CLIO starts quickly (~70-100ms):

| Component | Approx. Load Time |
|-----------|-------------------|
| CLIO::Core::APIManager | 26ms |
| CLIO::UI::Chat | 11ms |
| CLIO::Core::Config | 10ms |
| CLIO::Core::ToolExecutor | 7ms |
| CLIO::Core::WorkflowOrchestrator | 6ms |
| Other modules | <3ms each |

Lazy loading is not implemented for core modules because:
1. Total startup time is already excellent
2. Core modules (APIManager, Chat, WorkflowOrchestrator) are always needed
3. Optional features (Architect, MCP, OpenSpec) already load on demand

## Profiling

For detailed profiling, use Perl's built-in profiler:

```bash
# Install Devel::NYTProf (one-time)
cpan Devel::NYTProf

# Run with profiling
perl -d:NYTProf ./clio --input "test" --exit

# Generate report
nytprofhtml

# View report
open nytprof/index.html
```
