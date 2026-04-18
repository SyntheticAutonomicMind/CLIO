# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::UI::Commands::Billing;

use strict;
use warnings;
use utf8;
use parent 'CLIO::UI::Commands::Base';

use Carp qw(croak);
use CLIO::Util::RateLimit qw(get_rate_limit_type_name);

=head1 NAME

CLIO::UI::Commands::Billing - Usage and billing commands for CLIO

=head1 SYNOPSIS

  use CLIO::UI::Commands::Billing;
  
  my $billing_cmd = CLIO::UI::Commands::Billing->new(
      chat => $chat_instance,
      session => $session,
      debug => 0
  );
  
  $billing_cmd->handle_billing_command();

=head1 DESCRIPTION

Handles usage and billing tracking commands for CLIO.
Provider-aware: displays relevant statistics based on the active provider.

- GitHub Copilot: Account info, premium request multipliers, quota status
- MiniMax: Token usage summary (quota via /api quota)
- Other providers: Generic token usage summary

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        chat => $args{chat} || croak "chat instance required",
        debug => $args{debug} // 0,
    };
    
    $self->{session} = $args{session};
    
    bless $self, $class;
    return $self;
}


=head2 handle_billing_command(@args)

Display API usage and billing statistics.
Routes to provider-specific display based on the active provider.

=cut

sub handle_billing_command {
    my ($self, @args) = @_;
    
    unless ($self->{session}) {
        $self->display_error_message("No active session");
        return;
    }
    
    unless ($self->{session}->can('get_billing_summary')) {
        $self->display_error_message("Usage tracking not available in this session");
        return;
    }
    
    my $billing = $self->{session}->get_billing_summary();
    
    # Determine active provider
    my $provider = $self->_get_active_provider();
    my $provider_display = $self->_get_provider_display_name($provider);
    
    # Display provider-appropriate header
    $self->display_command_header("API USAGE - $provider_display");
    
    # Route to provider-specific display
    if ($provider eq 'github_copilot') {
        $self->_display_copilot_billing($billing);
    } elsif ($provider eq 'zai' || $provider eq 'zai_coding') {
        $self->_display_zai_billing($billing, $provider, $provider_display);
    } else {
        $self->_display_generic_billing($billing, $provider, $provider_display);
    }
}

=head2 _get_active_provider()

Determine the active provider from config or session state.

=cut

sub _get_active_provider {
    my ($self) = @_;
    
    # Check session state first (may have been set during model selection)
    if ($self->{session}{state} && $self->{session}{state}{selected_provider}) {
        return $self->{session}{state}{selected_provider};
    }
    
    # Fall back to config
    my $chat = $self->{chat};
    if ($chat && $chat->{config}) {
        return $chat->{config}->get('provider') || 'unknown';
    }
    
    return 'unknown';
}

=head2 _get_provider_display_name($provider)

Get a human-readable display name for a provider.

=cut

sub _get_provider_display_name {
    my ($self, $provider) = @_;
    
    eval { require CLIO::Providers; };
    if (!$@) {
        my $pdef = CLIO::Providers::get_provider($provider);
        return $pdef->{name} if $pdef && $pdef->{name};
    }
    
    return ucfirst($provider || 'Unknown');
}

=head2 _display_copilot_billing($billing)

Display GitHub Copilot-specific billing with account info, multipliers, and quota.

=cut

sub _display_copilot_billing {
    my ($self, $billing) = @_;

    my $provider = 'github_copilot';

    # Try cache first, fall back to fresh fetch to ensure current quota data
    # This is important when returning from a wait state or at session start
    my $user_data;
    eval {
        require CLIO::Core::CopilotUserAPI;
        my $user_api = CLIO::Core::CopilotUserAPI->new(debug => $self->{debug});
        $user_data = $user_api->get_cached_user() || $user_api->fetch_user();
    };
    
    # Show account info
    my $login = undef;
    my $plan = undef;
    
    if ($self->{session}{copilot_user}) {
        $login = $self->{session}{copilot_user}{login};
        $plan = $self->{session}{copilot_user}{copilot_plan};
    }
    
    if (!$login && $user_data) {
        $login = $user_data->{login};
        $plan = $user_data->{copilot_plan};
    }
    
    if ($login || $plan) {
        $self->display_section_header("Account");
        $self->writeline(sprintf("  %-25s %s", "Username:", $self->colorize($login || 'unknown', 'DATA')), markdown => 0);
        $self->writeline(sprintf("  %-25s %s", "Plan:", $self->colorize($plan || 'unknown', 'DATA')), markdown => 0);
    }
    
    # Get model and multiplier
    my $model = $self->{session}{state}{billing}{model} 
             || $self->{session}{billing}{model}
             || 'unknown';
    my $multiplier = $self->{session}{state}{billing}{multiplier} 
                  || $self->{session}{billing}{multiplier}
                  || 0;
    
    my $multiplier_str = $self->_format_multiplier($multiplier);
    
    # Session summary
    $self->display_section_header("Session Summary");
    $self->writeline(sprintf("  %-25s %s", "Model:", $self->colorize($model, 'DATA')), markdown => 0);
    $self->writeline(sprintf("  %-25s %s", "Billing Rate:", $self->colorize($multiplier_str, 'DATA')), markdown => 0);
    
    my $total_api_requests = $billing->{total_requests} || 0;
    my $total_premium_charged = $billing->{total_premium_requests} || 0;
    
    $self->writeline(sprintf("  %-25s %s", "API Requests:", $self->colorize($total_api_requests, 'DATA')), markdown => 0);
    $self->writeline(sprintf("  %-25s %s", "Premium Requests Charged:", $self->colorize($total_premium_charged, 'DATA')), markdown => 0);
    
    # Quota section
    my $quota = $self->{session}{quota} 
             || $self->{session}{state}{quota};
    
    if ($quota) {
        my $entitlement = $quota->{entitlement} || 0;
        my $used = $quota->{used} || 0;
        my $percent_used = $entitlement > 0 ? (100.0 - ($quota->{percent_remaining} || 0)) : 0;
        my $reset_date = $quota->{reset_date} || '';
        
        if ($entitlement > 0) {
            $self->display_section_header("Premium Quota");
            
            my $status_color = 'DATA';
            if ($percent_used >= 95) {
                $status_color = 'ERROR';
            } elsif ($percent_used >= 80) {
                $status_color = 'WARN';
            } elsif ($percent_used >= 50) {
                $status_color = 'LABEL';
            }
            
            my $status_str = sprintf("%d used of %d (%.1f%%)", $used, $entitlement, $percent_used);
            $self->writeline(sprintf("  %-25s %s", 
                "Status:", 
                $self->colorize($status_str, $status_color)), markdown => 0);
            
            my $overage = $quota->{overage_used} || 0;
            if ($overage > 0) {
                my $overage_str = sprintf("+%d overage", $overage);
                if ($quota->{overage_permitted}) {
                    $overage_str .= " (permitted)";
                }
                $self->writeline(sprintf("  %-25s %s", "Overage:", 
                    $self->colorize($overage_str, 'WARN')), markdown => 0);
            }
            
            if ($reset_date && $reset_date ne 'unknown') {
                my $reset_display = $reset_date;
                $reset_display =~ s/T.*//;
                $self->writeline(sprintf("  %-25s %s",
                    "Resets:",
                    $self->colorize($reset_display, 'DIM')), markdown => 0);
            }
        }
    }

    # Rate limit status section (scoped to current provider)
    my ($rate_limit_used, $rate_limit_until, $rate_limit_code);

    if ($self->{session}->can('state')) {
        my $state = $self->{session}->state();
        my $rl = $state->{rate_limits} && $state->{rate_limits}{$provider} ? $state->{rate_limits}{$provider} : {};
        $rate_limit_used = $rl->{rate_limit_quota_used};
        $rate_limit_until = $rl->{rate_limit_until};
        $rate_limit_code = $rl->{rate_limit_code};
    }

    if (defined $rate_limit_used || $rate_limit_until || $rate_limit_code) {
        $self->display_section_header("Rate Limit Status");

        # Display rate limit type if available
        if ($rate_limit_code) {
            my $type_name = get_rate_limit_type_name($rate_limit_code);
            $self->writeline(sprintf("  %-25s %s",
                "Type:",
                $self->colorize($type_name, 'WARN')), markdown => 0);
        }

        if (defined $rate_limit_used) {
            my $rl_color = 'DATA';
            if ($rate_limit_used >= 95) {
                $rl_color = 'ERROR';
            } elsif ($rate_limit_used >= 80) {
                $rl_color = 'WARN';
            }
            $self->writeline(sprintf("  %-25s %s%%",
                "Quota Used:",
                $self->colorize(sprintf("%.1f%%", $rate_limit_used), $rl_color)), markdown => 0);
        }

        if ($rate_limit_until && $rate_limit_until > time()) {
            my $wait_seconds = int($rate_limit_until - time());
            
            # Check if this is a weekly/monthly limit (not a retry cooldown)
            if ($rate_limit_code && $rate_limit_code =~ /user_weekly_rate_limited|user_monthly_rate_limited/i) {
                # Show "Weekly/Monthly Limit" instead of misleading cooldown countdown
                $self->writeline(sprintf("  %-25s %s",
                    "Status:",
                    $self->colorize("Weekly/Monthly Limit Active", 'WARN')), markdown => 0);
                $self->writeline(sprintf("  %-25s %s",
                    "Note:",
                    $self->colorize("Check API docs for reset time", 'DIM')), markdown => 0);
            } else {
                # Regular rate limit cooldown
                my $wait_minutes = int($wait_seconds / 60);
                my $wait_secs = $wait_seconds % 60;
                my $wait_str = $wait_minutes > 0
                    ? sprintf("%dm %02ds", $wait_minutes, $wait_secs)
                    : sprintf("%ds", $wait_seconds);
                $self->writeline(sprintf("  %-25s %s",
                    "Cooldown Remaining:",
                    $self->colorize($wait_str, 'WARN')), markdown => 0);
            }
        }
    }

    # Token usage
    $self->_display_token_usage($billing);
    
    # Premium warning
    $self->_display_premium_warning($multiplier);
    
    # Recent requests with multipliers
    $self->_display_recent_requests($billing, show_rate => 1);
    
    $self->writeline("", markdown => 0);
    $self->writeline($self->colorize("Multipliers indicate premium model usage relative to free models.", 'DIM'), markdown => 0);
    $self->writeline($self->colorize("Use /api quota for detailed quota status.", 'DIM'), markdown => 0);
    $self->writeline("", markdown => 0);
}

=head2 _display_generic_billing($billing, $provider, $provider_display)

Display generic billing for non-Copilot providers.
Shows token usage, request counts, and recent request history.

=cut

sub _display_generic_billing {
    my ($self, $billing, $provider, $provider_display) = @_;
    
    # Get model from session
    my $model = $self->{session}{state}{billing}{model} 
             || $self->{session}{billing}{model}
             || 'unknown';
    
    # Session summary
    $self->display_section_header("Session Summary");
    $self->writeline(sprintf("  %-25s %s", "Provider:", $self->colorize($provider_display, 'DATA')), markdown => 0);
    $self->writeline(sprintf("  %-25s %s", "Model:", $self->colorize($model, 'DATA')), markdown => 0);
    
    my $total_api_requests = $billing->{total_requests} || 0;
    $self->writeline(sprintf("  %-25s %s", "API Requests:", $self->colorize($total_api_requests, 'DATA')), markdown => 0);
    
    # Token usage
    $self->_display_token_usage($billing);
    
    # Recent requests (no rate column for non-Copilot)
    $self->_display_recent_requests($billing, show_rate => 0);
    
    # Provider-specific hints
    my $has_quota = ($provider eq 'minimax' || $provider eq 'minimax_token');
    if ($has_quota) {
        $self->writeline("", markdown => 0);
        $self->writeline($self->colorize("Use /api quota for token plan balance and usage details.", 'DIM'), markdown => 0);
    }
    
    $self->writeline("", markdown => 0);
}

=head2 _display_zai_billing($billing, $provider, $provider_display)

Display Z.AI-specific billing with plan info, peak hour status, and model cost multipliers.

=cut

sub _display_zai_billing {
    my ($self, $billing, $provider, $provider_display) = @_;
    
    # Get model from session
    my $model = $self->{session}{state}{billing}{model}
             || $self->{session}{billing}{model}
             || $self->{session}{selected_model}
             || 'unknown';
    
    # Strip provider prefix for display
    my $display_model = $model;
    $display_model =~ s{^(?:zai|zai_coding)/}{};
    
    # Determine plan type
    my $is_coding_plan = ($provider eq 'zai_coding');
    my $plan_label = $is_coding_plan ? 'Coding Plan' : 'Pay-as-you-go';
    
    # Session summary
    $self->display_section_header("Session Summary");
    $self->writeline(sprintf("  %-25s %s", "Provider:", $self->colorize($provider_display, 'DATA')), markdown => 0);
    $self->writeline(sprintf("  %-25s %s", "Plan:", $self->colorize($plan_label, 'DATA')), markdown => 0);
    $self->writeline(sprintf("  %-25s %s", "Model:", $self->colorize($display_model, 'DATA')), markdown => 0);
    
    my $total_api_requests = $billing->{total_requests} || 0;
    $self->writeline(sprintf("  %-25s %s", "API Requests:", $self->colorize($total_api_requests, 'DATA')), markdown => 0);
    
    # Peak hour and cost multiplier section (Coding Plan only)
    if ($is_coding_plan) {
        $self->display_section_header("Coding Plan Status");
        
        # Calculate CST time for peak hour detection
        my @now = gmtime(time());
        my $utc_hour = $now[2];
        my $cst_hour = ($utc_hour + 8) % 24;
        my $is_peak = ($cst_hour >= 14 && $cst_hour < 18);
        
        # Current CST time display
        my $cst_time_str = sprintf("%02d:%02d CST (UTC+8)", $cst_hour, $now[1]);
        $self->writeline(sprintf("  %-25s %s", "Current Time:",
            $self->colorize($cst_time_str, 'DATA')), markdown => 0);
        
        # Peak hour status
        if ($is_peak) {
            $self->writeline(sprintf("  %-25s %s", "Peak Hours:",
                $self->colorize("ACTIVE (14:00-18:00 CST)", 'WARN')), markdown => 0);
        } else {
            my $next_peak;
            if ($cst_hour < 14) {
                my $hours_until = 14 - $cst_hour;
                $next_peak = sprintf("in %dh", $hours_until);
            } else {
                # After peak, next peak is tomorrow
                my $hours_until = 24 - $cst_hour + 14;
                $next_peak = sprintf("in %dh", $hours_until);
            }
            $self->writeline(sprintf("  %-25s %s", "Peak Hours:",
                $self->colorize("Off-peak (next peak $next_peak)", 'DATA')), markdown => 0);
        }
        
        # Model cost multiplier
        my $model_lc = lc($display_model);
        my $is_glm5 = ($model_lc =~ /^glm-5/);
        my $cost_multiplier = $is_glm5 ? ($is_peak ? 3 : 2) : 1;
        my $mult_color = $cost_multiplier >= 3 ? 'WARN' : $cost_multiplier >= 2 ? 'LABEL' : 'DATA';
        my $mult_str = $cost_multiplier == 1 ? '1x (standard)' : "${cost_multiplier}x quota";
        
        $self->writeline(sprintf("  %-25s %s", "Cost Rate:",
            $self->colorize($mult_str, $mult_color)), markdown => 0);
        
        # GLM-5.x off-peak promotion note (valid through April 2026)
        if ($is_glm5 && !$is_peak) {
            $self->writeline(sprintf("  %-25s %s", "Promo:",
                $self->colorize("1x off-peak (through April)", 'DATA')), markdown => 0);
        }
        
        # Quota window info
        my $state = $self->{session}->can('state') ? $self->{session}->state() : $self->{session};
        if ($state) {
            my $peak_flag = $state->{zai_peak_hour};
            my $peak_mult = $state->{zai_peak_multiplier};
        }
        
        $self->writeline(sprintf("  %-25s %s", "Quota Window:",
            $self->colorize("Rolling 5-hour", 'DATA')), markdown => 0);
        $self->writeline("", markdown => 0);
    }

    # Rate limit status section
    my ($rate_limit_until, $rate_limit_code);

    if ($self->{session}->can('state')) {
        my $state = $self->{session}->state();
        my $rl = $state->{rate_limits} && $state->{rate_limits}{$provider} ? $state->{rate_limits}{$provider} : {};
        $rate_limit_until = $rl->{rate_limit_until};
        $rate_limit_code = $rl->{rate_limit_code};
    }

    if (defined $rate_limit_until || $rate_limit_code) {
        $self->display_section_header("Rate Limit Status");
        
        if ($rate_limit_code) {
            my $type_name = get_rate_limit_type_name($rate_limit_code);
            $self->writeline(sprintf("  %-25s %s",
                "Type:",
                $self->colorize($type_name, 'WARN')), markdown => 0);
        }
        
        if ($rate_limit_until && $rate_limit_until > time()) {
            my $wait_seconds = int($rate_limit_until - time());
            my $wait_minutes = int($wait_seconds / 60);
            my $wait_secs = $wait_seconds % 60;
            my $wait_str = $wait_minutes > 0
                ? sprintf("%dm %02ds", $wait_minutes, $wait_secs)
                : sprintf("%ds", $wait_seconds);
            $self->writeline(sprintf("  %-25s %s",
                "Cooldown:",
                $self->colorize($wait_str, 'WARN')), markdown => 0);
        }
        
        # Z.AI usage limit (code 1308) shows reset time from error message
        if ($rate_limit_code && $rate_limit_code eq 'zai_usage_limit') {
            my $state = $self->{session}->can('state') ? $self->{session}->state() : $self->{session};
            if ($state && $state->{zai_reset_time}) {
                $self->writeline(sprintf("  %-25s %s",
                    "Resets At:",
                    $self->colorize($state->{zai_reset_time}, 'DATA')), markdown => 0);
            }
        }
    }
    
    # Token usage
    $self->_display_token_usage($billing);
    
    # Recent requests
    $self->_display_recent_requests($billing, show_rate => 0);
    
    $self->writeline("", markdown => 0);
}

=head2 _display_token_usage($billing)

Display the token usage section (shared across all providers).

=cut

sub _display_token_usage {
    my ($self, $billing) = @_;
    
    $self->display_section_header("Token Usage");
    
    my $total = $billing->{total_tokens} || 0;
    my $prompt = $billing->{total_prompt_tokens} || 0;
    my $completion = $billing->{total_completion_tokens} || 0;
    
    $self->writeline(sprintf("  %-25s %s", "Total Tokens:", $self->colorize(_format_number($total), 'DATA')), markdown => 0);
    $self->writeline(sprintf("  %-25s %s", "  Input:", _format_number($prompt) . " tokens"), markdown => 0);
    $self->writeline(sprintf("  %-25s %s", "  Output:", _format_number($completion) . " tokens"), markdown => 0);
}

=head2 _format_multiplier($multiplier)

Format multiplier as display string.

=cut

sub _format_multiplier {
    my ($self, $multiplier) = @_;
    
    if ($multiplier == 0) {
        return "Free (0x)";
    } elsif ($multiplier == int($multiplier)) {
        return sprintf("%dx Premium", $multiplier);
    } else {
        my $str = sprintf("%.2fx Premium", $multiplier);
        $str =~ s/\.?0+x/x/;
        return $str;
    }
}

=head2 _display_premium_warning($multiplier)

Display informational billing rate notice (Copilot only).

=cut

sub _display_premium_warning {
    my ($self, $multiplier) = @_;
    
    return if $multiplier == 0;
    
    my $mult_display;
    if ($multiplier == int($multiplier)) {
        $mult_display = sprintf("%dx", $multiplier);
    } else {
        $mult_display = sprintf("%.2fx", $multiplier);
        $mult_display =~ s/\.?0+x$/x/;
    }
    
    my $msg = "This model has a $mult_display billing rate. You will be billed at this rate for all new user requests sent to the provider.";
    $self->display_system_message($msg);
    $self->writeline("", markdown => 0);
}

=head2 _display_recent_requests($billing, %opts)

Display recent requests table.

Options:
  show_rate => 1  - Show billing rate column (Copilot only)

=cut

sub _display_recent_requests {
    my ($self, $billing, %opts) = @_;
    my $show_rate = $opts{show_rate} // 0;
    
    return unless $billing->{requests} && @{$billing->{requests}};
    
    my @recent = @{$billing->{requests}};
    @recent = @recent[-10..-1] if @recent > 10;
    
    return unless @recent;
    
    $self->writeline($self->colorize("Recent Requests:", 'LABEL'), markdown => 0);
    
    if ($show_rate) {
        $self->writeline($self->colorize(sprintf("  %-5s %-25s %-12s %-12s", 
            "#", "Model", "Tokens", "Rate"), 'LABEL'), markdown => 0);
    } else {
        $self->writeline($self->colorize(sprintf("  %-5s %-25s %-12s %-12s", 
            "#", "Model", "Input", "Output"), 'LABEL'), markdown => 0);
    }
    
    my $count = 1;
    for my $req (@recent) {
        my $req_model = $req->{model} || 'unknown';
        $req_model = substr($req_model, 0, 23) . ".." if length($req_model) > 25;
        
        if ($show_rate) {
            my $req_multiplier = $req->{multiplier} || 0;
            my $rate_str;
            if ($req_multiplier == 0) {
                $rate_str = "Free (0x)";
            } elsif ($req_multiplier == int($req_multiplier)) {
                $rate_str = sprintf("%dx", $req_multiplier);
            } else {
                $rate_str = sprintf("%.2fx", $req_multiplier);
                $rate_str =~ s/\.?0+x$/x/;
            }
            
            $self->writeline(sprintf("  %-5s %-25s %-12s %-12s",
                $count,
                $req_model,
                $req->{total_tokens},
                $rate_str), markdown => 0);
        } else {
            $self->writeline(sprintf("  %-5s %-25s %-12s %-12s",
                $count,
                $req_model,
                $req->{prompt_tokens} || 0,
                $req->{completion_tokens} || 0), markdown => 0);
        }
        $count++;
    }
    $self->writeline("", markdown => 0);
}

=head2 _format_number($n)

Format a number with comma separators.

=cut

sub _format_number {
    my ($n) = @_;
    $n //= 0;
    my $formatted = "$n";
    $formatted =~ s/(\d)(?=(\d{3})+$)/$1,/g;
    return $formatted;
}


1;

__END__

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

Same as CLIO.

=cut

1;
