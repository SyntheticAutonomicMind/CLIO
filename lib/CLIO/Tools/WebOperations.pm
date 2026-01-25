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
   Parameters: url (required), timeout (optional, default 30s)
   Returns: Page content, status code, content-type
   
-  search_web - Web search using DuckDuckGo (no API key needed)
   Parameters: query (required), max_results (optional, default 10), timeout (optional, default 30s)
   Returns: Array of search results with title, url, snippet
   Note: Uses DuckDuckGo HTML scraping for privacy-focused search
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
    my $max_results = $params->{max_results} || 10;
    my $timeout = $params->{timeout} || 30;
    
    return $self->error_result("Missing 'query' parameter") unless $query;
    
    # Use DuckDuckGo HTML scraping (no API key required!)
    # DuckDuckGo's HTML search is more reliable than their instant answer API for general queries
    
    my $result;
    eval {
        require URI::Escape;
        my $encoded_query = URI::Escape::uri_escape($query);
        my $url = "https://html.duckduckgo.com/html/?q=$encoded_query";
        
        my $ua = CLIO::Compat::HTTP->new(
            timeout => $timeout,
            agent => 'Mozilla/5.0 (compatible; CLIO/1.0; +https://github.com/cliogpt/clio)',
        );
        
        my $response = $ua->get($url);
        
        unless ($response->is_success) {
            return $self->error_result("HTTP error: " . $response->status_line);
        }
        
        my $html = $response->decoded_content;
        
        # Parse DuckDuckGo HTML results
        # DuckDuckGo HTML format: <div class="result">...</div>
        my @results = ();
        
        # Extract result blocks
        while ($html =~ m{<div class="result[^"]*"[^>]*>(.*?)</div>\s*</div>}gs) {
            my $result_block = $1;
            
            last if @results >= $max_results;
            
            # Extract title from <a class="result__a">
            my $title = '';
            if ($result_block =~ m{<a[^>]*class="result__a"[^>]*>(.*?)</a>}s) {
                $title = $1;
                $title =~ s/<[^>]+>//g;  # Strip HTML tags
                $title =~ s/&quot;/"/g;
                $title =~ s/&amp;/&/g;
                $title =~ s/&lt;/</g;
                $title =~ s/&gt;/>/g;
                $title =~ s/^\s+|\s+$//g;  # Trim whitespace
            }
            
            # Extract URL from <a class="result__url">
            my $link = '';
            if ($result_block =~ m{<a[^>]*class="result__url"[^>]*href="([^"]+)"}s) {
                $link = $1;
                # DuckDuckGo uses redirect URLs, extract actual URL
                if ($link =~ m{//duckduckgo\.com/l/\?uddg=([^&]+)}) {
                    $link = URI::Escape::uri_unescape($1);
                }
            }
            
            # Extract snippet from <a class="result__snippet">
            my $snippet = '';
            if ($result_block =~ m{<a[^>]*class="result__snippet"[^>]*>(.*?)</a>}s) {
                $snippet = $1;
                $snippet =~ s/<[^>]+>//g;  # Strip HTML tags
                $snippet =~ s/&quot;/"/g;
                $snippet =~ s/&amp;/&/g;
                $snippet =~ s/&lt;/</g;
                $snippet =~ s/&gt;/>/g;
                $snippet =~ s/^\s+|\s+$//g;
            }
            
            # Only add if we have at least a title and URL
            if ($title && $link) {
                push @results, {
                    title => $title,
                    url => $link,
                    snippet => $snippet,
                };
            }
        }
        
        my $count = scalar(@results);
        
        if ($count == 0) {
            return $self->success_result(
                "No results found for '$query'",
                action_description => "searching web for '$query' (0 results)",
                results => [],
                query => $query,
                count => 0,
            );
        }
        
        $result = $self->success_result(
            "Found $count results for '$query'",
            action_description => "searching web for '$query' ($count results)",
            results => \@results,
            query => $query,
            count => $count,
        );
    };
    
    if ($@) {
        return $self->error_result("Web search failed: $@");
    }
    
    return $result;
}

1;
