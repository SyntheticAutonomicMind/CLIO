package CLIO::Tools::WebOperations;

use strict;
use warnings;
use Carp qw(croak confess);
use parent 'CLIO::Tools::Tool';
use CLIO::Compat::HTTP;
use CLIO::Util::JSON qw(encode_json decode_json);
use feature 'say';

=head1 NAME

CLIO::Tools::WebOperations - Web fetching and search operations

=head1 DESCRIPTION

Provides web operations for fetching URLs and searching the web.

Search providers:
1. SerpAPI - Reliable multi-engine search (requires API key)
   - Supports: google, bing, duckduckgo engines
   - Configure with: /api set serpapi_key YOUR_KEY
   - Select engine with: /api set search_engine google|bing|duckduckgo

2. DuckDuckGo direct - Fallback, no API key needed but may be rate-limited

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
   
-  search_web - Web search using SerpAPI (configurable) or DuckDuckGo (fallback)
   Parameters: query (required), max_results (optional, default 10), timeout (optional, default 30s)
   Returns: Array of search results with title, url, snippet
   
IMPORTANT - Configuration:
   For reliable results, configure SerpAPI:
   /api set serpapi_key YOUR_KEY     (get key at serpapi.com)
   /api set search_engine google     (options: google, bing, duckduckgo)
   
   Without SerpAPI key, falls back to DuckDuckGo direct (may be rate-limited).
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

=head2 get_additional_parameters

Define parameters for web_operations in JSON schema sent to AI.

=cut

sub get_additional_parameters {
    my ($self) = @_;
    
    return {
        url => {
            type => "string",
            description => "URL to fetch (for fetch_url operation, required)",
        },
        query => {
            type => "string",
            description => "Search query (for search_web operation, required)",
        },
        timeout => {
            type => "integer",
            description => "Timeout in seconds (optional, default: 30)",
        },
        max_results => {
            type => "integer",
            description => "Maximum search results to return (for search_web, default: 10)",
        },
    };
}

sub fetch_url {
    my ($self, $params, $context) = @_;
    
    my $url = $params->{url};
    my $timeout = $params->{timeout} || 30;
    
    return $self->error_result("Missing 'url' parameter") unless $url;
    
    my $result;
    eval {
        # Use browser-like user-agent for better compatibility
        my $ua = CLIO::Compat::HTTP->new(
            timeout => $timeout,
            agent => 'Links (2.8; Linux 4.3.3-hardened-r4 x86_64; GNU C 4.9.3; fb)',
        );
        
        my $response = $ua->get($url);
        
        if ($response->is_success) {
            my $content = $response->decoded_content;
            my $content_type = $response->header('content-type') || '';
            my $raw_size = length($content);
            
            # Convert HTML to readable text if content is HTML
            if ($content_type =~ /text\/html/i || $content =~ /^\s*<!DOCTYPE\s+html/i || $content =~ /<html/i) {
                $content = $self->_html_to_text($content);
            }
            
            my $final_size = length($content);
            my $action_desc = "fetching $url ($raw_size bytes raw, $final_size bytes text, " . $response->code . ")";
            
            $result = $self->success_result(
                $content,
                action_description => $action_desc,
                url => $url,
                status => $response->code,
                content_type => $content_type,
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

=head2 _html_to_text

Convert HTML content to readable plain text.
Strips scripts, styles, and HTML tags while preserving meaningful structure.

=cut

sub _html_to_text {
    my ($self, $html) = @_;
    
    return '' unless defined $html && length($html);
    
    my $text = $html;
    
    # Remove script and style blocks with their content (including multiline)
    $text =~ s/<script[^>]*>.*?<\/script>//gsi;
    $text =~ s/<style[^>]*>.*?<\/style>//gsi;
    
    # Remove noscript blocks
    $text =~ s/<noscript[^>]*>.*?<\/noscript>//gsi;
    
    # Remove head section (contains meta, links, etc.)
    $text =~ s/<head[^>]*>.*?<\/head>//gsi;
    
    # Remove HTML comments
    $text =~ s/<!--.*?-->//gs;
    
    # Add newlines before block elements for structure
    $text =~ s/<\/(p|div|h[1-6]|li|tr|br|hr)[^>]*>/\n/gi;
    $text =~ s/<(p|div|h[1-6]|li|tr|br|hr)[^>]*>/\n/gi;
    
    # Replace common list markers
    $text =~ s/<li[^>]*>/\n• /gi;
    
    # Remove all remaining HTML tags
    $text =~ s/<[^>]+>//g;
    
    # Decode common HTML entities
    $text =~ s/&nbsp;/ /g;
    $text =~ s/&amp;/&/g;
    $text =~ s/&lt;/</g;
    $text =~ s/&gt;/>/g;
    $text =~ s/&quot;/"/g;
    $text =~ s/&#39;/'/g;
    $text =~ s/&apos;/'/g;
    
    # Decode hyphen entities (important for temperature ranges, dates, etc.)
    $text =~ s/&#45;/-/g;
    $text =~ s/&#x2D;/-/gi;
    $text =~ s/&hyphen;/-/g;
    $text =~ s/&#8209;/-/g;
    $text =~ s/&#x2011;/-/gi;
    $text =~ s/&ndash;/–/g;
    $text =~ s/&#8211;/–/g;
    $text =~ s/&mdash;/—/g;
    $text =~ s/&#8212;/—/g;
    
    # Decode numeric HTML entities (&#NNN;)
    $text =~ s/&#(\d+);/chr($1)/ge;
    
    # Decode hex HTML entities (&#xHH;)
    $text =~ s/&#x([0-9a-fA-F]+);/chr(hex($1))/ge;
    
    # Normalize whitespace
    $text =~ s/[ \t]+/ /g;          # Collapse horizontal whitespace
    $text =~ s/\n[ \t]+/\n/g;       # Remove leading whitespace on lines
    $text =~ s/[ \t]+\n/\n/g;       # Remove trailing whitespace on lines
    $text =~ s/\n{3}/\n\n/g;       # Collapse multiple blank lines
    
    # Trim leading/trailing whitespace
    $text =~ s/^\s+//;
    $text =~ s/\s+$//;
    
    return $text;
}

sub search_web {
    my ($self, $params, $context) = @_;
    
    my $query = $params->{query};
    my $max_results = $params->{max_results} || 10;
    my $timeout = $params->{timeout} || 30;
    
    return $self->error_result("Missing 'query' parameter") unless $query;
    
    # Get config from context - check multiple locations
    my $config;
    if ($context && ref($context) eq 'HASH') {
        if ($context->{config}) {
            # Direct config reference (e.g., from ToolExecutor)
            $config = $context->{config};
            if (ref($config) && $config->can('get')) {
                # Config object - use get method
                $config = {
                    serpapi_key => $config->get('serpapi_key') || '',
                    search_engine => $config->get('search_engine') || 'google',
                    search_provider => $config->get('search_provider') || 'auto',
                    check_local_first => $config->get('check_local_first') || 0,
                };
            }
        } elsif ($context->{session} && ref($context->{session}) eq 'HASH') {
            $config = $context->{session}{config} || {};
        }
    }
    $config ||= {};
    
    # Check local history first (optional - enabled via config)
    # This searches previous sessions for related content before going to web
    my $local_note = '';
    if ($config->{check_local_first}) {
        $local_note = $self->_check_local_history($query, $context);
    }
    
    # Allow environment variable as fallback
    my $serpapi_key = $config->{serpapi_key} || $ENV{SERPAPI_KEY} || '';
    my $search_engine = $config->{search_engine} || 'google';  # google, bing, duckduckgo
    my $search_provider = $config->{search_provider} || 'auto';
    
    # Determine which provider to use
    my $result;
    my @errors;
    
    # Try SerpAPI first (if configured)
    if ($search_provider eq 'serpapi' || ($search_provider eq 'auto' && $serpapi_key)) {
        if ($serpapi_key) {
            $result = $self->_search_serpapi($query, $max_results, $timeout, $serpapi_key, $search_engine);
            if ($result && !$result->{error}) {
                # Prepend local history note if found
                $result = $self->_prepend_local_note($result, $local_note);
                return $result;
            }
            push @errors, "SerpAPI ($search_engine): " . ($result->{error} || 'unknown error');
        } elsif ($search_provider eq 'serpapi') {
            return $self->error_result("SerpAPI key not configured. Set with: /api set serpapi_key YOUR_KEY");
        }
    }
    
    # Fallback to DuckDuckGo direct (or explicit duckduckgo selection)
    if ($search_provider eq 'duckduckgo_direct' || $search_provider eq 'auto') {
        $result = $self->_search_duckduckgo_direct($query, $max_results, $timeout);
        if ($result && !$result->{error}) {
            # Prepend local history note if found
            $result = $self->_prepend_local_note($result, $local_note);
            return $result;
        }
        push @errors, "DuckDuckGo Direct: " . ($result->{error} || 'unknown error');
    }
    
    # All providers failed
    my $error_msg = "All search providers failed:\n" . join("\n", @errors);
    if (!$serpapi_key) {
        $error_msg .= "\n\nTip: Configure SerpAPI for reliable results:\n" .
                      "  /api set serpapi_key YOUR_KEY  (get key at serpapi.com)\n" .
                      "  /api set search_engine google  (options: google, bing, duckduckgo)";
    }
    return $self->error_result($error_msg);
}

=head2 _check_local_history

Check project history for related content before searching web.

This is an optional feature that helps avoid redundant web searches
when the answer might already exist in previous sessions.

Arguments:
- $query: Search query
- $context: Execution context with session info

Returns: String with local matches note, or empty string

=cut

sub _check_local_history {
    my ($self, $query, $context) = @_;
    
    return '' unless $context && $context->{session};
    
    # Try to search previous sessions
    my $sessions_dir = '.clio/sessions';
    return '' unless -d $sessions_dir;
    
    # Quick grep through recent session files
    my @matches;
    opendir my $dh, $sessions_dir or return '';
    my @files = 
        map { $_->[0] }
        sort { $b->[1] <=> $a->[1] }
        map { 
            my $path = File::Spec->catfile($sessions_dir, $_);
            [$path, (stat($path))[9] || 0]
        }
        grep { /\.json$/ && -f File::Spec->catfile($sessions_dir, $_) }
        readdir($dh);
    closedir $dh;
    
    # Search only last 3 sessions
    @files = @files[0..2] if @files > 3;
    
    for my $file (@files) {
        last if @matches >= 2;
        
        eval {
            open my $fh, '<', $file or die;
            local $/;
            my $content = <$fh>;
            close $fh;
            
            # Simple substring match
            if ($content =~ /\Q$query\E/i) {
                my $session_id = $file;
                $session_id =~ s/.*[\/\\]//;
                $session_id =~ s/\.json$//;
                push @matches, $session_id;
            }
        };
    }
    
    return '' unless @matches;
    
    return "[LOCAL HISTORY NOTE: Query '$query' may have been discussed in previous sessions: " .
           join(", ", @matches) . ". Use memory_operations(recall_sessions) for details.]\n\n";
}

=head2 _prepend_local_note

Prepend local history note to search results.

=cut

sub _prepend_local_note {
    my ($self, $result, $local_note) = @_;
    
    return $result unless $local_note;
    
    # Add note to the result summary
    if ($result->{result}) {
        $result->{result} = $local_note . $result->{result};
    }
    
    return $result;
}

# SerpAPI search implementation - supports multiple engines
sub _search_serpapi {
    my ($self, $query, $max_results, $timeout, $api_key, $engine) = @_;
    
    $engine ||= 'google';
    $engine = lc($engine);
    
    # Validate engine and get engine-specific parameters
    my %engine_config = (
        google => {
            name => 'Google',
            result_key => 'organic_results',
            title_key => 'title',
            link_key => 'link',
            snippet_key => 'snippet',
        },
        bing => {
            name => 'Bing',
            result_key => 'organic_results',
            title_key => 'title',
            link_key => 'link',
            snippet_key => 'snippet',
        },
        duckduckgo => {
            name => 'DuckDuckGo',
            result_key => 'organic_results',
            title_key => 'title',
            link_key => 'link',
            snippet_key => 'snippet',
        },
    );
    
    unless ($engine_config{$engine}) {
        return { error => "Unsupported search engine: $engine. Use: google, bing, duckduckgo" };
    }
    
    my $config = $engine_config{$engine};
    
    my $result;
    eval {
        my $encoded_query = _uri_escape($query);
        my $url = "https://serpapi.com/search?engine=$engine&q=$encoded_query&num=$max_results&api_key=$api_key";
        
        my $ua = CLIO::Compat::HTTP->new(
            timeout => $timeout,
            agent => 'CLIO/1.0',
        );
        
        my $response = $ua->get($url);
        
        unless ($response->is_success) {
            croak "HTTP error: " . $response->status_line;
        }
        
        my $json = decode_json($response->decoded_content);
        
        # Check for API errors
        if ($json->{error}) {
            croak "SerpAPI error: " . $json->{error};
        }
        
        my @results = ();
        my $organic = $json->{$config->{result_key}} || [];
        
        for my $item (@$organic) {
            last if @results >= $max_results;
            push @results, {
                title => $item->{$config->{title_key}} || 'No title',
                url => $item->{$config->{link_key}} || '',
                snippet => $item->{$config->{snippet_key}} || 'No description available',
            };
        }
        
        my $count = scalar(@results);
        my $provider_name = "SerpAPI ($config->{name})";
        
        # Format results as readable text for LLM consumption
        my $formatted = _format_search_results_markdown(\@results, $query, $provider_name);
        
        $result = $self->success_result(
            $formatted,  # Return formatted text as main output
            action_description => "searching web for '$query' via $provider_name ($count results)",
            results => \@results,  # Also include structured data
            query => $query,
            count => $count,
            provider => 'serpapi',
            engine => $config->{name},
        );
    };
    
    if ($@) {
        return { error => $@ };
    }
    
    return $result;
}

# DuckDuckGo HTML scraping implementation (fallback)
sub _search_duckduckgo_direct {
    my ($self, $query, $max_results, $timeout) = @_;
    
    my $result;
    eval {
        my $encoded_query = _uri_escape($query);
        # Use DuckDuckGo HTML endpoint with chip-select=search parameter
        my $url = "https://html.duckduckgo.com/html/?q=$encoded_query&chip-select=search";
        
        # Use exact 'links' browser User-Agent that DuckDuckGo trusts
        my $ua = CLIO::Compat::HTTP->new(
            timeout => $timeout,
            agent => 'Links (2.8; Linux 4.3.3-hardened-r4 x86_64; GNU C 4.9.3; fb)',
        );
        
        my $response = $ua->get($url);
        
        unless ($response->is_success) {
            croak "HTTP error: " . $response->status_line;
        }
        
        my $html = $response->decoded_content;
        
        # Check for rate limiting / IP blocking
        if ($html =~ /Unfortunately, bots use DuckDuckGo too/ || 
            $html =~ /If this persists, please/ ||
            (length($html) < 1000 && $html !~ /result/)) {
            croak "DuckDuckGo blocked the request (rate limit or IP block). " .
                "Configure SerpAPI for reliable results: /api set serpapi_key YOUR_KEY";
        }
        
        # Parse DuckDuckGo HTML results
        my @results = ();
        
        while ($html =~ m{<div class="result results_links[^"]*"[^>]*>(.*?)</div>\s*</div>}gs) {
            my $result_block = $1;
            last if @results >= $max_results;
            
            my $title = '';
            my $link = '';
            if ($result_block =~ m{<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>}s) {
                $link = $1;
                $title = $2;
                $title =~ s/<[^>]+>//g;
                $title =~ s/&quot;/"/g;
                $title =~ s/&amp;/&/g;
                $title =~ s/&lt;/</g;
                $title =~ s/&gt;/>/g;
                $title =~ s/^\s+|\s+$//g;
                
                # Extract actual URL from redirect
                if ($link =~ m{//duckduckgo\.com/l/\?uddg=([^&]+)}) {
                    $link = _uri_unescape($1);
                } elsif ($link =~ m{^//}) {
                    $link = 'https:' . $link;
                }
            }
            
            my $snippet = '';
            if ($result_block =~ m{<a[^>]*class="result__snippet"[^>]*>(.*?)</a>}s) {
                $snippet = $1;
                $snippet =~ s/<[^>]+>//g;
                $snippet =~ s/&quot;/"/g;
                $snippet =~ s/&amp;/&/g;
                $snippet =~ s/&lt;/</g;
                $snippet =~ s/&gt;/>/g;
                $snippet =~ s/^\s+|\s+$//g;
            }
            
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
                action_description => "searching web for '$query' via DuckDuckGo Direct (0 results)",
                results => [],
                query => $query,
                count => 0,
                provider => 'duckduckgo_direct',
            );
        } else {
            # Format results as readable text for LLM consumption
            my $formatted = _format_search_results_markdown(\@results, $query, 'DuckDuckGo Direct');
            
            $result = $self->success_result(
                $formatted,  # Return formatted text as main output
                action_description => "searching web for '$query' via DuckDuckGo Direct ($count results)",
                results => \@results,  # Also include structured data
                query => $query,
                count => $count,
                provider => 'duckduckgo_direct',
            );
        }
    };
    
    if ($@) {
        return { error => $@ };
    }
    
    return $result;
}

# Format search results as Markdown for LLM consumption
sub _format_search_results_markdown {
    my ($results, $query, $provider) = @_;
    
    my $count = scalar(@$results);
    my $markdown = "# Web Search Results for \"$query\"\n\n";
    $markdown .= "**Provider:** $provider | **Results:** $count\n\n";
    
    for my $i (0 .. $#{$results}) {
        my $r = $results->[$i];
        my $num = $i + 1;
        
        $markdown .= "## $num. $r->{title}\n";
        $markdown .= "**URL:** $r->{url}\n\n";
        $markdown .= "$r->{snippet}\n\n";
        $markdown .= "---\n\n";
    }
    
    return $markdown;
}

# URI escape helper
sub _uri_escape {
    my ($str) = @_;
    $str =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X", ord($1))/ge;
    return $str;
}

# URI unescape helper
sub _uri_unescape {
    my ($str) = @_;
    $str =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
    return $str;
}

1;

__END__

=head1 CONFIGURATION

Web search can be configured via CLIO commands:

  /api set serpapi_key YOUR_SERPAPI_KEY
  /api set search_engine google|bing|duckduckgo
  /api set search_provider auto|serpapi|duckduckgo_direct

Or via environment variables:

  export SERPAPI_KEY=your_key

Search provider priority (when search_provider=auto):
1. SerpAPI (if key configured) - uses configured engine
2. DuckDuckGo Direct (fallback, may be rate-limited)

=head1 GETTING API KEYS

SerpAPI: https://serpapi.com (100 free searches/month)
  - Supports multiple engines: Google, Bing, DuckDuckGo
  - Use: /api set serpapi_key YOUR_KEY
  - Choose engine: /api set search_engine google

=cut

1;
