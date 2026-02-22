package CLIO::MCP::Manager;

use strict;
use warnings;
use utf8;

=head1 NAME

CLIO::MCP::Manager - Manages multiple MCP server connections

=head1 DESCRIPTION

Central manager for MCP (Model Context Protocol) server connections.
Reads configuration, spawns servers, manages lifecycle, and provides
a unified interface for tool discovery and execution.

MCP servers are only started if the 'npx' command is available and
MCP is configured. The feature degrades gracefully when unavailable.

=head1 SYNOPSIS

    use CLIO::MCP::Manager;
    
    my $mgr = CLIO::MCP::Manager->new(config => $config, debug => 1);
    $mgr->start();
    
    my $tools = $mgr->all_tools();
    my $result = $mgr->call_tool('filesystem_read_file', { path => '/tmp/test.txt' });
    
    $mgr->shutdown();

=cut

use CLIO::Util::JSON qw(encode_json decode_json);

use CLIO::Core::Logger qw(should_log log_debug log_error log_info log_warning);
use CLIO::MCP::Client;

my $INSTANCE;

sub new {
    my ($class, %args) = @_;
    
    my $self = bless {
        config     => $args{config},
        debug      => $args{debug} || 0,
        clients    => {},      # name => CLIO::MCP::Client
        status     => {},      # name => { status => 'connected'|'failed'|'disabled', error => ... }
        available  => undef,   # Whether MCP is available (npx check)
    }, $class;
    
    $INSTANCE = $self;
    return $self;
}

=head2 instance

Get the singleton Manager instance.

=cut

sub instance { return $INSTANCE }

=head2 is_available

Check if MCP support is available (npx/node in PATH).

Returns: 1 if available, 0 if not

=cut

sub is_available {
    my ($self) = @_;
    
    # Cache the check
    if (!defined $self->{available}) {
        # Check for npx OR node - some MCP servers use node directly
        my $npx    = _which('npx');
        my $node   = _which('node');
        my $uvx    = _which('uvx');
        my $python = _which('python3') || _which('python');
        
        # MCP servers can be run with npx, node, python, or any executable
        # We just need at least one runtime available
        $self->{available} = ($npx || $node || $uvx || $python) ? 1 : 0;
        
        if (!$self->{available}) {
            log_debug('MCP', "MCP support unavailable: no npx, node, uvx, or python found in PATH");
        } else {
            my @found;
            push @found, 'npx'     if $npx;
            push @found, 'node'    if $node;
            push @found, 'uvx'     if $uvx;
            push @found, 'python'  if $python;
            log_debug('MCP', "MCP support available (runtimes: " . join(', ', @found) . ")");
        }
    }
    
    return $self->{available};
}

=head2 start

Initialize all configured MCP servers.
Reads MCP config and attempts to connect to each enabled server.

Returns: Number of successfully connected servers

=cut

sub start {
    my ($self) = @_;
    
    unless ($self->is_available()) {
        log_debug('MCP', "MCP disabled - no compatible runtimes found");
        return 0;
    }
    
    my $mcp_config = $self->_get_mcp_config();
    
    unless ($mcp_config && ref($mcp_config) eq 'HASH' && keys %$mcp_config) {
        log_debug('MCP', "No MCP servers configured");
        return 0;
    }
    
    my $connected = 0;
    
    for my $name (sort keys %$mcp_config) {
        my $server_config = $mcp_config->{$name};
        
        # Skip disabled servers
        if (exists $server_config->{enabled} && !$server_config->{enabled}) {
            $self->{status}{$name} = { status => 'disabled' };
            log_debug('MCP', "Server '$name' is disabled");
            next;
        }
        
        # Determine server type and create appropriate transport
        my $server_type = $server_config->{type} || 'local';
        my $client;
        
        if ($server_type eq 'remote') {
            # Remote HTTP/SSE server
            my $url = $server_config->{url};
            unless ($url) {
                $self->{status}{$name} = { status => 'failed', error => 'No url configured for remote server' };
                log_warning('MCP', "Server '$name' has no url configured");
                next;
            }
            
            my $headers = { %{$server_config->{headers} || {}} };
            
            # Handle OAuth authentication
            if ($server_config->{auth} && $server_config->{auth}{type} eq 'oauth') {
                my $auth_config = $server_config->{auth};
                eval {
                    require CLIO::MCP::Auth::OAuth;
                    my $oauth = CLIO::MCP::Auth::OAuth->new(
                        server_name       => $name,
                        authorization_url => $auth_config->{authorization_url},
                        token_url         => $auth_config->{token_url},
                        client_id         => $auth_config->{client_id},
                        client_secret     => $auth_config->{client_secret},
                        scopes            => $auth_config->{scopes} || [],
                        redirect_port     => $auth_config->{redirect_port} || 8912,
                        debug             => $self->{debug},
                    );
                    my $token = $oauth->get_access_token();
                    if ($token) {
                        $headers->{'Authorization'} = "Bearer $token";
                        $self->{_oauth}{$name} = $oauth;  # Cache for token refresh
                        log_debug('MCP', "OAuth token acquired for '$name'");
                    } else {
                        log_warning('MCP', "OAuth authentication failed for '$name'");
                    }
                };
                if ($@) {
                    log_warning('MCP', "OAuth setup failed for '$name': $@");
                }
            }
            
            require CLIO::MCP::Transport::HTTP;
            my $transport = CLIO::MCP::Transport::HTTP->new(
                url     => $url,
                headers => $headers,
                timeout => $server_config->{timeout} || 30,
                debug   => $self->{debug},
            );
            
            $client = CLIO::MCP::Client->new(
                name      => $name,
                transport => $transport,
                debug     => $self->{debug},
            );
        } else {
            # Local stdio server (default)
            my $command = $server_config->{command};
            unless ($command && ref($command) eq 'ARRAY' && @$command) {
                $self->{status}{$name} = { status => 'failed', error => 'No command configured' };
                log_warning('MCP', "Server '$name' has no command configured");
                next;
            }
            
            # Check that the command executable exists
            my $exe = $command->[0];
            unless ($self->_command_exists($exe)) {
                $self->{status}{$name} = { status => 'failed', error => "Command not found: $exe" };
                log_warning('MCP', "Server '$name': command '$exe' not found in PATH");
                next;
            }
            
            $client = CLIO::MCP::Client->new(
                name        => $name,
                command     => $command,
                environment => $server_config->{environment} || {},
                timeout     => $server_config->{timeout} || 30,
                debug       => $self->{debug},
            );
        }
        
        eval {
            if ($client->connect()) {
                $self->{clients}{$name} = $client;
                $self->{status}{$name}  = { status => 'connected' };
                $connected++;
                
                my $tools = $client->list_tools();
                my $tool_count = scalar @$tools;
                my $info = $client->server_info();
                my $server_name = $info ? ($info->{name} || $name) : $name;
                
                log_info('MCP', "Connected to '$server_name' ($tool_count tools)");
            } else {
                $self->{status}{$name} = { status => 'failed', error => 'Connection failed' };
                log_warning('MCP', "Failed to connect to '$name'");
            }
        };
        if ($@) {
            $self->{status}{$name} = { status => 'failed', error => "$@" };
            log_error('MCP', "Error connecting to '$name': $@");
        }
    }
    
    if ($connected > 0) {
        log_info('MCP', "$connected MCP server(s) connected");
    }
    
    return $connected;
}

=head2 shutdown

Disconnect all MCP servers gracefully.

=cut

sub shutdown {
    my ($self) = @_;
    
    for my $name (keys %{$self->{clients}}) {
        eval {
            $self->{clients}{$name}->disconnect();
        };
        if ($@) {
            log_warning('MCP', "Error disconnecting '$name': $@");
        }
    }
    
    $self->{clients} = {};
    $self->{status}  = {};
}

=head2 all_tools

Get all tools from all connected MCP servers, namespaced by server name.

Returns: Arrayref of { server => name, name => qualified_name, tool => tool_def }

=cut

sub all_tools {
    my ($self) = @_;
    
    my @all_tools;
    
    for my $name (sort keys %{$self->{clients}}) {
        my $client = $self->{clients}{$name};
        next unless $client->is_connected();
        
        my $tools = $client->list_tools();
        for my $tool (@$tools) {
            # Namespace: servername_toolname
            my $qualified_name = $self->_qualify_tool_name($name, $tool->{name});
            
            push @all_tools, {
                server         => $name,
                name           => $qualified_name,
                original_name  => $tool->{name},
                tool           => $tool,
            };
        }
    }
    
    return \@all_tools;
}

=head2 call_tool

Call a namespaced MCP tool.

Arguments:
- $qualified_name: Namespaced tool name (e.g., 'filesystem_read_file')
- $arguments: Hashref of arguments

Returns: Result hashref

=cut

sub call_tool {
    my ($self, $qualified_name, $arguments) = @_;
    
    # Find which server owns this tool
    for my $name (keys %{$self->{clients}}) {
        my $client = $self->{clients}{$name};
        next unless $client->is_connected();
        
        my $tools = $client->list_tools();
        for my $tool (@$tools) {
            my $qname = $self->_qualify_tool_name($name, $tool->{name});
            if ($qname eq $qualified_name) {
                return $client->call_tool($tool->{name}, $arguments);
            }
        }
    }
    
    return { error => "MCP tool not found: $qualified_name" };
}

=head2 server_status

Get status of all configured servers.

Returns: Hashref of { name => { status, tools_count, server_info, error } }

=cut

sub server_status {
    my ($self) = @_;
    
    my %result;
    
    for my $name (sort keys %{$self->{status}}) {
        my $status = $self->{status}{$name};
        my $info = {
            status => $status->{status},
        };
        
        if ($status->{status} eq 'connected' && $self->{clients}{$name}) {
            my $client = $self->{clients}{$name};
            $info->{tools_count} = scalar @{$client->list_tools()};
            $info->{server_info} = $client->server_info();
        }
        
        if ($status->{error}) {
            $info->{error} = $status->{error};
        }
        
        $result{$name} = $info;
    }
    
    return \%result;
}

=head2 add_server

Dynamically add and connect to an MCP server.

Arguments:
- $name: Server name
- $command_or_config: Arrayref of command (local) OR hashref { url => ..., headers => {} } (remote)

=cut

sub add_server {
    my ($self, $name, $command_or_config) = @_;
    
    if ($self->{clients}{$name}) {
        $self->{clients}{$name}->disconnect();
    }
    
    my $client;
    
    if (ref($command_or_config) eq 'HASH' && $command_or_config->{url}) {
        # Remote HTTP server
        my $headers = { %{$command_or_config->{headers} || {}} };
        
        # Handle OAuth if configured
        if ($command_or_config->{auth} && $command_or_config->{auth}{type} eq 'oauth') {
            eval {
                require CLIO::MCP::Auth::OAuth;
                my $ac = $command_or_config->{auth};
                my $oauth = CLIO::MCP::Auth::OAuth->new(
                    server_name       => $name,
                    authorization_url => $ac->{authorization_url},
                    token_url         => $ac->{token_url},
                    client_id         => $ac->{client_id},
                    client_secret     => $ac->{client_secret},
                    scopes            => $ac->{scopes} || [],
                    redirect_port     => $ac->{redirect_port} || 8912,
                    debug             => $self->{debug},
                );
                my $token = $oauth->get_access_token();
                if ($token) {
                    $headers->{'Authorization'} = "Bearer $token";
                    $self->{_oauth}{$name} = $oauth;
                }
            };
        }
        
        require CLIO::MCP::Transport::HTTP;
        my $transport = CLIO::MCP::Transport::HTTP->new(
            url     => $command_or_config->{url},
            headers => $headers,
            timeout => $command_or_config->{timeout} || 30,
            debug   => $self->{debug},
        );
        $client = CLIO::MCP::Client->new(
            name      => $name,
            transport => $transport,
            debug     => $self->{debug},
        );
    } else {
        # Local stdio server
        unless ($self->is_available()) {
            return { success => 0, error => 'MCP not available (no compatible runtimes found)' };
        }
        $client = CLIO::MCP::Client->new(
            name    => $name,
            command => $command_or_config,
            debug   => $self->{debug},
        );
    }
    
    if ($client->connect()) {
        $self->{clients}{$name} = $client;
        $self->{status}{$name}  = { status => 'connected' };
        
        my $tools = $client->list_tools();
        return { success => 1, tools_count => scalar @$tools };
    }
    
    $self->{status}{$name} = { status => 'failed', error => 'Connection failed' };
    return { success => 0, error => 'Failed to connect to MCP server' };
}

=head2 remove_server

Disconnect and remove an MCP server.

=cut

sub remove_server {
    my ($self, $name) = @_;
    
    if ($self->{clients}{$name}) {
        $self->{clients}{$name}->disconnect();
        delete $self->{clients}{$name};
    }
    
    delete $self->{status}{$name};
    
    return { success => 1 };
}

# === Private methods ===

sub _qualify_tool_name {
    my ($self, $server_name, $tool_name) = @_;
    
    # Sanitize names: only allow alphanumeric, underscore, hyphen
    my $safe_server = $server_name;
    $safe_server =~ s/[^a-zA-Z0-9_-]/_/g;
    
    my $safe_tool = $tool_name;
    $safe_tool =~ s/[^a-zA-Z0-9_-]/_/g;
    
    return "${safe_server}_${safe_tool}";
}

sub _get_mcp_config {
    my ($self) = @_;
    
    my $config = $self->{config};
    return undef unless $config;
    
    # Try to get MCP config from CLIO config object
    if (ref($config) && ref($config) ne 'HASH' && $config->can('get')) {
        return $config->get('mcp');
    }
    
    # Direct hashref config
    if (ref($config) eq 'HASH') {
        return $config->{mcp};
    }
    
    return undef;
}

sub _command_exists {
    my ($self, $exe) = @_;
    
    # Absolute path
    return -x $exe if $exe =~ m{^/};
    
    # Check PATH
    return defined _which($exe);
}

# Simple which() implementation - find executable in PATH (no CPAN dependency)
sub _which {
    my ($name) = @_;
    return undef unless defined $name && length $name;
    
    for my $dir (split /:/, $ENV{PATH} || '') {
        my $path = "$dir/$name";
        return $path if -x $path && !-d $path;
    }
    return undef;
}

sub DESTROY {
    my ($self) = @_;
    $self->shutdown();
}

1;

__END__

=head1 SEE ALSO

L<CLIO::MCP::Client>, L<CLIO::Tools::MCPBridge>

=cut
