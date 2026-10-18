#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::UI::Chat::Help;

use strict;
use warnings;
use utf8;

use CLIO::UI::Terminal qw(box_char);

=head1 NAME

CLIO::UI::Chat::Help - Help command display extracted from Chat.pm

=head1 SYNOPSIS

    my $help = CLIO::UI::Chat::Help->new($chat);
    $help->display_help();      # full listing
    $help->display_help('git'); # detailed help for one command

=head1 DESCRIPTION

Renders the slash-command help listing and per-command help.  Extracted from
CLIO::UI::Chat.

The command listing is generated directly from the live command registry
(C<< $chat->get_command_handler->command_defs >>), so the help output can
never drift out of sync with the commands that actually exist: every registered
command is always listed, and every command's summary text lives next to its
handler in one place.

=head1 METHODS

=cut

sub new {
    my ($class, $chat) = @_;
    return bless { chat => $chat }, $class;
}

# Each write goes through this helper so that a pagination cancel (writeline
# returns 0, i.e. the user pressed Q) aborts the whole render early instead of
# continuing to stream lines past the cancel.
sub _line {
    my ($self, $chat, $text, %opts) = @_;
    $opts{markdown} //= 0;
    return $chat->writeline($text // '', %opts);
}

# Category display order for the listing.  Commands whose category is not in
# this map are collected under their own (rare) heading at the end.
sub _category_order {
    return (
        'BASICS',
        'API & CONFIG',
        'SESSION',
        'FILE & GIT',
        'PLUGINS',
        'MCP',
        'TODO',
        'SPECS',
        'MEMORY',
        'PROFILE',
        'UPDATES',
        'DEVELOPER',
        'SKILLS & PROMPTS',
        'DEVICES & REMOTE',
        'MULTI-AGENT',
        'OTHER',
    );
}

=head2 display_help($target)

Render the full slash-command listing, or detailed help for a single command
when $target is supplied (e.g. C</help git>).

=cut

sub display_help {
    my ($self, $target) = @_;
    my $chat = $self->{chat};

    $chat->refresh_terminal_size();

    if (defined $target && length $target) {
        return $chat->get_command_handler->display_help_for($target);
    }

    return $self->_display_help_listing();
}

=head2 _display_help_listing

Render the full command listing from the live registry.  Aborts early if the
pager reports a cancel (writeline returns 0).

=cut

sub _display_help_listing {
    my ($self) = @_;
    my $chat = $self->{chat};
    my $ch   = $chat->get_command_handler;

    $chat->{pager}->reset();
    $chat->{pager}->enable();

    my $width = 62;
    my $dh    = box_char('dhorizontal');
    my $sh    = box_char('horizontal');

    # Header
    return 0 unless $self->_line($chat, '');
    return 0 unless $self->_line($chat, $chat->colorize($dh x $width, 'command_header'));
    return 0 unless $self->_line($chat, $chat->colorize($chat->agent_name() . " COMMANDS", 'command_header'));
    return 0 unless $self->_line($chat, $chat->colorize($dh x $width, 'command_header'));
    return 0 unless $self->_line($chat, '');

    # Collect every registered command so the listing can never drift from
    # what actually exists.
    my @rows;
    for my $def (@{$ch->command_defs}) {
        my @names = $def->{names} ? @{$def->{names}} : ($def->{name});
        my $cmd   = join(', ', map { "/$_" } @names);
        push @rows, [
            $def->{category} // 'OTHER',
            $cmd,
            $def->{summary} // '',
        ];
    }

    my @order = $self->_category_order();
    my %done;
    for my $cat (@order) {
        my @items = grep { $_->[0] eq $cat } @rows;
        next unless @items;
        $done{$cat} = 1;
        return 0 unless $self->_line($chat, $chat->colorize($cat, 'command_subheader'));
        return 0 unless $self->_line($chat, $chat->colorize($sh x $width, 'dim'));
        for my $r (@items) {
            return 0 unless $chat->display_command_row($r->[1], $r->[2], 30);
        }
        return 0 unless $self->_line($chat, '');
    }

    # Defensive: surface any command whose category was not in the ordered map.
    for my $r (@rows) {
        next if $done{$r->[0]};
        $done{$r->[0]} = 1;
        return 0 unless $self->_line($chat, $chat->colorize($r->[0], 'command_subheader'));
        return 0 unless $self->_line($chat, $chat->colorize($sh x $width, 'dim'));
        return 0 unless $chat->display_command_row($r->[1], $r->[2], 30);
        return 0 unless $self->_line($chat, '');
    }

    # Keyboard shortcuts (terminal UI knowledge lives here, not in the registry).
    return 0 unless $self->_line($chat, $chat->colorize('KEYBOARD SHORTCUTS', 'command_subheader'));
    return 0 unless $self->_line($chat, $chat->colorize($sh x $width, 'dim'));
    for my $item (@{$self->_keyboard_shortcuts()}) {
        return 0 unless $chat->display_command_row($item->[0], $item->[1], 30);
    }
    return 0 unless $self->_line($chat, '');

    $chat->{pager}->reset();
    return 1;
}

=head2 _keyboard_shortcuts

Static list of terminal editing shortcuts shown at the bottom of /help.

=cut

sub _keyboard_shortcuts {
    return [
        ['Left/Right',                'Move cursor by character'],
        ['Shift+Left/Right',          'Move cursor by word'],
        ['Option+Left/Right',         'Move cursor by word (macOS)'],
        ['Ctrl+A / Home',             'Move to start of line'],
        ['Ctrl+E / End',              'Move to end of line'],
        ['Backspace',                 'Delete character before cursor'],
        ['Delete / Fn+Delete',        'Delete character at cursor'],
        ['Ctrl+W',                    'Delete word before cursor'],
        ['Shift+Delete',              'Delete word before cursor'],
        ['Option+Backspace',          'Delete word before cursor (macOS)'],
        ['Alt+D',                     'Delete word after cursor'],
        ['Ctrl+Delete',               'Delete word after cursor'],
        ['Option+D',                  'Delete word after cursor (macOS)'],
        ['Ctrl+K',                    'Delete to end of line'],
        ['Ctrl+U',                    'Delete to start of line'],
        ['Up/Down',                   'Navigate command history'],
        ['Tab',                       'Auto-complete commands/paths'],
        ['ESC',                       'Interrupt the agent (during streaming)'],
        ['Ctrl+C',                    'Exit CLIO (classic Unix behaviour)'],
        ['Ctrl+D',                    'Exit CLIO (alias for Ctrl+C)'],
    ];
}

1;
