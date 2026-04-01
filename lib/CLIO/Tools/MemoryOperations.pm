# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Tools::MemoryOperations;

use strict;
use warnings;
use utf8;
use Cwd;
use Carp qw(croak confess);
use parent 'CLIO::Tools::Tool';
use CLIO::Util::ConfigPath qw(get_config_dir);
use CLIO::Util::JSON qw(encode_json decode_json);
use File::Spec;
use feature 'say';

=head1 NAME

CLIO::Tools::MemoryOperations - Memory and RAG operations

=head1 DESCRIPTION

Provides memory storage/retrieval and RAG (Retrieval-Augmented Generation) operations.

=cut

sub new {
    my ($class, %opts) = @_;
    
    return $class->SUPER::new(
        name => 'memory_operations',
        description => q{Memory and Long-Term Memory (LTM) operations.

SESSION-LEVEL MEMORY (key-value pairs stored in .clio/memory/):
-  store - Store information with key and content
   Parameters: key (required), content (required)
   Returns: {success, key, path}
   
-  retrieve - Get stored information by key
   Parameters: key (required)
   Returns: {success, content, timestamp}
   
-  search - Find memories by keyword search
   Parameters: query (required)
   Returns: {success, matches[], count}
   
-  list - List all stored memory keys
   Returns: {success, memories[], count}
   
-  delete - Remove a stored memory by key
   Parameters: key (required)
   Returns: {success}

PROJECT-LEVEL LTM RECALL (searches all previous sessions):
-  recall_sessions - Search all previous session history
   Parameters: 
     query (required) - Text to search for
     max_sessions (optional, default 10) - How many recent sessions to search
     max_results (optional, default 5) - Max matches to return
   Returns: {success, matches[{session_id, role, message_index, preview}]}
   Note: Searches newest sessions first, useful for remembering past work

PROJECT-LEVEL LTM STORAGE (persists facts across all sessions):
-  add_discovery - Store a discovered fact to project LTM
   Parameters:
     fact (required) - The discovery statement
     confidence (optional, 0.0-1.0, default 0.8) - Confidence in discovery
   Returns: {success}
   Example: Discovering that a code pattern exists, important behavior found
   
-  add_solution - Store a problem-solution pair to project LTM
   Parameters:
     error (required) - The problem/error description
     solution (required) - How to fix/solve it
     examples (optional, array) - File paths where this applies
   Returns: {success}
   Example: "If you see X error, the solution is Y"
   
-  add_pattern - Store a code/workflow pattern to project LTM
   Parameters:
     pattern (required) - Description of the pattern
     confidence (optional, 0.0-1.0, default 0.7) - Pattern reliability
     examples (optional, array) - Files demonstrating this pattern
   Returns: {success}
   Example: "Always check for X before doing Y"

LTM MAINTENANCE (agents can self-groom their memory):
-  update_ltm - Update an existing LTM entry (correct outdated information)
   Parameters:
     search_text (required) - Text to find in existing entry (substring match)
     replacement (required) - New text to replace the entry with
     entry_type (optional) - Limit to: discovery, solution, or pattern
   Returns: {success, type, old_text, new_text}
   Use when: LTM contains outdated info (e.g., "deploy to marvin" should be "deploy to zaphod")
   Note: Prefer update_ltm over adding a new entry when correcting existing knowledge

-  prune_ltm - Remove old, low-confidence, or excess LTM entries
   Parameters:
     max_age_days (optional, default 90) - Remove entries older than this
     min_confidence (optional, default 0.3) - Remove entries below this confidence
     max_discoveries (optional, default 50) - Max discoveries to keep
     max_solutions (optional, default 50) - Max solutions to keep
     max_patterns (optional, default 30) - Max patterns to keep
   Returns: {success, removed, remaining}
   Use when: LTM seems cluttered or you want to clean up old/low-quality entries
   
-  ltm_stats - Get statistics about the current LTM database
   Parameters: none
   Returns: {success, stats{discoveries, solutions, patterns, ...}}
   Use when: Checking LTM size before adding more entries

HOW TO USE:
1. Use store/retrieve for temporary per-project notes
2. Use recall_sessions to remember what you learned in previous sessions
3. Use add_discovery/add_solution/add_pattern for important facts to keep
4. Use update_ltm to correct outdated LTM entries instead of adding duplicates
5. All LTM data persists in .clio/ltm.json and is automatically injected
   into future sessions for context
},
        supported_operations => [qw(store retrieve search list delete recall_sessions add_discovery add_solution add_pattern update_ltm prune_ltm ltm_stats)],
        %opts,
    );
}

sub route_operation {
    my ($self, $operation, $params, $context) = @_;
    
    if ($operation eq 'store') {
        return $self->store($params, $context);
    } elsif ($operation eq 'retrieve') {
        return $self->retrieve($params, $context);
    } elsif ($operation eq 'search') {
        return $self->search($params, $context);
    } elsif ($operation eq 'list') {
        return $self->list_memories($params, $context);
    } elsif ($operation eq 'delete') {
        return $self->delete($params, $context);
    } elsif ($operation eq 'recall_sessions') {
        return $self->recall_sessions($params, $context);
    } elsif ($operation eq 'add_discovery') {
        return $self->add_discovery($params, $context);
    } elsif ($operation eq 'add_solution') {
        return $self->add_solution($params, $context);
    } elsif ($operation eq 'add_pattern') {
        return $self->add_pattern($params, $context);
    } elsif ($operation eq 'update_ltm') {
        return $self->update_ltm($params, $context);
    } elsif ($operation eq 'prune_ltm') {
        return $self->prune_ltm($params, $context);
    } elsif ($operation eq 'ltm_stats') {
        return $self->ltm_stats($params, $context);
    }
    
    return $self->error_result("Operation not implemented: $operation");
}

=head2 get_additional_parameters

Define parameters for memory_operations in JSON schema sent to AI.

=cut

sub get_additional_parameters {
    my ($self) = @_;
    
    return {
        key => {
            type => "string",
            description => "Memory key for store/retrieve/delete operations",
        },
        content => {
            type => "string",
            description => "Content to store (for store operation)",
        },
        query => {
            type => "string",
            description => "Search query (for search/recall_sessions operations)",
        },
        max_sessions => {
            type => "integer",
            description => "Maximum number of sessions to search (for recall_sessions, default: 10)",
        },
        max_results => {
            type => "integer",
            description => "Maximum results to return (for recall_sessions, default: 5)",
        },
        fact => {
            type => "string",
            description => "Discovery fact to store (for add_discovery operation)",
        },
        confidence => {
            type => "number",
            description => "Confidence level 0.0-1.0 (for add_discovery/add_pattern operations)",
        },
        error => {
            type => "string",
            description => "Error/problem description (for add_solution operation)",
        },
        solution => {
            type => "string",
            description => "Solution description (for add_solution operation)",
        },
        pattern => {
            type => "string",
            description => "Pattern description (for add_pattern operation)",
        },
        examples => {
            type => "array",
            items => { type => "string" },
            description => "Example file paths (for add_solution/add_pattern operations)",
        },
        max_age_days => {
            type => "integer",
            description => "Max age in days for LTM entries (for prune_ltm, default: 90)",
        },
        min_confidence => {
            type => "number",
            description => "Minimum confidence threshold (for prune_ltm, default: 0.3)",
        },
        max_discoveries => {
            type => "integer",
            description => "Max discoveries to keep (for prune_ltm, default: 50)",
        },
        max_solutions => {
            type => "integer",
            description => "Max solutions to keep (for prune_ltm, default: 50)",
        },
        max_patterns => {
            type => "integer",
            description => "Max patterns to keep (for prune_ltm, default: 30)",
        },
        search_text => {
            type => "string",
            description => "Text to search for in existing LTM entry (for update_ltm operation)",
        },
        replacement => {
            type => "string",
            description => "New text to replace the matched entry with (for update_ltm operation)",
        },
        entry_type => {
            type => "string",
            description => "Type of entry to update: discovery, solution, or pattern (for update_ltm, optional - searches all types if omitted)",
        },
    };
}

sub store {
    my ($self, $params, $context) = @_;
    
    my $key = $params->{key};
    my $content = $params->{content};
    my $memory_dir = $params->{memory_dir} || '.clio/memory';
    
    return $self->error_result("Missing 'key' parameter") unless $key;
    return $self->error_result("Missing 'content' parameter") unless $content;
    
    my $result;
    eval {
        mkdir $memory_dir unless -d $memory_dir;
        
        my $file_path = File::Spec->catfile($memory_dir, "$key.json");
        open my $fh, '>:utf8', $file_path or croak "Cannot write $file_path: $!";
        
        my $data = {
            key => $key,
            content => $content,
            timestamp => time(),
        };
        
        # encode_json can handle UTF-8 data correctly
        print $fh encode_json($data);
        close $fh;
        
        my $action_desc = "storing memory '$key'";
        
        $result = $self->success_result(
            "Memory stored successfully",
            action_description => $action_desc,
            key => $key,
            path => $file_path,
        );
    };
    
    if ($@) {
        return $self->error_result("Failed to store memory: $@");
    }
    
    return $result;
}

sub retrieve {
    my ($self, $params, $context) = @_;
    
    my $key = $params->{key};
    my $memory_dir = $params->{memory_dir} || '.clio/memory';
    
    return $self->error_result("Missing 'key' parameter") unless $key;
    
    my $result;
    eval {
        my $file_path = File::Spec->catfile($memory_dir, "$key.json");
        
        return $self->error_result("Memory not found: $key") unless -f $file_path;
        
        open my $fh, '<:utf8', $file_path or croak "Cannot read $file_path: $!";
        my $json = do { local $/; <$fh> };
        close $fh;
        
        my $data = decode_json($json);
        
        my $action_desc = "retrieving memory '$key'";
        
        $result = $self->success_result(
            $data->{content},
            action_description => $action_desc,
            key => $key,
            timestamp => $data->{timestamp},
        );
    };
    
    if ($@) {
        return $self->error_result("Failed to retrieve memory: $@");
    }
    
    return $result;
}

sub search {
    my ($self, $params, $context) = @_;
    
    my $query = $params->{query};
    my $memory_dir = $params->{memory_dir} || '.clio/memory';
    
    return $self->error_result("Missing 'query' parameter") unless $query;
    
    my $result;
    eval {
        my @matches;
        
        # Search session-level memory files
        if (-d $memory_dir) {
            opendir my $dh, $memory_dir or croak "Cannot open $memory_dir: $!";
            while (my $file = readdir $dh) {
                next unless $file =~ /\.json$/;
                
                my $path = File::Spec->catfile($memory_dir, $file);
                open my $fh, '<:utf8', $path or next;
                my $json = do { local $/; <$fh> };
                close $fh;
                
                my $data = eval { decode_json($json) };
                next unless $data;
                
                if ($data->{content} =~ /\Q$query\E/i || $data->{key} =~ /\Q$query\E/i) {
                    push @matches, {
                        source => 'session_memory',
                        key => $data->{key},
                        content => substr($data->{content}, 0, 200),
                        timestamp => $data->{timestamp},
                    };
                }
            }
            closedir $dh;
        }
        
        # Also search LTM entries and refresh matched entries' timestamps
        my $ltm = eval {
            ref($context) eq 'HASH' ? ($context->{ltm} || $context->{session}{ltm}) : undef;
        };
        my $ltm_matches = 0;
        if ($ltm && $ltm->can('search_entries')) {
            my $ltm_results = $ltm->search_entries($query, refresh => 1);
            for my $entry (@$ltm_results) {
                push @matches, {
                    source => 'ltm',
                    type => $entry->{type},
                    content => substr($entry->{text}, 0, 300),
                    confidence => $entry->{confidence},
                };
                $ltm_matches++;
            }
            # Save LTM if entries were refreshed
            if ($ltm_matches > 0) {
                eval {
                    my $ltm_file = File::Spec->catfile(Cwd::getcwd(), '.clio', 'ltm.json');
                    $ltm->save($ltm_file) if -e $ltm_file;
                };
            }
        }
        
        my $action_desc = "searching memories for '$query' (" . scalar(@matches) . " matches";
        $action_desc .= ", $ltm_matches from LTM" if $ltm_matches;
        $action_desc .= ")";
        
        $result = $self->success_result(
            \@matches,
            action_description => $action_desc,
            query => $query,
            count => scalar(@matches),
        );
    };
    
    if ($@) {
        return $self->error_result("Search failed: $@");
    }
    
    return $result;
}

sub list_memories {
    my ($self, $params, $context) = @_;
    
    my $memory_dir = $params->{memory_dir} || '.clio/memory';
    
    my $result;
    eval {
        return $self->error_result("Memory directory not found") unless -d $memory_dir;
        
        my @memories;
        opendir my $dh, $memory_dir or croak "Cannot open $memory_dir: $!";
        while (my $file = readdir $dh) {
            next unless $file =~ /^(.+)\.json$/;
            push @memories, $1;
        }
        closedir $dh;
        
        my $count = scalar(@memories);
        my $action_desc = "listing memories ($count items)";
        
        $result = $self->success_result(
            \@memories,
            action_description => $action_desc,
            count => $count,
        );
    };
    
    if ($@) {
        return $self->error_result("Failed to list memories: $@");
    }
    
    return $result;
}

sub delete {
    my ($self, $params, $context) = @_;
    
    my $key = $params->{key};
    my $memory_dir = $params->{memory_dir} || '.clio/memory';
    
    return $self->error_result("Missing 'key' parameter") unless $key;
    
    my $result;
    eval {
        my $file_path = File::Spec->catfile($memory_dir, "$key.json");
        
        return $self->error_result("Memory not found: $key") unless -f $file_path;
        
        unlink $file_path or croak "Cannot delete $file_path: $!";
        
        my $action_desc = "deleting memory '$key'";
        
        $result = $self->success_result(
            "Memory deleted successfully",
            action_description => $action_desc,
            key => $key,
        );
    };
    
    if ($@) {
        return $self->error_result("Failed to delete memory: $@");
    }
    
    return $result;
}

=head2 recall_sessions

Search through previous session history files for relevant content.
Searches newest sessions first, returns matches with session IDs.

Parameters:
  query - Text to search for in session history
  max_sessions - Maximum number of sessions to search (default: 10)
  max_results - Maximum total results to return (default: 5)

=cut

sub recall_sessions {
    my ($self, $params, $context) = @_;
    
    my $query = $params->{query};
    my $max_sessions = $params->{max_sessions} || 10;
    my $max_results = $params->{max_results} || 5;
    
    return $self->error_result("Missing 'query' parameter") unless $query;
    
    my $result;
    eval {
        # Find sessions directory - ALWAYS use project-local .clio/sessions
        my $sessions_dir = '.clio/sessions';
        
        return $self->error_result("Sessions directory not found") unless -d $sessions_dir;
        
        # Extract keywords from query for fuzzy matching
        my @keywords = _extract_keywords($query);
        my $query_lc = lc($query);
        
        # Get all session files sorted by modification time (newest first)
        opendir my $dh, $sessions_dir or croak "Cannot open $sessions_dir: $!";
        my @session_files = 
            map { $_->[0] }
            sort { $b->[1] <=> $a->[1] }
            map { 
                my $path = File::Spec->catfile($sessions_dir, $_);
                [$path, (stat($path))[9] || 0]
            }
            grep { /\.json$/ && -f File::Spec->catfile($sessions_dir, $_) }
            readdir($dh);
        closedir $dh;
        
        @session_files = @session_files[0 .. ($max_sessions - 1)] 
            if @session_files > $max_sessions;
        
        my @scored_matches;
        my $sessions_searched = 0;
        
        SESSION: for my $session_path (@session_files) {
            my $session_id = $session_path;
            $session_id =~ s/.*[\/\\]//;
            $session_id =~ s/\.json$//;
            
            my $json;
            eval {
                open my $fh, '<', $session_path or croak "Cannot read: $!";
                local $/;
                $json = <$fh>;
                close $fh;
            };
            next SESSION if $@;
            
            my $session_data = eval { decode_json($json) };
            next SESSION unless $session_data && $session_data->{history};
            
            $sessions_searched++;
            
            # Check session title/metadata for matches (boost)
            my $session_title = $session_data->{title} || '';
            my $title_boost = 0;
            if ($session_title) {
                my $title_lc = lc($session_title);
                $title_boost = 2.0 if $title_lc =~ /\Q$query_lc\E/;
                if (!$title_boost) {
                    for my $kw (@keywords) {
                        $title_boost += 0.5 if $title_lc =~ /\Q$kw\E/;
                    }
                }
            }
            
            for my $i (0 .. $#{$session_data->{history}}) {
                my $msg = $session_data->{history}[$i];
                next unless $msg && $msg->{content};
                
                my $role = $msg->{role};
                $role = $role->{role} if ref($role) eq 'HASH';
                next if $role && $role eq 'system';
                
                my $content = $msg->{content};
                $content = '' if ref($content);
                next unless length($content) > 10;
                
                my $content_lc = lc($content);
                
                # Score this message
                my $score = 0;
                
                # Exact phrase match (highest value)
                if ($content_lc =~ /\Q$query_lc\E/) {
                    $score += 3.0;
                }
                
                # Keyword matching - count how many keywords hit
                my $keyword_hits = 0;
                for my $kw (@keywords) {
                    if ($content_lc =~ /\Q$kw\E/) {
                        $keyword_hits++;
                        $score += 1.0;
                    }
                }
                
                # Bonus for high keyword density (most keywords matched)
                if (@keywords > 1 && $keyword_hits >= @keywords * 0.7) {
                    $score += 1.5;  # Most keywords found together
                }
                
                # Add title boost
                $score += $title_boost;
                
                # Boost assistant messages with tool results (more informative)
                $score += 0.3 if $role && $role eq 'assistant';
                
                # Boost user messages (contain intent)
                $score += 0.2 if $role && $role eq 'user';
                
                next unless $score > 0;
                
                # Extract best context snippet around the match
                my $snippet = _extract_best_snippet($content, $query_lc, \@keywords, 600);
                
                push @scored_matches, {
                    session_id => $session_id,
                    session_title => $session_title || undef,
                    role => $role || 'unknown',
                    message_index => $i,
                    preview => $snippet,
                    score => $score,
                    keyword_hits => $keyword_hits,
                    match_query => $query,
                };
            }
        }
        
        # Sort by score descending, take top N
        @scored_matches = sort { $b->{score} <=> $a->{score} } @scored_matches;
        my @top_matches = @scored_matches > $max_results 
            ? @scored_matches[0 .. ($max_results - 1)] 
            : @scored_matches;
        
        my $action_desc = "searched $sessions_searched sessions for '$query' (" . 
                          scalar(@top_matches) . " matches, " . 
                          scalar(@scored_matches) . " total candidates)";
        
        $result = $self->success_result(
            \@top_matches,
            action_description => $action_desc,
            query => $query,
            keywords => \@keywords,
            sessions_searched => $sessions_searched,
            total_sessions => scalar(@session_files),
            matches_found => scalar(@top_matches),
        );
    };
    
    if ($@) {
        return $self->error_result("Session recall failed: $@");
    }
    
    return $result;
}

=head2 _extract_keywords

Extract meaningful keywords from a search query, filtering stop words.

=cut

sub _extract_keywords {
    my ($query) = @_;
    
    my %stop_words = map { $_ => 1 } qw(
        a an the is are was were be been being
        in on at to for of by with from as
        and or but not no nor so yet
        it its this that these those
        i me my we us our you your he she they them
        do does did have has had will would should could
        what where when how why which who whom
        all any some each every
        very much more most just also too
    );
    
    # Split on non-word characters, lowercase, filter
    my @words = grep { 
        length($_) >= 2 && !$stop_words{$_} 
    } map { lc($_) } split(/[\s\-_.,;:!?()\[\]{}'"\/\\]+/, $query);
    
    # Deduplicate preserving order
    my %seen;
    @words = grep { !$seen{$_}++ } @words;
    
    return @words;
}

=head2 _extract_best_snippet

Extract the most relevant context snippet from content around keyword matches.

=cut

sub _extract_best_snippet {
    my ($content, $query_lc, $keywords, $max_len) = @_;
    
    $max_len ||= 600;
    my $content_lc = lc($content);
    
    # Try exact query match position first
    my $best_pos = index($content_lc, $query_lc);
    
    # If no exact match, find the position with the densest keyword cluster
    if ($best_pos < 0 && $keywords && @$keywords) {
        my @positions;
        for my $kw (@$keywords) {
            my $pos = index($content_lc, $kw);
            push @positions, $pos if $pos >= 0;
        }
        
        if (@positions) {
            # Use median position as center
            @positions = sort { $a <=> $b } @positions;
            $best_pos = $positions[int(@positions / 2)];
        }
    }
    
    $best_pos = 0 if $best_pos < 0;
    
    # Center snippet around best position
    my $half = int($max_len / 2);
    my $start = $best_pos > $half ? $best_pos - $half : 0;
    my $snippet = substr($content, $start, $max_len);
    $snippet = "..." . $snippet if $start > 0;
    $snippet .= "..." if length($content) > $start + $max_len;
    
    return $snippet;
}

=head2 add_discovery

Store a discovery to project-level LTM (Long-Term Memory)

Parameters:
  fact - The discovery text (required)
  confidence - Confidence score 0.0-1.0 (optional, default 0.8)

=cut

sub add_discovery {
    my ($self, $params, $context) = @_;
    
    my $fact = $params->{fact};
    my $confidence = $params->{confidence} // 0.8;
    
    return $self->error_result("Missing 'fact' parameter") unless $fact;
    return $self->error_result("Confidence must be between 0 and 1") if $confidence < 0 || $confidence > 1;
    
    my $result;
    eval {
        # Get LTM from session if available
        my $ltm = $context->{ltm} || $context->{session}->{ltm} if ref($context) eq 'HASH';
        return $self->error_result("LTM not available in context") unless $ltm;
        
        # Add discovery to LTM
        $ltm->add_discovery($fact, $confidence, 1);  # verified=1 (user explicitly added)
        
        # Save LTM - use current working directory for cross-platform compatibility
        # The stored working_directory may be from a different machine
        my $working_dir = Cwd::getcwd();
        my $ltm_file = File::Spec->catfile($working_dir, '.clio', 'ltm.json');
        $ltm->save($ltm_file);
        
        $result = $self->success_result(
            "Discovery stored successfully",
            action_description => "storing discovery to LTM",
            fact => $fact,
            confidence => $confidence,
        );
    };
    
    if ($@) {
        return $self->error_result("Failed to add discovery: $@");
    }
    
    return $result;
}

=head2 add_solution

Store a problem-solution mapping to project-level LTM

Parameters:
  error - The error/problem description (required)
  solution - The solution text (required)
  examples - Array of file paths or contexts where this applies (optional)

=cut

sub add_solution {
    my ($self, $params, $context) = @_;
    
    my $error = $params->{error};
    my $solution = $params->{solution};
    my $examples = $params->{examples} // [];
    
    return $self->error_result("Missing 'error' parameter") unless $error;
    return $self->error_result("Missing 'solution' parameter") unless $solution;
    
    my $result;
    eval {
        # Get LTM from context
        my $ltm = $context->{ltm} || $context->{session}->{ltm} if ref($context) eq 'HASH';
        return $self->error_result("LTM not available in context") unless $ltm;
        
        # Add solution to LTM
        $ltm->add_problem_solution($error, $solution, $examples);
        
        # Save LTM - use current working directory for cross-platform compatibility
        my $working_dir = Cwd::getcwd();
        my $ltm_file = File::Spec->catfile($working_dir, '.clio', 'ltm.json');
        $ltm->save($ltm_file);
        
        $result = $self->success_result(
            "Solution stored successfully",
            action_description => "storing problem-solution to LTM",
            error => $error,
            solution => $solution,
        );
    };
    
    if ($@) {
        return $self->error_result("Failed to add solution: $@");
    }
    
    return $result;
}

=head2 add_pattern

Store a code pattern to project-level LTM

Parameters:
  pattern - The pattern description (required)
  confidence - Confidence score 0.0-1.0 (optional, default 0.7)
  examples - Array of file paths demonstrating this pattern (optional)

=cut

sub add_pattern {
    my ($self, $params, $context) = @_;
    
    my $pattern = $params->{pattern};
    my $confidence = $params->{confidence} // 0.7;
    my $examples = $params->{examples} // [];
    
    return $self->error_result("Missing 'pattern' parameter") unless $pattern;
    return $self->error_result("Confidence must be between 0 and 1") if $confidence < 0 || $confidence > 1;
    
    my $result;
    eval {
        # Get LTM from context
        my $ltm = $context->{ltm} || $context->{session}->{ltm} if ref($context) eq 'HASH';
        return $self->error_result("LTM not available in context") unless $ltm;
        
        # Add pattern to LTM
        $ltm->add_code_pattern($pattern, $confidence, $examples);
        
        # Save LTM - use current working directory for cross-platform compatibility
        my $working_dir = Cwd::getcwd();
        my $ltm_file = File::Spec->catfile($working_dir, '.clio', 'ltm.json');
        $ltm->save($ltm_file);
        
        $result = $self->success_result(
            "Pattern stored successfully",
            action_description => "storing code pattern to LTM",
            pattern => $pattern,
            confidence => $confidence,
        );
    };
    
    if ($@) {
        return $self->error_result("Failed to add pattern: $@");
    }
    
    return $result;
}

=head2 update_ltm

Update an existing LTM entry by finding matching text and replacing it.
Useful for correcting outdated information without creating duplicates.

Parameters:
  search_text - Text to search for in existing entries (required)
  replacement - New text to replace the matched entry with (required)
  entry_type - Type to search: discovery, solution, pattern (optional, searches all)

=cut

sub update_ltm {
    my ($self, $params, $context) = @_;
    
    my $search = $params->{search_text} || $params->{search};
    my $replacement = $params->{replacement};
    my $type = $params->{entry_type} || $params->{type};
    
    return $self->error_result("Missing 'search_text' parameter") unless $search;
    return $self->error_result("Missing 'replacement' parameter") unless $replacement;
    
    my $result;
    eval {
        my $ltm = $context->{ltm} || $context->{session}->{ltm} if ref($context) eq 'HASH';
        return $self->error_result("LTM not available in context") unless $ltm;
        
        my $update_result = $ltm->update_entry(
            search      => $search,
            replacement => $replacement,
            type        => $type,
        );
        
        if ($update_result->{found}) {
            # Save the updated LTM
            eval {
                my $ltm_file = File::Spec->catfile(Cwd::getcwd(), '.clio', 'ltm.json');
                $ltm->save($ltm_file) if -e $ltm_file;
            };
            
            $result = $self->success_result(
                encode_json($update_result),
                action_description => "updated LTM $update_result->{type}: '$search' -> new text",
                type => $update_result->{type},
                old_text => $update_result->{old_text},
                new_text => $update_result->{new_text},
            );
        } else {
            $result = $self->error_result(
                "No LTM entry matching '$search' found. Use add_discovery/add_solution/add_pattern to create new entries."
            );
        }
    };
    
    if ($@) {
        return $self->error_result("Failed to update LTM: $@");
    }
    
    return $result;
}

=head2 prune_ltm

Prune old, low-confidence, or excess LTM entries to prevent unbounded growth.

Parameters:
  max_age_days - Remove entries older than this (optional, default 90)
  min_confidence - Remove entries below this confidence (optional, default 0.3)
  max_discoveries - Max discoveries to keep (optional, default 50)
  max_solutions - Max solutions to keep (optional, default 50)
  max_patterns - Max patterns to keep (optional, default 30)

=cut

sub prune_ltm {
    my ($self, $params, $context) = @_;
    
    my $max_age_days = $params->{max_age_days} // 90;
    my $min_confidence = $params->{min_confidence} // 0.3;
    my $max_discoveries = $params->{max_discoveries} // 50;
    my $max_solutions = $params->{max_solutions} // 50;
    my $max_patterns = $params->{max_patterns} // 30;
    
    my $result;
    eval {
        # Get LTM from context
        my $ltm = $context->{ltm} || $context->{session}->{ltm} if ref($context) eq 'HASH';
        return $self->error_result("LTM not available in context") unless $ltm;
        
        # Prune LTM
        my $removed = $ltm->prune(
            max_age_days => $max_age_days,
            min_confidence => $min_confidence,
            max_discoveries => $max_discoveries,
            max_solutions => $max_solutions,
            max_patterns => $max_patterns,
        );
        
        my $total_removed = $removed->{discoveries} + $removed->{solutions} + 
                            $removed->{patterns} + $removed->{workflows} + $removed->{failures};
        
        # Save LTM - use current working directory for cross-platform compatibility
        my $working_dir = Cwd::getcwd();
        my $ltm_file = File::Spec->catfile($working_dir, '.clio', 'ltm.json');
        $ltm->save($ltm_file);
        
        my $stats = $ltm->get_stats();
        
        $result = $self->success_result(
            "Pruned $total_removed entries from LTM",
            action_description => "pruning LTM (removed $total_removed entries)",
            removed => $removed,
            remaining => {
                discoveries => $stats->{discoveries},
                solutions => $stats->{solutions},
                patterns => $stats->{patterns},
            },
        );
    };
    
    if ($@) {
        return $self->error_result("Failed to prune LTM: $@");
    }
    
    return $result;
}

=head2 ltm_stats

Get statistics about the current LTM database.

Returns counts and metadata about stored patterns.

=cut

sub ltm_stats {
    my ($self, $params, $context) = @_;
    
    my $result;
    eval {
        # Get LTM from context
        my $ltm = $context->{ltm} || $context->{session}->{ltm} if ref($context) eq 'HASH';
        return $self->error_result("LTM not available in context") unless $ltm;
        
        my $stats = $ltm->get_stats();
        
        my $total = ($stats->{discoveries} // 0) + ($stats->{problem_solutions} // 0) + 
                    ($stats->{code_patterns} // 0) + ($stats->{workflows} // 0) + 
                    ($stats->{failures} // 0);
        
        $result = $self->success_result(
            encode_json($stats),
            action_description => "retrieved LTM stats ($total total entries)",
            stats => $stats,
        );
    };
    
    if ($@) {
        return $self->error_result("Failed to get LTM stats: $@");
    }
    
    return $result;
}

1;
