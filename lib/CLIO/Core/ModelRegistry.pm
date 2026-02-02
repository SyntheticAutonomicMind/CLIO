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
    
    # No hardcoded models - all models must come from provider APIs
    # This ensures the model list is always current and accurate
    
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

=head2 validate_model

Validate that a model name exists in the registry.

Arguments:
  - model_id: Model identifier (e.g., 'gpt-4o')

Returns:
  - (1, '') if valid
  - (0, error_message) if invalid

=cut

sub validate_model {
    my ($self, $model_id) = @_;
    
    unless (defined $model_id && length($model_id)) {
        return (0, "Model name cannot be empty");
    }
    
    my $model_info = $self->get_model_info($model_id);
    if ($model_info) {
        return (1, '');
    }
    
    return (0, "Model '$model_id' not found. Use '/api models' to see available models.");
}

1;

=head1 NOTES

All models are fetched dynamically from provider APIs. No hardcoded models.

Currently supports:
- GitHub Copilot: Fetched from their /models API with pricing/billing info
- OpenAI: Requires API integration (future work)
- Anthropic: Requires API integration (future work)

=head1 SEE ALSO

L<CLIO::Core::GitHubCopilotModelsAPI>
L<CLIO::Core::APIManager>

=cut

1;
