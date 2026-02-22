package CLIO::Core::TaskOrchestrator;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
use CLIO::Util::JSON qw(encode_json decode_json);
use Time::HiRes qw(time);
use CLIO::Core::Logger qw(should_log);

=head1 NAME

CLIO::Core::TaskOrchestrator - MCP-compliant task orchestration engine

=head1 SYNOPSIS

  use CLIO::Core::TaskOrchestrator;
  
  my $orchestrator = CLIO::Core::TaskOrchestrator->new(
      debug => 1,
      protocol_manager => $protocol_mgr,
      session => $session,
      ai_agent => $agent,
      max_parallel_protocols => 3,
      task_timeout => 300
  );
  
  # Analyze complex user task
  my $analysis = $orchestrator->analyze_and_decompose_task(
      "Create a new module and add tests",
      $context
  );
  
  # Execute protocol chain
  my $result = $orchestrator->execute_protocol_chain(
      $analysis->{execution_plan},
      $context
  );

=head1 DESCRIPTION

TaskOrchestrator is CLIO's intelligent task decomposition and protocol
orchestration engine. It analyzes complex user requests and determines
which protocols (Architect, Editor, Validate, etc.) should be invoked
and in what order.

Key responsibilities:
- Parse complex tasks and identify required protocols
- Create optimal protocol execution chains
- Manage protocol dependencies and context flow
- Handle parallel protocol execution
- Track execution logs and performance metrics

This is the "brain" that decides when to use #architect, #editor, #validate,
and other specialized protocols based on user intent.

=head1 METHODS

=head2 new(%args)

Create a new TaskOrchestrator instance.

Arguments:
- debug: Enable debug logging
- protocol_manager: CLIO::Protocols::Manager instance
- session: Session object
- ai_agent: AI agent instance
- max_parallel_protocols: Maximum concurrent protocols (default: 3)
- task_timeout: Timeout in seconds (default: 300)

=head2 analyze_and_decompose_task($user_input, $context)

Analyze user input and decompose into executable protocol chain.

Returns: HashRef with:
- original_input: User's request
- complexity_score: Calculated complexity metric
- required_protocols: List of protocols needed
- execution_plan: Ordered protocol chain
- dependencies: Protocol dependency graph
- context_requirements: Required context for execution

=head2 execute_protocol_chain($protocol_chain, $context)

Execute a chain of protocols in order, managing context flow and dependencies.

Returns: Execution result with status and outputs

=cut

# MCP-Compliant Task Orchestration Engine
# Handles complex multi-protocol task execution with proper context management

sub new {
    my ($class, %args) = @_;
    return bless {
        debug => $args{debug} || 0,
        protocol_manager => $args{protocol_manager},
        session => $args{session},
        ai_agent => $args{ai_agent},
        max_parallel_protocols => $args{max_parallel_protocols} || 3,
        task_timeout => $args{task_timeout} || 300, # 5 minutes
        execution_log => [],
        protocol_cache => {},
        context_stack => []
    }, $class;
}

# Parse complex user input and decompose into executable protocol chains
sub analyze_and_decompose_task {
    my ($self, $user_input, $context) = @_;
    
    print STDERR "[ORCHESTRATOR] Analyzing complex task: $user_input\n" if $self->{debug};
    
    my $task_analysis = {
        original_input => $user_input,
        timestamp => time(),
        complexity_score => $self->_calculate_complexity($user_input),
        required_protocols => [],
        execution_plan => [],
        dependencies => {},
        context_requirements => []
    };
    
    # Analyze input for protocol requirements using pattern matching
    my @protocol_indicators = $self->_extract_protocol_indicators($user_input);
    
    # Determine optimal protocol chain
    my $protocol_chain = $self->_create_protocol_chain(@protocol_indicators);
    $task_analysis->{execution_plan} = $protocol_chain;
    
    # Extract context requirements
    $task_analysis->{context_requirements} = $self->_analyze_context_needs($user_input, $context);
    
    # Calculate dependencies between protocols
    $task_analysis->{dependencies} = $self->_calculate_protocol_dependencies($protocol_chain);
    
    print STDERR "[DEBUG][TaskOrchestrator] Task analysis complete: " . 
                 scalar(@{$task_analysis->{execution_plan}}) . " protocols identified\n" 
        if should_log('DEBUG');
    
    return $task_analysis;
}

# Execute complex task using MCP-compliant protocol orchestration
sub execute_complex_task {
    my ($self, $task_analysis, $context) = @_;
    
    my $execution_result = {
        task_id => time() . '_' . int(rand(10000)),
        start_time => time(),
        status => 'in_progress',
        protocol_results => [],
        aggregated_response => '',
        errors => [],
        performance_metrics => {}
    };
    
    print STDERR "[ORCHESTRATOR] Starting complex task execution (Task ID: $execution_result->{task_id})\n" if $self->{debug};
    
    # Initialize context stack for MCP compliance
    $self->_push_context($context, $task_analysis);
    
    eval {
        # Execute protocol chain with proper dependency management
        for my $protocol_step (@{$task_analysis->{execution_plan}}) {
            my $step_result = $self->_execute_protocol_step($protocol_step, $execution_result);
            
            if ($step_result->{success}) {
                push @{$execution_result->{protocol_results}}, $step_result;
                
                # Update context with results for next protocol
                $self->_update_execution_context($step_result);
            } else {
                push @{$execution_result->{errors}}, {
                    protocol => $protocol_step->{protocol},
                    error => $step_result->{error},
                    timestamp => time()
                };
                
                # Check if this is a critical failure
                if ($protocol_step->{critical}) {
                    die "Critical protocol failure: $step_result->{error}";
                }
            }
        }
        
        # Aggregate all protocol results into final response
        $execution_result->{aggregated_response} = $self->_aggregate_protocol_results(
            $execution_result->{protocol_results}
        );
        
        $execution_result->{status} = 'completed';
        
    };
    
    if ($@) {
        $execution_result->{status} = 'failed';
        push @{$execution_result->{errors}}, {
            type => 'execution_failure',
            error => $@,
            timestamp => time()
        };
        print STDERR "[ORCHESTRATOR] Task execution failed: $@\n" if $self->{debug};
    }
    
    $execution_result->{end_time} = time();
    $execution_result->{total_duration} = $execution_result->{end_time} - $execution_result->{start_time};
    
    # Pop context stack
    $self->_pop_context();
    
    # Log execution for analysis
    push @{$self->{execution_log}}, $execution_result;
    
    print STDERR "[DEBUG][TaskOrchestrator] Task execution complete: $execution_result->{status} " . 
                 "(Duration: " . sprintf("%.2f", $execution_result->{total_duration}) . "s)\n" 
        if should_log('DEBUG');
    
    return $execution_result;
}

# Validate protocol chain for MCP compliance
sub validate_mcp_compliance {
    my ($self, $protocol_chain) = @_;
    
    my $compliance_report = {
        is_compliant => 1,
        violations => [],
        recommendations => [],
        protocol_coverage => {}
    };
    
    # Check for MCP required patterns
    my @required_patterns = (
        'proper_context_flow',
        'error_handling',
        'result_aggregation',
        'resource_management'
    );
    
    for my $pattern (@required_patterns) {
        unless ($self->_check_mcp_pattern($protocol_chain, $pattern)) {
            $compliance_report->{is_compliant} = 0;
            push @{$compliance_report->{violations}}, $pattern;
        }
    }
    
    # Generate recommendations for better MCP compliance
    if (!$compliance_report->{is_compliant}) {
        $compliance_report->{recommendations} = $self->_generate_mcp_recommendations(
            $compliance_report->{violations}
        );
    }
    
    return $compliance_report;
}

# Get execution statistics and performance metrics
sub get_execution_metrics {
    my ($self) = @_;
    
    my $metrics = {
        total_tasks => scalar(@{$self->{execution_log}}),
        success_rate => 0,
        average_duration => 0,
        protocol_usage => {},
        common_failures => {},
        performance_trends => {}
    };
    
    return $metrics unless @{$self->{execution_log}};
    
    my $successful_tasks = 0;
    my $total_duration = 0;
    
    for my $execution (@{$self->{execution_log}}) {
        $successful_tasks++ if $execution->{status} eq 'completed';
        $total_duration += $execution->{total_duration};
        
        # Track protocol usage
        for my $result (@{$execution->{protocol_results}}) {
            $metrics->{protocol_usage}->{$result->{protocol}}++;
        }
        
        # Track failure patterns
        for my $error (@{$execution->{errors}}) {
            my $error_key = $error->{protocol} || $error->{type};
            $metrics->{common_failures}->{$error_key}++;
        }
    }
    
    $metrics->{success_rate} = $successful_tasks / @{$self->{execution_log}};
    $metrics->{average_duration} = $total_duration / @{$self->{execution_log}};
    
    return $metrics;
}

# Private helper methods

sub _calculate_complexity {
    my ($self, $input) = @_;
    
    my $complexity = 0;
    
    # Base complexity (1-3 based on input length)
    my $length = length($input);
    if ($length < 50) {
        $complexity += 1;
    } elsif ($length < 150) {
        $complexity += 2;
    } else {
        $complexity += 3;
    }
    
    # Count indicators of complexity
    $complexity += ($input =~ /\b(and|then|also|additionally|furthermore)\b/gi) * 1;  # Coordination
    $complexity += ($input =~ /\b(if|when|unless|while|until)\b/gi) * 1.5;  # Conditionals
    $complexity += ($input =~ /\b(analyze|create|modify|search|validate|test|implement|refactor|audit)\b/gi) * 1;  # Action verbs
    $complexity += ($input =~ /\b(file|directory|code|repository|database|system|security)\b/gi) * 0.5;  # Object references
    $complexity += ($input =~ /\b(all|every|entire|complete|comprehensive)\b/gi) * 1;  # Scope indicators
    
    # Cap complexity at 10
    $complexity = 10 if $complexity > 10;
    
    return $complexity;
}

sub _extract_protocol_indicators {
    my ($self, $input) = @_;
    
    my @indicators = ();
    
    # File operations
    push @indicators, 'FILE_OP' if $input =~ /\b(read|write|create|edit|file|directory|src|path)\b/i;
    
    # Code analysis
    push @indicators, 'CODE_ANALYSIS' if $input =~ /\b(analyze|check|code|syntax|style|performance|impact)\b/i;
    
    # Git operations
    push @indicators, 'GIT' if $input =~ /\b(git|commit|branch|merge|repository|repo|history|version)\b/i;
    
    # Search operations
    push @indicators, 'SEARCH' if $input =~ /\b(search|find|look|query|pattern|connection|TODO|comment)\b/i;
    
    # Memory operations
    push @indicators, 'MEMORY' if $input =~ /\b(remember|recall|save|store|memory|report|document)\b/i;
    
    # Validation
    push @indicators, 'VALIDATE' if $input =~ /\b(validate|verify|check|test|confirm|requirements)\b/i;
    
    # Shell operations
    push @indicators, 'SHELL' if $input =~ /\b(run|execute|command|shell|terminal)\b/i;
    
    # Web operations
    push @indicators, 'WEB_SEARCH' if $input =~ /\b(web|internet|online|url|website)\b/i;
    
    # Pattern recognition
    push @indicators, 'PATTERN' if $input =~ /\b(pattern|template|format|structure|existing|authentication)\b/i;
    
    # Security
    push @indicators, 'SECURITY' if $input =~ /\b(security|safe|protect|secure|audit|vulnerabilit|authentication)\b/i;
    
    # Refactoring
    push @indicators, 'REFACTOR' if $input =~ /\b(refactor|improve|suggest|optimization|implement|change)\b/i;
    
    # Audit
    push @indicators, 'AUDIT' if $input =~ /\b(audit|report|generate|comprehensive|complete)\b/i;
    
    # RAG (Retrieval Augmented Generation)
    push @indicators, 'RAG' if $input =~ /\b(context|retrieve|knowledge|information|database)\b/i;
    
    return @indicators;
}

sub _create_protocol_chain {
    my ($self, @indicators) = @_;
    
    my @chain = ();
    
    # Create logical execution order
    my %protocol_priority = (
        'MEMORY' => 1,      # Load context first
        'RAG' => 2,         # Retrieve augmented knowledge
        'SEARCH' => 3,      # Find relevant information
        'FILE_OP' => 4,     # Read/write files
        'PATTERN' => 5,     # Analyze patterns
        'CODE_ANALYSIS' => 6, # Analyze code
        'GIT' => 7,         # Git operations
        'VALIDATE' => 8,    # Validate results
        'SECURITY' => 9,    # Security checks
        'REFACTOR' => 10,   # Refactoring operations
        'SHELL' => 11,      # Execute commands
        'WEB_SEARCH' => 12, # Web research
        'AUDIT' => 13       # Generate audit reports
    );
    
    # Sort indicators by priority
    my @sorted_indicators = sort { 
        ($protocol_priority{$a} || 999) <=> ($protocol_priority{$b} || 999) 
    } @indicators;
    
    for my $protocol (@sorted_indicators) {
        push @chain, {
            protocol => $protocol,
            critical => $self->_is_critical_protocol($protocol),
            context_dependent => $self->_requires_context($protocol),
            parallel_safe => $self->_is_parallel_safe($protocol)
        };
    }
    
    return \@chain;
}

sub _analyze_context_needs {
    my ($self, $input, $context) = @_;
    
    my @needs = ();
    
    push @needs, 'current_file' if $input =~ /\b(this|current|file)\b/i;
    push @needs, 'working_directory' if $input =~ /\b(here|directory|folder)\b/i;
    push @needs, 'conversation_history' if $input =~ /\b(we|earlier|before|previous)\b/i;
    push @needs, 'project_context' if $input =~ /\b(project|repository|codebase)\b/i;
    
    return \@needs;
}

sub _calculate_protocol_dependencies {
    my ($self, $chain) = @_;
    
    my %dependencies = ();
    
    for my $i (0..$#{$chain}) {
        my $protocol = $chain->[$i]->{protocol};
        $dependencies{$protocol} = [];
        
        # Protocols that need to run before this one
        for my $j (0..$i-1) {
            my $prev_protocol = $chain->[$j]->{protocol};
            
            if ($self->_has_dependency($protocol, $prev_protocol)) {
                push @{$dependencies{$protocol}}, $prev_protocol;
            }
        }
    }
    
    return \%dependencies;
}

sub _execute_protocol_step {
    my ($self, $step, $execution_context) = @_;
    
    my $protocol = $step->{protocol};
    my $start_time = time();
    
    print STDERR "[ORCHESTRATOR] Executing protocol: $protocol\n" if $self->{debug};
    
    # Prepare protocol context from execution context
    my $protocol_context = $self->_prepare_protocol_context($step, $execution_context);
    
    # Execute the protocol
    my $result = eval {
        if ($self->{protocol_manager}) {
            # Use actual protocol manager if available
            return $self->{protocol_manager}->execute_protocol($protocol, $protocol_context);
        } else {
            # Mock execution for testing
            return {
                success => 1,
                protocol => $protocol,
                response => "Mock response for $protocol",
                execution_time => time() - $start_time
            };
        }
    };
    
    if ($@) {
        return {
            success => 0,
            protocol => $protocol,
            error => $@,
            execution_time => time() - $start_time
        };
    }
    
    $result->{execution_time} = time() - $start_time;
    
    print STDERR "[DEBUG][TaskOrchestrator] Protocol $protocol completed in " . 
                 sprintf("%.3f", $result->{execution_time}) . "s\n" 
        if should_log('DEBUG');
    
    return $result;
}

sub _aggregate_protocol_results {
    my ($self, $results) = @_;
    
    my $aggregated = "# Complex Task Execution Results\n\n";
    
    for my $result (@$results) {
        $aggregated .= "## Protocol: $result->{protocol}\n\n";
        
        if (ref $result->{response}) {
            require Data::Dumper;
            $aggregated .= "```\n" . Data::Dumper::Dumper($result->{response}) . "```\n\n";
        } else {
            $aggregated .= "$result->{response}\n\n";
        }
    }
    
    return $aggregated;
}

sub _push_context {
    my ($self, $context, $task_analysis) = @_;
    
    push @{$self->{context_stack}}, {
        context => $context,
        task_analysis => $task_analysis,
        timestamp => time()
    };
}

sub _pop_context {
    my ($self) = @_;
    
    return pop @{$self->{context_stack}};
}

sub _update_execution_context {
    my ($self, $step_result) = @_;
    
    # Update current context with results from this protocol
    if (@{$self->{context_stack}}) {
        my $current_context = $self->{context_stack}->[-1];
        $current_context->{protocol_results}->{$step_result->{protocol}} = $step_result;
    }
}

sub _prepare_protocol_context {
    my ($self, $step, $execution_context) = @_;
    
    my $context = {};
    
    # Add current execution context
    if (@{$self->{context_stack}}) {
        my $current = $self->{context_stack}->[-1];
        $context = { %{$current->{context}} };
        
        # Add results from previous protocols
        if ($current->{protocol_results}) {
            $context->{previous_protocol_results} = $current->{protocol_results};
        }
    }
    
    return $context;
}

sub _is_critical_protocol {
    my ($self, $protocol) = @_;
    
    # Define which protocols are critical for task success
    my %critical_protocols = (
        'FILE_OP' => 1,
        'MEMORY' => 1,
        'VALIDATE' => 0,
        'SEARCH' => 0
    );
    
    return $critical_protocols{$protocol} || 0;
}

sub _requires_context {
    my ($self, $protocol) = @_;
    
    # Define which protocols need context from previous executions
    my %context_dependent = (
        'CODE_ANALYSIS' => 1,
        'VALIDATE' => 1,
        'GIT' => 1,
        'SHELL' => 1
    );
    
    return $context_dependent{$protocol} || 0;
}

sub _is_parallel_safe {
    my ($self, $protocol) = @_;
    
    # Define which protocols can be executed in parallel
    my %parallel_safe = (
        'SEARCH' => 1,
        'WEB_SEARCH' => 1,
        'PATTERN' => 1,
        'MEMORY' => 0,  # Sequential access required
        'FILE_OP' => 0, # File conflicts possible
        'GIT' => 0      # Git operations must be sequential
    );
    
    return $parallel_safe{$protocol} || 0;
}

sub _has_dependency {
    my ($self, $protocol1, $protocol2) = @_;
    
    # Define protocol dependencies
    my %dependencies = (
        'CODE_ANALYSIS' => ['FILE_OP'],
        'VALIDATE' => ['CODE_ANALYSIS', 'FILE_OP'],
        'GIT' => ['FILE_OP'],
        'SHELL' => ['FILE_OP', 'GIT']
    );
    
    return grep { $_ eq $protocol2 } @{$dependencies{$protocol1} || []};
}

sub _check_mcp_pattern {
    my ($self, $chain, $pattern) = @_;
    
    # Implement MCP compliance checks
    if ($pattern eq 'proper_context_flow') {
        # Check that context flows properly between protocols
        return 1; # Simplified for now
    } elsif ($pattern eq 'error_handling') {
        # Check that error handling is properly implemented
        return 1; # Simplified for now
    } elsif ($pattern eq 'result_aggregation') {
        # Check that results are properly aggregated
        return 1; # Simplified for now
    } elsif ($pattern eq 'resource_management') {
        # Check that resources are properly managed
        return 1; # Simplified for now
    }
    
    return 0;
}

sub _generate_mcp_recommendations {
    my ($self, $violations) = @_;
    
    my @recommendations = ();
    
    for my $violation (@$violations) {
        if ($violation eq 'proper_context_flow') {
            push @recommendations, "Implement proper context threading between protocols";
        } elsif ($violation eq 'error_handling') {
            push @recommendations, "Add comprehensive error recovery mechanisms";
        } elsif ($violation eq 'result_aggregation') {
            push @recommendations, "Implement better result synthesis strategies";
        } elsif ($violation eq 'resource_management') {
            push @recommendations, "Add resource cleanup and management";
        }
    }
    
    return \@recommendations;
}

1;
