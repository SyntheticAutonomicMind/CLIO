package CLIO::UI::Commands::Billing;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Carp qw(croak);
use CLIO::Core::Logger qw(should_log);

=head1 NAME

CLIO::UI::Commands::Billing - Billing and usage commands for CLIO

=head1 SYNOPSIS

  use CLIO::UI::Commands::Billing;
  
  my $billing_cmd = CLIO::UI::Commands::Billing->new(
      chat => $chat_instance,
      session => $session,
      debug => 0
  );
  
  # Handle /billing command
  $billing_cmd->handle_billing_command();

=head1 DESCRIPTION

Handles billing and usage tracking commands for CLIO.
Displays API usage statistics and billing information.

Extracted from Chat.pm to improve maintainability.

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        chat => $args{chat} || croak "chat instance required",
        debug => $args{debug} // 0,
    };
    
    # Assign object references separately (hash literal assignment bug workaround)
    $self->{session} = $args{session};
    
    bless $self, $class;
    return $self;
}

# Delegate display methods to chat
sub display_system_message { shift->{chat}->display_system_message(@_) }
sub display_error_message { shift->{chat}->display_error_message(@_) }
sub display_command_header { shift->{chat}->display_command_header(@_) }
sub display_section_header { shift->{chat}->display_section_header(@_) }
sub writeline { shift->{chat}->writeline(@_) }
sub colorize { shift->{chat}->colorize(@_) }

=head2 handle_billing_command(@args)

Display API usage and billing statistics.

=cut

sub handle_billing_command {
    my ($self, @args) = @_;
    
    unless ($self->{session}) {
        $self->display_error_message("No active session");
        return;
    }
    
    unless ($self->{session}->can('get_billing_summary')) {
        $self->display_error_message("Billing tracking not available in this session");
        return;
    }
    
    my $billing = $self->{session}->get_billing_summary();
    
    # Try to fetch user data from CopilotUserAPI for richer info
    my $user_data;
    eval {
        require CLIO::Core::CopilotUserAPI;
        my $user_api = CLIO::Core::CopilotUserAPI->new(debug => $self->{debug});
        $user_data = $user_api->get_cached_user();  # Don't make API call, just use cache
    };
    # Ignore errors - $user_data will be undef
    
    # Display header using proper style
    $self->display_command_header("GITHUB COPILOT BILLING");
    
    # Show account info - prefer prepopulated session data, fall back to API cache
    my $login = undef;
    my $plan = undef;
    
    # Check session-stored user data first (from prepopulation)
    if ($self->{session}{copilot_user}) {
        $login = $self->{session}{copilot_user}{login};
        $plan = $self->{session}{copilot_user}{copilot_plan};
    }
    
    # Fall back to CopilotUserAPI cache
    if (!$login && $user_data) {
        $login = $user_data->{login};
        $plan = $user_data->{copilot_plan};
    }
    
    if ($login || $plan) {
        $self->display_section_header("Account");
        $self->writeline(sprintf("  %-25s %s", "Username:", $self->colorize($login || 'unknown', 'DATA')), markdown => 0);
        $self->writeline(sprintf("  %-25s %s", "Plan:", $self->colorize($plan || 'unknown', 'DATA')), markdown => 0);
    }
    
    # Get model and multiplier from session - check multiple paths
    my $model = $self->{session}{state}{billing}{model} 
             || $self->{session}{billing}{model}
             || 'unknown';
    my $multiplier = $self->{session}{state}{billing}{multiplier} 
                  || $self->{session}{billing}{multiplier}
                  || 0;
    
    # Format multiplier string
    my $multiplier_str = $self->_format_multiplier($multiplier);
    
    # Session summary
    $self->display_section_header("Session Summary");
    $self->writeline(sprintf("  %-25s %s", "Model:", $self->colorize($model, 'DATA')), markdown => 0);
    $self->writeline(sprintf("  %-25s %s", "Billing Rate:", $self->colorize($multiplier_str, 'DATA')), markdown => 0);
    
    # Show actual API requests vs premium requests charged
    my $total_api_requests = $billing->{total_requests} || 0;
    my $total_premium_charged = $billing->{total_premium_requests} || 0;
    
    $self->writeline(sprintf("  %-25s %s", "API Requests (Total):", $self->colorize($total_api_requests, 'DATA')), markdown => 0);
    $self->writeline(sprintf("  %-25s %s", "Premium Requests Charged:", $self->colorize($total_premium_charged, 'DATA')), markdown => 0);
    
    # Show quota allotment - check multiple paths (state may be nested differently)
    my $quota = $self->{session}{quota} 
             || $self->{session}{state}{quota};
    
    if ($quota) {
        my $entitlement = $quota->{entitlement} || 0;
        my $used = $quota->{used} || 0;
        my $percent_used = $entitlement > 0 ? (100.0 - ($quota->{percent_remaining} || 0)) : 0;
        my $reset_date = $quota->{reset_date} || '';
        
        if ($entitlement > 0) {
            $self->display_section_header("Premium Quota");
            
            # Color based on usage percentage
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
            
            # Show overage if applicable
            my $overage = $quota->{overage_used} || 0;
            if ($overage > 0) {
                my $overage_str = sprintf("+%d overage", $overage);
                if ($quota->{overage_permitted}) {
                    $overage_str .= " (permitted)";
                }
                $self->writeline(sprintf("  %-25s %s", "Overage:", 
                    $self->colorize($overage_str, 'WARN')), markdown => 0);
            }
            
            # Show reset date
            if ($reset_date && $reset_date ne 'unknown') {
                my $reset_display = $reset_date;
                $reset_display =~ s/T.*//;  # Remove time portion
                $self->writeline(sprintf("  %-25s %s", 
                    "Resets:", 
                    $self->colorize($reset_display, 'DIM')), markdown => 0);
            }
        }
    }
    
    # Token usage section
    $self->display_section_header("Token Usage");
    $self->writeline(sprintf("  %-25s %s", "Total Tokens:", $self->colorize($billing->{total_tokens}, 'DATA')), markdown => 0);
    $self->writeline(sprintf("  %-25s %s tokens", "  Prompt:", $billing->{total_prompt_tokens}), markdown => 0);
    $self->writeline(sprintf("  %-25s %s tokens", "  Completion:", $billing->{total_completion_tokens}), markdown => 0);
    
    # Premium usage warning if applicable
    $self->_display_premium_warning($multiplier);
    
    # Recent requests with multipliers
    $self->_display_recent_requests($billing);
    
    $self->writeline("", markdown => 0);
    $self->writeline($self->colorize("Note: GitHub Copilot uses subscription-based billing.", 'DIM'), markdown => 0);
    $self->writeline($self->colorize("      Multipliers indicate premium model usage relative to free models.", 'DIM'), markdown => 0);
    $self->writeline("", markdown => 0);
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

Display warning for premium model usage.

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
    
    $self->writeline($self->colorize("[WARN] Premium Model Usage:", 'LABEL'), markdown => 0);
    $self->writeline(sprintf("  This model has a %s billing multiplier.", 
        $self->colorize($mult_display, 'DATA')), markdown => 0);
    $self->writeline("  Excessive use may impact your GitHub Copilot subscription.", markdown => 0);
    $self->writeline("", markdown => 0);
}

=head2 _display_recent_requests($billing)

Display recent requests table.

=cut

sub _display_recent_requests {
    my ($self, $billing) = @_;
    
    return unless $billing->{requests} && @{$billing->{requests}};
    
    my @recent = @{$billing->{requests}};
    @recent = @recent[-10..-1] if @recent > 10;
    
    return unless @recent;
    
    $self->writeline($self->colorize("Recent Requests:", 'LABEL'), markdown => 0);
    $self->writeline($self->colorize(sprintf("  %-5s %-25s %-12s %-12s", 
        "#", "Model", "Tokens", "Rate"), 'LABEL'), markdown => 0);
    
    my $count = 1;
    for my $req (@recent) {
        my $req_model = $req->{model} || 'unknown';
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
        
        $req_model = substr($req_model, 0, 23) . "..." if length($req_model) > 25;
        
        printf "  %-5s %-25s %-12s %-12s\n",
            $count,
            $req_model,
            $req->{total_tokens},
            $rate_str;
        $count++;
    }
    $self->writeline("", markdown => 0);
}

1;

__END__

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

Same as CLIO.

=cut
