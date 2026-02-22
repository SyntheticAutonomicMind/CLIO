package CLIO::Core::ProtocolIntegration;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
use CLIO::Core::Logger qw(should_log);
use CLIO::Util::JSON qw(encode_json decode_json);
use CLIO::Protocols::Manager;

=head1 NAME

CLIO::Core::ProtocolIntegration - Intelligent protocol integration for AI agent responses

=head1 DESCRIPTION

This module provides automatic protocol detection, selection, and integration
for AI agent responses, enabling the agent to automatically utilize available
protocols based on user intent and context.

=head1 FEATURES

- Context-aware protocol selection
- Automatic protocol routing based on user intent
- Response integration with protocol results
- Dynamic protocol chain execution
- Intent classification and mapping

=cut

sub new {
    my ($class, %opts) = @_;
    
    my $self = {
        debug => $opts{debug} || 0,
        session => $opts{session},
        protocol_patterns => {},
        intent_classifiers => {},
        protocol_chains => {},
        last_context => {},
    };
    
    # Initialize the patterns and classifiers
    $self = bless $self, $class;
    $self->{protocol_patterns} = $self->_initialize_protocol_patterns();
    $self->{intent_classifiers} = $self->_initialize_intent_classifiers();
    $self->{protocol_chains} = $self->_initialize_protocol_chains();
    
    return $self;
}

=head2 analyze_user_intent

Analyze user input to determine appropriate protocols to invoke.

    my $analysis = $integration->analyze_user_intent($user_input, $context);

=cut

sub analyze_user_intent {
    my ($self, $user_input, $context) = @_;
    
    return {} unless $user_input;
    
    my $analysis = {
        primary_intent => '',
        confidence => 0,
        suggested_protocols => [],
        context_factors => [],
        execution_priority => 'normal'
    };
    
    # Normalize input for analysis (preserve URLs)
    my $normalized_input = lc($user_input);
    # Don't strip punctuation from URLs - just clean spaces
    $normalized_input =~ s/\s+/ /g;
    
    # Check against protocol patterns
    for my $protocol (keys %{$self->{protocol_patterns}}) {
        my $patterns = $self->{protocol_patterns}{$protocol};
        
        for my $pattern (@$patterns) {
            if ($normalized_input =~ /$pattern/i) {
                my $confidence = $self->_calculate_pattern_confidence($pattern, $normalized_input);
                
                if ($confidence > $analysis->{confidence}) {
                    $analysis->{primary_intent} = $protocol;
                    $analysis->{confidence} = $confidence;
                }
                
                push @{$analysis->{suggested_protocols}}, {
                    protocol => $protocol,
                    confidence => $confidence,
                    trigger_pattern => $pattern
                };
            }
        }
    }
    
    # Sort protocols by confidence
    @{$analysis->{suggested_protocols}} = sort { 
        $b->{confidence} <=> $a->{confidence} 
    } @{$analysis->{suggested_protocols}};
    
    # Add context factors
    $analysis->{context_factors} = $self->_analyze_context_factors($user_input, $context);
    
    # Determine execution priority
    $analysis->{execution_priority} = $self->_determine_execution_priority($analysis);
    
    return $analysis;
}

=head2 execute_protocol_chain

Execute a chain of protocols based on the intent analysis.

    my $results = $integration->execute_protocol_chain($analysis, $user_input);

=cut

sub execute_protocol_chain {
    my ($self, $analysis, $user_input) = @_;
    
    return {} unless $analysis && $analysis->{suggested_protocols};
    
    my $results = {
        executed_protocols => [],
        responses => [],
        errors => [],
        execution_time => time(),
        success => 1
    };
    
    # Execute protocols in order of confidence
    for my $protocol_info (@{$analysis->{suggested_protocols}}) {
        my $protocol = $protocol_info->{protocol};
        my $confidence = $protocol_info->{confidence};
        
        # Skip low-confidence protocols unless explicitly requested
        next if $confidence < 0.3 && $analysis->{execution_priority} ne 'aggressive';
        
        print STDERR "[DEBUG] Executing protocol $protocol (confidence: $confidence)\n" if should_log('DEBUG');
        
        eval {
            my $protocol_input = $self->_prepare_protocol_input($protocol, $user_input, $analysis);
            my $response = CLIO::Protocols::Manager->handle($protocol_input, $self->{session});
            
            if ($response && !$response->{error}) {
                push @{$results->{executed_protocols}}, $protocol;
                push @{$results->{responses}}, {
                    protocol => $protocol,
                    response => $response,
                    confidence => $confidence
                };
                
                print STDERR "[DEBUG] Protocol $protocol executed successfully\n" if should_log('DEBUG');
            } else {
                my $error_msg = $response->{error} || "Unknown protocol error";
                push @{$results->{errors}}, {
                    protocol => $protocol,
                    error => $error_msg
                };
                print STDERR "[DEBUG] Protocol $protocol failed: $error_msg\n" if should_log('DEBUG');
            }
        };
        
        if ($@) {
            push @{$results->{errors}}, {
                protocol => $protocol,
                error => "Exception: $@"
            };
            $results->{success} = 0;
            print STDERR "[ERROR] Protocol $protocol exception: $@\n" if should_log('ERROR');
        }
        
        # Break early if we have a high-confidence successful result
        if (@{$results->{responses}} && $confidence > 0.8) {
            print STDERR "[DEBUG] High-confidence result achieved, stopping chain\n" if should_log('DEBUG');
            last;
        }
    }
    
    return $results;
}

=head2 integrate_protocol_responses

Integrate protocol responses into the AI agent's response.

    my $integrated_response = $integration->integrate_protocol_responses(
        $ai_response, $protocol_results
    );

=cut

sub integrate_protocol_responses {
    my ($self, $ai_response, $protocol_results) = @_;
    
    return $ai_response unless $protocol_results && @{$protocol_results->{responses}};
    
    my $integrated = {
        original_response => $ai_response,
        protocol_enhancements => [],
        final_response => $ai_response,
        integration_mode => 'append'
    };
    
    # Determine integration strategy
    my $integration_mode = $self->_determine_integration_mode($ai_response, $protocol_results);
    $integrated->{integration_mode} = $integration_mode;
    
    # Process each protocol response
    for my $result (@{$protocol_results->{responses}}) {
        my $protocol = $result->{protocol};
        my $response = $result->{response};
        
        my $enhancement = $self->_format_protocol_enhancement($protocol, $response);
        push @{$integrated->{protocol_enhancements}}, $enhancement;
    }
    
    # Apply integration strategy
    if ($integration_mode eq 'prepend') {
        $integrated->{final_response} = join("\n\n", 
            @{$integrated->{protocol_enhancements}}, 
            $ai_response
        );
    } elsif ($integration_mode eq 'inline') {
        $integrated->{final_response} = $self->_inline_integrate_responses(
            $ai_response, 
            $integrated->{protocol_enhancements}
        );
    } else { # append (default)
        $integrated->{final_response} = join("\n\n", 
            $ai_response, 
            @{$integrated->{protocol_enhancements}}
        );
    }
    
    return $integrated;
}

=head2 should_use_protocols

Determine if protocols should be used for the given input.

    my $should_use = $integration->should_use_protocols($user_input, $context);

=cut

sub should_use_protocols {
    my ($self, $user_input, $context) = @_;
    
    # Don't use protocols for simple conversational responses
    return 0 if $user_input =~ /^(hi|hello|thanks|thank you|ok|okay|yes|no)$/i;
    
    # Don't use protocols for very short responses
    return 0 if length($user_input) < 10;
    
    # Use protocols for URLs - this is critical!
    return 1 if $user_input =~ /https?:\/\/[^\s]+/i;
    
    # Use protocols for specific action words
    return 1 if $user_input =~ /\b(create|edit|search|analyze|validate|check|run|execute|show|list|find|get|fetch|download|retrieve|load)\b/i;
    
    # Use protocols for file operations
    return 1 if $user_input =~ /\b(file|directory|folder|code|script|function|class|method)\b/i;
    
    # Use protocols for version control
    return 1 if $user_input =~ /\b(git|commit|branch|merge|diff|log|status)\b/i;
    
    # Default to not using protocols for general conversation
    return 0;
}

# Private methods

sub _initialize_protocol_patterns {
    my ($self) = @_;
    
    return {
        'VALIDATE' => [
            'validate.*(?:code|script|file|syntax)',
            'check.*(?:syntax|code|file|errors)',
            '(?:is|are).*(?:code|syntax).*(?:correct|valid|ok)',
            'syntax.*(?:check|error|validation|correct)',
            'lint.*(?:code|file|this)'
        ],
        'SHELL' => [
            'run.*(?:command|script|shell)',
            'execute.*(?:command|script|shell)',
            'shell.*(?:command|script)',
            '(?:run|execute).*[`\'""][^`\'""]',
            'command.*line.*(?:run|execute)'
        ],
        'ARCHITECT' => [
            'design.*(?:system|architecture|solution)',
            'architect.*(?:system|solution)',
            'how.*(?:should|would|can).*(?:design|build|structure)',
            'what.*(?:architecture|design|structure|approach)',
            'requirements?.*(?:analysis|for)'
        ],
        'EDITOR' => [
            'edit.*(?:file|code|function|method)',
            'modify.*(?:file|code|function|method)',
            'change.*(?:file|code|function|method)',
            'update.*(?:file|code|function|method)',
            'fix.*(?:file|code|bug|error)'
        ],
        'GIT' => [
            'git.*(?:status|log|diff|commit|branch|merge)',
            '(?:show|get|check).*(?:git|status|commits|branches)',
            'version.*control.*(?:status|history)',
            'repository.*(?:status|history|log)',
            'what.*(?:changed|commits|branches)'
        ],
        'REPOMAP' => [
            'map.*(?:repository|repo|codebase)',
            'analyze.*(?:repository|repo|codebase|structure)',
            'repository.*(?:structure|overview|map)',
            'codebase.*(?:structure|overview|analysis)',
            'project.*(?:structure|overview)'
        ],
        'RAG' => [
            'search.*(?:code|documentation|files)',
            'find.*(?:in|code|documentation|files)',
            'lookup.*(?:code|documentation)',
            'what.*(?:does|is|are).*(?:function|class|method|variable)',
            'where.*(?:is|are).*(?:defined|used|called)'
        ],
        'WEB_SEARCH' => [
            'search.*(?:web|online|internet)',
            'look.*up.*(?:online|web)',
            'find.*(?:online|web|internet)',
            'web.*search',
            'google.*(?:search.*)?for',
            'search.*(?:for|on).*google',  # "search for X on Google"
            'look.*up.*(?:on|via).*google', # "look up X on Google"
            '(?:search|find|look).*(?:using|with|via).*google' # "search using Google"
        ],
        'URL_FETCH' => [
            'fetch.*(?:url|link|page|https?://)',
            'get.*(?:content|data).*from.*(?:url|link|website|https?://)',
            'download.*from.*(?:url|link|https?://)',
            'retrieve.*from.*(?:url|link|website|https?://)',
            'load.*(?:url|link|page|https?://)',
            'https?://[^\s]+',  # Direct URL detection
            'fetch.*https?://',  # Fetch with URL
            'get.*https?://',    # Get with URL
        ],
        'MEMORY' => [
            'remember.*(?:this|that)',
            'save.*(?:this|that).*(?:memory)',
            'recall.*(?:what|when|where)',
            'what.*(?:did|was).*(?:say|discuss|talk)',
            'memory.*(?:search|lookup|recall)'
        ],
        'RECALL' => [
            'recall.*(?:context|history|earlier|previous)',
            'what.*(?:did.*say|discussed|talked.*about).*(?:earlier|before|previously)',
            'search.*(?:history|earlier|previous|archived)',
            'find.*(?:in|from).*(?:history|earlier|previous)',
            'look.*(?:back|up).*(?:history|conversation)',
            'earlier.*(?:conversation|discussed|mentioned)'
        ]
    };
}

sub _initialize_intent_classifiers {
    my ($self) = @_;
    
    return {
        'file_operation' => [
            'create', 'edit', 'modify', 'delete', 'move', 'copy', 'file', 'directory'
        ],
        'code_analysis' => [
            'analyze', 'parse', 'check', 'validate', 'syntax', 'structure', 'ast'
        ],
        'search_operation' => [
            'search', 'find', 'lookup', 'locate', 'where', 'what', 'which'
        ],
        'execution' => [
            'run', 'execute', 'command', 'script', 'shell', 'terminal'
        ],
        'version_control' => [
            'git', 'commit', 'branch', 'merge', 'push', 'pull', 'diff', 'log'
        ]
    };
}

sub _initialize_protocol_chains {
    my ($self) = @_;
    
    return {
        'file_creation' => ['ARCHITECT', 'EDITOR', 'VALIDATE'],
        'code_analysis' => ['VALIDATE', 'REPOMAP'],
        'repository_overview' => ['REPOMAP', 'GIT'],
        'code_modification' => ['EDITOR', 'VALIDATE'],
        'research_task' => ['RAG', 'WEB_SEARCH', 'URL_FETCH']
    };
}

sub _calculate_pattern_confidence {
    my ($self, $pattern, $input) = @_;
    
    # Base confidence from pattern match
    my $confidence = 0.5;
    
    # Boost for exact word matches
    my @pattern_words = split(/\s+/, $pattern);
    my @input_words = split(/\s+/, $input);
    
    my $word_matches = 0;
    for my $pword (@pattern_words) {
        $pword =~ s/[^\w]//g; # Remove regex metacharacters for counting
        for my $iword (@input_words) {
            if (lc($pword) eq lc($iword)) {
                $word_matches++;
                last;
            }
        }
    }
    
    # Adjust confidence based on word matches
    if (@pattern_words > 0) {
        my $match_ratio = $word_matches / @pattern_words;
        $confidence += $match_ratio * 0.4;
    }
    
    # Boost for longer patterns (more specific)
    if (length($pattern) > 20) {
        $confidence += 0.1;
    }
    
    # Cap confidence at 1.0
    return ($confidence > 1.0) ? 1.0 : $confidence;
}

sub _analyze_context_factors {
    my ($self, $input, $context) = @_;
    
    my @factors = ();
    
    # File context
    if ($context && $context->{current_file}) {
        push @factors, "current_file: " . $context->{current_file};
    }
    
    # Directory context
    if ($context && $context->{working_directory}) {
        push @factors, "working_directory: " . $context->{working_directory};
    }
    
    # Recent protocol usage
    if ($context && $context->{recent_protocols}) {
        push @factors, "recent_protocols: " . join(", ", @{$context->{recent_protocols}});
    }
    
    # Session history context
    if ($context && $context->{conversation_topics}) {
        push @factors, "conversation_topics: " . join(", ", @{$context->{conversation_topics}});
    }
    
    return \@factors;
}

sub _determine_execution_priority {
    my ($self, $analysis) = @_;
    
    # High priority for explicit protocol mentions
    return 'high' if $analysis->{confidence} > 0.8;
    
    # Aggressive for development/coding contexts
    return 'aggressive' if grep { $_->{protocol} =~ /^(EDITOR|ARCHITECT|VALIDATE)$/ } 
                          @{$analysis->{suggested_protocols}};
    
    # Conservative for search operations
    return 'conservative' if grep { $_->{protocol} =~ /^(WEB_SEARCH|URL_FETCH)$/ } 
                            @{$analysis->{suggested_protocols}};
    
    return 'normal';
}

sub _prepare_protocol_input {
    my ($self, $protocol, $user_input, $analysis) = @_;
    
    # Extract relevant parameters based on protocol type
    my $protocol_input = "[${protocol}:";
    
    if ($protocol eq 'VALIDATE') {
        # Extract file or code content
        if ($user_input =~ /file\s+([^\s]+)/) {
            $protocol_input .= "file=$1]";
        } else {
            $protocol_input .= "content=" . $self->_extract_code_content($user_input) . "]";
        }
    } elsif ($protocol eq 'SHELL') {
        # Extract command
        if ($user_input =~ /`([^`]+)`/) {
            $protocol_input .= "command=$1]";
        } else {
            # Try to extract command from context
            my $command = $self->_extract_shell_command($user_input);
            $protocol_input .= "command=$command]";
        }
    } elsif ($protocol eq 'EDITOR') {
        # Extract file and operation
        my $file = $self->_extract_filename($user_input);
        my $operation = $self->_extract_operation($user_input);
        $protocol_input .= "file=$file:operation=$operation]";
    } elsif ($protocol eq 'RAG') {
        # Extract search query
        my $query = $self->_extract_search_query($user_input);
        $protocol_input .= "query=$query]";
    } elsif ($protocol eq 'GIT') {
        # Extract git operation
        my $operation = $self->_extract_git_operation($user_input);
        $protocol_input .= "operation=$operation]";
    } elsif ($protocol eq 'URL_FETCH') {
        # Extract URL and create proper URL_FETCH format
        my $url = $self->_extract_url($user_input);
        if ($url) {
            # Create params as base64 encoded JSON
            use MIME::Base64;
            my $params = encode_json({ url => $url });
            my $b64_params = encode_base64($params, '');
            $protocol_input = "[URL_FETCH:action=fetch:params=$b64_params]";
        } else {
            $protocol_input .= "query=$user_input]";
        }
    } elsif ($protocol eq 'WEB_SEARCH') {
        # Extract search query and create proper WEB_SEARCH format
        my $query = $self->_extract_search_query($user_input);
        # Create params as base64 encoded JSON
        use MIME::Base64;
        my $params = encode_json({ 
            query => $query,
            max_results => 5,
            engines => ['google']
        });
        my $b64_params = encode_base64($params, '');
        $protocol_input = "[WEB_SEARCH:action=search:params=$b64_params]";
    } else {
        # Generic protocol input
        $protocol_input .= "query=$user_input]";
    }
    
    return $protocol_input;
}

sub _extract_url {
    my ($self, $text) = @_;
    
    # Extract HTTP/HTTPS URLs from text
    if ($text =~ /(https?:\/\/[^\s]+)/i) {
        return $1;
    }
    
    return undef;
}

sub _determine_integration_mode {
    my ($self, $ai_response, $protocol_results) = @_;
    
    # If AI response is short or generic, prepend protocol results
    return 'prepend' if length($ai_response) < 100;
    
    # If protocol results are highly relevant, inline them
    return 'inline' if @{$protocol_results->{responses}} == 1 && 
                      $protocol_results->{responses}[0]{confidence} > 0.8;
    
    # Default to appending
    return 'append';
}

sub _format_protocol_enhancement {
    my ($self, $protocol, $response) = @_;
    
    my $enhancement = "\n--- $protocol RESULTS ---\n";
    
    if (ref($response) eq 'HASH') {
        if ($response->{content}) {
            $enhancement .= $response->{content};
        } elsif ($response->{data}) {
            $enhancement .= JSON->new->pretty->encode($response->{data});
        } else {
            $enhancement .= JSON->new->pretty->encode($response);
        }
    } else {
        $enhancement .= $response;
    }
    
    $enhancement .= "\n--- END $protocol ---\n";
    
    return $enhancement;
}

sub _inline_integrate_responses {
    my ($self, $ai_response, $enhancements) = @_;
    
    # Simple inline integration - insert at first paragraph break
    my @paragraphs = split(/\n\n/, $ai_response);
    
    if (@paragraphs > 1) {
        return join("\n\n", $paragraphs[0], @$enhancements, @paragraphs[1..$#paragraphs]);
    } else {
        return join("\n\n", $ai_response, @$enhancements);
    }
}

# Helper methods for extracting information from user input

sub _extract_code_content {
    my ($self, $input) = @_;
    
    # Look for code blocks
    if ($input =~ /```([^`]+)```/) {
        return $1;
    }
    
    # Look for inline code
    if ($input =~ /`([^`]+)`/) {
        return $1;
    }
    
    # Return the whole input if no code blocks found
    return $input;
}

sub _extract_shell_command {
    my ($self, $input) = @_;
    
    # Look for explicit commands
    if ($input =~ /(?:run|execute)\s+(.+)$/i) {
        return $1;
    }
    
    # Look for command-like patterns
    if ($input =~ /\b(ls|cd|mkdir|rm|cp|mv|grep|find|ps|top|kill)\b.*/) {
        return $&;
    }
    
    return $input;
}

sub _extract_filename {
    my ($self, $input) = @_;
    
    # Look for file extensions
    if ($input =~ /([^\s]+\.[a-zA-Z]{1,4})\b/) {
        return $1;
    }
    
    # Look for file paths
    if ($input =~ m{([./~][^\s]+)}) {
        return $1;
    }
    
    return "unknown_file";
}

sub _extract_operation {
    my ($self, $input) = @_;
    
    return 'create' if $input =~ /\b(create|new|add)\b/i;
    return 'edit' if $input =~ /\b(edit|modify|change|update)\b/i;
    return 'delete' if $input =~ /\b(delete|remove|rm)\b/i;
    return 'view' if $input =~ /\b(show|view|display|cat)\b/i;
    
    return 'edit'; # default
}

sub _extract_search_query {
    my ($self, $input) = @_;
    
    # Remove common prefixes
    my $query = $input;
    $query =~ s/^(?:search|find|lookup|where|what|how)\s+(?:for|is|are|do|does)\s*//i;
    $query =~ s/\?$//; # Remove trailing question marks
    
    return $query;
}

sub _extract_git_operation {
    my ($self, $input) = @_;
    
    return 'status' if $input =~ /\b(status|st)\b/i;
    return 'log' if $input =~ /\b(log|history)\b/i;
    return 'diff' if $input =~ /\b(diff|changes)\b/i;
    return 'branch' if $input =~ /\b(branch|branches)\b/i;
    return 'commit' if $input =~ /\b(commit)\b/i;
    
    return 'status'; # default
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

1;
