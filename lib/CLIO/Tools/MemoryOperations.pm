# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Tools::MemoryOperations;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
use Cwd;
use Carp qw(croak confess);
use parent 'CLIO::Tools::Tool';
use CLIO::Util::ConfigPath qw(get_config_dir);
use CLIO::Util::JSON qw(encode_json decode_json safe_decode_json);
use CLIO::Util::PathResolver qw(strip_path_quotes);
use File::Spec;

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

SESSION MEMORY (key-value, stored in .clio/memory/):
-  store: key (required), content (required)
-  retrieve: key (required)
-  search: query (required)
-  list: no params
-  delete: key (required)

LTM RECALL:
-  recall_sessions: Search previous sessions. Returns scored matches {session_id,
    session_title, role, message_index, preview, score, keyword_hits}.
    Searches newest first. Scoring: exact phrase +3pts, keyword +1pt, title
    match +2pts, assistant/user role +0.3/+0.2.

LTM STORAGE (persist facts across sessions):
-  add_discovery: fact (required), confidence (optional). Stores to .clio/ltm.json. Returns success confirmation.
-  add_solution: error + solution (required), examples (optional). Stores to .clio/ltm.json. Returns success confirmation.
-  add_pattern: pattern (required), confidence (optional). Stores to .clio/ltm.json. Returns success confirmation.

LTM CORROBORATION (trust tier promotion):
-  add_corroboration: search_text (required), source_agent (optional), source_session (optional), entry_type (optional). 
    Adds independent corroboration to an existing LTM entry. When an entry receives >=2 corroborations from distinct 
    agent:session pairs, it auto-promotes from [UNVERIFIED] to [TRUSTED] tier. Use this when you independently 
    verify a memory is correct (e.g., you tested a solution and it worked, you confirmed a pattern in the codebase).

LTM MAINTENANCE:
-  update_ltm: search_text + replacement (required), entry_type (optional). Updates existing entry. Returns {updated, count}.
-  prune_ltm: age/limits optional. Removes old entries. Returns {pruned, remaining}.
-  ltm_stats: no params. Returns {discoveries, solutions, patterns, workflows, failures, rules}
},
        supported_operations => [qw(store retrieve search list delete recall_sessions add_discovery add_solution add_pattern add_corroboration update_ltm prune_ltm ltm_stats)],
        %opts,
    );
}

sub dispatch_table {
    return {
        store           => 'store',
        retrieve        => 'retrieve',
        search          => 'search',
        list            => 'list_memories',
        delete          => 'delete',
        recall_sessions => 'recall_sessions',
        add_discovery   => 'add_discovery',
        add_solution    => 'add_solution',
        add_pattern     => 'add_pattern',
        add_corroboration => 'add_corroboration',
        update_ltm      => 'update_ltm',
        prune_ltm       => 'prune_ltm',
        ltm_stats       => 'ltm_stats',
    };
}

=head2 get_additional_parameters

Define parameters for memory_operations in JSON schema sent to AI.

=cut

sub get_additional_parameters {
    my ($self) = @_;
    
    return {
        key => {
            type => "string",
            description => "[REQUIRED for store/retrieve/delete] Memory key for store/retrieve/delete operations.",
        },
        content => {
            type => "string",
            description => "[REQUIRED for store] Content to store in session memory.",
        },
        query => {
            type        => "string",
            description => "[REQUIRED] Search query for session history. Returns scored matches sorted by relevance.",
        },
        max_sessions => {
            type        => "integer",
            description => "[OPTIONAL] Max sessions to search (newest first). Default: 10.",
        },
        max_results => {
            type        => "integer",
            description => "[OPTIONAL] Max matches to return. Default: 5.",
        },
        fact => {
            type => "string",
            description => "[REQUIRED for add_discovery] Discovery fact to store in LTM. Auto-saves to .clio/ltm.json.",
        },
        confidence => {
            type => "number",
            description => "[OPTIONAL] Confidence level 0.0-1.0. Default: 0.8. Used for add_discovery/add_pattern.",
        },
        error => {
            type => "string",
            description => "[REQUIRED for add_solution] Error/problem description. Stored in .clio/ltm.json.",
        },
        solution => {
            type => "string",
            description => "[REQUIRED for add_solution] Solution description. Stored in .clio/ltm.json.",
        },
        pattern => {
            type => "string",
            description => "[REQUIRED for add_pattern] Pattern description to store in LTM.",
        },
        examples => {
            type => "array",
            items => { type => "string" },
            description => "[OPTIONAL] Example file paths for add_solution/add_pattern.",
        },
        max_age_days => {
            type => "integer",
            description => "[OPTIONAL] Max age in days for prune_ltm. Default: 90.",
        },
        min_confidence => {
            type => "number",
            description => "[OPTIONAL] Minimum confidence threshold for prune_ltm. Default: 0.3.",
        },
        max_discoveries => {
            type => "integer",
            description => "[OPTIONAL] Max discoveries to keep for prune_ltm. Default: 50.",
        },
        max_solutions => {
            type => "integer",
            description => "[OPTIONAL] Max solutions to keep for prune_ltm. Default: 50.",
        },
        max_patterns => {
            type => "integer",
            description => "[OPTIONAL] Max patterns to keep for prune_ltm. Default: 30.",
        },
        search_text => {
            type => "string",
            description => "[REQUIRED for add_corroboration] Text to search for in LTM to find entry to corroborate.",
        },
        replacement => {
            type => "string",
            description => "[REQUIRED for update_ltm] Replacement text.",
        },
        entry_type => {
            type => "string",
            description => "[OPTIONAL for add_corroboration] Type filter: discovery, solution, pattern, workflow, failure.",
        },
        source_agent => {
            type => "string",
            description => "[OPTIONAL for add_corroboration] Agent ID providing corroboration. Default: CLIO_AGENT_ID env.",
        },
        source_session => {
            type => "string",
            description => "[OPTIONAL for add_corroboration] Session ID providing corroboration. Default: CLIO_SESSION_ID env.",
        },
    };
}

sub store {
    my ($self, $params, $context) = @_;
    
    my $key = $params->{key};
    my $content = $params->{content};
    my $memory_dir = strip_path_quotes($params->{memory_dir}) || '.clio/memory';
    
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
        return $self->error_result("Failed to store memory: " . $self->_clean_eval_error($@));
    }
    
    return $result;
}

sub retrieve {
    my ($self, $params, $context) = @_;
    
    my $key = $params->{key};
    my $memory_dir = strip_path_quotes($params->{memory_dir}) || '.clio/memory';
    
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
        return $self->error_result("Failed to retrieve memory: " . $self->_clean_eval_error($@));
    }
    
    return $result;
}

sub search {
    my ($self, $params, $context) = @_;
    
    my $query = $params->{query};
    my $memory_dir = strip_path_quotes($params->{memory_dir}) || '.clio/memory';
    
    return $self->error_result("Missing 'query' parameter") unless $query;
    
    my $result;
    eval {
        my @matches;
        
        # Search session-level memory files
        if (-d $memory_dir) {
            opendir my $dh, $memory_dir or croak "Cannot open $memory_dir: $!";
            while (my $file = readdir $dh) {
                # Allow ESC interrupt during memory search over many files.
                next unless $file =~ /\.json$/;

                if ($self->check_interrupt($context)) {
                    log_info('MemoryOps', "User interrupt during memory search");
                    last;
                }

                my $path = File::Spec->catfile($memory_dir, $file);
                open my $fh, '<:utf8', $path or next;
                my $json = do { local $/; <$fh> };
                close $fh;

                my $data = safe_decode_json($json);
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
                    require CLIO::Util::PathResolver;
                    my $ltm_file = CLIO::Util::PathResolver::find_ltm_path(_ltm_working_dir($context));
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
        return $self->error_result("Search failed: " . $self->_clean_eval_error($@));
    }
    
    return $result;
}

sub list_memories {
    my ($self, $params, $context) = @_;
    
    my $memory_dir = strip_path_quotes($params->{memory_dir}) || '.clio/memory';
    
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
        return $self->error_result("Failed to list memories: " . $self->_clean_eval_error($@));
    }
    
    return $result;
}

sub delete {
    my ($self, $params, $context) = @_;
    
    my $key = $params->{key};
    my $memory_dir = strip_path_quotes($params->{memory_dir}) || '.clio/memory';
    
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
        return $self->error_result("Failed to delete memory: " . $self->_clean_eval_error($@));
    }
    
    return $result;
}

=head2 recall_sessions

Search through previous session history files for relevant content.
Searches newest sessions first, returns matches with session IDs.

Parameters:
  query - Text to search for in session history
  max_sessions - Maximum number of sessions to search (default: 10, max: 50)
  max_results - Maximum total results to return (default: 5)

=cut

sub recall_sessions {
    my ($self, $params, $context) = @_;
    
    my $query = $params->{query};
    my $max_sessions = $params->{max_sessions} || 10;
    my $max_results = $params->{max_results} || 5;
    
    # Enforce hard limits to prevent OOM
    $max_sessions = 50 if $max_sessions > 50;
    $max_results = 20 if $max_results > 20;
    
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
            # Allow ESC interrupt during session history search. With many
            # sessions on disk this loop can take many seconds; without
            # polling the user waits for the entire history to be scanned.
            if ($self->check_interrupt($context)) {
                log_info('MemoryOps', "User interrupt during recall_sessions after $sessions_searched session(s)");
                last SESSION;
            }

            my $session_id = $session_path;
            $session_id =~ s/.*[\/\\]//;
            $session_id =~ s/\.json$//;
            
            # Check file size before reading - skip huge files to prevent OOM
            my $file_size = -s $session_path;
            if ($file_size > 50_000_000) {  # 50MB limit
                log_warning('MemoryOps', "Skipping large session file $session_id ($file_size bytes)");
                next SESSION;
            }
            
            my $json;
            eval {
                open my $fh, '<', $session_path or croak "Cannot read: $!";
                local $/;
                $json = <$fh>;
                close $fh;
            };
            next SESSION if $@;
            
            my $session_data = safe_decode_json($json);
            next SESSION unless $session_data && $session_data->{history};
            
            # Clear large variables early to free memory
            $json = undef;
            
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

            # Also search YaRN threads for full untrimmed conversation history.
            # Session history may have been trimmed, but YaRN stores every message.
            # Dedup against history matches so we don't double-report.
            my %seen_content;  # Track content digests already matched in history
            for my $match (@scored_matches) {
                next unless $match->{session_id} eq $session_id;
                my $digest = substr($match->{preview} // '', 0, 80);
                $seen_content{$digest} = 1;
            }

            if ($session_data->{yarn} && ref($session_data->{yarn}) eq 'HASH') {
                my $yarn_threads = $session_data->{yarn};
                THREAD: for my $thread_id (sort keys %$yarn_threads) {
                    my $thread = $yarn_threads->{$thread_id};
                    next THREAD unless $thread && ref($thread) eq 'ARRAY' && @$thread;

                    for my $mi (0 .. $#$thread) {
                        my $msg = $thread->[$mi];
                        next unless $msg && $msg->{content};

                        my $role = $msg->{role};
                        $role = $role->{role} if ref($role) eq 'HASH';
                        next if $role && $role eq 'system';

                        my $content = $msg->{content};
                        $content = '' if ref($content);
                        next unless length($content) > 10;

                        # Skip if already matched in history (same content digest)
                        my $content_digest = substr($content, 0, 80);
                        next if $seen_content{$content_digest};
                        $seen_content{$content_digest} = 1;

                        my $content_lc = lc($content);

                        # Same scoring as history search
                        my $score = 0;

                        if ($content_lc =~ /\Q$query_lc\E/) {
                            $score += 3.0;
                        }

                        my $keyword_hits = 0;
                        for my $kw (@keywords) {
                            if ($content_lc =~ /\Q$kw\E/) {
                                $keyword_hits++;
                                $score += 1.0;
                            }
                        }

                        if (@keywords > 1 && $keyword_hits >= @keywords * 0.7) {
                            $score += 1.5;
                        }

                        $score += $title_boost;
                        $score += 0.3 if $role && $role eq 'assistant';
                        $score += 0.2 if $role && $role eq 'user';

                        # Slight boost for yarn matches (untrimmed context is more valuable)
                        $score += 0.5;

                        next unless $score > 0;

                        my $snippet = _extract_best_snippet($content, $query_lc, \@keywords, 600);

                        push @scored_matches, {
                            session_id   => $session_id,
                            session_title => $session_title || undef,
                            role         => $role || 'unknown',
                            message_index => "yarn:$thread_id:$mi",
                            preview      => $snippet,
                            score        => $score,
                            keyword_hits => $keyword_hits,
                            match_query  => $query,
                        };
                    }
                }
            }
            
            # Clear session data to free memory before next iteration
            $session_data = undef;
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
        return $self->error_result("Session recall failed: " . $self->_clean_eval_error($@));
    }
    
    return $result;
}

=head2 _extract_keywords

Extract meaningful keywords from a search query, filtering stop words.

=cut

# Default stop words - can be overridden by setting $CLIO::Tools::MemoryOperations::STOP_WORDS
our @DEFAULT_STOP_WORDS = qw(
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

sub _extract_keywords {
    my ($query) = @_;
    
    # Allow custom stop words via package variable
    my @stop_words = @DEFAULT_STOP_WORDS;
    my %stop_words = map { $_ => 1 } @stop_words;
    
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
        
        # Save LTM
        $self->_save_ltm($ltm, $context);
        
        $result = $self->success_result(
            "Discovery stored successfully",
            action_description => "storing discovery to LTM",
            fact => $fact,
            confidence => $confidence,
        );
    };
    
    if ($@) {
        return $self->error_result("Failed to add discovery: " . $self->_clean_eval_error($@));
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
        
        # Save LTM
        $self->_save_ltm($ltm, $context);
        
        $result = $self->success_result(
            "Solution stored successfully",
            action_description => "storing problem-solution to LTM",
            error => $error,
            solution => $solution,
        );
    };
    
    if ($@) {
        return $self->error_result("Failed to add solution: " . $self->_clean_eval_error($@));
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
        
        # Save LTM
        $self->_save_ltm($ltm, $context);
        
        $result = $self->success_result(
            "Pattern stored successfully",
            action_description => "storing code pattern to LTM",
            pattern => $pattern,
            confidence => $confidence,
        );
    };
    
    if ($@) {
        return $self->error_result("Failed to add pattern: " . $self->_clean_eval_error($@));
    }
    
    return $result;
}

=head2 _save_ltm

Internal helper to save LTM to disk. Resolves the canonical LTM path via
PathResolver::find_ltm_path so the write target always matches the read
target used at session load time.

=cut

sub _save_ltm {
    my ($self, $ltm, $context) = @_;

    # Resolve the canonical LTM file via PathResolver::find_ltm_path so the
    # write target always matches the read target used at session load time.
    # Walking up the project tree ensures we converge on the repo-root
    # .clio/ltm.json even when the session was started from a subdirectory.
    require CLIO::Util::PathResolver;
    my $working_dir = _ltm_working_dir($context);
    my $ltm_file = CLIO::Util::PathResolver::find_ltm_path($working_dir);
    $ltm->save($ltm_file);
}

sub _ltm_working_dir {
    my ($context) = @_;
    if (ref($context) eq 'HASH'
        && $context->{session}
        && $context->{session}->{state}
        && $context->{session}->{state}->{working_directory}) {
        return $context->{session}->{state}->{working_directory};
    }
    return Cwd::getcwd();
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
                require CLIO::Util::PathResolver;
                my $ltm_file = CLIO::Util::PathResolver::find_ltm_path(_ltm_working_dir($context));
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
        return $self->error_result("Failed to update LTM: " . $self->_clean_eval_error($@));
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
        require CLIO::Util::PathResolver;
        my $ltm_file = CLIO::Util::PathResolver::find_ltm_path(_ltm_working_dir($context));
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
        return $self->error_result("Failed to prune LTM: " . $self->_clean_eval_error($@));
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
        return $self->error_result("Failed to get LTM stats: " . $self->_clean_eval_error($@));
    }
    
    return $result;
}

=head2 add_corroboration

Add a corroboration to an existing LTM entry from an independent source.
When corroboration_count reaches threshold (2), entry is promoted to 'trusted' tier.

Parameters:
  search_text - Text to find the entry to corroborate (required)
  source_agent - Agent ID providing corroboration (optional, default: CLIO_AGENT_ID env)
  source_session - Session ID providing corroboration (optional, default: CLIO_SESSION_ID env)
  entry_type - Type filter: discovery, solution, pattern, workflow, failure (optional)

=cut

sub add_corroboration {
    my ($self, $params, $context) = @_;

    my $search_text = $params->{search_text};
    my $source_agent = $params->{source_agent};
    my $source_session = $params->{source_session};
    my $type = $params->{entry_type};

    return $self->error_result("Missing 'search_text' parameter") unless $search_text;

    # Defensive identity fallback. LongTerm.pm reads $ENV{CLIO_AGENT_ID} /
    # $ENV{CLIO_SESSION_ID} as the default corroboration source key, and
    # those env vars are set by `clio` and SubAgent.pm at session start.
    # If a caller invokes this tool without that wiring in place (eg, a
    # test harness, a script, or a future entry point that forgot to set
    # the env), fall back to the session_id from the live session so we
    # still get a usable identity rather than the silent "unknown:unknown"
    # trap documented in tests/unit/test_ltm_corroboration.pl.
    unless ($source_session || $ENV{CLIO_SESSION_ID}) {
        my $ctx_session = ref($context) eq 'HASH' ? $context->{session} : undef;
        if (ref($ctx_session) eq 'HASH' && $ctx_session->{session_id}) {
            $source_session = $ctx_session->{session_id};
        }
    }
    unless ($source_agent) {
        $source_agent = $ENV{CLIO_AGENT_ID} || 'main';
    }

    my $result;
    eval {
        my $ltm = $context->{ltm} || $context->{session}->{ltm} if ref($context) eq 'HASH';
        return $self->error_result("LTM not available in context") unless $ltm;

        my $corroboration_result = $ltm->add_corroboration($search_text, $source_agent, $source_session, $type);
        
        if ($corroboration_result->{found}) {
            # Save the updated LTM
            eval {
                require CLIO::Util::PathResolver;
                my $ltm_file = CLIO::Util::PathResolver::find_ltm_path(_ltm_working_dir($context));
                $ltm->save($ltm_file) if -e $ltm_file;
            };
            
            my $action_desc = "corroborating LTM entry: '$search_text' (tier: $corroboration_result->{tier})";
            if ($corroboration_result->{promoted}) {
                $action_desc .= " -> PROMOTED TO TRUSTED";
            }
            
            $result = $self->success_result(
                encode_json($corroboration_result),
                action_description => $action_desc,
                found => $corroboration_result->{found},
                promoted => $corroboration_result->{promoted},
                tier => $corroboration_result->{tier},
                corroboration_count => $corroboration_result->{corroboration_count},
                category => $corroboration_result->{category},
            );
        } else {
            $result = $self->error_result(
                "No LTM entry matching '$search_text' found."
            );
        }
    };
    
    if ($@) {
        return $self->error_result("Failed to add corroboration: " . $self->_clean_eval_error($@));
    }
    
    return $result;
}

1;
