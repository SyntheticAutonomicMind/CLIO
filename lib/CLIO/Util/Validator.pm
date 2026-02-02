package CLIO::Util::Validator;

use strict;
use warnings;
use utf8;

=head1 NAME

CLIO::Util::Validator - Centralized input validation for CLIO settings

=head1 DESCRIPTION

Provides reusable validators for API settings, config values, and other user inputs.
All validators return (is_valid, error_message) to enable clear user feedback.

=head1 SYNOPSIS

  use CLIO::Util::Validator;
  
  my ($valid, $msg) = CLIO::Util::Validator::validate_model('gpt-4o');
  unless ($valid) {
      print "Error: $msg\n";
  }

=cut

=head2 validate_model

Validate that a model name exists in the model registry.

Arguments:
  - model_id: Model identifier (e.g., 'gpt-4o')
  - registry: Optional ModelRegistry instance (will create default if not provided)

Returns:
  - (1, '') if valid
  - (0, error_message) if invalid

=cut

sub validate_model {
    my ($model_id, $registry) = @_;
    
    unless (defined $model_id && length($model_id)) {
        return (0, "Model name cannot be empty");
    }
    
    # Create default registry if not provided
    unless ($registry) {
        require CLIO::Core::ModelRegistry;
        $registry = CLIO::Core::ModelRegistry->new();
    }
    
    my $model_info = $registry->get_model_info($model_id);
    if ($model_info) {
        return (1, '');
    }
    
    return (0, "Model '$model_id' not found. Use '/api models' to see available models.");
}

=head2 validate_provider

Validate that a provider exists.

Arguments:
  - provider_name: Provider identifier (e.g., 'openai')

Returns:
  - (1, '') if valid
  - (0, error_message) if invalid

=cut

sub validate_provider {
    my ($provider_name) = @_;
    
    unless (defined $provider_name && length($provider_name)) {
        return (0, "Provider name cannot be empty");
    }
    
    require CLIO::Providers;
    if (CLIO::Providers::provider_exists($provider_name)) {
        return (1, '');
    }
    
    my @providers = CLIO::Providers::list_providers();
    my $providers_str = join(', ', sort @providers);
    return (0, "Provider '$provider_name' not found. Available: $providers_str");
}

=head2 validate_search_engine

Validate search engine selection.

Arguments:
  - engine_name: Search engine name (e.g., 'google')

Returns:
  - (1, '') if valid
  - (0, error_message) if invalid

=cut

sub validate_search_engine {
    my ($engine_name) = @_;
    
    unless (defined $engine_name && length($engine_name)) {
        return (0, "Search engine name cannot be empty");
    }
    
    my @valid_engines = qw(google bing duckduckgo);
    $engine_name = lc($engine_name);
    
    if (grep { $_ eq $engine_name } @valid_engines) {
        return (1, '');
    }
    
    return (0, "Invalid search engine '$engine_name'. Valid options: " . join(', ', @valid_engines));
}

=head2 validate_search_provider

Validate search provider selection.

Arguments:
  - provider_name: Search provider (e.g., 'serpapi')

Returns:
  - (1, '') if valid
  - (0, error_message) if invalid

=cut

sub validate_search_provider {
    my ($provider_name) = @_;
    
    unless (defined $provider_name && length($provider_name)) {
        return (0, "Search provider name cannot be empty");
    }
    
    my @valid_providers = qw(serpapi duckduckgo);
    $provider_name = lc($provider_name);
    
    if (grep { $_ eq $provider_name } @valid_providers) {
        return (1, '');
    }
    
    return (0, "Invalid search provider '$provider_name'. Valid options: " . join(', ', @valid_providers));
}

=head2 validate_url

Validate that a string is a reasonable URL.

Arguments:
  - url: URL string to validate

Returns:
  - (1, '') if valid
  - (0, error_message) if invalid

=cut

sub validate_url {
    my ($url) = @_;
    
    unless (defined $url && length($url)) {
        return (0, "URL cannot be empty");
    }
    
    # Basic URL validation: must contain :// and not have spaces
    if ($url =~ m{^https?://[^\s]+$}) {
        return (1, '');
    }
    
    # Also allow other schemes like ws://, wss://
    if ($url =~ m{^[a-z][a-z0-9+\-.]*://[^\s]+$}) {
        return (1, '');
    }
    
    return (0, "Invalid URL format: '$url'. Must be a valid URL (e.g., http://example.com)");
}

=head2 validate_api_key

Validate that an API key meets basic requirements.

Arguments:
  - key: API key string to validate
  - min_length: Minimum length (default: 8)

Returns:
  - (1, '') if valid
  - (0, error_message) if invalid

=cut

sub validate_api_key {
    my ($key, $min_length) = @_;
    $min_length ||= 8;
    
    unless (defined $key && length($key)) {
        return (0, "API key cannot be empty");
    }
    
    if (length($key) < $min_length) {
        return (0, "API key too short (minimum $min_length characters)");
    }
    
    # Reject keys with only whitespace or suspicious characters
    if ($key =~ /^\s+$/) {
        return (0, "API key cannot be only whitespace");
    }
    
    return (1, '');
}

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

1;
