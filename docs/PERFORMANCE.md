# Performance Benchmarks

This document describes CLIO's performance characteristics and benchmarking tools.

## Quick Summary

| Metric | Typical Value | Target |
|--------|---------------|--------|
| Module load time | 70-100ms | < 2s |
| Tool execution (file ops) | 0.3-1ms | < 50ms |
| Session save | 1-2ms | < 100ms |
| Session load | 20-25ms | < 200ms |

## Running Benchmarks

```bash
# Basic benchmark
perl tests/benchmark.pl

# With more iterations for accuracy
perl tests/benchmark.pl --iterations 100

# Verbose output
perl tests/benchmark.pl --verbose
```

## Performance Targets

### Module Loading
- **Target:** < 2 seconds
- **Measured:** ~70-100ms on modern hardware
- **Notes:** Lazy loading of optional modules improves startup time

### Tool Execution
- **Target:** < 50ms per tool call
- **Measured:** 0.3-1ms for file operations
- **Notes:** Most time is spent in file I/O, not in CLIO overhead

### Session Management
- **Target:** Save < 100ms, Load < 200ms
- **Measured:** Save ~1ms, Load ~20ms
- **Notes:** Load time scales with session history size

## Optimization Tips

### For Users

1. **Session Size**: Large sessions (>1000 messages) may slow down load time
   - Use `/session trim` to remove old sessions
   - Enable `session_auto_prune` in config

2. **Debug Mode**: Running with `--debug` significantly impacts performance
   - Only use during troubleshooting
   - Debug logging adds 10-20% overhead

3. **Tool Results**: Large tool outputs are automatically chunked
   - Results >8KB are stored and referenced
   - Reduces memory pressure in API calls

### For Developers

1. **Avoid Reloading Modules**: All modules are loaded once at startup
2. **Use Session Caching**: Session state is cached in memory
3. **Batch Operations**: Use `multi_replace_string` instead of multiple single replaces
4. **Lazy Loading**: Optional features load modules on demand

## Memory Usage

CLIO's memory footprint depends on:
- Session history length (primary factor)
- Number of active tool results stored
- LTM (Long-Term Memory) database size

Typical baseline memory: 50-100MB
With large session (500+ messages): 150-300MB

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

## Bottleneck Areas

Known performance considerations:

1. **JSON Encoding/Decoding**: Core module JSON::PP is slower than JSON::XS
   - Optional: Install JSON::XS for 10x faster JSON parsing
   - `cpan JSON::XS`

2. **API Latency**: Network calls dominate total response time
   - CLIO adds <5ms overhead per API call
   - Total latency is 95%+ API provider response time

3. **Token Counting**: Large messages require token estimation
   - Cached after first calculation
   - Minimal impact in practice

## Lazy Loading Analysis

Module load time analysis shows CLIO starts very quickly (~70ms):

| Module | Load Time |
|--------|-----------|
| CLIO::Core::APIManager | 26ms |
| CLIO::Core::Config | 10ms |
| CLIO::UI::Chat | 11ms |
| CLIO::Core::ToolExecutor | 7ms |
| CLIO::Core::WorkflowOrchestrator | 6ms |
| Other modules | <3ms each |

**Decision:** Lazy loading not implemented because:
1. Total startup time is already excellent (~70ms)
2. Most heavy modules (APIManager, Chat) are required for core functionality
3. Optional features (Architect, RepoMap) already load on demand
4. Complexity of lazy loading outweighs the marginal benefit

## Benchmark Results Archive

Run benchmarks periodically and compare against these baselines:

| Date | Module Load | Tool Create | Session Load | Notes |
|------|-------------|-------------|--------------|-------|
| 2026-01-30 | 71ms | 0.62ms | 20.7ms | Baseline |

To add your results:
```bash
perl tests/benchmark.pl >> docs/PERFORMANCE.md
```
