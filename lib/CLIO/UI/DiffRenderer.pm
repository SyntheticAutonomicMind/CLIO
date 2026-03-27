# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::UI::DiffRenderer;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

=head1 NAME

CLIO::UI::DiffRenderer - Render unified diffs with color for file changes

=head1 DESCRIPTION

Generates and displays compact, colorized unified diffs showing file
modifications made by tool operations. Uses Algorithm::Diff if available,
falls back to the system diff command.

=head1 SYNOPSIS

    use CLIO::UI::DiffRenderer;
    
    my $renderer = CLIO::UI::DiffRenderer->new(theme_mgr => $theme, ansi => $ansi);
    my $diff_text = $renderer->generate_diff($old_content, $new_content, $filename);
    $renderer->display_diff($diff_text);

=cut

sub new {
    my ($class, %args) = @_;
    return bless {
        theme_mgr   => $args{theme_mgr},
        ansi        => $args{ansi},
        max_lines   => $args{max_lines} || 20,
        context     => $args{context} || 3,
    }, $class;
}

=head2 generate_diff($old, $new, $filename)

Generate a unified diff between old and new content.
Returns arrayref of diff lines (without ANSI colors).

=cut

sub generate_diff {
    my ($self, $old, $new, $filename) = @_;
    $old //= '';
    $new //= '';
    $filename //= 'file';
    
    # Use system diff
    my @diff_lines;
    eval {
        use File::Temp qw(tempfile);
        my ($fh_old, $tmp_old) = tempfile(UNLINK => 1);
        my ($fh_new, $tmp_new) = tempfile(UNLINK => 1);
        binmode($fh_old, ':encoding(UTF-8)');
        binmode($fh_new, ':encoding(UTF-8)');
        print $fh_old $old;
        print $fh_new $new;
        close $fh_old;
        close $fh_new;
        
        my $ctx = $self->{context};
        my $diff_output = `diff -u -U$ctx "$tmp_old" "$tmp_new" 2>/dev/null`;
        @diff_lines = split /\n/, $diff_output;
        
        # Replace temp file names with actual filename
        if (@diff_lines >= 2) {
            $diff_lines[0] = "--- a/$filename";
            $diff_lines[1] = "+++ b/$filename";
        }
    };
    
    return \@diff_lines;
}

=head2 format_diff($diff_lines)

Format diff lines with ANSI colors for display.
Returns a single string ready for printing.

=cut

sub format_diff {
    my ($self, $diff_lines) = @_;
    return '' unless $diff_lines && @$diff_lines;
    
    my @output;
    my $line_count = 0;
    my $truncated = 0;
    
    for my $line (@$diff_lines) {
        # Skip the --- / +++ header lines (we show filename separately)
        next if $line =~ /^---\s/ || $line =~ /^\+\+\+\s/;
        
        if ($line_count >= $self->{max_lines}) {
            $truncated = scalar(@$diff_lines) - $line_count;
            last;
        }
        
        if ($line =~ /^@@/) {
            # Hunk header - dim
            push @output, $self->_colorize($line, 'DIM');
        } elsif ($line =~ /^\+/) {
            # Addition - green
            push @output, $self->_colorize($line, 'GREEN');
        } elsif ($line =~ /^-/) {
            # Deletion - red
            push @output, $self->_colorize($line, 'RED');
        } else {
            # Context - dim
            push @output, $self->_colorize($line, 'DIM');
        }
        $line_count++;
    }
    
    if ($truncated > 0) {
        push @output, $self->_colorize("  ... ($truncated more lines)", 'DIM');
    }
    
    return join("\n", @output);
}

=head2 display_diff($old, $new, $filename)

Generate and display a colorized diff inline.

=cut

sub display_diff {
    my ($self, $old, $new, $filename) = @_;
    
    my $diff_lines = $self->generate_diff($old, $new, $filename);
    return unless $diff_lines && @$diff_lines > 2;  # Skip if only headers (no actual changes)
    
    my $formatted = $self->format_diff($diff_lines);
    return unless $formatted;
    
    print $formatted, "\n";
}

sub _colorize {
    my ($self, $text, $color_name) = @_;
    
    if ($self->{ansi}) {
        my $code = $self->{ansi}->parse("\@${color_name}\@");
        my $reset = $self->{ansi}->parse('@RESET@');
        return "    ${code}${text}${reset}";
    }
    return "    $text";
}

1;
