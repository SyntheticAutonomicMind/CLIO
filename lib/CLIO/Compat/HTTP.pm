package CLIO::Compat::HTTP;

use strict;
use warnings;
use HTTP::Tiny;
use JSON::PP qw(decode_json encode_json);
use CLIO::Core::Logger qw(should_log);

# Check if SSL is available for HTTP::Tiny
our $HAS_SSL;
our $HAS_CURL;
BEGIN {
    $HAS_SSL = eval { require IO::Socket::SSL; require Net::SSLeay; 1 };
    
    # Check for curl: first try filesystem paths (desktop), then 'which' command (iOS/a-Shell)
    $HAS_CURL = -x '/usr/bin/curl' || -x '/bin/curl' || -x '/usr/local/bin/curl';
    
    unless ($HAS_CURL) {
        # iOS/a-Shell pattern: curl is an ios_system command, not a filesystem path
        my $which_curl = `which curl 2>/dev/null`;
        $HAS_CURL = ($which_curl && $which_curl =~ /curl/);
    }
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
    
    # Initialize HTTP::Tiny
    # We always need HTTP::Tiny for HTTP requests, even if we use curl for HTTPS
    my %http_tiny_opts = (
        timeout => $timeout,
        agent => $agent,
        default_headers => $default_headers,
    );
    
    # Add SSL verification option only if SSL is available
    if ($HAS_SSL) {
        # Use defined-or with proper precedence
        my $verify = defined($ssl_opts->{verify_SSL}) ? $ssl_opts->{verify_SSL} : 1;
        $http_tiny_opts{verify_SSL} = $verify;
    } elsif (!$HAS_CURL) {
        # Only warn if neither SSL nor curl is available - this is a real problem
        print STDERR "[WARN][HTTP] Neither IO::Socket::SSL nor curl available - HTTPS will not work!\n"
            if should_log('WARNING');
    }
    
    # Always create HTTP::Tiny instance (needed for HTTP URLs even with curl for HTTPS)
    $self->{http} = HTTP::Tiny->new(%http_tiny_opts);
    
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

=head2 _find_ca_bundle

Find platform-appropriate CA certificate bundle for curl.

Searches for CA certificates in standard Unix locations and iOS locations.
Returns undef if no bundle is found.

Returns: Path to CA bundle file, or undef

=cut

sub _find_ca_bundle {
    my ($self) = @_;
    
    # Standard Unix/Linux/macOS paths
    my @paths = (
        '/etc/ssl/certs/ca-certificates.crt',     # Debian/Ubuntu
        '/etc/pki/tls/certs/ca-bundle.crt',       # RHEL/CentOS
        '/etc/ssl/cert.pem',                       # OpenBSD/macOS
        '/usr/local/etc/openssl/cert.pem',        # macOS Homebrew
        # iOS/a-Shell specific paths
        "$ENV{HOME}/Documents/cacert.pem",         # User Documents
        "$ENV{HOME}/../cacert.pem",                # a-Shell app bundle
        '/tmp/cacert.pem',                         # Temporary location
    );
    
    for my $path (@paths) {
        if (-f $path && -r $path) {
            return $path;
        }
    }
    
    return undef;
}

sub _request_via_curl {
    my ($self, $method, $uri, $headers, $content) = @_;
    
    use File::Temp qw(tempfile);
    use POSIX qw(:sys_wait_h);
    
    # Build curl command
    my @cmd = ('curl', '-s', '-i', '-X', $method);
    
    # Add timeout
    push @cmd, '--max-time', $self->{timeout} if $self->{timeout};
    
    # Add CA bundle for HTTPS (iOS/a-Shell compatibility)
    my $ca_bundle = $self->_find_ca_bundle();
    if ($ca_bundle) {
        push @cmd, '--cacert', $ca_bundle;
    }
    
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

=head2 _request_via_curl_streaming

Make an HTTPS request using curl with true streaming output.
Instead of buffering the entire response, reads curl output incrementally
and delivers chunks to the callback as they arrive.

Arguments:
- $method: HTTP method
- $uri: Request URL
- $headers: Hash ref of headers
- $content: Request body
- $callback: Code ref called with ($chunk, $response_obj, undef)

Returns: Response hash compatible with HTTP::Tiny format

=cut

sub _request_via_curl_streaming {
    my ($self, $method, $uri, $headers, $content, $callback) = @_;
    
    use File::Temp qw(tempfile);
    
    # Build curl command - use -N (no-buffer) for streaming and separate headers
    my @cmd = ('curl', '-s', '-N', '-X', $method);
    
    # Write headers to a temp file so we can parse them
    my ($hdr_fh, $hdr_file) = tempfile(UNLINK => 1);
    close $hdr_fh;
    push @cmd, '-D', $hdr_file;  # Dump headers to file
    
    # Add timeout
    push @cmd, '--max-time', $self->{timeout} if $self->{timeout};
    
    # Add CA bundle for HTTPS (iOS/a-Shell compatibility)
    my $ca_bundle = $self->_find_ca_bundle();
    if ($ca_bundle) {
        push @cmd, '--cacert', $ca_bundle;
    }
    
    # Add headers
    for my $header (keys %$headers) {
        push @cmd, '-H', "$header: $headers->{$header}";
    }
    
    # Add request body
    my $content_file;
    if (defined $content && length($content) > 0) {
        my $content_fh;
        ($content_fh, $content_file) = tempfile(UNLINK => 1);
        print $content_fh $content;
        close $content_fh;
        push @cmd, '--data-binary', "\@$content_file";
    }
    
    # Add URL
    push @cmd, $uri;
    
    if ($ENV{CLIO_DEBUG}) {
        print STDERR "[DEBUG][HTTP::curl_streaming] Starting streaming curl request\n";
    }
    
    # Open curl as a pipe for streaming reads
    my $curl_pid = open(my $curl_fh, '-|', @cmd);
    
    if (!$curl_pid) {
        return {
            success => 0,
            status => 599,
            reason => 'Internal Exception',
            headers => {},
            content => "Failed to execute curl for streaming: $!",
        };
    }
    
    # Read and deliver chunks incrementally
    my $accumulated_content = '';
    my $resp_obj;
    my $read_buf;
    my $chunk_size = 4096;  # Read in 4KB chunks for responsive streaming
    
    # sysread on the pipe will block until data arrives or be interrupted by signals
    # The ALRM signal handler (set by Chat.pm) fires every second, causing EINTR
    # which we handle below - this allows ESC interrupt detection during streaming
    
    while (1) {
        my $bytes = sysread($curl_fh, $read_buf, $chunk_size);
        
        if (!defined $bytes) {
            # sysread error - likely EINTR from signal
            use POSIX qw(:errno_h);
            next if $! == EINTR;  # Retry on signal interrupt
            last;  # Real error
        }
        
        last if $bytes == 0;  # EOF
        
        $accumulated_content .= $read_buf;
        
        # Create response object lazily (we don't have headers yet from pipe mode)
        if (!$resp_obj) {
            $resp_obj = bless {
                success => 1,  # Assume success, will verify later
                status => 200,
                reason => 'OK',
                content => '',
                headers => {},
            }, 'CLIO::Compat::HTTP::Response';
        }
        
        # Deliver chunk to callback
        eval { $callback->($read_buf, $resp_obj, undef); };
        if ($@) {
            print STDERR "[WARN][HTTP::curl_streaming] Callback error: $@\n" if $ENV{CLIO_DEBUG};
        }
    }
    
    close($curl_fh);
    my $exit_code = $? >> 8;
    
    # Parse headers from the header dump file
    my $status = 200;
    my $reason = 'OK';
    my %resp_headers;
    
    if (open(my $hfh, '<', $hdr_file)) {
        while (my $line = <$hfh>) {
            chomp $line;
            $line =~ s/\r$//;
            if ($line =~ /^HTTP\/[\d.]+\s+(\d+)\s+(.*)$/) {
                $status = $1;
                $reason = $2;
            } elsif ($line =~ /^([^:]+):\s*(.+)$/) {
                $resp_headers{lc($1)} = $2;
            }
        }
        close $hfh;
    }
    
    if ($ENV{CLIO_DEBUG}) {
        print STDERR "[DEBUG][HTTP::curl_streaming] Streaming complete: status=$status, " . 
            length($accumulated_content) . " bytes, exit_code=$exit_code\n";
    }
    
    return {
        success => ($status >= 200 && $status < 300),
        status => $status,
        reason => $reason,
        headers => \%resp_headers,
        content => $accumulated_content,
    };
}

=head2 request

Perform HTTP request with HTTP::Request-like object or parameters.

Arguments:
- $req: HTTP::Request object or method string
- $url_or_callback: (optional) URL if first arg is method, OR callback for streaming

Returns: Response object compatible with LWP::UserAgent

Streaming: When a callback is provided, uses true streaming:
- HTTP::Tiny: native data_callback for real-time chunk delivery
- curl: pipe-based streaming with incremental reads
This allows interrupt detection during long API calls.

=cut

sub request {
    my ($self, $req, $url_or_callback) = @_;
    
    # Handle HTTP::Request-like objects
    if (ref($req) && $req->can('method')) {
        my $method = $req->method // 'GET';
        $method = uc($method);  # HTTP::Tiny needs uppercase methods!
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
        
        # Determine if we have a streaming callback
        my $has_callback = ref($url_or_callback) eq 'CODE';
        
        # DEBUG: Print what we're about to send
        if ($ENV{CLIO_DEBUG}) {
            print STDERR "\n[DEBUG][HTTP] Request details:\n";
            print STDERR "  Backend: " . ($use_curl ? "curl" : "HTTP::Tiny") . "\n";
            print STDERR "  Method: $method\n";
            print STDERR "  URI: $uri\n";
            print STDERR "  Content length: " . length($content) . " bytes\n";
            print STDERR "  Streaming: " . ($has_callback ? "true" : "false") . "\n";
        }
        
        my $response;
        if ($use_curl) {
            if ($has_callback) {
                # Use curl with true streaming via pipe
                $response = $self->_request_via_curl_streaming($method, $uri, \%headers, $content, $url_or_callback);
            } else {
                # Use curl with buffered response
                $response = $self->_request_via_curl($method, $uri, \%headers, $content);
            }
        } else {
            # Use HTTP::Tiny
            my %options = (
                headers => \%headers,
            );
            $options{content} = $content if defined $content && length($content) > 0;
            
            if ($has_callback) {
                # True streaming: Use HTTP::Tiny's data_callback for real-time chunk delivery
                # Each chunk from the server triggers the callback immediately
                my $resp_obj_ref;  # Will hold response object once headers arrive
                my $accumulated_content = '';
                
                $options{data_callback} = sub {
                    my ($chunk, $response) = @_;
                    $accumulated_content .= $chunk;
                    
                    # Create response object on first chunk (headers are available)
                    if (!$resp_obj_ref) {
                        $resp_obj_ref = $self->_convert_response({
                            success => ($response->{status} >= 200 && $response->{status} < 300),
                            status => $response->{status},
                            reason => $response->{reason},
                            headers => $response->{headers} || {},
                            content => '',  # Content delivered via callback
                        });
                    }
                    
                    # Deliver chunk to caller's callback
                    $url_or_callback->($chunk, $resp_obj_ref, undef);
                };
                
                $response = $self->{http}->request($method, $uri, \%options);
                # Note: with data_callback, $response->{content} is empty
                # Store accumulated content on the response for post-processing
                $response->{content} = $accumulated_content;
                
                if ($ENV{CLIO_DEBUG}) {
                    print STDERR "[DEBUG][HTTP] True streaming complete: " . length($accumulated_content) . " bytes delivered via callback\n";
                }
            } else {
                $response = $self->{http}->request($method, $uri, \%options);
            }
        }
        
        my $resp_obj = $self->_convert_response($response);
        
        return $resp_obj;
    }
    
    # Handle simple method + URL
    my $method = uc($req // 'GET');  # Default to GET if method undefined
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
    
    # Default method to GET if undefined (avoid 'uninitialized' warning in uc())
    $method //= 'GET';
    
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
