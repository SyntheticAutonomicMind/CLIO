package CLIO::MCP::Auth::OAuth;

=head1 NAME

CLIO::MCP::Auth::OAuth - OAuth 2.0 PKCE authentication for MCP servers

=head1 DESCRIPTION

Implements the OAuth 2.0 Authorization Code flow with PKCE (Proof Key for
Code Exchange) for authenticating with Model Context Protocol (MCP) servers.
Handles authorization URL generation, token exchange, storage, and refresh.

=head1 SYNOPSIS

    use CLIO::MCP::Auth::OAuth;
    
    my $auth = CLIO::MCP::Auth::OAuth->new(
        server_name       => 'my-server',
        authorization_url => 'https://example.com/auth',
        token_url         => 'https://example.com/token',
        client_id         => 'my-client-id',
    );
    
    my $url = $auth->get_authorization_url();
    my $token = $auth->exchange_code($code);

=cut

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
use Carp qw(croak);
use CLIO::Util::JSON qw(encode_json decode_json);
use MIME::Base64;
use Digest::SHA qw(sha256);
use File::Spec;
use CLIO::Core::Logger qw(should_log log_debug);

sub new {
    my ($class, %args) = @_;
    croak 'server_name required' unless $args{server_name};
    croak 'authorization_url required' unless $args{authorization_url};
    croak 'token_url required' unless $args{token_url};
    croak 'client_id required' unless $args{client_id};
    
    my $self = bless {
        server_name       => $args{server_name},
        authorization_url => $args{authorization_url},
        token_url         => $args{token_url},
        client_id         => $args{client_id},
        client_secret     => $args{client_secret},
        scopes            => $args{scopes} || [],
        redirect_port     => $args{redirect_port} || 8912,
        redirect_path     => $args{redirect_path} || '/callback',
        debug             => $args{debug} || 0,
        _token_data       => undef,
    }, $class;
    $self->_load_cached_token();
    return $self;
}

sub get_access_token {
    my ($self) = @_;
    if ($self->{_token_data}) {
        my $token = $self->{_token_data};
        if ($token->{expires_at} && time() < $token->{expires_at} - 60) {
            log_debug('MCP:OAuth', 'Using cached token for ' . $self->{server_name});
            return $token->{access_token};
        }
        if ($token->{refresh_token}) {
            log_debug('MCP:OAuth', 'Refreshing token for ' . $self->{server_name});
            my $refreshed = $self->_refresh_token($token->{refresh_token});
            return $refreshed->{access_token} if $refreshed;
        }
    }
    log_debug('MCP:OAuth', 'Starting OAuth flow for ' . $self->{server_name});
    my $token = $self->_run_oauth_flow();
    return $token ? $token->{access_token} : undef;
}

sub has_token { defined $_[0]->{_token_data} && defined $_[0]->{_token_data}{access_token} }

sub clear_token {
    my ($self) = @_;
    $self->{_token_data} = undef;
    my $file = $self->_token_file();
    unlink $file if -f $file;
}

sub _run_oauth_flow {
    my ($self) = @_;
    my $cv = $self->_generate_code_verifier();
    my $cc = $self->_generate_code_challenge($cv);
    my $state = $self->_generate_state();
    my $redir = 'http://127.0.0.1:' . $self->{redirect_port} . $self->{redirect_path};
    my $scope = join(' ', @{$self->{scopes}});
    my @p = (
        'response_type=code',
        'client_id=' . _url_encode($self->{client_id}),
        'redirect_uri=' . _url_encode($redir),
        'code_challenge=' . _url_encode($cc),
        'code_challenge_method=S256',
        'state=' . _url_encode($state),
    );
    push @p, 'scope=' . _url_encode($scope) if $scope;
    my $auth_url = $self->{authorization_url} . '?' . join('&', @p);
    
    my ($srv, $ok) = $self->_start_callback_server();
    return undef unless $ok;
    
    print "
  Opening browser for authentication...
";
    print "  If it doesn't open, visit:
  $auth_url

";
    print "  Waiting for callback on port $self->{redirect_port}...
";
    $self->_open_browser($auth_url);
    
    my $cb = $self->_wait_for_callback($srv, $state);
    close $srv;
    return undef unless $cb && $cb->{code};
    
    return $self->_exchange_code(code => $cb->{code}, code_verifier => $cv, redirect_uri => $redir);
}

sub _generate_code_verifier {
    my @c = ('A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_', '~');
    my $v = '';
    if (open my $fh, '<:raw', '/dev/urandom') {
        my $b; read($fh, $b, 64); close $fh;
        $v .= $c[$_ % scalar(@c)] for unpack('C*', $b);
    } else { $v .= $c[int(rand(scalar @c))] for 1..64; }
    return $v;
}

sub _generate_code_challenge {
    my ($self, $v) = @_;
    return _base64url_encode(sha256($v));
}

sub _generate_state {
    my @c = ('A'..'Z', 'a'..'z', '0'..'9');
    my $s = ''; $s .= $c[int(rand(scalar @c))] for 1..32;
    return $s;
}

sub _exchange_code {
    my ($self, %a) = @_;
    my %p = (grant_type => 'authorization_code', code => $a{code},
             redirect_uri => $a{redirect_uri}, client_id => $self->{client_id},
             code_verifier => $a{code_verifier});
    $p{client_secret} = $self->{client_secret} if $self->{client_secret};
    return $self->_token_request(%p);
}

sub _refresh_token {
    my ($self, $rt) = @_;
    my %p = (grant_type => 'refresh_token', refresh_token => $rt, client_id => $self->{client_id});
    $p{client_secret} = $self->{client_secret} if $self->{client_secret};
    return $self->_token_request(%p);
}

sub _token_request {
    my ($self, %p) = @_;
    require HTTP::Tiny;
    my $http = HTTP::Tiny->new(timeout => 30);
    my $body = join('&', map { _url_encode($_) . '=' . _url_encode($p{$_}) } keys %p);
    my $r = $http->request('POST', $self->{token_url}, {
        headers => { 'Content-Type' => 'application/x-www-form-urlencoded', 'Accept' => 'application/json' },
        content => $body,
    });
    unless ($r->{success}) {
        print STDERR '[ERROR][MCP:OAuth] Token request failed: ' . $r->{status} . ' ' . $r->{reason} . "
" if should_log('ERROR');
        return undef;
    }
    my $d = eval { decode_json($r->{content}) };
    return undef if $@ || !$d->{access_token};
    $d->{expires_at} = time() + $d->{expires_in} if $d->{expires_in};
    $self->{_token_data} = $d;
    $self->_save_token($d);
    return $d;
}

sub _start_callback_server {
    my ($self) = @_;
    require IO::Socket::INET;
    my $s = IO::Socket::INET->new(LocalAddr => '127.0.0.1', LocalPort => $self->{redirect_port},
                                   Proto => 'tcp', Listen => 1, ReuseAddr => 1);
    return ($s, 1) if $s;
    return (undef, 0);
}

sub _wait_for_callback {
    my ($self, $server, $expected_state) = @_;
    local $SIG{ALRM} = sub { die 'timeout' };
    alarm(120);
    my $result;
    eval {
        my $client = $server->accept();
        if ($client) {
            my $req = '';
            while (my $line = <$client>) { $req .= $line; last if $line =~ /^?
$/; }
            if ($req =~ /^GET\s+([^\s]+)/) {
                my %params;
                if ($1 =~ /\?(.+)/) {
                    for (split /&/, $1) { my ($k,$v) = split /=/, $_, 2; $params{_url_decode($k)} = _url_decode($v||''); }
                }
                if ($params{state} && $params{state} eq $expected_state && $params{code}) {
                    $result = { code => $params{code} };
                    my $h = '<html><body><h1>OK</h1><p>Return to CLIO.</p></body></html>';
                    print $client "HTTP/1.1 200 OK
Content-Type: text/html
Content-Length: " . length($h) . "
Connection: close

$h";
                }
            }
            close $client;
        }
    };
    alarm(0);
    return $result;
}

sub _open_browser {
    my ($self, $url) = @_;
    my $cmd = ($^O eq 'darwin') ? 'open' : ($^O eq 'linux') ? 'xdg-open' : undef;
    return unless $cmd;
    if (fork() == 0) { open STDOUT, '>/dev/null'; open STDERR, '>/dev/null'; exec $cmd, $url; exit 1; }
}

sub _token_dir { File::Spec->catdir($ENV{HOME} || '/tmp', '.clio', 'mcp-tokens') }

sub _token_file {
    my ($self) = @_;
    my $n = $self->{server_name}; $n =~ s/[^a-zA-Z0-9_-]/_/g;
    return File::Spec->catfile($self->_token_dir(), "$n.json");
}

sub _load_cached_token {
    my ($self) = @_;
    my $f = $self->_token_file();
    return unless -f $f;
    eval { open my $fh, '<:raw', $f or die; my $j = do { local $/; <$fh> }; close $fh;
           $self->{_token_data} = decode_json($j); };
}

sub _save_token {
    my ($self, $d) = @_;
    my $dir = $self->_token_dir();
    unless (-d $dir) { require File::Path; File::Path::make_path($dir); }
    my $f = $self->_token_file();
    my $t = "$f.tmp";
    eval { open my $fh, '>:raw', $t or die; print $fh encode_json($d); close $fh;
           chmod 0600, $t; rename $t, $f or die; };
    unlink $t if $@ && -f $t;
}

sub _url_encode { my $s = shift; $s =~ s/([^A-Za-z0-9\-._~])/sprintf('%%%02X', ord($1))/ge; $s }
sub _url_decode { my $s = shift; $s =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge; $s }
sub _base64url_encode { my $b = MIME::Base64::encode_base64(shift, ''); $b =~ tr{+/}{-_}; $b =~ s/=+$//; $b }

1;
