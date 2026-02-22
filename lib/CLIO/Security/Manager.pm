package CLIO::Security::Manager;

use strict;
use warnings;
use utf8;
use CLIO::Security::Auth;
use CLIO::Security::Authz;

=head1 NAME

CLIO::Security::Manager - Central security management for CLIO

=head1 SYNOPSIS

    use CLIO::Security::Manager;
    
    my $security = CLIO::Security::Manager->new(debug => 1);
    my $token = $security->authenticate('user123', 'password');
    my $allowed = $security->authorize($token, 'read', '/api/data');

=head1 DESCRIPTION

This module provides a unified interface for security operations in CLIO,
coordinating authentication, authorization, input validation, and audit logging.

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        debug => $args{debug} || 0,
        auth => CLIO::Security::Auth->new(debug => $args{debug}),
        authz => CLIO::Security::Authz->new(debug => $args{debug}),
        input_filters => [],
        output_filters => [],
        security_policies => {},
        audit_log => []
    };
    
    bless $self, $class;
    
    $self->_initialize_security_policies();
    
    return $self;
}

=head2 authenticate($user_id, $credentials)

Authenticate a user and return a token.

=cut

sub authenticate {
    my ($self, $user_id, $credentials) = @_;
    
    # Input validation
    unless ($self->_validate_input($user_id) && $self->_validate_input($credentials)) {
        $self->_log("Authentication failed: invalid input");
        return undef;
    }
    
    # Perform authentication
    my $token = $self->{auth}->authenticate($user_id, $credentials);
    
    if ($token) {
        # Assign default 'user' role if user doesn't have any roles
        my $user_roles = $self->{authz}->get_user_roles($user_id);
        if (!@$user_roles) {
            $self->{authz}->assign_role($user_id, 'user');
        }
        
        $self->_audit('user_authenticated', $user_id, 'successful_login');
    }
    
    return $token;
}

=head2 authorize($token, $permission, $resource)

Check if a token holder is authorized for an action.

=cut

sub authorize {
    my ($self, $token, $permission, $resource) = @_;
    
    # Validate token first
    my $token_data = $self->{auth}->validate_token($token);
    return 0 unless $token_data;
    
    my $user_id = $token_data->{user_id};
    
    # Check authorization
    return $self->{authz}->check_permission($user_id, $permission, $resource);
}

=head2 logout($token)

Logout a user by invalidating their token.

=cut

sub logout {
    my ($self, $token) = @_;
    
    my $token_data = $self->{auth}->validate_token($token);
    if ($token_data) {
        my $user_id = $token_data->{user_id};
        $self->_audit('user_logout', $user_id, 'session_ended');
    }
    
    return $self->{auth}->logout($token);
}

=head2 get_user_info($token)

Get information about the token holder.

=cut

sub get_user_info {
    my ($self, $token) = @_;
    
    my $token_data = $self->{auth}->validate_token($token);
    return undef unless $token_data;
    
    my $user_id = $token_data->{user_id};
    my $roles = $self->{authz}->get_user_roles($user_id);
    my $permissions = $self->{authz}->get_user_permissions($user_id);
    
    return {
        user_id => $user_id,
        roles => $roles,
        permissions => $permissions,
        token_created => $token_data->{created},
        token_expires => $token_data->{expires},
        last_used => $token_data->{last_used}
    };
}

=head2 validate_input($input)

Validate and sanitize input data.

=cut

sub validate_input {
    my ($self, $input) = @_;
    
    return 0 unless defined $input;
    
    # Apply input filters
    for my $filter (@{$self->{input_filters}}) {
        $input = $filter->($input);
        return 0 unless defined $input;
    }
    
    return $self->_validate_input($input);
}

=head2 sanitize_output($output)

Sanitize output data for safe display.

=cut

sub sanitize_output {
    my ($self, $output) = @_;
    
    return '' unless defined $output;
    
    # Apply output filters
    for my $filter (@{$self->{output_filters}}) {
        $output = $filter->($output);
    }
    
    return $output;
}

=head2 add_input_filter($filter_code)

Add an input validation filter.

=cut

sub add_input_filter {
    my ($self, $filter_code) = @_;
    
    return 0 unless ref($filter_code) eq 'CODE';
    
    push @{$self->{input_filters}}, $filter_code;
    $self->_log("Input filter added");
    
    return 1;
}

=head2 add_output_filter($filter_code)

Add an output sanitization filter.

=cut

sub add_output_filter {
    my ($self, $filter_code) = @_;
    
    return 0 unless ref($filter_code) eq 'CODE';
    
    push @{$self->{output_filters}}, $filter_code;
    $self->_log("Output filter added");
    
    return 1;
}

=head2 define_security_policy($name, $policy)

Define a security policy.

=cut

sub define_security_policy {
    my ($self, $name, $policy) = @_;
    
    return 0 unless $name && ref($policy) eq 'HASH';
    
    $self->{security_policies}->{$name} = $policy;
    $self->_audit('policy_defined', 'system', $name);
    $self->_log("Security policy defined: $name");
    
    return 1;
}

=head2 enforce_policy($policy_name, $context)

Enforce a security policy in a given context.

=cut

sub enforce_policy {
    my ($self, $policy_name, $context) = @_;
    
    my $policy = $self->{security_policies}->{$policy_name};
    return 1 unless $policy; # If no policy, allow by default
    
    # Apply policy rules based on context
    if ($policy->{require_auth} && !$context->{authenticated}) {
        $self->_log("Policy violation: authentication required");
        return 0;
    }
    
    if ($policy->{max_request_size} && $context->{request_size} > $policy->{max_request_size}) {
        $self->_log("Policy violation: request too large");
        return 0;
    }
    
    if ($policy->{allowed_ips} && !grep { $_ eq $context->{client_ip} } @{$policy->{allowed_ips}}) {
        $self->_log("Policy violation: IP not allowed");
        return 0;
    }
    
    return 1;
}

=head2 get_security_status()

Get current security system status.

=cut

sub get_security_status {
    my ($self) = @_;
    
    my $auth_stats = $self->{auth}->get_statistics();
    my $authz_stats = $self->{authz}->get_statistics();
    
    return {
        authentication => $auth_stats,
        authorization => $authz_stats,
        input_filters => scalar(@{$self->{input_filters}}),
        output_filters => scalar(@{$self->{output_filters}}),
        security_policies => scalar(keys %{$self->{security_policies}}),
        audit_entries => scalar(@{$self->{audit_log}})
    };
}

=head2 get_audit_trail($limit)

Get security audit trail.

=cut

sub get_audit_trail {
    my ($self, $limit) = @_;
    
    my @auth_log = @{$self->{auth}->get_audit_log()};
    my @authz_log = @{$self->{authz}->get_audit_log()};
    my @security_log = @{$self->{audit_log}};
    
    # Combine and sort by timestamp
    my @combined = sort { $b->{timestamp} <=> $a->{timestamp} } (@auth_log, @authz_log, @security_log);
    
    if ($limit && $limit > 0) {
        @combined = splice(@combined, 0, $limit);
    }
    
    return \@combined;
}

=head2 cleanup()

Perform security system cleanup.

=cut

sub cleanup {
    my ($self) = @_;
    
    # Cleanup expired tokens
    my $cleaned_tokens = $self->{auth}->cleanup_expired_tokens();
    
    # Cleanup old audit logs (keep last 1000 entries)
    if (@{$self->{audit_log}} > 1000) {
        splice(@{$self->{audit_log}}, 0, -1000);
    }
    
    $self->_log("Security cleanup completed: $cleaned_tokens tokens cleaned");
    return $cleaned_tokens;
}

# Private methods

sub _initialize_security_policies {
    my ($self) = @_;
    
    # Default security policies
    $self->define_security_policy('strict', {
        require_auth => 1,
        max_request_size => 1024 * 1024, # 1MB
        allowed_methods => ['GET', 'POST'],
        rate_limit => 100 # requests per minute
    });
    
    $self->define_security_policy('permissive', {
        require_auth => 0,
        max_request_size => 10 * 1024 * 1024, # 10MB
        allowed_methods => ['GET', 'POST', 'PUT', 'DELETE'],
        rate_limit => 1000
    });
}

sub _validate_input {
    my ($self, $input) = @_;
    
    return 0 unless defined $input;
    
    # Basic validation rules
    # Check for null bytes
    return 0 if $input =~ /\0/;
    
    # Check for script injection patterns
    return 0 if $input =~ /<script\b/i;
    
    # Check for SQL injection patterns
    return 0 if $input =~ /('|(\\)|;|--|\/\*|\*\/)/;
    
    # Check length (max 10KB for input)
    return 0 if length($input) > 10240;
    
    return 1;
}

sub _audit {
    my ($self, $action, $user_id, $details) = @_;
    
    push @{$self->{audit_log}}, {
        timestamp => time(),
        action => $action,
        user_id => $user_id,
        details => $details,
        component => 'security_manager'
    };
}

sub _log {
    my ($self, $message) = @_;
    
    return unless $self->{debug};
    
    warn "[DEBUG Security] $message\n";
}

1;

__END__

=head1 AUTHOR

Fewtarius

=head1 COPYRIGHT

Copyright (c) 2025 CLIO Project. All rights reserved.

=cut

1;
