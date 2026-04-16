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
    @args = grep {
        if ($_ eq '--refresh') { $refresh = 1; 0; } else { 1; }
    } @args;

    my @all_models;

    require CLIO::Providers;
    my @providers = CLIO::Providers::list_providers();

    for my $provider_name (@providers) {
        my $provider_def = CLIO::Providers::get_provider($provider_name);
        next unless $provider_def;

        my $api_key = $self->{config}->get_provider_key($provider_name);
        my $has_auth = $api_key
            || $provider_name eq 'github_copilot'
            || $provider_name eq 'sam'
            || $provider_name eq 'llama.cpp'
            || $provider_name eq 'lmstudio';

        if ($provider_name eq 'github_copilot' && !$api_key) {
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

    $self->_display_multi_provider_models(\@all_models);
}

sub _fetch_provider_models {
    my ($self, $provider_name, $provider_def, $api_key, $refresh) = @_;

    my $models = [];

    if ($provider_name eq 'github_copilot') {
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
    } elsif ($provider_def->{native_api} && $provider_name eq 'google') {
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
                        description => $m->{description} || '',
                        _supports_tools => (grep { $_ eq 'generateContent' } @methods) ? 1 : 0,
                    };
                }
            } else {
                log_warning('API', "Failed to fetch Google models: HTTP " . $resp->code . " " . ($resp->decoded_content // ''));
            }
        };
        if ($@) {
            log_warning('API', "Failed to fetch Google models: $@");
        }
    } elsif ($provider_name =~ /^minimax/) {
        $models = [
            { id => 'MiniMax-M2.7',           name => 'MiniMax M2.7',           description => 'Recursive self-improvement, ~60 tps (204.8k ctx, 131k out)' },
            { id => 'MiniMax-M2.7-highspeed',  name => 'MiniMax M2.7 Highspeed',  description => 'Same as M2.7, ~100 tps (204.8k ctx, 131k out)' },
            { id => 'MiniMax-M2.5',           name => 'MiniMax M2.5',           description => 'Code generation and refactoring, ~60 tps (204.8k ctx, 131k out)' },
            { id => 'MiniMax-M2.5-highspeed',  name => 'MiniMax M2.5 Highspeed',  description => 'Same as M2.5, ~100 tps (204.8k ctx, 131k out)' },
            { id => 'MiniMax-M2.1',           name => 'MiniMax M2.1',           description => '230B params, code + reasoning, ~60 tps (204.8k ctx, 131k out)' },
            { id => 'MiniMax-M2.1-highspeed',  name => 'MiniMax M2.1 Highspeed',  description => 'Same as M2.1, ~100 tps (204.8k ctx, 131k out)' },
            { id => 'MiniMax-M2',             name => 'MiniMax M2',             description => 'Function calling, advanced reasoning (204.8k ctx, 131k out)' },
        ];
    } elsif ($provider_name eq 'zai') {
        # Z.AI models - text and vision models
        # API reference: https://docs.z.ai/api-reference/llm/chat-completion
        $models = [
            # GLM-5 Series (Flagship - Agentic Engineering)
            { id => 'glm-5.1',       name => 'GLM-5.1',       description => 'SOTA coding, 8-hour autonomous tasks (200k ctx, $1.40/$4.40 per 1M)' },
            { id => 'glm-5',         name => 'GLM-5',         description => 'Agentic Engineering, complex systems (200k ctx, $1.00/$3.20 per 1M)' },
            { id => 'glm-5-turbo',   name => 'GLM-5-Turbo',   description => 'OpenClaw optimized, complex tasks (200k ctx, $1.20/$4.00 per 1M)' },
            # GLM-4.7 Series
            { id => 'glm-4.7',       name => 'GLM-4.7',       description => 'SOTA Performance, enhanced coding (200k ctx, $0.60/$2.20 per 1M)' },
            { id => 'glm-4.7-flashx',name => 'GLM-4.7-FlashX',description => 'Lightweight high-speed (200k ctx, $0.07/$0.40 per 1M)' },
            { id => 'glm-4.7-flash', name => 'GLM-4.7-Flash', description => 'Free lightweight (200k ctx, free)' },
            # GLM-4.6 Series
            { id => 'glm-4.6',       name => 'GLM-4.6',       description => 'High Performance, strong coding (200k ctx, $0.60/$2.20 per 1M)' },
            # GLM-4.5 Series
            { id => 'glm-4.5',       name => 'GLM-4.5',       description => 'Better Performance, strong reasoning (128k ctx, $0.60/$2.20 per 1M)' },
            { id => 'glm-4.5-x',     name => 'GLM-4.5-X',     description => 'Ultra-Fast response (128k ctx, $2.20/$8.90 per 1M)' },
            { id => 'glm-4.5-air',   name => 'GLM-4.5-Air',   description => 'Cost-Effective lightweight (128k ctx, $0.20/$1.10 per 1M)' },
            { id => 'glm-4.5-airx',  name => 'GLM-4.5-AirX', description => 'Lightweight fast response (128k ctx, $1.10/$4.50 per 1M)' },
            { id => 'glm-4.5-flash', name => 'GLM-4.5-Flash', description => 'Free lightweight (200k ctx, free)' },
            # 32B Model
            { id => 'glm-4-32b-0414-128k', name => 'GLM-4-32B', description => 'High intelligence at low cost (128k ctx, $0.10/$0.10 per 1M)' },
            # Vision Models
            { id => 'glm-5v-turbo',  name => 'GLM-5V-Turbo',  description => 'Multimodal coding, vision-based tasks (200k ctx, $1.20/$4.00 per 1M)' },
            { id => 'glm-4.6v',       name => 'GLM-4.6V',      description => 'Vision with function calling (128k ctx, $0.30/$0.90 per 1M)' },
            { id => 'glm-4.6v-flashx',name => 'GLM-4.6V-FlashX',description => 'Vision lightweight fast (128k ctx, $0.04/$0.40 per 1M)' },
            { id => 'glm-4.6v-flash', name => 'GLM-4.6V-Flash',description => 'Vision free tier (128k ctx, free)' },
            { id => 'glm-4.5v',       name => 'GLM-4.5V',      description => 'Vision multimodal (64k ctx, $0.60/$1.80 per 1M)' },
            # OCR
            { id => 'glm-ocr',       name => 'GLM-OCR',       description => 'Document parsing, information extraction ($0.03 per 1M)' },
        ];
    } elsif ($provider_name eq 'zai_coding') {
        # Z.AI Coding Plan models - quota-based (not billed via API)
        # See: https://docs.z.ai/devpack/overview
        $models = [
            { id => 'glm-5.1',       name => 'GLM-5.1',       description => 'SOTA coding model (200k ctx, plan quota)' },
            { id => 'glm-5-turbo',   name => 'GLM-5-Turbo',   description => 'OpenClaw optimized (200k ctx, plan quota)' },
            { id => 'glm-4.7',       name => 'GLM-4.7',       description => 'High Performance (200k ctx, plan quota)' },
            { id => 'glm-4.5-air',   name => 'GLM-4.5-Air',   description => 'Cost-Effective (128k ctx, plan quota)' },
        ];
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
                $models = $data->{data} || [];
            }
        };
        if ($@) {
            log_warning('API', "Failed to fetch models from $provider_name: $@");
        }
    }

    return $models;
}

sub _display_multi_provider_models {
    my ($self, $all_models) = @_;

    my %by_provider;
    for my $model (@$all_models) {
        my $provider = $model->{_provider} || 'unknown';
        push @{$by_provider{$provider}}, $model;
    }

    my @provider_order = sort {
        return -1 if $a eq 'github_copilot';
        return 1 if $b eq 'github_copilot';
        return $a cmp $b;
    } keys %by_provider;

    $self->refresh_terminal_size();
    $self->{chat}->{pager}->reset();
    $self->{chat}->{pager}->enable();

    my @lines;
    my $total_count = scalar @$all_models;

    push @lines, "";
    push @lines, box_char("hhorizontal") x 76;
    push @lines, $self->colorize("AVAILABLE MODELS", 'DATA') . " (" . scalar(@provider_order) . " providers, $total_count models)";
    push @lines, box_char("hhorizontal") x 76;

    for my $provider_name (@provider_order) {
        my $models = $by_provider{$provider_name};
        my $display_name = $models->[0]{_provider_display} || $provider_name;
        my $count = scalar @$models;

        push @lines, "";
        push @lines, $self->colorize("$display_name ($count models)", 'THEME');
        push @lines, "  " . (box_char("horizontal") x 72);

        my @sorted = sort { $a->{id} cmp $b->{id} } @$models;

        for my $model (@sorted) {
            my $full_id = $model->{_full_id} || $model->{id};
            my $billing_info = '';

            if ($model->{billing} && defined $model->{billing}{multiplier}) {
                my $mult = $model->{billing}{multiplier};
                if    ($mult == 0)              { $billing_info = 'FREE'; }
                elsif ($mult == int($mult))     { $billing_info = int($mult) . 'x'; }
                else                            { $billing_info = sprintf("%.1fx", $mult); }
            }

            my $max_name = $billing_info ? 62 : 74;
            my $display_id = $full_id;
            if (length($display_id) > $max_name) {
                $display_id = substr($display_id, 0, $max_name - 3) . "...";
            }

            if ($billing_info) {
                my $colored = $self->colorize($display_id, 'USER');
                my $pad = $max_name - length($display_id);
                $pad = 1 if $pad < 1;
                push @lines, sprintf("  %s%s %10s", $colored, ' ' x $pad, $billing_info);
            } else {
                push @lines, "  " . $self->colorize($display_id, 'USER');
            }
        }
    }

    push @lines, "";
    push @lines, box_char("hhorizontal") x 76;
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

sub _display_models_list {
    my ($self, $models, $api_base) = @_;

    my @free_models;
    my @premium_models;
    my @unknown_models;

    for my $model (@$models) {
        my $is_premium = undef;

        if (exists $model->{billing} && defined $model->{billing}{is_premium}) {
            $is_premium = $model->{billing}{is_premium};
        } elsif (exists $model->{is_premium}) {
            $is_premium = $model->{is_premium};
        }

        if (defined $is_premium) {
            if ($is_premium) { push @premium_models, $model; }
            else             { push @free_models, $model; }
        } else {
            push @unknown_models, $model;
        }
    }

    @free_models    = sort { $a->{id} cmp $b->{id} } @free_models;
    @premium_models = sort { $a->{id} cmp $b->{id} } @premium_models;
    @unknown_models = sort { $a->{id} cmp $b->{id} } @unknown_models;

    my $has_billing = (@free_models || @premium_models);

    $self->refresh_terminal_size();
    $self->{chat}->{pager}->reset();
    $self->{chat}->{pager}->enable();

    my @lines;

    push @lines, "";
    push @lines, box_char("hhorizontal") x 54;
    push @lines, $self->colorize("AVAILABLE MODELS", 'DATA') . " (" . $self->colorize($api_base, 'THEME') . ")";
    push @lines, box_char("hhorizontal") x 54;
    push @lines, "";

    if ($has_billing) {
        my $header = sprintf("  %-64s %12s", "Model", "Rate");
        push @lines, $self->colorize($header, 'THEME');
        push @lines, sprintf("  %-64s %12s", box_char("hhorizontal") x 64, box_char("hhorizontal") x 12);
    } else {
        my $header = sprintf("  %-70s", "Model");
        push @lines, $self->colorize($header, 'THEME');
        push @lines, sprintf("  %-70s", box_char("hhorizontal") x 70);
    }

    if (@free_models) {
        push @lines, "";
        push @lines, $self->colorize("FREE MODELS", 'THEME');
        for my $model (@free_models) {
            push @lines, "  " . $self->_format_model_for_display($model, $has_billing);
        }
    }

    if (@premium_models) {
        push @lines, "";
        push @lines, $self->colorize("PREMIUM MODELS", 'THEME');
        for my $model (@premium_models) {
            push @lines, "  " . $self->_format_model_for_display($model, $has_billing);
        }
    }

    if (@unknown_models) {
        push @lines, "";
        push @lines, $self->colorize($has_billing ? 'OTHER MODELS' : 'ALL MODELS', 'THEME');
        for my $model (@unknown_models) {
            push @lines, "  " . $self->_format_model_for_display($model, $has_billing);
        }
    }

    push @lines, "";
    push @lines, box_char("hhorizontal") x 54;
    push @lines, sprintf("Total: %d models available", scalar(@$models));

    if ($has_billing) {
        push @lines, "";
        push @lines, $self->colorize("Note: Subscription-based billing", 'SYSTEM');
        push @lines, "      " . $self->colorize("FREE = Included in subscription", 'SYSTEM');
        push @lines, "      " . $self->colorize("1x/3x/10x = Premium multiplier on usage", 'SYSTEM');
    }
    push @lines, "";

    for my $line (@lines) {
        last unless $self->writeline($line);
    }
    $self->{chat}->{pager}->disable();
}

sub _format_model_for_display {
    my ($self, $model, $has_billing) = @_;

    my $name = $model->{id} || 'Unknown';

    my $max_name_length = $has_billing ? 62 : 68;
    if (length($name) > $max_name_length) {
        $name = substr($name, 0, $max_name_length - 3) . "...";
    }

    if ($has_billing) {
        my $billing_rate = '-';

        if ($model->{billing} && defined $model->{billing}{multiplier}) {
            my $mult = $model->{billing}{multiplier};
            if    ($mult == 0)           { $billing_rate = 'FREE'; }
            elsif ($mult == int($mult))  { $billing_rate = int($mult) . 'x'; }
            else                         { $billing_rate = sprintf("%.2fx", $mult); }
        } elsif (defined $model->{premium_multiplier}) {
            my $mult = $model->{premium_multiplier};
            if    ($mult == 0)           { $billing_rate = 'FREE'; }
            elsif ($mult == int($mult))  { $billing_rate = int($mult) . 'x'; }
            else                         { $billing_rate = sprintf("%.2fx", $mult); }
        }

        my $colored_name = $self->colorize($name, 'USER');
        my $name_display_width = length($name);
        my $padding = $max_name_length - $name_display_width;
        $padding = 1 if $padding < 1;

        return sprintf("%s%s %10s", $colored_name, ' ' x $padding, $billing_rate);
    } else {
        return $self->colorize($name, 'USER');
    }
}

1;

__END__

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

Same as CLIO.

=cut

1;
