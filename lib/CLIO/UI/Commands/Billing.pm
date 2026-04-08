# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::UI::Commands::Billing;

use strict;
use warnings;
use utf8;
use parent 'CLIO::UI::Commands::Base';

use Carp qw(croak);

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
    
    # Try to fetch user data from CopilotUserAPI for richer info
    my $user_data;
    eval {
        require CLIO::Core::CopilotUserAPI;
        my $user_api = CLIO::Core::CopilotUserAPI->new(debug => $self->{debug});
        $user_data = $user_api->get_cached_user();
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

Display warning for premium model usage (Copilot only).

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
    
    my $msg = "Premium Model Usage: $mult_display billing multiplier. Excessive use may impact your subscription.";
    $self->{chat}->display_warning_message($msg);
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
