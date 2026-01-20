package CLIO::Core::AIAgent;

use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
use CLIO::Core::ProtocolIntegration;
use CLIO::Core::TaskOrchestrator;
use CLIO::Core::NaturalLanguage;
use CLIO::Core::Logger qw(should_log);

=head1 NAME

CLIO::Core::AIAgent - Enhanced AI agent with automatic protocol integration

=head1 DESCRIPTION

This module wraps the AI API calls with intelligent protocol integration,
ensuring that appropriate protocols are automatically invoked based on
user requests and context.

=head1 FEATURES

- Automatic protocol detection and execution
- Pre-processing of user requests with protocol augmentation
- Post-processing of AI responses with protocol integration
- Context-aware protocol selection
- Fallback handling for protocol failures

=cut

sub new {
    my ($class, %opts) = @_;
    
    my $self = {
        debug => $opts{debug} || 0,
        session => $opts{session},
        api => $opts{api},
        protocol_integration => CLIO::Core::ProtocolIntegration->new(
            debug => $opts{debug} || 0,
            session => $opts{session}
        ),
        task_orchestrator => CLIO::Core::TaskOrchestrator->new(
            debug => $opts{debug} || 0,
            session => $opts{session},
            protocol_manager => undef  # Will be set when available
        ),
        natural_language_processor => CLIO::Core::NaturalLanguage->new(
            debug => $opts{debug} || 0
        ),
        last_protocol_results => {},
        integration_mode => $opts{integration_mode} || 'automatic',
        complexity_threshold => $opts{complexity_threshold} || 10,
        enable_natural_language => $opts{enable_natural_language} // 1,
    };
    return bless $self, $class;
}

=head2 process_user_request

Process a user request with automatic protocol integration.

    my $response = $agent->process_user_request($user_input, $context);

=cut

sub process_user_request {
    my ($self, $user_input, $context) = @_;
    
    $context ||= {};
    my $result = {
        original_input => $user_input,
        protocol_results => {},
        ai_response => '',
        final_response => '',
        protocols_used => [],
        processing_time => time(),
        success => 1,
        errors => [],
        execution_type => 'simple',
        task_complexity => 0
    };
    
    print STDERR "[DEBUG][AIAgent] Processing request: '$user_input'\n" if should_log('DEBUG');
    
    # Step 0: Try natural language processing first if enabled
    if ($self->{enable_natural_language}) {
        print STDERR "[DEBUG][AIAgent] Attempting natural language processing\n" if should_log('DEBUG');
        
        my $nl_result = $self->{natural_language_processor}->process_natural_language($user_input, $context);
        
        if ($nl_result && $nl_result->{success}) {
            print STDERR "[DEBUG][AIAgent] Natural language processing successful\n" if should_log('DEBUG');
            $result->{execution_type} = 'natural_language';
            $result->{protocols_used} = $nl_result->{protocols_used} || [];
            $result->{final_response} = $nl_result->{final_response};
            $result->{natural_language_result} = $nl_result;
            return $result;
        } elsif ($nl_result && $nl_result->{confidence} && $nl_result->{confidence} > 0.3) {
            # Partial match - use for protocol guidance but continue with normal processing
            print STDERR "[DEBUG][AIAgent] Partial natural language match, using for guidance\n" if should_log('DEBUG');
            $context->{natural_language_hint} = $nl_result;
        }
    }
    
    # Step 1: Analyze task complexity for orchestration decision
    my $task_analysis = $self->{task_orchestrator}->analyze_and_decompose_task($user_input, $context);
    $result->{task_complexity} = $task_analysis->{complexity_score};
    
    # Step 2: Determine execution strategy based on complexity
    if ($task_analysis->{complexity_score} >= $self->{complexity_threshold}) {
        print STDERR "[DEBUG][AIAgent] High complexity detected (" . $task_analysis->{complexity_score} . "), using task orchestration\n" if should_log('DEBUG');
        
        # Use complex task orchestration
        $result->{execution_type} = 'complex';
        my $orchestration_result = $self->{task_orchestrator}->execute_complex_task($task_analysis, $context);
        
        if ($orchestration_result->{status} eq 'completed') {
            $result->{protocol_results} = {
                responses => $orchestration_result->{protocol_results},
                executed_protocols => [map { $_->{protocol} } @{$orchestration_result->{protocol_results}}]
            };
            $result->{protocols_used} = $result->{protocol_results}->{executed_protocols};
            $result->{ai_response} = $orchestration_result->{aggregated_response};
            $result->{final_response} = $self->_create_enhanced_prompt($user_input, $result->{protocol_results});
            
            # Add orchestration metadata
            $result->{orchestration_metadata} = {
                task_id => $orchestration_result->{task_id},
                execution_time => $orchestration_result->{total_duration},
                protocols_executed => scalar(@{$orchestration_result->{protocol_results}}),
                mcp_compliant => 1
            };
        } else {
            # Fallback to simple protocol integration if orchestration fails
            print STDERR "[DEBUG][AIAgent] Orchestration failed, falling back to simple integration\n" if should_log('DEBUG');
            push @{$result->{errors}}, "Task orchestration failed: " . join("; ", map { $_->{error} } @{$orchestration_result->{errors}});
            return $self->_execute_simple_protocol_integration($user_input, $context, $result);
        }
    } else {
        print STDERR "[DEBUG][AIAgent] Low complexity (" . $task_analysis->{complexity_score} . "), using simple integration\n" if should_log('DEBUG');
        
        # Use simple protocol integration for low-complexity tasks
        return $self->_execute_simple_protocol_integration($user_input, $context, $result);
    }
    
    # Step 3: Process with AI model using accumulated context
    my $enhanced_prompt = $self->_create_enhanced_prompt($user_input, $result->{protocol_results});
    $result->{ai_response} = $self->_process_with_model($enhanced_prompt, $context);
    
    # Step 4: Finalize response and store context
    $result->{final_response} = $result->{ai_response};
    $result->{processing_time} = time() - $result->{processing_time};
    
    print STDERR "[DEBUG][AIAgent] Request processed successfully (type: " . $result->{execution_type} . ", protocols: " . join(", ", @{$result->{protocols_used}}) . ")\n" if should_log('DEBUG');
    
    return $result;
}

# Simple protocol integration for low-complexity tasks
sub _execute_simple_protocol_integration {
    my ($self, $user_input, $context, $result) = @_;
    
    # Step 1: Analyze user intent for protocol usage
    my $should_use_protocols = $self->{protocol_integration}->should_use_protocols($user_input, $context);
    
    if ($should_use_protocols || $self->{integration_mode} eq 'aggressive') {
        print STDERR "[DEBUG][AIAgent] Analyzing for protocol usage\n" if should_log('DEBUG');
        
        my $intent_analysis = $self->{protocol_integration}->analyze_user_intent($user_input, $context);
        
        if ($intent_analysis->{confidence} > 0.1 || $self->{integration_mode} eq 'aggressive') {
            print STDERR "[DEBUG][AIAgent] Executing protocol chain (confidence: " . $intent_analysis->{confidence} . ")\n" if should_log('DEBUG');
            
            # Step 2: Execute relevant protocols
            $result->{protocol_results} = $self->{protocol_integration}->execute_protocol_chain($intent_analysis, $user_input);
            $result->{protocols_used} = $result->{protocol_results}->{executed_protocols} || [];
            
            # Update session context with protocol results
            if (@{$result->{protocols_used}}) {
                $self->{session}->{state}->{recent_protocols} = $result->{protocols_used};
                $self->{session}->{state}->{last_protocol_time} = time();
            }
        }
    }
    
    # Step 3: Prepare enhanced prompt for AI
    my $enhanced_prompt = $self->_create_enhanced_prompt($user_input, $result->{protocol_results});
    
    # Step 4: Get AI response
    eval {
        print STDERR "[DEBUG][AIAgent] Sending request to AI API\n" if should_log('DEBUG');
        
        my $api_response = $self->_send_ai_request($enhanced_prompt);
        
        # Debug the response from _send_ai_request
        if ($self->{debug}) {
            require Data::Dumper;
            print STDERR "[DEBUG][AIAgent] _send_ai_request returned: " . Data::Dumper::Dumper($api_response) . "\n";
        }
        
        if ($api_response && $api_response->{content}) {
            print STDERR "[DEBUG][AIAgent] Setting ai_response to: '$api_response->{content}'\n" if should_log('DEBUG');
            $result->{ai_response} = $api_response->{content};
        } else {
            print STDERR "[DEBUG][AIAgent] No content found in API response\n" if should_log('DEBUG');
            push @{$result->{errors}}, "AI API returned no content";
            $result->{success} = 0;
        }
    };
    
    if ($@) {
        push @{$result->{errors}}, "AI API error: $@";
        $result->{success} = 0;
        print STDERR "[ERROR][AIAgent] API error: $@\n" if should_log('ERROR');
    }
    
    # Step 5: Integrate protocol results with AI response
    if ($result->{ai_response} && $result->{protocol_results} && 
        $result->{protocol_results}->{responses} && 
        @{$result->{protocol_results}->{responses}}) {
        print STDERR "[DEBUG][AIAgent] Integrating protocol responses\n" if should_log('DEBUG');
        
        my $integrated = $self->{protocol_integration}->integrate_protocol_responses(
            $result->{ai_response},
            $result->{protocol_results}
        );
        
        $result->{final_response} = $integrated->{final_response};
        $result->{integration_mode} = $integrated->{integration_mode};
    } else {
        $result->{final_response} = $result->{ai_response} || "No response available";
    }
    
    # Step 6: Update processing metrics
    $result->{processing_time} = time() - $result->{processing_time};
    
    print STDERR "[DEBUG][AIAgent] Processing complete in " . $result->{processing_time} . "s\n" if should_log('DEBUG');
    
    return $result;
}

=head2 set_integration_mode

Set the protocol integration mode.

    $agent->set_integration_mode('aggressive');  # Always try protocols
    $agent->set_integration_mode('conservative'); # Only obvious cases
    $agent->set_integration_mode('automatic');   # Smart detection (default)

=cut

sub set_integration_mode {
    my ($self, $mode) = @_;
    
    if ($mode =~ /^(aggressive|conservative|automatic)$/) {
        $self->{integration_mode} = $mode;
        print STDERR "[DEBUG][AIAgent] Integration mode set to: $mode\n" if should_log('DEBUG');
    } else {
        print STDERR "[WARNING][AIAgent] Invalid integration mode: $mode\n" if should_log('WARNING');
    }
}

=head2 get_protocol_statistics

Get statistics about protocol usage.

    my $stats = $agent->get_protocol_statistics();

=cut

sub get_protocol_statistics {
    my ($self) = @_;
    
    my $session_state = $self->{session}->{state};
    
    return {
        recent_protocols => $session_state->{recent_protocols} || [],
        last_protocol_time => $session_state->{last_protocol_time} || 0,
        total_protocol_calls => $session_state->{total_protocol_calls} || 0,
        successful_protocols => $session_state->{successful_protocols} || 0,
        failed_protocols => $session_state->{failed_protocols} || 0,
        integration_mode => $self->{integration_mode}
    };
}

# Private methods

sub _create_enhanced_prompt {
    my ($self, $user_input, $protocol_results) = @_;
    
    my $enhanced_prompt = $user_input;
    
    # Add protocol context if available (both successes and failures)
    if ($protocol_results && 
        (($protocol_results->{responses} && @{$protocol_results->{responses}}) ||
         ($protocol_results->{errors} && @{$protocol_results->{errors}}))) {
        
        my $protocol_context = "\n\n--- PROTOCOL CONTEXT ---\n";
        
        # Add successful protocol responses
        if ($protocol_results->{responses} && @{$protocol_results->{responses}}) {
            for my $result (@{$protocol_results->{responses}}) {
                my $protocol = $result->{protocol};
                my $response = $result->{response};
                
                $protocol_context .= "[$protocol SUCCESS]: ";
                
                if (ref($response) eq 'HASH') {
                    if ($response->{processed_content}) {
                        # Use processed content instead of raw content for better summary
                        my $processed = $response->{processed_content};
                        if (ref($processed) eq 'HASH') {
                            if ($processed->{title}) {
                                $protocol_context .= "Title: " . $processed->{title} . "\n";
                            }
                            if ($processed->{summary}) {
                                $protocol_context .= "Summary: " . $processed->{summary} . "\n";
                            } elsif ($processed->{text_content} && length($processed->{text_content}) < 2000) {
                                $protocol_context .= "Content: " . $processed->{text_content} . "\n";
                            }
                            if ($processed->{meta_tags} && $processed->{meta_tags}->{description}) {
                                $protocol_context .= "Description: " . $processed->{meta_tags}->{description} . "\n";
                            }
                        } else {
                            $protocol_context .= $processed;
                        }
                    } elsif ($response->{content_summary}) {
                        $protocol_context .= $response->{content_summary};
                    } elsif ($response->{content} && length($response->{content}) < 2000) {
                        $protocol_context .= $response->{content};
                    } elsif ($response->{data}) {
                        $protocol_context .= "Data available: " . ref($response->{data});
                    } else {
                        # Truncate large JSON responses
                        my $json = encode_json($response);
                        if (length($json) > 2000) {
                            $protocol_context .= substr($json, 0, 2000) . "...[truncated]";
                        } else {
                            $protocol_context .= $json;
                        }
                    }
                } else {
                    $protocol_context .= $response;
                }
                
                $protocol_context .= "\n";
            }
        }
        
        # Add failed protocol attempts
        if ($protocol_results->{errors} && @{$protocol_results->{errors}}) {
            for my $error (@{$protocol_results->{errors}}) {
                my $protocol = $error->{protocol};
                my $error_msg = $error->{error};
                
                $protocol_context .= "[$protocol FAILED]: $error_msg\n";
            }
        }
        
        $protocol_context .= "--- END PROTOCOL CONTEXT ---\n\n";
        
        # Insert context before the user's question
        $enhanced_prompt = $protocol_context . 
                          "Based on the protocol information above, please respond to: " . 
                          $user_input;
    }
    
    # Add session context hints
    my $recent_protocols = $self->{session}->{state}->{recent_protocols} || [];
    if (@$recent_protocols) {
        $enhanced_prompt .= "\n\n[Recently used protocols: " . join(", ", @$recent_protocols) . "]";
    }
    
    return $enhanced_prompt;
}

sub _send_ai_request {
    my ($self, $prompt) = @_;
    
    # Use the existing API manager to send the request
    my $api = $self->{api};
    
    # For now, return a mock response structure
    # In real implementation, this would call $api->send_request()
    
    # Build messages array from session history
    my @messages = ();
    
    # Add session history
    if ($self->{session}->{state}->{history}) {
        print STDERR \"[DEBUG][AIAgent] Building messages from session history, count: \" . scalar(@{$self->{session}->{state}->{history}}) . \"\\n\" if $self->{debug};
        foreach my $msg (@{$self->{session}->{state}->{history}}) {
            print STDERR \"[DEBUG][AIAgent]   - role=$msg->{role}, content_length=\" . length($msg->{content}) . \"\\n\" if $self->{debug};
            push @messages, { role => $msg->{role}, content => $msg->{content} };
        }
    } else {
        print STDERR \"[WARNING][AIAgent] No session history available!\\n\" if $self->{debug};
    }
    
    # Add current request
    push @messages, { role => 'user', content => $prompt };
    
    # Call the API synchronously for now
    my $response_result;
    eval {
        my $response = $api->send_request(undef, messages => \@messages);
        
        # Debug the response structure
        if ($self->{debug}) {
            require Data::Dumper;
            print STDERR "[DEBUG][AIAgent] API response structure: " . Data::Dumper::Dumper($response) . "\n";
        }
        
        if ($response && !$response->{error} && $response->{content}) {
            print STDERR "[DEBUG][AIAgent] API returned content: '$response->{content}'\n" if should_log('DEBUG');
            $response_result = {
                content => $response->{content},
                success => 1
            };
        } else {
            my $error_msg = "No content in API response";
            if ($response->{error}) {
                $error_msg = $response->{error};
            } elsif (!$response) {
                $error_msg = "No response from API";
            }
            print STDERR "[DEBUG][AIAgent] API error: $error_msg\n" if should_log('DEBUG');
            $response_result = {
                error => $error_msg,
                success => 0
            };
        }
    };

    if ($@) {
        return {
            error => "API exception: $@", 
            success => 0
        };
    }
    
    return $response_result;
}

# Process request with AI model - wrapper for _send_ai_request
sub _process_with_model {
    my ($self, $enhanced_prompt, $context) = @_;
    
    print STDERR "[DEBUG][AIAgent] Processing with AI model\n" if should_log('DEBUG');
    
    my $api_response = $self->_send_ai_request($enhanced_prompt);
    
    if ($api_response && $api_response->{content}) {
        return $api_response->{content};
    } elsif ($api_response && $api_response->{error}) {
        print STDERR "[ERROR][AIAgent] AI model error: " . $api_response->{error} . "\n" if should_log('ERROR');
        return "I encountered an error processing your request: " . $api_response->{error};
    } else {
        print STDERR "[ERROR][AIAgent] No content received from AI model\n" if should_log('ERROR');
        return "I'm sorry, but I didn't receive a proper response from the AI model.";
    }
}

1;

__END__

=head1 AUTHOR

Fewtarius

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2024 CLIO

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
