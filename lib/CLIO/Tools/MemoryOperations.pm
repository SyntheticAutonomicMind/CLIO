package CLIO::Tools::MemoryOperations;

use strict;
use warnings;
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
        description => q{Memory and knowledge base operations.

Operations:
-  store - Store information in memory
-  retrieve - Retrieve from memory by key
-  search - Semantic search in knowledge base
-  list - List all stored memories
-  delete - Delete memory entry
-  recall_sessions - Search previous session history for relevant content
   Parameters: query (required), max_sessions (default: 10), max_results (default: 5)
   Returns: Matches with session_id, role, preview text
},
        supported_operations => [qw(store retrieve search list delete recall_sessions)],
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
    }
    
    return $self->error_result("Operation not implemented: $operation");
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
        open my $fh, '>:utf8', $file_path or die "Cannot write $file_path: $!";
        
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
        
        open my $fh, '<:utf8', $file_path or die "Cannot read $file_path: $!";
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
        opendir my $dh, $memory_dir or die "Cannot open $memory_dir: $!";
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
        opendir my $dh, $memory_dir or die "Cannot open $memory_dir: $!";
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
        
        unlink $file_path or die "Cannot delete $file_path: $!";
        
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
        # Find sessions directory (use get_config_dir for platform-aware path)
        my $sessions_dir = '.clio/sessions';
        $sessions_dir = File::Spec->catdir(get_config_dir(), 'sessions') 
            unless -d $sessions_dir;
        
        return $self->error_result("Sessions directory not found") unless -d $sessions_dir;
        
        # Get all session files sorted by modification time (newest first)
        opendir my $dh, $sessions_dir or die "Cannot open $sessions_dir: $!";
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
                open my $fh, '<', $session_path or die "Cannot read: $!";
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

1;
