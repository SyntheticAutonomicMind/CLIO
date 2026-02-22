package CLIO::Security::Authz;

use strict;
use warnings;
use CLIO::Util::JSON qw(encode_json decode_json);

=head1 NAME

CLIO::Security::Authz - Authorization system for CLIO

=head1 SYNOPSIS

    use CLIO::Security::Authz;
    
    my $authz = CLIO::Security::Authz->new(debug => 1);
    $authz->define_role('admin', ['read', 'write', 'delete']);
    $authz->assign_role('user123', 'admin');
    my $allowed = $authz->check_permission('user123', 'read', '/api/data');

=head1 DESCRIPTION

This module provides role-based access control (RBAC) and permission management
for CLIO, including resource-level access control and policy enforcement.

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        debug => $args{debug} || 0,
        roles => {},
        user_roles => {},
        permissions => {},
        policies => {},
        audit_log => []
    };
    
    bless $self, $class;
    
    # Initialize default roles and permissions
    $self->_initialize_defaults();
    
    return $self;
}

=head2 define_role($role_name, $permissions)

Define a role with a set of permissions.

=cut

sub define_role {
    my ($self, $role_name, $permissions) = @_;
    
    unless ($role_name && ref($permissions) eq 'ARRAY') {
        $self->_log("Invalid role definition: $role_name");
        return 0;
    }
    
    $self->{roles}->{$role_name} = {
        permissions => [@$permissions],
        created => time(),
        description => "Role: $role_name"
    };
    
    $self->_audit('role_defined', 'system', "$role_name with " . scalar(@$permissions) . " permissions");
    $self->_log("Role defined: $role_name with permissions: " . join(', ', @$permissions));
    
    return 1;
}

=head2 assign_role($user_id, $role_name)

Assign a role to a user.

=cut

sub assign_role {
    my ($self, $user_id, $role_name) = @_;
    
    unless ($user_id && $role_name) {
        $self->_log("Invalid role assignment parameters");
        return 0;
    }
    
    unless (exists $self->{roles}->{$role_name}) {
        $self->_log("Role does not exist: $role_name");
        return 0;
    }
    
    $self->{user_roles}->{$user_id} ||= [];
    
    # Don't add duplicate roles
    unless (grep { $_ eq $role_name } @{$self->{user_roles}->{$user_id}}) {
        push @{$self->{user_roles}->{$user_id}}, $role_name;
        $self->_audit('role_assigned', $user_id, $role_name);
        $self->_log("Role $role_name assigned to user: $user_id");
    }
    
    return 1;
}

=head2 revoke_role($user_id, $role_name)

Revoke a role from a user.

=cut

sub revoke_role {
    my ($self, $user_id, $role_name) = @_;
    
    return 0 unless $user_id && $role_name;
    return 0 unless $self->{user_roles}->{$user_id};
    
    my $roles = $self->{user_roles}->{$user_id};
    @$roles = grep { $_ ne $role_name } @$roles;
    
    $self->_audit('role_revoked', $user_id, $role_name);
    $self->_log("Role $role_name revoked from user: $user_id");
    
    return 1;
}

=head2 check_permission($user_id, $permission, $resource)

Check if a user has permission to perform an action on a resource.

=cut

sub check_permission {
    my ($self, $user_id, $permission, $resource) = @_;
    
    $resource ||= '*';
    
    $self->_log("Checking permission: $user_id -> $permission on $resource");
    
    # Get user's roles
    my $user_roles = $self->{user_roles}->{$user_id} || [];
    
    # Check each role for the permission
    for my $role_name (@$user_roles) {
        my $role = $self->{roles}->{$role_name};
        next unless $role;
        
        my $permissions = $role->{permissions};
        
        # Check for exact permission match
        if (grep { $_ eq $permission || $_ eq '*' } @$permissions) {
            
            # Check resource-specific policies
            if ($self->_check_resource_policy($user_id, $permission, $resource)) {
                $self->_audit('permission_granted', $user_id, "$permission on $resource via $role_name");
                $self->_log("Permission granted: $user_id -> $permission on $resource");
                return 1;
            }
        }
    }
    
    $self->_audit('permission_denied', $user_id, "$permission on $resource");
    $self->_log("Permission denied: $user_id -> $permission on $resource");
    return 0;
}

=head2 define_policy($name, $conditions)

Define a security policy.

=cut

sub define_policy {
    my ($self, $name, $conditions) = @_;
    
    unless ($name && ref($conditions) eq 'HASH') {
        $self->_log("Invalid policy definition: $name");
        return 0;
    }
    
    $self->{policies}->{$name} = {
        conditions => $conditions,
        created => time(),
        active => 1
    };
    
    $self->_audit('policy_defined', 'system', $name);
    $self->_log("Policy defined: $name");
    
    return 1;
}

=head2 get_user_roles($user_id)

Get all roles assigned to a user.

=cut

sub get_user_roles {
    my ($self, $user_id) = @_;
    
    return $self->{user_roles}->{$user_id} || [];
}

=head2 get_user_permissions($user_id)

Get all permissions for a user based on their roles.

=cut

sub get_user_permissions {
    my ($self, $user_id) = @_;
    
    my $user_roles = $self->{user_roles}->{$user_id} || [];
    my %permissions;
    
    for my $role_name (@$user_roles) {
        my $role = $self->{roles}->{$role_name};
        next unless $role;
        
        for my $perm (@{$role->{permissions}}) {
            $permissions{$perm} = 1;
        }
    }
    
    return [keys %permissions];
}

=head2 list_roles()

Get all defined roles.

=cut

sub list_roles {
    my ($self) = @_;
    
    my @roles;
    for my $name (keys %{$self->{roles}}) {
        my $role = $self->{roles}->{$name};
        push @roles, {
            name => $name,
            permissions => $role->{permissions},
            created => $role->{created},
            description => $role->{description}
        };
    }
    
    return \@roles;
}

=head2 get_statistics()

Get authorization statistics.

=cut

sub get_statistics {
    my ($self) = @_;
    
    my $total_permissions = 0;
    for my $role (values %{$self->{roles}}) {
        $total_permissions += scalar(@{$role->{permissions}});
    }
    
    return {
        total_roles => scalar(keys %{$self->{roles}}),
        total_users => scalar(keys %{$self->{user_roles}}),
        total_permissions => $total_permissions,
        total_policies => scalar(keys %{$self->{policies}}),
        audit_entries => scalar(@{$self->{audit_log}})
    };
}

=head2 get_audit_log()

Get the audit log.

=cut

sub get_audit_log {
    my ($self) = @_;
    
    return $self->{audit_log};
}

=head2 export_config()

Export the current authorization configuration.

=cut

sub export_config {
    my ($self) = @_;
    
    return {
        roles => $self->{roles},
        user_roles => $self->{user_roles},
        policies => $self->{policies}
    };
}

=head2 import_config($config)

Import authorization configuration.

=cut

sub import_config {
    my ($self, $config) = @_;
    
    return 0 unless ref($config) eq 'HASH';
    
    if ($config->{roles}) {
        $self->{roles} = $config->{roles};
    }
    
    if ($config->{user_roles}) {
        $self->{user_roles} = $config->{user_roles};
    }
    
    if ($config->{policies}) {
        $self->{policies} = $config->{policies};
    }
    
    $self->_audit('config_imported', 'system', 'authorization config imported');
    $self->_log("Authorization configuration imported");
    
    return 1;
}

# Private methods

sub _initialize_defaults {
    my ($self) = @_;
    
    # Define default roles
    $self->define_role('admin', ['*']);
    $self->define_role('user', ['read', 'write']);
    $self->define_role('guest', ['read']);
    
    # Define default policies
    $self->define_policy('default_access', {
        allow_all => 0,
        require_auth => 1,
        resource_restrictions => {}
    });
}

sub _check_resource_policy {
    my ($self, $user_id, $permission, $resource) = @_;
    
    # Simplified policy checking - in real implementation would be more complex
    
    # For now, allow all access if user has the basic permission
    # More sophisticated resource-level policies would be implemented here
    
    return 1;
}

sub _audit {
    my ($self, $action, $user_id, $details) = @_;
    
    push @{$self->{audit_log}}, {
        timestamp => time(),
        action => $action,
        user_id => $user_id,
        details => $details
    };
}

sub _log {
    my ($self, $message) = @_;
    
    return unless $self->{debug};
    
    warn "[DEBUG Authz] $message\n";
}

1;

__END__

=head1 AUTHOR

Fewtarius

=head1 COPYRIGHT

Copyright (c) 2025 CLIO Project. All rights reserved.

=cut

1;
