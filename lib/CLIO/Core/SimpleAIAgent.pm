package CLIO::Core::SimpleAIAgent;

use strict;
use warnings;
use CLIO::Core::Logger qw(should_log);
use CLIO::Core::HashtagParser;
use JSON::PP qw(encode_json decode_json);
use Data::Dumper;
use MIME::Base64 qw(encode_base64 decode_base64);

=head1 NAME

CLIO::Core::SimpleAIAgent - Simplified AI agent that bypasses broken natural language processing

=head1 DESCRIPTION

This module provides a working AI interface that directly calls the API when the 
main natural language processing system is broken. It ensures the system works
for both conversational and protocol-based requests.

=cut

sub new {
    my ($class, %opts) = @_;
    
    my $self = {
        debug => $opts{debug} || 0,
        session => $opts{session},
        api => $opts{api},
        ui => $opts{ui} || undef,  # UI reference for user_collaboration
    };
    
    bless $self, $class;
    
    # Initialize orchestrator immediately so it's available for /todo and other commands
    # even before the first user request
    eval {
        require CLIO::Core::WorkflowOrchestrator;
        $self->{orchestrator} = CLIO::Core::WorkflowOrchestrator->new(
            debug => $self->{debug},
            api_manager => $self->{api},
            session => $self->{session},
            ui => $self->{ui},
        );
        print STDERR "[DEBUG][SimpleAIAgent] Orchestrator initialized in constructor\n" if should_log('DEBUG');
    };
    if ($@) {
        print STDERR "[ERROR][SimpleAIAgent] Failed to initialize orchestrator: $@\n";
    }
    
    return $self;
}

=head2 set_ui

Set the UI object after construction (for collaboration support).
This is called after Chat UI is created so orchestrator can access it.

Arguments:
- $ui: The Chat UI object

=cut

sub set_ui {
    my ($self, $ui) = @_;
    
    return unless $ui;
    
    $self->{ui} = $ui;
    
    # Update orchestrator with new UI
    if ($self->{orchestrator}) {
        $self->{orchestrator}->{ui} = $ui;
        $self->{orchestrator}->{tool_executor}->{ui} = $ui if $self->{orchestrator}->{tool_executor};
        print STDERR "[DEBUG][SimpleAIAgent] Updated orchestrator and tool_executor with UI\n" if should_log('DEBUG');
    }
}

=head2 process_user_request

Process a user request directly with the API, bypassing the broken natural language processor.

Arguments:
- $user_input: User's input text
- $context: Context hash (optional)
  * conversation_history: Array of previous messages
  * on_chunk: Callback for streaming responses

=cut

sub process_user_request {
    my ($self, $user_input, $context) = @_;
    
    $context ||= {};
    
    # Extract on_chunk callback if provided
    my $on_chunk = $context->{on_chunk};
    
    my $result = {
        original_input => $user_input,
        ai_response => '',
        final_response => '',
        protocols_used => [],
        success => 1,
        errors => [],
        processing_time => time()
    };
    
    print STDERR "[DEBUG][SimpleAIAgent] Processing request: '$user_input'\n" if should_log('DEBUG');
    
    # Check if it's a direct protocol command
    if ($user_input =~ /^\[([A-Z_]+):/) {
        print STDERR "[DEBUG][SimpleAIAgent] Direct protocol command detected\n" if should_log('DEBUG');
        # Let the protocol manager handle it
        eval {
            require CLIO::Protocols::Manager;
            my $protocol_result = CLIO::Protocols::Manager->handle($user_input, $self->{session});
            if ($protocol_result && $protocol_result->{success}) {
                $result->{final_response} = $protocol_result->{response} || "Protocol executed successfully";
                $result->{protocols_used} = [$1];
            } else {
                $result->{final_response} = "Protocol execution failed: " . ($protocol_result->{error} || "Unknown error");
                $result->{success} = 0;
            }
        };
        if ($@) {
            $result->{final_response} = "Protocol execution error: $@";
            $result->{success} = 0;
        }
        return $result;
    }
    
    # Use WorkflowOrchestrator for all natural language requests
    print STDERR "[DEBUG][SimpleAIAgent] Using WorkflowOrchestrator for natural language request\n" if should_log('DEBUG');
    
    # Parse and resolve hashtags BEFORE sending to orchestrator
    my $processed_input = $user_input;
    eval {
        my $parser = CLIO::Core::HashtagParser->new(
            session => $self->{session},
            debug => $self->{debug}
        );
        
        # Parse hashtags
        my $tags = $parser->parse($user_input);
        
        if ($tags && @$tags) {
            print STDERR "[DEBUG][SimpleAIAgent] Found " . scalar(@$tags) . " hashtags\n" if should_log('DEBUG');
            
            # Resolve hashtags to context
            my $context_data = $parser->resolve($tags);
            
            if ($context_data && @$context_data) {
                # Format context for prompt injection
                my $formatted_context = $parser->format_context($context_data);
                
                # Inject context into user input
                $processed_input = $formatted_context . $user_input;
                
                print STDERR "[DEBUG][SimpleAIAgent] Injected " . length($formatted_context) . " bytes of context\n" if should_log('DEBUG');
            }
        }
    };
    if ($@) {
        print STDERR "[WARN]SimpleAIAgent] Hashtag parsing failed: $@\n";
        # Continue with original input if hashtag parsing fails
    }
    
    eval {
        # Orchestrator is now initialized in constructor, just make sure it exists
        unless ($self->{orchestrator}) {
            require CLIO::Core::WorkflowOrchestrator;
            $self->{orchestrator} = CLIO::Core::WorkflowOrchestrator->new(
                debug => $self->{debug},
                api_manager => $self->{api},
                session => $self->{session},
                ui => $context->{ui},  # Forward UI for user_collaboration
                spinner => $context->{spinner}  # Forward spinner for interactive tools
            );
        }
        
        # Update UI reference if provided in context (for dynamic chat updates)
        if ($context->{ui} && $self->{orchestrator}) {
            $self->{orchestrator}->{ui} = $context->{ui};
        }
        
        # Update spinner reference if provided in context
        if ($context->{spinner} && $self->{orchestrator}) {
            $self->{orchestrator}->{spinner} = $context->{spinner};
        }
        
        my $orchestrator = $self->{orchestrator};
        
        # Prepare conversation history
        my @messages = ();
        if ($context->{conversation_history} && ref($context->{conversation_history}) eq 'ARRAY') {
            my $history = $context->{conversation_history};
            # Only include last 10 messages to avoid context overflow
            my $start_idx = @$history > 10 ? @$history - 10 : 0;
            for my $i ($start_idx .. $#{$history}) {
                my $msg = $history->[$i];
                next unless $msg && $msg->{role} && $msg->{content};
                push @messages, {
                    role => $msg->{role},
                    content => $msg->{content}
                };
            }
        }
        
        my $orchestrator_result = $orchestrator->process_input(
            $processed_input,  # Use processed input with hashtag context
            $self->{session},
            on_chunk => $on_chunk  # Pass through streaming callback
        );
        
        if ($orchestrator_result && $orchestrator_result->{success}) {
            $result->{ai_response} = $orchestrator_result->{content};
            $result->{final_response} = $orchestrator_result->{content};
            $result->{protocols_used} = $orchestrator_result->{tool_calls_made} || [];
            $result->{success} = 1;
            
            print STDERR "[DEBUG][SimpleAIAgent] Orchestrator returned content length: " . length($orchestrator_result->{content} || '') . "\n" if should_log('DEBUG');
            print STDERR "[DEBUG][SimpleAIAgent] Content: '" . ($orchestrator_result->{content} || 'UNDEF') . "'\n" if should_log('DEBUG');
            
            # Include metrics if streaming was used
            if ($orchestrator_result->{metrics}) {
                $result->{metrics} = $orchestrator_result->{metrics};
            }
        } else {
            my $error = $orchestrator_result->{error} || "Unknown error in workflow orchestration";
            push @{$result->{errors}}, $error;
            $result->{success} = 0;
            $result->{final_response} = "I'm sorry, I didn't receive a proper response. Please try rephrasing your question.";
        }
    };
    
    if ($@) {
        push @{$result->{errors}}, "API exception: $@";
        $result->{success} = 0;
        $result->{final_response} = "I'm experiencing technical difficulties. Please try again.";
        print STDERR "[ERROR][SimpleAIAgent] API error: $@\n" if should_log('ERROR');
    }
    
    # Set processing time
    $result->{processing_time} = time() - $result->{processing_time};
    
    print STDERR "[DEBUG][SimpleAIAgent] Processing complete in " . $result->{processing_time} . "s\n" if $self->{debug};
    
    return $result;
}

=head2 _build_system_prompt

Build a comprehensive system prompt that tells the AI about its capabilities

=cut

sub _build_system_prompt {
    my ($self) = @_;
    
    return <<'SYSTEM_PROMPT';
You are CLIO, an AI assistant with powerful file and repository management capabilities.

**Your Capabilities:**

You can help users with:

1. **File Operations** - Reading, writing, and managing files
   - Example: "read the README.md file"
   - Example: "show me the contents of lib/CA/Core/AIAgent.pm"

2. **Git Operations** - Repository status, history, and management
   - Example: "show me git status"
   - Example: "what's the latest commit?"
   - Example: "show git log"

3. **URL Fetching** - Retrieving content from web URLs
   - Example: "fetch https://example.com"
   - Example: "get the content from https://github.com/user/repo"

4. **General Assistance** - Answering questions, explaining code, brainstorming ideas
   - Code review and suggestions
   - Debugging help
   - Architecture discussions

**How to Use Your Capabilities:**

When a user asks you to read a file, check git status, or fetch a URL, you will automatically
execute the appropriate command and provide them with the results.

**Important:**

- Be helpful and conversational
- When you execute file/git/URL operations, the results will be provided to you automatically
- Don't tell users you "can't" do something if it's within your capabilities above
- For operations you truly can't perform, explain clearly and suggest alternatives
- Be concise but thorough
- Use the information from file/git operations to provide accurate, specific answers

**Response Style:**

- Be direct and helpful
- Don't over-explain your capabilities unless asked
- Focus on answering the user's question
- When you've executed an operation (file read, git status, etc.), incorporate the results naturally into your response

You are running on the Qwen-3-Coder-Max model via DashScope API.
SYSTEM_PROMPT
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
