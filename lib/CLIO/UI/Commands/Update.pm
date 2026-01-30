package CLIO::UI::Commands::Update;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Carp qw(croak);
use CLIO::Core::Logger qw(should_log);

=head1 NAME

CLIO::UI::Commands::Update - Update management commands for CLIO

=head1 SYNOPSIS

  use CLIO::UI::Commands::Update;
  
  my $update_cmd = CLIO::UI::Commands::Update->new(
      chat => $chat_instance,
      debug => 0
  );
  
  # Handle /update commands
  $update_cmd->handle_update_command('status');
  $update_cmd->handle_update_command('check');
  $update_cmd->handle_update_command('install');

=head1 DESCRIPTION

Handles update management commands including:
- /update [status] - Show current version and update status
- /update check - Check for available updates
- /update install - Install the latest version
- /update list - List all available versions
- /update switch <version> - Switch to a specific version

Extracted from Chat.pm to improve maintainability.

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        chat => $args{chat} || croak "chat instance required",
        debug => $args{debug} // 0,
    };
    
    bless $self, $class;
    return $self;
}

# Delegate display methods to chat
sub display_command_header { shift->{chat}->display_command_header(@_) }
sub display_info_message { shift->{chat}->display_info_message(@_) }
sub display_success_message { shift->{chat}->display_success_message(@_) }
sub display_error_message { shift->{chat}->display_error_message(@_) }
sub display_list_item { shift->{chat}->display_list_item(@_) }
sub colorize { shift->{chat}->colorize(@_) }

=head2 _get_updater()

Lazy load and return the Update module.

=cut

sub _get_updater {
    my ($self) = @_;
    
    eval {
        require CLIO::Update;
    };
    if ($@) {
        $self->display_error_message("Update module not available: $@");
        return undef;
    }
    
    return CLIO::Update->new(debug => $self->{debug});
}

=head2 handle_update_command(@args)

Main handler for /update commands.

=cut

sub handle_update_command {
    my ($self, @args) = @_;
    
    my $updater = $self->_get_updater();
    return unless $updater;
    
    my $subcmd = @args ? lc($args[0]) : 'status';
    
    if ($subcmd eq 'check') {
        $self->_check_updates($updater);
    }
    elsif ($subcmd eq 'install') {
        $self->_install_update($updater);
    }
    elsif ($subcmd eq 'status' || $subcmd eq '' || $subcmd eq 'help') {
        $self->_show_status($updater);
    }
    elsif ($subcmd eq 'list') {
        $self->_list_versions($updater);
    }
    elsif ($subcmd eq 'switch') {
        $self->_switch_version($updater, $args[1]);
    }
    else {
        $self->display_error_message("Unknown subcommand: $subcmd");
        print "\n";
        print "Available commands:\n";
        $self->display_list_item("/update - Show current version and update help");
        $self->display_list_item("/update status - Show current version and update status");
        $self->display_list_item("/update check - Check for available updates");
        $self->display_list_item("/update list - List all available versions");
        $self->display_list_item("/update install - Install the latest version");
        $self->display_list_item("/update switch <version> - Switch to a specific version");
        print "\n";
    }
}

=head2 _check_updates($updater)

Check for available updates.

=cut

sub _check_updates {
    my ($self, $updater) = @_;
    
    $self->display_command_header("UPDATE CHECK");
    $self->display_info_message("Checking for updates...");
    print "\n";
    
    my $result = $updater->check_for_updates();
    
    if ($result->{error}) {
        $self->display_error_message("Update check failed: $result->{error}");
        return;
    }
    
    my $current = $result->{current_version} || 'unknown';
    my $latest = $result->{latest_version} || 'unknown';
    
    print "Current version: " . $self->colorize($current, 'command_value') . "\n";
    print "Latest version:  " . $self->colorize($latest, 'command_value') . "\n";
    print "\n";
    
    if ($result->{update_available}) {
        $self->display_success_message("Update available: $latest");
        print "\n";
        print "Run " . $self->colorize('/update install', 'command') . " to install\n";
    } else {
        $self->display_success_message("You are running the latest version");
    }
    print "\n";
}

=head2 _install_update($updater)

Install the latest update.

=cut

sub _install_update {
    my ($self, $updater) = @_;
    
    $self->display_command_header("UPDATE INSTALLATION");
    
    my $check_result = $updater->check_for_updates();
    
    if ($check_result->{error}) {
        $self->display_error_message("Cannot check for updates: $check_result->{error}");
        return;
    }
    
    unless ($check_result->{update_available}) {
        $self->display_info_message("You are already running the latest version ($check_result->{current_version})");
        return;
    }
    
    print "Current version: " . $self->colorize($check_result->{current_version}, 'muted') . "\n";
    print "New version:     " . $self->colorize($check_result->{latest_version}, 'command_value') . "\n";
    print "\n";
    
    print "Install update? [y/N]: ";
    my $confirm = <STDIN>;
    chomp $confirm if $confirm;
    
    unless ($confirm && $confirm =~ /^y/i) {
        $self->display_info_message("Update cancelled");
        return;
    }
    
    print "\n";
    $self->display_info_message("Installing update...");
    print "\n";
    
    my $result = $updater->install_latest();
    
    if ($result->{success}) {
        $self->display_success_message("Update installed successfully!");
        print "\n";
        $self->display_info_message("Please restart CLIO to use the new version");
        print "\n";
        print "Run: " . $self->colorize('./clio', 'command') . "\n";
    } else {
        $self->display_error_message("Update installation failed: " . ($result->{error} || 'Unknown error'));
        print "\n";
        if ($result->{rollback}) {
            $self->display_info_message("Previous version restored (rollback successful)");
        }
    }
    print "\n";
}

=head2 _show_status($updater)

Show current update status.

=cut

sub _show_status {
    my ($self, $updater) = @_;
    
    $self->display_command_header("UPDATE STATUS");
    
    my $current = $updater->get_current_version();
    print "Current version: " . $self->colorize($current, 'command_value') . "\n";
    
    my $cache_info = $updater->get_available_update();
    
    if (!$cache_info->{cached}) {
        print "\n";
        $self->display_info_message("No update information cached");
        print "\n";
        print "Run " . $self->colorize('/update check', 'command') . " to check for updates\n";
    }
    elsif ($cache_info->{up_to_date}) {
        print "Latest version:  " . $self->colorize($cache_info->{version}, 'command_value') . "\n";
        print "\n";
        $self->display_success_message("You are running the latest version");
    }
    else {
        print "Latest version:  " . $self->colorize($cache_info->{version}, 'success') . "\n";
        print "\n";
        $self->display_success_message("Update available!");
        print "\n";
        print "Run " . $self->colorize('/update install', 'command') . " to install\n";
    }
    print "\n";
}

=head2 _list_versions($updater)

List all available versions.

=cut

sub _list_versions {
    my ($self, $updater) = @_;
    
    $self->display_command_header("AVAILABLE VERSIONS");
    $self->display_info_message("Fetching releases from GitHub...");
    print "\n";
    
    my $releases = $updater->get_all_releases();
    
    unless ($releases && @$releases) {
        $self->display_error_message("Failed to fetch releases from GitHub");
        return;
    }
    
    my $current = $updater->get_current_version();
    
    print "Current version: " . $self->colorize($current, 'command_value') . "\n\n";
    print "Available versions:\n\n";
    
    my $count = 0;
    for my $release (@$releases) {
        my $version = $release->{version};
        my $date = $release->{published_at} || '';
        $date =~ s/T.*//;
        
        my $marker = '';
        my $version_color = 'command_value';
        if ($version eq $current) {
            $marker = ' (current)';
            $version_color = 'success';
        }
        
        if ($release->{prerelease}) {
            $marker .= ' [pre-release]';
        }
        
        print "  " . $self->colorize($version, $version_color);
        print $self->colorize($marker, 'muted') if $marker;
        print "  " . $self->colorize($date, 'muted') if $date;
        print "\n";
        
        $count++;
        last if $count >= 20;
    }
    
    if (scalar(@$releases) > 20) {
        print "\n  " . $self->colorize("... and " . (scalar(@$releases) - 20) . " more", 'muted') . "\n";
    }
    
    print "\n";
    print "Use " . $self->colorize('/update switch <version>', 'command') . " to switch to a specific version\n";
    print "\n";
}

=head2 _switch_version($updater, $target_version)

Switch to a specific version.

=cut

sub _switch_version {
    my ($self, $updater, $target_version) = @_;
    
    unless ($target_version) {
        $self->display_error_message("Version number required");
        print "\n";
        print "Usage: " . $self->colorize('/update switch <version>', 'command') . "\n";
        print "Example: " . $self->colorize('/update switch 20260125.8', 'command') . "\n";
        print "\n";
        print "Use " . $self->colorize('/update list', 'command') . " to see available versions\n";
        return;
    }
    
    $self->display_command_header("VERSION SWITCH");
    $self->display_info_message("Verifying version $target_version...");
    
    my $release = $updater->get_release_by_version($target_version);
    
    unless ($release) {
        print "\n";
        $self->display_error_message("Version $target_version not found on GitHub");
        print "\n";
        print "Use " . $self->colorize('/update list', 'command') . " to see available versions\n";
        return;
    }
    
    my $current = $updater->get_current_version();
    
    print "\n";
    print "Current version: " . $self->colorize($current, 'muted') . "\n";
    print "Target version:  " . $self->colorize($target_version, 'command_value') . "\n";
    print "\n";
    
    print "Switch to version $target_version? [y/N]: ";
    my $confirm = <STDIN>;
    chomp $confirm if $confirm;
    
    unless ($confirm && $confirm =~ /^y/i) {
        $self->display_info_message("Switch cancelled");
        return;
    }
    
    print "\n";
    $self->display_info_message("Switching to version $target_version...");
    print "\n";
    
    my $result = $updater->switch_to_version($target_version);
    
    if ($result->{success}) {
        $self->display_success_message("Switched to version $target_version!");
        print "\n";
        $self->display_info_message("Please restart CLIO to use the new version");
        print "\n";
    } else {
        $self->display_error_message("Switch failed: " . ($result->{error} || 'Unknown error'));
    }
    print "\n";
}

1;

__END__

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

Same as CLIO.

=cut
