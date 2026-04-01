# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::UI::Commands::API::Auth;

use strict;
use warnings;
use utf8;
use parent 'CLIO::UI::Commands::Base';

use Carp qw(croak);
use CLIO::UI::Terminal qw(box_char ui_char);
use CLIO::Core::Logger qw(log_debug log_warning);
use CLIO::Util::JSON qw(decode_json);

=head1 NAME

CLIO::UI::Commands::API::Auth - Authentication commands for CLIO API

=head1 DESCRIPTION

Handles /api login, /api logout, and /api quota commands.
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

sub check_github_auth {
    my ($self) = @_;

    require CLIO::Core::GitHubAuth;
    my $gh_auth = CLIO::Core::GitHubAuth->new(debug => $self->{debug});

    unless ($gh_auth->is_authenticated()) {
        $self->writeline("", markdown => 0);
        $self->display_system_message("GitHub Copilot requires authentication");

        my ($header, $input_line) = @{$self->{chat}{theme_mgr}->get_confirmation_prompt(
            "Login now?",
            "yes/no",
            "skip"
        )};

        print $header, "\n";
        print $input_line;
        my $response = <STDIN>;
        chomp $response if defined $response;

        if ($response && $response =~ /^y(es)?$/i) {
            $self->handle_login();
        } else {
            $self->display_system_message("You can login later with: /api login");
        }
    }
}

sub handle_login {
    my ($self, @args) = @_;

    require CLIO::Core::GitHubAuth;

    my $auth = CLIO::Core::GitHubAuth->new(debug => $self->{debug});

    if ($auth->is_authenticated()) {
        my $username = $auth->get_username() || 'unknown';
        $self->display_system_message("Already authenticated as: $username");
        $self->display_system_message("Use /logout to sign out first");
        return;
    }

    $self->writeline("", markdown => 0);
    $self->writeline(box_char('hhorizontal') x 54, markdown => 0);
    $self->writeline($self->colorize("GITHUB COPILOT AUTHENTICATION", 'DATA'), markdown => 0);
    $self->writeline(box_char('hhorizontal') x 54, markdown => 0);
    $self->writeline("", markdown => 0);

    $self->writeline($self->colorize("Step 1:", 'PROMPT') . " Requesting device code from GitHub...", markdown => 0);

    my $device_data;
    eval { $device_data = $auth->start_device_flow(); };
    if ($@) {
        $self->display_error_message("Failed to start device flow: $@");
        return;
    }

    $self->writeline("", markdown => 0);
    $self->writeline($self->colorize("Step 2:", 'PROMPT') . " Authorize in your browser", markdown => 0);
    $self->writeline("", markdown => 0);
    $self->writeline("  1. Visit: " . $self->colorize($device_data->{verification_uri}, 'USER'), markdown => 0);
    $self->writeline("  2. Enter code: " . $self->colorize($device_data->{user_code}, 'DATA'), markdown => 0);
    $self->writeline("", markdown => 0);

    $self->writeline("  " . $self->colorize("Waiting for authorization...", 'DIM') . " (this may take a few minutes)", markdown => 0);

    my $github_token;
    eval {
        $github_token = $auth->poll_for_token(
            $device_data->{device_code},
            $device_data->{interval}
        );
    };

    if ($@) {
        $self->writeline("", markdown => 0);
        $self->display_error_message("Authentication failed: $@");
        return;
    }

    unless ($github_token) {
        $self->writeline("", markdown => 0);
        $self->display_error_message("Authentication timed out");
        return;
    }

    $self->writeline($self->colorize("", 'PROMPT') . " Authorized!", markdown => 0);
    $self->writeline("", markdown => 0);

    $self->writeline($self->colorize("Step 3:", 'PROMPT') . " Exchanging for Copilot token...", markdown => 0);

    my $copilot_token;
    eval { $copilot_token = $auth->exchange_for_copilot_token($github_token); };
    if ($@) {
        $self->display_error_message("Failed to exchange for Copilot token: $@");
        return;
    }

    if ($copilot_token) {
        $self->writeline("  " . $self->colorize("", 'PROMPT') . " Copilot token obtained", markdown => 0);
    } else {
        $self->writeline("  " . $self->colorize("[ ]", 'DIM') . " Copilot token unavailable (will use GitHub token directly)", markdown => 0);
    }
    $self->writeline("", markdown => 0);

    $self->writeline($self->colorize("Step 4:", 'PROMPT') . " Saving tokens...", markdown => 0);

    eval { $auth->save_tokens($github_token, $copilot_token); };
    if ($@) {
        $self->display_error_message("Failed to save tokens: $@");
        return;
    }

    $self->writeline("  " . $self->colorize("", 'PROMPT') . " Tokens saved to ~/.clio/github_tokens.json", markdown => 0);
    $self->writeline("", markdown => 0);

    $self->writeline(box_char('hhorizontal') x 54, markdown => 0);
    $self->writeline($self->colorize("SUCCESS!", 'PROMPT'), markdown => 0);
    $self->writeline(box_char('hhorizontal') x 54, markdown => 0);
    $self->writeline("", markdown => 0);

    if ($copilot_token) {
        my $username = $copilot_token->{username} || 'unknown';
        my $expires_in = int(($copilot_token->{expires_at} - time()) / 60);
        $self->display_system_message("Authenticated as: $username");
        $self->display_system_message("Token expires in: ~$expires_in minutes");
        $self->display_system_message("Token will auto-refresh before expiration");
    } else {
        $self->display_system_message("Authenticated with GitHub token");
        $self->display_system_message("Using GitHub token directly (Copilot endpoint unavailable)");
    }
    $self->writeline("", markdown => 0);

    $self->reinit_api_manager();
    log_debug('API', "APIManager reloaded successfully");
}

sub handle_logout {
    my ($self, @args) = @_;

    require CLIO::Core::GitHubAuth;

    my $auth = CLIO::Core::GitHubAuth->new(debug => $self->{debug});

    unless ($auth->is_authenticated()) {
        $self->display_system_message("Not currently authenticated");
        return;
    }

    my $username = $auth->get_username() || 'unknown';
    $auth->clear_tokens();
    $self->display_system_message("Signed out from GitHub (was: $username)");
    $self->display_system_message("Use /login to authenticate again");
}

sub handle_quota {
    my ($self, @args) = @_;

    my $refresh = 0;
    @args = grep {
        if ($_ eq '--refresh') { $refresh = 1; 0; } else { 1; }
    } @args;

    my $provider = $self->{config}->get('provider') || '';
    if ($provider =~ /^minimax/) {
        $self->_handle_minimax_quota($refresh);
        return;
    }

    eval { require CLIO::Core::CopilotUserAPI; };
    if ($@) {
        $self->display_error_message("CopilotUserAPI not available: $@");
        return;
    }

    my $api = CLIO::Core::CopilotUserAPI->new(
        debug     => $self->{debug},
        cache_ttl => $refresh ? 0 : 300,
    );

    my $user;
    if ($refresh) {
        $user = $api->fetch_user();
    } else {
        $user = $api->get_cached_user() || $api->fetch_user();
    }

    unless ($user) {
        $self->display_error_message("Failed to fetch Copilot quota: $@");
        $self->display_system_message("Make sure you're authenticated with /api login");
        return;
    }

    $self->display_command_header("GITHUB COPILOT QUOTA");

    $self->display_section_header("Account");
    $self->writeline(sprintf("  %-20s %s", "Login:", $self->colorize($user->{login} || 'unknown', 'USER')), markdown => 0);
    $self->writeline(sprintf("  %-20s %s", "Plan:", $self->colorize($user->{copilot_plan} || 'unknown', 'DATA')), markdown => 0);
    $self->writeline("", markdown => 0);

    if ($user->{premium_usage}) {
        my $pu = $user->{premium_usage};
        my $used = $pu->{used} // 0;
        my $entitlement = $pu->{entitlement} // 0;
        my $overage = $pu->{overage_enabled} ? 'enabled' : 'disabled';

        $self->display_section_header("Premium Quota");

        my $pct = $entitlement > 0 ? sprintf("%.1f%%", ($used / $entitlement) * 100) : 'N/A';
        my $pct_color = 'PROMPT';
        if ($entitlement > 0) {
            my $ratio = $used / $entitlement;
            $pct_color = $ratio > 0.9 ? 'ERROR' : $ratio > 0.7 ? 'SYSTEM' : 'PROMPT';
        }

        $self->writeline(sprintf("  %-20s %s / %s (%s)",
            "Usage:", $self->colorize($used, 'DATA'), $self->colorize($entitlement, 'DATA'),
            $self->colorize($pct, $pct_color)), markdown => 0);
        $self->writeline(sprintf("  %-20s %s", "Overage:", $self->colorize($overage, 'DIM')), markdown => 0);

        if ($pu->{reset_date}) {
            $self->writeline(sprintf("  %-20s %s", "Resets:", $self->colorize($pu->{reset_date}, 'DIM')), markdown => 0);
        }

        if ($entitlement > 0) {
            my $ratio = $used / $entitlement;
            my $bar_width = 40;
            my $filled = int($ratio * $bar_width);
            $filled = $bar_width if $filled > $bar_width;
            my $empty = $bar_width - $filled;
            my $bar_color = $ratio > 0.9 ? 'ERROR' : $ratio > 0.7 ? 'SYSTEM' : 'PROMPT';
            my $bar = $self->colorize(ui_char("filled_block") x $filled, $bar_color) . $self->colorize(ui_char("light_shade") x $empty, "DIM");
            $self->writeline("", markdown => 0);
            $self->writeline("  [$bar]", markdown => 0);
        }
    }

    $self->writeline("", markdown => 0);
    $self->display_system_message("Use /api quota --refresh to bypass cache");
}

sub _handle_minimax_quota {
    my ($self, $refresh) = @_;

    my $api_key = $self->{config}->get('api_key') || $self->{config}->get_provider_key('minimax');
    unless ($api_key) {
        $self->display_error_message("No MiniMax API key configured");
        $self->display_system_message("Set it with: /api set key <your-minimax-key>");
        return;
    }

    $self->display_system_message("Fetching MiniMax Token Plan usage...");

    eval { require CLIO::Compat::HTTP; };
    if ($@) {
        $self->display_error_message("HTTP client not available: $@");
        return;
    }

    my $ua = CLIO::Compat::HTTP->new(timeout => 15);
    my $url = 'https://api.minimax.io/v1/token_plan/usage';
    my $resp = $ua->get($url, headers => {
        'Authorization' => "Bearer $api_key",
        'Accept'        => 'application/json',
    });

    unless ($resp->is_success) {
        $self->display_error_message("Failed to fetch MiniMax quota: HTTP " . $resp->code);
        return;
    }

    my $data;
    eval { $data = decode_json($resp->decoded_content); };
    if ($@) {
        $self->display_error_message("Failed to parse MiniMax quota response: $@");
        return;
    }

    unless ($data->{base_resp} && $data->{base_resp}{status_code} == 0) {
        my $msg = $data->{base_resp}{status_msg} || 'Unknown error';
        $self->display_error_message("MiniMax API error: $msg");
        return;
    }

    $self->display_command_header("MINIMAX TOKEN PLAN QUOTA");

    if ($data->{total_tokens_left}) {
        $self->display_section_header("Token Balance");
        $self->writeline(sprintf("  %-20s %s",
            "Tokens remaining:",
            $self->colorize(sprintf("%s", $data->{total_tokens_left}), 'DATA')),
            markdown => 0);
    }

    if ($data->{plan_usages} && @{$data->{plan_usages}}) {
        $self->writeline("", markdown => 0);
        $self->display_section_header("Active Plans");

        for my $plan (@{$data->{plan_usages}}) {
            my $name = $plan->{name} || 'Unknown Plan';
            my $total = $plan->{total} || 0;
            my $used  = $plan->{used}  || 0;
            my $left  = $total - $used;
            my $pct   = $total > 0 ? sprintf("%.1f%%", ($used / $total) * 100) : 'N/A';
            my $expire = $plan->{expire_at} || 'N/A';

            my $pct_color = 'PROMPT';
            if ($total > 0) {
                my $ratio = $used / $total;
                $pct_color = $ratio > 0.9 ? 'ERROR' : $ratio > 0.7 ? 'SYSTEM' : 'PROMPT';
            }

            $self->writeline("  " . $self->colorize($name, 'USER'), markdown => 0);
            $self->writeline(sprintf("    %-18s %s / %s (%s)",
                "Usage:", $self->colorize($used, 'DATA'), $self->colorize($total, 'DATA'),
                $self->colorize($pct, $pct_color)), markdown => 0);
            $self->writeline(sprintf("    %-18s %s", "Remaining:", $self->colorize($left, 'DATA')), markdown => 0);
            $self->writeline(sprintf("    %-18s %s", "Expires:", $self->colorize($expire, 'DIM')), markdown => 0);

            if ($total > 0) {
                my $ratio = $used / $total;
                my $bar_width = 40;
                my $filled = int($ratio * $bar_width);
                $filled = $bar_width if $filled > $bar_width;
                my $empty = $bar_width - $filled;
                my $bar_color = $ratio > 0.9 ? 'ERROR' : $ratio > 0.7 ? 'SYSTEM' : 'PROMPT';
                my $bar = $self->colorize(ui_char("filled_block") x $filled, $bar_color) . $self->colorize(ui_char("light_shade") x $empty, "DIM");
                $self->writeline("    [$bar]", markdown => 0);
            }
            $self->writeline("", markdown => 0);
        }
    }

    $self->writeline("", markdown => 0);
    $self->display_system_message("Use /api quota --refresh to bypass cache");
}

sub reinit_api_manager {
    my ($self) = @_;

    log_debug('API', "Re-initializing APIManager after config change");

    my $broker_client = $self->{ai_agent}->{api} ? $self->{ai_agent}->{api}{broker_client} : undef;

    require CLIO::Core::APIManager;
    my $new_api = CLIO::Core::APIManager->new(
        debug         => $self->{debug},
        session       => $self->{session}->state(),
        config        => $self->{config},
        broker_client => $broker_client,
    );
    $self->{ai_agent}->{api} = $new_api;

    if ($self->{ai_agent}->{orchestrator}) {
        $self->{ai_agent}->{orchestrator}->{api_manager} = $new_api;
        log_debug('API', "Orchestrator's api_manager updated after config change");
    }
}

1;

__END__

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

Same as CLIO.

=cut
