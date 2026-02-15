package CLIO::UI::Commands::Device;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;
use CLIO::Core::DeviceRegistry;
use Carp qw(croak);

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

=head1 NAME

CLIO::UI::Commands::Device - Device registry management commands

=head1 DESCRIPTION

Provides /device and /group commands for managing remote devices and device groups.

=head1 COMMANDS

    /device                      List all registered devices
    /device add NAME HOST        Add a device (e.g., /device add myserver admin@host)
    /device remove NAME          Remove a device
    /device info NAME            Show device details
    
    /group                       List all device groups
    /group add NAME DEVICES...   Create a group (e.g., /group add servers web1 web2)
    /group remove NAME           Remove a group
    /group addto GROUP DEVICE    Add device to group
    /group removefrom GROUP DEV  Remove device from group

=cut

my $singleton;

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        chat => $args{chat} || croak "chat instance required",
        debug => $args{debug} // 0,
    };
    
    bless $self, $class;
    return $self;
}

sub _get_instance {
    my ($context) = @_;
    
    # If we have a chat object in context, use it
    if ($context && $context->{chat}) {
        return __PACKAGE__->new(chat => $context->{chat});
    }
    
    # Fallback singleton (won't have proper display methods)
    $singleton ||= bless { chat => undef }, __PACKAGE__;
    return $singleton;
}

sub _get_registry {
    return CLIO::Core::DeviceRegistry->new();
}

# Delegate display methods to chat
sub display_command_header { 
    my $self = shift; 
    $self->{chat} ? $self->{chat}->display_command_header(@_) : _fallback_header(@_);
}
sub display_section_header { 
    my $self = shift; 
    $self->{chat} ? $self->{chat}->display_section_header(@_) : _fallback_section(@_);
}
sub display_key_value { 
    my $self = shift; 
    $self->{chat} ? $self->{chat}->display_key_value(@_) : _fallback_kv(@_);
}
sub display_command_row { 
    my $self = shift; 
    $self->{chat} ? $self->{chat}->display_command_row(@_) : _fallback_row(@_);
}
sub display_list_item { 
    my $self = shift; 
    $self->{chat} ? $self->{chat}->display_list_item(@_) : _fallback_item(@_);
}
sub display_system_message { 
    my $self = shift; 
    $self->{chat} ? $self->{chat}->display_system_message(@_) : _fallback_msg(@_);
}
sub display_error_message { 
    my $self = shift; 
    $self->{chat} ? $self->{chat}->display_error_message(@_) : _fallback_err(@_);
}
sub display_success_message { 
    my $self = shift; 
    $self->{chat} ? $self->{chat}->display_success_message(@_) : _fallback_ok(@_);
}
sub writeline { 
    my $self = shift; 
    $self->{chat} ? $self->{chat}->writeline(@_) : print "\n";
}

# Fallback display methods when no chat available (uses unicode box-drawing)
sub _fallback_header { print "\n$_[0]\n" . ("═" x 62) . "\n" }
sub _fallback_section { print "$_[0]\n" . ("─" x 62) . "\n" }
sub _fallback_kv { printf "  %-15s %s\n", "$_[0]:", $_[1] }
sub _fallback_row { printf "  %-25s %s\n", $_[0], $_[1] }
sub _fallback_item { print "  - $_[0]\n" }
sub _fallback_msg { print "$_[0]\n" }
sub _fallback_err { print "ERROR: $_[0]\n" }
sub _fallback_ok { print "[OK] $_[0]\n" }

# ============================================================================
# Class method entry points (called from CommandHandler)
# ============================================================================

sub handle_device_command {
    my ($args, $context) = @_;
    
    my $self = _get_instance($context);
    
    my @parts = split(/\s+/, $args || '');
    my $subcommand = shift @parts || 'list';
    
    if ($subcommand eq 'add') {
        return $self->_device_add(\@parts);
    } elsif ($subcommand eq 'remove' || $subcommand eq 'rm') {
        return $self->_device_remove(\@parts);
    } elsif ($subcommand eq 'info') {
        return $self->_device_info(\@parts);
    } elsif ($subcommand eq 'list' || $subcommand eq 'ls') {
        return $self->_device_list();
    } elsif ($subcommand eq 'help' || $subcommand eq '?') {
        return $self->_device_help();
    } else {
        # Maybe the subcommand is a device name for info
        if (@parts == 0) {
            unshift @parts, $subcommand;
            return $self->_device_info(\@parts);
        }
        return $self->_device_help();
    }
}

sub handle_group_command {
    my ($args, $context) = @_;
    
    my $self = _get_instance($context);
    
    my @parts = split(/\s+/, $args || '');
    my $subcommand = shift @parts || 'list';
    
    if ($subcommand eq 'add' || $subcommand eq 'create') {
        return $self->_group_add(\@parts);
    } elsif ($subcommand eq 'remove' || $subcommand eq 'rm') {
        return $self->_group_remove(\@parts);
    } elsif ($subcommand eq 'addto') {
        return $self->_group_addto(\@parts);
    } elsif ($subcommand eq 'removefrom' || $subcommand eq 'rmfrom') {
        return $self->_group_removefrom(\@parts);
    } elsif ($subcommand eq 'list' || $subcommand eq 'ls') {
        return $self->_group_list();
    } elsif ($subcommand eq 'info') {
        return $self->_group_info(\@parts);
    } elsif ($subcommand eq 'help' || $subcommand eq '?') {
        return $self->_group_help();
    } else {
        # Maybe it's a group name for info
        if (@parts == 0) {
            unshift @parts, $subcommand;
            return $self->_group_info(\@parts);
        }
        return $self->_group_help();
    }
}

# ============================================================================
# Device Subcommands
# ============================================================================

sub _device_add {
    my ($self, $parts) = @_;
    
    my $name = shift @$parts;
    my $host = shift @$parts;
    
    unless ($name && $host) {
        $self->display_error_message("Usage: /device add NAME HOST [--desc DESCRIPTION]");
        return { handled => 1 };
    }
    
    # Parse optional flags
    my %opts;
    while (@$parts) {
        my $flag = shift @$parts;
        if ($flag eq '--desc' || $flag eq '-d') {
            $opts{description} = join(' ', @$parts);
            @$parts = ();
        } elsif ($flag eq '--port' || $flag eq '-p') {
            $opts{ssh_port} = shift @$parts;
        } elsif ($flag eq '--key' || $flag eq '-k') {
            $opts{ssh_key} = shift @$parts;
        } elsif ($flag eq '--model' || $flag eq '-m') {
            $opts{default_model} = shift @$parts;
        }
    }
    
    my $reg = _get_registry();
    my $result = $reg->add_device($name, $host, \%opts);
    
    if ($result->{success}) {
        $self->display_success_message("Device '$name' added: $host");
    } else {
        $self->display_error_message($result->{error});
    }
    
    return { handled => 1 };
}

sub _device_remove {
    my ($self, $parts) = @_;
    
    my $name = shift @$parts;
    
    unless ($name) {
        $self->display_error_message("Usage: /device remove NAME");
        return { handled => 1 };
    }
    
    my $reg = _get_registry();
    my $result = $reg->remove_device($name);
    
    if ($result->{success}) {
        $self->display_success_message("Device '$name' removed");
    } else {
        $self->display_error_message($result->{error});
    }
    
    return { handled => 1 };
}

sub _device_info {
    my ($self, $parts) = @_;
    
    my $name = shift @$parts;
    
    unless ($name) {
        $self->display_error_message("Usage: /device info NAME");
        return { handled => 1 };
    }
    
    my $reg = _get_registry();
    my $device = $reg->get_device($name);
    
    unless ($device) {
        $self->display_error_message("Device '$name' not found");
        return { handled => 1 };
    }
    
    $self->display_command_header("DEVICE: " . uc($name));
    
    $self->display_key_value("Host", $device->{host});
    $self->display_key_value("Description", $device->{description} || '(none)');
    $self->display_key_value("SSH Port", $device->{ssh_port});
    $self->display_key_value("SSH Key", $device->{ssh_key} || '(default)');
    $self->display_key_value("Default Model", $device->{default_model} || '(default)');
    $self->display_key_value("Added", scalar(localtime($device->{added_at})));
    $self->writeline("", markdown => 0);
    
    return { handled => 1 };
}

sub _device_list {
    my ($self) = @_;
    
    my $reg = _get_registry();
    my @devices = $reg->list_devices();
    
    $self->display_command_header("DEVICES");
    
    if (@devices == 0) {
        $self->display_system_message("No devices registered.");
        $self->display_system_message("Use: /device add NAME user\@host");
    } else {
        $self->display_section_header("Registered Devices");
        for my $device (@devices) {
            my $desc = $device->{description} ? " - $device->{description}" : "";
            $self->display_command_row($device->{name}, "$device->{host}$desc", 15);
        }
    }
    $self->writeline("", markdown => 0);
    
    return { handled => 1 };
}

sub _device_help {
    my ($self) = @_;
    
    $self->display_command_header("DEVICE");
    
    $self->display_section_header("COMMANDS");
    $self->display_command_row("/device", "List all devices", 30);
    $self->display_command_row("/device add NAME HOST", "Add a device", 30);
    $self->display_command_row("/device remove NAME", "Remove a device", 30);
    $self->display_command_row("/device info NAME", "Show device details", 30);
    $self->writeline("", markdown => 0);
    
    $self->display_section_header("OPTIONS FOR ADD");
    $self->display_command_row("--desc TEXT", "Description", 20);
    $self->display_command_row("--port NUM", "SSH port (default: 22)", 20);
    $self->display_command_row("--key PATH", "SSH key path", 20);
    $self->display_command_row("--model NAME", "Default AI model", 20);
    $self->writeline("", markdown => 0);
    
    $self->display_section_header("EXAMPLES");
    $self->display_command_row("/device add 2s deck\@2s", "Add device named '2s'", 35);
    $self->display_command_row("/device add server admin\@192.168.1.10 --desc Production", "With description", 35);
    $self->writeline("", markdown => 0);
    
    return { handled => 1 };
}

# ============================================================================
# Group Subcommands
# ============================================================================

sub _group_add {
    my ($self, $parts) = @_;
    
    my $name = shift @$parts;
    my @members = @$parts;
    
    unless ($name && @members) {
        $self->display_error_message("Usage: /group add NAME DEVICE1 DEVICE2 ...");
        return { handled => 1 };
    }
    
    # Check for description flag
    my %opts;
    my @clean_members;
    my $skip_next = 0;
    for my $i (0..$#members) {
        if ($skip_next) {
            $skip_next = 0;
            next;
        }
        if ($members[$i] eq '--desc' || $members[$i] eq '-d') {
            $opts{description} = $members[$i + 1] if defined $members[$i + 1];
            $skip_next = 1;
        } else {
            push @clean_members, $members[$i];
        }
    }
    
    my $reg = _get_registry();
    my $result = $reg->add_group($name, \@clean_members, \%opts);
    
    if ($result->{success}) {
        my $count = scalar @{$result->{members}};
        $self->display_success_message("Group '$name' created with $count member(s)");
    } else {
        $self->display_error_message($result->{error});
    }
    
    return { handled => 1 };
}

sub _group_remove {
    my ($self, $parts) = @_;
    
    my $name = shift @$parts;
    
    unless ($name) {
        $self->display_error_message("Usage: /group remove NAME");
        return { handled => 1 };
    }
    
    my $reg = _get_registry();
    my $result = $reg->remove_group($name);
    
    if ($result->{success}) {
        $self->display_success_message("Group '$name' removed");
    } else {
        $self->display_error_message($result->{error});
    }
    
    return { handled => 1 };
}

sub _group_addto {
    my ($self, $parts) = @_;
    
    my $group = shift @$parts;
    my $device = shift @$parts;
    
    unless ($group && $device) {
        $self->display_error_message("Usage: /group addto GROUP DEVICE");
        return { handled => 1 };
    }
    
    my $reg = _get_registry();
    my $result = $reg->add_to_group($group, $device);
    
    if ($result->{success}) {
        $self->display_success_message("Added '$device' to group '$group'");
    } else {
        $self->display_error_message($result->{error});
    }
    
    return { handled => 1 };
}

sub _group_removefrom {
    my ($self, $parts) = @_;
    
    my $group = shift @$parts;
    my $device = shift @$parts;
    
    unless ($group && $device) {
        $self->display_error_message("Usage: /group removefrom GROUP DEVICE");
        return { handled => 1 };
    }
    
    my $reg = _get_registry();
    my $result = $reg->remove_from_group($group, $device);
    
    if ($result->{success}) {
        $self->display_success_message("Removed '$device' from group '$group'");
    } else {
        $self->display_error_message($result->{error});
    }
    
    return { handled => 1 };
}

sub _group_info {
    my ($self, $parts) = @_;
    
    my $name = shift @$parts;
    
    unless ($name) {
        $self->display_error_message("Usage: /group info NAME");
        return { handled => 1 };
    }
    
    my $reg = _get_registry();
    my $group = $reg->get_group($name);
    
    unless ($group) {
        $self->display_error_message("Group '$name' not found");
        return { handled => 1 };
    }
    
    $self->display_command_header("GROUP: " . uc($name));
    
    $self->display_key_value("Description", $group->{description} || '(none)');
    $self->display_key_value("Members", scalar(@{$group->{members}}));
    $self->display_key_value("Created", scalar(localtime($group->{created_at})));
    $self->writeline("", markdown => 0);
    
    $self->display_section_header("Devices");
    for my $member (@{$group->{members}}) {
        my $device = $reg->get_device($member);
        if ($device) {
            $self->display_command_row($member, $device->{host}, 15);
        } else {
            $self->display_list_item($member);
        }
    }
    $self->writeline("", markdown => 0);
    
    return { handled => 1 };
}

sub _group_list {
    my ($self) = @_;
    
    my $reg = _get_registry();
    my @groups = $reg->list_groups();
    
    $self->display_command_header("GROUPS");
    
    if (@groups == 0) {
        $self->display_system_message("No groups defined.");
        $self->display_system_message("Use: /group add NAME device1 device2 ...");
    } else {
        $self->display_section_header("Device Groups");
        for my $group (@groups) {
            my $count = scalar(@{$group->{members}});
            my $desc = $group->{description} ? " - $group->{description}" : "";
            $self->display_command_row($group->{name}, "$count device(s)$desc", 15);
        }
    }
    $self->writeline("", markdown => 0);
    
    return { handled => 1 };
}

sub _group_help {
    my ($self) = @_;
    
    $self->display_command_header("GROUP");
    
    $self->display_section_header("COMMANDS");
    $self->display_command_row("/group", "List all groups", 35);
    $self->display_command_row("/group add NAME DEV1 DEV2 ...", "Create group", 35);
    $self->display_command_row("/group remove NAME", "Remove group", 35);
    $self->display_command_row("/group info NAME", "Show group details", 35);
    $self->display_command_row("/group addto GROUP DEVICE", "Add device to group", 35);
    $self->display_command_row("/group removefrom GROUP DEVICE", "Remove from group", 35);
    $self->writeline("", markdown => 0);
    
    $self->display_section_header("EXAMPLES");
    $self->display_command_row("/group add servers server1 server2 server3", "Create group", 40);
    $self->display_command_row("/group addto handhelds ally", "Add to existing group", 40);
    $self->writeline("", markdown => 0);
    
    return { handled => 1 };
}

1;

__END__

=head1 AUTHOR

CLIO Team

=cut
