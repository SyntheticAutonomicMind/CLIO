package CLIO::MCP::Client;

use strict;
use warnings;
use utf8;

=head1 NAME

CLIO::MCP::Client - Model Context Protocol client implementation

=head1 DESCRIPTION

Transport-agnostic MCP client. Handles the MCP protocol lifecycle
(initialize, tool discovery, tool calls) over any transport that
implements send_request(), send_notification(), connect(), disconnect().

Supported transports:
- CLIO::MCP::Transport::Stdio - Local servers via subprocess stdin/stdout
- CLIO::MCP::Transport::HTTP  - Remote servers via Streamable HTTP / SSE

=head1 SYNOPSIS

    use CLIO::MCP::Client;
    use CLIO::MCP::Transport::Stdio;
    
    my $transport = CLIO::MCP::Transport::Stdio->new(
        command => ['npx', '-y', '@modelcontextprotocol/server-filesystem', '/tmp'],
    );
    
    my $client = CLIO::MCP::Client->new(
        name      => 'filesystem',
        transport => $transport,
    );
    
    $client->connect() or die "Failed";
    my $tools = $client->list_tools();
    my $result = $client->call_tool('read_file', { path => '/tmp/test.txt' });
    $client->disconnect();

=cut

use CLIO::Util::JSON qw(encode_json decode_json);
use CLIO::Core::Logger qw(should_log log_debug);

sub new {
    my ($class, %args) = @_;
    
    my $self = bless {
        name        => $args{name} || 'unnamed',
        transport   => $args{transport},
        debug       => $args{debug} || 0,
        connected   => 0,
        server_info => undef,
        server_caps => undef,
        tools       => [],
    }, $class;
    
    # Legacy: build stdio transport from command if no transport provided
    if (!$self->{transport} && $args{command}) {
        require CLIO::MCP::Transport::Stdio;
        $self->{transport} = CLIO::MCP::Transport::Stdio->new(
            name        => $args{name},
            command     => $args{command},
            environment => $args{environment} || {},
            timeout     => $args{timeout} || 30,
            debug       => $args{debug} || 0,
        );
    }
    
    return $self;
}

=head2 connect

Connect transport and perform MCP initialization handshake.

Returns: 1 on success, 0 on failure

=cut

sub connect {
    my ($self) = @_;
    
    my $transport = $self->{transport};
    unless ($transport) {
        print STDERR "[ERROR][MCP:$self->{name}] No transport configured\n" if should_log('ERROR');
        return 0;
    }
    
    log_debug('MCP', "Connecting to server '$self->{name}'");
    
    # Connect transport
    unless ($transport->connect()) {
        print STDERR "[ERROR][MCP:$self->{name}] Transport connection failed\n" if should_log('ERROR');
        return 0;
    }
    
    # MCP initialization handshake
    my $init_ok = $self->_initialize();
    
    if ($init_ok) {
        $self->{connected} = 1;
        log_debug('MCP', "Server '$self->{name}' initialized successfully");
        $self->_discover_tools();
        return 1;
    } else {
        print STDERR "[ERROR][MCP:$self->{name}] Initialization handshake failed\n" if should_log('ERROR');
        $self->disconnect();
        return 0;
    }
}

=head2 disconnect

Gracefully shut down the MCP server connection.

=cut

sub disconnect {
    my ($self) = @_;
    
    if ($self->{transport}) {
        $self->{transport}->disconnect();
    }
    
    $self->{connected} = 0;
    log_debug('MCP', "Server '$self->{name}' disconnected");
}

=head2 is_connected

Check if the MCP server is connected and alive.

=cut

sub is_connected {
    my ($self) = @_;
    return 0 unless $self->{connected} && $self->{transport};
    return $self->{transport}->is_connected();
}

=head2 list_tools

Get the list of tools available from this MCP server.

Returns: Arrayref of tool definitions

=cut

sub list_tools {
    my ($self) = @_;
    return $self->{tools} || [];
}

=head2 call_tool

Call a tool on the MCP server.

Arguments:
- $tool_name: Name of the tool to call
- $arguments: Hashref of arguments to pass

Returns: Hashref with result (content array) or error

=cut

sub call_tool {
    my ($self, $tool_name, $arguments) = @_;
    
    unless ($self->is_connected()) {
        return { error => "Not connected to server '$self->{name}'" };
    }
    
    my $response = $self->{transport}->send_request('tools/call', {
        name      => $tool_name,
        arguments => $arguments || {},
    });
    
    if (!$response) {
        return { error => "No response from server '$self->{name}'" };
    }
    
    if ($response->{error}) {
        return {
            error   => $response->{error}{message} || 'Unknown error',
            code    => $response->{error}{code},
            isError => 1,
        };
    }
    
    my $result = $response->{result} || {};
    
    # Extract text content from MCP result format
    my $text = '';
    if ($result->{content} && ref($result->{content}) eq 'ARRAY') {
        for my $item (@{$result->{content}}) {
            if ($item->{type} eq 'text') {
                $text .= $item->{text} . "\n" if defined $item->{text};
            } elsif ($item->{type} eq 'image') {
                $text .= "[Image: $item->{mimeType}]\n";
            } elsif ($item->{type} eq 'resource') {
                if ($item->{resource} && $item->{resource}{text}) {
                    $text .= $item->{resource}{text} . "\n";
                } else {
                    $text .= "[Resource: $item->{resource}{uri}]\n";
                }
            }
        }
    }
    
    return {
        content => $result->{content},
        text    => $text,
        isError => $result->{isError} ? 1 : 0,
    };
}

=head2 Accessors

=cut

sub server_info         { return $_[0]->{server_info} }
sub server_capabilities { return $_[0]->{server_caps} }
sub name                { return $_[0]->{name} }

# === Private methods ===

sub _initialize {
    my ($self) = @_;
    
    my $response = $self->{transport}->send_request('initialize', {
        protocolVersion => '2025-11-25',
        capabilities    => {
            roots => { listChanged => JSON::PP::false },
        },
        clientInfo => {
            name    => 'CLIO',
            version => '2.0.0',
        },
    });
    
    unless ($response && $response->{result}) {
        print STDERR "[ERROR][MCP:$self->{name}] Initialize failed - no valid response\n" if should_log('ERROR');
        return 0;
    }
    
    my $result = $response->{result};
    
    $self->{server_info} = $result->{serverInfo};
    $self->{server_caps} = $result->{capabilities};
    
    my $server_name = $result->{serverInfo}{name} || 'unknown';
    my $server_ver  = $result->{serverInfo}{version} || '?';
    my $proto_ver   = $result->{protocolVersion} || '?';
    
    log_debug('MCP', "Server: $server_name v$server_ver (protocol: $proto_ver)");
    
    if ($result->{instructions}) {
        log_debug('MCP', "Server instructions: $result->{instructions}");
    }
    
    # Send initialized notification
    $self->{transport}->send_notification('notifications/initialized', {});
    
    return 1;
}

sub _discover_tools {
    my ($self) = @_;
    
    unless ($self->{server_caps} && $self->{server_caps}{tools}) {
        log_debug('MCP', "Server '$self->{name}' does not advertise tools capability");
        $self->{tools} = [];
        return;
    }
    
    my $response = $self->{transport}->send_request('tools/list', {});
    
    unless ($response && $response->{result} && $response->{result}{tools}) {
        print STDERR "[WARN][MCP:$self->{name}] tools/list returned no tools\n" if should_log('WARNING');
        $self->{tools} = [];
        return;
    }
    
    $self->{tools} = $response->{result}{tools};
    
    my $count = scalar @{$self->{tools}};
    log_debug('MCP', "Server '$self->{name}' provides $count tool(s)");
    
    for my $tool (@{$self->{tools}}) {
        log_debug('MCP', "  - $tool->{name}: " . ($tool->{description} || 'no description'));
    }
}

sub DESTROY {
    my ($self) = @_;
    $self->disconnect() if $self->{connected};
}

1;

__END__

=head1 SEE ALSO

L<CLIO::MCP::Transport::Stdio>, L<CLIO::MCP::Transport::HTTP>, L<CLIO::MCP::Manager>

MCP Specification: L<https://modelcontextprotocol.io/specification/2025-11-25>

=cut
