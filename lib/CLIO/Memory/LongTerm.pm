package CLIO::Memory::LongTerm;

use strict;
use warnings;
use CLIO::Core::Logger qw(should_log);
use JSON::PP;
use utf8;

=head1 NAME

CLIO::Memory::LongTerm - Dynamic experience database for project-specific learning

=head1 DESCRIPTION

LongTerm memory stores patterns learned from actual usage across sessions.
Unlike static configuration (.clio/instructions.md), LTM dynamically learns from:

- Code patterns discovered during work
- Problem-solution mappings from debugging
- Workflow sequences that work well
- Failures and how to prevent them
- Context-specific rules for modules/directories
- Discoveries about the codebase

Storage: Per-project in .clio/ltm.json

=head1 SYNOPSIS

    my $ltm = CLIO::Memory::LongTerm->new();
    
    # Add a discovery
    $ltm->add_discovery("Config stored in CLIO::Core::Config", 1.0);
    
    # Add a problem-solution mapping
    $ltm->add_problem_solution(
        "syntax error near }",
        "Check for missing semicolon",
        ["lib/CLIO/Module.pm:45"]
    );
    
    # Retrieve relevant patterns
    my $patterns = $ltm->get_patterns_for_context("lib/CLIO/Core/");
    
    # Save/load
    $ltm->save(".clio/ltm.json");
    my $ltm = CLIO::Memory::LongTerm->load(".clio/ltm.json");

=cut

print STDERR "[TRACE] CLIO::Memory::LongTerm loaded\n" if should_log('DEBUG');

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        debug => $args{debug} // 0,
        
        # Core data structure
        patterns => {
            # Facts discovered about the codebase
            discoveries => [],
            # example: {fact => "Config in CLIO::Core::Config", confidence => 1.0, verified => 1, timestamp => ...}
            
            # Error messages and their solutions
            problem_solutions => [],
            # example: {error => "syntax error near }", solution => "Check semicolon", solved_count => 5, examples => [...]}
            
            # Project-specific code patterns
            code_patterns => [],
            # example: {pattern => "Use error_result() not die", confidence => 0.9, examples => [...]}
            
            # Repeated workflow sequences
            workflows => [],
            # example: {sequence => ["read", "analyze", "fix", "test"], count => 10, success_rate => 0.95}
            
            # Things that broke and why
            failures => [],
            # example: {what => "Changed API without updating callers", impact => "Runtime errors", prevention => "grep first"}
            
            # Rules specific to directories/modules
            context_rules => {},
            # example: {"lib/CLIO/Core/" => ["use strict/warnings", "POD required"]}
        },
        
        # Metadata
        metadata => {
            created => time(),
            last_updated => time(),
            version => "1.0",
        },
    };
    
    bless $self, $class;
    return $self;
}

=head2 add_discovery

Add a discovered fact about the codebase

    $ltm->add_discovery($fact, $confidence, $verified);

=cut

sub add_discovery {
    my ($self, $fact, $confidence, $verified) = @_;
    
    $confidence //= 0.8;
    $verified //= 0;
    
    # Check if already exists
    for my $d (@{$self->{patterns}{discoveries}}) {
        if ($d->{fact} eq $fact) {
            # Update confidence if higher
            if ($confidence > $d->{confidence}) {
                $d->{confidence} = $confidence;
                $d->{verified} = $verified;
                $d->{updated} = time();
            }
            return;
        }
    }
    
    # Add new discovery
    push @{$self->{patterns}{discoveries}}, {
        fact => $fact,
        confidence => $confidence,
        verified => $verified,
        timestamp => time(),
    };
    
    $self->{metadata}{last_updated} = time();
    print STDERR "[DEBUG][LTM] Added discovery: $fact (confidence: $confidence)\n" if should_log('DEBUG');
}

=head2 add_problem_solution

Add a problem-solution mapping from debugging experience

    $ltm->add_problem_solution($error_pattern, $solution, \@examples);

=cut

sub add_problem_solution {
    my ($self, $error, $solution, $examples) = @_;
    
    $examples //= [];
    
    # Check if already exists
    for my $ps (@{$self->{patterns}{problem_solutions}}) {
        if ($ps->{error} eq $error) {
            # Increment solved count
            $ps->{solved_count}++;
            $ps->{updated} = time();
            
            # Add new examples
            for my $ex (@$examples) {
                push @{$ps->{examples}}, $ex unless grep { $_ eq $ex } @{$ps->{examples}};
            }
            return;
        }
    }
    
    # Add new problem-solution
    push @{$self->{patterns}{problem_solutions}}, {
        error => $error,
        solution => $solution,
        solved_count => 1,
        examples => $examples,
        timestamp => time(),
    };
    
    $self->{metadata}{last_updated} = time();
    print STDERR "[DEBUG][LTM] Added problem-solution: $error -> $solution\n" if should_log('DEBUG');
}

=head2 add_code_pattern

Add a code pattern observed in the project

    $ltm->add_code_pattern($pattern_description, $confidence, \@examples);

=cut

sub add_code_pattern {
    my ($self, $pattern, $confidence, $examples) = @_;
    
    $confidence //= 0.7;
    $examples //= [];
    
    # Check if already exists
    for my $cp (@{$self->{patterns}{code_patterns}}) {
        if ($cp->{pattern} eq $pattern) {
            # Increase confidence based on repeated observation
            $cp->{confidence} = ($cp->{confidence} + $confidence) / 2;
            $cp->{updated} = time();
            
            # Add new examples
            for my $ex (@$examples) {
                push @{$cp->{examples}}, $ex unless grep { $_ eq $ex } @{$cp->{examples}};
            }
            return;
        }
    }
    
    # Add new code pattern
    push @{$self->{patterns}{code_patterns}}, {
        pattern => $pattern,
        confidence => $confidence,
        examples => $examples,
        timestamp => time(),
    };
    
    $self->{metadata}{last_updated} = time();
    print STDERR "[DEBUG][LTM] Added code pattern: $pattern (confidence: $confidence)\n" if should_log('DEBUG');
}

=head2 add_workflow

Add a successful workflow sequence

    $ltm->add_workflow(\@sequence, $success);

=cut

sub add_workflow {
    my ($self, $sequence, $success) = @_;
    
    $success //= 1;
    
    my $seq_key = join("->", @$sequence);
    
    # Check if already exists
    for my $wf (@{$self->{patterns}{workflows}}) {
        my $wf_key = join("->", @{$wf->{sequence}});
        if ($wf_key eq $seq_key) {
            # Update success rate
            $wf->{count}++;
            my $successes = int($wf->{success_rate} * ($wf->{count} - 1));
            $successes += $success ? 1 : 0;
            $wf->{success_rate} = $successes / $wf->{count};
            $wf->{updated} = time();
            return;
        }
    }
    
    # Add new workflow
    push @{$self->{patterns}{workflows}}, {
        sequence => $sequence,
        count => 1,
        success_rate => $success ? 1.0 : 0.0,
        timestamp => time(),
    };
    
    $self->{metadata}{last_updated} = time();
    print STDERR "[DEBUG][LTM] Added workflow: $seq_key\n" if should_log('DEBUG');
}

=head2 add_failure

Record a failure and how to prevent it

    $ltm->add_failure($what_broke, $impact, $prevention);

=cut

sub add_failure {
    my ($self, $what, $impact, $prevention) = @_;
    
    # Check if already exists
    for my $f (@{$self->{patterns}{failures}}) {
        if ($f->{what} eq $what) {
            $f->{occurrences}++;
            $f->{updated} = time();
            return;
        }
    }
    
    # Add new failure
    push @{$self->{patterns}{failures}}, {
        what => $what,
        impact => $impact,
        prevention => $prevention,
        occurrences => 1,
        timestamp => time(),
    };
    
    $self->{metadata}{last_updated} = time();
    print STDERR "[DEBUG][LTM] Added failure: $what\n" if should_log('DEBUG');
}

=head2 add_context_rule

Add a rule for a specific directory or module

    $ltm->add_context_rule("lib/CLIO/Core/", "Always use strict/warnings");

=cut

sub add_context_rule {
    my ($self, $context, $rule) = @_;
    
    $self->{patterns}{context_rules}{$context} //= [];
    
    # Add if not already present
    unless (grep { $_ eq $rule } @{$self->{patterns}{context_rules}{$context}}) {
        push @{$self->{patterns}{context_rules}{$context}}, $rule;
        $self->{metadata}{last_updated} = time();
        print STDERR "[DEBUG][LTM] Added context rule for $context: $rule\n" if should_log('DEBUG');
    }
}

=head2 get_patterns_for_context

Get all relevant patterns for a given context (file path, module, etc)

    my $patterns = $ltm->get_patterns_for_context("lib/CLIO/Core/Module.pm");

=cut

sub get_patterns_for_context {
    my ($self, $context) = @_;
    
    my $result = {
        discoveries => $self->{patterns}{discoveries},  # All discoveries
        context_rules => [],
        code_patterns => $self->{patterns}{code_patterns},  # All code patterns
    };
    
    # Find matching context rules
    for my $ctx (keys %{$self->{patterns}{context_rules}}) {
        if ($context =~ /^\Q$ctx\E/ || $context =~ /\Q$ctx\E/) {
            push @{$result->{context_rules}}, {
                context => $ctx,
                rules => $self->{patterns}{context_rules}{$ctx}
            };
        }
    }
    
    return $result;
}

=head2 search_solutions

Search for solutions to a given error pattern

    my @solutions = $ltm->search_solutions("syntax error");

=cut

sub search_solutions {
    my ($self, $error_pattern) = @_;
    
    my @matches;
    
    for my $ps (@{$self->{patterns}{problem_solutions}}) {
        if ($ps->{error} =~ /\Q$error_pattern\E/i || $error_pattern =~ /\Q$ps->{error}\E/i) {
            push @matches, $ps;
        }
    }
    
    # Sort by solved_count descending
    @matches = sort { $b->{solved_count} <=> $a->{solved_count} } @matches;
    
    return \@matches;
}

=head2 get_all_patterns

Get all patterns for display

    my $all = $ltm->get_all_patterns();

=cut

sub get_all_patterns {
    my ($self) = @_;
    return $self->{patterns};
}

=head2 get_summary

Get a summary of stored patterns

    my $summary = $ltm->get_summary();

=cut

sub get_summary {
    my ($self) = @_;
    
    return {
        discoveries => scalar(@{$self->{patterns}{discoveries}}),
        problem_solutions => scalar(@{$self->{patterns}{problem_solutions}}),
        code_patterns => scalar(@{$self->{patterns}{code_patterns}}),
        workflows => scalar(@{$self->{patterns}{workflows}}),
        failures => scalar(@{$self->{patterns}{failures}}),
        context_rules => scalar(keys %{$self->{patterns}{context_rules}}),
        last_updated => $self->{metadata}{last_updated},
    };
}

=head2 save

Save LTM to JSON file

    $ltm->save(".clio/ltm.json");

=cut

sub save {
    my ($self, $file) = @_;
    
    return unless $file;
    
    # Ensure directory exists
    if ($file =~ m{^(.*)/[^/]+$}) {
        my $dir = $1;
        unless (-d $dir) {
            require File::Path;
            File::Path::make_path($dir);
        }
    }
    
    my $data = {
        patterns => $self->{patterns},
        metadata => $self->{metadata},
    };
    
    open my $fh, '>', $file or die "Cannot save LTM to $file: $!";
    print $fh JSON::PP->new->pretty->canonical->encode($data);
    close $fh;
    
    print STDERR "[DEBUG][LTM] Saved to $file\n" if should_log('DEBUG');
}

=head2 load

Load LTM from JSON file

    my $ltm = CLIO::Memory::LongTerm->load(".clio/ltm.json");

=cut

sub load {
    my ($class, $file, %args) = @_;
    
    return $class->new(%args) unless -e $file;
    
    open my $fh, '<', $file or do {
        print STDERR "[DEBUG][LTM] Cannot load from $file: $!\n" if should_log('DEBUG');
        return $class->new(%args);
    };
    
    local $/;
    my $json = <$fh>;
    close $fh;
    
    my $data = eval { JSON::PP->new->decode($json) };
    if ($@) {
        print STDERR "[DEBUG][LTM] Failed to parse $file: $@\n" if should_log('DEBUG');
        return $class->new(%args);
    }
    
    my $self = $class->new(%args);
    $self->{patterns} = $data->{patterns} if $data->{patterns};
    $self->{metadata} = $data->{metadata} if $data->{metadata};
    
    print STDERR "[DEBUG][LTM] Loaded from $file\n" if should_log('DEBUG');
    return $self;
}

=head2 Deprecated: store_pattern / retrieve_pattern

Legacy methods for backward compatibility

=cut

sub store_pattern {
    my ($self, $key, $value) = @_;
    # Legacy method - convert to discovery
    $self->add_discovery("$key: $value", 0.5);
}

sub retrieve_pattern {
    my ($self, $key) = @_;
    # Legacy method - search discoveries
    for my $d (@{$self->{patterns}{discoveries}}) {
        return $d->{fact} if $d->{fact} =~ /^\Q$key\E:/;
    }
    return undef;
}

sub list_patterns {
    my ($self) = @_;
    my @facts = map { $_->{fact} } @{$self->{patterns}{discoveries}};
    return \@facts;
}

1;
