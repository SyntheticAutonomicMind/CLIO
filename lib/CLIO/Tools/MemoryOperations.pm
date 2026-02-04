package CLIO::Tools::MemoryOperations;

use strict;
use warnings;
use Carp qw(croak confess);
use parent 'CLIO::Tools::Tool';
use CLIO::Util::ConfigPath qw(get_config_dir);
use JSON::PP qw(encode_json decode_json);
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
4. All LTM data persists in .clio/ltm.json and is automatically injected
   into future sessions for context
},
        supported_operations => [qw(store retrieve search list delete recall_sessions add_discovery add_solution add_pattern prune_ltm ltm_stats)],
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
        return $self->error_result("Memory directory not found") unless -d $memory_dir;
        
        my @matches;
        opendir my $dh, $memory_dir or croak "Cannot open $memory_dir: $!";
        while (my $file = readdir $dh) {
            next unless $file =~ /\.json$/;
            
            my $path = File::Spec->catfile($memory_dir, $file);
            open my $fh, '<:utf8', $path or next;
            my $json = do { local $/; <$fh> };
            close $fh;
            
            my $data = eval { decode_json($json) };
            next unless $data;
            
            # Simple text search
            if ($data->{content} =~ /\Q$query\E/i || $data->{key} =~ /\Q$query\E/i) {
                push @matches, {
                    key => $data->{key},
                    content => substr($data->{content}, 0, 200),  # Preview
                    timestamp => $data->{timestamp},
                };
            }
        }
        closedir $dh;
        
        my $action_desc = "searching memories for '$query' (" . scalar(@matches) . " matches)";
        
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
        # Sessions are project-scoped, not global
        my $sessions_dir = '.clio/sessions';
        
        return $self->error_result("Sessions directory not found") unless -d $sessions_dir;
        
        # Get all session files sorted by modification time (newest first)
        opendir my $dh, $sessions_dir or croak "Cannot open $sessions_dir: $!";
        my @session_files = 
            map { $_->[0] }
            sort { $b->[1] <=> $a->[1] }  # Sort by mtime descending (newest first)
            map { 
                my $path = File::Spec->catfile($sessions_dir, $_);
                [$path, (stat($path))[9] || 0]
            }
            grep { /\.json$/ && -f File::Spec->catfile($sessions_dir, $_) }
            readdir($dh);
        closedir $dh;
        
        # Limit number of sessions to search
        @session_files = @session_files[0 .. ($max_sessions - 1)] 
            if @session_files > $max_sessions;
        
        my @matches;
        my $sessions_searched = 0;
        
        SESSION: for my $session_path (@session_files) {
            last if @matches >= $max_results;
            
            # Extract session ID from path
            my $session_id = $session_path;
            $session_id =~ s/.*[\/\\]//;  # Remove directory
            $session_id =~ s/\.json$//;    # Remove extension
            
            # Read session file
            my $json;
            eval {
                open my $fh, '<', $session_path or croak "Cannot read: $!";
                local $/;
                $json = <$fh>;
                close $fh;
            };
            next SESSION if $@;
            
            # Parse JSON
            my $session_data = eval { decode_json($json) };
            next SESSION unless $session_data && $session_data->{history};
            
            $sessions_searched++;
            
            # Search through history
            for my $i (0 .. $#{$session_data->{history}}) {
                last SESSION if @matches >= $max_results;
                
                my $msg = $session_data->{history}[$i];
                next unless $msg && $msg->{content};
                
                # Skip if content is too short or is a system message
                my $role = $msg->{role};
                $role = $role->{role} if ref($role) eq 'HASH';  # Handle nested role
                next if $role && $role eq 'system';
                
                my $content = $msg->{content};
                $content = '' if ref($content);  # Skip non-string content
                
                # Check if query matches
                if ($content =~ /\Q$query\E/i) {
                    # Extract context around the match
                    my $match_pos = index(lc($content), lc($query));
                    my $start = $match_pos > 100 ? $match_pos - 100 : 0;
                    my $context_text = substr($content, $start, 500);
                    $context_text = "..." . $context_text if $start > 0;
                    $context_text .= "..." if length($content) > $start + 500;
                    
                    push @matches, {
                        session_id => $session_id,
                        role => $role || 'unknown',
                        message_index => $i,
                        preview => $context_text,
                        match_query => $query,
                    };
                }
            }
        }
        
        my $action_desc = "searched $sessions_searched sessions for '$query' (" . 
                          scalar(@matches) . " matches)";
        
        $result = $self->success_result(
            \@matches,
            action_description => $action_desc,
            query => $query,
            sessions_searched => $sessions_searched,
            total_sessions => scalar(@session_files),
            matches_found => scalar(@matches),
        );
    };
    
    if ($@) {
        return $self->error_result("Session recall failed: $@");
    }
    
    return $result;
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
        
        # Save LTM - get working_directory from session
        my $working_dir = ($context->{session} && $context->{session}->can('working_directory')) 
            ? $context->{session}->working_directory 
            : '.';
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
        
        # Save LTM - get working_directory from session
        my $working_dir = ($context->{session} && $context->{session}->can('working_directory')) 
            ? $context->{session}->working_directory 
            : '.';
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
        
        # Save LTM - get working_directory from session
        my $working_dir = ($context->{session} && $context->{session}->can('working_directory')) 
            ? $context->{session}->working_directory 
            : '.';
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
        
        # Save LTM
        my $working_dir = ($context->{session} && $context->{session}->can('working_directory')) 
            ? $context->{session}->working_directory 
            : '.';
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
        
        my $total = $stats->{discoveries} + $stats->{solutions} + $stats->{patterns} + 
                    $stats->{workflows} + $stats->{failures};
        
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
