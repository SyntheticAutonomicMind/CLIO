#!/usr/bin/env perl

package CLIO::NaturalLanguage::TaskProcessor;

use strict;
use warnings;
use utf8;
use CLIO::Util::JSON qw(encode_json decode_json);

=head1 NAME

CLIO::NaturalLanguage::TaskProcessor - Natural language task processing for CLIO

=head1 DESCRIPTION

This module processes natural language requests and breaks them down into
executable protocol chains. It supports complex multi-step tasks like
"Clone github.com/user/repo and analyze the code" or 
"Research diabetes breakthroughs from 2024".

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        protocol_manager => $args{protocol_manager},
        debug => $args{debug} || 0,
        task_templates => {},
        confidence_threshold => 0.3,
    };
    
    bless $self, $class;
    $self->initialize_task_templates();
    return $self;
}

# Initialize common task templates
sub initialize_task_templates {
    my ($self) = @_;
    
    $self->{task_templates} = {
        git_operations => {
            patterns => [
                qr/clone\s+.*github\.com/i,
                qr/clone\s+.*gitlab\.com/i,
                qr/clone\s+.*bitbucket\.org/i,
                qr/git\s+clone/i,
                qr/download.*repository/i,
                qr/get.*source.*code/i,
            ],
            protocols => ['GitProtocol'],
            examples => ['clone github.com/user/repo', 'download repository from github'],
        },
        
        web_research => {
            patterns => [
                qr/research/i,
                qr/search.*for/i,
                qr/find.*information/i,
                qr/look.*up/i,
                qr/investigate/i,
                qr/study/i,
                qr/learn.*about/i,
            ],
            protocols => ['WebSearchProtocol'],
            examples => ['research diabetes treatments', 'search for AI breakthroughs'],
        },
        
        code_analysis => {
            patterns => [
                qr/analyze.*code/i,
                qr/review.*code/i,
                qr/examine.*source/i,
                qr/code.*review/i,
                qr/security.*audit/i,
                qr/vulnerability.*scan/i,
                qr/static.*analysis/i,
            ],
            protocols => ['CodeAnalysisProtocol', 'SecurityProtocol'],
            examples => ['analyze the code', 'review security vulnerabilities'],
        },
        
        file_operations => {
            patterns => [
                qr/read.*file/i,
                qr/write.*to.*file/i,
                qr/create.*file/i,
                qr/edit.*file/i,
                qr/save.*to/i,
                qr/open.*file/i,
            ],
            protocols => ['FileProtocol'],
            examples => ['read config.txt', 'create new file', 'save results to output.txt'],
        },
        
        system_operations => {
            patterns => [
                qr/compile/i,
                qr/build/i,
                qr/install/i,
                qr/update.*kernel/i,
                qr/run.*command/i,
                qr/execute/i,
                qr/shell/i,
            ],
            protocols => ['ShellProtocol'],
            examples => ['compile the project', 'update kernel to version 6.12.40'],
        },
        
        data_processing => {
            patterns => [
                qr/parse.*data/i,
                qr/extract.*information/i,
                qr/process.*file/i,
                qr/format.*output/i,
                qr/convert/i,
                qr/transform/i,
            ],
            protocols => ['DataProcessingProtocol'],
            examples => ['parse JSON data', 'convert CSV to XML'],
        },
        
        multi_step_workflows => {
            patterns => [
                qr/(.+)\s+and\s+(.+)/i,
                qr/(.+),\s*then\s+(.+)/i,
                qr/(.+);\s*(.+)/i,
                qr/first\s+(.+),?\s*then\s+(.+)/i,
                qr/after\s+(.+),\s*(.+)/i,
            ],
            is_compound => 1,
            examples => ['clone repo and analyze code', 'research topic, then summarize findings'],
        }
    };
}

# Main processing function
sub process_natural_language {
    my ($self, $input, $context) = @_;
    
    print STDERR "[NL] Processing: $input\n" if $self->{debug};
    
    # Normalize input
    $input = $self->normalize_input($input);
    
    # Check for compound tasks first
    if (my $compound_tasks = $self->detect_compound_tasks($input)) {
        return $self->process_compound_tasks($compound_tasks, $context);
    }
    
    # Single task processing
    my $task_analysis = $self->analyze_task($input);
    
    if (!$task_analysis->{confidence} || $task_analysis->{confidence} < $self->{confidence_threshold}) {
        print STDERR "[NL] Low confidence: " . $task_analysis->{confidence} . "\n" if $self->{debug};
        return $self->fallback_processing($input, $context);
    }
    
    return $self->execute_task_plan($task_analysis, $context);
}

# Normalize input for better processing
sub normalize_input {
    my ($self, $input) = @_;
    
    # Remove extra whitespace
    $input =~ s/\s+/ /g;
    $input =~ s/^\s+|\s+$//g;
    
    # Normalize common variations
    $input =~ s/\brepository\b/repo/gi;
    $input =~ s/\bapplication\b/app/gi;
    $input =~ s/\bdirectory\b/dir/gi;
    $input =~ s/\bexamine\b/analyze/gi;
    
    return $input;
}

# Detect compound tasks (multiple steps)
sub detect_compound_tasks {
    my ($self, $input) = @_;
    
    my $compound_template = $self->{task_templates}->{multi_step_workflows};
    
    for my $pattern (@{$compound_template->{patterns}}) {
        if ($input =~ /$pattern/) {
            my @parts = ($1, $2);
            print STDERR "[NL] Detected compound task: " . join(" -> ", @parts) . "\n" if $self->{debug};
            return \@parts;
        }   
    }
    
    # Also check for explicit separators
    if ($input =~ /[;,]/ && $input !~ /^(https?|git@|ftp):/i) {
        my @parts = split /[;,]\s*/, $input;
        if (@parts > 1) {
            print STDERR "[NL] Detected separated compound task: " . join(" -> ", @parts) . "\n" if $self->{debug};
            return \@parts;
        }
    }
    
    return undef;
}

# Process compound (multi-step) tasks
sub process_compound_tasks {
    my ($self, $tasks, $context) = @_;
    
    my @execution_plan;
    my $overall_context = { %$context };
    
    for my $i (0..$#{$tasks}) {
        my $task = $tasks->[$i];
        my $task_analysis = $self->analyze_task($task);
        
        # Add dependency information
        $task_analysis->{step_number} = $i + 1;
        $task_analysis->{total_steps} = scalar @$tasks;
        $task_analysis->{depends_on_previous} = $i > 0;
        
        push @execution_plan, $task_analysis;
    }
    
    return {
        type => 'compound_task',
        steps => \@execution_plan,
        protocols_needed => $self->collect_protocols_from_plan(\@execution_plan),
        estimated_time => $self->estimate_execution_time(\@execution_plan),
        confidence => $self->calculate_overall_confidence(\@execution_plan),
    };
}

# Analyze individual task
sub analyze_task {
    my ($self, $task) = @_;
    
    my %scores;
    my @matched_categories;
    
    # Score against each template
    for my $category (keys %{$self->{task_templates}}) {
        next if $category eq 'multi_step_workflows';
        
        my $template = $self->{task_templates}->{$category};
        my $score = 0;
        my @pattern_matches;
        
        for my $pattern (@{$template->{patterns}}) {
            if ($task =~ /$pattern/) {
                $score += 0.5;  # Increased from 0.3
                push @pattern_matches, $pattern;
            }
        }
        
        # Bonus for multiple pattern matches
        if (@pattern_matches > 1) {
            $score += 0.3;  # Increased from 0.2
        }
        
        # Context-aware scoring
        $score += $self->context_score($task, $template);
        
        if ($score > 0) {
            $scores{$category} = $score;
            push @matched_categories, $category;
        }
    }
    
    # Find best match
    my $best_category = (sort { $scores{$b} <=> $scores{$a} } keys %scores)[0];
    
    if (!$best_category) {
        return {
            type => 'unknown',
            confidence => 0,
            protocols => [],
            task => $task,
        };
    }
    
    my $template = $self->{task_templates}->{$best_category};
    
    return {
        type => $best_category,
        confidence => $scores{$best_category},
        protocols => $template->{protocols} || [],
        task => $task,
        original_input => $task,
        parameters => $self->extract_parameters($task, $best_category),
        all_matches => \%scores,
    };
}

# Context-aware scoring improvements
sub context_score {
    my ($self, $task, $template) = @_;
    
    my $bonus = 0;
    
    # URL detection
    if ($task =~ /https?:\/\/|git@|\.git\b/) {
        $bonus += 0.2 if grep { $_ eq 'GitProtocol' } @{$template->{protocols} || []};
    }
    
    # File extension detection
    if ($task =~ /\.(js|py|pl|cpp|java|go|rs)\b/) {
        $bonus += 0.1 if grep { $_ eq 'CodeAnalysisProtocol' } @{$template->{protocols} || []};
    }
    
    # Path detection
    if ($task =~ /\/\w+/ || $task =~ /\w+\/\w+/) {
        $bonus += 0.1 if grep { $_ eq 'FileProtocol' } @{$template->{protocols} || []};
    }
    
    return $bonus;
}

# Extract parameters from tasks
sub extract_parameters {
    my ($self, $task, $category) = @_;
    
    my %params;
    
    if ($category eq 'git_operations') {
        if ($task =~ /(https?:\/\/[^\s]+|git@[^\s]+)/i) {
            $params{repository_url} = $1;
        }
        if ($task =~ /clone.*?([a-zA-Z0-9._\/-]+)(?:\s|$)/i) {
            $params{repository_name} = $1;
        }
    }
    
    if ($category eq 'web_research') {
        if ($task =~ /(?:research|search|find|investigate)\s+(.+?)(?:\s+from|\s+in|\s*$)/i) {
            $params{search_query} = $1;
        }
        if ($task =~ /from\s+(\d{4})/i) {
            $params{time_filter} = $1;
        }
    }
    
    if ($category eq 'system_operations') {
        if ($task =~ /update.*kernel.*to.*version\s+([\d\.]+)/i) {
            $params{kernel_version} = $1;
        }
        if ($task =~ /install\s+(.+?)(?:\s|$)/i) {
            $params{package_name} = $1;
        }
    }
    
    if ($category eq 'file_operations') {
        if ($task =~ /(?:read|open|edit)\s+(.+?)(?:\s|$)/i) {
            $params{filename} = $1;
        }
        if ($task =~ /(?:save|write).*?to\s+(.+?)(?:\s|$)/i) {
            $params{output_file} = $1;
        }
    }
    
    return \%params;
}

# Execute task plan
sub execute_task_plan {
    my ($self, $task_analysis, $context) = @_;
    
    if ($task_analysis->{type} eq 'compound_task') {
        return $self->execute_compound_plan($task_analysis, $context);
    }
    
    return $self->execute_single_task($task_analysis, $context);
}

# Execute single task
sub execute_single_task {
    my ($self, $task_analysis, $context) = @_;
    
    my $protocols = $task_analysis->{protocols};
    
    if (!@$protocols) {
        return {
            success => 0,
            error => "No suitable protocols found for task type: " . $task_analysis->{type},
            task_analysis => $task_analysis,
        };
    }
    
    # Create protocol chain
    my @protocol_chain;
    for my $protocol_name (@$protocols) {
        my $protocol_class = "CLIO::Protocol::$protocol_name";
        
        eval "require $protocol_class";
        if ($@) {
            print STDERR "[NL] Warning: Could not load $protocol_class: $@\n" if $self->{debug};
            next;
        }
        
        my $protocol = $protocol_class->new();
        push @protocol_chain, {
            name => $protocol_name,
            instance => $protocol,
            parameters => $task_analysis->{parameters},
        };
    }
    
    if (!@protocol_chain) {
        return {
            success => 0,
            error => "No protocols could be loaded",
            task_analysis => $task_analysis,
        };
    }
    
    # Execute protocol chain
    return $self->execute_protocol_chain(\@protocol_chain, $context, $task_analysis);
}

# Execute compound task plan
sub execute_compound_plan {
    my ($self, $plan, $context) = @_;
    
    my @results;
    my $current_context = { %$context };
    
    for my $step (@{$plan->{steps}}) {
        print STDERR "[NL] Executing step " . $step->{step_number} . ": " . $step->{task} . "\n" if $self->{debug};
        
        my $step_result = $self->execute_single_task($step, $current_context);
        push @results, $step_result;
        
        # Update context with results for next step
        if ($step_result->{success}) {
            $current_context->{previous_step_result} = $step_result;
            $current_context->{step_number} = $step->{step_number};
            
            # Pass along any created files or data
            if ($step_result->{created_files}) {
                $current_context->{available_files} = [
                    @{$current_context->{available_files} || []},
                    @{$step_result->{created_files}}
                ];
            }
        } else {
            # Stop on failure unless configured otherwise
            last unless $plan->{continue_on_failure};
        }
    }
    
    return {
        success => !grep { !$_->{success} } @results,
        type => 'compound_task',
        step_results => \@results,
        final_context => $current_context,
        protocols_used => [map { @{$_->{protocols_used} || []} } @results],
    };
}

# Execute protocol chain
sub execute_protocol_chain {
    my ($self, $protocol_chain, $context, $task_analysis) = @_;
    
    my @results;
    my $chain_context = { %$context };
    
    for my $protocol_info (@$protocol_chain) {
        my $protocol = $protocol_info->{instance};
        my $params = $protocol_info->{parameters} || {};
        
        # Merge task parameters with context
        my $execution_params = {
            %$chain_context,
            %$params,
            task => $task_analysis->{task},
            original_input => $task_analysis->{original_input},
        };
        
        print STDERR "[NL] Executing protocol: " . $protocol_info->{name} . "\n" if $self->{debug};
        
        my $result = $protocol->execute($execution_params);
        push @results, {
            protocol => $protocol_info->{name},
            result => $result,
            success => $result->{success} || 0,
        };
        
        # Update context for next protocol
        if ($result->{success}) {
            $chain_context->{previous_result} = $result;
        }
    }
    
    my $overall_success = !grep { !$_->{success} } @results;
    my $final_response = $self->synthesize_response(\@results, $task_analysis);
    
    return {
        success => $overall_success,
        protocols_used => [map { $_->{protocol} } @results],
        protocol_results => \@results,
        final_response => $final_response,
        task_analysis => $task_analysis,
    };
}

# Synthesize final response from protocol results
sub synthesize_response {
    my ($self, $results, $task_analysis) = @_;
    
    my @response_parts;
    
    # Add task summary
    push @response_parts, "Task: " . $task_analysis->{task};
    
    # Add results from each protocol
    for my $result (@$results) {
        if ($result->{success} && $result->{result}->{response}) {
            push @response_parts, "\n" . $result->{protocol} . " result:";
            push @response_parts, $result->{result}->{response};
        } elsif (!$result->{success}) {
            push @response_parts, "\n" . $result->{protocol} . " failed: " . 
                                ($result->{result}->{error} || "Unknown error");
        }
    }
    
    return join("\n", @response_parts);
}

# Fallback processing for unrecognized tasks
sub fallback_processing {
    my ($self, $input, $context) = @_;
    
    # Try basic web search if it looks like a question
    if ($input =~ /\?|what|how|when|where|who|why/i) {
        return {
            type => 'web_search_fallback',
            protocols => ['WebSearchProtocol'],
            confidence => 0.3,
            task => $input,
            parameters => { search_query => $input },
        };
    }
    
    # Try code analysis if it mentions files or code
    if ($input =~ /\.(?:js|py|pl|cpp|java|go|rs|txt|md)\b|code|file/i) {
        return {
            type => 'file_analysis_fallback',
            protocols => ['FileProtocol', 'CodeAnalysisProtocol'],
            confidence => 0.3,
            task => $input,
            parameters => {},
        };
    }
    
    return {
        success => 0,
        error => "Could not understand the request: $input",
        confidence => 0,
        suggestion => "Try being more specific, or use commands like 'search for X', 'analyze file Y', or 'clone repository Z'",
    };
}

# Helper functions
sub collect_protocols_from_plan {
    my ($self, $plan) = @_;
    my %protocols;
    for my $step (@$plan) {
        for my $protocol (@{$step->{protocols} || []}) {
            $protocols{$protocol} = 1;
        }
    }
    return [keys %protocols];
}

sub estimate_execution_time {
    my ($self, $plan) = @_;
    # Simple heuristic: 5 seconds per step
    return scalar(@$plan) * 5;
}

sub calculate_overall_confidence {
    my ($self, $plan) = @_;
    return 0 unless @$plan;
    
    my $total = 0;
    for my $step (@$plan) {
        $total += $step->{confidence} || 0;
    }
    return $total / @$plan;
}

1;

=head1 AUTHOR

Fewtarius

=head1 COPYRIGHT

Copyright (c) 2025 CLIO Project. All rights reserved.

=cut

1;
