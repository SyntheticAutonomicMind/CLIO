#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::UI::Chat::Header;

use strict;
use warnings;
use utf8;

use POSIX qw(_exit);
use File::Spec;
use CLIO::Core::Logger qw(log_debug log_info log_warning);
use CLIO::UI::Terminal qw(box_char ui_char);
use CLIO::Compat::Terminal qw(ReadMode);

=head1 NAME

CLIO::UI::Chat::Header - Banner, session info, update checks extracted from Chat.pm

=head1 SYNOPSIS

    my $header = CLIO::UI::Chat::Header->new($chat);
    print $header->agent_name();
    $header->display_header();
    $header->check_for_updates_async();

=head1 DESCRIPTION

Extracted from CLIO::UI::Chat to reduce Chat.pm size. Each method receives
the Chat instance as $self->{chat} and delegates display calls back to it.

=cut

sub new {
    my ($class, $chat) = @_;
    return bless { chat => $chat }, $class;
}

=head2 agent_name

=cut

sub agent_name {
    my ($self) = @_;
    return $ENV{CLIO_AGENT_NAME} || 'CLIO';
}

=head2 check_for_updates_async

=cut

sub check_for_updates_async {
    my ($self) = @_;
    my $chat = $self->{chat};

    eval { require CLIO::Update; };
    if ($@) {
        log_debug('Chat', "Update module not available: $@");
        return;
    }

    my $updater = CLIO::Update->new(debug => $chat->{debug});

    my $update_info = $updater->get_available_update();
    if ($update_info && $update_info->{cached} && !$update_info->{up_to_date}) {
        my $version = $update_info->{version} || 'unknown';
        $chat->display_system_message("An update is available ($version). Run " .
            $chat->colorize('/update install', 'command') . " to upgrade.");
    }

    my $cache_file = File::Spec->catfile('.clio', 'update_check_cache');
    if (-f $cache_file) {
        $chat->{_update_cache_mtime} = (stat($cache_file))[9];
        log_debug('Chat', "Tracking update cache mtime: $chat->{_update_cache_mtime}");
    }

    if ($^O eq 'MSWin32') {
        log_debug('Chat', "Skipping async update check on Windows (no fork)");
        return;
    }

    my $intermediate = fork();
    if (!defined $intermediate) {
        log_warning('Chat', "Failed to fork update checker: $!");
        return;
    }

    if ($intermediate == 0) {
        my $grandchild = fork();
        _exit(0) unless defined $grandchild && $grandchild == 0;

        eval {
            require CLIO::Compat::Terminal;
            CLIO::Compat::Terminal::reset_terminal_light();
        };

        close(STDIN);
        close(STDOUT);
        close(STDERR);

        eval { $updater->check_for_updates(); };
        _exit(0);
    }

    waitpid($intermediate, 0);
}

=head2 check_for_update_notification

=cut

sub check_for_update_notification {
    my ($self) = @_;
    my $chat = $self->{chat};

    my $now = time();
    my $last_check = $chat->{_last_update_check} || 0;
    my $check_interval = 30;
    return if ($now - $last_check) < $check_interval;
    $chat->{_last_update_check} = $now;

    eval { require CLIO::Update; };
    return if $@;

    my $cache_file = File::Spec->catfile('.clio', 'update_check_cache');
    return unless -f $cache_file;

    my $current_mtime = (stat($cache_file))[9];
    my $last_known_mtime = $chat->{_update_cache_mtime} || 0;
    return if $current_mtime <= $last_known_mtime;

    log_debug('Chat', "Update cache modified, checking for new updates");

    my $updater = CLIO::Update->new(debug => $chat->{debug});
    my $update_info = $updater->get_available_update();
    $chat->{_update_cache_mtime} = $current_mtime;

    if ($update_info && $update_info->{cached} && !$update_info->{up_to_date}) {
        my $version = $update_info->{version} || 'unknown';
        my $notified_version = $chat->{_notified_update_version} || '';
        if ($version ne $notified_version) {
            $chat->display_system_message("An update is available ($version). Run " .
                $chat->colorize('/update install', 'command') . " to upgrade.");
            $chat->{_notified_update_version} = $version;
        }
    }
}

=head2 display_header

=cut

sub display_header {
    my ($self) = @_;
    my $chat = $self->{chat};

    if ($chat->{config} && !$chat->{config}->get('show_banner')) {
        return;
    }

    my $session_id = $chat->{session} ? $chat->{session}->{session_id} : 'unknown';
    my $model = $chat->{config} ? $chat->{config}->get('model') : 'unknown';

    my $provider = $chat->{config} ? $chat->{config}->get('provider') : undef;
    unless ($provider) {
        my $api_base = $chat->{config} ? $chat->{config}->get('api_base') : '';
        my $presets = $chat->{config} ? $chat->{config}->get('provider_presets') : {};
        if ($api_base && $presets) {
            for my $p (keys %$presets) {
                if ($presets->{$p}->{base} eq $api_base) {
                    $provider = $p;
                    last;
                }
            }
        }
    }

    require CLIO::Providers;
    my %provider_names;
    for my $pname (CLIO::Providers::list_providers()) {
        my $pdef = CLIO::Providers::get_provider($pname);
        $provider_names{$pname} = $pdef->{name} if $pdef && $pdef->{name};
    }
    $provider_names{'gemini'}  //= 'Google Gemini';
    $provider_names{'qwen'}    //= 'Qwen';
    $provider_names{'grok'}    //= 'xAI Grok';

    my $provider_display = $provider ? ($provider_names{$provider} || ucfirst($provider)) : 'Unknown';

    my $display_model = $model;
    if (defined $display_model && $display_model =~ m{^([a-z][a-z0-9_.-]*)/(.+)$}i && CLIO::Providers::provider_exists($1)) {
        my $model_provider = $1;
        $display_model = $2;
        $provider_display = $provider_names{$model_provider} || ucfirst($model_provider);
    }
    $display_model //= '(none configured)';
    my $model_with_provider = "$display_model\@$provider_display";

    if (!$provider) {
        $model_with_provider = 'NO PROVIDER';
        print "\n";

        my $session_name = $chat->{session} ? $chat->{session}->session_name() : undef;
        my $session_name_line = '';
        if ($session_name) {
            my $label_color = $chat->{theme_mgr}->get_color('label') || '';
            my $data_color = $chat->{theme_mgr}->get_color('value') || '';
            my $reset = $chat->{ansi}->parse('@RESET@');
            $session_name_line = "${label_color}Session:    ${data_color}${session_name}${reset}";
        }

        for my $ln (1..3) {
            my $template_key = "banner_line$ln";
            my $template = $chat->{theme_mgr}->get_template($template_key);
            next unless $template;
            my $rendered = $chat->{theme_mgr}->render($template_key, {
                session_id => $session_id,
                session_name => $session_name,
                session_name_line => $session_name_line,
                model => $model_with_provider,
                routing_verb => 'Connected',
                route_suffix => '',
            });
            my $stripped = $rendered;
            $stripped =~ s/\e\[[0-9;]*m//g;
            $stripped =~ s/^\s+//;
            $stripped =~ s/\s+$//;
            next unless length($stripped) > 0;
            print $rendered, "\n";
        }
        print "You are not connected to a provider.\n";
        my $l5_template = $chat->{theme_mgr}->get_template('banner_line5');
        if ($l5_template) {
            my $rendered = $chat->{theme_mgr}->render('banner_line5', {
                session_id => $session_id,
                session_name => $session_name,
                session_name_line => $session_name_line,
                model => $model_with_provider,
                routing_verb => 'Connected',
                route_suffix => '',
            });
            print $rendered, "\n";
        }
        print "\n";
        return;
    }

    if ($chat->{session}) {
        my $state = $chat->{session}->state();
        if ($state && $state->{api_config}) {
            my $ac = $state->{api_config};
            if ($ac->{model} || $ac->{provider} || $ac->{api_base}) {
                $model_with_provider .= " (session)";
            }
        }
    }

    # Determine routing status for banner display
    my $candidates = $chat->{config} ? $chat->{config}->get('model_candidates') : [];
    my $routing_active = ref($candidates) eq 'ARRAY' && @$candidates > 1;
    my $route_name = $chat->{config} ? $chat->{config}->get('route_name') : undef;
    my $routing_verb = $routing_active ? 'Routing' : 'Connected';
    my $route_suffix = '';
    if ($routing_active && $route_name && length($route_name)) {
        $route_suffix = " via $route_name";
    } elsif ($routing_active) {
        # Multiple --model candidates without a named route
        $route_suffix = " (" . scalar(@$candidates) . " models)";
    }

    print "\n";

    my $session_name = $chat->{session} ? $chat->{session}->session_name() : undef;
    my $session_name_line = '';
    if ($session_name) {
        my $label_color = $chat->{theme_mgr}->get_color('label') || '';
        my $data_color = $chat->{theme_mgr}->get_color('value') || '';
        my $reset = $chat->{ansi}->parse('@RESET@');
        $session_name_line = "${label_color}Session:    ${data_color}${session_name}${reset}";
    }

    my $line_num = 1;
    while (1) {
        my $template_key = "banner_line$line_num";
        my $template = $chat->{theme_mgr}->get_template($template_key);
        last unless $template;

        my $rendered = $chat->{theme_mgr}->render($template_key, {
            session_id => $session_id,
            session_name => $session_name,
            session_name_line => $session_name_line,
            model => $model_with_provider,
            routing_verb => $routing_verb,
            route_suffix => $route_suffix,
        });

        $line_num++;
        my $stripped = $rendered;
        $stripped =~ s/\e\[[0-9;]*m//g;
        $stripped =~ s/^\s+//;
        $stripped =~ s/\s+$//;
        next unless length($stripped) > 0;

        print $rendered, "\n";
    }

    print "\n";
}

=head2 _check_auth_migration

=cut

sub _check_auth_migration {
    my ($self) = @_;
    my $chat = $self->{chat};

    my $provider = $chat->{config} ? $chat->{config}->get('provider') : '';
    return unless $provider && $provider eq 'github_copilot';

    eval {
        require CLIO::Core::GitHubAuth;
        my $auth = CLIO::Core::GitHubAuth->new(debug => 0);

        my $static_key = $chat->{config}->get('api_key');
        my $api_keys = $chat->{config}->get('api_keys') || {};
        $static_key ||= $api_keys->{$provider};

        if ($static_key) {
            log_info('Chat', "Static API key configured for github_copilot, skipping GitHub auth");
            return;
        }

        my $reason = $auth->needs_reauth();
        if ($reason) {
            $chat->display_system_message($reason);
            return;
        }

        my $tokens = $auth->load_tokens();
        if (!$tokens || !$tokens->{github_token}) {
            log_info('Chat', "GitHub Copilot provider configured but no tokens found");
            eval {
                if ($chat->{command_handler} && $chat->{command_handler}{api_cmd}) {
                    $chat->{command_handler}{api_cmd}->check_github_auth();
                } else {
                    $chat->display_system_message(
                        "GitHub Copilot requires authentication. Please run /api login"
                    );
                }
            };
            if ($@) {
                log_warning('Chat', "Auth prompt failed: $@");
            }
            return;
        }

        my $validation = $auth->validate_github_token();
        if ($validation && !$validation->{valid}) {
            my $status = $validation->{status} || 'unknown';
            if ($status == 401 || $status == 403) {
                $chat->display_system_message(
                    "Your GitHub authentication has expired (HTTP $status). "
                    . "Starting re-authentication..."
                );
                $auth->clear_tokens();
                eval {
                    if ($chat->{command_handler} && $chat->{command_handler}{api_cmd}) {
                        $chat->{command_handler}{api_cmd}->handle_login_command();
                    } else {
                        $chat->display_system_message(
                            "Please run /api login to re-authenticate."
                        );
                    }
                };
                if ($@) {
                    log_warning('Chat', "Auto re-auth failed: $@");
                    $chat->display_system_message(
                        "Automatic re-authentication failed. Please run /api login manually."
                    );
                }
            } elsif ($validation->{error} && $validation->{error} =~ /Network/) {
                log_debug('Chat', "Skipping token validation - network error");
            }
        }
    };
}

=head2 _prepopulate_session_data

=cut

sub _prepopulate_session_data {
    my ($self) = @_;
    my $chat = $self->{chat};

    return unless $chat->{session};

    my $provider = $chat->{config} ? $chat->{config}->get('provider') : '';
    return unless $provider && $provider eq 'github_copilot';

    log_debug('Chat', "Prepopulating session data from CopilotUserAPI");

    eval {
        require CLIO::Core::CopilotUserAPI;
        my $user_api = CLIO::Core::CopilotUserAPI->new(debug => $chat->{debug});

        my $user_data = $user_api->get_cached_user() || $user_api->fetch_user();
        return unless $user_data;

        my $state;
        if ($chat->{session}->can('state')) {
            $state = $chat->{session}->state();
        } else {
            $state = $chat->{session};
        }
        return unless $state;

        my $premium = $user_data->get_premium_quota();
        if ($premium) {
            $state->{quota} = {
                entitlement => $premium->{entitlement},
                used => $premium->{used},
                available => $premium->{entitlement} - $premium->{used},
                percent_remaining => $premium->{percent_remaining},
                overage_used => $premium->{overage_count} || 0,
                overage_permitted => $premium->{overage_permitted},
                reset_date => $user_data->{quota_reset_date_utc} || 'unknown',
                last_updated => time(),
            };

            $state->{copilot_user} = {
                login => $user_data->{login},
                copilot_plan => $user_data->{copilot_plan},
                access_type_sku => $user_data->{access_type_sku},
            };

            log_debug('Chat', "Prepopulated quota: " . "$premium->{used}/$premium->{entitlement} " .
                "($premium->{percent_remaining}% remaining)\n");
        }

        my $model = $chat->{config}->get('model') || 'unknown';
        if ($model ne 'unknown' && !$state->{billing}{model}) {
            $state->{billing}{model} = $model;

            my $cfg_provider = $chat->{config}->get('provider') || '';
            my $model_provider = '';
            require CLIO::Providers;
            if ($model =~ m{^([a-z][a-z0-9_.-]*)/(.+)$}i && CLIO::Providers::provider_exists($1)) {
                $model_provider = $1;
            }
            if (($cfg_provider eq 'github_copilot' || $model_provider eq 'github_copilot') && (!$model_provider || $model_provider eq 'github_copilot')) {
                eval {
                    require CLIO::Core::GitHubCopilotModelsAPI;
                    my $models_api = CLIO::Core::GitHubCopilotModelsAPI->new(debug => $chat->{debug});
                    my $api_model = $model;
                    if ($api_model =~ m{^([a-z][a-z0-9_.-]*)/(.+)$}i && CLIO::Providers::provider_exists($1)) {
                        $api_model = $2;
                    }
                    my $billing = $models_api->get_model_billing($api_model);
                    if ($billing && defined $billing->{multiplier}) {
                        $state->{billing}{multiplier} = $billing->{multiplier};
                        log_debug('Chat', "Prepopulated model billing: $api_model -> " . "$billing->{multiplier}x");
                    }
                    if ($billing && $billing->{category}) {
                        $state->{billing}{category} = $billing->{category};
                    }
                    if ($billing && $billing->{vendor}) {
                        $state->{billing}{vendor} = $billing->{vendor};
                    }
                };
            }
        }
    };

    if ($@) {
        log_debug('Chat', "Prepopulation failed (non-fatal): $@");
    }
}

1;