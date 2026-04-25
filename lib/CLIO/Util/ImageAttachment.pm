# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Util::ImageAttachment;

use strict;
use warnings;
use utf8;
use Carp qw(croak);
use CLIO::Core::Logger qw(log_debug log_warning);

=head1 NAME

CLIO::Util::ImageAttachment - Read, validate, and encode image files for multimodal API messages

=head1 DESCRIPTION

Utility for preparing image files to be sent as part of multimodal chat messages.
Handles MIME type detection, base64 encoding, size validation, and format conversion.

=head1 SYNOPSIS

    use CLIO::Util::ImageAttachment;
    
    my $attachment = CLIO::Util::ImageAttachment->new('screenshot.png');
    my $data_url = $attachment->to_data_url();  # data:image/png;base64,...
    
    # Or build an OpenAI content part directly
    my $part = $attachment->to_openai_part();  # { type => 'image_url', image_url => { url => '...' } }

=cut

# Supported image formats and their MIME types
my %MIME_TYPES = (
    'png'  => 'image/png',
    'jpg'  => 'image/jpeg',
    'jpeg' => 'image/jpeg',
    'gif'  => 'image/gif',
    'webp' => 'image/webp',
    'bmp'  => 'image/bmp',
);

# Magic bytes for format detection (fallback when extension is unreliable)
my %MAGIC_BYTES = (
    "\x89PNG"     => 'image/png',
    "\xFF\xD8"   => 'image/jpeg',
    'GIF8'        => 'image/gif',
    'RIFF'        => 'image/webp',  # WebP starts with RIFF....WEBP
    'BM'          => 'image/bmp',
);

# Size limits
use constant MAX_FILE_SIZE_BYTES => 20 * 1024 * 1024;  # 20MB (OpenAI limit)
use constant WARN_FILE_SIZE_BYTES => 5 * 1024 * 1024;  # 5MB (warn above this)

=head2 new($file_path)

Create a new ImageAttachment from a file path.

Arguments:
- $file_path: Path to the image file

Returns: ImageAttachment object, or undef if file is invalid

=cut

sub new {
    my ($class, $file_path) = @_;
    
    return undef unless defined $file_path && length($file_path) > 0;
    
    # Resolve path
    require Cwd;
    require File::Spec;
    my $resolved = File::Spec->rel2abs($file_path);
    
    unless (-e $resolved) {
        log_warning('ImageAttachment', "File not found: $resolved");
        return undef;
    }
    
    unless (-f $resolved && -r $resolved) {
        log_warning('ImageAttachment', "Not a readable file: $resolved");
        return undef;
    }
    
    my $size = -s $resolved;
    if ($size > MAX_FILE_SIZE_BYTES) {
        log_warning('ImageAttachment', "File too large: " . _format_bytes($size) . " (max " . _format_bytes(MAX_FILE_SIZE_BYTES) . ")");
        return undef;
    }
    
    my $mime_type = _detect_mime_type($resolved);
    unless ($mime_type) {
        log_warning('ImageAttachment', "Unsupported image format: $resolved");
        return undef;
    }
    
    my $self = bless {
        file_path => $resolved,
        size      => $size,
        mime_type => $mime_type,
    }, $class;
    
    if ($size > WARN_FILE_SIZE_BYTES) {
        log_warning('ImageAttachment', "Large image: " . _format_bytes($size) . " (may slow API response)");
    }
    
    log_debug('ImageAttachment', "Loaded $mime_type image: $resolved (" . _format_bytes($size) . ")");
    
    return $self;
}

=head2 file_path

Returns the resolved absolute file path.

=cut

sub file_path { $_[0]{file_path} }

=head2 size

Returns the file size in bytes.

=cut

sub size { $_[0]{size} }

=head2 mime_type

Returns the detected MIME type.

=cut

sub mime_type { $_[0]{mime_type} }

=head2 to_base64

Read the image file and return base64-encoded data.

Returns: Base64 string, or undef on error

=cut

sub to_base64 {
    my ($self) = @_;
    
    # Return cached base64 if already encoded
    return $self->{_cached_base64} if defined $self->{_cached_base64};
    
    my $path = $self->{file_path};
    
    open my $fh, '<:raw', $path or do {
        log_warning('ImageAttachment', "Cannot read $path: $!");
        return undef;
    };
    
    local $/;
    my $data = <$fh>;
    close $fh;
    
    unless (defined $data && length($data) > 0) {
        log_warning('ImageAttachment', "Empty file: $path");
        return undef;
    }
    
    require MIME::Base64;
    $self->{_cached_base64} = MIME::Base64::encode_base64($data, '');  # no line breaks
    return $self->{_cached_base64};
}

=head2 to_data_url

Create a data URL suitable for OpenAI image_url format.

Returns: "data:image/png;base64,ABC..." string, or undef on error

=cut

sub to_data_url {
    my ($self) = @_;
    
    my $base64 = $self->to_base64();
    return undef unless defined $base64;
    
    return 'data:' . $self->{mime_type} . ';base64,' . $base64;
}

=head2 to_openai_part

Build an OpenAI-compatible content part hashref.

Returns:
    { type => 'image_url', image_url => { url => 'data:image/png;base64,ABC...' } }

=cut

sub to_openai_part {
    my ($self) = @_;
    
    my $data_url = $self->to_data_url();
    return undef unless defined $data_url;
    
    return {
        type      => 'image_url',
        image_url => { url => $data_url },
    };
}

=head2 to_google_part

Build a Google Gemini-compatible content part hashref.

Returns:
    { inlineData => { mimeType => 'image/png', data => 'ABC...' } }

=cut

sub to_google_part {
    my ($self) = @_;
    
    my $base64 = $self->to_base64();
    return undef unless defined $base64;
    
    return {
        inlineData => {
            mimeType => $self->{mime_type},
            data     => $base64,
        },
    };
}

=head2 to_text_description

Return a text description of the image for non-multimodal contexts.

Returns: String like "[Image: screenshot.png (image/png, 245KB)]"

=cut

sub to_text_description {
    my ($self) = @_;
    
    my $basename = $self->{file_path};
    $basename =~ s|.*[/\\]||;  # extract filename from path
    
    return "[Image: $basename (" . $self->{mime_type} . ', ' . _format_bytes($self->{size}) . ')]';
}

# ─────────────────────────────────────────────────────────────
# Private helpers
# ─────────────────────────────────────────────────────────────

sub _detect_mime_type {
    my ($file_path) = @_;
    
    # First: check extension
    if ($file_path =~ /\.([a-zA-Z0-9]+)$/) {
        my $ext = lc($1);
        return $MIME_TYPES{$ext} if exists $MIME_TYPES{$ext};
    }
    
    # Second: check magic bytes
    open my $fh, '<:raw', $file_path or return undef;
    my $header;
    read($fh, $header, 12);
    close $fh;
    
    for my $magic (keys %MAGIC_BYTES) {
        if (substr($header, 0, length($magic)) eq $magic) {
            # Special case: RIFF could be WebP or something else
            if ($magic eq 'RIFF') {
                return 'image/webp' if index($header, 'WEBP') >= 0;
                next;
            }
            return $MAGIC_BYTES{$magic};
        }
    }
    
    return undef;
}

sub _format_bytes {
    my ($bytes) = @_;
    return sprintf('%.1f MB', $bytes / (1024 * 1024)) if $bytes >= 1024 * 1024;
    return sprintf('%.1f KB', $bytes / 1024) if $bytes >= 1024;
    return "$bytes bytes";
}

sub _looks_like_image_path {
    my ($path) = @_;
    return 0 unless defined $path && length($path) > 0;
    # Check if the path ends with a recognized image extension
    if ($path =~ /\.([a-zA-Z0-9]+)$/) {
        my $ext = lc($1);
        return 1 if exists $MIME_TYPES{$ext};
    }
    return 0;
}

=head2 parse_attachments_from_text($text)

Scan text for @path/to/image.png references and return:
- The cleaned text (with @references removed)
- Array of attachment file paths

Returns: ($cleaned_text, @attachment_paths)

=cut

sub parse_attachments_from_text {
    my ($text) = @_;
    
    return ($text, ()) unless defined $text;
    
    my @attachments;
    my $cleaned = $text;
    
    # Match @"path with spaces.png" - only strip if it looks like an image path
    while ($cleaned =~ /@"([^"]+)"/) {
        my $path = $1;
        if (_looks_like_image_path($path)) {
            # Remove the @"..." pattern from text
            my $quoted = '@"' . $path . '"';
            $cleaned =~ s/\s*\Q$quoted\E//;
            push @attachments, $path;
        } else {
            last;  # Non-image quoted path - stop to avoid infinite loop
        }
    }
    
    # Match @path/to/file.png - only strip if it has an image extension
    # This avoids stripping email addresses, @mentions, etc.
    while ($cleaned =~ /\s*\@(\S+\.(?:png|jpe?g|gif|webp|bmp))/i) {
        my $path = $1;
        my $full = '@' . $path;
        $cleaned =~ s/\s*\Q$full\E//;
        push @attachments, $path;
    }
    
    # Clean up extra whitespace
    $cleaned =~ s/^\s+|\s+$//g;
    $cleaned =~ s/\s{2,}/ /g;
    
    return ($cleaned, @attachments);
}

=head1 AUTHOR

CLIO Project

=head1 LICENSE

GPL-3.0

=cut

1;