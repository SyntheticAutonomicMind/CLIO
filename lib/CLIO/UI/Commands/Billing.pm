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
        session => $args{session},
        debug => $args{debug} // 0,
    };
    
    bless $self, $class;
    return $self;
}

# Delegate display methods to chat
sub display_system_message { shift->{chat}->display_system_message(@_) }
sub display_error_message { shift->{chat}->display_error_message(@_) }
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
    
    print "\n";
    print $self->colorize("=" x 70, 'DATA'), "\n";
    print $self->colorize("GITHUB COPILOT BILLING", 'DATA'), "\n";
    print $self->colorize("=" x 70, 'DATA'), "\n";
    print "\n";
    
    # Get model and multiplier from session
    my $model = $self->{session}{state}{billing}{model} || 'unknown';
    my $multiplier = $self->{session}{state}{billing}{multiplier} || 0;
    
    # Format multiplier string
    my $multiplier_str = $self->_format_multiplier($multiplier);
    
    # Session summary
    print $self->colorize("Session Summary:", 'LABEL'), "\n";
    printf "  %-25s %s\n", "Model:", $self->colorize($model, 'DATA');
    printf "  %-25s %s\n", "Billing Rate:", $self->colorize($multiplier_str, 'DATA');
    
    # Show actual API requests vs premium requests charged
    my $total_api_requests = $billing->{total_requests} || 0;
    my $total_premium_charged = $billing->{total_premium_requests} || 0;
    
    printf "  %-25s %s\n", "API Requests (Total):", $self->colorize($total_api_requests, 'DATA');
    printf "  %-25s %s\n", "Premium Requests Charged:", $self->colorize($total_premium_charged, 'DATA');
    
    # Show quota allotment if available
    if ($self->{session}{quota}) {
        my $quota = $self->{session}{quota};
        my $entitlement = $quota->{entitlement} || 0;
        my $used = $quota->{used} || 0;
        
        if ($entitlement > 0) {
            printf "  %-25s %s of %s\n", 
                "Premium Quota Status:", 
                $self->colorize("$used used", 'DATA'),
                $self->colorize("$entitlement total", 'DATA');
        }
    }
    
    printf "  %-25s %s\n", "Total Tokens:", $self->colorize($billing->{total_tokens}, 'DATA');
    printf "  %-25s %s tokens\n", "  - Prompt:", $billing->{total_prompt_tokens};
    printf "  %-25s %s tokens\n", "  - Completion:", $billing->{total_completion_tokens};
    print "\n";
    
    # Premium usage warning if applicable
    $self->_display_premium_warning($multiplier);
    
    # Recent requests with multipliers
    $self->_display_recent_requests($billing);
    
    print $self->colorize("=" x 70, 'DATA'), "\n";
    print "\n";
    print $self->colorize("Note: GitHub Copilot uses subscription-based billing.", 'SYSTEM'), "\n";
    print $self->colorize("      Multipliers indicate premium model usage relative to free models.", 'SYSTEM'), "\n";
    print "\n";
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
    
    print $self->colorize("[WARN] Premium Model Usage:", 'LABEL'), "\n";
    printf "  This model has a %s billing multiplier.\n", 
        $self->colorize($mult_display, 'DATA');
    print "  Excessive use may impact your GitHub Copilot subscription.\n";
    print "\n";
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
    
    print $self->colorize("Recent Requests:", 'LABEL'), "\n";
    print $self->colorize(sprintf("  %-5s %-25s %-12s %-12s", 
        "#", "Model", "Tokens", "Rate"), 'LABEL'), "\n";
    
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
    print "\n";
}

1;

__END__

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

Same as CLIO.

=cut
