#!/usr/bin/env perl
# Test CLIO::Providers - provider_from_url detection
#
# Tests URL-to-provider detection for all known API endpoints.

use strict;
use warnings;
use lib './lib';
use Test::More;

use CLIO::Providers qw(provider_from_url);

# =============================================================================
# Standard API providers
# =============================================================================

subtest 'standard API providers' => sub {
    is(provider_from_url('https://api.githubcopilot.com'), 'github-copilot',
        'GitHub Copilot detected');
    is(provider_from_url('https://api.githubcopilot.com/'), 'github-copilot',
        'GitHub Copilot with trailing slash');
    is(provider_from_url('https://api.openai.com/v1/chat/completions'), 'openai',
        'OpenAI detected');
    is(provider_from_url('https://generativelanguage.googleapis.com/v1beta'), 'google',
        'Google Gemini detected');
    is(provider_from_url('https://openrouter.ai/api/v1/chat/completions'), 'openrouter',
        'OpenRouter detected');
    is(provider_from_url('https://api.minimax.io/v1/chat/completions'), 'minimax',
        'MiniMax detected');
    is(provider_from_url('https://ollama.com/v1/chat/completions'), 'ollama-cloud',
        'Ollama Cloud detected');
    is(provider_from_url('https://api.deepseek.com/v1'), 'deepseek',
        'DeepSeek detected');
    is(provider_from_url('https://api.anthropic.com/v1/messages'), 'anthropic',
        'Anthropic detected');
    is(provider_from_url('https://api.z.ai/api/paas/v4'), 'zai',
        'Z.AI detected');
    is(provider_from_url('https://api.z.ai/api/coding/paas/v4'), 'zai-coding',
        'Z.AI Coding Plan detected');
    is(provider_from_url('https://integrate.api.nvidia.com/v1'), 'nvidia',
        'NVIDIA detected');
};

# =============================================================================
# Local/self-hosted providers
# =============================================================================

subtest 'local providers' => sub {
    is(provider_from_url('http://localhost:1234/v1/chat/completions'), 'lmstudio',
        'LM Studio (localhost) detected');
    is(provider_from_url('http://127.0.0.1:1234/v1'), 'lmstudio',
        'LM Studio (127.0.0.1) detected');
    is(provider_from_url('http://localhost:8080/v1/chat/completions'), 'sam',
        'SAM (localhost) detected');
    is(provider_from_url('http://127.0.0.1:8080/v1'), 'sam',
        'SAM (127.0.0.1) detected');
};

# =============================================================================
# Edge cases
# =============================================================================

subtest 'edge cases' => sub {
    is(provider_from_url(undef), undef, 'undef returns undef');
    is(provider_from_url(''), undef, 'empty string returns undef');
    is(provider_from_url('https://unknown.example.com'), undef,
        'Unknown URL returns undef');
    is(provider_from_url('https://api.githubcopilot.com/models'), 'github-copilot',
        'GitHub Copilot with /models path detected');
};

done_testing();
