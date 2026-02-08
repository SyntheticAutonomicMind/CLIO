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
Unlike static configuration (.clio/instructions.md), LTM is populated by AGENTS.

IMPORTANT FOR AGENTS: Use the memory_operations tool to store discoveries when:
  - You fix a bug or find a root cause
  - You learn a new code pattern that applies project-wide
  - You discover a problem-solution mapping
  - You complete complex tasks with successful workflows

Syntax: memory_operations(operation: "add_discovery", fact: "...", confidence: 0.9)
        memory_operations(operation: "add_solution", error: "...", solution: "...")
        memory_operations(operation: "add_pattern", pattern: "...", confidence: 0.85)

This keeps LTM clean and prevents noise from heuristic auto-capture.

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

=head2 query_discoveries

Query discoveries with optional limit

    my $discoveries = $ltm->query_discoveries(limit => 5);

=cut

sub query_discoveries {
    my ($self, %args) = @_;
    my $limit = $args{limit} || 0;
    
    my @items = @{$self->{patterns}{discoveries}};
    
    if ($limit > 0 && @items > $limit) {
        @items = @items[0..$limit-1];
    }
    
    return \@items;
}

=head2 query_solutions

Query problem solutions with optional limit

    my $solutions = $ltm->query_solutions(limit => 5);

=cut

sub query_solutions {
    my ($self, %args) = @_;
    my $limit = $args{limit} || 0;
    
    my @items = @{$self->{patterns}{problem_solutions}};
    
    if ($limit > 0 && @items > $limit) {
        @items = @items[0..$limit-1];
    }
    
    return \@items;
}

=head2 query_patterns

Query code patterns with optional limit

    my $patterns = $ltm->query_patterns(limit => 5);

=cut

sub query_patterns {
    my ($self, %args) = @_;
    my $limit = $args{limit} || 0;
    
    my @items = @{$self->{patterns}{code_patterns}};
    
    if ($limit > 0 && @items > $limit) {
        @items = @items[0..$limit-1];
    }
    
    return \@items;
}

=head2 query_workflows

Query workflows with optional limit

    my $workflows = $ltm->query_workflows(limit => 5);

=cut

sub query_workflows {
    my ($self, %args) = @_;
    my $limit = $args{limit} || 0;
    
    my @items = @{$self->{patterns}{workflows}};
    
    if ($limit > 0 && @items > $limit) {
        @items = @items[0..$limit-1];
    }
    
    return \@items;
}

=head2 query_failures

Query failure patterns with optional limit

    my $failures = $ltm->query_failures(limit => 5);

=cut

sub query_failures {
    my ($self, %args) = @_;
    my $limit = $args{limit} || 0;
    
    my @items = @{$self->{patterns}{failures}};
    
    if ($limit > 0 && @items > $limit) {
        @items = @items[0..$limit-1];
    }
    
    return \@items;
}

=head2 query_context_rules

Query context rules with optional limit

    my $rules = $ltm->query_context_rules(limit => 5);

=cut

sub query_context_rules {
    my ($self, %args) = @_;
    my $limit = $args{limit} || 0;
    
    my @items;
    for my $ctx (keys %{$self->{patterns}{context_rules}}) {
        for my $rule (@{$self->{patterns}{context_rules}{$ctx}}) {
            push @items, {
                context => $ctx,
                %$rule
            };
        }
    }
    
    if ($limit > 0 && @items > $limit) {
        @items = @items[0..$limit-1];
    }
    
    return \@items;
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
    
    # Atomic write: write to temp file, then rename
    # Use PID in temp filename to prevent race conditions with multiple agents
    my $temp_file = $file . '.tmp.' . $$;  # $$ = process ID
    
    eval {
        open my $fh, '>:encoding(UTF-8)', $temp_file or die "Cannot create temp LTM file: $!";
        print $fh JSON::PP->new->pretty->canonical->encode($data);
        close $fh;
        
        # Atomic rename (overwrites target file atomically on Unix)
        rename $temp_file, $file or die "Cannot save LTM (rename failed): $!";
    };
    if ($@) {
        # Clean up temp file if it exists
        unlink $temp_file if -f $temp_file;
        die $@;
    }
    
    print STDERR "[DEBUG][LTM] Saved to $file\n" if should_log('DEBUG');
}

=head2 load

Load LTM from JSON file

    my $ltm = CLIO::Memory::LongTerm->load(".clio/ltm.json");

=cut

sub load {
    my ($class, $file, %args) = @_;
    
    return $class->new(%args) unless -e $file;
    
    open my $fh, '<:encoding(UTF-8)', $file or do {
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

=head2 prune

Prune old, low-confidence, or duplicate entries to keep LTM manageable.

Arguments:
- max_discoveries: Max number of discoveries to keep (default: 50)
- max_solutions: Max number of problem-solutions to keep (default: 50)
- max_patterns: Max number of code patterns to keep (default: 30)
- max_workflows: Max number of workflows to keep (default: 20)
- max_failures: Max number of failures to keep (default: 30)
- min_confidence: Remove entries below this confidence (default: 0.3)
- max_age_days: Remove entries older than this (default: 90)

Returns: Hash with counts of entries removed per category

    my $removed = $ltm->prune(max_discoveries => 30, min_confidence => 0.5);
    print "Removed $removed->{discoveries} discoveries\n";

=cut

sub prune {
    my ($self, %args) = @_;
    
    my $max_discoveries = $args{max_discoveries} // 50;
    my $max_solutions = $args{max_solutions} // 50;
    my $max_patterns = $args{max_patterns} // 30;
    my $max_workflows = $args{max_workflows} // 20;
    my $max_failures = $args{max_failures} // 30;
    my $min_confidence = $args{min_confidence} // 0.3;
    my $max_age_days = $args{max_age_days} // 90;
    
    my $cutoff_time = time() - ($max_age_days * 86400);
    my %removed = (
        discoveries => 0,
        solutions => 0,
        patterns => 0,
        workflows => 0,
        failures => 0,
    );
    
    # Helper to filter array by age and confidence
    my $filter_and_limit = sub {
        my ($array, $limit, $has_confidence) = @_;
        my @original = @$array;
        my @filtered;
        
        for my $item (@original) {
            my $timestamp = $item->{timestamp} || $item->{updated} || 0;
            my $confidence = $item->{confidence} // 1.0;
            
            # Keep if: recent enough AND (no confidence field OR confidence above threshold)
            if ($timestamp >= $cutoff_time) {
                if (!$has_confidence || $confidence >= $min_confidence) {
                    push @filtered, $item;
                }
            }
        }
        
        # Sort by timestamp (newest first) and limit
        @filtered = sort { 
            ($b->{timestamp} || $b->{updated} || 0) <=> 
            ($a->{timestamp} || $a->{updated} || 0) 
        } @filtered;
        
        if (@filtered > $limit) {
            @filtered = @filtered[0..$limit-1];
        }
        
        return (\@filtered, scalar(@original) - scalar(@filtered));
    };
    
    # Prune discoveries
    my ($new_discoveries, $removed_discoveries) = $filter_and_limit->(
        $self->{patterns}{discoveries}, $max_discoveries, 1
    );
    $self->{patterns}{discoveries} = $new_discoveries;
    $removed{discoveries} = $removed_discoveries;
    
    # Prune problem_solutions
    my ($new_solutions, $removed_solutions) = $filter_and_limit->(
        $self->{patterns}{problem_solutions}, $max_solutions, 0
    );
    $self->{patterns}{problem_solutions} = $new_solutions;
    $removed{solutions} = $removed_solutions;
    
    # Prune code_patterns
    my ($new_patterns, $removed_patterns) = $filter_and_limit->(
        $self->{patterns}{code_patterns}, $max_patterns, 1
    );
    $self->{patterns}{code_patterns} = $new_patterns;
    $removed{patterns} = $removed_patterns;
    
    # Prune workflows
    my ($new_workflows, $removed_workflows) = $filter_and_limit->(
        $self->{patterns}{workflows}, $max_workflows, 0
    );
    $self->{patterns}{workflows} = $new_workflows;
    $removed{workflows} = $removed_workflows;
    
    # Prune failures
    my ($new_failures, $removed_failures) = $filter_and_limit->(
        $self->{patterns}{failures}, $max_failures, 0
    );
    $self->{patterns}{failures} = $new_failures;
    $removed{failures} = $removed_failures;
    
    # Update metadata
    $self->{metadata}{last_updated} = time();
    $self->{metadata}{last_pruned} = time();
    
    my $total = $removed{discoveries} + $removed{solutions} + $removed{patterns} + 
                $removed{workflows} + $removed{failures};
    
    print STDERR "[DEBUG][LTM] Pruned $total entries\n" if should_log('DEBUG') && $total > 0;
    
    return \%removed;
}

=head2 get_stats

Get statistics about the LTM database

Returns: Hash with counts and metadata

    my $stats = $ltm->get_stats();
    print "Discoveries: $stats->{discoveries}\n";

=cut

sub get_stats {
    my ($self) = @_;
    
    return {
        discoveries => scalar(@{$self->{patterns}{discoveries}}),
        solutions => scalar(@{$self->{patterns}{problem_solutions}}),
        patterns => scalar(@{$self->{patterns}{code_patterns}}),
        workflows => scalar(@{$self->{patterns}{workflows}}),
        failures => scalar(@{$self->{patterns}{failures}}),
        context_rules => scalar(keys %{$self->{patterns}{context_rules}}),
        created => $self->{metadata}{created},
        last_updated => $self->{metadata}{last_updated},
        last_pruned => $self->{metadata}{last_pruned},
    };
}

1;
