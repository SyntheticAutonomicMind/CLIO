package CLIO::Update::Releases;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;
use File::Spec;
use Cwd qw(getcwd);
use File::Path qw(mkpath rmtree);
use CLIO::Util::JSON qw(decode_json);
use CLIO::Util::Proxy qw(resolve_proxy_url);
use CLIO::Core::Logger qw(log_debug log_error log_warning);

my $NULLDEV = $^O eq 'MSWin32' ? 'nul' : '/dev/null';

# Get proxy arguments for curl commands (list form for system()).
sub _proxy_arg {
    my $proxy = resolve_proxy_url();
    if ($proxy) {
        return ('--proxy', $proxy);
    }
    return ();
}

# Get proxy flag string for shell-based curl calls.
sub _proxy_shell_arg {
    my @args = _proxy_arg();
    return '' unless @args;
    return join(' ', map { "'$_'" } @args) . ' ';
}

=head1 NAME

CLIO::Update::Releases - GitHub releases API + tarball download primitives

=head1 SYNOPSIS

    use CLIO::Update::Releases;

    my $release = CLIO::Update::Releases::get_latest_version(
        github_repo => 'SyntheticAutonomicMind/CLIO',
    );
    my $path = CLIO::Update::Releases::download_version(
        version => '20260720.1',
        github_repo => 'SyntheticAutonomicMind/CLIO',
    );

=head1 DESCRIPTION

Class methods that fetch CLIO release metadata from GitHub's API and
download release tarballs. Split out of CLIO::Update to keep that
module focused on update workflow (check / install / cache).

Each method accepts options as a hash:

    api_base    => 'https://api.github.com'   # GitHub API root
    github_repo => 'SyntheticAutonomicMind/CLIO'
    timeout     => 10                          # HTTP timeout (seconds)
    proxy       => undef                       # explicit proxy URL (optional)

=cut

# Default options applied when caller doesn't override.
sub _defaults {
    return (
        api_base    => 'https://api.github.com',
        github_repo => 'SyntheticAutonomicMind/CLIO',
        timeout     => 10,
    );
}

sub _resolve_opts {
    my %opts = @_;
    my %defaults = _defaults();
    return (%defaults, %opts);
}

=head2 get_latest_version

Fetch latest version from GitHub releases API.

Returns:
- Hashref with {version, tag_name, tarball_url, published_at, ...} or undef on failure

=cut

sub get_latest_version {
    my %opts = _resolve_opts(@_);

    my $api_url = sprintf("%s/repos/%s/releases/latest",
        $opts{api_base},
        $opts{github_repo}
    );

    log_debug('Update', "Fetching latest release from: $api_url");

    my $response = `curl -s -m $opts{timeout} @{[_proxy_shell_arg()]}-H "Accept: application/vnd.github+json" "$api_url" 2>$NULLDEV`;

    if ($? != 0) {
        log_debug('Update', "curl failed with exit code: " . ($? >> 8));
        return undef;
    }

    my $data;
    eval { $data = decode_json($response); };
    if ($@ || !$data) {
        log_debug('Update', "Failed to parse JSON response: $@");
        return undef;
    }

    my $tag_name = $data->{tag_name} || '';
    my $version  = $tag_name;
    $version =~ s/^v//;

    return {
        version       => $version,
        tag_name      => $tag_name,
        tarball_url   => $data->{tarball_url}   || '',
        published_at  => $data->{published_at}  || '',
        release_name  => $data->{name}          || '',
        release_notes => $data->{body}          || '',
    };
}

=head2 get_all_releases

Fetch all available releases from GitHub.

Arguments:
- per_page: Number of releases per page (default: 30)
- page:     Page number (default: 1)

Returns:
- Arrayref of release hashrefs, each with {version, tag_name, tarball_url, published_at, release_name, prerelease, draft}
- undef on failure

=cut

sub get_all_releases {
    my %opts = _resolve_opts(@_);

    my $per_page = delete $opts{per_page} || 30;
    my $page     = delete $opts{page}     || 1;

    my $api_url = sprintf("%s/repos/%s/releases?per_page=%d&page=%d",
        $opts{api_base},
        $opts{github_repo},
        $per_page,
        $page
    );

    log_debug('Update', "Fetching releases from: $api_url");

    my $response = `curl -s -m $opts{timeout} @{[_proxy_shell_arg()]}-H "Accept: application/vnd.github+json" "$api_url" 2>$NULLDEV`;

    if ($? != 0) {
        log_debug('Update', "curl failed with exit code: " . ($? >> 8));
        return undef;
    }

    my $data;
    eval { $data = decode_json($response); };
    if ($@ || !$data || ref($data) ne 'ARRAY') {
        log_debug('Update', "Failed to parse JSON response: $@");
        return undef;
    }

    my @releases;
    for my $release (@$data) {
        my $tag_name = $release->{tag_name} || '';
        my $version  = $tag_name;
        $version =~ s/^v//;

        push @releases, {
            version       => $version,
            tag_name      => $tag_name,
            tarball_url   => $release->{tarball_url}   || '',
            published_at  => $release->{published_at}  || '',
            release_name  => $release->{name} || $version,
            prerelease    => $release->{prerelease} ? 1 : 0,
            draft         => $release->{draft}      ? 1 : 0,
        };
    }

    log_debug('Update', "Found " . scalar(@releases) . " releases");
    return \@releases;
}

=head2 get_release_by_version

Fetch a specific release by version number.

Arguments:
- version: Version to fetch (e.g., "20260125.8")

Returns:
- Release hashref with {version, tag_name, tarball_url, ...} or undef

=cut

sub get_release_by_version {
    my %opts = _resolve_opts(@_);
    my $version = delete $opts{version};

    return undef unless $version;

    unless ($version =~ /^[A-Za-z0-9._-]+$/) {
        log_error("Update", "Invalid version format: $version");
        return undef;
    }

    # Try with 'v' prefix first (common convention), then without
    my @tags_to_try = ("v$version", $version);

    for my $tag (@tags_to_try) {
        my $api_url = sprintf("%s/repos/%s/releases/tags/%s",
            $opts{api_base},
            $opts{github_repo},
            $tag
        );

        log_debug('Update', "Fetching release by tag: $tag");

        my $response = `curl -s -m $opts{timeout} @{[_proxy_shell_arg()]}-H "Accept: application/vnd.github+json" "$api_url" 2>$NULLDEV`;

        next if $? != 0;

        my $data;
        eval { $data = decode_json($response); };
        next if $@ || !$data || $data->{message};

        my $tag_name = $data->{tag_name} || '';
        my $ver      = $tag_name;
        $ver =~ s/^v//;

        return {
            version       => $ver,
            tag_name      => $tag_name,
            tarball_url   => $data->{tarball_url}   || '',
            published_at  => $data->{published_at}  || '',
            release_name  => $data->{name}          || $ver,
            release_notes => $data->{body}          || '',
            prerelease    => $data->{prerelease} ? 1 : 0,
        };
    }

    log_debug('Update', "Version $version not found");
    return undef;
}

=head2 download_version

Download a specific version (not just latest).

Arguments:
- version: Version to download (e.g., "20260125.8")

Returns:
- In list context: ($extracted_dir, $cleanup_dir). $cleanup_dir is the
  top-level download directory that should be removed once install
  completes. Pass it to L<Cleanup|/remove_cleanup_dir> rather than
  computing it via dirname() on $extracted_dir.
- In scalar context: path to downloaded and extracted directory, or undef
  on failure. Callers that need the cleanup dir should use list context.

=cut

sub download_version {
    my %opts = _resolve_opts(@_);
    my $version = delete $opts{version};

    return undef unless $version;

    unless ($version =~ /^[A-Za-z0-9._-]+$/) {
        log_error("Update", "Invalid version format: $version");
        return undef;
    }

    my $release = get_release_by_version(%opts, version => $version);
    unless ($release && $release->{tarball_url}) {
        log_error('Update', "Cannot find release for version: $version");
        return undef;
    }

    return _download_and_extract(%opts,
        version     => $version,
        tarball_url => $release->{tarball_url},
    );
}

=head2 download_latest

Download latest release tarball from GitHub.

Returns:
- Path to downloaded and extracted directory, or undef on failure

=cut

sub download_latest {
    my %opts = _resolve_opts(@_);

    my $release = get_latest_version(%opts);
    unless ($release && $release->{tarball_url}) {
        log_error('Update', "Cannot get latest release info");
        return undef;
    }

    return _download_and_extract(%opts,
        version     => $release->{version},
        tarball_url => $release->{tarball_url},
    );
}

# Shared download + extract implementation used by download_version and
# download_latest. Handles the /tmp working directory, curl, tar extract,
# and verifies the result looks like a CLIO source tree.
sub _download_and_extract {
    my %opts = @_;
    my $version     = $opts{version}     or return undef;
    my $tarball_url = $opts{tarball_url} or return undef;
    my $timeout     = $opts{timeout}     || 30;

    my $download_dir = "/tmp/clio-update-$version";
    if (-d $download_dir) {
        log_debug('Update', "Removing existing download dir: $download_dir");
        rmtree($download_dir);
    }

    mkpath($download_dir) or do {
        log_error('Update', "Cannot create download dir: $!");
        return undef;
    };

    my $tarball_path = "$download_dir/clio.tar.gz";
    log_debug('Update', "Downloading $tarball_url -> $tarball_path");

    my $curl_result = system("curl", "-sL", "-m", $timeout, _proxy_arg(), "-o", $tarball_path, $tarball_url);
    if ($curl_result != 0) {
        log_error('Update', "Download failed");
        rmtree($download_dir);
        return undef;
    }

    log_debug('Update', "Extracting tarball");
    my $orig_dir = getcwd();
    my $extract_ok = 0;
    if (chdir($download_dir)) {
        $extract_ok = (system("tar", "-xzf", "clio.tar.gz") == 0);
        chdir($orig_dir) or log_warning("Update", "Cannot return to $orig_dir: $!");
    }

    if (!$extract_ok) {
        log_error('Update', "Extraction failed");
        rmtree($download_dir);
        return undef;
    }

    opendir(my $dh, $download_dir) or return undef;
    my @subdirs = grep { -d "$download_dir/$_" && $_ !~ /^\./ } readdir($dh);
    closedir($dh);

    unless (@subdirs) {
        log_error('Update', "No extracted directory found");
        rmtree($download_dir);
        return undef;
    }

    my $extracted_dir = File::Spec->catdir($download_dir, $subdirs[0]);

    unless (-f "$extracted_dir/clio") {
        log_error('Update', "Downloaded directory doesn't look like CLIO (no ./clio executable)");
        rmtree($download_dir);
        return undef;
    }

    log_debug('Update', "Successfully downloaded to: $extracted_dir");
    # Return both the extracted path and the cleanup scope. Callers that
    # only need the extracted path can still call us in scalar context;
    # callers that need to clean up should use list context to avoid the
    # fragile dirname($source_dir) approach (which previously caused
    # switch_to_version to rmtree('/tmp') when source_dir sat at /tmp/foo
    # and walked the entire real /tmp tree).
    return wantarray ? ($extracted_dir, $download_dir) : $extracted_dir;
}

1;