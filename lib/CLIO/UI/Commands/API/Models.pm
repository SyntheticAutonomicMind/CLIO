# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::UI::Commands::API::Models;

use strict;
use warnings;
use utf8;
use parent 'CLIO::UI::Commands::Base';
use CLIO::UI::Terminal qw(box_char);

use Carp qw(croak);
use CLIO::Core::Logger qw(log_debug log_warning);
use CLIO::Util::JSON qw(decode_json);

# Format token counts for display (e.g., 204800 -> "205k", 1000000 -> "1.0M")
sub _format_tokens {
    my ($tokens) = @_;
    return 'N/A' unless defined $tokens && $tokens > 0;
    if ($tokens >= 1_000_000) {
        return sprintf("%.1fM", $tokens / 1_000_000);
    }
    elsif ($tokens >= 1000) {
        my $k = $tokens / 1000;
        return $k == int($k) ? int($k) . "k" : sprintf("%.1fk", $k);
    }
    return $tokens;
}

# Lazy-loaded MCM instance for capability lookups in display methods
my $_mcm_instance;

sub _get_mcm_capabilities {
    my ($self, $provider_name, $model_id) = @_;
    
    return undef unless $provider_name && $model_id;
    
    # Only look up for providers known to lack /v1/models metadata
    return undef unless $provider_name eq 'nvidia';
    
    $_mcm_instance //= do {
        require CLIO::Core::ModelCapabilitiesManager;
        CLIO::Core::ModelCapabilitiesManager->new(debug => 0);
    };
    
    return $_mcm_instance->get_capabilities($provider_name, $model_id);
}

=head1 NAME

CLIO::UI::Commands::API::Models - Model listing and selection commands

=head1 DESCRIPTION

Handles /model, /api models, and model display logic.
Extracted from CLIO::UI::Commands::API for maintainability.

=cut

sub new {
    my ($class, %args) = @_;
    my $self = $class->SUPER::new(%args);
    $self->{config}    = $args{config};
    $self->{session}   = $args{session};
    $self->{ai_agent}  = $args{ai_agent};
    return $self;
}

sub handle_model {
    my ($self, @args) = @_;

    my $model_name = join(' ', @args);
    $model_name =~ s/^\s+|\s+$//g if $model_name;

    unless ($model_name) {
        my $current = $self->{config}->get('model') || 'not set';
        $self->display_system_message("Current model: $current");
        $self->display_system_message("Usage: /model <name> to switch");
        return;
    }

    # Resolve aliases
    my $resolved = $self->{config}->get_model_alias($model_name);
    if ($resolved) {
        $self->display_system_message("Alias '$model_name' -> $resolved");
        $model_name = $resolved;
    }

    require CLIO::Providers;
    my $current_provider = $self->{config}->get('provider') || '';
    my $full_model = $model_name;

    # Auto-prepend provider if no provider prefix
    my $has_provider_prefix = 0;
    if ($model_name =~ m{^([a-z][a-z0-9_.-]*)/(.+)$}i) {
        my ($prefix, $rest) = ($1, $2);
        $has_provider_prefix = 1 if CLIO::Providers::provider_exists($prefix);
    }

    if (!$has_provider_prefix && $current_provider) {
        $full_model = "$current_provider/$model_name";
    }

    $self->{config}->set('model', $full_model);
    $self->{config}->save();

    # Clear any session-only model override so the global value takes effect
    if ($self->{session} && $self->{session}->state()) {
        my $state = $self->{session}->state();
        if ($state->{api_config} && exists $state->{api_config}{model}) {
            delete $state->{api_config}{model};
            $self->{session}->save();
        }
    }

    $self->display_system_message("Model set to: $full_model");

    # Reinit API manager
    require CLIO::UI::Commands::API::Auth;
    my $auth_cmd = CLIO::UI::Commands::API::Auth->new(
        chat => $self->{chat}, config => $self->{config},
        session => $self->{session}, ai_agent => $self->{ai_agent},
        debug => $self->{debug},
    );
    $auth_cmd->reinit_api_manager();
}

sub handle_models {
    my ($self, @args) = @_;

    my $refresh = 0;
    my $show_capabilities = 0;
    @args = grep {
        if ($_ eq '--refresh')       { $refresh = 1; 0; }
        elsif ($_ eq '--capabilities') { $show_capabilities = 1; 0; }
        else { 1; }
    } @args;

    my @all_models;

    require CLIO::Providers;
    my @providers = CLIO::Providers::list_providers();

    for my $provider_name (@providers) {
        my $provider_def = CLIO::Providers::get_provider($provider_name);
        next unless $provider_def;

        my $api_key = $self->{config}->get_provider_key($provider_name);
        my $has_auth = $api_key
            || ($provider_def->{requires_auth} && $provider_def->{requires_auth} eq 'copilot')
            || ($provider_def->{requires_auth} && $provider_def->{requires_auth} eq 'none');

        if ($provider_def->{requires_auth} && $provider_def->{requires_auth} eq 'copilot' && !$api_key) {
            eval {
                require CLIO::Core::GitHubAuth;
                my $auth = CLIO::Core::GitHubAuth->new(debug => 0);
                $api_key = $auth->get_copilot_token();
                $has_auth = 1 if $api_key;
            };
            $has_auth = 0 unless $api_key;
        }

        next unless $has_auth;

        my $models = $self->_fetch_provider_models($provider_name, $provider_def, $api_key, $refresh);

        if ($models && @$models) {
            for my $model (@$models) {
                $model->{_provider}         = $provider_name;
                $model->{_provider_display} = $provider_def->{name} || $provider_name;
                $model->{_full_id}          = "$provider_name/$model->{id}";
            }
            push @all_models, @$models;
        }
    }

    unless (@all_models) {
        $self->display_error_message("No models available from any configured provider");
        $self->display_system_message("Configure a provider with: /api set provider <name>");
        return;
    }

    if ($show_capabilities) {
        $self->_display_capabilities_view(\@all_models);
    } else {
        $self->_display_multi_provider_models(\@all_models);
    }
}

sub _fetch_provider_models {
    my ($self, $provider_name, $provider_def, $api_key, $refresh) = @_;

    my $models = [];

    if ($provider_def->{copilot_models}) {
        eval {
            require CLIO::Core::GitHubCopilotModelsAPI;
            my $cache_ttl = $refresh ? 0 : undef;
            my $models_api = CLIO::Core::GitHubCopilotModelsAPI->new(
                debug     => $self->{debug},
                cache_ttl => $cache_ttl,
                api_key   => $api_key,
            );
            my $data = $models_api->fetch_models();
            $models = $data->{data} || [] if $data;
        };
        if ($@) {
            log_warning('API', "Failed to fetch GitHub Copilot models: $@");
        }
    } elsif ($provider_def->{native_api}) {
        if ($provider_def->{endpoint} && $provider_def->{endpoint}{anthropic}) {
            # Anthropic-compatible provider: use x-api-key auth and /v1/models endpoint
            my $stored_base = $self->{config}->get_provider_base($provider_name);
            my $env_base = $ENV{ANTHROPIC_BASE_URL};
            my $def_base = $provider_def->{api_base} // 'https://api.anthropic.com/v1/messages';
            my $api_base = $stored_base || $env_base || $def_base;

            # Derive the models URL: strip any path suffix and use /v1/models
            (my $base_root = $api_base) =~ s{/v\d+/.*$}{};
            my $models_url = "$base_root/v1/models";

            eval {
                require CLIO::Compat::HTTP;
                my $ua = CLIO::Compat::HTTP->new(timeout => 30);
                my %headers = (
                    'x-api-key'        => $api_key,
                    'anthropic-version' => '2023-06-01',
                    'Accept'           => 'application/json',
                );
                my $resp = $ua->get($models_url, headers => \%headers);
                if ($resp->is_success) {
                    my $data = decode_json($resp->decoded_content);
                    for my $m (@{$data->{data} || []}) {
                        push @$models, {
                            id               => $m->{id},
                            name             => $m->{display_name} || $m->{id},
                            _context_tokens  => 200000,
                            _output_tokens   => 32000,
                            _supports_tools  => 1,
                            _supports_vision => 1,
                        };
                    }
                } else {
                    log_warning('API', "Failed to fetch Anthropic models: HTTP " . $resp->code . " " . ($resp->decoded_content // ''));
                }
            };
            if ($@) {
                log_warning('API', "Failed to fetch Anthropic models: $@");
            }
        } elsif ($provider_def->{endpoint} && $provider_def->{endpoint}{google}) {
            # Google native provider
            my $api_base = $provider_def->{api_base} || 'https://generativelanguage.googleapis.com/v1beta';
            $api_base =~ s{/+$}{};
            my $models_url = "$api_base/models?key=$api_key";

            eval {
                require CLIO::Compat::HTTP;
                my $ua = CLIO::Compat::HTTP->new(timeout => 30);
                my $resp = $ua->get($models_url, headers => { 'Accept' => 'application/json' });

                if ($resp->is_success) {
                    my $data = decode_json($resp->decoded_content);
                    for my $m (@{$data->{models} || []}) {
                        my @methods = @{$m->{supportedGenerationMethods} || []};
                        next unless grep { $_ eq 'generateContent' } @methods;
                        (my $model_id = $m->{name}) =~ s{^models/}{};
                        push @$models, {
                            id          => $model_id,
                            name        => $m->{displayName} || $model_id,
                            _context_tokens  => $m->{inputTokenLimit},
                            _output_tokens   => $m->{outputTokenLimit},
                            _supports_tools  => (grep { $_ eq 'generateContent' } @methods) ? 1 : 0,
                            _supports_vision => (grep { $_ eq 'imageUnderstanding' } @methods) ? 1 : 0,
                        };
                    }
                } else {
                    log_warning('API', "Failed to fetch Google models: HTTP " . $resp->code . " " . ($resp->decoded_content // ''));
                }
            };
            if ($@) {
                log_warning('API', "Failed to fetch Google models: $@");
            }
        } else {
            # OAI-compatible native provider (NVIDIA, etc.)
            # Uses standard /v1/models endpoint with Bearer auth
            my $api_base = $provider_def->{api_base} || '';
            my $models_url;
            if ($api_base =~ m{^(https?://[^/]+)(.*)}) {
                # Use the root host + /v1/models path
                $models_url = "$1/v1/models";
            }
            
            return [] unless $models_url && $api_key;
            
            eval {
                require CLIO::Compat::HTTP;
                my $ua = CLIO::Compat::HTTP->new(timeout => 30);
                my %headers = ('Authorization' => "Bearer $api_key");
                my $resp = $ua->get($models_url, headers => \%headers);
                
                if ($resp->is_success) {
                    my $data = decode_json($resp->decoded_content);
                    for my $m (@{$data->{data} || []}) {
                        push @$models, {
                            id               => $m->{id},
                            name             => $m->{id},
                            # NVIDIA /v1/models doesn't include token limits
                            _context_tokens  => $m->{context_length} || $m->{max_input_tokens},
                            _output_tokens   => $m->{max_completion_tokens} || $m->{max_tokens},
                        };
                    }
                } else {
                    log_warning('API', "Failed to fetch $provider_name models: HTTP " . $resp->code . " " . ($resp->decoded_content // ''));
                }
            };
            if ($@) {
                log_warning('API', "Failed to fetch models from $provider_name: $@");
            }
        }
    } elsif ($provider_def->{static_models}) {
        $models = $self->_get_static_models($provider_name);
    } else {
        # Use per-provider stored base URL if available, otherwise provider default
        my $stored_base = $self->{config}->get_provider_base($provider_name);
        my $api_base = $stored_base || $provider_def->{api_base} || '';

        my $models_url;
        if ($api_base =~ m{openrouter\.ai}i) {
            $models_url = 'https://openrouter.ai/api/v1/models';
        } elsif ($api_base =~ m{^(https?://[^/]+)}) {
            $models_url = "$1/v1/models";
        }

        return [] unless $models_url && $api_key;

        eval {
            require CLIO::Compat::HTTP;
            my $ua = CLIO::Compat::HTTP->new(timeout => 30);
            my %headers = ('Authorization' => "Bearer $api_key");
            my $resp = $ua->get($models_url, headers => \%headers);

            if ($resp->is_success) {
                my $data = decode_json($resp->decoded_content);
                for my $m (@{$data->{data} || []}) {
                    my $ctx = $m->{context_length} || ($m->{top_provider} && $m->{top_provider}{context_length});
                    my $out = $m->{top_provider} && $m->{top_provider}{max_completion_tokens};
                    my $arch = $m->{architecture} || {};
                    my $modalities = $arch->{input_modalities} || [];
                    push @$models, {
                        id               => $m->{id},
                        name             => $m->{name} || $m->{id},
                        _context_tokens  => $ctx,
                        _output_tokens   => $out,
                        _supports_vision => (grep { /image|vision/i } @$modalities) ? 1 : 0,
                        billing          => $m->{billing},
                    };
                }
            }
        };
        if ($@) {
            log_warning('API', "Failed to fetch models from $provider_name: $@");
        }
    }

    return $models;
}

sub _get_static_models {
    my ($self, $provider_name) = @_;

    if ($provider_name =~ /^minimax/) {
        return [
            { id => 'MiniMax-M3',              name => 'MiniMax M3',              _context_tokens => 1000000, _output_tokens => 131072, _supports_vision => 1 },
            { id => 'MiniMax-M2.7',           name => 'MiniMax M2.7',           _context_tokens => 204800, _output_tokens => 131072 },
            { id => 'MiniMax-M2.7-highspeed',  name => 'MiniMax M2.7 Highspeed',  _context_tokens => 204800, _output_tokens => 131072 },
            { id => 'MiniMax-M2.5',           name => 'MiniMax M2.5',           _context_tokens => 204800, _output_tokens => 131072 },
            { id => 'MiniMax-M2.5-highspeed',  name => 'MiniMax M2.5 Highspeed',  _context_tokens => 204800, _output_tokens => 131072 },
            { id => 'MiniMax-M2.1',           name => 'MiniMax M2.1',           _context_tokens => 204800, _output_tokens => 131072 },
            { id => 'MiniMax-M2.1-highspeed',  name => 'MiniMax M2.1 Highspeed',  _context_tokens => 204800, _output_tokens => 131072 },
            { id => 'MiniMax-M2',             name => 'MiniMax M2',             _context_tokens => 204800, _output_tokens => 131072 },
        ];
    }
    elsif ($provider_name eq 'zai') {
        return [
            { id => 'glm-5.1',        _context_tokens => 200000, _output_tokens => 131072 },
            { id => 'glm-5',          _context_tokens => 200000, _output_tokens => 131072 },
            { id => 'glm-5-turbo',    _context_tokens => 200000, _output_tokens => 131072 },
            { id => 'glm-4.7',        _context_tokens => 200000, _output_tokens => 131072 },
            { id => 'glm-4.7-flashx', _context_tokens => 200000, _output_tokens => 131072 },
            { id => 'glm-4.7-flash',  _context_tokens => 200000, _output_tokens => 131072 },
            { id => 'glm-4.6',        _context_tokens => 200000, _output_tokens => 131072 },
            { id => 'glm-4.5',        _context_tokens => 128000, _output_tokens => 16384 },
            { id => 'glm-4.5-x',      _context_tokens => 128000, _output_tokens => 16384 },
            { id => 'glm-4.5-air',    _context_tokens => 128000, _output_tokens => 16384 },
            { id => 'glm-4.5-airx',   _context_tokens => 128000, _output_tokens => 16384 },
            { id => 'glm-4.5-flash',  _context_tokens => 200000, _output_tokens => 131072 },
            { id => 'glm-4-32b-0414-128k', _context_tokens => 128000, _output_tokens => 131072 },
            { id => 'glm-5v-turbo',   _context_tokens => 200000, _output_tokens => 131072, _supports_vision => 1 },
            { id => 'glm-4.6v',       _context_tokens => 128000, _output_tokens => 16384, _supports_vision => 1 },
            { id => 'glm-4.6v-flashx',_context_tokens => 128000, _output_tokens => 16384, _supports_vision => 1 },
            { id => 'glm-4.6v-flash', _context_tokens => 128000, _output_tokens => 16384, _supports_vision => 1 },
            { id => 'glm-4.5v',       _context_tokens => 64000,  _output_tokens => 16384, _supports_vision => 1 },
            { id => 'glm-ocr',        _context_tokens => 32000,  _output_tokens => 8192 },
        ];
    }
    elsif ($provider_name eq 'zai_coding') {
        return [
            { id => 'glm-5.1',       _context_tokens => 200000, _output_tokens => 131072 },
            { id => 'glm-5-turbo',   _context_tokens => 200000, _output_tokens => 131072 },
            { id => 'glm-4.7',       _context_tokens => 200000, _output_tokens => 131072 },
            { id => 'glm-4.5-air',   _context_tokens => 128000, _output_tokens => 16384 },
        ];
    }

    return [];
}

sub _display_multi_provider_models {
    my ($self, $all_models) = @_;

    my %by_provider;
    for my $model (@$all_models) {
        my $provider = $model->{_provider} || 'unknown';
        push @{$by_provider{$provider}}, $model;
    }

    my @provider_order = sort {
        my $a_def = CLIO::Providers::get_provider($a);
        my $b_def = CLIO::Providers::get_provider($b);
        my $a_pri = ($a_def && $a_def->{priority_display}) ? 0 : 1;
        my $b_pri = ($b_def && $b_def->{priority_display}) ? 0 : 1;
        return $a_pri <=> $b_pri || $a cmp $b;
    } keys %by_provider;

   $self->refresh_terminal_size();
   $self->{chat}->{pager}->reset();
   $self->{chat}->{pager}->enable();

   my @lines;
   my $total_count = scalar @$all_models;

   # Calculate dynamic model column width based on terminal width
   # Leave space for other columns: 2 spaces + 6 (Ctx) + 1 space + 6 (Out) + 2 spaces + 5 (Cap) + buffer = ~25 chars
   my $available_width = $self->{chat}->{terminal_width} || 80;
   my $max_id_width = $available_width - 25;
   # Ensure reasonable bounds
   $max_id_width = 20 if $max_id_width < 20;
   $max_id_width = 50 if $max_id_width > 50;

   push @lines, "";
   push @lines, box_char("hhorizontal") x $available_width;
   push @lines, $self->colorize("AVAILABLE MODELS", 'DATA') . " (" . scalar(@provider_order) . " providers, $total_count models)";
   push @lines, box_char("hhorizontal") x $available_width;

   for my $provider_name (@provider_order) {
       my $models = $by_provider{$provider_name};
       my $display_name = $models->[0]{_provider_display} || $provider_name;

       # Filter out embedding models and router entries
       my @chat_models = grep {
           my $id = $_->{id} || '';
           $id !~ /embedding|embed/i && !($id =~ m{/routers/})
       } @$models;

       # Deduplicate by model ID (keep first occurrence)
       my %seen;
       my @unique;
       for my $m (sort { $a->{id} cmp $b->{id} } @chat_models) {
           my $id = $m->{_full_id} || $m->{id};
           # Strip provider prefix for dedup (e.g., github_copilot/gpt-4 -> gpt-4)
           my $base_id = $id;
           $base_id =~ s{^\Q$provider_name\E/}{};
           next if $seen{lc($base_id)}++;
           push @unique, $m;
       }

       my $count = scalar @unique;

       push @lines, "";
       push @lines, $self->colorize("$display_name ($provider_name)", 'THEME');
       push @lines, "  " . (box_char("horizontal") x ($available_width - 2));

       # Column headers
       push @lines, $self->colorize(
           sprintf("  %-${max_id_width}s %6s %6s  %-5s", "Model", "Ctx", "Out", "Cap"),
           'DIM'
       );

       for my $model (@unique) {
           my $line = $self->_format_model_line($model, $provider_name, $max_id_width);
           push @lines, $line;
       }
   }

   push @lines, "";
   push @lines, box_char("hhorizontal") x $available_width;
   push @lines, sprintf("Total: %d models across %d providers", $total_count, scalar(@provider_order));
   push @lines, "";
   push @lines, $self->colorize("Usage: /api set model <provider>/<model>", 'SYSTEM');
   push @lines, $self->colorize("  e.g.: /api set model github_copilot/gpt-4.1", 'SYSTEM');
   push @lines, $self->colorize("  e.g.: /api set model openrouter/deepseek/deepseek-r1-0528", 'SYSTEM');
   push @lines, "";

   for my $line (@lines) {
       last unless $self->writeline($line);
   }
   $self->{chat}->{pager}->disable();
}

sub _format_model_line {
   my ($self, $model, $provider_name, $max_id_width) = @_;

   $max_id_width //= 30;

   my $full_id = $model->{_full_id} || $model->{id};

   # Strip provider prefix from display ID (it's already in the section header)
   my $display_id = $full_id;
   if ($provider_name) {
       $display_id =~ s{^\Q$provider_name\E/}{};
   }

   # Context tokens - check multiple sources
   my $ctx = $model->{_context_tokens};
   if (!$ctx && $model->{capabilities} && $model->{capabilities}{limits}) {
       $ctx = $model->{capabilities}{limits}{max_context_window_tokens}
           || $model->{capabilities}{limits}{max_prompt_tokens};
   }
   # Fallback to MCM for providers that don't return context in /v1/models (e.g., NVIDIA NIM)
   if (!$ctx && $provider_name) {
       my $caps = $self->_get_mcm_capabilities($provider_name, $full_id);
       $ctx = $caps->{context_window} if $caps;
   }
   my $ctx_str = $ctx ? _format_tokens($ctx) : "-";

   # Output tokens
   my $out = $model->{_output_tokens};
   if (!$out && $model->{capabilities} && $model->{capabilities}{limits}) {
       $out = $model->{capabilities}{limits}{max_output_tokens};
   }
   if (!$out && $provider_name) {
       my $caps = $self->_get_mcm_capabilities($provider_name, $full_id);
       $out = $caps->{max_output_tokens} if $caps;
   }
   my $out_str = $out ? _format_tokens($out) : "-";

   # Feature flags (abbreviated for compact display)
   my @features;
   push @features, "t" if $model->{_supports_tools};
   push @features, "v" if $model->{_supports_vision};
   push @features, "r" if $model->{_supports_reasoning};

   # Check Copilot capabilities supports hash
   if ($model->{capabilities} && $model->{capabilities}{supports}) {
       my $s = $model->{capabilities}{supports};
       push @features, "t" if $s->{tool_calls} && !grep { $_ eq 't' } @features;
       push @features, "v" if $s->{vision} && !grep { $_ eq 'v' } @features;
   }

   # Fallback to MCM for feature flags
   if (!@features && $provider_name) {
       my $caps = $self->_get_mcm_capabilities($provider_name, $full_id);
       if ($caps) {
           push @features, "t" if $caps->{supports_tools};
           push @features, "v" if $caps->{supports_vision};
           push @features, "r" if $caps->{supports_reasoning};
       }
   }

   my $features_str = join("", @features);

   # Build colorized data fields (padded to fixed widths on plain text)
   my $ctx_padded = sprintf("%6s", $ctx_str);
   my $out_padded = sprintf("%6s", $out_str);
   my $feat_padded = sprintf("%-5s", $features_str);

   my $data_line = " " .
       $self->colorize($ctx_padded, 'DATA') . " " .
       $self->colorize($out_padded, 'DATA') . "  " .
       $self->colorize($feat_padded, 'DIM');

   # If model ID fits in column, single line
   if (length($display_id) <= $max_id_width) {
       my $id_padded = sprintf("%-${max_id_width}s", $display_id);
       return "  " . $self->colorize($id_padded, 'USER') . $data_line;
   }

   # Model ID too long - truncate with ellipsis to keep columns aligned
   my $truncated = substr($display_id, 0, $max_id_width - 1) . "\x{2026}";
   my $id_padded = sprintf("%-${max_id_width}s", $truncated);
   return "  " . $self->colorize($id_padded, 'USER') . $data_line;
}

sub _format_capabilities_line {
   my ($self, $model, $provider_name, $max_id_width, $mcm, $has_cap_map) = @_;

   $max_id_width //= 30;

   my $model_id = $model->{id};
   my $full_id = $model->{_full_id} || $model_id;

   # Strip provider prefix
   my $display_id = $full_id;
   $display_id =~ s{^\Q$provider_name\E/}{};

   # Truncate long model IDs with ellipsis
   if (length($display_id) > $max_id_width) {
       $display_id = substr($display_id, 0, $max_id_width - 1) . "\x{2026}";
   }

   # Context tokens from model data or MCM
   my $ctx = $model->{_context_tokens};
   if (!$ctx && $model->{capabilities} && $model->{capabilities}{limits}) {
       $ctx = $model->{capabilities}{limits}{max_context_window_tokens}
           || $model->{capabilities}{limits}{max_prompt_tokens};
   }
   if ($has_cap_map && !$ctx) {
       my $caps = $mcm->get_capabilities($provider_name, $model_id);
       $ctx = $caps->{context_window} if $caps;
   }
   my $ctx_str = $ctx ? _format_tokens($ctx) : "-";

   # Output tokens
   my $out = $model->{_output_tokens};
   if (!$out && $model->{capabilities} && $model->{capabilities}{limits}) {
       $out = $model->{capabilities}{limits}{max_output_tokens};
   }
   my $out_str = $out ? _format_tokens($out) : "-";

   # Feature flags (abbreviated for compact display)
   my @features;
   push @features, "t" if $model->{_supports_tools};
   push @features, "v" if $model->{_supports_vision};
   push @features, "r" if $model->{_supports_reasoning};

   # Check Copilot capabilities supports hash
   if ($model->{capabilities} && $model->{capabilities}{supports}) {
       my $s = $model->{capabilities}{supports};
       push @features, "t" if $s->{tool_calls} && !grep { $_ eq 't' } @features;
       push @features, "v" if $s->{vision} && !grep { $_ eq 'v' } @features;
       push @features, "s" if $s->{streaming};
   }

   # MCM capabilities for providers with capability maps
   if ($has_cap_map) {
       my $caps = $mcm->get_capabilities($provider_name, $model_id);
       if ($caps) {
           push @features, "t" if $caps->{supports_tools} && !grep { $_ eq 't' } @features;
           push @features, "v" if $caps->{supports_vision} && !grep { $_ eq 'v' } @features;
           push @features, "r" if $caps->{supports_reasoning} && !grep { $_ eq 'r' } @features;
           push @features, "s" if $caps->{supports_streaming} && !grep { $_ eq 's' } @features;
       }
   }

   my $features_str = join("", @features);

   # Build colorized data fields (padded to fixed widths on plain text)
   my $ctx_padded = sprintf("%6s", $ctx_str);
   my $out_padded = sprintf("%6s", $out_str);
   my $feat_padded = sprintf("%-5s", $features_str);

   my $data_line = " " .
       $self->colorize($ctx_padded, 'DATA') . " " .
       $self->colorize($out_padded, 'DATA') . "  " .
       $self->colorize($feat_padded, 'DIM');

   # Single line with dynamic width
   my $id_padded = sprintf("%-${max_id_width}s", $display_id);
   return "  " . $self->colorize($id_padded, 'USER') . $data_line;
}

sub _display_capabilities_view {
    my ($self, $all_models) = @_;

    require CLIO::Core::ModelCapabilitiesManager;
    my $mcm = CLIO::Core::ModelCapabilitiesManager->new(debug => 0);

    my %by_provider;
    for my $model (@$all_models) {
        my $provider = $model->{_provider} || 'unknown';
        push @{$by_provider{$provider}}, $model;
    }

    my @provider_order = sort {
        my $a_def = CLIO::Providers::get_provider($a);
        my $b_def = CLIO::Providers::get_provider($b);
        my $a_pri = ($a_def && $a_def->{priority_display}) ? 0 : 1;
        my $b_pri = ($b_def && $b_def->{priority_display}) ? 0 : 1;
        return $a_pri <=> $b_pri || $a cmp $b;
    } keys %by_provider;

    $self->refresh_terminal_size();
    $self->{chat}->{pager}->reset();
    $self->{chat}->{pager}->enable();

   my @lines;

   # Calculate dynamic model column width based on terminal width
   my $available_width = $self->{chat}->{terminal_width} || 80;
   my $max_id_width = $available_width - 25;
   $max_id_width = 20 if $max_id_width < 20;
   $max_id_width = 50 if $max_id_width > 50;

   push @lines, "";
   push @lines, box_char("hhorizontal") x $available_width;
   push @lines, $self->colorize("MODEL CAPABILITIES", 'DATA') . " (" . scalar(@provider_order) . " providers)";
   push @lines, box_char("hhorizontal") x $available_width;

   for my $provider_name (@provider_order) {
       my $models = $by_provider{$provider_name};
       my $display_name = $models->[0]{_provider_display} || $provider_name;

       require CLIO::Providers;
       my $provider_def = CLIO::Providers::get_provider($provider_name);
       my $has_cap_map = $provider_def && $provider_def->{capability_map};

       # Filter out embedding models and router entries
       my @chat_models = grep {
           my $id = $_->{id} || '';
           $id !~ /embedding|embed/i && !($id =~ m{/routers/})
       } @$models;

       # Deduplicate by model ID
       my %seen;
       my @unique;
       for my $m (sort { $a->{id} cmp $b->{id} } @chat_models) {
           my $id = $m->{_full_id} || $m->{id};
           my $base_id = $id;
           $base_id =~ s{^\Q$provider_name\E/}{};
           next if $seen{lc($base_id)}++;
           push @unique, $m;
       }

       push @lines, "";
       push @lines, $self->colorize("$display_name ($provider_name)", 'THEME');
       push @lines, "  " . (box_char("horizontal") x ($available_width - 2));

       # Column headers
       push @lines, $self->colorize(
           sprintf("  %-${max_id_width}s %6s %6s  %-5s", "Model", "Ctx", "Out", "Cap"),
           'DIM'
       );

       for my $model (@unique) {
           my $line = $self->_format_capabilities_line($model, $provider_name, $max_id_width, $mcm, $has_cap_map);
           push @lines, $line;
       }
   }

   push @lines, "";
   push @lines, box_char("hhorizontal") x $available_width;
   push @lines, "";
   
   for my $line (@lines) {
       last unless $self->writeline($line);
   }
   $self->{chat}->{pager}->disable();
}

sub _display_models_list {
    my ($self, $models, $api_base) = @_;

    my @sorted_models = sort { $a->{id} cmp $b->{id} } @$models;

    $self->refresh_terminal_size();
    $self->{chat}->{pager}->reset();
    $self->{chat}->{pager}->enable();

    my @lines;

    # Calculate dynamic model column width based on terminal width
    my $available_width = $self->{chat}->{terminal_width} || 80;
    my $max_id_width = $available_width - 25;
    $max_id_width = 20 if $max_id_width < 20;
    $max_id_width = 50 if $max_id_width > 50;

    push @lines, "";
    push @lines, box_char("hhorizontal") x $available_width;
    push @lines, $self->colorize("AVAILABLE MODELS", 'DATA') . " (" . $self->colorize($api_base, 'THEME') . ")";
    push @lines, box_char("hhorizontal") x $available_width;

    # Column headers
    push @lines, "";
    push @lines, $self->colorize(
        sprintf("  %-${max_id_width}s %6s %6s  %-5s", "Model", "Ctx", "Out", "Cap"),
        'DIM'
    );

    for my $model (@sorted_models) {
        push @lines, $self->_format_model_line($model, undef, $max_id_width);
    }

    push @lines, "";
    push @lines, box_char("hhorizontal") x $available_width;
    push @lines, sprintf("Total: %d models available", scalar(@$models));
    push @lines, "";

    for my $line (@lines) {
        last unless $self->writeline($line);
    }
    $self->{chat}->{pager}->disable();
}

1;

__END__

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

Same as CLIO.

=cut
