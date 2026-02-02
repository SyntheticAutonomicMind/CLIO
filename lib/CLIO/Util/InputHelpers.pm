package CLIO::Util::InputHelpers;

use strict;
use warnings;
use utf8;

=head1 NAME

CLIO::Util::InputHelpers - Generic input validation helpers

=head1 DESCRIPTION

Provides reusable validators for generic input patterns that appear
across multiple parts of CLIO. Specific validators stay in their
authority modules (ModelRegistry, Providers, Theme, etc.).

=head1 SYNOPSIS

  use CLIO::Util::InputHelpers;
  
  my ($valid, $msg) = CLIO::Util::InputHelpers::validate_enum($value, \@options);
  my ($valid, $path) = CLIO::Util::InputHelpers::validate_directory($path);

=cut

=head2 validate_enum

Validate a value against a list of valid options.

Arguments:
  - value: Value to validate
  - valid_options: Arrayref of valid strings
  - case_insensitive: Optional, default true

Returns:
  - (1, normalized_value) if valid (normalized to match case in list)
  - (0, error_message) if invalid

=cut

sub validate_enum {
    my ($value, $valid_options, $case_insensitive) = @_;
    $case_insensitive = 1 unless defined $case_insensitive;
    
    unless (defined $value && length($value)) {
        return (0, "Value cannot be empty");
    }
    
    unless ($valid_options && ref($valid_options) eq 'ARRAY' && @$valid_options) {
        return (0, "No valid options provided");
    }
    
    # Check exact match first
    for my $option (@$valid_options) {
        if ($option eq $value) {
            return (1, $option);
        }
    }
    
    # Check case-insensitive match if enabled
    if ($case_insensitive) {
        my $lc_value = lc($value);
        for my $option (@$valid_options) {
            if (lc($option) eq $lc_value) {
                return (1, $option);
            }
        }
    }
    
    my $options_str = join(', ', @$valid_options);
    return (0, "Invalid option '$value'. Valid options: $options_str");
}

=head2 validate_integer

Validate a value is a positive integer within optional bounds.

Arguments:
  - value: Value to validate
  - min: Minimum value (optional)
  - max: Maximum value (optional)

Returns:
  - (1, normalized_int) if valid
  - (0, error_message) if invalid

=cut

sub validate_integer {
    my ($value, $min, $max) = @_;
    
    unless (defined $value && length($value)) {
        return (0, "Value cannot be empty");
    }
    
    if ($value !~ /^-?\d+$/) {
        return (0, "'$value' is not an integer");
    }
    
    my $int_value = int($value);
    
    if (defined $min && $int_value < $min) {
        return (0, "Value $int_value is less than minimum $min");
    }
    
    if (defined $max && $int_value > $max) {
        return (0, "Value $int_value is greater than maximum $max");
    }
    
    return (1, $int_value);
}

=head2 validate_directory

Validate that a directory path is valid and accessible.

Arguments:
  - path: Directory path to validate
  - must_exist: If true, directory must already exist (default: true)
  - writable: If true, directory must be writable (default: false)

Returns:
  - (1, absolute_path) if valid
  - (0, error_message) if invalid

=cut

sub validate_directory {
    my ($path, $must_exist, $writable) = @_;
    $must_exist = 1 unless defined $must_exist;
    $writable = 0 unless defined $writable;
    
    unless (defined $path && length($path)) {
        return (0, "Directory path cannot be empty");
    }
    
    # Expand ~ to home directory
    if ($path =~ /^~/) {
        require File::Glob;
        my @expanded = File::Glob::bsd_glob($path);
        if (@expanded) {
            $path = $expanded[0];
        } else {
            return (0, "Could not expand path: $path");
        }
    }
    
    # Get absolute path
    require Cwd;
    my $abs_path = Cwd::abs_path($path);
    
    # Check if directory exists
    if (-d $abs_path) {
        # Directory exists - check if writable if requested
        if ($writable && !-w $abs_path) {
            return (0, "Directory '$path' exists but is not writable");
        }
        return (1, $abs_path);
    }
    
    # Directory doesn't exist
    if ($must_exist) {
        return (0, "Directory '$path' does not exist");
    }
    
    # If we don't require it to exist, check that parent exists and is writable
    my $parent = $path;
    $parent =~ s{/[^/]*$}{};
    $parent = '.' if $parent eq '';
    
    if (-d $parent && -w $parent) {
        return (1, $path);
    }
    
    return (0, "Parent directory of '$path' does not exist or is not writable");
}

1;
