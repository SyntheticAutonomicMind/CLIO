# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Memory::LongTerm;

use strict;
use warnings;
use CLIO::Core::Logger qw(log_debug log_info);
use CLIO::Util::JSON qw(encode_json decode_json encode_json_pretty);
use utf8;
use Carp qw(croak);
use POSIX qw(strftime);

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

log_debug('LongTerm', "CLIO::Memory::LongTerm loaded");

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
    $fact = $self->absolutize_dates($fact);
    
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
    log_debug('LTM', "Added discovery: $fact (confidence: $confidence)");
}

=head2 add_problem_solution

Add a problem-solution mapping from debugging experience

    $ltm->add_problem_solution($error_pattern, $solution, \@examples);

=cut

sub add_problem_solution {
    my ($self, $error, $solution, $examples) = @_;
    
    $examples //= [];
    $error = $self->absolutize_dates($error);
    $solution = $self->absolutize_dates($solution);
    
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
    log_debug('LTM', "Added problem-solution: $error -> $solution");
}

=head2 add_code_pattern

Add a code pattern observed in the project

    $ltm->add_code_pattern($pattern_description, $confidence, \@examples);

=cut

sub add_code_pattern {
    my ($self, $pattern, $confidence, $examples) = @_;
    
    $confidence //= 0.7;
    $examples //= [];
    $pattern = $self->absolutize_dates($pattern);
    
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
    log_debug('LTM', "Added code pattern: $pattern (confidence: $confidence)");
}

=head2 update_entry

Update an existing LTM entry by searching for matching text and replacing it.
Searches across the specified type (or all types) using substring matching.

    my $updated = $ltm->update_entry(
        search      => 'deploy to marvin',
        replacement => 'deploy to zaphod',
        type        => 'discovery',      # optional: discovery, solution, pattern, or undef for all
    );

Returns: hashref { found => 0|1, type => $matched_type, old_text => $old, new_text => $new }

=cut

sub update_entry {
    my ($self, %args) = @_;
    
    my $search = $args{search} or return { found => 0, error => 'Missing search text' };
    my $replacement = $args{replacement} or return { found => 0, error => 'Missing replacement text' };
    my $type_filter = $args{type};  # optional
    my $search_lc = lc($search);
    my $now = time();
    
    $replacement = $self->absolutize_dates($replacement);
    
    # Search discoveries
    if (!$type_filter || $type_filter eq 'discovery') {
        for my $d (@{$self->{patterns}{discoveries} || []}) {
            if (index(lc($d->{fact} || ''), $search_lc) >= 0) {
                my $old = $d->{fact};
                $d->{fact} = $replacement;
                $d->{updated} = $now;
                $d->{search_count} = ($d->{search_count} || 0) + 1;
                $self->{metadata}{last_updated} = $now;
                log_debug('LTM', "Updated discovery: '$old' -> '$replacement'");
                return { found => 1, type => 'discovery', old_text => $old, new_text => $replacement };
            }
        }
    }
    
    # Search solutions (match against error or solution text)
    if (!$type_filter || $type_filter eq 'solution') {
        for my $s (@{$self->{patterns}{problem_solutions} || []}) {
            my $combined = lc(($s->{error} || '') . ' ' . ($s->{solution} || ''));
            if (index($combined, $search_lc) >= 0) {
                my $old_error = $s->{error};
                my $old_solution = $s->{solution};
                # If replacement contains ' -> ', split into error/solution
                if ($replacement =~ /^(.+?)\s*->\s*(.+)$/) {
                    $s->{error} = $self->absolutize_dates($1);
                    $s->{solution} = $self->absolutize_dates($2);
                } else {
                    # Replace whichever field matched
                    if (index(lc($s->{error} || ''), $search_lc) >= 0) {
                        $s->{error} = $replacement;
                    } else {
                        $s->{solution} = $replacement;
                    }
                }
                $s->{updated} = $now;
                $s->{search_count} = ($s->{search_count} || 0) + 1;
                $self->{metadata}{last_updated} = $now;
                log_debug('LTM', "Updated solution: error '$old_error' -> '$s->{error}'");
                return {
                    found => 1, type => 'solution',
                    old_text => "$old_error -> $old_solution",
                    new_text => "$s->{error} -> $s->{solution}",
                };
            }
        }
    }
    
    # Search patterns
    if (!$type_filter || $type_filter eq 'pattern') {
        for my $p (@{$self->{patterns}{code_patterns} || []}) {
            if (index(lc($p->{pattern} || ''), $search_lc) >= 0) {
                my $old = $p->{pattern};
                $p->{pattern} = $replacement;
                $p->{updated} = $now;
                $p->{search_count} = ($p->{search_count} || 0) + 1;
                $self->{metadata}{last_updated} = $now;
                log_debug('LTM', "Updated pattern: '$old' -> '$replacement'");
                return { found => 1, type => 'pattern', old_text => $old, new_text => $replacement };
            }
        }
    }
    
    return { found => 0, error => "No entry matching '$search' found" };
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
    log_debug('LTM', "Added workflow: $seq_key");
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
    log_debug('LTM', "Added failure: $what");
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
        log_debug('LTM', "Added context rule for $context: $rule");
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

Get a summary of stored patterns (delegates to get_stats)

    my $summary = $ltm->get_summary();

=cut

sub get_summary {
    my ($self) = @_;
    return $self->get_stats();
}

=head2 search_entries

Search across all LTM entries by keyword. Optionally refreshes matched entries'
timestamps to prevent decay for actively-used knowledge.

    my $results = $ltm->search_entries('terminal corruption', refresh => 1);

Returns arrayref of matching entries with type, text preview, and confidence.

=cut

sub search_entries {
    my ($self, $query, %opts) = @_;
    return [] unless $query && length($query) > 0;
    
    my $refresh = $opts{refresh} || 0;
    my $now = time();
    my @results;
    my $query_lc = lc($query);
    my @query_words = split /\s+/, $query_lc;
    
    # Search discoveries
    for my $entry (@{$self->{patterns}{discoveries} || []}) {
        my $text = lc($entry->{fact} || '');
        if (_text_matches($text, $query_lc, \@query_words)) {
            push @results, {
                type => 'discovery',
                text => $entry->{fact},
                confidence => $entry->{confidence} || 0.5,
            };
            if ($refresh) {
                $entry->{updated} = $now;
                $entry->{search_count} = ($entry->{search_count} || 0) + 1;
            }
        }
    }
    
    # Search solutions
    for my $entry (@{$self->{patterns}{problem_solutions} || []}) {
        my $text = lc(($entry->{error} || '') . ' ' . ($entry->{solution} || ''));
        if (_text_matches($text, $query_lc, \@query_words)) {
            push @results, {
                type => 'solution',
                text => ($entry->{error} || '') . ' -> ' . ($entry->{solution} || ''),
                confidence => $entry->{confidence} || 0.5,
            };
            if ($refresh) {
                $entry->{updated} = $now;
                $entry->{search_count} = ($entry->{search_count} || 0) + 1;
            }
        }
    }
    
    # Search code patterns
    for my $entry (@{$self->{patterns}{code_patterns} || []}) {
        my $text = lc($entry->{pattern} || '');
        if (_text_matches($text, $query_lc, \@query_words)) {
            push @results, {
                type => 'pattern',
                text => $entry->{pattern},
                confidence => $entry->{confidence} || 0.5,
            };
            if ($refresh) {
                $entry->{updated} = $now;
                $entry->{search_count} = ($entry->{search_count} || 0) + 1;
            }
        }
    }
    
    return \@results;
}

# Check if text matches query (exact substring or 2+ word matches)
sub _text_matches {
    my ($text, $query_lc, $query_words) = @_;
    
    # Exact substring match
    return 1 if index($text, $query_lc) >= 0;
    
    # Multi-word: at least 2 query words present (or all if only 1 word)
    my $threshold = @$query_words > 1 ? 2 : 1;
    my $hits = 0;
    for my $word (@$query_words) {
        next if length($word) < 3;  # skip short words
        $hits++ if index($text, $word) >= 0;
    }
    return $hits >= $threshold;
}

=head2 score_entry

Score an LTM entry for ranking. Higher score = more relevant.

Scoring factors:
- confidence (0-1)
- recency decay (exponential, half-life ~60 days)
- type weight (solutions > patterns > discoveries)
- usage weight (solved_count, verified flag)

Arguments:
- $entry: Entry hashref
- $type: 'discovery', 'solution', or 'pattern'
- $now: Current timestamp (optional, defaults to time())

Returns: Numeric score (0+)

=cut

sub score_entry {
    my ($self, $entry, $type, $now) = @_;

    $now //= time();
    my $confidence = $entry->{confidence} // 0.5;

    # Recency: exponential decay with ~60-day half-life
    my $timestamp = $entry->{updated} || $entry->{timestamp} || $now;
    my $age_days = ($now - $timestamp) / 86400;
    my $recency = exp(-0.693 * $age_days / 60);  # ln(2)/60 ~ 0.01155

    # Type weight: solutions are actionable, patterns are conventions
    my %type_weights = (
        solution  => 1.3,
        pattern   => 1.1,
        discovery => 1.0,
        workflow  => 0.8,
        failure   => 0.9,
    );
    my $type_weight = $type_weights{$type} // 1.0;

    # Usage weight: entries that have been applied/verified are more valuable
    my $usage = 1.0;
    if ($type eq 'solution') {
        my $solved = $entry->{solved_count} // 1;
        $usage = 1.0 + log(1 + $solved) * 0.3;  # diminishing returns
    } elsif ($type eq 'discovery') {
        $usage = $entry->{verified} ? 1.2 : 0.9;
    }

    # Search weight: entries actively searched for by agents are more valuable
    my $search_count = $entry->{search_count} || 0;
    if ($search_count > 0) {
        $usage += log(1 + $search_count) * 0.2;  # diminishing returns
    }

    return $confidence * $recency * $type_weight * $usage;
}

=head2 get_scored_entries

Get all entries scored and sorted, grouped by type.

Returns: ArrayRef of { entry => $entry, type => $type, score => $score }

=cut

sub get_scored_entries {
    my ($self, $now) = @_;

    $now //= time();
    my @scored;

    for my $d (@{$self->{patterns}{discoveries} || []}) {
        push @scored, { entry => $d, type => 'discovery', score => $self->score_entry($d, 'discovery', $now) };
    }
    for my $s (@{$self->{patterns}{problem_solutions} || []}) {
        push @scored, { entry => $s, type => 'solution', score => $self->score_entry($s, 'solution', $now) };
    }
    for my $p (@{$self->{patterns}{code_patterns} || []}) {
        push @scored, { entry => $p, type => 'pattern', score => $self->score_entry($p, 'pattern', $now) };
    }
    for my $w (@{$self->{patterns}{workflows} || []}) {
        push @scored, { entry => $w, type => 'workflow', score => $self->score_entry($w, 'workflow', $now) };
    }
    for my $f (@{$self->{patterns}{failures} || []}) {
        push @scored, { entry => $f, type => 'failure', score => $self->score_entry($f, 'failure', $now) };
    }

    @scored = sort { $b->{score} <=> $a->{score} } @scored;
    return \@scored;
}

=head2 render_budgeted_section

Render an LTM section for system prompt injection within a token budget.

Arguments:
- max_chars: Maximum characters for the section (default: 12000, ~3000 tokens)

Returns: ($rendered_text, $included_count, $total_count)

=cut

sub render_budgeted_section {
    my ($self, %args) = @_;

    my $max_chars = $args{max_chars} // 12000;
    my $now = time();

    my $scored = $self->get_scored_entries($now);
    my $total_count = scalar @$scored;
    return ('', 0, 0) if $total_count == 0;

    # Render entries by score, accumulating into budget
    my @included;
    my @excluded;
    my $chars_used = 0;

    # Reserve space for header + footer (~600 chars)
    my $budget = $max_chars - 600;

    for my $item (@$scored) {
        my $rendered = $self->_render_entry($item->{entry}, $item->{type});
        my $len = length($rendered);

        if ($chars_used + $len <= $budget) {
            push @included, $item;
            $chars_used += $len;
        } else {
            push @excluded, $item;
        }
    }

    # Build the section
    my $section = "## Long-Term Memory Patterns\n\n";
    $section .= "The following are the highest-priority patterns from previous sessions. ";
    $section .= "Additional memories exist - use `memory_operations(operation: \"search\", query: \"keyword\")` to find specific topics.\n\n";

    # Group included entries by type for rendering
    my %by_type;
    for my $item (@included) {
        push @{$by_type{$item->{type}}}, $item;
    }

    # Render in standard order
    my @type_order = (
        ['discovery', 'Key Discoveries'],
        ['solution',  'Problem Solutions'],
        ['pattern',   'Code Patterns'],
        ['workflow',  'Successful Workflows'],
        ['failure',   'Known Failures (Avoid These)'],
    );

    for my $pair (@type_order) {
        my ($type, $heading) = @$pair;
        next unless $by_type{$type} && @{$by_type{$type}};

        $section .= "### $heading\n";
        for my $item (@{$by_type{$type}}) {
            $section .= $self->_render_entry($item->{entry}, $type);
        }
        $section .= "\n";
    }

    $section .= "_These patterns are project-specific and should inform your approach to similar tasks._\n";

    # Add index footer for excluded entries
    if (@excluded) {
        my $footer = $self->_render_index_footer(\@excluded, scalar(@included), $total_count);
        $section .= "\n$footer";
    }

    return ($section, scalar(@included), $total_count);
}

=head2 _render_entry

Render a single LTM entry as markdown text.

=cut

sub _render_entry {
    my ($self, $entry, $type) = @_;

    if ($type eq 'discovery') {
        my $fact = $entry->{fact} || 'Unknown';
        my $confidence = $entry->{confidence} || 0;
        my $verified = $entry->{verified} ? 'Verified' : 'Unverified';
        return "- **$fact** (Confidence: " . sprintf("%.0f%%", $confidence * 100) . ", $verified)\n";
    }
    elsif ($type eq 'solution') {
        my $error = $entry->{error} || 'Unknown error';
        my $solution = $entry->{solution} || 'No solution';
        my $solved_count = $entry->{solved_count} || 0;
        my $text = "**Problem:** $error\n**Solution:** $solution\n";
        if ($entry->{examples} && @{$entry->{examples}}) {
            $text .= "  Examples: " . join(", ", @{$entry->{examples}}) . "\n";
        }
        $text .= "_Applied successfully $solved_count time" . ($solved_count == 1 ? '' : 's') . "_\n\n";
        return $text;
    }
    elsif ($type eq 'pattern') {
        my $pattern = $entry->{pattern} || 'Unknown pattern';
        my $confidence = $entry->{confidence} || 0;
        my $examples = $entry->{examples} || [];
        my $text = "- **$pattern** (Confidence: " . sprintf("%.0f%%", $confidence * 100) . ")\n";
        if (@$examples) {
            $text .= "  Examples: " . join(", ", @$examples) . "\n";
        }
        return $text;
    }
    elsif ($type eq 'workflow') {
        my $sequence = $entry->{sequence} || [];
        my $success_rate = $entry->{success_rate} || 0;
        my $count = $entry->{count} || 0;
        return '' unless @$sequence;
        return "- " . join(" -> ", @$sequence) . "\n" .
               "  _Success rate: " . sprintf("%.0f%%", $success_rate * 100) . " ($count attempts)_\n";
    }
    elsif ($type eq 'failure') {
        my $what = $entry->{what} || 'Unknown failure';
        my $impact = $entry->{impact} || 'Unknown impact';
        my $prevention = $entry->{prevention} || 'No prevention documented';
        return "- **$what**: $impact\n  _Prevention: ${prevention}_\n";
    }

    return '';
}

=head2 _render_index_footer

Render a compact footer showing what additional memories exist.

Arguments:
- $excluded: ArrayRef of excluded scored entries
- $included_count: Number of included entries
- $total_count: Total number of entries

Returns: Footer text string

=cut

sub _render_index_footer {
    my ($self, $excluded, $included_count, $total_count) = @_;

    # Group excluded by type and extract keywords
    my %by_type;
    for my $item (@$excluded) {
        push @{$by_type{$item->{type}}}, $item;
    }

    my @lines;
    push @lines, "_Showing $included_count of $total_count memories (highest-scored). Additional memories available:_";

    my %type_labels = (
        solution  => 'solutions',
        discovery => 'discoveries',
        pattern   => 'patterns',
        workflow  => 'workflows',
        failure   => 'failure records',
    );

    for my $type (qw(solution discovery pattern workflow failure)) {
        next unless $by_type{$type} && @{$by_type{$type}};
        my $count = scalar @{$by_type{$type}};
        my $label = $type_labels{$type};
        my $keywords = $self->_extract_keywords($by_type{$type}, 5);
        push @lines, "_- $count more $label (topics: $keywords)_";
    }

    push @lines, '_Use `memory_operations(operation: "search", query: "keyword")` to retrieve specific memories._';
    push @lines, '';

    return join("\n", @lines);
}

=head2 _extract_keywords

Extract top N keywords from a set of LTM entries for the index footer.

Arguments:
- $entries: ArrayRef of scored entry hashes
- $n: Number of keywords to return (default: 5)

Returns: Comma-separated keyword string

=cut

sub _extract_keywords {
    my ($self, $entries, $n) = @_;

    $n //= 5;

    # Stop words to exclude
    my %stop = map { $_ => 1 } qw(
        the a an is are was were be been being have has had do does did
        will would shall should may might can could must need to of in
        for on at by with from and or but not no nor so yet both either
        neither each every all any few more most other some such than
        too very just also back again still already always never often
        sometimes this that these those it its they them their he she
        him her his we us our you your if when then how what which who
        where why because since while after before during until unless
        about above below between through into onto upon as use used
        using make sure before after don dont doesn like got into set
    );

    # Collect text from all entries
    my %word_freq;
    for my $item (@$entries) {
        my $e = $item->{entry};
        my $text = '';
        $text .= ($e->{fact} // '') . ' ';
        $text .= ($e->{error} // '') . ' ';
        $text .= ($e->{solution} // '') . ' ';
        $text .= ($e->{pattern} // '') . ' ';
        $text .= ($e->{what} // '') . ' ';

        # Tokenize: split on non-word chars, lowercase, filter
        my @words = map { lc($_) } ($text =~ /([A-Za-z][A-Za-z_-]{2})/g);
        for my $w (@words) {
            next if $stop{$w};
            next if length($w) < 4;  # skip very short words
            $word_freq{$w}++;
        }
    }

    # Sort by frequency, take top N
    my @sorted = sort { $word_freq{$b} <=> $word_freq{$a} || $a cmp $b } keys %word_freq;
    my @top = @sorted[0 .. ($n - 1 < $#sorted ? $n - 1 : $#sorted)];

    return join(', ', @top) || 'various';
}

=head2 consolidate

Run inline consolidation: confidence decay, age-out, hard caps, dedup.
Designed to run synchronously at session start (<100ms).

Arguments (all optional):
- max_age_days: Remove entries older than this with low confidence (default: 90)
- confidence_decay_days: Start decaying after this many days without update (default: 60)
- max_discoveries: Hard cap on discoveries (default: 30)
- max_solutions: Hard cap on solutions (default: 30)
- max_patterns: Hard cap on patterns (default: 20)
- dedup_threshold: Jaccard similarity threshold for dedup (default: 0.7)

Returns: HashRef { removed => N, decayed => N, deduped => N }

=cut

sub consolidate {
    my ($self, %args) = @_;

    my $max_age_days   = $args{max_age_days} // 90;
    my $decay_days     = $args{confidence_decay_days} // 60;
    my $max_disc       = $args{max_discoveries} // 30;
    my $max_sol        = $args{max_solutions} // 30;
    my $max_pat        = $args{max_patterns} // 20;
    my $dedup_thresh   = $args{dedup_threshold} // 0.7;
    my $now = time();

    my $stats = { removed => 0, decayed => 0, deduped => 0 };

    # Phase 1: Confidence decay for stale entries
    for my $category (qw(discoveries problem_solutions code_patterns)) {
        for my $entry (@{$self->{patterns}{$category} || []}) {
            my $last_touch = $entry->{updated} || $entry->{timestamp} || $now;
            my $stale_days = ($now - $last_touch) / 86400;

            if ($stale_days > $decay_days) {
                # Decay 0.1 per 30-day period beyond the threshold
                my $periods = int(($stale_days - $decay_days) / 30);
                my $decay = $periods * 0.1;
                my $old_conf = $entry->{confidence} // 0.5;
                my $new_conf = $old_conf - $decay;
                $new_conf = 0.3 if $new_conf < 0.3;  # floor

                if ($new_conf < $old_conf) {
                    $entry->{confidence} = $new_conf;
                    $stats->{decayed}++;
                }
            }
        }
    }

    # Phase 2: Age-out entries that are old AND low confidence
    my $age_cutoff = $now - ($max_age_days * 86400);
    for my $category (qw(discoveries problem_solutions code_patterns workflows failures)) {
        my @kept;
        for my $entry (@{$self->{patterns}{$category} || []}) {
            my $ts = $entry->{updated} || $entry->{timestamp} || $now;
            my $conf = $entry->{confidence} // 0.5;

            # Keep if recent enough OR high confidence
            if ($ts >= $age_cutoff || $conf >= 0.5) {
                push @kept, $entry;
            } else {
                $stats->{removed}++;
            }
        }
        $self->{patterns}{$category} = \@kept;
    }

    # Phase 3: Deduplication via Jaccard similarity
    for my $category (qw(discoveries problem_solutions code_patterns)) {
        my $entries = $self->{patterns}{$category} || [];
        next unless @$entries > 1;

        my @deduped;
        my @removed_indices;

        for my $i (0 .. $#$entries) {
            next if grep { $_ == $i } @removed_indices;

            my $text_i = $self->_entry_text($entries->[$i], $category);
            my $keep = 1;

            for my $j ($i + 1 .. $#$entries) {
                next if grep { $_ == $j } @removed_indices;

                my $text_j = $self->_entry_text($entries->[$j], $category);
                my $sim = $self->_jaccard_similarity($text_i, $text_j);

                if ($sim >= $dedup_thresh) {
                    # Keep the one with higher confidence (or more recent)
                    my $conf_i = $entries->[$i]{confidence} // 0.5;
                    my $conf_j = $entries->[$j]{confidence} // 0.5;

                    if ($conf_j > $conf_i) {
                        push @removed_indices, $i;
                        $keep = 0;
                        $stats->{deduped}++;
                        last;
                    } else {
                        push @removed_indices, $j;
                        $stats->{deduped}++;
                    }
                }
            }

            push @deduped, $entries->[$i] if $keep;
        }

        $self->{patterns}{$category} = \@deduped;
    }

    # Phase 4: Hard caps (keep highest-scored)
    my %caps = (
        discoveries       => $max_disc,
        problem_solutions => $max_sol,
        code_patterns     => $max_pat,
    );

    for my $category (keys %caps) {
        my $entries = $self->{patterns}{$category} || [];
        next unless @$entries > $caps{$category};

        # Score and sort
        my $type = $category eq 'discoveries' ? 'discovery'
                 : $category eq 'problem_solutions' ? 'solution'
                 : 'pattern';

        my @with_scores = map {
            { entry => $_, score => $self->score_entry($_, $type, $now) }
        } @$entries;

        @with_scores = sort { $b->{score} <=> $a->{score} } @with_scores;

        my $over = @with_scores - $caps{$category};
        splice(@with_scores, $caps{$category});
        $stats->{removed} += $over;

        $self->{patterns}{$category} = [ map { $_->{entry} } @with_scores ];
    }

    # Update metadata
    $self->{metadata}{last_consolidated} = $now;
    $self->{metadata}{last_updated} = $now;

    my $total_changes = $stats->{removed} + $stats->{decayed} + $stats->{deduped};
    if ($total_changes > 0) {
        log_info('LTM', "Consolidation: removed=$stats->{removed}, decayed=$stats->{decayed}, deduped=$stats->{deduped}");
    }

    return $stats;
}

=head2 maybe_consolidate

Check gate conditions and run consolidation if needed.
Called at session start during LTM load.

Arguments:
- min_hours: Minimum hours since last consolidation (default: 24)
- min_entries: Minimum total entries before consolidating (default: 20)

Returns: HashRef of consolidation stats, or undef if skipped

=cut

sub maybe_consolidate {
    my ($self, %args) = @_;

    my $min_hours   = $args{min_hours} // 24;
    my $min_entries = $args{min_entries} // 20;
    my $now = time();

    # Gate: enough time since last consolidation?
    my $last_consol = $self->{metadata}{last_consolidated} // 0;
    my $hours_since = ($now - $last_consol) / 3600;
    if ($hours_since < $min_hours) {
        log_debug('LTM', sprintf("Consolidation skipped: only %.1f hours since last (need %d)", $hours_since, $min_hours));
        return undef;
    }

    # Gate: enough entries to bother?
    my $total = 0;
    for my $cat (qw(discoveries problem_solutions code_patterns workflows failures)) {
        $total += scalar(@{$self->{patterns}{$cat} || []});
    }
    if ($total < $min_entries) {
        log_debug('LTM', "Consolidation skipped: only $total entries (need $min_entries)");
        return undef;
    }

    log_debug('LTM', "Running consolidation ($total entries, ${hours_since}h since last)");
    return $self->consolidate(%args);
}

=head2 _entry_text

Extract text content from an entry for comparison.

=cut

sub _entry_text {
    my ($self, $entry, $category) = @_;

    if ($category eq 'discoveries') {
        return $entry->{fact} // '';
    } elsif ($category eq 'problem_solutions') {
        return ($entry->{error} // '') . ' ' . ($entry->{solution} // '');
    } elsif ($category eq 'code_patterns') {
        return $entry->{pattern} // '';
    }
    return '';
}

=head2 _jaccard_similarity

Compute Jaccard similarity between two text strings.

=cut

sub _jaccard_similarity {
    my ($self, $text_a, $text_b) = @_;

    my @words_a = map { lc($_) } ($text_a =~ /(\w{3})/g);
    my @words_b = map { lc($_) } ($text_b =~ /(\w{3})/g);

    return 0 unless @words_a && @words_b;

    my %set_a = map { $_ => 1 } @words_a;
    my %set_b = map { $_ => 1 } @words_b;

    my $intersection = 0;
    for my $w (keys %set_a) {
        $intersection++ if $set_b{$w};
    }

    my %union = (%set_a, %set_b);
    my $union_size = scalar keys %union;

    return $union_size ? $intersection / $union_size : 0;
}

=head2 absolutize_dates

Replace relative date references in text with absolute dates.
Called when storing new entries.

Arguments:
- $text: Text to process

Returns: Text with relative dates replaced

=cut

sub absolutize_dates {
    my ($self, $text) = @_;
    return $text unless defined $text;

    my $now = time();
    my %replacements = (
        'today'         => strftime('%Y-%m-%d', localtime($now)),
        'yesterday'     => strftime('%Y-%m-%d', localtime($now - 86400)),
        'last week'     => strftime('week of %Y-%m-%d', localtime($now - 7 * 86400)),
        'this week'     => strftime('week of %Y-%m-%d', localtime($now)),
        'last month'    => strftime('%Y-%m', localtime($now - 30 * 86400)),
        'this month'    => strftime('%Y-%m', localtime($now)),
    );

    for my $relative (keys %replacements) {
        my $absolute = $replacements{$relative};
        $text =~ s/\b\Q$relative\E\b/$absolute/gi;
    }

    return $text;
}

=head2 get_stats

Get detailed statistics about stored patterns.

Returns: HashRef with counts and metadata

=cut

sub get_stats {
    my ($self) = @_;

    return {
        discoveries       => scalar(@{$self->{patterns}{discoveries} || []}),
        problem_solutions => scalar(@{$self->{patterns}{problem_solutions} || []}),
        code_patterns     => scalar(@{$self->{patterns}{code_patterns} || []}),
        workflows         => scalar(@{$self->{patterns}{workflows} || []}),
        failures          => scalar(@{$self->{patterns}{failures} || []}),
        context_rules     => scalar(keys %{$self->{patterns}{context_rules} || {}}),
        last_updated      => $self->{metadata}{last_updated},
        last_consolidated => $self->{metadata}{last_consolidated},
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
        open my $fh, '>:encoding(UTF-8)', $temp_file or croak "Cannot create temp LTM file: $!";
        print $fh encode_json_pretty($data);
        close $fh;
        
        # Atomic rename (overwrites target file atomically on Unix)
        rename $temp_file, $file or croak "Cannot save LTM (rename failed): $!";
    };
    if ($@) {
        # Clean up temp file if it exists
        unlink $temp_file if -f $temp_file;
        croak $@;
    }
    
    log_debug('LTM', "Saved to $file");
}

=head2 load

Load LTM from JSON file

    my $ltm = CLIO::Memory::LongTerm->load(".clio/ltm.json");

=cut

sub load {
    my ($class, $file, %args) = @_;
    
    return $class->new(%args) unless -e $file;
    
    open my $fh, '<:encoding(UTF-8)', $file or do {
        log_debug('LTM', "Cannot load from $file: $!");
        return $class->new(%args);
    };
    
    local $/;
    my $json = <$fh>;
    close $fh;
    
    my $data = eval { decode_json($json) };
    if ($@) {
        log_debug('LTM', "Failed to parse $file: $@");
        return $class->new(%args);
    }
    
    my $self = $class->new(%args);
    $self->{patterns} = $data->{patterns} if $data->{patterns};
    $self->{metadata} = $data->{metadata} if $data->{metadata};
    
    log_debug('LTM', "Loaded from $file");
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
    
    log_debug('LTM', "Pruned $total entries");
    
    return \%removed;
}


1;
