package CLIO::Update;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use File::Spec;
use File::Basename qw(dirname);
use File::Path qw(mkpath rmtree);
use JSON::PP qw(decode_json);
use CLIO::Core::Logger qw(should_log);

=head1 NAME

CLIO::Update - Update checking and installation management

=head1 DESCRIPTION

Handles checking for CLIO updates from GitHub releases and installing them.

Features:
- Non-blocking background update checks
- Cached update status to avoid API rate limits
- Auto-detection of installation method (system vs user)
- Safe update installation with verification
- Rollback support in case of failure

=head1 SYNOPSIS

    use CLIO::Update;
    
    my $updater = CLIO::Update->new(debug => 1);
    
    # Check for updates (non-blocking)
    $updater->check_for_updates_async();
    
    # Get update status
    if (my $version = $updater->get_available_update()) {
        print "Update available: $version\n";
    }
    
    # Install update
    my $result = $updater->install_latest();

=cut

sub new {
    my ($class, %opts) = @_;
    
    my $self = {
        debug => $opts{debug} || 0,
        github_repo => 'SyntheticAutonomicMind/CLIO',
        api_base => 'https://api.github.com',
        cache_dir => '.clio',
        cache_duration => 43200,  # 12 hours in seconds
        timeout => 10,  # HTTP request timeout
    };
    
    bless $self, $class;
    return $self;
}

=head2 get_current_version

Get the currently installed CLIO version.

Returns:
- Version string (e.g., "20260122.2") or "unknown"

=cut

sub get_current_version {
    my ($self) = @_;
    
    # Priority 1: lib/CLIO.pm version (always available when installed)
    my $version;
    eval {
        require CLIO;
        $version = $CLIO::VERSION;
    };
    return $version if $version && $version ne 'unknown';
    
    # Priority 2: VERSION file in current directory (development mode)
    if (-f 'VERSION') {
        open my $fh, '<', 'VERSION' or return 'unknown';
        my $file_version = <$fh>;
        close $fh;
        chomp $file_version if $file_version;
        return $file_version if $file_version;
    }
    
    # Priority 3: Git tag (if in repo)
    my $git_version = `git describe --tags --abbrev=0 2>/dev/null`;
    if ($? == 0 && $git_version) {
        chomp $git_version;
        $git_version =~ s/^v//;  # Remove leading 'v' if present
        return $git_version;
    }
    
    return 'unknown';
}

=head2 get_latest_version

Fetch latest version from GitHub releases API.

Returns:
- Hashref with {version, tag_name, tarball_url, published_at} or undef on failure

=cut

sub get_latest_version {
    my ($self) = @_;
    
    my $api_url = sprintf("%s/repos/%s/releases/latest",
        $self->{api_base},
        $self->{github_repo}
    );
    
    print STDERR "[DEBUG][Update] Fetching latest release from: $api_url\n"
        if $self->{debug};
    
    # Use curl for HTTP request (more reliable than LWP)
    my $response = `curl -s -m $self->{timeout} -H "Accept: application/vnd.github+json" "$api_url" 2>/dev/null`;
    
    if ($? != 0) {
        print STDERR "[DEBUG][Update] curl failed with exit code: " . ($? >> 8) . "\n"
            if $self->{debug};
        return undef;
    }
    
    # Parse JSON response
    my $data;
    eval {
        $data = decode_json($response);
    };
    
    if ($@ || !$data) {
        print STDERR "[DEBUG][Update] Failed to parse JSON response: $@\n"
            if $self->{debug};
        return undef;
    }
    
    # Extract version info
    my $tag_name = $data->{tag_name} || '';
    my $version = $tag_name;
    $version =~ s/^v//;  # Remove leading 'v'
    
    my $tarball_url = $data->{tarball_url} || '';
    my $published_at = $data->{published_at} || '';
    
    return {
        version => $version,
        tag_name => $tag_name,
        tarball_url => $tarball_url,
        published_at => $published_at,
        release_name => $data->{name} || '',
        release_notes => $data->{body} || '',
    };
}

=head2 get_all_releases

Fetch all available releases from GitHub.

Arguments:
- $per_page: Number of releases per page (default: 30)
- $page: Page number (default: 1)

Returns:
- Arrayref of release hashrefs, each with {version, tag_name, tarball_url, published_at, release_name}
- undef on failure

=cut

sub get_all_releases {
    my ($self, %opts) = @_;
    
    my $per_page = $opts{per_page} || 30;
    my $page = $opts{page} || 1;
    
    my $api_url = sprintf("%s/repos/%s/releases?per_page=%d&page=%d",
        $self->{api_base},
        $self->{github_repo},
        $per_page,
        $page
    );
    
    print STDERR "[DEBUG][Update] Fetching releases from: $api_url\n"
        if $self->{debug};
    
    # Use curl for HTTP request
    my $response = `curl -s -m $self->{timeout} -H "Accept: application/vnd.github+json" "$api_url" 2>/dev/null`;
    
    if ($? != 0) {
        print STDERR "[DEBUG][Update] curl failed with exit code: " . ($? >> 8) . "\n"
            if $self->{debug};
        return undef;
    }
    
    # Parse JSON response
    my $data;
    eval {
        $data = decode_json($response);
    };
    
    if ($@ || !$data || ref($data) ne 'ARRAY') {
        print STDERR "[DEBUG][Update] Failed to parse JSON response: $@\n"
            if $self->{debug};
        return undef;
    }
    
    # Transform each release
    my @releases;
    for my $release (@$data) {
        my $tag_name = $release->{tag_name} || '';
        my $version = $tag_name;
        $version =~ s/^v//;  # Remove leading 'v'
        
        push @releases, {
            version => $version,
            tag_name => $tag_name,
            tarball_url => $release->{tarball_url} || '',
            published_at => $release->{published_at} || '',
            release_name => $release->{name} || $version,
            prerelease => $release->{prerelease} ? 1 : 0,
            draft => $release->{draft} ? 1 : 0,
        };
    }
    
    print STDERR "[DEBUG][Update] Found " . scalar(@releases) . " releases\n"
        if $self->{debug};
    
    return \@releases;
}

=head2 get_release_by_version

Fetch a specific release by version number.

Arguments:
- $version: Version to fetch (e.g., "20260125.8")

Returns:
- Release hashref with {version, tag_name, tarball_url, etc.} or undef

=cut

sub get_release_by_version {
    my ($self, $version) = @_;
    
    return undef unless $version;
    
    # Try with 'v' prefix first (common convention), then without
    my @tags_to_try = ("v$version", $version);
    
    for my $tag (@tags_to_try) {
        my $api_url = sprintf("%s/repos/%s/releases/tags/%s",
            $self->{api_base},
            $self->{github_repo},
            $tag
        );
        
        print STDERR "[DEBUG][Update] Fetching release by tag: $tag\n"
            if $self->{debug};
        
        my $response = `curl -s -m $self->{timeout} -H "Accept: application/vnd.github+json" "$api_url" 2>/dev/null`;
        
        next if $? != 0;
        
        my $data;
        eval {
            $data = decode_json($response);
        };
        
        next if $@ || !$data || $data->{message};  # Skip if error or "not found" message
        
        my $tag_name = $data->{tag_name} || '';
        my $ver = $tag_name;
        $ver =~ s/^v//;
        
        return {
            version => $ver,
            tag_name => $tag_name,
            tarball_url => $data->{tarball_url} || '',
            published_at => $data->{published_at} || '',
            release_name => $data->{name} || $ver,
            release_notes => $data->{body} || '',
            prerelease => $data->{prerelease} ? 1 : 0,
        };
    }
    
    print STDERR "[DEBUG][Update] Version $version not found\n"
        if $self->{debug};
    return undef;
}

=head2 download_version

Download a specific version (not just latest).

Arguments:
- $version: Version to download (e.g., "20260125.8")

Returns:
- Path to downloaded and extracted directory, or undef on failure

=cut

sub download_version {
    my ($self, $version) = @_;
    
    return undef unless $version;
    
    # Get release info for this version
    my $release = $self->get_release_by_version($version);
    unless ($release && $release->{tarball_url}) {
        print STDERR "[ERROR][Update] Cannot find release for version: $version\n" if should_log('ERROR');
        return undef;
    }
    
    my $tarball_url = $release->{tarball_url};
    
    # Create download directory
    my $download_dir = "/tmp/clio-update-$version";
    if (-d $download_dir) {
        print STDERR "[DEBUG][Update] Removing existing download dir: $download_dir\n"
            if $self->{debug};
        rmtree($download_dir);
    }
    
    mkpath($download_dir) or do {
        print STDERR "[ERROR][Update] Cannot create download dir: $!\n" if should_log('ERROR');
        return undef;
    };
    
    # Download tarball
    my $tarball_path = "$download_dir/clio.tar.gz";
    print STDERR "[DEBUG][Update] Downloading version $version from: $tarball_url\n"
        if $self->{debug};
    
    my $curl_result = system("curl", "-sL", "-m", "30", "-o", $tarball_path, $tarball_url);
    
    if ($curl_result != 0) {
        print STDERR "[ERROR][Update] Download failed\n" if should_log('ERROR');
        rmtree($download_dir);
        return undef;
    }
    
    # Extract tarball
    print STDERR "[DEBUG][Update] Extracting tarball\n"
        if $self->{debug};
    
    my $extract_result = system("cd '$download_dir' && tar -xzf clio.tar.gz 2>/dev/null");
    
    if ($extract_result != 0) {
        print STDERR "[ERROR][Update] Extraction failed\n" if should_log('ERROR');
        rmtree($download_dir);
        return undef;
    }
    
    # Find extracted directory
    opendir(my $dh, $download_dir) or return undef;
    my @subdirs = grep { -d "$download_dir/$_" && $_ !~ /^\./ } readdir($dh);
    closedir($dh);
    
    unless (@subdirs) {
        print STDERR "[ERROR][Update] No extracted directory found\n" if should_log('ERROR');
        rmtree($download_dir);
        return undef;
    }
    
    my $extracted_dir = File::Spec->catdir($download_dir, $subdirs[0]);
    
    # Verify it looks like CLIO
    unless (-f "$extracted_dir/clio") {
        print STDERR "[ERROR][Update] Downloaded directory doesn't look like CLIO (no ./clio executable)\n" if should_log('ERROR');
        rmtree($download_dir);
        return undef;
    }
    
    print STDERR "[DEBUG][Update] Successfully downloaded version $version to: $extracted_dir\n"
        if $self->{debug};
    
    return $extracted_dir;
}

=head2 install_version

Install a specific version of CLIO.

Arguments:
- $version: Version to install

Returns:
- Hashref with {success, error, message}

=cut

sub install_version {
    my ($self, $version) = @_;
    
    return { success => 0, error => 'Version required' } unless $version;
    
    # Download the version
    my $source_dir = $self->download_version($version);
    unless ($source_dir) {
        return { success => 0, error => "Failed to download version $version" };
    }
    
    # Install from directory
    my $result = $self->install_from_directory($source_dir);
    
    # Clean up download directory
    my $download_dir = dirname($source_dir);
    rmtree($download_dir) if -d $download_dir;
    
    if ($result) {
        return { success => 1, message => "Installed version $version" };
    } else {
        return { success => 0, error => "Installation failed for version $version" };
    }
}

=head2 check_for_updates

Check if an update is available (synchronous).

Returns:
- Hashref with {current_version, latest_version, update_available, error} fields

=cut

sub check_for_updates {
    my ($self) = @_;
    
    my $current = $self->get_current_version();
    my $latest_info = $self->get_latest_version();
    
    # If we couldn't fetch latest version, return error
    unless ($latest_info && $latest_info->{version}) {
        return {
            current_version => $current,
            latest_version => 'unknown',
            update_available => 0,
            error => 'Failed to fetch latest version from GitHub'
        };
    }
    
    my $latest = $latest_info->{version};
    
    # Compare versions
    my $update_available = 0;
    if ($self->_compare_versions($latest, $current) > 0) {
        # Newer version available
        $update_available = 1;
    }
    
    return {
        current_version => $current,
        latest_version => $latest,
        update_available => $update_available,
        release_info => $latest_info,
    };
}

=head2 check_for_updates_async

Check for updates in background (non-blocking).

Forks a process to check GitHub API, writes result to cache file.
Parent process continues immediately.

=cut

sub check_for_updates_async {
    my ($self) = @_;
    
    # Check if cache is fresh (within cache_duration)
    my $cache_file = File::Spec->catfile($self->{cache_dir}, 'update_check_cache');
    if (-f $cache_file) {
        my $mtime = (stat($cache_file))[9];
        my $age = time() - $mtime;
        
        if ($age < $self->{cache_duration}) {
            print STDERR "[DEBUG][Update] Cache is fresh (age: ${age}s), skipping check\n"
                if $self->{debug};
            return;
        }
    }
    
    print STDERR "[DEBUG][Update] Starting background update check\n"
        if $self->{debug};
    
    # Fork to background
    my $pid = fork();
    
    if (!defined $pid) {
        # Fork failures during background update check are not critical
        # Only log in debug mode to avoid alarming users
        print STDERR "[DEBUG][Update] Failed to fork for background update check\n" 
            if should_log('DEBUG');
        return;
    }
    
    if ($pid == 0) {
        # Child process - CRITICAL: Reset terminal state while connected to parent TTY
        # This must happen BEFORE any file descriptor operations
        eval {
            require CLIO::Compat::Terminal;
            CLIO::Compat::Terminal::reset_terminal();
        };
        
        # Detach from terminal I/O to avoid interfering with parent
        close(STDIN);
        close(STDOUT);
        close(STDERR);
        
        # Check for updates
        my $result = $self->check_for_updates();
        
        # Ensure cache dir exists
        mkpath($self->{cache_dir}) unless -d $self->{cache_dir};
        
        # Write to cache
        my $cache_file = File::Spec->catfile($self->{cache_dir}, 'update_check_cache');
        
        if ($result && !$result->{error} && $result->{update_available}) {
            # Update available - cache the version
            open my $fh, '>', $cache_file or exit 1;
            print $fh $result->{latest_version} . "\n";
            close $fh;
            
            # Also write detailed info
            my $info_file = File::Spec->catfile($self->{cache_dir}, 'update_info');
            open my $info_fh, '>', $info_file or exit 1;
            require JSON::PP;
            print $info_fh JSON::PP->new->encode($result->{release_info} || {});
            close $info_fh;
        } else {
            # No update available or error - touch cache file to mark check complete
            open my $fh, '>', $cache_file or exit 1;
            print $fh "up-to-date\n";
            close $fh;
        }
        
        exit 0;  # Child exits
    }
    
    # Parent continues immediately (non-blocking)
}

=head2 get_available_update

Check if an update is available from cached check.

Returns:
- Hashref with {cached, up_to_date, version, current_version}
  * cached: 1 if cache exists, 0 if no cache
  * up_to_date: 1 if up-to-date, 0 if update available, undef if no cache
  * version: Latest version (if available), or current version if up-to-date
  * current_version: Current installed version

=cut

sub get_available_update {
    my ($self) = @_;
    
    my $cache_file = File::Spec->catfile($self->{cache_dir}, 'update_check_cache');
    my $current = $self->get_current_version();
    
    # No cache file exists
    unless (-f $cache_file) {
        return {
            cached => 0,
            up_to_date => undef,
            version => undef,
            current_version => $current,
        };
    }
    
    # Read cache file
    open my $fh, '<', $cache_file or return {
        cached => 0,
        up_to_date => undef,
        version => undef,
        current_version => $current,
    };
    my $content = <$fh>;
    close $fh;
    
    chomp $content if $content;
    
    # Cache says up-to-date
    if (!$content || $content eq 'up-to-date') {
        return {
            cached => 1,
            up_to_date => 1,
            version => $current,
            current_version => $current,
        };
    }
    
    # Cache has a version - check if it's different from current
    my $update_available = ($content ne $current) ? 1 : 0;
    
    return {
        cached => 1,
        up_to_date => $update_available ? 0 : 1,
        version => $content,
        current_version => $current,
    };
}

=head2 detect_install_location

Detect where CLIO is installed and determine if it's a system or user install.

Returns:
- Hashref with {path, type, writable, method}
  * path: Full path to CLIO executable
  * type: 'system' or 'user'
  * writable: Boolean - can we write without sudo?
  * method: Suggested installation method

=cut

sub detect_install_location {
    my ($self) = @_;
    
    # Find CLIO executable location
    my $clio_path = `which clio 2>/dev/null`;
    chomp $clio_path if $clio_path;
    
    unless ($clio_path && -f $clio_path) {
        # Maybe we're running from source
        $clio_path = './clio' if -f './clio';
    }
    
    return undef unless $clio_path;
    
    # Resolve symlinks to find actual location
    $clio_path = `readlink -f "$clio_path" 2>/dev/null` || $clio_path;
    chomp $clio_path;
    
    # Get the directory containing the clio executable
    my $bin_dir = dirname($clio_path);
    
    # The install directory is typically the parent of the bin directory
    # CLIO installs to: $INSTALL_DIR/clio (executable)
    #                  $INSTALL_DIR/lib/  (modules)
    # So if we found /opt/clio/clio, install_dir is /opt/clio
    # If we found /usr/local/bin/clio (symlink -> /opt/clio/clio), install_dir is /opt/clio
    
    my $install_dir = $bin_dir;
    
    # Check if this is actually the install directory (has lib/CLIO subdirectory)
    if (-d "$bin_dir/lib/CLIO") {
        # Good - this is the install directory
        $install_dir = $bin_dir;
    } else {
        # Maybe clio is in a bin subdirectory?
        # This shouldn't happen with CLIO's install.sh, but handle it anyway
        print STDERR "[WARN][Update] Cannot find lib/CLIO in $bin_dir - may be development mode\n"
            if $self->{debug};
    }
    
    # Determine if this is a user install or system install
    # User install: anywhere under $HOME
    # System install: anywhere else (typically /opt, /usr, /srv, etc.)
    my $type = 'system';  # Default to system
    my $is_user_home = 0;
    
    if ($install_dir =~ m{^\Q$ENV{HOME}\E(/|$)}) {
        $type = 'user';
        $is_user_home = 1;
    }
    
    # Check if the install directory is writable
    my $writable = -w $install_dir;
    
    # Determine if we need sudo
    my $needs_sudo = (!$is_user_home && !$writable);
    
    print STDERR "[DEBUG][Update] Detected install location:\n" if $self->{debug};
    print STDERR "[DEBUG][Update]   Path: $clio_path\n" if $self->{debug};
    print STDERR "[DEBUG][Update]   Install dir: $install_dir\n" if $self->{debug};
    print STDERR "[DEBUG][Update]   Type: $type\n" if $self->{debug};
    print STDERR "[DEBUG][Update]   User home: " . ($is_user_home ? 'yes' : 'no') . "\n" if $self->{debug};
    print STDERR "[DEBUG][Update]   Writable: " . ($writable ? 'yes' : 'no') . "\n" if $self->{debug};
    print STDERR "[DEBUG][Update]   Needs sudo: " . ($needs_sudo ? 'yes' : 'no') . "\n" if $self->{debug};
    
    return {
        path => $clio_path,
        install_dir => $install_dir,
        type => $type,
        is_user_home => $is_user_home,
        writable => $writable,
        needs_sudo => $needs_sudo,
    };
}

=head2 download_latest

Download latest release tarball from GitHub.

Returns:
- Path to downloaded and extracted directory, or undef on failure

=cut

sub download_latest {
    my ($self) = @_;
    
    # Get latest release info
    my $release = $self->get_latest_version();
    unless ($release && $release->{tarball_url}) {
        print STDERR "[ERROR][Update] Cannot get latest release info\n" if should_log('ERROR');
        return undef;
    }
    
    my $version = $release->{version};
    my $tarball_url = $release->{tarball_url};
    
    # Create download directory
    my $download_dir = "/tmp/clio-update-$version";
    if (-d $download_dir) {
        print STDERR "[DEBUG][Update] Removing existing download dir: $download_dir\n"
            if $self->{debug};
        rmtree($download_dir);
    }
    
    mkpath($download_dir) or do {
        print STDERR "[ERROR][Update] Cannot create download dir: $!\n" if should_log('ERROR');
        return undef;
    };
    
    # Download tarball
    my $tarball_path = "$download_dir/clio.tar.gz";
    print STDERR "[DEBUG][Update] Downloading from: $tarball_url\n"
        if $self->{debug};
    
    my $curl_result = system("curl", "-sL", "-m", "30", "-o", $tarball_path, $tarball_url);
    
    if ($curl_result != 0) {
        print STDERR "[ERROR][Update] Download failed\n" if should_log('ERROR');
        rmtree($download_dir);
        return undef;
    }
    
    # Extract tarball
    print STDERR "[DEBUG][Update] Extracting tarball\n"
        if $self->{debug};
    
    my $extract_result = system("cd '$download_dir' && tar -xzf clio.tar.gz 2>/dev/null");
    
    if ($extract_result != 0) {
        print STDERR "[ERROR][Update] Extraction failed\n" if should_log('ERROR');
        rmtree($download_dir);
        return undef;
    }
    
    # Find extracted directory (GitHub creates a subdirectory like SyntheticAutonomicMind-CLIO-abc123/)
    opendir(my $dh, $download_dir) or return undef;
    my @subdirs = grep { -d "$download_dir/$_" && $_ !~ /^\./ } readdir($dh);
    closedir($dh);
    
    unless (@subdirs) {
        print STDERR "[ERROR][Update] No extracted directory found\n" if should_log('ERROR');
        rmtree($download_dir);
        return undef;
    }
    
    my $extracted_dir = File::Spec->catdir($download_dir, $subdirs[0]);
    
    # Verify it looks like CLIO (has ./clio executable)
    unless (-f "$extracted_dir/clio") {
        print STDERR "[ERROR][Update] Downloaded directory doesn't look like CLIO (no ./clio executable)\n" if should_log('ERROR');
        rmtree($download_dir);
        return undef;
    }
    
    print STDERR "[DEBUG][Update] Successfully downloaded to: $extracted_dir\n"
        if $self->{debug};
    
    return $extracted_dir;
}

=head2 install_from_directory

Install CLIO from a directory (already downloaded/extracted).

Arguments:
- $source_dir: Path to extracted CLIO source

Returns:
- Boolean success

=cut

sub install_from_directory {
    my ($self, $source_dir) = @_;
    
    unless (-d $source_dir && -f "$source_dir/clio") {
        print STDERR "[ERROR][Update] Invalid source directory: $source_dir\n" if should_log('ERROR');
        return 0;
    }
    
    # Verify install.sh exists
    unless (-f "$source_dir/install.sh") {
        print STDERR "[ERROR][Update] install.sh not found in source directory\n" if should_log('ERROR');
        return 0;
    }
    
    # Detect current installation location
    my $install_info = $self->detect_install_location();
    unless ($install_info) {
        print STDERR "[ERROR][Update] Cannot detect CLIO installation location\n" if should_log('ERROR');
        return 0;
    }
    
    my $install_dir = $install_info->{install_dir};
    my $is_user_home = $install_info->{is_user_home};
    my $needs_sudo = $install_info->{needs_sudo};
    
    print STDERR "[DEBUG][Update] Installing CLIO update:\n" if $self->{debug};
    print STDERR "[DEBUG][Update]   Current install: $install_dir\n" if $self->{debug};
    print STDERR "[DEBUG][Update]   User home install: " . ($is_user_home ? 'yes' : 'no') . "\n" if $self->{debug};
    print STDERR "[DEBUG][Update]   Needs sudo: " . ($needs_sudo ? 'yes' : 'no') . "\n" if $self->{debug};
    
    # Change to source directory
    my $original_dir = `pwd`;
    chomp $original_dir;
    
    chdir($source_dir) or do {
        print STDERR "[ERROR][Update] Cannot cd to $source_dir: $!\n" if should_log('ERROR');
        return 0;
    };
    
    my $success = 0;
    
    # Determine the correct install.sh command based on detected location
    # install.sh behavior:
    #   - ./install.sh --user          -> installs to ~/.local/clio
    #   - ./install.sh /path/to/dir    -> installs to /path/to/dir
    #   - ./install.sh                 -> installs to /opt/clio (default)
    
    my $install_cmd;
    
    # Special case: if current install is ~/.local/clio, use --user flag
    if ($install_dir eq "$ENV{HOME}/.local/clio") {
        print STDERR "[DEBUG][Update] Using --user flag for ~/.local/clio install\n"
            if $self->{debug};
        $install_cmd = "bash install.sh --user";
    }
    # Otherwise, explicitly specify the target directory
    else {
        # Determine if we need sudo
        if ($needs_sudo) {
            print STDERR "[DEBUG][Update] System install to $install_dir (needs sudo)\n"
                if $self->{debug};
            $install_cmd = "sudo bash install.sh '$install_dir'";
        } else {
            print STDERR "[DEBUG][Update] Installing to $install_dir (no sudo needed)\n"
                if $self->{debug};
            $install_cmd = "bash install.sh '$install_dir'";
        }
    }
    
    print STDERR "[DEBUG][Update] Running: $install_cmd\n"
        if $self->{debug};
    
    my $result = system($install_cmd);
    $success = ($result == 0);
    
    if (!$success) {
        print STDERR "[ERROR][Update] Installation command failed: $install_cmd\n" if should_log('ERROR');
        print STDERR "[ERROR][Update] Exit code: " . ($result >> 8) . "\n" if should_log('ERROR');
    }
    
    chdir($original_dir);
    
    return $success;
}

=head2 install_latest

Download and install the latest version of CLIO.

Returns:
- Hashref with {success, message, version}

=cut

sub install_latest {
    my ($self) = @_;
    
    # Download latest
    my $source_dir = $self->download_latest();
    unless ($source_dir) {
        return {
            success => 0,
            message => "Failed to download latest version",
        };
    }
    
    # Get version from downloaded source
    my $new_version = 'unknown';
    if (-f "$source_dir/VERSION") {
        open my $fh, '<', "$source_dir/VERSION";
        $new_version = <$fh>;
        close $fh;
        chomp $new_version if $new_version;
    }
    
    # Install
    my $install_success = $self->install_from_directory($source_dir);
    
    # Cleanup download directory
    rmtree(dirname($source_dir));
    
    if ($install_success) {
        # Clear update cache
        my $cache_file = File::Spec->catfile($self->{cache_dir}, 'update_check_cache');
        unlink $cache_file if -f $cache_file;
        
        return {
            success => 1,
            message => "Successfully updated to version $new_version",
            version => $new_version,
        };
    } else {
        return {
            success => 0,
            message => "Installation failed",
        };
    }
}

=head2 _compare_versions

Compare two version strings in YYYYMMDD.B format.

Arguments:
- $v1, $v2: Version strings to compare

Returns:
- 1 if v1 > v2
- 0 if v1 == v2
- -1 if v1 < v2

=cut

sub _compare_versions {
    my ($self, $v1, $v2) = @_;
    
    # Handle unknown versions
    return 0 if $v1 eq 'unknown' || $v2 eq 'unknown';
    
    # Remove 'v' prefix if present
    $v1 =~ s/^v//;
    $v2 =~ s/^v//;
    
    # Handle git describe format (20260122.1-5-gabcdef)
    $v1 =~ s/-\d+-g[a-f0-9]+$//;
    $v2 =~ s/-\d+-g[a-f0-9]+$//;
    
    # Parse YYYYMMDD.BUILD format
    my ($date1, $build1) = split /\./, $v1;
    my ($date2, $build2) = split /\./, $v2;
    
    $date1 ||= 0;
    $date2 ||= 0;
    $build1 ||= 0;
    $build2 ||= 0;
    
    # Compare dates first
    return 1 if $date1 > $date2;
    return -1 if $date1 < $date2;
    
    # Dates equal, compare build numbers
    return 1 if $build1 > $build2;
    return -1 if $build1 < $build2;
    
    return 0;  # Equal
}

1;
