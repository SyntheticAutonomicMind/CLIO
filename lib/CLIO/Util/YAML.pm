# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Util::YAML;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Carp qw(croak);
use Exporter qw(import);

our @EXPORT_OK = qw(yaml_load yaml_load_file yaml_dump);

=head1 NAME

CLIO::Util::YAML - Lightweight YAML parser for OpenSpec config files

=head1 DESCRIPTION

Minimal YAML parser that handles the subset used by OpenSpec config and
schema files: key-value pairs, arrays, multiline strings (block scalars),
and simple nested mappings. No CPAN dependency required.

Supported features:
- Scalar values (strings, numbers, booleans)
- Block scalar literals (|)
- Sequence arrays (- item)
- Nested mappings (one level)
- Comments (#)

Not supported (not needed for OpenSpec):
- Anchors/aliases (&, *)
- Flow collections ({}, [])
- Multi-document (---)
- Complex nesting beyond 2 levels
- Tags (!!)

=head1 SYNOPSIS

    use CLIO::Util::YAML qw(yaml_load yaml_load_file yaml_dump);

    my $data = yaml_load_file('openspec/config.yaml');
    my $data = yaml_load($yaml_string);
    my $yaml = yaml_dump($hashref);

=cut

=head2 yaml_load($string)

Parse a YAML string into a Perl data structure (hashref).

=cut

sub yaml_load {
    my ($text) = @_;
    croak "yaml_load requires a string argument" unless defined $text;

    my @lines = split /\n/, $text;
    my $result = {};

    my $i = 0;
    while ($i < scalar @lines) {
        my $line = $lines[$i];

        # Skip blank lines and comments
        if ($line =~ /^\s*$/ || $line =~ /^\s*#/) {
            $i++;
            next;
        }

        # Skip document markers
        if ($line =~ /^---\s*$/ || $line =~ /^\.\.\.\s*$/) {
            $i++;
            next;
        }

        # Top-level key-value
        if ($line =~ /^(\w[\w\-]*):\s*(.*)$/) {
            my ($key, $value) = ($1, $2);
            $value =~ s/\s*#.*$// if defined $value;  # strip inline comments

            if ($value eq '' || $value eq '~' || $value eq 'null') {
                # Could be a nested mapping or null
                # Peek at next line to see if it's indented
                if ($i + 1 < scalar @lines && $lines[$i + 1] =~ /^\s+/) {
                    # Check if next line starts a sequence
                    if ($lines[$i + 1] =~ /^\s+-\s/) {
                        ($result->{$key}, $i) = _parse_sequence(\@lines, $i + 1);
                    } else {
                        ($result->{$key}, $i) = _parse_mapping(\@lines, $i + 1);
                    }
                } else {
                    $result->{$key} = undef;
                    $i++;
                }
            }
            elsif ($value eq '|' || $value eq '|+' || $value eq '|-') {
                # Block scalar
                my $chomp = $value;
                ($result->{$key}, $i) = _parse_block_scalar(\@lines, $i + 1, $chomp);
            }
            elsif ($value eq '>' || $value eq '>+' || $value eq '>-') {
                # Folded scalar (treat as block for our purposes)
                my $chomp = $value;
                ($result->{$key}, $i) = _parse_folded_scalar(\@lines, $i + 1, $chomp);
            }
            elsif ($value =~ /^\[/) {
                # Inline array: [item1, item2]
                $result->{$key} = _parse_inline_array($value);
                $i++;
            }
            else {
                $result->{$key} = _parse_scalar($value);
                $i++;
            }
        }
        else {
            # Unknown line format, skip
            $i++;
        }
    }

    return $result;
}

=head2 yaml_load_file($path)

Load and parse a YAML file.

=cut

sub yaml_load_file {
    my ($path) = @_;
    croak "yaml_load_file requires a file path" unless defined $path;
    croak "YAML file not found: $path" unless -f $path;

    open my $fh, '<:encoding(UTF-8)', $path
        or croak "Cannot read YAML file $path: $!";
    my $content = do { local $/; <$fh> };
    close $fh;

    return yaml_load($content);
}

=head2 yaml_dump($hashref)

Dump a simple hashref to YAML string. Handles scalars, arrays, and
one level of nested hashes.

=cut

sub yaml_dump {
    my ($data) = @_;
    croak "yaml_dump requires a hashref" unless ref $data eq 'HASH';

    my @lines;
    for my $key (sort keys %$data) {
        my $val = $data->{$key};

        if (!defined $val) {
            push @lines, "$key:";
        }
        elsif (ref $val eq 'ARRAY') {
            if (@$val == 0) {
                push @lines, "$key: []";
            } else {
                push @lines, "$key:";
                for my $item (@$val) {
                    if (ref $item eq 'HASH') {
                        # Array of hashes - inline the first key, indent rest
                        my @keys = sort keys %$item;
                        if (@keys) {
                            push @lines, "  - $keys[0]: " . _dump_scalar($item->{$keys[0]});
                            for my $k (@keys[1..$#keys]) {
                                push @lines, "    $k: " . _dump_scalar($item->{$k});
                            }
                        }
                    } else {
                        push @lines, "  - " . _dump_scalar($item);
                    }
                }
            }
        }
        elsif (ref $val eq 'HASH') {
            push @lines, "$key:";
            for my $k (sort keys %$val) {
                my $v = $val->{$k};
                if (ref $v eq 'ARRAY') {
                    push @lines, "  $k:";
                    for my $item (@$v) {
                        push @lines, "    - " . _dump_scalar($item);
                    }
                } else {
                    push @lines, "  $k: " . _dump_scalar($v);
                }
            }
        }
        elsif ($val =~ /\n/) {
            # Multiline string - use block scalar
            push @lines, "$key: |";
            for my $vline (split /\n/, $val) {
                push @lines, "  $vline";
            }
        }
        else {
            push @lines, "$key: " . _dump_scalar($val);
        }
    }

    return join("\n", @lines) . "\n";
}

# --- Internal parsing functions ---

sub _parse_scalar {
    my ($val) = @_;
    return undef if !defined $val || $val eq '~' || $val eq 'null';
    return 1 if $val eq 'true' || $val eq 'True' || $val eq 'TRUE';
    return 0 if $val eq 'false' || $val eq 'False' || $val eq 'FALSE';

    # Quoted string
    if ($val =~ /^"(.*)"$/) {
        my $s = $1;
        $s =~ s/\\n/\n/g;
        $s =~ s/\\t/\t/g;
        $s =~ s/\\"/"/g;
        $s =~ s/\\\\/\\/g;
        return $s;
    }
    if ($val =~ /^'(.*)'$/) {
        return $1;
    }

    # Number
    return $val + 0 if $val =~ /^-?\d+(\.\d+)?$/;

    # Plain string (strip trailing whitespace)
    $val =~ s/\s+$//;
    return $val;
}

sub _parse_block_scalar {
    my ($lines, $start, $chomp) = @_;
    my @content;

    # Determine indent of first content line
    my $indent;
    for (my $j = $start; $j < scalar @$lines; $j++) {
        if ($lines->[$j] =~ /^(\s+)\S/) {
            $indent = length($1);
            last;
        }
        last if $lines->[$j] =~ /^\S/;  # unindented = end of block
    }

    return ('', $start) unless defined $indent;

    my $i = $start;
    while ($i < scalar @$lines) {
        my $line = $lines->[$i];

        # Blank line within block
        if ($line =~ /^\s*$/) {
            push @content, '';
            $i++;
            next;
        }

        # Check indent
        if ($line =~ /^(\s+)/) {
            if (length($1) >= $indent) {
                push @content, substr($line, $indent);
                $i++;
                next;
            }
        }

        # Line not indented enough - end of block
        last;
    }

    # Handle chomping
    my $text = join("\n", @content);
    if ($chomp eq '|-') {
        $text =~ s/\n+$//;
    } elsif ($chomp eq '|+') {
        $text .= "\n" if @content && $content[-1] ne '';
    } else {
        # Default: single trailing newline
        $text =~ s/\n+$/\n/;
    }

    return ($text, $i);
}

sub _parse_folded_scalar {
    my ($lines, $start, $chomp) = @_;
    # For our purposes, treat folded same as literal
    return _parse_block_scalar($lines, $start, $chomp =~ s/>/|/r);
}

sub _parse_sequence {
    my ($lines, $start) = @_;
    my @items;

    # Determine the sequence indent level from the first item
    my $seq_indent;
    for (my $j = $start; $j < scalar @$lines; $j++) {
        if ($lines->[$j] =~ /^(\s+)-\s/) {
            $seq_indent = length($1);
            last;
        }
        last if $lines->[$j] =~ /^\S/;
    }
    return ([], $start) unless defined $seq_indent;

    my $i = $start;
    while ($i < scalar @$lines) {
        my $line = $lines->[$i];

        # Skip blank lines
        if ($line =~ /^\s*$/) {
            $i++;
            next;
        }

        # Skip comments
        if ($line =~ /^\s*#/) {
            $i++;
            next;
        }

        # Sequence item at our indent level
        if ($line =~ /^(\s+)-\s+(.*)$/ && length($1) == $seq_indent) {
            my ($indent_str, $value) = ($1, $2);

            # Check if this is a mapping item (key: value after -)
            if ($value =~ /^(\w[\w\-]*):\s*(.*)$/) {
                my ($key, $val) = ($1, $2);
                $val =~ s/\s*#.*$// if defined $val;  # strip inline comments
                my $item = {};

                # Item keys are indented to: seq_indent + 2 (for "- ") or more
                my $item_indent = $seq_indent + 2;

                # Handle block scalar as first value
                if ($val eq '|' || $val eq '|+' || $val eq '|-') {
                    ($item->{$key}, $i) = _parse_block_scalar($lines, $i + 1, $val);
                }
                elsif ($val =~ /^\[/) {
                    $item->{$key} = _parse_inline_array($val);
                    $i++;
                }
                elsif ($val eq '' || $val eq '~') {
                    # Could be nested sequence or mapping
                    if ($i + 1 < scalar @$lines) {
                        my $peek = $lines->[$i + 1];
                        if ($peek =~ /^(\s+)-\s/ && length($1) > $seq_indent) {
                            ($item->{$key}, $i) = _parse_sequence($lines, $i + 1);
                        } elsif ($peek =~ /^(\s+)\w/ && length($1) > $seq_indent + 2) {
                            ($item->{$key}, $i) = _parse_mapping($lines, $i + 1);
                        } else {
                            $item->{$key} = undef;
                            $i++;
                        }
                    } else {
                        $item->{$key} = undef;
                        $i++;
                    }
                }
                else {
                    $item->{$key} = _parse_scalar($val);
                    $i++;
                }

                # Read continuation keys at item indent level
                while ($i < scalar @$lines) {
                    my $next = $lines->[$i];

                    # Skip blank lines within the item
                    if ($next =~ /^\s*$/) {
                        # Peek ahead - if next non-blank is still our item, continue
                        my $peek = $i + 1;
                        while ($peek < scalar @$lines && $lines->[$peek] =~ /^\s*$/) { $peek++ }
                        if ($peek < scalar @$lines && $lines->[$peek] =~ /^(\s+)\w/ && length($1) >= $item_indent) {
                            $i++;
                            next;
                        }
                        last;
                    }

                    # Comment at item indent
                    if ($next =~ /^\s*#/) {
                        $i++;
                        next;
                    }

                    if ($next =~ /^(\s+)(\w[\w\-]*):\s*(.*)$/ && length($1) >= $item_indent) {
                        my ($k, $v) = ($2, $3);
                        $v =~ s/\s*#.*$// if defined $v;

                        if ($v eq '|' || $v eq '|+' || $v eq '|-') {
                            ($item->{$k}, $i) = _parse_block_scalar($lines, $i + 1, $v);
                        }
                        elsif ($v =~ /^\[/) {
                            $item->{$k} = _parse_inline_array($v);
                            $i++;
                        }
                        elsif ($v eq '' || $v eq '~') {
                            if ($i + 1 < scalar @$lines && $lines->[$i + 1] =~ /^(\s+)-\s/ && length($1) >= $item_indent + 2) {
                                ($item->{$k}, $i) = _parse_sequence($lines, $i + 1);
                            } else {
                                $item->{$k} = undef;
                                $i++;
                            }
                        }
                        else {
                            $item->{$k} = _parse_scalar($v);
                            $i++;
                        }
                    }
                    else {
                        # Not a continuation - end of this item
                        last;
                    }
                }
                push @items, $item;
            }
            else {
                push @items, _parse_scalar($value);
                $i++;
            }
        }
        elsif ($line =~ /^\S/ || ($line =~ /^(\s+)/ && length($1) < $seq_indent)) {
            # Unindented or less indented - end of sequence
            last;
        }
        else {
            $i++;
        }
    }

    return (\@items, $i);
}

sub _parse_mapping {
    my ($lines, $start) = @_;
    my $result = {};

    # Determine indent level
    my $indent;
    if ($start < scalar @$lines && $lines->[$start] =~ /^(\s+)/) {
        $indent = length($1);
    }
    return ($result, $start) unless defined $indent;

    my $i = $start;
    while ($i < scalar @$lines) {
        my $line = $lines->[$i];

        # Skip blank lines and comments
        if ($line =~ /^\s*$/ || $line =~ /^\s*#/) {
            $i++;
            next;
        }

        # Check indent
        if ($line =~ /^(\s+)(\w[\w\-]*):\s*(.*)$/) {
            my ($ind, $key, $value) = ($1, $2, $3);

            if (length($ind) < $indent) {
                # Dedented - end of mapping
                last;
            }
            if (length($ind) == $indent) {
                $value =~ s/\s*#.*$// if defined $value;

                if ($value eq '' || $value eq '~') {
                    # Could be nested - peek
                    if ($i + 1 < scalar @$lines && $lines->[$i + 1] =~ /^\s+-\s/) {
                        ($result->{$key}, $i) = _parse_sequence($lines, $i + 1);
                    } elsif ($i + 1 < scalar @$lines && $lines->[$i + 1] =~ /^(\s+)/ && length($1) > $indent) {
                        ($result->{$key}, $i) = _parse_mapping($lines, $i + 1);
                    } else {
                        $result->{$key} = undef;
                        $i++;
                    }
                }
                elsif ($value eq '|' || $value eq '|+' || $value eq '|-') {
                    ($result->{$key}, $i) = _parse_block_scalar($lines, $i + 1, $value);
                }
                elsif ($value =~ /^\[/) {
                    $result->{$key} = _parse_inline_array($value);
                    $i++;
                }
                else {
                    $result->{$key} = _parse_scalar($value);
                    $i++;
                }
            }
            else {
                # More indented than expected
                last;
            }
        }
        elsif ($line =~ /^\S/) {
            # Unindented - end of mapping
            last;
        }
        else {
            $i++;
        }
    }

    return ($result, $i);
}

sub _parse_inline_array {
    my ($text) = @_;
    # [item1, item2, "item 3"]
    $text =~ s/^\[\s*//;
    $text =~ s/\s*\]$//;
    return [] if $text eq '';

    my @items;
    while ($text =~ /\S/) {
        if ($text =~ s/^"([^"]*)"(?:\s*,\s*)?//) {
            push @items, $1;
        }
        elsif ($text =~ s/^'([^']*)'(?:\s*,\s*)?//) {
            push @items, $1;
        }
        elsif ($text =~ s/^([^,\]]+)(?:\s*,\s*)?//) {
            my $v = $1;
            $v =~ s/\s+$//;
            push @items, _parse_scalar($v);
        }
        else {
            last;
        }
    }
    return \@items;
}

sub _dump_scalar {
    my ($val) = @_;
    return '~' unless defined $val;
    return '"' . $val . '"' if $val =~ /[:#\[\]{},&*!|>'"%@`\n]/ || $val =~ /^\s/ || $val =~ /\s$/;
    return $val;
}

=head1 POD

=head2 Limitations

This parser handles the YAML subset used by OpenSpec configuration files.
It is not a general-purpose YAML parser. For full YAML support, use
YAML::XS or YAML::PP from CPAN.

=cut

1;
