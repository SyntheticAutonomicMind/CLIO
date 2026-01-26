package CLIO::Core::ModelRegistry;

use strict;
use warnings;
use CLIO::Core::Logger qw(should_log);
use JSON::PP;

=head1 NAME

CLIO::Core::ModelRegistry - Centralized model registry for multiple AI providers

=head1 DESCRIPTION

Aggregates available models from multiple AI providers (OpenAI, Anthropic, GitHub Copilot, etc.)
and provides unified access to model capabilities and pricing information.

Inspired by SAM's model management architecture.

=head1 SYNOPSIS

    use CLIO::Core::ModelRegistry;
    
    my $registry = CLIO::Core::ModelRegistry->new();
    
    # Get all available models
    my $models = $registry->get_all_models();
    
    # Get specific model info
    my $info = $registry->get_model_info('gpt-4o');
    
    # Get models by provider
    my $openai_models = $registry->get_models_by_provider('openai');

=head1 METHODS

=head2 new

Create a new model registry.

Arguments:
- debug: Enable debug output (optional)
- github_copilot_api: GitHubCopilotModelsAPI instance (optional)

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        debug => $args{debug} // 0,
        github_copilot_api => $args{github_copilot_api},
        models => {},  # Cached model data
    };
    
    bless $self, $class;
    return $self;
}

=head2 get_all_models

Get all available models from all providers.

Returns arrayref of model hashrefs, each containing:
- id: Model identifier (e.g., 'gpt-4o')
- name: Display name
- provider: Provider name (openai, anthropic, github_copilot)
- enabled: Boolean
- pricing: {input_per_1k, output_per_1k} or '-' if unavailable
- billing: {is_premium, multiplier} (GitHub Copilot specific)
- capabilities: {max_prompt_tokens, max_output_tokens, max_context_window_tokens, family}

=cut

sub get_all_models {
    my ($self) = @_;
    
    my @all_models;
    
    # Get GitHub Copilot models if API available
    if ($self->{github_copilot_api}) {
        push @all_models, @{$self->_get_github_copilot_models()};
    }
    
    # Get OpenAI models (hardcoded with known pricing)
    push @all_models, @{$self->_get_openai_models()};
    
    # Get Anthropic models (hardcoded with known pricing)
    push @all_models, @{$self->_get_anthropic_models()};
    
    return \@all_models;
}

=head2 get_models_by_provider

Get all models for a specific provider.

Arguments:
- $provider: Provider name (openai, anthropic, github_copilot)

Returns arrayref of model hashrefs

=cut

sub get_models_by_provider {
    my ($self, $provider) = @_;
    
    my $all_models = $self->get_all_models();
    
    return [grep { $_->{provider} eq $provider } @$all_models];
}

=head2 get_model_info

Get detailed information about a specific model.

Arguments:
- $model_id: Model identifier

Returns hashref with model info, or undef if not found

=cut

sub get_model_info {
    my ($self, $model_id) = @_;
    
    my $all_models = $self->get_all_models();
    
    for my $model (@$all_models) {
        return $model if $model->{id} eq $model_id;
    }
    
    return undef;
}

# Private methods for each provider

sub _get_github_copilot_models {
    my ($self) = @_;
    
    return [] unless $self->{github_copilot_api};
    
    my $gh_models = $self->{github_copilot_api}->get_all_models();
    return [] unless $gh_models;
    
    my @models;
    
    for my $model (@$gh_models) {
        my $capabilities = $model->{capabilities} || {};
        my $limits = $capabilities->{limits} || {};
        my $billing = $model->{billing} || {};
        
        push @models, {
            id => $model->{id},
            name => $model->{name} || $model->{id},
            provider => 'github_copilot',
            enabled => $model->{enabled} // 1,
            pricing => '-',  # GitHub Copilot uses multiplier system, not per-token pricing
            billing => {
                is_premium => $billing->{is_premium} || 0,
                multiplier => $billing->{multiplier} || 0,
            },
            capabilities => {
                max_prompt_tokens => $limits->{max_prompt_tokens},
                max_output_tokens => $limits->{max_output_tokens},
                max_context_window_tokens => $limits->{max_context_window_tokens},
                family => $capabilities->{family},
            },
        };
    }
    
    return \@models;
}

sub _get_openai_models {
    my ($self) = @_;
    
    # Hardcoded OpenAI model list with current pricing (as of 2026-01)
    # Pricing: https://openai.com/api/pricing/
    # Use '-' for models without published pricing (like GitHub does)
    
    return [
        {
            id => 'gpt-4o',
            name => 'GPT-4o',
            provider => 'openai',
            enabled => 1,
            pricing => {
                input_per_1m => 2.50,   # $2.50 per 1M input tokens
                output_per_1m => 10.00,  # $10.00 per 1M output tokens
            },
            capabilities => {
                max_prompt_tokens => 128000,
                max_output_tokens => 16384,
                max_context_window_tokens => 128000,
                family => 'gpt-4',
            },
        },
        {
            id => 'gpt-4o-mini',
            name => 'GPT-4o Mini',
            provider => 'openai',
            enabled => 1,
            pricing => {
                input_per_1m => 0.150,   # $0.15 per 1M input tokens
                output_per_1m => 0.600,  # $0.60 per 1M output tokens
            },
            capabilities => {
                max_prompt_tokens => 128000,
                max_output_tokens => 16384,
                max_context_window_tokens => 128000,
                family => 'gpt-4',
            },
        },
        {
            id => 'gpt-4-turbo',
            name => 'GPT-4 Turbo',
            provider => 'openai',
            enabled => 1,
            pricing => {
                input_per_1m => 10.00,
                output_per_1m => 30.00,
            },
            capabilities => {
                max_prompt_tokens => 128000,
                max_output_tokens => 4096,
                max_context_window_tokens => 128000,
                family => 'gpt-4',
            },
        },
        {
            id => 'gpt-3.5-turbo',
            name => 'GPT-3.5 Turbo',
            provider => 'openai',
            enabled => 1,
            pricing => {
                input_per_1m => 0.50,
                output_per_1m => 1.50,
            },
            capabilities => {
                max_prompt_tokens => 16385,
                max_output_tokens => 4096,
                max_context_window_tokens => 16385,
                family => 'gpt-3.5',
            },
        },
        {
            id => 'o1-preview',
            name => 'o1 Preview',
            provider => 'openai',
            enabled => 1,
            pricing => {
                input_per_1m => 15.00,
                output_per_1m => 60.00,
            },
            capabilities => {
                max_prompt_tokens => 128000,
                max_output_tokens => 32768,
                max_context_window_tokens => 128000,
                family => 'o1',
            },
        },
        {
            id => 'o1-mini',
            name => 'o1 Mini',
            provider => 'openai',
            enabled => 1,
            pricing => {
                input_per_1m => 3.00,
                output_per_1m => 12.00,
            },
            capabilities => {
                max_prompt_tokens => 128000,
                max_output_tokens => 65536,
                max_context_window_tokens => 128000,
                family => 'o1',
            },
        },
    ];
}

sub _get_anthropic_models {
    my ($self) = @_;
    
    # Hardcoded Anthropic model list with current pricing (as of 2026-01)
    # Pricing: https://www.anthropic.com/pricing
    
    return [
        {
            id => 'claude-3-5-sonnet-20241022',
            name => 'Claude 3.5 Sonnet',
            provider => 'anthropic',
            enabled => 1,
            pricing => {
                input_per_1m => 3.00,
                output_per_1m => 15.00,
            },
            capabilities => {
                max_prompt_tokens => 200000,
                max_output_tokens => 8192,
                max_context_window_tokens => 200000,
                family => 'claude-3.5',
            },
        },
        {
            id => 'claude-3-5-haiku-20241022',
            name => 'Claude 3.5 Haiku',
            provider => 'anthropic',
            enabled => 1,
            pricing => {
                input_per_1m => 0.80,
                output_per_1m => 4.00,
            },
            capabilities => {
                max_prompt_tokens => 200000,
                max_output_tokens => 8192,
                max_context_window_tokens => 200000,
                family => 'claude-3.5',
            },
        },
        {
            id => 'claude-3-opus-20240229',
            name => 'Claude 3 Opus',
            provider => 'anthropic',
            enabled => 1,
            pricing => {
                input_per_1m => 15.00,
                output_per_1m => 75.00,
            },
            capabilities => {
                max_prompt_tokens => 200000,
                max_output_tokens => 4096,
                max_context_window_tokens => 200000,
                family => 'claude-3',
            },
        },
        {
            id => 'claude-3-sonnet-20240229',
            name => 'Claude 3 Sonnet',
            provider => 'anthropic',
            enabled => 1,
            pricing => {
                input_per_1m => 3.00,
                output_per_1m => 15.00,
            },
            capabilities => {
                max_prompt_tokens => 200000,
                max_output_tokens => 4096,
                max_context_window_tokens => 200000,
                family => 'claude-3',
            },
        },
        {
            id => 'claude-3-haiku-20240307',
            name => 'Claude 3 Haiku',
            provider => 'anthropic',
            enabled => 1,
            pricing => {
                input_per_1m => 0.25,
                output_per_1m => 1.25,
            },
            capabilities => {
                max_prompt_tokens => 200000,
                max_output_tokens => 4096,
                max_context_window_tokens => 200000,
                family => 'claude-3',
            },
        },
    ];
}

=head2 format_pricing

Format pricing information for display.

Arguments:
- $pricing: Pricing hashref or '-'

Returns: Formatted string (e.g., "$2.50/$10.00 per 1M" or "-")

=cut

sub format_pricing {
    my ($self, $pricing) = @_;
    
    return '-' if $pricing eq '-' || !$pricing;
    
    if ($pricing->{input_per_1m} && $pricing->{output_per_1m}) {
        return sprintf("\$%.2f/\$%.2f per 1M", 
            $pricing->{input_per_1m}, 
            $pricing->{output_per_1m}
        );
    }
    
    return '-';
}

1;

=head1 NOTES

Model pricing is hardcoded for OpenAI and Anthropic as their APIs don't provide
this information. GitHub Copilot pricing is fetched from their /models API.

Use '-' for models without pricing information (following SAM's convention).

Update hardcoded pricing periodically from:
- OpenAI: https://openai.com/api/pricing/
- Anthropic: https://www.anthropic.com/pricing

=head1 SEE ALSO

L<CLIO::Core::GitHubCopilotModelsAPI>
L<CLIO::Core::APIManager>

=cut

1;
