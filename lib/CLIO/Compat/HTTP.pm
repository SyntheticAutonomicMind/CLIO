package CLIO::Compat::HTTP;

use strict;
use warnings;
use HTTP::Tiny;
use JSON::PP qw(decode_json encode_json);

# Check if SSL is available for HTTP::Tiny
our $HAS_SSL;
our $HAS_CURL;
BEGIN {
    $HAS_SSL = eval { require IO::Socket::SSL; require Net::SSLeay; 1 };
    $HAS_CURL = -x '/usr/bin/curl' || -x '/bin/curl' || -x '/usr/local/bin/curl';
}

=head1 NAME

CLIO::Compat::HTTP - Portable HTTP client using core modules

=head1 DESCRIPTION

Provides HTTP client functionality using HTTP::Tiny (Perl core since 5.14).
Drop-in replacement for LWP::UserAgent usage in CLIO.

For HTTPS support:
- Prefers HTTP::Tiny with IO::Socket::SSL (if available)
- Falls back to system curl command (portable, works everywhere)

Also provides HTTP::Request-like interface for compatibility.

=head1 METHODS

=cut

sub new {
    my ($class, %opts) = @_;
    
    my $timeout = $opts{timeout} || 30;
    my $agent = $opts{agent} || 'CLIO/1.0';
    my $default_headers = $opts{default_headers} || {};
    my $ssl_opts = $opts{ssl_opts} || { verify_SSL => 1 };
    
    my $self = {
        timeout => $timeout,
        agent => $agent,
        http => undef,
        default_headers => $default_headers,
        use_curl_for_https => !$HAS_SSL && $HAS_CURL,
    };
    
    # Initialize HTTP::Tiny if we have SSL
    if ($HAS_SSL) {
        $self->{http} = HTTP::Tiny->new(
            timeout => $timeout,
            agent => $agent,
            default_headers => $default_headers,
            verify_SSL => $ssl_opts->{verify_hostname} || $ssl_opts->{verify_SSL} || 1,
        );
    } elsif (!$HAS_CURL) {
        warn "[WARN]HTTP] Neither IO::Socket::SSL nor curl available - HTTPS will not work!\n";
        # Still create HTTP::Tiny for HTTP-only requests
        $self->{http} = HTTP::Tiny->new(
            timeout => $timeout,
            agent => $agent,
            default_headers => $default_headers,
        );
    }
    
    return bless $self, $class;
}

=head2 default_header

Set a default header for all requests.

Arguments:
- $key: Header name
- $value: Header value

=cut

sub default_header {
    my ($self, $key, $value) = @_;
    $self->{default_headers}{$key} = $value;
}

=head2 get

Perform HTTP GET request with optional headers.

Arguments:
- $url: URL to fetch
- %opts: Optional hash with 'headers' key

Returns: Response object compatible with LWP::UserAgent

=cut

sub get {
    my ($self, $url, %opts) = @_;
    
    my $headers = {
        %{$self->{default_headers}},
        %{$opts{headers} || {}},
    };
    
    # Use curl for HTTPS if needed
    my $use_curl = $self->{use_curl_for_https} && $url =~ /^https:/i;
    
    my $response;
    if ($use_curl) {
        $response = $self->_request_via_curl('GET', $url, $headers, '');
    } else {
        $response = $self->{http}->get($url, { headers => $headers });
    }
    
    return $self->_convert_response($response);
}

=head2 post

Perform HTTP POST request.

Arguments:
- $url: URL to post to
- $options: Hash ref with headers, content

Returns: Response object compatible with LWP::UserAgent

=cut

sub post {
    my ($self, $url, %opts) = @_;
    
    my $headers = $opts{headers} || {};
    my $content = $opts{content};
    
    # Use curl for HTTPS if needed
    my $use_curl = $self->{use_curl_for_https} && $url =~ /^https:/i;
    
    my $response;
    if ($use_curl) {
        $response = $self->_request_via_curl('POST', $url, $headers, $content);
    } else {
        $response = $self->{http}->post($url, {
            headers => $headers,
            content => $content,
        });
    }
    
    return $self->_convert_response($response);
}

=head2 _request_via_curl

Fallback HTTP implementation using curl command.
Used when IO::Socket::SSL is not available for HTTPS.

Arguments:
- $method: HTTP method (GET, POST, etc.)
- $uri: URL
- $headers: Hash ref of headers
- $content: Request body (optional)

Returns: Hash ref compatible with HTTP::Tiny response format

=cut

sub _request_via_curl {
    my ($self, $method, $uri, $headers, $content) = @_;
    
    use File::Temp qw(tempfile);
    use POSIX qw(:sys_wait_h);
    
    # Build curl command
    my @cmd = ('curl', '-s', '-i', '-X', $method);
    
    # Add timeout
    push @cmd, '--max-time', $self->{timeout} if $self->{timeout};
    
    # Add headers
    for my $header (keys %$headers) {
        push @cmd, '-H', "$header: $headers->{$header}";
    }
    
    # Add request body for POST/PUT (use stdin to avoid shell escaping issues)
    my $content_fh;
    if (defined $content && length($content) > 0) {
        ($content_fh, my $content_file) = tempfile();
        print $content_fh $content;
        close $content_fh;
        push @cmd, '--data-binary', "\@$content_file";
    }
    
    # Add URL
    push @cmd, $uri;
    
    if ($ENV{CLIO_DEBUG}) {
        print STDERR "[DEBUG][HTTP::curl] Running curl with " . scalar(@cmd) . " args\n";
    }
    
    # Execute curl using safe pipe open
    my $output = '';
    if (open(my $curl_fh, '-|', @cmd)) {
        local $/;
        $output = <$curl_fh>;
        close($curl_fh);
    } else {
        return {
            success => 0,
            status => 599,
            reason => 'Internal Exception',
            headers => {},
            content => "Failed to execute curl: $!",
        };
    }
    
    my $exit_code = $? >> 8;
    
    # Parse HTTP response
    my ($status_line, $header_block, $body);
    if ($output =~ /^(HTTP\/[\d.]+\s+(\d+)\s+([^\r\n]*))\r?\n(.*?)\r?\n\r?\n(.*)$/s) {
        $status_line = $1;
        my $status = $2;
        my $reason = $3;
        $header_block = $4;
        $body = $5;
        
        # Parse headers
        my %resp_headers;
        for my $line (split /\r?\n/, $header_block) {
            if ($line =~ /^([^:]+):\s*(.+)$/) {
                $resp_headers{lc($1)} = $2;
            }
        }
        
        if ($ENV{CLIO_DEBUG}) {
            print STDERR "[DEBUG][HTTP::curl] Status: $status $reason\n";
            print STDERR "[DEBUG][HTTP::curl] Body length: " . length($body) . "\n";
        }
        
        return {
            success => ($status >= 200 && $status < 300),
            status => $status,
            reason => $reason,
            headers => \%resp_headers,
            content => $body,
        };
    } else {
        # Failed to parse response
        return {
            success => 0,
            status => 599,
            reason => 'Internal Exception',
            headers => {},
            content => "curl failed: exit code $exit_code",
        };
    }
}

=head2 request

Perform HTTP request with HTTP::Request-like object or parameters.

Arguments:
- $req: HTTP::Request object or method string
- $url_or_callback: (optional) URL if first arg is method, OR callback for streaming

Returns: Response object compatible with LWP::UserAgent

Note: HTTP::Tiny doesn't support true streaming, so callbacks are called
with the full response content split into chunks to simulate streaming.

=cut

sub request {
    my ($self, $req, $url_or_callback) = @_;
    
    # Handle HTTP::Request-like objects
    if (ref($req) && $req->can('method')) {
        my $method = uc($req->method);  # HTTP::Tiny needs uppercase methods!
        my $uri = $req->uri->as_string;
        my $content = $req->content;
        
        # Extract headers
        my %headers;
        $req->headers->scan(sub { 
            my ($key, $val) = @_;
            $headers{$key} = $val;
        });
        
        # Decide whether to use curl for HTTPS
        my $use_curl = $self->{use_curl_for_https} && $uri =~ /^https:/i;
        
        # DEBUG: Print what we're about to send
        if ($ENV{CLIO_DEBUG}) {
            print STDERR "\n[DEBUG][HTTP] Request details:\n";
            print STDERR "  Backend: " . ($use_curl ? "curl" : "HTTP::Tiny") . "\n";
            print STDERR "  Method: $method\n";
            print STDERR "  URI: $uri\n";
            print STDERR "  Content length: " . length($content) . " bytes\n";
        }
        
        my $response;
        if ($use_curl) {
            # Use curl for HTTPS when IO::Socket::SSL is not available
            $response = $self->_request_via_curl($method, $uri, \%headers, $content);
        } else {
            # Use HTTP::Tiny
            my %options = (
                headers => \%headers,
            );
            $options{content} = $content if defined $content && length($content) > 0;
            $response = $self->{http}->request($method, $uri, \%options);
        }
        
        my $resp_obj = $self->_convert_response($response);
        
        # Handle streaming callback (simulate with chunked delivery)
        if (ref($url_or_callback) eq 'CODE') {
            my $callback = $url_or_callback;
            my $body = $response->{content} || '';
            
            if ($ENV{CLIO_DEBUG}) {
                print STDERR "[DEBUG][HTTP] Simulating streaming with " . length($body) . " byte response\n";
            }
            
            # Split response into chunks and call callback
            # Use 8KB chunks to simulate streaming
            my $chunk_size = 8192;
            my $offset = 0;
            while ($offset < length($body)) {
                my $chunk = substr($body, $offset, $chunk_size);
                $callback->($chunk, $resp_obj, undef);
                $offset += $chunk_size;
            }
        }
        
        return $resp_obj;
    }
    
    # Handle simple method + URL
    my $method = uc($req);  # Uppercase for HTTP::Tiny
    my $uri = $url_or_callback;
    
    # Use curl for HTTPS if needed
    my $use_curl = $self->{use_curl_for_https} && $uri =~ /^https:/i;
    
    my $response;
    if ($use_curl) {
        $response = $self->_request_via_curl($method, $uri, {}, '');
    } else {
        $response = $self->{http}->request($method, $uri);
    }
    
    return $self->_convert_response($response);
}

=head2 _convert_response

Convert HTTP::Tiny response to LWP::UserAgent-compatible format.

Arguments:
- $response: HTTP::Tiny response hash

Returns: Object with is_success, code, message, content, decoded_content methods

=cut

sub _convert_response {
    my ($self, $response) = @_;
    
    return bless {
        success => $response->{success},
        status => $response->{status},
        reason => $response->{reason},
        content => $response->{content} || '',
        headers => $response->{headers} || {},
    }, 'CLIO::Compat::HTTP::Response';
}

package CLIO::Compat::HTTP::Response;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    return bless \%args, $class;
}

sub is_success {
    my $self = shift;
    return $self->{success};
}

sub code {
    my $self = shift;
    return $self->{status};
}

sub message {
    my $self = shift;
    return $self->{reason};
}

sub content {
    my $self = shift;
    return $self->{content};
}

sub decoded_content {
    my $self = shift;
    return $self->{content};  # HTTP::Tiny auto-decodes
}

sub header {
    my ($self, $name) = @_;
    return $self->{headers}{lc($name)};
}

sub headers {
    my $self = shift;
    return bless { headers => $self->{headers} }, 'CLIO::Compat::HTTP::Headers';
}

sub status_line {
    my $self = shift;
    return $self->{status} . " " . $self->{reason};
}

sub content_type {
    my $self = shift;
    return $self->{headers}{'content-type'};
}

package CLIO::Compat::HTTP::Request;

use strict;
use warnings;

=head1 NAME

CLIO::Compat::HTTP::Request - HTTP::Request-like interface for compatibility

=head1 DESCRIPTION

Provides HTTP::Request-compatible interface for building requests.

=cut

sub new {
    my ($class, $method, $url) = @_;
    
    my $self = {
        method => uc($method),
        url => $url,
        headers => {},
        content => '',
    };
    
    return bless $self, $class;
}

sub method {
    my $self = shift;
    return $self->{method};
}

sub uri {
    my $self = shift;
    # Return simple object with as_string method
    return bless { url => $self->{url} }, 'CLIO::Compat::HTTP::URI';
}

sub header {
    my ($self, $name, $value) = @_;
    if (defined $value) {
        $self->{headers}{$name} = $value;
    }
    return $self->{headers}{$name};
}

sub headers {
    my $self = shift;
    return bless { headers => $self->{headers} }, 'CLIO::Compat::HTTP::Headers';
}

sub content {
    my ($self, $content) = @_;
    if (defined $content) {
        $self->{content} = $content;
    }
    return $self->{content};
}

package CLIO::Compat::HTTP::URI;

sub as_string {
    my $self = shift;
    return $self->{url};
}

package CLIO::Compat::HTTP::Headers;

sub scan {
    my ($self, $callback) = @_;
    while (my ($key, $value) = each %{$self->{headers}}) {
        $callback->($key, $value);
    }
}

sub header_field_names {
    my $self = shift;
    return keys %{$self->{headers}};
}

sub clone {
    my $self = shift;
    return bless { headers => { %{$self->{headers}} } }, ref($self);
}

package CLIO::Compat::HTTP::Request;

# Export HTTP::Request as alias
package HTTP::Request;
our @ISA = ('CLIO::Compat::HTTP::Request');

package CLIO::Compat::HTTP;

1;
