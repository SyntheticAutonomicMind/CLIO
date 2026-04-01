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

```
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

CLIO manages the AI context window automatically with a two-tier trimming system:

### Proactive Trimming

The `MessageValidator` trims messages before each API call using a token-budget walk. It walks backward from the newest message, keeping messages until the budget is exhausted. This runs every iteration after the first.

- **Safe context threshold:** 75% of the model's max context (`SAFE_CONTEXT_PERCENT = 0.75`)
- **Strategy:** Budget walk from newest, preserves most recent user message
- **Thread summary:** Compressed summary of dropped messages injected as context

### Reactive Trimming

If an API call returns `token_limit_exceeded` despite proactive trimming:

1. **Escalation 1:** Keep messages fitting 50% of max prompt tokens
2. **Escalation 2:** Aggressive trim with compressed recovery context
3. **Escalation 3:** Emergency reset to system prompt + last user message

Each escalation injects a thread summary and recovery context (git state, todo state) so the agent can continue seamlessly.

### Key Design Decisions

- The **most recent** user message is always preserved (not the first)
- Thread summaries extract file paths, git commits, and collaboration decisions
- Recovery injection includes git recent commits and working tree status
- The agent is instructed to continue seamlessly without announcing recovery

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
   - Activity-based idle timeout (default 60s) prevents hangs
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
