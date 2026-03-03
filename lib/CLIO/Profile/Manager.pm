package CLIO::Profile::Manager;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
use CLIO::Core::Logger qw(log_debug log_warning log_error);
use File::Spec;
use File::Path qw(make_path);

=head1 NAME

CLIO::Profile::Manager - Manage user personality profiles for CLIO

=head1 DESCRIPTION

Handles loading, saving, and injecting user profiles into the system prompt.
Profiles live at ~/.clio/profile.md (global, never in any git repo) and are
injected alongside LTM patterns to personalize AI collaboration.

=cut

my $PROFILE_FILENAME = 'profile.md';

sub new {
    my ($class, %args) = @_;
    return bless {
        debug => $args{debug} || 0,
    }, $class;
}

=head2 profile_path

Get the path to the user's profile file.

Returns:
- Full path to ~/.clio/profile.md

=cut

sub profile_path {
    my ($self) = @_;
    my $home = $ENV{HOME} || $ENV{USERPROFILE} || '';
    return File::Spec->catfile($home, '.clio', $PROFILE_FILENAME);
}

=head2 profile_exists

Check if a profile file exists.

Returns:
- 1 if exists, 0 if not

=cut

sub profile_exists {
    my ($self) = @_;
    return -f $self->profile_path() ? 1 : 0;
}

=head2 load_profile

Load the user's profile content.

Returns:
- Profile content as string, or undef if no profile exists

=cut

sub load_profile {
    my ($self) = @_;

    my $path = $self->profile_path();

    unless (-f $path) {
        log_debug('ProfileManager', "No profile found at $path");
        return undef;
    }

    my $content;
    eval {
        open my $fh, '<:encoding(UTF-8)', $path or die "Cannot open $path: $!";
        local $/;
        $content = <$fh>;
        close $fh;
    };

    if ($@ || !$content) {
        log_warning('ProfileManager', "Failed to read profile: $@");
        return undef;
    }

    # Trim whitespace
    $content =~ s/^\s+|\s+$//g;

    if (length($content) < 10) {
        log_debug('ProfileManager', "Profile too short, ignoring");
        return undef;
    }

    log_debug('ProfileManager', "Loaded profile (" . length($content) . " bytes)");
    return $content;
}

=head2 save_profile

Save profile content to ~/.clio/profile.md.

Arguments:
- $content: Profile markdown content

Returns:
- 1 on success, 0 on failure

=cut

sub save_profile {
    my ($self, $content) = @_;

    my $path = $self->profile_path();
    my $dir = File::Spec->catdir($ENV{HOME} || '', '.clio');

    # Ensure directory exists
    unless (-d $dir) {
        eval { make_path($dir) };
        if ($@) {
            log_error('ProfileManager', "Cannot create directory $dir: $@");
            return 0;
        }
    }

    eval {
        my $temp = $path . '.tmp.' . $$;
        open my $fh, '>:encoding(UTF-8)', $temp or die "Cannot write $temp: $!";
        print $fh $content;
        close $fh;
        rename $temp, $path or die "Cannot rename $temp to $path: $!";
    };

    if ($@) {
        log_error('ProfileManager', "Failed to save profile: $@");
        return 0;
    }

    log_debug('ProfileManager', "Saved profile to $path (" . length($content) . " bytes)");
    return 1;
}

=head2 clear_profile

Remove the profile file.

Returns:
- 1 on success, 0 on failure

=cut

sub clear_profile {
    my ($self) = @_;

    my $path = $self->profile_path();

    unless (-f $path) {
        return 1;  # Already gone
    }

    if (unlink $path) {
        log_debug('ProfileManager', "Removed profile at $path");
        return 1;
    } else {
        log_error('ProfileManager', "Failed to remove profile: $!");
        return 0;
    }
}

=head2 generate_prompt_section

Generate the system prompt section for profile injection.
This is called by PromptBuilder to add profile context.

Returns:
- Markdown string for system prompt injection, or empty string

=cut

sub generate_prompt_section {
    my ($self) = @_;

    my $content = $self->load_profile();
    return '' unless $content;

    my $section = <<'SECTION_HEADER';
# User Profile

The following profile describes the human you are working with.
Adapt your communication style, decision-making, and workflow to match their preferences.

SECTION_HEADER

    $section .= $content;

    return $section;
}

1;
