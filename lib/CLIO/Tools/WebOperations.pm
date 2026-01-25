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
   
IMPORTANT - Known Limitations:
   DuckDuckGo may block requests from datacenter/cloud IP addresses.
   Residential networks typically work better. If you encounter blocking errors,
   consider using a search API (Bing API, Google Custom Search Engine) which
   allow programmatic access with API keys.
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
        # Use browser-like user-agent for better compatibility
        # Use 'links' text browser - widely compatible and not flagged as bot
        my $ua = CLIO::Compat::HTTP->new(
            timeout => $timeout,
            agent => 'Links (2.29; Linux x86_64; GNU C 11.2; text)',
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
    # Match SAM's approach: GET request with query parameters
    
    my $result;
    eval {
        my $encoded_query = _uri_escape($query);
        # Use DuckDuckGo HTML endpoint (simpler to parse than main site)
        # CRITICAL: Don't include &s=0 parameter - it triggers bot detection!
        my $url = "https://html.duckduckgo.com/html/?q=$encoded_query";
        
        # Use browser-like user-agent to avoid CAPTCHA (matches SAM's approach)
        # DuckDuckGo blocks obvious bots, so we pretend to be a real browser
        # CRITICAL: Use 'links' text browser User-Agent - it works reliably!
        # DuckDuckGo trusts links and doesn't require HTTP/2
        my $ua = CLIO::Compat::HTTP->new(
            timeout => $timeout,
            agent => 'Links (2.29; Linux x86_64; GNU C 11.2; text)',
        );
        
        # Use GET request (not POST) - matches SAM
        my $response = $ua->get($url);
        
        unless ($response->is_success) {
            die "HTTP error: " . $response->status_line;
        }
        
        my $html = $response->decoded_content;
        
        # Check for CAPTCHA or IP-based blocking
        if ($html =~ /Unfortunately, bots use DuckDuckGo too/) {
            die "DuckDuckGo CAPTCHA challenge detected. This usually happens when:\n" .
                "  - Requests are coming from a datacenter/cloud IP address\n" .
                "  - Too many requests from the same IP\n" .
                "  - Network is flagged for bot activity\n" .
                "Consider using a search API (Bing, Google Custom Search) for reliable programmatic access.";
        }
        
        # Check for HTTP error responses in content (400, 403, etc.)
        if ($html =~ /^<!DOCTYPE html>/ && length($html) < 500) {
            die "DuckDuckGo returned an error page. This may indicate IP-based blocking. " .
                "Residential networks typically have better success than datacenter/cloud IPs.";
        }
        
        # Parse DuckDuckGo HTML results
        # DuckDuckGo HTML format: <div class="result">...</div>
        my @results = ();
        
        # Extract result blocks - DuckDuckGo uses "result results_links" class
        while ($html =~ m{<div class="result results_links[^"]*"[^>]*>(.*?)</div>\s*</div>}gs) {
            my $result_block = $1;
            
            last if @results >= $max_results;
            
            # Extract title and URL from <a class="result__a">
            my $title = '';
            my $link = '';
            if ($result_block =~ m{<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>}s) {
                $link = $1;
                $title = $2;
                $title =~ s/<[^>]+>//g;  # Strip HTML tags
                $title =~ s/&quot;/"/g;
                $title =~ s/&amp;/&/g;
                $title =~ s/&lt;/</g;
                $title =~ s/&gt;/>/g;
                $title =~ s/^\s+|\s+$//g;  # Trim whitespace
                
                # DuckDuckGo uses redirect URLs, extract actual URL
                if ($link =~ m{//duckduckgo\.com/l/\?uddg=([^&]+)}) {
                    $link = _uri_unescape($1);
                } elsif ($link =~ m{^//}) {
                    # Protocol-relative URL
                    $link = 'https:' . $link;
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
                    snippet => $snippet || 'No description available',
                };
            }
        }
        
        my $count = scalar(@results);
        
        if ($count == 0) {
            $result = $self->success_result(
                "No results found for '$query'",
                action_description => "searching web for '$query' (0 results)",
                results => [],
                query => $query,
                count => 0,
            );
        } else {
            $result = $self->success_result(
                "Found $count results for '$query'",
                action_description => "searching web for '$query' ($count results)",
                results => \@results,
                query => $query,
                count => $count,
            );
        }
    };
    
    if ($@) {
        return $self->error_result("Web search failed: $@");
    }
    
    return $result;
}

# Helper function: URI escape (percent encoding)
# Implements RFC 3986 URI encoding without CPAN dependencies
sub _uri_escape {
    my ($str) = @_;
    return '' unless defined $str;
    
    # Encode all bytes except unreserved characters (A-Za-z0-9-_.~)
    $str =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X", ord($1))/ge;
    
    return $str;
}

# Helper function: URI unescape (percent decoding)
# Decodes percent-encoded characters without CPAN dependencies
sub _uri_unescape {
    my ($str) = @_;
    return '' unless defined $str;
    
    # Decode %XX sequences
    $str =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
    
    return $str;
}

1;
