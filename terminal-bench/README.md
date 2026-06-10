# CLIO Terminal-Bench Adapter

Run [CLIO](https://github.com/syntheticautonomicmind/clio) in the [Terminal-Bench](https://github.com/harbor-framework/terminal-bench) evaluation framework.

## What This Does

This adapter lets you evaluate CLIO's agent performance against the Terminal-Bench task suite - real-world terminal tasks like compiling code, setting up servers, and training models.

## Prerequisites

- [terminal-bench](https://github.com/harbor-framework/terminal-bench) installed (`pip install terminal-bench`)
- Docker running
- API key for your chosen model provider

## Quick Start

```bash
# Run CLIO on a single task
PYTHONPATH=terminal-bench tb run \
    --agent-import-path clio_tb_agent:ClioAgent \
    --model anthropic/claude-sonnet-4-20250514 \
    --dataset terminal-bench-core==head \
    --task-id hello-world

# Run on the full benchmark
PYTHONPATH=terminal-bench tb run \
    --agent-import-path clio_tb_agent:ClioAgent \
    --model anthropic/claude-sonnet-4-20250514 \
    --dataset terminal-bench-core==head \
    --n-concurrent 4
```

## API Key Configuration

CLIO checks the `CLIO_API_KEY` environment variable first, then falls back to provider-specific keys. Set whichever matches your provider:

```bash
# Universal (works for any provider)
export CLIO_API_KEY=sk-...

# Provider-specific
export ANTHROPIC_API_KEY=sk-ant-...    # for anthropic/ models
export OPENAI_API_KEY=sk-...           # for openai/ models
export GEMINI_API_KEY=...              # for google/ models
```

## Custom CLIO Path

If CLIO is not at the default location (detected relative to this adapter), specify it:

```bash
PYTHONPATH=terminal-bench tb run \
    --agent-import-path clio_tb_agent:ClioAgent \
    --agent-kwarg clio_path=/path/to/clio/repo \
    --model anthropic/claude-sonnet-4-20250514 \
    --dataset terminal-bench-core==head
```

## How It Works

1. The adapter copies the CLIO source tree into the Docker task container
2. A setup script installs Perl and system dependencies, then links `clio` into PATH
3. CLIO runs in non-interactive mode: `clio --no-color --new --model <model> --input <instruction> --exit`
4. The adapter parses OSC protocol events from the tmux output for token usage reporting
5. Terminal-Bench evaluates the result against the task's test script

## OSC Protocol Integration

CLIO supports structured communication via OSC escape sequences (`CLIO_HOST_PROTOCOL=1`). This adapter enables the protocol and parses `clio:tokens` events from the tmux session output to populate `AgentResult` token counts.

Events emitted by CLIO:
- `clio:status` - Agent state changes (thinking, streaming, tools, idle)
- `clio:tool` - Tool execution start/end
- `clio:tokens` - Token usage per request
- `clio:spinner` - Spinner control
- `clio:todo` - Todo list updates

## Architecture

```
terminal-bench/
    clio_tb_agent.py        # Agent class (AbstractInstalledAgent)
    clio-setup.sh.j2        # Container setup script (Jinja2 template)
    README.md               # This file
```

## Supported Models

CLIO supports any model available through its configured providers. Use the `provider/model` format:

- `anthropic/claude-sonnet-4-20250514`
- `openai/gpt-4.1`
- `google/gemini-2.5-pro`
- `github-copilot/claude-sonnet-4`

Check `clio --list-models` for available models.