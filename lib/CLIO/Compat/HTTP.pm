# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Compat::HTTP;

use strict;
use warnings;
use utf8;
use HTTP::Tiny;
use File::Temp qw(tempfile);
use POSIX qw(:errno_h);
use CLIO::Util::JSON qw(decode_json encode_json);
use CLIO::Core::Logger qw(should_log log_debug log_warning);
use CLIO::Util::CABundle qw(find_ca_bundle);
use CLIO::Util::Proxy qw(resolve_proxy_url);
use CLIO::Util::Curl qw(locate_curl);

# Check if SSL is available for HTTP::Tiny
our $HAS_SSL;
our $HAS_CURL;
BEGIN {
    $HAS_SSL = eval { require IO::Socket::SSL; require Net::SSLeay; 1 };
    $HAS_CURL = defined locate_curl();
}

=head1 NAME

CLIO::Compat::HTTP - Portable HTTP client using core modules

=head1 SYNOPSIS

    use CLIO::Compat::HTTP;

    my $response = CLIO::Compat::HTTP::_request_via_curl($url, %opts);
    my $streaming = CLIO::Compat::HTTP::_request_via_curl_streaming($url, $cb, %opts);

=head1 DESCRIPTION

Provides HTTP client functionality using HTTP::Tiny (Perl core since 5.14).
Drop-in replacement for LWP::UserAgent usage in CLIO.

For HTTPS support:
- Prefers HTTP::Tiny with IO::Socket::SSL (if available)
- Falls back to system curl command (portable, works everywhere)

Proxy support:
- HTTP proxies: http://host:port
- SOCKS proxies: socks5://host:port, socks5h://host:port, socks4://host:port
- Configured via constructor `proxy` option or environment variables
- Environment variables checked (in order): HTTPS_PROXY, HTTP_PROXY, ALL_PROXY

Also provides HTTP::Request-like interface for compatibility.

=head1 METHODS

=cut

sub new {
    my ($class, %opts) = @_;
    
    my $timeout = $opts{timeout} || 30;
    my $proxy = $opts{proxy} || '';
    my $agent = $opts{agent} || 'CLIO/1.0';
    my $default_headers = $opts{default_headers} || {};
    
    # CLIO_TLS_VERIFY=0 disables SSL certificate verification (for self-signed certs)
    # Env var wins when ssl_opts doesn't explicitly set verify_SSL
    my $tls_verify = (exists $opts{ssl_opts} && defined $opts{ssl_opts}{verify_SSL})
        ? $opts{ssl_opts}{verify_SSL}
        : defined $ENV{CLIO_TLS_VERIFY} ? ($ENV{CLIO_TLS_VERIFY} ? 1 : 0)
        : 1;
    my $ssl_opts = $opts{ssl_opts} || { verify_SSL => $tls_verify };
    
    # Resolve proxy: explicit parameter > environment variables
    my $resolved_proxy = _resolve_proxy($proxy);
    
    my $self = {
        timeout => $timeout,
        agent => $agent,
        http => undef,
        default_headers => $default_headers,
        use_curl_for_https => !$HAS_SSL && $HAS_CURL,
        proxy => $resolved_proxy,
        tls_verify => $tls_verify,
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
        $http_tiny_opts{verify_SSL} = $tls_verify;
    } elsif (!$HAS_CURL) {
        # Only warn if neither SSL nor curl is available - this is a real problem
        log_warning('HTTP', "Neither IO::Socket::SSL nor curl available - HTTPS will not work!");
    }
    
    # Always create HTTP::Tiny instance (needed for HTTP URLs even with curl for HTTPS)
    # Pass proxy to HTTP::Tiny if configured
    if ($self->{proxy}) {
        $http_tiny_opts{proxy} = $self->{proxy};
    }
    
    $self->{http} = HTTP::Tiny->new(%http_tiny_opts);
    
    return bless $self, $class;
}

=head2 _resolve_proxy

Resolve proxy URL from explicit parameter or environment variables.
Checks standard proxy environment variables in order of precedence.

Arguments:
- $explicit: Explicitly configured proxy URL (from config or constructor)

Returns: Proxy URL string, or empty string if no proxy configured

=cut

sub _resolve_proxy {
    my ($explicit) = @_;
    return resolve_proxy_url($explicit);
}

=head2 proxy

Get or set the proxy URL.

Arguments:
- $url: New proxy URL (optional)

Returns: Current proxy URL

=cut

sub proxy {
    my ($self, $url) = @_;
    if (defined $url) {
        $self->{proxy} = $url;
        # Update HTTP::Tiny proxy too
        if ($self->{http}) {
            # HTTP::Tiny doesn't support changing proxy after construction,
            # so recreate it with the new proxy
            my %opts = (
                timeout => $self->{timeout},
                agent => $self->{agent},
                default_headers => $self->{default_headers},
            );
            $opts{verify_SSL} = 1 if $HAS_SSL;
            $opts{proxy} = $url if $url;
            $self->{http} = HTTP::Tiny->new(%opts);
        }
    }
    return $self->{proxy};
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

Searches for CA certificates using the centralized CLIO::Util::CABundle module.
Returns undef if no bundle is found.

Returns: Path to CA bundle file, or undef

=cut

sub _find_ca_bundle {
    my ($self) = @_;
    return find_ca_bundle();
}

sub _request_via_curl {
    my ($self, $method, $uri, $headers, $content) = @_;
    
    # Build curl command
    my @cmd = ('curl', '-s', '-i', '-X', $method);
    
    # Add timeout
    push @cmd, '--max-time', $self->{timeout} if $self->{timeout};
    
    # Add proxy if configured
    push @cmd, '--proxy', $self->{proxy} if $self->{proxy};
    
    # Add CA bundle for HTTPS (iOS/a-Shell compatibility)
    my $ca_bundle = $self->_find_ca_bundle();
    if ($ca_bundle) {
        push @cmd, '--cacert', $ca_bundle;
    }
    
    # Disable TLS verification if requested
    push @cmd, '--insecure' unless $self->{tls_verify};
    
    # Add headers
    for my $header (keys %$headers) {
        push @cmd, '-H', "$header: $headers->{$header}";
    }
    
    # Add request body for POST/PUT (use stdin to avoid shell escaping issues)
    my $content_fh;
    my $content_file;
    if (defined $content && length($content) > 0) {
        ($content_fh, $content_file) = tempfile();
        print $content_fh $content;
        close $content_fh;
        push @cmd, '--data-binary', "\@$content_file";
    }
    
    # Add URL
    push @cmd, $uri;
    
    if (should_log("DEBUG")) {
        log_debug('HTTP', "Running curl with " . scalar(@cmd) . " args");
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
    
    # Clean up temp file used for POST data
    unlink $content_file if $content_file;

    my $exit_code = $? >> 8;

    # Parse HTTP response
    my ($status_line, $header_block, $body);
    if ($output =~ /^(HTTP\/[\d.]+\s+(\d+)\s*([^\r\n]*))\r?\n(.*?)\r?\n\r?\n(.*)$/s) {
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
        
        if (should_log("DEBUG")) {
            log_debug('HTTP::curl', "Status: $status $reason");
            log_debug('HTTP', "Body length: " . length($body));
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
    
    # Build curl command - use -N (no-buffer) for streaming and separate headers
    my @cmd = ('curl', '-s', '-N', '-X', $method);
    
    # Write headers to a temp file so we can parse them
    my ($hdr_fh, $hdr_file) = tempfile(UNLINK => 1);
    close $hdr_fh;
    push @cmd, '-D', $hdr_file;  # Dump headers to file
    
    # Add timeout
    push @cmd, '--max-time', $self->{timeout} if $self->{timeout};
    
    # Add proxy if configured
    push @cmd, '--proxy', $self->{proxy} if $self->{proxy};
    
    # Add CA bundle for HTTPS (iOS/a-Shell compatibility)
    my $ca_bundle = $self->_find_ca_bundle();
    if ($ca_bundle) {
        push @cmd, '--cacert', $ca_bundle;
    }
    
    # Disable TLS verification if requested
    push @cmd, '--insecure' unless $self->{tls_verify};
    
    # Add headers
    for my $header (keys %$headers) {
        push @cmd, '-H', "$header: $headers->{$header}";
    }
    
    # Add request body
    my $content_file;
    if (defined $content && length($content) > 0) {
        my $content_fh;
    my $content_file;
        ($content_fh, $content_file) = tempfile(UNLINK => 1);
        print $content_fh $content;
        close $content_fh;
        push @cmd, '--data-binary', "\@$content_file";
    }
    
    # Add URL
    push @cmd, $uri;
    
    if (should_log("DEBUG")) {
        log_debug('HTTP::curl_streaming', "Starting streaming curl request");
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
    my $read_buf;
    my $chunk_size = 4096;  # Read in 4KB chunks for responsive streaming
    my $preliminary_response;  # Created on first chunk for real-time delivery
    
    # sysread on the pipe will block until data arrives or be interrupted by signals
    # The ALRM signal handler (set by Chat.pm) fires every second, causing EINTR
    # which we handle below - this allows ESC interrupt detection during streaming
    
    while (1) {
        my $bytes = sysread($curl_fh, $read_buf, $chunk_size);
        
        if (!defined $bytes) {
            # sysread error - likely EINTR from signal
            # On EINTR (signal interrupt), check whether the ALRM handler
            # detected a user ESC interrupt. If so, kill curl and abort
            # immediately instead of blindly retrying - this is what makes
            # ESC interrupt a streaming response within ~250ms instead of
            # waiting for the full server response.
            if ($! == EINTR) {
                if (eval { CLIO::Core::Interrupt::pending() }) {
                    log_info('HTTP::curl_streaming', "User interrupt detected (EINTR), aborting stream");
                    kill('TERM', $curl_pid);
                    waitpid($curl_pid, 0);
                    last;
                }
                next;  # Non-interrupt signal - retry
            }
            last;  # Real error
        }
        
        last if $bytes == 0;  # EOF
        
        $accumulated_content .= $read_buf;
        
        # Deliver chunk immediately to callback (real-time streaming)
        if ($callback) {
            $preliminary_response //= bless {
                success => 1,
                status => 200,
                reason => 'OK',
                headers => {},
                content => '',
            }, 'CLIO::Compat::HTTP::Response';
            eval { $callback->($read_buf, $preliminary_response, undef); };
            if ($@) {
                log_warning('HTTP::curl_streaming', "Callback error: $@");
            }
        }

        # Check for user interrupt (ESC) after delivering the chunk.
        # Even if the syscall didn't return EINTR, the ALRM handler
        # may have set the global flag between iterations.
        if (eval { CLIO::Core::Interrupt::pending() }) {
            log_info('HTTP::curl_streaming', "User interrupt detected after chunk, aborting stream");
            kill('TERM', $curl_pid);
            waitpid($curl_pid, 0);
            last;
        }
    }
    
    close($curl_fh);
    my $exit_code = $? >> 8;
    
    # Map common curl exit codes to human-readable descriptions
    my %curl_errors = (
        6  => 'DNS resolution failed',
        7  => 'Connection refused',
        18 => 'Partial transfer',
        22 => 'HTTP error',
        28 => 'Connection timed out',
        35 => 'TLS handshake failed',
        47 => 'Too many redirects',
        52 => 'Empty reply from server',
        55 => 'Send error',
        56 => 'Connection reset by server',
        92 => 'HTTP/2 stream error',
    );

    # Parse headers from the header dump file
    my $status;
    my $reason;
    my %resp_headers;
    
    if (open(my $hfh, '<', $hdr_file)) {
        log_debug('HTTP::curl_streaming', "Parsing headers from $hdr_file");
        while (my $line = <$hfh>) {
            chomp $line;
            $line =~ s/\r$//;
            log_debug('HTTP::curl_streaming', "Header line: $line");
            if ($line =~ /^HTTP\/[\d.]+\s+(\d+)\s*(.*)$/) {
                $status = $1;
                $reason = $2 // '';
            } elsif ($line =~ /^([^:]+):\s*(.+)$/) {
                $resp_headers{lc($1)} = $2;
            }
        }
        close $hfh;
        log_debug('HTTP::curl_streaming', "Parsed " . scalar(keys %resp_headers) . " headers: " . join(", ", keys %resp_headers));
    } else {
        log_debug('HTTP::curl_streaming', "Failed to open header file $hdr_file: $!");
    }
    
    # If no HTTP status was parsed from headers, check curl exit code
    if (!defined $status) {
        if ($exit_code == 0 && length($accumulated_content) > 0) {
            # curl succeeded and we got data - assume 200
            $status = 200;
            $reason = 'OK';
        } else {
            # curl failed or no data - report as connection error
            $status = 599;
            $reason = $curl_errors{$exit_code} || "curl exit code $exit_code";
        }
    }
    $reason //= '';

    # Override bogus status on curl failure.  HTTP/2 can report "000" when
    # the stream is reset before a real status arrives.  Treat any non-success
    # exit combined with a non-2xx status (including < 100) as a connection error.
    if ($exit_code != 0 && !($status >= 200 && $status < 300)) {
        my $desc = $curl_errors{$exit_code} || "curl exit code $exit_code";
        if ($status < 100) {
            log_debug('HTTP::curl_streaming', "Bogus status $status with curl exit $exit_code - setting to 599 ($desc)");
            $status = 599;
            $reason = $desc;
        }
    } elsif ($exit_code != 0 && $status >= 200 && $status < 300) {
        my $desc = $curl_errors{$exit_code} || "curl exit code $exit_code";
        log_debug('HTTP::curl_streaming', "curl exit code $exit_code but headers showed $status - overriding to 599 ($desc)");
        $status = 599;
        $reason = "$desc (was HTTP $status)";
    }

    if (should_log("DEBUG")) {
        log_debug('HTTP', "Streaming complete: status=$status, " . length($accumulated_content) . " bytes, exit_code=$exit_code");
    }
    
    # Create response object with correct headers (parsed from header file)
    my $final_response = bless {
        success => ($status >= 200 && $status < 300),
        status => $status,
        reason => $reason,
        headers => \%resp_headers,
        content => $accumulated_content,
    }, 'CLIO::Compat::HTTP::Response';
    
    return $final_response;
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
        if (should_log("DEBUG")) {
            log_debug('HTTP', "Request details:");
            log_debug('HTTP', "  Backend: " . ($use_curl ? "curl" : "HTTP::Tiny") . "");
            log_debug('HTTP', "  Method: $method");
            log_debug('HTTP', "  URI: $uri");
            log_debug('HTTP', "  Content length: " . length($content) . " bytes");
            log_debug('HTTP', "  Streaming: " . ($has_callback ? "true" : "false") . "");
        }
        
        my $response;
        if ($use_curl || ($has_callback && $HAS_CURL)) {
            # Use curl for streaming when available. HTTP::Tiny's internal
            # _do_timeout() retries select() after EINTR without checking for
            # interrupts, so the ALRM-handler-set flag is never checked until
            # the next data chunk arrives — which can be seconds or minutes.
            # Curl's sysread-based loop checks Interrupt::pending() after
            # each EINTR and each chunk, enabling sub-second ESC detection.
            # (When SSL IS available but curl is also available, we override
            # the normal HTTP::Tiny path for streaming only; non-streaming
            # requests still use HTTP::Tiny for connection pooling.)
            if ($has_callback) {
                $response = $self->_request_via_curl_streaming($method, $uri, \%headers, $content, $url_or_callback);
            } else {
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
                    
                    # Check for user interrupt (ESC) after delivering the chunk.
                    # HTTP::Tiny does not support early abort from data_callback
                    # via a return value, but if we die() here the exception
                    # propagates through HTTP::Tiny's internal read loop (which
                    # does not catch exceptions from data_callback) and is
                    # caught by the eval{} in APIManager::send_request_streaming.
                    # This lets the user abort a streaming response within
                    # ~250ms (the ALRM interval) instead of waiting for the
                    # server to finish its full response.
                    if (eval { CLIO::Core::Interrupt::pending() }) {
                        log_info('HTTP', "User interrupt detected during HTTP::Tiny streaming, aborting");
                        die "__CLIO_INTERRUPT_ABORT__\n";
                    }
                };
                
                $response = $self->{http}->request($method, $uri, \%options);
                # Note: with data_callback, $response->{content} is empty
                # Store accumulated content on the response for post-processing
                # Only overwrite content when we actually received streaming data (2xx response).
                # For error responses (4xx/5xx), the error body is in $response->{content} already
                # and the data_callback was never invoked, so accumulated_content would be empty.
                # Overwriting would destroy the error message, making debugging impossible.
                if (length($accumulated_content) > 0) {
                    $response->{content} = $accumulated_content;
                } # else: preserve original $response->{content} (may contain error body)
                
                if (should_log("DEBUG")) {
                    log_debug('HTTP', "True streaming complete: " . length($accumulated_content) . " bytes delivered via callback");
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
use utf8;

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
use utf8;

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

sub header {
    my ($self, $name) = @_;
    return $self->{headers}{lc($name)};
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
