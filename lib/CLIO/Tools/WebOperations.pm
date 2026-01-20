package CLIO::Tools::WebOperations;

use strict;
use warnings;
use parent 'CLIO::Tools::Tool';
use CLIO::Compat::HTTP;
use feature 'say';

=head1 NAME

CLIO::Tools::WebOperations - Web fetching and search operations

=cut

sub new {
    my ($class, %opts) = @_;
    
    return $class->SUPER::new(
        name => 'web_operations',
        description => q{Web operations: fetch URLs and search.

Operations:
-  fetch_url - Fetch content from URL
-  search_web - Web search (requires API key)
},
        supported_operations => [qw(fetch_url search_web)],
        %opts,
    );
}

sub route_operation {
    my ($self, $operation, $params, $context) = @_;
    
    if ($operation eq 'fetch_url') {
        return $self->fetch_url($params, $context);
    } elsif ($operation eq 'search_web') {
        return $self->search_web($params, $context);
    }
    
    return $self->error_result("Operation not implemented: $operation");
}

sub fetch_url {
    my ($self, $params, $context) = @_;
    
    my $url = $params->{url};
    my $timeout = $params->{timeout} || 30;
    
    return $self->error_result("Missing 'url' parameter") unless $url;
    
    my $result;
    eval {
        my $ua = CLIO::Compat::HTTP->new(
            timeout => $timeout,
            agent => 'CLIO/1.0',
        );
        
        my $response = $ua->get($url);
        
        if ($response->is_success) {
            my $size = length($response->decoded_content);
            my $action_desc = "fetching $url ($size bytes, " . $response->code . ")";
            
            $result = $self->success_result(
                $response->decoded_content,
                action_description => $action_desc,
                url => $url,
                status => $response->code,
                content_type => $response->header('content-type'),
            );
        } else {
            return $self->error_result("HTTP error: " . $response->status_line);
        }
    };
    
    if ($@) {
        return $self->error_result("Failed to fetch URL: $@");
    }
    
    return $result;
}

sub search_web {
    my ($self, $params, $context) = @_;
    
    my $query = $params->{query};
    
    return $self->error_result("Missing 'query' parameter") unless $query;
    
    # Placeholder - would need actual search API integration
    return $self->error_result("Web search not implemented - requires API key configuration");
}

1;
