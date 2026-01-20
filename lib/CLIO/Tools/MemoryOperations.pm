package CLIO::Tools::MemoryOperations;

use strict;
use warnings;
use parent 'CLIO::Tools::Tool';
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
},
        supported_operations => [qw(store retrieve search list delete)],
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
    }
    
    return $self->error_result("Operation not implemented: $operation");
}

sub store {
    my ($self, $params, $context) = @_;
    
    my $key = $params->{key};
    my $content = $params->{content};
    my $memory_dir = $params->{memory_dir} || 'memory';
    
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
    my $memory_dir = $params->{memory_dir} || 'memory';
    
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
    my $memory_dir = $params->{memory_dir} || 'memory';
    
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
    
    my $memory_dir = $params->{memory_dir} || 'memory';
    
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
    my $memory_dir = $params->{memory_dir} || 'memory';
    
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

1;
