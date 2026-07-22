# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::UI::Spinners;

use strict;
use warnings;
use utf8;
use Exporter 'import';

our @EXPORT_OK = qw(spinner_frames spinner_metadata list_spinners detect_locale_utf8 parse_legacy_frames);

=head1 NAME

CLIO::UI::Spinners - Named spinner animations with capability-aware fallback

=head1 DESCRIPTION

Catalog of named spinner animations that the theme system can reference via
the C<spinner_style> key in style files.

Each spinner entry has:
- frames: arrayref of strings (one frame per animation tick)
- requires_utf8: bool - if true and the locale/terminal can't display UTF-8,
  falls back to the C<dots> spinner instead
- delay: optional milliseconds-per-frame override
- description: short human-readable label for the /style preview

Built-in spinners:

=over 4

=item dots (default)

ASCII dot cascade. Works everywhere.

Frames: .  ..  ...  ..  .  (blank)

=item rotator

ASCII classic vi-search rotation. Works everywhere.

Frames: |  /  -  \

=item braille

8-frame Unicode braille pattern. Very smooth visually. Falls back to
dots on non-UTF-8 locales.

Frames: ⠁ ⠂ ⠄ ⡀ ⢀ ⠠ ⠐ ⠈

=back

Themes select via:

    spinner_style=dots        # default
    spinner_style=rotator
    spinner_style=braille

For custom frame sequences, themes can still override with C<spinner_frames>:

    spinner_frames=.,..,...,..,., 

=cut

my %SPINNERS = (
    dots => {
        frames       => ['.', '..', '...', '..', '.', ' '],
        requires_utf8 => 0,
        delay_ms      => 200,
        description   => 'ASCII dot cascade (works on all terminals)',
    },
    rotator => {
        frames       => ['|', '/', '-', '\\'],
        requires_utf8 => 0,
        delay_ms      => 120,
        description   => 'ASCII classic rotation (vi search style)',
    },
    braille => {
        frames       => ["\x{2801}", "\x{2802}", "\x{2804}", "\x{2808}",
                         "\x{2810}", "\x{2820}", "\x{2840}", "\x{2880}"],
        requires_utf8 => 1,
        delay_ms      => 80,
        description   => 'Unicode braille pattern (falls back to dots on non-UTF-8)',
    },
);

=head2 spinner_frames($name, %opts)

Get the frame list for a named spinner. Applies capability fallback:
if the spinner requires UTF-8 and the locale can't render it, returns
the dots spinner frames instead.

Returns: arrayref of frame strings. Falls back to dots frames if the
requested name is unknown.

Arguments:
- $name: spinner name (dots, rotator, braille, ...)
- %opts:
    - force_utf8: bool - bypass locale check (for testing)

=cut

sub spinner_frames {
    my ($name, %opts) = @_;

    $name //= 'dots';
    my $entry = $SPINNERS{$name};

    unless ($entry) {
        # Unknown spinner - log and fall back to dots.
        if (eval { require CLIO::Core::Logger; 1 }) {
            CLIO::Core::Logger::log_warning('Spinners',
                "Unknown spinner style '$name', falling back to dots");
        }
        return [ @{$SPINNERS{dots}{frames}} ];
    }

    # Capability check: UTF-8 spinners degrade to dots on non-UTF-8 locales.
    if ($entry->{requires_utf8}) {
        my $force = $opts{force_utf8};
        my $has_utf8 = $force // detect_locale_utf8();
        unless ($has_utf8) {
            return [ @{$SPINNERS{dots}{frames}} ];
        }
    }

    return [ @{$entry->{frames}} ];
}

=head2 spinner_metadata($name)

Get the full metadata hash for a named spinner (or undef if unknown).

=cut

sub spinner_metadata {
    my ($name) = @_;
    return undef unless defined $name && exists $SPINNERS{$name};
    return { %{$SPINNERS{$name}} };  # shallow copy
}

=head2 list_spinners

Get sorted list of available spinner names.

=cut

sub list_spinners {
    return sort keys %SPINNERS;
}

=head2 detect_locale_utf8

Returns 1 if the current locale environment advertises UTF-8 encoding.

Checks LC_ALL, LC_CTYPE, LANG in that order.

=cut

sub detect_locale_utf8 {
    for my $var ($ENV{LC_ALL}, $ENV{LC_CTYPE}, $ENV{LANG}) {
        next unless defined $var;
        return 1 if $var =~ /UTF-?8/i;
    }
    return 0;
}

# Internal: legacy frame string parser for backward compat with themes
# that use the legacy spinner_frames=... format.
sub _parse_legacy_frames {
    my ($frames_str) = @_;
    $frames_str //= '.,..,...,..,., ';
    my @frames = split(/,/, $frames_str);
    @frames = map { s/^\s+//r } @frames;
    @frames = map { $_ eq '' ? ' ' : $_ } @frames;
    return \@frames;
}

# Allow callers (Theme.pm) to parse a legacy spinner_frames string.
sub parse_legacy_frames { _parse_legacy_frames(@_); }

1;

__END__

=head1 EXAMPLES

    use CLIO::UI::Spinners qw(spinner_frames);

    # Get frames for the braille spinner (auto-fallbacks to dots
    # if locale isn't UTF-8).
    my $frames = spinner_frames('braille');

    # In a style file:
    spinner_style=braille

    # Custom override still works:
    spinner_frames=*,**,***,**,*, 

=head1 SEE ALSO

L<CLIO::UI::Theme>, L<CLIO::UI::ProgressSpinner>

=cut

1;