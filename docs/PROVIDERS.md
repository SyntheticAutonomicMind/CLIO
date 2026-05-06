# CLIO Provider Configuration Guide

**Complete reference for configuring AI providers in CLIO**

---

## Quick Reference

| Provider | Short Name | Auth Type |
|----------|------------|-----------|
| **GitHub Copilot** | `github_copilot` | OAuth |
| **OpenAI** | `openai` | API Key |
| **Google Gemini** | `google` | API Key |
| **DeepSeek** | `deepseek` | API Key |
| **OpenRouter** | `openrouter` | API Key |
| **Ollama Cloud** | `ollama_cloud` | API Key |
| **MiniMax** | `minimax` | API Key |
| **MiniMax Token Plan** | `minimax_token` | API Key |
| **Z.AI** | `zai` | API Key |
| **Z.AI Coding Plan** | `zai_coding` | API Key |
| **llama.cpp** | `llama.cpp` | None |
| **LM Studio** | `lmstudio` | None |
| **SAM** | `sam` | API Key |

Models change frequently. After configuring your provider, use `/api models` to see the current list of available models.

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

# List available models for your provider
/api models

# View current configuration
/api show
```

All `/api set` commands save globally. Add `--session` to override for the current session only:

```bash
/api set model gpt-4.1 --session       # This session only
/api set provider llama.cpp --session   # This session only

# Save configuration
/config save
```

### Proxy Configuration

If you need to route API requests through a proxy (corporate network, VPN, etc.):

```bash
# Via config command (persists)
/config set http_proxy http://proxy.example.com:8080

# Via environment variable (session-scoped)
export HTTPS_PROXY=http://proxy.example.com:8080
export ALL_PROXY=socks5://proxy.example.com:1080
```

Supported formats: `http://`, `https://`, `socks5://`, `socks5h://`, `socks4://`. Config `http_proxy` takes priority over environment variables.

---

## Cloud Providers

### GitHub Copilot

**Best for:** Users with existing Copilot subscription who want access to GPT, Claude, and MiniMax models.

**Get Access:**
1. Subscribe to GitHub Copilot at [github.com/features/copilot](https://github.com/features/copilot)
2. Ensure your subscription is active

**Configure CLIO:**
```bash
clio --new

# Login via browser OAuth
/api set provider github_copilot
/api login

# Follow the browser prompts to authenticate
# Token is stored securely and auto-refreshes
```

**Available model families:** GPT, Claude Opus and Sonnet, MiniMax, and more. Use `/api models` for the current list.

```bash
/api models           # See what's available
/api set model <name> # Switch models
```

Note: For an alternative option, consider using OpenRouter with MiniMax instead.

---

### OpenAI

**Best for:** Direct OpenAI API access, latest models immediately

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

**Available model families:** GPT, o-series reasoning models. Use `/api models` for the current list.

---

### Google Gemini

**Best for:** Large context windows, multimodal tasks

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

**Available model families:** Gemini Pro, Gemini Flash. Use `/api models` for the current list.

---

### DeepSeek

**Best for:** Coding tasks, reasoning

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

**Available model families:** DeepSeek Coder, DeepSeek Chat, DeepSeek Reasoner. Use `/api models` for the current list.

---

### OpenRouter

**Best for:** Access to many models via single API, comparing models

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

**Available models:** OpenRouter provides access to hundreds of models from all major providers. Use `/api models` for the current list.

Models use the `provider/model` format:
```bash
/api set model openai/<model-name>
/api set model deepseek/<model-name>
```

---

### Ollama Cloud

**Best for:** Access to open-source models (Qwen, Gemma, DeepSeek, etc.) with API convenience

**Get API Key:**
1. Create account at [ollama.com](https://ollama.com)
2. Go to your account settings
3. Create an API key

**Configure CLIO:**
```bash
clio --new
/api set provider ollama_cloud
/api set key <your-api-key>
/config save
```

**Available model families:** Qwen, Gemma, DeepSeek, Mistral, Llama, and more. Use `/api models` for the current list.

**Features:**
- Supports tools/function calling
- Streaming responses
- Reasoning models (for thinking-enabled models)

**Example models:**
| Model | Size | Best For |
|-------|------|----------|
| gemma4:31b | 31B | Balanced performance |
| qwen3:8b | 8B | Fast, low memory |
| deepseek-v3.2 | - | Coding, reasoning |

---

### MiniMax

**Best for:** High-throughput coding, large output windows, interleaved reasoning

**Get API Key:**
1. Create account at [platform.minimax.io](https://platform.minimax.io)
2. Go to API Keys in your dashboard
3. Create new key

**Configure CLIO (standard):**
```bash
clio --new
/api set provider minimax
/api set key <your-api-key>
/config save
```

**Configure CLIO (Token Plan):**
```bash
clio --new
/api set provider minimax_token
/api set key <your-api-key>
/config save
```

The only difference between `minimax` and `minimax_token` is the API endpoint.

**Available model families:** MiniMax M2 series. Use `/api models` for the current list.

**Sampling defaults:** CLIO automatically applies MiniMax's recommended sampling parameters (`temperature=1.0`, `top_p=0.95`, `top_k=40`) when using this provider. These can be overridden per-session or globally:

```bash
/api set temperature 0.7        # Custom temperature
/api set temperature reset      # Revert to MiniMax default (1.0)
```

**Reasoning:** MiniMax M2 supports interleaved thinking natively. Enable display with `/api set thinking on` and control depth with `/api set thinking_effort low|medium|high`.

**Check Quota (Token Plan only):**
```bash
/api quota
```

---

### Z.AI

**Best for:** GLM-5.1 flagship model, vision, reasoning, long-horizon tasks (8-hour autonomous execution)

**Get API Key:**
1. Create account at [z.ai](https://z.ai)
2. Go to API Keys in your dashboard
3. Create new key

**Configure CLIO:**
```bash
clio --new
/api set provider zai
/api set key <your-api-key>
/config save
```

**Available models:**
| Model | Context | Output | Pricing (1M tokens) |
|-------|---------|--------|---------------------|
| GLM-5.1 | 200K | 128K | $1.40 / $4.40 |
| GLM-5 | 200K | 128K | $1.00 / $3.20 |
| GLM-5-Turbo | 200K | 128K | $1.20 / $4.00 |
| GLM-4.7 | 200K | 128K | $0.60 / $2.20 |
| GLM-4.7-FlashX | 200K | 128K | $0.07 / $0.40 |
| GLM-4.7-Flash | 200K | 128K | FREE |
| GLM-4.6 | 200K | 128K | $0.60 / $2.20 |
| GLM-4.5 | 128K | 96K | $0.60 / $2.20 |
| GLM-4.5-X | 128K | 96K | $2.20 / $8.90 |
| GLM-4.5-Air | 128K | 96K | $0.20 / $1.10 |
| GLM-4.5-AirX | 128K | 96K | $1.10 / $4.50 |
| GLM-4.5-Flash | 200K | 96K | FREE |
| GLM-4-32B | 128K | 16K | $0.10 / $0.10 |

**Vision models:**
| Model | Context | Output | Pricing (1M tokens) |
|-------|---------|--------|---------------------|
| GLM-5V-Turbo | 200K | 128K | $1.20 / $4.00 |
| GLM-4.6V | 128K | 32K | $0.30 / $0.90 |
| GLM-4.6V-FlashX | 128K | 32K | $0.04 / $0.40 |
| GLM-4.6V-Flash | 128K | 32K | FREE |
| GLM-4.5V | 64K | 16K | $0.60 / $1.80 |

**OCR:** GLM-OCR ($0.03 / 1M tokens)

**Reasoning:** GLM-4.5+ supports chain-of-thought reasoning. Enable with `/api set thinking on` and control depth with `/api set thinking_effort low|medium|high`.

---

### Z.AI Coding Plan

**Best for:** Free coding assistance with GLM-4.7, GLM-5.1, and GLM-5 models

**Get Access:**
1. Create account at [z.ai](https://z.ai/subscribe)
2. Subscribe to a coding plan (Lite from $18/month)
3. Get your API key from the coding plan dashboard

**Configure CLIO:**
```bash
clio --new
/api set provider zai_coding
/api set key <your-coding-plan-key>
/config save
```

**Available models:** GLM-5.1, GLM-5-Turbo, GLM-4.7, GLM-4.5-Air (all included in plan)

**Note:** Coding plan provides quota-based access (not API billing). Limits: 80-1,600 prompts per 5 hours depending on plan. See [coding plan docs](https://docs.z.ai/devpack/overview) for details.

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
# List available models
/api models

# Change model
/api set model <model-name>

# For OpenRouter, use full model path
/api set model provider/model-name
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
- Check exact model name with `/api models`
- Some providers require full path (e.g., `openrouter/deepseek/model-name`)

### Environment Variables

You can also configure CLIO via environment variables:

```bash
export CLIO_PROVIDER=openai
export CLIO_API_KEY=sk-...
export CLIO_MODEL=model-name
```

Configuration precedence: `/api set` commands > environment variables > defaults

---

## Provider Comparison

| Feature | GitHub Copilot | OpenAI | Google | DeepSeek | Local |
|---------|---------------|--------|--------|----------|-------|
| **Setup Ease** |  |  |  |  |  |
| **Model Variety** |  |  |  |  |  |
| **Privacy** | Cloud | Cloud | Cloud | Cloud |  |
| **Offline** | No | No | No | No | Yes |

---

## See Also

- [Installation Guide](INSTALLATION.md) - Getting CLIO installed
- [User Guide](USER_GUIDE.md) - Complete CLIO usage reference
- [Features](FEATURES.md) - All CLIO capabilities
