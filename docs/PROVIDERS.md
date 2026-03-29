# CLIO Provider Configuration Guide

**Complete reference for configuring AI providers in CLIO**

---

## Quick Reference

| Provider | Short Name | Auth Type | Default Model | Cost |
|----------|------------|-----------|---------------|------|
| **GitHub Copilot** | `github_copilot` | OAuth | `claude-haiku-4.5` | ~$10-19/mo subscription |
| **OpenAI** | `openai` | API Key | `gpt-4.1` | Pay-per-use |
| **Anthropic** | `anthropic` | API Key | `claude-sonnet-4-20250514` | Pay-per-use |
| **Google Gemini** | `google` | API Key | `gemini-2.5-flash` | Free tier + pay-per-use |
| **DeepSeek** | `deepseek` | API Key | `deepseek-coder` | Pay-per-use (low cost) |
| **OpenRouter** | `openrouter` | API Key | `llama-3.1-405b-instruct:free` | Varies by model |
| **MiniMax** | `minimax` | API Key | `MiniMax-M2.7` | Pay-per-use |
| **MiniMax Token Plan** | `minimax_token` | API Key | `MiniMax-M2.7` | Subscription |
| **llama.cpp** | `llama.cpp` | None | `local-model` | Free (local) |
| **LM Studio** | `lmstudio` | None | `local-model` | Free (local) |
| **SAM** | `sam` | API Key | `github_copilot/gpt-4.1` | Free (local) |

---

## Configuration Commands

All provider configuration is done with the `/api` command inside CLIO:

```bash
# See all providers
/api providers

# Get details for a specific provider
/api providers github_copilot

# Switch provider
/api set provider <name>

# Set API key
/api set key <your-key>

# Set model
/api set model <model-name>

# View current configuration
/api show

# Save configuration
/config save
```

---

## Cloud Providers

### GitHub Copilot (Recommended)

**Best for:** Most users - single subscription gives access to multiple models (GPT-4, Claude, etc.)

**Pricing:** ~$10/month (Individual) or ~$19/month (Business)

**Get Access:**
1. Subscribe to GitHub Copilot at [github.com/features/copilot](https://github.com/features/copilot)
2. Ensure your subscription is active

**Configure CLIO:**
```bash
clio --new

# Login via browser OAuth (recommended)
/api set provider github_copilot
/api login

# Follow the browser prompts to authenticate
# Token is stored securely and auto-refreshes
```

**Available Models via Copilot:**
- `gpt-4.1` - Latest GPT-4 variant
- `gpt-4o` - GPT-4 Optimized  
- `gpt-4.1-mini` - Faster, cheaper GPT-4
- `claude-sonnet-4` - Claude Sonnet 4
- `claude-haiku-4.5` - Fast Claude (default)
- `o3-mini` - OpenAI reasoning model

**Switch Models:**
```bash
/api set model gpt-4.1
/api set model claude-sonnet-4
```

---

### OpenAI

**Best for:** Direct OpenAI API access, latest models immediately

**Pricing:** Pay-per-use ([openai.com/pricing](https://openai.com/pricing))

**Get API Key:**
1. Create account at [platform.openai.com](https://platform.openai.com)
2. Go to API Keys: [platform.openai.com/api-keys](https://platform.openai.com/api-keys)
3. Create new secret key

**Configure CLIO:**
```bash
clio --new
/api set provider openai
/api set key sk-proj-...your-key...
/config save
```

**Available Models:**
- `gpt-4.1` - Latest GPT-4 (recommended)
- `gpt-4o` - GPT-4 Optimized
- `gpt-4.1-mini` - Fast and cost-effective
- `gpt-4.1-nano` - Fastest, cheapest
- `o3-mini` - Reasoning model

---

### Anthropic

**Best for:** Direct Claude API access, latest Claude features

**Pricing:** Pay-per-use ([anthropic.com/pricing](https://anthropic.com/pricing))

**Status:** Experimental (native API integration)

**Get API Key:**
1. Create account at [console.anthropic.com](https://console.anthropic.com)
2. Go to API Keys in settings
3. Create new key

**Configure CLIO:**
```bash
clio --new
/api set provider anthropic
/api set key sk-ant-...your-key...
/config save
```

**Available Models:**
- `claude-sonnet-4-20250514` - Claude Sonnet 4 (default)
- `claude-opus-4-20250514` - Most capable Claude
- `claude-haiku-4` - Fast and efficient

---

### Google Gemini

**Best for:** Large context windows (1M+ tokens), multimodal tasks

**Pricing:** Free tier available, then pay-per-use ([ai.google.dev/pricing](https://ai.google.dev/pricing))

**Get API Key:**
1. Go to [aistudio.google.com](https://aistudio.google.com)
2. Click "Get API Key"
3. Create key for new or existing project

**Configure CLIO:**
```bash
clio --new
/api set provider google
/api set key AIza...your-key...
/config save
```

**Available Models:**
- `gemini-2.5-flash` - Fast, efficient (default)
- `gemini-2.5-pro` - Most capable
- `gemini-2.0-flash` - Previous generation

**Note:** Google Gemini supports up to 1M token context window.

---

### DeepSeek

**Best for:** Cost-effective coding tasks, budget-conscious users

**Pricing:** Very low pay-per-use rates ([platform.deepseek.com](https://platform.deepseek.com))

**Get API Key:**
1. Create account at [platform.deepseek.com](https://platform.deepseek.com)
2. Go to API Keys section
3. Create new key

**Configure CLIO:**
```bash
clio --new
/api set provider deepseek
/api set key sk-...your-key...
/config save
```

**Available Models:**
- `deepseek-coder` - Optimized for code (default)
- `deepseek-chat` - General conversation
- `deepseek-reasoner` - Enhanced reasoning

---

### OpenRouter

**Best for:** Access to many models via single API, comparing models

**Pricing:** Varies by model ([openrouter.ai/models](https://openrouter.ai/models))

**Get API Key:**
1. Create account at [openrouter.ai](https://openrouter.ai)
2. Go to Keys section
3. Create new key

**Configure CLIO:**
```bash
clio --new
/api set provider openrouter
/api set key sk-or-...your-key...
/config save
```

**Available Models:** 
OpenRouter provides access to 100+ models. Some popular options:
- `meta-llama/llama-3.1-405b-instruct:free` - Free Llama (default)
- `anthropic/claude-sonnet-4` - Claude via OpenRouter
- `openai/gpt-4.1` - GPT-4 via OpenRouter
- `google/gemini-2.5-pro` - Gemini via OpenRouter

**Switch Models:**
```bash
/api set model anthropic/claude-sonnet-4
/api set model openai/gpt-4.1
```

---

### MiniMax

**Best for:** High-throughput coding, large output windows (131k tokens), competitive pricing

**Pricing:** Pay-per-use or Token Plan subscription ([platform.minimax.io](https://platform.minimax.io))

**Get API Key:**
1. Create account at [platform.minimax.io](https://platform.minimax.io)
2. Go to API Keys in your dashboard
3. Create new key

**Configure CLIO (Pay-per-use):**
```bash
clio --new
/api set provider minimax
/api set key <your-api-key>
/config save
```

**Configure CLIO (Token Plan subscription):**
```bash
clio --new
/api set provider minimax_token
/api set key <your-api-key>
/config save
```

The only difference between `minimax` and `minimax_token` is the API endpoint. Token Plan users get rate-limited access at a flat subscription cost.

**Available Models:**
- `MiniMax-M2.7` - Latest, recursive self-improvement (~60 tps)
- `MiniMax-M2.7-highspeed` - Same as M2.7 (~100 tps)
- `MiniMax-M2.5` - Code generation and refactoring (~60 tps)
- `MiniMax-M2.5-highspeed` - Same as M2.5 (~100 tps)
- `MiniMax-M2.1` - 230B params, code + reasoning (~60 tps)
- `MiniMax-M2.1-highspeed` - Same as M2.1 (~100 tps)
- `MiniMax-M2` - Function calling, advanced reasoning

All models share a 204.8k context window and 131k max output tokens.

**Check Quota (Token Plan only):**
```bash
/api quota
```

Shows 5-hour rolling window usage and weekly limits.

**Use with --model flag:**
```bash
clio --model MiniMax-M2.7 --new
```

CLIO auto-detects MiniMax models and routes to the correct provider.

---

## Local Providers

Local providers run entirely on your machine - no internet required, no API costs.

### llama.cpp

**Best for:** Privacy-focused users, offline use, running open-source models

**Requirements:** 
- Sufficient RAM/VRAM for your chosen model
- llama.cpp compiled and running

**Setup llama.cpp:**
```bash
# Clone and build
git clone https://github.com/ggerganov/llama.cpp.git
cd llama.cpp && make

# Download a model (GGUF format)
# Visit: https://huggingface.co/models?search=gguf

# Start the server
./llama-server -m /path/to/model.gguf --port 8080
```

**Configure CLIO:**
```bash
clio --new
/api set provider llama.cpp
/api show
```

No API key needed - connects to `http://localhost:8080` by default.

**Custom Port:**
```bash
/api set api_base http://localhost:9000/v1/chat/completions
```

---

### LM Studio

**Best for:** GUI-based model management, easy setup for beginners

**Requirements:**
- LM Studio installed
- Downloaded model running

**Setup LM Studio:**
1. Download from [lmstudio.ai](https://lmstudio.ai)
2. Install and launch
3. Download a model from the built-in browser
4. Start the local server (default port: 1234)

**Configure CLIO:**
```bash
clio --new
/api set provider lmstudio
/api show
```

No API key needed - connects to `http://localhost:1234` by default.

---

### SAM (Synthetic Autonomic Mind)

**Best for:** Users running SAM locally for enhanced capabilities

**Requirements:**
- SAM server running locally
- SAM API token (if configured)

**Configure CLIO:**
```bash
clio --new
/api set provider sam
/api set key <sam-token-if-required>
/config save
```

Default endpoint: `http://localhost:8080/v1/chat/completions`

---

## Common Tasks

### Switching Providers

You can switch providers at any time:

```bash
# Switch to a different provider
/api set provider openai
/api set key sk-...
/config save

# Switch back
/api set provider github_copilot
/api login
```

### Checking Current Configuration

```bash
/api show
```

Shows: current provider, model, API base URL, and authentication status.

### Using Different Models

```bash
# List what model you're using
/api show

# Change model
/api set model gpt-4.1

# For OpenRouter, use full model path
/api set model anthropic/claude-sonnet-4
```

### Troubleshooting

**"API authentication failed"**
- Verify your API key is correct
- For GitHub Copilot: run `/api login` again
- Check subscription status with provider

**"Connection refused" (local providers)**
- Ensure local server is running
- Check port number matches configuration
- Verify with: `curl http://localhost:8080/health`

**"Model not found"**
- Check exact model name spelling
- Some providers require full path (e.g., `openrouter/anthropic/claude-3`)
- Run `/api providers <name>` for available models

### Environment Variables

You can also configure CLIO via environment variables:

```bash
export CLIO_PROVIDER=openai
export CLIO_API_KEY=sk-...
export CLIO_MODEL=gpt-4.1
```

Configuration precedence: `/api set` commands > environment variables > defaults

---

## Provider Comparison

| Feature | GitHub Copilot | OpenAI | Anthropic | Google | Local |
|---------|---------------|--------|-----------|--------|-------|
| **Setup Ease** | ★★★★★ | ★★★★☆ | ★★★★☆ | ★★★★☆ | ★★★☆☆ |
| **Model Variety** | ★★★★★ | ★★★★☆ | ★★★☆☆ | ★★★☆☆ | ★★★★★ |
| **Cost** | Fixed monthly | Pay-per-use | Pay-per-use | Free tier | Free |
| **Privacy** | Cloud | Cloud | Cloud | Cloud | ★★★★★ |
| **Offline** | No | No | No | No | Yes |
| **Context Size** | Varies | 128K | 200K | 1M+ | Varies |

---

## See Also

- [Installation Guide](INSTALLATION.md) - Getting CLIO installed
- [User Guide](USER_GUIDE.md) - Complete CLIO usage reference
- [Features](FEATURES.md) - All CLIO capabilities
