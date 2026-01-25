package CLIO::Memory::AutoCapture;

use strict;
use warnings;
use CLIO::Core::Logger qw(should_log);

=head1 NAME

CLIO::Memory::AutoCapture - Automatically extract and store discoveries to LTM

=head1 DESCRIPTION

This module analyzes AI responses and automatically stores key discoveries,
problem solutions, and workflow patterns to the Long-Term Memory (LTM).

When an agent completes a response, this module:
1. Parses the response for discovery patterns
2. Extracts problem-solution mappings
3. Identifies successful workflows
4. Stores in LTM with confidence scoring

This enables knowledge persistence across sessions without requiring
explicit agent action or /memory commands.

=head1 SYNOPSIS

    my $capturer = CLIO::Memory::AutoCapture->new(debug => 1);
    
    # After agent response completes:
    $capturer->process_response(
        response => $agent_response,
        ltm => $session->ltm,
        context => { files_modified => [...], tools_used => [...] }
    );

=cut

sub new {
    my ($class, %opts) = @_;
    my $self = {
        debug => $opts{debug} // 0,
        
        # Patterns for extracting discoveries
        discovery_patterns => [
            qr/\b(?:found|discovered|realized|noticed|determined|identified|learned|found that)\b.*?[.!]/i,
            qr/\b(?:the issue|the problem|root cause|the bug|the error)\b.*?is.*?[.!]/i,
            qr/\b(?:this is|this happens|this occurs|this works)\b.*?because.*?[.!]/i,
            qr/\b(?:the key|the critical|the important)\b.*?(?:issue|thing|part|step|factor).*?is.*?[.!]/i,
        ],
        
        # Patterns for extracting solutions
        solution_patterns => [
            qr/\b(?:solution|fix|resolution|workaround|approach|method)\b.*?:?\s*(.+?)(?:\n\n|$)/i,
            qr/\b(?:try|should|must|need to|have to)\b.*?[.!]/i,
            qr/\b(?:need|requires|requires)\b.*?to.*?[.!]/i,
        ],
        
        # Patterns for code discoveries
        code_patterns => [
            qr/\b(?:in|at|file|module|class|function|method)\b\s+(?:`|"|')([^`"']+)(?:`|"|')/i,
            qr/(?:lib|src|app)[^\s:,.]*[^\s:,.]/i,
        ],
    };
    
    bless $self, $class;
    return $self;
}

=head2 process_response

Analyze agent response and extract discoveries to LTM

Arguments:
- response: The complete agent response text
- ltm: CLIO::Memory::LongTerm instance
- context: Hash with optional metadata
  * files_modified: Array of files changed
  * tools_used: Array of tools called
  * working_directory: Current directory
  * problem: Original user problem/question

=cut

sub process_response {
    my ($self, %args) = @_;
    
    my $response = $args{response};
    my $ltm = $args{ltm};
    my $context = $args{context} // {};
    
    return unless $response && $ltm;
    
    if (should_log('DEBUG')) {
        print STDERR "[AutoCapture] Processing response (length: " . length($response) . ")\n";
    }
    
    # Extract discoveries
    my @discoveries = $self->extract_discoveries($response);
    for my $discovery (@discoveries) {
        my $fact = $discovery->{fact};
        my $confidence = $discovery->{confidence};
        
        $ltm->add_discovery($fact, $confidence, 1);  # verified=1 (from actual agent work)
        
        if (should_log('DEBUG')) {
            print STDERR "[AutoCapture] Stored discovery: $fact (conf: " . sprintf("%.0f%%", $confidence*100) . ")\n";
        }
    }
    
    # Extract problem-solution pairs
    my @solutions = $self->extract_solutions($response, $context->{problem});
    for my $solution (@solutions) {
        my $error = $solution->{error};
        my $fix = $solution->{fix};
        my $examples = $solution->{examples} // [];
        
        $ltm->add_problem_solution($error, $fix, $examples);
        
        if (should_log('DEBUG')) {
            print STDERR "[AutoCapture] Stored solution: $error -> $fix\n";
        }
    }
    
    # Extract code patterns
    my @patterns = $self->extract_code_patterns($response);
    for my $pattern (@patterns) {
        my $desc = $pattern->{description};
        my $confidence = $pattern->{confidence};
        my $examples = $pattern->{examples} // [];
        
        $ltm->add_code_pattern($desc, $confidence, $examples);
        
        if (should_log('DEBUG')) {
            print STDERR "[AutoCapture] Stored pattern: $desc\n";
        }
    }
    
    # Extract workflows if tools were used
    if ($context->{tools_used} && @{$context->{tools_used}}) {
        my @workflow = @{$context->{tools_used}};
        $ltm->add_workflow(\@workflow, 1);  # success=1 (agent completed task)
        
        if (should_log('DEBUG')) {
            print STDERR "[AutoCapture] Stored workflow: " . join(" -> ", @workflow) . "\n";
        }
    }
    
    return 1;
}

=head2 extract_discoveries

Extract key discoveries from response text

Returns: Array of { fact => "...", confidence => 0.0-1.0 }

=cut

sub extract_discoveries {
    my ($self, $response) = @_;
    
    my @discoveries;
    
    # Split into sentences for better extraction
    my @sentences = split(/(?<=[.!?\n])\s+/, $response);
    
    for my $sentence (@sentences) {
        next unless length($sentence) > 10;  # Skip trivial sentences
        
        # Check each discovery pattern
        for my $pattern (@{$self->{discovery_patterns}}) {
            if ($sentence =~ $pattern) {
                my $fact = $1 || $sentence;
                
                # Clean up
                $fact =~ s/^(?:and|but|so|however|therefore)\s+//i;
                $fact =~ s/\s+/ /g;
                $fact = substr($fact, 0, 200);  # Cap at 200 chars
                
                next if length($fact) < 15;  # Too short
                
                # Confidence based on pattern strength and sentence position
                my $confidence = 0.7;  # Base confidence
                $confidence += 0.2 if $sentence =~ /\b(?:definitely|clearly|obviously|root cause)\b/i;
                $confidence = 1.0 if $confidence > 1.0;
                
                push @discoveries, {
                    fact => $fact,
                    confidence => $confidence,
                };
                
                last;  # One discovery per sentence
            }
        }
    }
    
    # Remove duplicates (case-insensitive)
    my %seen;
    @discoveries = grep { !$seen{lc($_->{fact})}++ } @discoveries;
    
    return @discoveries;
}

=head2 extract_solutions

Extract problem-solution pairs from response

Returns: Array of { error => "...", fix => "...", examples => [...] }

=cut

sub extract_solutions {
    my ($self, $response, $problem) = @_;
    
    my @solutions;
    
    # Look for solution sections
    if ($response =~ /(?:solution|fix|resolution|approach).*?:?\s*(.+?)(?:next step|summary|conclusion|$)/is) {
        my $solution_text = $1;
        
        # Extract actual solution
        if ($solution_text =~ /^(.+?)(?:\n\n|$)/s) {
            my $fix = $1;
            $fix =~ s/^[-*]\s+//;  # Remove bullet
            $fix = substr($fix, 0, 300);
            
            my $error = $problem || "Issue";
            
            push @solutions, {
                error => $error,
                fix => $fix,
                examples => [],
            };
        }
    }
    
    # Look for "try", "should", "need to" patterns
    while ($response =~ /(?:try|should|need to|must|required to)\s+(.+?)(?:\.|!|\n)/g) {
        my $action = $1;
        next if length($action) < 10;
        
        push @solutions, {
            error => "How to accomplish task",
            fix => $action,
            examples => [],
        };
    }
    
    return @solutions;
}

=head2 extract_code_patterns

Extract code-related patterns and discoveries

Returns: Array of { description => "...", confidence => 0.0-1.0, examples => [...] }

=cut

sub extract_code_patterns {
    my ($self, $response) = @_;
    
    my @patterns;
    
    # Look for file/module mentions with context
    while ($response =~ /(?:in|at|file|module|function)\s+(?:`|"|')([^`"']+)(?:`|"|')\s+(?:at\s+line\s+)?(\d+)?\s*[:-]\s*(.+?)(?:\.|!|\n)/g) {
        my ($file, $line, $note) = ($1, $2, $3);
        
        next unless length($note) > 5;
        
        my $desc = "In $file" . ($line ? " line $line" : "") . ": $note";
        $desc = substr($desc, 0, 200);
        
        push @patterns, {
            description => $desc,
            confidence => 0.8,
            examples => [$file . ($line ? ":$line" : "")],
        };
    }
    
    # Look for code best practices
    if ($response =~ /\b(?:use|always|never)\s+(?:strict|warnings|warnings)\b/i) {
        push @patterns, {
            description => "Always use strict and warnings in Perl modules",
            confidence => 0.9,
            examples => ["lib/**/*.pm"],
        };
    }
    
    return @patterns;
}

=head2 should_capture

Determine if this response contains important discoveries

Returns: 1 if response likely contains valuable patterns, 0 otherwise

=cut

sub should_capture {
    my ($self, $response) = @_;
    
    return 0 unless $response;
    
    # Check for discovery indicators
    my $has_discovery = $response =~ /\b(?:found|discovered|identified|root cause|the issue|the problem)\b/i;
    my $has_solution = $response =~ /\b(?:solution|fix|approach|try|should|need to)\b/i;
    my $has_code = $response =~ /(?:lib|src|file|module|function|class)\//;
    
    return 1 if $has_discovery || $has_solution || $has_code;
    return 0;
}

1;
