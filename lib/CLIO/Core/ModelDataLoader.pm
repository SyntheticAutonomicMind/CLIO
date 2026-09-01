# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Core::ModelDataLoader;

use strict;
use warnings;
use utf8;
use Carp qw(croak);
use CLIO::Core::Logger qw(log_debug log_warning);
use CLIO::Util::JSON qw(decode_json safe_decode_json);

=head1 NAME

CLIO::Core::ModelDataLoader - Load and cache model capability data from JSON files

=head1 DESCRIPTION

Centralized loader for model capability JSON files. Provides unified access to
model families, variants, provider mappings, provider defaults, and heuristics.
Caches loaded data in memory for performance.

=head1 SYNOPSIS

    use CLIO::Core::ModelDataLoader;
    
    my $loader = CLIO::Core::ModelDataLoader->new(debug => 1);
    
    # Get model capabilities by canonical name
    my $caps = $loader->get_model_capabilities('deepseek-v4');
    
    # Get model capabilities by provider-specific ID
    my $caps = $loader->get_model_capabilities_by_provider('nvidia', 'deepseek-ai/deepseek-v4-flash');
    
    # Get provider defaults
    my $defaults = $loader->get_provider_defaults('llama.cpp');
    
    # Match heuristics for unknown models
    my $caps = $loader->match_heuristics('unknown-model-name');

=cut

=head2 new

Create a new ModelDataLoader.

Arguments:
- debug: Enable debug output (optional, default: 0)
- data_dir: Directory containing JSON files (optional, default: from ConfigPath)

=cut

sub new {
    my ($class, %args) = @_;

    my $data_dir = $args{data_dir};
    if (!$data_dir) {
        # Default to the installed module directory
        use File::Spec;
        use File::Basename;
        my $module_dir = File::Basename::dirname(__FILE__);
        $data_dir = File::Spec->catdir($module_dir, 'model-data');
        $data_dir = "/home/deck/repositories/CLIO/lib/CLIO/Core/model-data" unless -d $data_dir;
    }

    my $self = {
        debug       => $args{debug} || 0,
        data_dir    => $data_dir,
        _cache      => {},
        _loaded     => 0,
    };

    bless $self, $class;
    return $self;
}

=head2 _ensure_loaded

Load all JSON files if not already loaded.

=cut

sub _ensure_loaded {
    my ($self) = @_;
    return if $self->{_loaded};

    $self->_load_models();
    $self->_load_provider_defaults();
    $self->_load_heuristics();
    $self->_load_provider_mapping();
    
    $self->{_loaded} = 1;
    log_debug('ModelDataLoader', "Loaded all model data from $self->{data_dir}");
}

=head2 _load_file

Load a single JSON file with error handling.

=cut

sub _load_file {
    my ($self, $filename) = @_;

    my $path = "$self->{data_dir}/$filename";
    unless (-f $path) {
        log_debug('ModelDataLoader', "JSON file not found: $path");
        return {};
    }

    open my $fh, '<:encoding(UTF-8)', $path or do {
        log_debug('ModelDataLoader', "Cannot read $path: $!");
        return {};
    };

    my $content = do { local $/; <$fh> };
    close $fh;

    my $data = safe_decode_json($content);
    if ($@ || !$data) {
        log_debug('ModelDataLoader', "Failed to parse $path: $@");
        return {};
    }

    return $data;
}

# Current schema version of the model-data JSON files. Bump when the on-disk
# format changes incompatibly - older files will croak with a clear error
# pointing the user at the upgrade path.
our $SUPPORTED_DATA_VERSION = 3;

sub _check_data_version {
    my ($data, $filename) = @_;

    my $version = $data->{version};
    return unless defined $version;  # No version field - legacy file.

    if ($version > $SUPPORTED_DATA_VERSION) {
        croak "ModelDataLoader: $filename has version $version, " .
              "but this build of CLIO only supports up to version $SUPPORTED_DATA_VERSION. " .
              "The model-data JSON schema has changed incompatibly. " .
              "Please update CLIO or downgrade the data file.";
    }
}

=head2 _load_models

Load models.json with model families and standalone models.

=cut

sub _load_models {
    my ($self) = @_;
    my $data = $self->_load_file('models.json');
    $self->{_cache}{model_families}     = $data->{model_families}     || {};
    $self->{_cache}{standalone_models}  = $data->{standalone_models}  || {};
    $self->{_cache}{provider_mappings}  = $data->{provider_mappings}  || {};
    _check_data_version($data, 'models.json');
}

=head2 _load_provider_defaults

Load provider-defaults.json with provider-level fallback defaults.

=cut

sub _load_provider_defaults {
    my ($self) = @_;
    my $data = $self->_load_file('provider-defaults.json');
    $self->{_cache}{provider_defaults} = $data->{providers} || {};
    _check_data_version($data, 'provider-defaults.json');
}

=head2 _load_heuristics

Load heuristics.json with pattern-based fallback rules.

=cut

sub _load_heuristics {
    my ($self) = @_;
    my $data = $self->_load_file('heuristics.json');
    $self->{_cache}{heuristics_patterns} = $data->{patterns} || [];
    $self->{_cache}{heuristics_prefix_strip} = $data->{prefix_strip} || [];
    $self->{_cache}{heuristics_quantization_strip} = $data->{quantization_suffix_strip} || '';
    _check_data_version($data, 'heuristics.json');
}

=head2 _load_provider_mapping

Load provider-mapping.json with provider-to-model mappings.

=cut

sub _load_provider_mapping {
    my ($self) = @_;
    my $data = $self->_load_file('provider-mapping.json');
    $self->{_cache}{provider_mapping} = $data->{mappings} || {};
    _check_data_version($data, 'provider-mapping.json');
}

=head2 get_model_capabilities

Get capabilities for a model by canonical name (family or variant).

Arguments:
- $model: Canonical model name (e.g., 'deepseek-v4', 'deepseek-v4-flash')

Returns:
- Hashref with capability data, or undef if not found

=cut

sub get_model_capabilities {
    my ($self, $model) = @_;
    return undef unless $model;
    
    $self->_ensure_loaded();
    
    # Try exact match in model families
    if (my $family = $self->{_cache}{model_families}{$model}) {
        return $self->_build_caps_from_family($model, $family->{base}, {});
    }
    
    # Try exact match in standalone models
    if (my $standalone = $self->{_cache}{standalone_models}{$model}) {
        return $standalone;
    }
    
    # Try case-insensitive match in standalone models
    my $lc_model = lc($model);
    for my $standalone_name (keys %{$self->{_cache}{standalone_models}}) {
        if (lc($standalone_name) eq $lc_model) {
            return $self->{_cache}{standalone_models}{$standalone_name};
        }
    }
    
    # Try variant match across all families
    for my $family_name (keys %{$self->{_cache}{model_families}}) {
        my $family = $self->{_cache}{model_families}{$family_name};
        if (my $variant = $family->{variants}{$model}) {
            return $self->_build_caps_from_family($model, $family->{base}, $variant);
        }
    }
    
    return undef;
}

=head2 _build_caps_from_family

Build capabilities hash from family base + variant overrides.

=cut

sub _build_caps_from_family {
    my ($self, $model, $base, $variant) = @_;
    
    my $caps = { %$base };
    $caps = { %$caps, %$variant } if %$variant;
    $caps->{model} = $model;
    return $caps;
}

=head2 get_model_capabilities_by_provider

Get capabilities for a model by provider-specific ID.

Arguments:
- $provider: Provider name (e.g., 'nvidia', 'deepseek', 'llama.cpp')
- $model_id: Provider-specific model ID (e.g., 'deepseek-ai/deepseek-v4-flash')

Returns:
- Hashref with capability data, or undef if not found

=cut

sub get_model_capabilities_by_provider {
    my ($self, $provider, $model_id) = @_;
    return undef unless $provider && $model_id;
    
    $self->_ensure_loaded();
    
    my $mapping = $self->{_cache}{provider_mappings}{$provider};
    return undef unless $mapping;
    
    # Normalize the model ID based on provider's format
    my $canonical = $self->_normalize_model_id($model_id, $mapping->{model_id_format});
    return undef unless $canonical;
    
    # Try to find in our model database
    return $self->get_model_capabilities($canonical);
}

=head2 _normalize_model_id

Normalize a provider-specific model ID to canonical form.

=cut

sub _normalize_model_id {
    my ($self, $model_id, $format) = @_;
    
    return $model_id unless $format;
    
    if ($format eq 'basename') {
        # llama.cpp: strip path and .gguf extension, then try to match
        # against known model family/variant names
        my $base = $model_id;
        $base =~ s{.*/}{};
        $base =~ s{\.gguf$}{}i;
        
        # Try to match against known canonical names
        my $canonical = $self->_match_canonical_name($base);
        return $canonical if $canonical;
        
        return $base;
    }
    elsif ($format eq 'org/model') {
        # NVIDIA: strip org/ prefix to get canonical name
        my $base = $model_id;
        $base =~ s{^[^/]+/}{};
        
        # Try to match against known canonical names
        my $canonical = $self->_match_canonical_name($base);
        return $canonical if $canonical;
        
        return $base;
    }
    elsif ($format eq 'model') {
        # DeepSeek, MiniMax, Z.AI: use as-is
        return $model_id;
    }
    elsif ($format eq 'provider/model') {
        # OpenRouter: strip provider prefix
        my $base = $model_id;
        $base =~ s{^[^/]+/}{};
        return $base;
    }
    elsif ($format eq 'model:tag') {
        # Ollama Cloud: strip :tag suffix
        $model_id =~ s{:.*$}{};
        return $model_id;
    }
    
    return $model_id;
}

=head2 _match_canonical_name

Try to match a model name against known canonical names in the database.

=cut

sub _match_canonical_name {
    my ($self, $name) = @_;
    
    # First try exact match in families
    return $name if exists $self->{_cache}{model_families}{$name};
    
    # Try exact match in standalone models
    return $name if exists $self->{_cache}{standalone_models}{$name};
    
    # Try exact match in family variants
    for my $family_name (keys %{$self->{_cache}{model_families}}) {
        my $family = $self->{_cache}{model_families}{$family_name};
        next unless $family->{variants};
        return $name if exists $family->{variants}{$name};
    }
    
    # Try case-insensitive match
    my $lc_name = lc($name);
    for my $family_name (keys %{$self->{_cache}{model_families}}) {
        my $family = $self->{_cache}{model_families}{$family_name};
        return $family_name if lc($family_name) eq $lc_name;
        next unless $family->{variants};
        for my $variant (keys %{$family->{variants}}) {
            return $variant if lc($variant) eq $lc_name;
        }
    }
    
    for my $standalone (keys %{$self->{_cache}{standalone_models}}) {
        return $standalone if lc($standalone) eq $lc_name;
    }
    
    # Try fuzzy matching: check if canonical name is a substring
    # (e.g., "deepseek-v4-flash" in "DeepSeek-V4-Flash-0731-UD-IQ3_XXS-1-of-4")
    for my $family_name (keys %{$self->{_cache}{model_families}}) {
        my $family = $self->{_cache}{model_families}{$family_name};
        if ($lc_name =~ /\Q$family_name\E/i) {
            return $family_name;
        }
        next unless $family->{variants};
        for my $variant (keys %{$family->{variants}}) {
            if ($lc_name =~ /\Q$variant\E/i) {
                return $variant;
            }
        }
    }
    
    for my $standalone (keys %{$self->{_cache}{standalone_models}}) {
        if ($lc_name =~ /\Q$standalone\E/i) {
            return $standalone;
        }
    }
    
    return undef;
}

=head2 get_provider_defaults

Get provider-level fallback defaults.

Arguments:
- $provider: Provider name (e.g., 'openai', 'llama.cpp')

Returns:
- Hashref with provider defaults, or undef if not found

=cut

sub get_provider_defaults {
    my ($self, $provider) = @_;
    return undef unless $provider;
    
    $self->_ensure_loaded();
    return $self->{_cache}{provider_defaults}{$provider};
}

=head2 match_heuristics

Match a model name against heuristic patterns.

Arguments:
- $model: Model identifier to match

Returns:
- Hashref with inferred capabilities, or undef if no pattern matches

=cut

sub match_heuristics {
    my ($self, $model) = @_;
    return undef unless $model;
    
    $self->_ensure_loaded();
    
    # Normalize the model name
    my $normalized = $model;
    $normalized =~ s{^\Q$_\E/}{} for @{$self->{_cache}{heuristics_prefix_strip}};
    $normalized =~ s{$self->{_cache}{heuristics_quantization_strip}}{}i 
        if $self->{_cache}{heuristics_quantization_strip};
    
    my $best_match = undef;
    my $best_priority = -1;
    
    for my $pattern (@{$self->{_cache}{heuristics_patterns}}) {
        if ($normalized =~ /$pattern->{pattern}/i) {
            if ($pattern->{priority} > $best_priority) {
                $best_priority = $pattern->{priority};
                $best_match = $pattern->{capabilities};
            }
        }
    }
    
    if ($best_match) {
        log_debug('ModelDataLoader', "Heuristic match for $model: " . ($best_match->{reasoning_mode} // 'none') . " (priority $best_priority)");
        return $best_match;
    }
    
    return undef;
}

=head2 list_all_models

Get list of all known model names.

Returns:
- Arrayref of model names

=cut

sub list_all_models {
    my ($self) = @_;
    $self->_ensure_loaded();
    
    my @models;
    
    for my $family_name (keys %{$self->{_cache}{model_families}}) {
        push @models, $family_name;
        my $family = $self->{_cache}{model_families}{$family_name};
        push @models, keys %{$family->{variants}} if $family->{variants};
    }
    
    push @models, keys %{$self->{_cache}{standalone_models}};
    
    return \@models;
}

=head2 reload

Force reload all JSON files (clears cache and reloads).

=cut

sub reload {
    my ($self) = @_;
    $self->{_cache} = {};
    $self->{_loaded} = 0;
    $self->_ensure_loaded();
}

1;

=head1 SEE ALSO

L<CLIO::Core::ModelCapabilitiesManager>, L<CLIO::Core::Defaults>

=cut