package CLIO::Core::DeviceRegistry;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;
use Carp qw(croak);
use CLIO::Util::JSON qw(encode_json decode_json);
use File::Spec;
use File::Path qw(make_path);

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

=head1 NAME

CLIO::Core::DeviceRegistry - Manage named devices and device groups for remote execution

=head1 DESCRIPTION

Provides a registry of named devices (SSH targets) and device groups for easy
remote execution. Devices can be referenced by friendly names instead of
full user@host strings.

=head1 SYNOPSIS

    use CLIO::Core::DeviceRegistry;
    
    my $registry = CLIO::Core::DeviceRegistry->new();
    
    # Add a device
    $registry->add_device('laptop', 'user@laptop', { description => 'Development laptop' });
    
    # Create a group
    $registry->add_group('servers', ['server1', 'server2', 'server3']);
    
    # Resolve device(s)
    my @hosts = $registry->resolve('servers');  # Returns all hosts in group
    my $host = $registry->resolve('laptop');    # Returns single host

=cut

sub new {
    my ($class, %opts) = @_;
    
    my $self = bless {
        config_dir => $opts{config_dir} || _default_config_dir(),
        devices => {},
        groups => {},
    }, $class;
    
    $self->_load_registry();
    
    return $self;
}

sub _default_config_dir {
    # Use project-local .clio if it exists, otherwise global
    if (-d '.clio') {
        return '.clio';
    }
    return File::Spec->catdir($ENV{HOME}, '.clio');
}

sub _registry_file {
    my ($self) = @_;
    return File::Spec->catfile($self->{config_dir}, 'devices.json');
}

sub _load_registry {
    my ($self) = @_;
    
    my $file = $self->_registry_file();
    return unless -f $file;
    
    eval {
        open my $fh, '<:encoding(UTF-8)', $file or die "Cannot open $file: $!";
        my $content = do { local $/; <$fh> };
        close $fh;
        
        my $data = decode_json($content);
        $self->{devices} = $data->{devices} || {};
        $self->{groups} = $data->{groups} || {};
    };
    if ($@) {
        warn "[WARN][DeviceRegistry] Failed to load registry: $@\n";
    }
}

sub _save_registry {
    my ($self) = @_;
    
    my $file = $self->_registry_file();
    my $dir = File::Spec->catdir($self->{config_dir});
    
    make_path($dir) unless -d $dir;
    
    eval {
        my $data = {
            devices => $self->{devices},
            groups => $self->{groups},
            updated_at => time(),
        };
        
        open my $fh, '>:encoding(UTF-8)', $file or croak "Cannot write $file: $!";
        print $fh encode_json($data);
        close $fh;
    };
    if ($@) {
        warn "[WARN][DeviceRegistry] Failed to save registry: $@\n";
        return 0;
    }
    return 1;
}

=head2 add_device

Add a device to the registry.

    $registry->add_device('myserver', 'admin@192.168.1.10', {
        description => 'Home server',
        ssh_port => 22,
        ssh_key => '/path/to/key',
        default_model => 'gpt-4.1',
    });

=cut

sub add_device {
    my ($self, $name, $host, $opts) = @_;
    
    unless ($name && $host) {
        return { success => 0, error => "Device name and host are required" };
    }
    
    # Validate name (alphanumeric, dash, underscore)
    unless ($name =~ /^[a-zA-Z0-9_-]+$/) {
        return { success => 0, error => "Device name must be alphanumeric (with - and _ allowed)" };
    }
    
    $self->{devices}{$name} = {
        host => $host,
        description => $opts->{description} || '',
        ssh_port => $opts->{ssh_port} || 22,
        ssh_key => $opts->{ssh_key} || '',
        default_model => $opts->{default_model} || '',
        added_at => time(),
    };
    
    $self->_save_registry();
    
    return { success => 1, device => $name, host => $host };
}

=head2 remove_device

Remove a device from the registry.

    $registry->remove_device('myserver');

=cut

sub remove_device {
    my ($self, $name) = @_;
    
    unless (exists $self->{devices}{$name}) {
        return { success => 0, error => "Device '$name' not found" };
    }
    
    delete $self->{devices}{$name};
    
    # Also remove from any groups
    for my $group (keys %{$self->{groups}}) {
        $self->{groups}{$group}{members} = [
            grep { $_ ne $name } @{$self->{groups}{$group}{members}}
        ];
    }
    
    $self->_save_registry();
    
    return { success => 1, removed => $name };
}

=head2 get_device

Get device information.

    my $device = $registry->get_device('myserver');
    # Returns: { host => 'admin@192.168.1.10', description => '...', ... }

=cut

sub get_device {
    my ($self, $name) = @_;
    return $self->{devices}{$name};
}

=head2 list_devices

List all registered devices.

    my @devices = $registry->list_devices();
    # Returns array of { name => '...', host => '...', ... }

=cut

sub list_devices {
    my ($self) = @_;
    
    my @devices;
    for my $name (sort keys %{$self->{devices}}) {
        push @devices, {
            name => $name,
            %{$self->{devices}{$name}},
        };
    }
    return @devices;
}

=head2 add_group

Create a device group.

    $registry->add_group('servers', ['web1', 'web2', 'db1'], {
        description => 'Production servers',
    });

=cut

sub add_group {
    my ($self, $name, $members, $opts) = @_;
    
    unless ($name && ref($members) eq 'ARRAY') {
        return { success => 0, error => "Group name and member array required" };
    }
    
    # Validate name
    unless ($name =~ /^[a-zA-Z0-9_-]+$/) {
        return { success => 0, error => "Group name must be alphanumeric (with - and _ allowed)" };
    }
    
    # Validate all members exist (or are valid host strings)
    my @valid_members;
    for my $member (@$members) {
        if (exists $self->{devices}{$member}) {
            push @valid_members, $member;
        } elsif ($member =~ /@/) {
            # Looks like a direct host string - add as anonymous device
            push @valid_members, $member;
        } else {
            return { success => 0, error => "Member '$member' is not a registered device or valid host" };
        }
    }
    
    $self->{groups}{$name} = {
        members => \@valid_members,
        description => $opts->{description} || '',
        created_at => time(),
    };
    
    $self->_save_registry();
    
    return { success => 1, group => $name, members => \@valid_members };
}

=head2 remove_group

Remove a device group.

    $registry->remove_group('servers');

=cut

sub remove_group {
    my ($self, $name) = @_;
    
    unless (exists $self->{groups}{$name}) {
        return { success => 0, error => "Group '$name' not found" };
    }
    
    delete $self->{groups}{$name};
    $self->_save_registry();
    
    return { success => 1, removed => $name };
}

=head2 get_group

Get group information.

    my $group = $registry->get_group('servers');

=cut

sub get_group {
    my ($self, $name) = @_;
    return $self->{groups}{$name};
}

=head2 list_groups

List all device groups.

    my @groups = $registry->list_groups();

=cut

sub list_groups {
    my ($self) = @_;
    
    my @groups;
    for my $name (sort keys %{$self->{groups}}) {
        push @groups, {
            name => $name,
            %{$self->{groups}{$name}},
        };
    }
    return @groups;
}

=head2 resolve

Resolve a name to one or more SSH hosts.

    # Single device
    my @hosts = $registry->resolve('myserver');
    # Returns: ('admin@192.168.1.10')
    
    # Group
    my @hosts = $registry->resolve('servers');
    # Returns: ('admin@web1', 'admin@web2', 'admin@db1')
    
    # Special: 'all'
    my @hosts = $registry->resolve('all');
    # Returns all registered devices

=cut

sub resolve {
    my ($self, $name) = @_;
    
    return () unless $name;
    
    # Special case: 'all' returns all devices
    if (lc($name) eq 'all') {
        return map { $self->{devices}{$_}{host} } sort keys %{$self->{devices}};
    }
    
    # Check if it's a group
    if (exists $self->{groups}{$name}) {
        my @hosts;
        for my $member (@{$self->{groups}{$name}{members}}) {
            if (exists $self->{devices}{$member}) {
                push @hosts, $self->{devices}{$member}{host};
            } else {
                # Direct host string
                push @hosts, $member;
            }
        }
        return @hosts;
    }
    
    # Check if it's a device
    if (exists $self->{devices}{$name}) {
        return ($self->{devices}{$name}{host});
    }
    
    # Maybe it's a direct host string
    if ($name =~ /@/) {
        return ($name);
    }
    
    return ();
}

=head2 resolve_with_info

Resolve a name and return detailed info for each host.

    my @devices = $registry->resolve_with_info('servers');
    # Returns: (
    #   { name => 'web1', host => 'admin@web1', ... },
    #   { name => 'web2', host => 'admin@web2', ... },
    # )

=cut

sub resolve_with_info {
    my ($self, $name) = @_;
    
    return () unless $name;
    
    my @result;
    
    # Special case: 'all'
    if (lc($name) eq 'all') {
        for my $device_name (sort keys %{$self->{devices}}) {
            push @result, {
                name => $device_name,
                %{$self->{devices}{$device_name}},
            };
        }
        return @result;
    }
    
    # Check if it's a group
    if (exists $self->{groups}{$name}) {
        for my $member (@{$self->{groups}{$name}{members}}) {
            if (exists $self->{devices}{$member}) {
                push @result, {
                    name => $member,
                    %{$self->{devices}{$member}},
                };
            } else {
                # Direct host string
                push @result, {
                    name => $member,
                    host => $member,
                };
            }
        }
        return @result;
    }
    
    # Check if it's a device
    if (exists $self->{devices}{$name}) {
        return ({
            name => $name,
            %{$self->{devices}{$name}},
        });
    }
    
    # Direct host string
    if ($name =~ /@/) {
        return ({
            name => $name,
            host => $name,
        });
    }
    
    return ();
}

=head2 add_to_group

Add a device to an existing group.

    $registry->add_to_group('servers', 'newserver');

=cut

sub add_to_group {
    my ($self, $group_name, $device_name) = @_;
    
    unless (exists $self->{groups}{$group_name}) {
        return { success => 0, error => "Group '$group_name' not found" };
    }
    
    # Validate device exists or is valid host
    unless (exists $self->{devices}{$device_name} || $device_name =~ /@/) {
        return { success => 0, error => "Device '$device_name' is not registered and not a valid host" };
    }
    
    # Check if already in group
    if (grep { $_ eq $device_name } @{$self->{groups}{$group_name}{members}}) {
        return { success => 0, error => "Device '$device_name' is already in group '$group_name'" };
    }
    
    push @{$self->{groups}{$group_name}{members}}, $device_name;
    $self->_save_registry();
    
    return { success => 1, group => $group_name, added => $device_name };
}

=head2 remove_from_group

Remove a device from a group.

    $registry->remove_from_group('servers', 'oldserver');

=cut

sub remove_from_group {
    my ($self, $group_name, $device_name) = @_;
    
    unless (exists $self->{groups}{$group_name}) {
        return { success => 0, error => "Group '$group_name' not found" };
    }
    
    my @new_members = grep { $_ ne $device_name } @{$self->{groups}{$group_name}{members}};
    
    if (scalar @new_members == scalar @{$self->{groups}{$group_name}{members}}) {
        return { success => 0, error => "Device '$device_name' not in group '$group_name'" };
    }
    
    $self->{groups}{$group_name}{members} = \@new_members;
    $self->_save_registry();
    
    return { success => 1, group => $group_name, removed => $device_name };
}

1;

__END__

=head1 STORAGE FORMAT

Devices and groups are stored in ~/.clio/devices.json (or .clio/devices.json for project-local):

    {
        "devices": {
            "myserver": {
                "host": "admin@192.168.1.10",
                "description": "Home server",
                "ssh_port": 22,
                "ssh_key": "",
                "default_model": "gpt-4.1",
                "added_at": 1706800000
            }
        },
        "groups": {
            "servers": {
                "members": ["myserver", "webserver"],
                "description": "All servers",
                "created_at": 1706800000
            }
        },
        "updated_at": 1706800000
    }

=head1 AUTHOR

CLIO Team

=cut
