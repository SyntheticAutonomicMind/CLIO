#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::UI::Chat::Security;

use strict;
use warnings;
use utf8;

use CLIO::Core::Logger qw(log_debug log_warning);
use CLIO::Compat::Terminal qw(ReadKey ReadMode);

=head1 NAME

CLIO::UI::Chat::Security - Agent authorization and message handling extracted from Chat.pm

=head1 SYNOPSIS

    my $sec = CLIO::UI::Chat::Security->new($chat);
    $sec->check_agent_messages($broker_client);
    $sec->_handle_agent_authorization($msg, $broker_client);
    $sec->display_agent_message($msg);

=head1 DESCRIPTION

Handles sub-agent messages, authorization requests from child agents,
and security prompt display. Extracted from CLIO::UI::Chat.

=cut

sub new {
    my ($class, $chat) = @_;
    return bless { chat => $chat }, $class;
}

=head2 check_agent_messages($broker_client)

Poll the broker for messages from sub-agents and handle them.
Returns 1 if any messages were processed.

=cut

sub check_agent_messages {
    my ($self, $broker_client) = @_;
    my $chat = $self->{chat};

    return 0 unless $broker_client;

    my $messages = eval { $broker_client->poll_user_inbox() };

    if ($@) {
        log_debug('Chat', "Failed to poll agent inbox: $@");
        return 0;
    }

    return 1 unless $messages && @$messages;

    my @handled_ids;

    for my $msg (@$messages) {
        if ($msg->{type} eq 'authorization_request') {
            $self->_handle_agent_authorization($msg, $broker_client);
            push @handled_ids, $msg->{id} if $msg->{id};
        } else {
            $self->display_agent_message($msg);
            push @handled_ids, $msg->{id} if $msg->{id};
        }
    }

    if (@handled_ids) {
        eval { $broker_client->acknowledge_messages(@handled_ids) };
    }

    return 1;
}

=head2 _handle_agent_authorization($msg, $broker_client)

Handle an authorization request from a child agent. Displays the security prompt
to the user and sends the response back through the broker.

=cut

sub _handle_agent_authorization {
    my ($self, $msg, $broker_client) = @_;
    my $chat = $self->{chat};

    my $from        = $msg->{from} || 'unknown';
    my $request_id  = $msg->{request_id};
    my $category    = $msg->{category} || 'unknown';
    my $description = $msg->{description} || 'unknown';
    my $risk_level  = $msg->{risk_level} || 'standard';
    my $flags       = $msg->{flags} || [];

    my $is_critical = ($risk_level eq 'critical');

    print "\a";

    my $theme_mgr = $chat->{theme_mgr};

    my $cat_label = {
        command_execution => 'Command',
        script_creation   => 'Script',
        web_fetch         => 'Web Request',
    }->{$category} || ucfirst($category);

    my $options = '(y)es once | (a)llow session | (n)o deny';

    if ($theme_mgr && $theme_mgr->can('get_security_prompt')) {
        my ($prompt_line, $input_line) = $theme_mgr->get_security_prompt(
            $description,
            $flags,
            $options,
        );
        print "\n";
        if ($is_critical) {
            print "\e[1;31m[WARN] CRITICAL RISK\e[0m ";
        }
        print $chat->colorize("[Agent: $from] ", 'CYAN');
        print "$cat_label Authorization\n";
        print "$prompt_line\n$input_line";
    } else {
        my @flag_parts;
        for my $flag (@{$flags || []}) {
            push @flag_parts, "[$flag->{severity}] $flag->{description}";
        }
        my $flags_str = join(" | ", @flag_parts);
        print "\n";
        if ($is_critical) {
            print "* CRITICAL RISK ";
        } else {
            print "* Security ";
        }
        print "[Agent: $from] $cat_label | $description\n  $flags_str\n  $options: ";
    }

    require CLIO::Compat::Terminal;

    my $saved_alrm = $SIG{ALRM};
    my $remaining_alarm = alarm(0);

    while (defined(eval { CLIO::Compat::Terminal::ReadKey(-1) })) { }
    CLIO::Compat::Terminal::ReadMode(0);

    my $response = <STDIN>;
    chomp($response) if defined $response;
    $response = lc($response || 'n');

    CLIO::Compat::Terminal::ReadMode(1);

    $SIG{ALRM} = $saved_alrm || 'DEFAULT';
    alarm($remaining_alarm) if $remaining_alarm;

    my ($approved, $grant_type);
    if ($response eq 'y' || $response eq 'yes') {
        $approved = 1;
        $grant_type = 'once';
    } elsif ($response eq 'a' || $response eq 'allow') {
        $approved = 1;
        $grant_type = 'session';
    } else {
        $approved = 0;
        $grant_type = 'denied';
    }

    log_debug('Chat', "Agent auth response for $request_id: approved=$approved grant=$grant_type");

    eval {
        $broker_client->send_authorization_response(
            request_id => $request_id,
            approved   => $approved,
            grant_type => $grant_type,
        );
    };
    if ($@) {
        log_debug('Chat', "Failed to send authorization response: $@");
    }
}

=head2 display_agent_message($msg)

Display a single message from a sub-agent with proper formatting.

=cut

sub display_agent_message {
    my ($self, $msg) = @_;
    my $chat = $self->{chat};

    my $from = $msg->{from} || 'unknown';
    my $type = $msg->{type} || 'generic';
    my $content = $msg->{content} || '';

    my $color;
    if ($type eq 'question') {
        $color = 'YELLOW';
    } elsif ($type eq 'blocked') {
        $color = 'RED';
    } elsif ($type eq 'complete') {
        $color = 'GREEN';
    } else {
        $color = 'CYAN';
    }

    my $agent_label = uc($from);
    print $chat->colorize("$agent_label: ", $color);

    my $max_content_length = 2000;
    if (ref($content) eq 'HASH') {
        print "\n";
        for my $key (sort keys %$content) {
            next unless defined $content->{$key};
            my $val = $content->{$key};
            if (length($val) > $max_content_length) {
                $val = substr($val, 0, $max_content_length) . "... [truncated]";
            }
            print "  $key: $val\n";
        }
    } else {
        if (length($content) > $max_content_length) {
            $content = substr($content, 0, $max_content_length) . "... [truncated]";
        }
        print "$content\n";
    }

    if ($type eq 'question' || $type eq 'blocked') {
        print "\a";
        print $chat->colorize("  Reply with: \@$from <your-response>", 'DIM'), "\n";
    }
    print "\n";
}

1;