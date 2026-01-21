package CLIO::Protocols::Recall;

use strict;
use warnings;
use parent 'CLIO::Protocols::Handler';
use MIME::Base64 qw(decode_base64 encode_base64);
use JSON::PP qw(encode_json);
use CLIO::Core::Logger qw(should_log);
use POSIX qw(strftime);

=head1 NAME

CLIO::Protocols::Recall - Protocol handler for recalling archived conversation history

=head1 DESCRIPTION

Recalls messages from YaRN storage that have been trimmed from active context.
Allows agents to search and retrieve historical conversation context.

Protocol format: [RECALL:query=<base64>:limit=<num>]

=head1 SYNOPSIS

    use CLIO::Protocols::Recall;
    
    my $recall = CLIO::Protocols::Recall->new();
    my $result = $recall->process_request({
        protocol => 'RECALL',
        query => encode_base64('error handling'),
        limit => '10'
    }, $session);

=cut

sub process_request {
    my ($self, $input, $session) = @_;
    
    print STDERR "[RECALL] Processing request\n" if should_log('DEBUG');
    
    # Validate input
    unless ($self->validate_input($input)) {
        return $self->handle_errors("Invalid input format");
    }
    
    # Decode query
    my $query = decode_base64($input->{query} // '');
    my $limit = $input->{limit} // 10;
    $limit = 10 if $limit > 50;  # Cap at 50 results
    
    unless ($query) {
        return $self->handle_errors("Query parameter required");
    }
    
    # Get session state
    unless ($session && $session->{state}) {
        return $self->handle_errors("No session state available");
    }
    
    my $state = $session->{state};
    my $thread_id = $state->{session_id};
    
    # Search YaRN storage
    my $results = $self->search_yarn($state->{yarn}, $thread_id, $query, $limit);
    
    # Format response
    my $response = $self->format_recall_response($results, $query, $limit);
    
    return {
        success => 1,
        data => $response,
        matches => scalar(@$results)
    };
}

=head2 search_yarn

Search YaRN thread for messages matching query.

Arguments:
- $yarn: YaRN instance
- $thread_id: Thread ID to search
- $query: Search query string
- $limit: Maximum results to return

Returns: Array reference of matching messages

=cut

sub search_yarn {
    my ($self, $yarn, $thread_id, $query, $limit) = @_;
    
    my $thread = $yarn->get_thread($thread_id);
    return [] unless $thread && ref $thread eq 'ARRAY';
    
    my @matches;
    my $query_lc = lc($query);
    
    # Search messages for query
    for my $msg (@$thread) {
        next unless ref $msg eq 'HASH';
        next unless $msg->{content};
        
        my $content_lc = lc($msg->{content});
        if (index($content_lc, $query_lc) >= 0) {
            push @matches, $msg;
            last if @matches >= $limit;
        }
    }
    
    # Sort by timestamp (most recent first) if available
    @matches = sort { 
        ($b->{timestamp} // 0) <=> ($a->{timestamp} // 0) 
    } @matches;
    
    return \@matches;
}

=head2 format_recall_response

Format search results into readable response for agent.

=cut

sub format_recall_response {
    my ($self, $results, $query, $limit) = @_;
    
    my $count = scalar(@$results);
    
    if ($count == 0) {
        return "No archived messages found matching query: '$query'\n\n" .
               "Try:\n" .
               "- Different keywords\n" .
               "- Broader search terms\n" .
               "- Check if context exists in current conversation";
    }
    
    my $response = "Recall Results: Found $count message(s) matching '$query'\n";
    $response .= "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" . "\n\n";
    
    my $msg_num = 1;
    for my $msg (@$results) {
        my $role = uc($msg->{role} // 'unknown');
        my $timestamp = $msg->{timestamp} ? 
            strftime("%Y-%m-%d %H:%M:%S", localtime($msg->{timestamp})) : 
            'unknown time';
        
        my $content = $msg->{content} // '';
        
        # Truncate very long messages (keep first 500 chars)
        if (length($content) > 500) {
            $content = substr($content, 0, 500) . "\n\n[... truncated ...]";
        }
        
        $response .= "[$msg_num] $role at $timestamp\n";
        $response .= "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" . "\n";
        $response .= "$content\n";
        $response .= "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" . "\n\n";
        
        $msg_num++;
    }
    
    $response .= "Note: These messages were archived from active context but remain searchable.\n";
    
    return $response;
}

1;

=head1 AUTHOR

CLIO Project

=head1 LICENSE

GPL-3.0

=cut
