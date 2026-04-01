# CLIO Provider Configuration Guide

**Complete reference for configuring AI providers in CLIO**

---

## Quick Reference

| Provider | Short Name | Auth Type |
|----------|------------|-----------|
| **GitHub Copilot** | `github_copilot` | OAuth |
| **OpenAI** | `openai` | API Key |
| **Anthropic** | `anthropic` | API Key |
| **Google Gemini** | `google` | API Key |
| **DeepSeek** | `deepseek` | API Key |
| **OpenRouter** | `openrouter` | API Key |
| **MiniMax** | `minimax` | API Key |
| **MiniMax Token Plan** | `minimax_token` | API Key |
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

# Save configuration
/config save
```

---

## Cloud Providers

### GitHub Copilot (Recommended)

**Best for:** Most users - single subscription gives access to models from OpenAI, Anthropic, MiniMax, and more.

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

**Available model families:** GPT, Claude Opus and Sonnet, MiniMax, and more. Use `/api models` for the current list.

```bash
/api models           # See what's available
/api set model <name> # Switch models
```

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

### Anthropic

**Best for:** Direct Claude API access, latest Claude features

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

**Available model families:** Claude Opus, Claude Sonnet, Claude Haiku. Use `/api models` for the current list.

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
/api set model anthropic/<model-name>
/api set model openai/<model-name>
```

---

### MiniMax

**Best for:** High-throughput coding, large output windows

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

**Check Quota (Token Plan only):**
```bash
/api quota
```

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
- Some providers require full path (e.g., `openrouter/anthropic/model-name`)

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

| Feature | GitHub Copilot | OpenAI | Anthropic | Google | Local |
|---------|---------------|--------|-----------|--------|-------|
| **Setup Ease** |  |  |  |  |  |
| **Model Variety** |  |  |  |  |  |
| **Privacy** | Cloud | Cloud | Cloud | Cloud |  |
| **Offline** | No | No | No | No | Yes |

---

## See Also

- [Installation Guide](INSTALLATION.md) - Getting CLIO installed
- [User Guide](USER_GUIDE.md) - Complete CLIO usage reference
- [Features](FEATURES.md) - All CLIO capabilities
