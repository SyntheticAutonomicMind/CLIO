package CLIO::Protocols::Model;

use strict;
use warnings;
use base 'CLIO::Protocols::Handler';
use MIME::Base64;
use JSON::PP;

=head1 NAME

CLIO::Protocols::Model - AI model selection and management protocol handler

=head1 DESCRIPTION

This module provides intelligent model selection and management capabilities.
It handles model routing, configuration, prompt optimization, and performance
monitoring across different AI endpoints and model types.

=head1 PROTOCOL FORMAT

[MODEL:action=<action>:request=<base64_request>:context=<base64_context>:options=<base64_options>]

Actions:
- select: Choose optimal model for task
- configure: Set model parameters
- route: Route request to appropriate model
- optimize: Optimize prompts for specific models
- monitor: Track model performance
- fallback: Handle model failures

Request:
- task_type: architect|editor|analysis|general
- prompt: The actual prompt/request
- complexity: simple|moderate|complex
- requirements: speed|quality|cost

Context:
- previous_models: Models used recently
- performance_history: Past performance data
- user_preferences: User model preferences
- system_constraints: Resource limitations

=cut

sub new {
    my ($class, %args) = @_;
    my $self = bless {
        model_registry => {
            'qwen3-coder-max' => {
                type => 'code_specialized',
                strengths => ['code_generation', 'code_analysis', 'refactoring'],
                weaknesses => ['general_conversation'],
                cost_tier => 'high',
                speed_tier => 'medium',
                quality_tier => 'high',
                endpoints => ['dashscope-cn', 'dashscope-intl'],
                context_window => 32768,
            },
            'qwen-coder' => {
                type => 'code_general',
                strengths => ['code_generation', 'debugging', 'documentation'],
                weaknesses => ['complex_architecture'],
                cost_tier => 'medium',
                speed_tier => 'high',
                quality_tier => 'medium',
                endpoints => ['dashscope-cn', 'dashscope-intl'],
                context_window => 16384,
            },
            'gpt-4' => {
                type => 'general_advanced',
                strengths => ['reasoning', 'architecture', 'complex_analysis'],
                weaknesses => ['cost', 'speed'],
                cost_tier => 'high',
                speed_tier => 'low',
                quality_tier => 'high',
                endpoints => ['openai'],
                context_window => 8192,
            },
            'gpt-3.5-turbo' => {
                type => 'general_fast',
                strengths => ['speed', 'general_tasks', 'cost_effective'],
                weaknesses => ['complex_reasoning'],
                cost_tier => 'low',
                speed_tier => 'high',
                quality_tier => 'medium',
                endpoints => ['openai'],
                context_window => 4096,
            },
            'github-copilot' => {
                type => 'code_completion',
                strengths => ['code_completion', 'inline_suggestions', 'context_aware'],
                weaknesses => ['architectural_design'],
                cost_tier => 'low',
                speed_tier => 'high',
                quality_tier => 'medium',
                endpoints => ['github-copilot'],
                context_window => 2048,
            },
        },
        task_model_preferences => {
            architect => ['qwen3-coder-max', 'gpt-4', 'qwen-coder'],
            editor => ['qwen3-coder-max', 'github-copilot', 'qwen-coder'],
            analysis => ['qwen3-coder-max', 'gpt-4', 'qwen-coder'],
            general => ['gpt-3.5-turbo', 'qwen-coder', 'gpt-4'],
            debugging => ['qwen3-coder-max', 'github-copilot', 'qwen-coder'],
            documentation => ['qwen-coder', 'qwen3-coder-max', 'gpt-3.5-turbo'],
        },
        performance_history => {},
        fallback_chains => {
            'qwen3-coder-max' => ['qwen-coder', 'gpt-4', 'gpt-3.5-turbo'],
            'gpt-4' => ['gpt-3.5-turbo', 'qwen3-coder-max', 'qwen-coder'],
            'github-copilot' => ['qwen3-coder-max', 'qwen-coder'],
        },
        %args
    }, $class;
    
    return $self;
}

sub process_request {
    my ($self, $input) = @_;
    
    # Parse protocol: [MODEL:action=<action>:request=<base64_request>:context=<base64_context>:options=<base64_options>]
    if ($input !~ /^\[MODEL:action=([^:]+):request=([^:]+)(?::context=([^:]+))?(?::options=([^:]+))?\]$/) {
        return $self->handle_errors('Invalid MODEL protocol format');
    }
    
    my ($action, $b64_request, $b64_context, $b64_options) = ($1, $2, $3, $4);
    
    # Decode request
    my $request = eval { decode_base64($b64_request) };
    if ($@) {
        return $self->handle_errors("Failed to decode request: $@");
    }
    
    # Parse request if it's JSON
    my $request_spec = {};
    if ($request =~ /^\s*\{/) {
        $request_spec = eval { decode_json($request) };
        if ($@) {
            $request_spec = { prompt => $request, task_type => 'general' };
        }
    } else {
        $request_spec = { prompt => $request, task_type => 'general' };
    }
    
    # Decode context if provided
    my $context = {};
    if ($b64_context) {
        my $context_json = eval { decode_base64($b64_context) };
        if ($@) {
            return $self->handle_errors("Failed to decode context: $@");
        }
        $context = eval { decode_json($context_json) };
        if ($@) {
            return $self->handle_errors("Invalid context JSON: $@");
        }
    }
    
    # Decode options if provided
    my $options = {};
    if ($b64_options) {
        my $options_json = eval { decode_base64($b64_options) };
        if ($@) {
            return $self->handle_errors("Failed to decode options: $@");
        }
        $options = eval { decode_json($options_json) };
        if ($@) {
            return $self->handle_errors("Invalid options JSON: $@");
        }
    }
    
    # Route to appropriate action handler
    my $method = "_handle_$action";
    if ($self->can($method)) {
        return $self->$method($request_spec, $context, $options);
    } else {
        return $self->handle_errors("Unknown action: $action");
    }
}

sub _handle_select {
    my ($self, $request_spec, $context, $options) = @_;
    
    my $task_type = $request_spec->{task_type} || 'general';
    my $complexity = $request_spec->{complexity} || 'moderate';
    my $requirements = $request_spec->{requirements} || [];
    
    # Get candidate models for task type
    my $candidates = $self->{task_model_preferences}->{$task_type} || 
                    $self->{task_model_preferences}->{general};
    
    # Score models based on requirements and context
    my @scored_models = ();
    for my $model_name (@$candidates) {
        my $model_info = $self->{model_registry}->{$model_name};
        next unless $model_info;
        
        my $score = $self->_score_model($model_name, $model_info, $request_spec, $context, $options);
        push @scored_models, {
            name => $model_name,
            score => $score,
            info => $model_info,
            reasoning => $score->{reasoning},
        };
    }
    
    # Sort by score (highest first)
    @scored_models = sort { $b->{score}->{total} <=> $a->{score}->{total} } @scored_models;
    
    my $selected_model = $scored_models[0];
    my $alternatives = [@scored_models[1..2]];  # Top 3 alternatives
    
    my $result = {
        success => 1,
        action => 'select',
        selected_model => $selected_model->{name},
        model_info => $selected_model->{info},
        selection_reasoning => $selected_model->{reasoning},
        confidence_score => $selected_model->{score}->{total},
        alternatives => [map { { name => $_->{name}, score => $_->{score}->{total} } } @$alternatives],
        task_type => $task_type,
        complexity => $complexity,
    };
    
    return $self->format_response($result);
}

sub _handle_configure {
    my ($self, $request_spec, $context, $options) = @_;
    
    my $model_name = $request_spec->{model_name} || $context->{current_model};
    unless ($model_name) {
        return $self->handle_errors("model_name required for configure action");
    }
    
    my $model_info = $self->{model_registry}->{$model_name};
    unless ($model_info) {
        return $self->handle_errors("Unknown model: $model_name");
    }
    
    # Generate optimal configuration for model and task
    my $config = $self->_generate_model_config($model_name, $model_info, $request_spec, $context, $options);
    
    my $result = {
        success => 1,
        action => 'configure',
        model_name => $model_name,
        configuration => $config,
        explanation => $self->_explain_configuration($config, $model_info, $request_spec),
    };
    
    return $self->format_response($result);
}

sub _handle_route {
    my ($self, $request_spec, $context, $options) = @_;
    
    # First select the best model
    my $selection_result = $self->_handle_select($request_spec, $context, $options);
    unless ($selection_result->{data}->{success}) {
        return $selection_result;
    }
    
    my $selected_model = $selection_result->{data}->{selected_model};
    my $model_info = $self->{model_registry}->{$selected_model};
    
    # Configure model
    my $config = $self->_generate_model_config($selected_model, $model_info, $request_spec, $context, $options);
    
    # Optimize prompt for selected model
    my $optimized_prompt = $self->_optimize_prompt_for_model($request_spec->{prompt}, $selected_model, $model_info, $options);
    
    # Select endpoint
    my $endpoint = $self->_select_endpoint($model_info->{endpoints}, $context, $options);
    
    my $result = {
        success => 1,
        action => 'route',
        routing => {
            model => $selected_model,
            endpoint => $endpoint,
            configuration => $config,
            optimized_prompt => $optimized_prompt,
            fallback_models => $self->{fallback_chains}->{$selected_model} || [],
        },
        request_id => $self->_generate_request_id(),
        timestamp => time(),
    };
    
    return $self->format_response($result);
}

sub _handle_optimize {
    my ($self, $request_spec, $context, $options) = @_;
    
    my $model_name = $request_spec->{model_name} || $context->{current_model};
    unless ($model_name) {
        return $self->handle_errors("model_name required for optimize action");
    }
    
    my $model_info = $self->{model_registry}->{$model_name};
    unless ($model_info) {
        return $self->handle_errors("Unknown model: $model_name");
    }
    
    my $original_prompt = $request_spec->{prompt};
    my $optimized_prompt = $self->_optimize_prompt_for_model($original_prompt, $model_name, $model_info, $options);
    
    my $optimizations_applied = $self->_get_optimization_details($original_prompt, $optimized_prompt, $model_info);
    
    my $result = {
        success => 1,
        action => 'optimize',
        model_name => $model_name,
        original_prompt => $original_prompt,
        optimized_prompt => $optimized_prompt,
        optimizations_applied => $optimizations_applied,
        improvement_estimate => $self->_estimate_improvement($optimizations_applied),
    };
    
    return $self->format_response($result);
}

sub _handle_monitor {
    my ($self, $request_spec, $context, $options) = @_;
    
    my $model_name = $request_spec->{model_name};
    my $performance_data = $request_spec->{performance_data};
    
    if ($performance_data) {
        # Record performance data
        $self->_record_performance($model_name, $performance_data);
    }
    
    # Get performance statistics
    my $stats = $self->_get_performance_stats($model_name);
    my $trends = $self->_analyze_performance_trends($model_name);
    my $recommendations = $self->_generate_performance_recommendations($stats, $trends);
    
    my $result = {
        success => 1,
        action => 'monitor',
        model_name => $model_name,
        performance_stats => $stats,
        trends => $trends,
        recommendations => $recommendations,
        data_points => scalar keys %{$self->{performance_history}->{$model_name} || {}},
    };
    
    return $self->format_response($result);
}

sub _handle_fallback {
    my ($self, $request_spec, $context, $options) = @_;
    
    my $failed_model = $request_spec->{failed_model};
    my $failure_reason = $request_spec->{failure_reason} || 'unknown';
    
    unless ($failed_model) {
        return $self->handle_errors("failed_model required for fallback action");
    }
    
    # Get fallback chain
    my $fallback_chain = $self->{fallback_chains}->{$failed_model} || [];
    
    # Select next available model
    my $fallback_model = $self->_select_fallback_model($fallback_chain, $context, $options);
    
    # Record failure for learning
    $self->_record_failure($failed_model, $failure_reason, $context);
    
    my $result = {
        success => 1,
        action => 'fallback',
        failed_model => $failed_model,
        failure_reason => $failure_reason,
        fallback_model => $fallback_model,
        fallback_chain => $fallback_chain,
        fallback_reasoning => $self->_explain_fallback_choice($fallback_model, $failed_model, $context),
    };
    
    return $self->format_response($result);
}

# Model Scoring and Selection
sub _score_model {
    my ($self, $model_name, $model_info, $request_spec, $context, $options) = @_;
    
    my $scores = {
        task_suitability => 0,
        performance_history => 0,
        resource_requirements => 0,
        availability => 0,
        cost_efficiency => 0,
    };
    
    my $reasoning = [];
    
    # Task suitability scoring
    my $task_type = $request_spec->{task_type};
    if (grep { $_ eq $task_type } @{$model_info->{strengths}}) {
        $scores->{task_suitability} = 10;
        push @$reasoning, "Excellent match for $task_type tasks";
    } elsif (grep { $_ eq $task_type } @{$model_info->{weaknesses} || []}) {
        $scores->{task_suitability} = 3;
        push @$reasoning, "Not ideal for $task_type tasks";
    } else {
        $scores->{task_suitability} = 6;
        push @$reasoning, "Moderate match for $task_type tasks";
    }
    
    # Performance history scoring
    my $perf_history = $self->{performance_history}->{$model_name};
    if ($perf_history && $perf_history->{success_rate}) {
        $scores->{performance_history} = $perf_history->{success_rate} * 10;
        push @$reasoning, sprintf("Historical success rate: %.1f%%", $perf_history->{success_rate} * 100);
    } else {
        $scores->{performance_history} = 5;  # Neutral score for unknown
        push @$reasoning, "No performance history available";
    }
    
    # Resource requirements scoring
    my $complexity = $request_spec->{complexity} || 'moderate';
    if ($complexity eq 'simple' && $model_info->{speed_tier} eq 'high') {
        $scores->{resource_requirements} = 9;
        push @$reasoning, "Fast model suitable for simple tasks";
    } elsif ($complexity eq 'complex' && $model_info->{quality_tier} eq 'high') {
        $scores->{resource_requirements} = 9;
        push @$reasoning, "High-quality model suitable for complex tasks";
    } else {
        $scores->{resource_requirements} = 6;
        push @$reasoning, "Standard resource match";
    }
    
    # Availability scoring (check if endpoints are available)
    my $available_endpoints = 0;
    for my $endpoint (@{$model_info->{endpoints}}) {
        if ($self->_is_endpoint_available($endpoint, $context)) {
            $available_endpoints++;
        }
    }
    
    if ($available_endpoints > 0) {
        $scores->{availability} = 10;
        push @$reasoning, "$available_endpoints endpoint(s) available";
    } else {
        $scores->{availability} = 0;
        push @$reasoning, "No available endpoints";
    }
    
    # Cost efficiency scoring
    my $requirements = $request_spec->{requirements} || [];
    if (grep { $_ eq 'cost' } @$requirements) {
        my $cost_score = $model_info->{cost_tier} eq 'low' ? 10 : 
                        $model_info->{cost_tier} eq 'medium' ? 6 : 3;
        $scores->{cost_efficiency} = $cost_score;
        push @$reasoning, "Cost tier: " . $model_info->{cost_tier};
    } else {
        $scores->{cost_efficiency} = 7;  # Neutral when cost not a priority
    }
    
    # Calculate weighted total
    my $weights = {
        task_suitability => 0.4,
        performance_history => 0.2,
        resource_requirements => 0.2,
        availability => 0.15,
        cost_efficiency => 0.05,
    };
    
    my $total = 0;
    for my $category (keys %$scores) {
        $total += $scores->{$category} * $weights->{$category};
    }
    
    return {
        total => $total,
        breakdown => $scores,
        reasoning => $reasoning,
        weights => $weights,
    };
}

# Model Configuration
sub _generate_model_config {
    my ($self, $model_name, $model_info, $request_spec, $context, $options) = @_;
    
    my $config = {
        model => $model_name,
        temperature => 0.7,
        max_tokens => 2048,
        top_p => 0.9,
        frequency_penalty => 0.0,
        presence_penalty => 0.0,
    };
    
    # Adjust based on task type
    my $task_type = $request_spec->{task_type};
    if ($task_type eq 'editor') {
        # More deterministic for code editing
        $config->{temperature} = 0.3;
        $config->{top_p} = 0.8;
    } elsif ($task_type eq 'architect') {
        # More creative for architectural design
        $config->{temperature} = 0.8;
        $config->{max_tokens} = 4096;
    } elsif ($task_type eq 'analysis') {
        # Balanced for analysis
        $config->{temperature} = 0.5;
        $config->{top_p} = 0.9;
    }
    
    # Model-specific adjustments
    if ($model_name =~ /qwen/) {
        # Qwen models work well with slightly higher temperature
        $config->{temperature} += 0.1;
    } elsif ($model_name =~ /gpt-4/) {
        # GPT-4 can handle more tokens effectively
        $config->{max_tokens} = 8192 if $config->{max_tokens} < 8192;
    }
    
    # Context window considerations
    my $context_length = length($request_spec->{prompt} || '');
    if ($context_length > $model_info->{context_window} * 0.5) {
        # If prompt is using more than 50% of context window, reduce max_tokens
        $config->{max_tokens} = int($model_info->{context_window} * 0.3);
    }
    
    return $config;
}

# Prompt Optimization
sub _optimize_prompt_for_model {
    my ($self, $prompt, $model_name, $model_info, $options) = @_;
    
    my $optimized = $prompt;
    
    # Model-specific optimizations
    if ($model_name =~ /qwen.*coder/) {
        # Qwen coder models prefer explicit code context
        if ($prompt !~ /```/ && $prompt =~ /code|function|class|method/) {
            $optimized = "You are an expert programmer. $optimized\n\nPlease provide code examples where appropriate.";
        }
    } elsif ($model_name =~ /gpt-4/) {
        # GPT-4 benefits from structured thinking prompts
        if (length($prompt) > 500) {
            $optimized = "Think step by step:\n\n$optimized";
        }
    } elsif ($model_name =~ /github-copilot/) {
        # GitHub Copilot works best with direct, concise requests
        $optimized =~ s/please\s+//gi;
        $optimized =~ s/could you\s+//gi;
        $optimized =~ s/would you mind\s+//gi;
    }
    
    # Task-type optimizations
    if ($options->{task_type} eq 'architect') {
        $optimized = "As a software architect, $optimized\n\nConsider scalability, maintainability, and best practices.";
    } elsif ($options->{task_type} eq 'editor') {
        $optimized = "As a code editor, $optimized\n\nFocus on clean, working code with proper error handling.";
    }
    
    return $optimized;
}

# Utility Methods
sub _select_endpoint {
    my ($self, $endpoints, $context, $options) = @_;
    
    # Simple endpoint selection (could be enhanced with load balancing)
    for my $endpoint (@$endpoints) {
        if ($self->_is_endpoint_available($endpoint, $context)) {
            return $endpoint;
        }
    }
    
    return $endpoints->[0];  # Fallback to first endpoint
}

sub _is_endpoint_available {
    my ($self, $endpoint, $context) = @_;
    
    # Endpoint availability is now determined by provider configuration
    # All configured endpoints are considered available
    return 1;
}

sub _generate_request_id {
    my ($self) = @_;
    return sprintf("req_%d_%d", time(), int(rand(10000)));
}

sub _select_fallback_model {
    my ($self, $fallback_chain, $context, $options) = @_;
    
    for my $model (@$fallback_chain) {
        my $model_info = $self->{model_registry}->{$model};
        if ($model_info && $self->_is_model_available($model, $model_info, $context)) {
            return $model;
        }
    }
    
    # Ultimate fallback
    return 'qwen-coder';
}

sub _is_model_available {
    my ($self, $model_name, $model_info, $context) = @_;
    
    for my $endpoint (@{$model_info->{endpoints}}) {
        if ($self->_is_endpoint_available($endpoint, $context)) {
            return 1;
        }
    }
    
    return 0;
}

# Stub methods for advanced functionality
sub _explain_configuration { 
    my ($self, $config, $model_info, $request_spec) = @_;
    return "Configuration optimized for " . $request_spec->{task_type} . " tasks";
}

sub _get_optimization_details { return ['prompt_structure_improved', 'model_specific_formatting'] }
sub _estimate_improvement { return { quality => '+15%', speed => '+5%' } }
sub _record_performance { }
sub _get_performance_stats { return { success_rate => 0.95, avg_response_time => 1.2 } }
sub _analyze_performance_trends { return { trend => 'stable', recommendation => 'continue_current_usage' } }
sub _generate_performance_recommendations { return ['Monitor response times', 'Consider A/B testing'] }
sub _record_failure { }
sub _explain_fallback_choice { 
    my ($self, $fallback_model, $failed_model, $context) = @_;
    return "Selected $fallback_model as fallback for $failed_model due to similar capabilities";
}

1;

__END__

=head1 USAGE EXAMPLES

=head2 Model Selection

  [MODEL:action=select:request=<base64_request>:context=<base64_context>]
  
  Request JSON:
  {
    "task_type": "editor",
    "complexity": "moderate",
    "requirements": ["speed", "quality"]
  }

=head2 Model Configuration

  [MODEL:action=configure:request=<base64_request>:options=<base64_options>]
  
  Request JSON:
  {
    "model_name": "qwen3-coder-max",
    "task_type": "architect"
  }

=head2 Request Routing

  [MODEL:action=route:request=<base64_request>:context=<base64_context>]
  
  Request JSON:
  {
    "prompt": "Analyze this code for performance issues",
    "task_type": "analysis",
    "complexity": "complex"
  }

=head2 Prompt Optimization

  [MODEL:action=optimize:request=<base64_request>]
  
  Request JSON:
  {
    "prompt": "Write a function to sort an array",
    "model_name": "qwen3-coder-max"
  }

=head1 RETURN FORMAT

  {
    "success": true,
    "action": "select",
    "selected_model": "qwen3-coder-max",
    "model_info": {...},
    "selection_reasoning": [...],
    "confidence_score": 8.7,
    "alternatives": [...]
  }
1;
