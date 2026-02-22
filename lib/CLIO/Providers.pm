package CLIO::Providers;

use strict;
use warnings;
use utf8;
use Exporter 'import';

our @EXPORT_OK = qw(get_provider list_providers provider_exists);

=head1 NAME

CLIO::Providers - Central provider registry for CLIO

=head1 DESCRIPTION

Single source of truth for all API provider configurations.
Defines default settings for each provider (api_base, model, capabilities).
Users can override any setting via /api commands, but these are the defaults.

=head1 SYNOPSIS

    use CLIO::Providers qw(get_provider list_providers);
    
    my $provider = get_provider('sam');
    # Returns: { name => 'SAM', api_base => 'http://localhost:8080/api/chat/completions', ... }
    
    my @providers = list_providers();
    # Returns: ('sam', 'github_copilot', 'openai', ...)

=cut

# THE SINGLE SOURCE OF TRUTH FOR PROVIDER CONFIGURATIONS
# Each provider has:
#   - name: Display name
#   - api_base: Base URL for API requests
#   - model: Default model to use
#   - requires_auth: Authentication method (optional, copilot/apikey/none)
#   - supports_tools: Whether provider supports function calling
#   - supports_streaming: Whether provider supports streaming responses
#   - chat_endpoint_suffix: Path to append to api_base for chat (if not already in api_base)

my %PROVIDERS = (
    sam => {
        name => 'SAM (Local)',
        api_base => 'http://localhost:8080/v1/chat/completions',
        model => 'github_copilot/gpt-4.1',
        requires_auth => 'apikey',
        supports_tools => 1,
        supports_streaming => 1,
        max_context_tokens => 32000,  # Local models typically have smaller context
    },
    
    github_copilot => {
        name => 'GitHub Copilot',
        api_base => 'https://api.githubcopilot.com',
        model => 'claude-haiku-4.5',
        requires_auth => 'copilot',  # Uses GitHub OAuth flow
        supports_tools => 1,
        supports_streaming => 1,
        chat_endpoint_suffix => '/chat/completions',
    },
    
    openai => {
        name => 'OpenAI',
        api_base => 'https://api.openai.com/v1/chat/completions',
        model => 'gpt-4',
        requires_auth => 'apikey',
        supports_tools => 1,
        supports_streaming => 1,
    },
    
    deepseek => {
        name => 'DeepSeek',
        api_base => 'https://api.deepseek.com/v1',
        model => 'deepseek-coder',
        requires_auth => 'apikey',
        supports_tools => 1,
        supports_streaming => 1,
        chat_endpoint_suffix => '/chat/completions',
    },
    
    'llama.cpp' => {
        name => 'llama.cpp (Local)',
        api_base => 'http://localhost:8080/v1/chat/completions',
        model => 'local-model',
        requires_auth => 'none',
        supports_tools => 1,  # llama.cpp supports OpenAI-compatible function calling
        supports_streaming => 1,
        max_context_tokens => 32000,  # Local models typically have smaller context
    },
    
    lmstudio => {
        name => 'LM Studio',
        api_base => 'http://localhost:1234/v1/chat/completions',
        model => 'local-model',
        requires_auth => 'none',
        supports_tools => 1,  # LM Studio supports OpenAI-compatible function calling
        supports_streaming => 1,
        max_context_tokens => 32000,  # Local models typically have smaller context
    },
    
    openrouter => {
        name => 'OpenRouter',
        api_base => 'https://openrouter.ai/api/v1/chat/completions',
        model => 'meta-llama/llama-3.1-405b-instruct:free',
        requires_auth => 'apikey',
        supports_tools => 1,
        supports_streaming => 1,
    },
    
    anthropic => {
        name => 'Anthropic',
        api_base => 'https://api.anthropic.com/v1/messages',
        model => 'claude-sonnet-4-20250514',
        requires_auth => 'apikey',
        supports_tools => 1,
        supports_streaming => 1,
        native_api => 1,  # Uses native provider module, not OpenAI-compatible
        provider_module => 'CLIO::Providers::Anthropic',
        experimental => 1,  # Native API support is experimental
    },
    
    google => {
        name => 'Google Gemini',
        api_base => 'https://generativelanguage.googleapis.com/v1beta',
        model => 'gemini-2.5-flash',
        requires_auth => 'apikey',
        supports_tools => 1,
        supports_streaming => 1,
        native_api => 1,
        provider_module => 'CLIO::Providers::Google',
        experimental => 1,  # Native API support is experimental
    },
);

=head2 get_provider

Get provider configuration by name

Arguments:
  $name - Provider name (e.g. 'sam', 'openai')

Returns:
  Hashref with provider config, or undef if not found

=cut

sub get_provider {
    my ($name) = @_;
    
    return unless defined $name;
    return unless exists $PROVIDERS{$name};
    
    # Return copy so caller can't modify the registry
    my %provider = %{$PROVIDERS{$name}};
    return \%provider;
}

=head2 list_providers

Get list of all provider names

Returns:
  Array of provider names in alphabetical order

=cut

sub list_providers {
    return sort keys %PROVIDERS;
}

=head2 provider_exists

Check if a provider exists

Arguments:
  $name - Provider name to check

Returns:
  1 if provider exists, 0 otherwise

=cut

sub provider_exists {
    my ($name) = @_;
    
    return 0 unless defined $name;
    return exists $PROVIDERS{$name} ? 1 : 0;
}

=head2 validate_provider

Validate that a provider exists.

Arguments:
  - provider_name: Provider identifier (e.g., 'openai')

Returns:
  - (1, '') if valid
  - (0, error_message) if invalid

=cut

sub validate_provider {
    my ($provider_name) = @_;
    
    unless (defined $provider_name && length($provider_name)) {
        return (0, "Provider name cannot be empty");
    }
    
    if (provider_exists($provider_name)) {
        return (1, '');
    }
    
    my @providers = list_providers();
    my $providers_str = join(', ', @providers);
    return (0, "Provider '$provider_name' not found. Available: $providers_str");
}

1;

=head1 AUTHOR

CLIO Project

=head1 LICENSE

This is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut

1;
