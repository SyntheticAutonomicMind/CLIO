package CLIO::Security::AuthorizationRelay;

use strict;
use warnings;
use utf8;

use CLIO::Core::Logger qw(log_debug log_info log_warning log_error);

=head1 NAME

CLIO::Security::AuthorizationRelay - Route authorization requests through the coordination broker

=head1 DESCRIPTION

When a sub-agent (headless, no TTY) encounters a security prompt that requires
user approval, this module sends the request through the coordination broker to
the primary session where the user can respond interactively.

The relay is transparent to the calling tool - it returns 1 (approved) or 0
(denied), matching the same interface as the direct TTY prompt functions.

=head1 SYNOPSIS

    use CLIO::Security::AuthorizationRelay;

    my $relay = CLIO::Security::AuthorizationRelay->new(
        broker_client => $client,
        timeout       => 60,
    );

    # Check if relay is available (has broker connection)
    if ($relay->available()) {
        my $approved = $relay->request_authorization(
            category    => 'command_execution',
            description => 'rm -rf /tmp/old-builds',
            risk_level  => 'high',
            flags       => [ { category => 'system_destructive', description => 'Recursive deletion' } ],
            agent_id    => 'agent-1',
        );
    }

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = bless {
        broker_client => $args{broker_client},
        timeout       => $args{timeout} || 60,
    }, $class;
    
    return $self;
}

=head2 available

Returns true if the relay has a broker client and can route requests.

=cut

sub available {
    my ($self) = @_;
    return $self->{broker_client} && $self->{broker_client}->{socket} ? 1 : 0;
}

=head2 request_authorization(%args)

Send an authorization request through the broker and wait for the user's response.

Arguments:
- category: Security category (e.g., 'command_execution', 'script_creation', 'web_fetch')
- description: Human-readable description of what needs approval (the command, path, URL, etc.)
- risk_level: 'standard', 'high', or 'critical'
- flags: Arrayref of flag hashrefs with category and description (same format as CommandAnalyzer)
- agent_id: ID of the requesting agent (optional, derived from broker client if not provided)
- options: Custom options string (optional, defaults to standard y/a/n prompt)

Returns: Hashref with:
- approved: 1 if approved, 0 if denied
- grant_type: 'once', 'session', or 'denied'

=cut

sub request_authorization {
    my ($self, %args) = @_;
    
    unless ($self->available()) {
        log_warning('AuthRelay', "No broker connection - denying authorization request");
        return { approved => 0, grant_type => 'denied', reason => 'no broker connection' };
    }
    
    my $category    = $args{category} || 'unknown';
    my $description = $args{description} || 'unknown operation';
    my $risk_level  = $args{risk_level} || 'standard';
    my $flags       = $args{flags} || [];
    my $agent_id    = $args{agent_id} || $self->{broker_client}->{agent_id} || 'unknown';
    my $options     = $args{options};
    
    # Generate unique request ID for matching response
    my $request_id = "auth-" . time() . "-" . int(rand(10000));
    
    log_info('AuthRelay', "Sending authorization request $request_id: $category - $description (risk: $risk_level)");
    
    # Send authorization request to broker
    my $response = $self->{broker_client}->send_and_wait({
        type        => 'authorization_request',
        request_id  => $request_id,
        agent_id    => $agent_id,
        category    => $category,
        description => $description,
        risk_level  => $risk_level,
        flags       => $flags,
        options     => $options,
    }, $self->{timeout});
    
    unless ($response) {
        log_warning('AuthRelay', "Timeout waiting for authorization response ($self->{timeout}s) - denying");
        return { approved => 0, grant_type => 'denied', reason => 'timeout' };
    }
    
    if ($response->{type} eq 'authorization_response') {
        my $approved   = $response->{approved} ? 1 : 0;
        my $grant_type = $response->{grant_type} || ($approved ? 'once' : 'denied');
        
        log_info('AuthRelay', "Authorization response for $request_id: approved=$approved grant=$grant_type");
        return { approved => $approved, grant_type => $grant_type };
    }
    
    if ($response->{type} eq 'error') {
        log_warning('AuthRelay', "Broker error for authorization request: $response->{message}");
        return { approved => 0, grant_type => 'denied', reason => $response->{message} };
    }
    
    # Unexpected response type
    log_warning('AuthRelay', "Unexpected response type: $response->{type}");
    return { approved => 0, grant_type => 'denied', reason => 'unexpected response' };
}

=head2 request_command_authorization($command, $analysis, $context)

Convenience method for TerminalOperations - formats a command authorization
request matching the existing _prompt_command_confirmation interface.

Returns: 1 if approved, 0 if denied. Also handles session grants.

=cut

sub request_command_authorization {
    my ($self, $command, $analysis, $context) = @_;
    
    my $is_critical = $analysis->{blocked} || ($analysis->{risk_level} eq 'critical');
    
    my $result = $self->request_authorization(
        category    => 'command_execution',
        description => $command,
        risk_level  => $is_critical ? 'critical' : ($analysis->{risk_level} || 'standard'),
        flags       => $analysis->{flags} || [],
    );
    
    return $result;
}

=head2 request_script_authorization($path, $scan_result, $context)

Convenience method for FileOperations - formats a script creation
authorization request.

Returns: Hashref with approved and grant_type.

=cut

sub request_script_authorization {
    my ($self, $path, $scan_result, $context) = @_;
    
    return $self->request_authorization(
        category    => 'script_creation',
        description => $path,
        risk_level  => $scan_result->{risk_level} || 'standard',
        flags       => $scan_result->{flags} || [],
    );
}

=head2 request_url_authorization($url, $security_check, $context)

Convenience method for WebOperations - formats a URL fetch
authorization request.

Returns: Hashref with approved and grant_type.

=cut

sub request_url_authorization {
    my ($self, $url, $security_check, $context) = @_;
    
    return $self->request_authorization(
        category    => 'web_fetch',
        description => $url,
        risk_level  => 'standard',
        flags       => $security_check->{flags} || [],
    );
}

1;
