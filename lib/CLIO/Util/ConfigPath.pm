package CLIO::Util::ConfigPath;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use File::Spec;
use File::Path qw(make_path);

=head1 NAME

CLIO::Util::ConfigPath - Platform-aware configuration directory resolution

=head1 DESCRIPTION

Provides platform-aware path resolution for CLIO's configuration and data
directories. Handles iOS/iPadOS sandboxing where $HOME is not writable.

=head1 SYNOPSIS

    use CLIO::Util::ConfigPath qw(get_config_dir get_config_file);
    
    my $dir = get_config_dir();  # Returns writable .clio directory
    my $file = get_config_file('github_tokens.json');
    my $xdg_dir = get_config_dir('xdg');  # Returns .config/clio

=head1 EXPORTS

None by default. Export get_config_dir and get_config_file on request.

=cut

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(get_config_dir get_config_file);

=head2 get_config_dir

Get platform-appropriate writable configuration directory.

Arguments:
- $type: Optional. 'xdg' for .config/clio, undef for .clio (default)

Returns: Full path to writable config directory

iOS/iPadOS Detection:
- Checks if Documents exists and HOME is not writable
- Falls back to HOME/Documents/.clio on iOS
- Works on all Unix-like platforms

=cut

sub get_config_dir {
    my ($type) = @_;
    
    my $home = $ENV{HOME} || $ENV{USERPROFILE} || '.';
    
    # Determine subdirectory based on type
    my @subdir = $type && $type eq 'xdg' 
        ? ('.config', 'clio')
        : ('.clio');
    
    # Try standard HOME location first
    my $config_dir = File::Spec->catdir($home, @subdir);
    
    # Check if we can write to HOME (works on desktop Unix/macOS/Windows)
    if (-d $config_dir || -w $home) {
        # HOME is writable, use standard location
        make_path($config_dir) unless -d $config_dir;
        return $config_dir if -d $config_dir;
    }
    
    # Fallback: iOS/iPadOS or other sandboxed environment
    # Check if Documents exists and HOME is not writable (iOS pattern)
    my $docs_dir = File::Spec->catdir($home, 'Documents');
    if (-d $docs_dir && !-w $home) {
        # iOS detected - use Documents/.clio
        $config_dir = File::Spec->catdir($docs_dir, @subdir);
        make_path($config_dir) unless -d $config_dir;
        return $config_dir;
    }
    
    # Last resort: use current directory
    $config_dir = File::Spec->catdir('.', @subdir);
    make_path($config_dir) unless -d $config_dir;
    
    return $config_dir;
}

=head2 get_config_file

Get platform-appropriate path to a configuration file.

Arguments:
- $filename: Required. Name of config file (e.g., 'github_tokens.json')
- $type: Optional. 'xdg' for .config/clio location, undef for .clio

Returns: Full path to config file

Example:
    my $tokens = get_config_file('github_tokens.json');
    my $prompts = get_config_file('system-prompts', 'xdg');

=cut

sub get_config_file {
    my ($filename, $type) = @_;
    
    die "get_config_file: filename required" unless $filename;
    
    my $dir = get_config_dir($type);
    return File::Spec->catfile($dir, $filename);
}

1;

=head1 PLATFORM NOTES

=head2 Linux/macOS

Standard locations:
- ~/.clio/ for main config
- ~/.config/clio/ for XDG-compliant config

=head2 Windows

Uses %USERPROFILE%\.clio\

=head2 iOS/iPadOS

Due to sandboxing, HOME is not writable. Uses:
- ~/Documents/.clio/ for main config
- ~/Documents/.config/clio/ for XDG-style config

Detection: Checks if Documents/ exists and HOME is not writable.

=head1 SEE ALSO

L<CLIO::Core::Config>, L<CLIO::Core::GitHubAuth>

=cut

1;
