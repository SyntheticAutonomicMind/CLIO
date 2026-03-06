# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::UI::Commands::Base;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

=head1 NAME

CLIO::UI::Commands::Base - Base class for CLIO slash command modules

=head1 SYNOPSIS

  package CLIO::UI::Commands::MyCommand;
  use parent 'CLIO::UI::Commands::Base';

  sub new {
      my ($class, %args) = @_;
      my $self = $class->SUPER::new(%args);
      return $self;
  }

=head1 DESCRIPTION

Base class for all CLIO::UI::Commands::* modules. Provides delegation
methods that forward display and output calls to the parent Chat instance.

All Commands modules hold a reference to the Chat object in $self->{chat}.
Rather than copy-pasting delegation stubs in every module, they inherit
them here.

=cut

sub new {
    my ($class, %args) = @_;
    my $self = {
        chat  => $args{chat},
        debug => $args{debug} // 0,
    };
    bless $self, $class;
    return $self;
}

# Display delegation - forward all display/output calls to Chat

sub colorize                 { shift->{chat}->colorize(@_) }
sub writeline                { shift->{chat}->writeline(@_) }
sub display_system_message   { shift->{chat}->display_system_message(@_) }
sub display_error_message    { shift->{chat}->display_error_message(@_) }
sub display_success_message  { shift->{chat}->display_success_message(@_) }
sub display_warning_message  { shift->{chat}->display_warning_message(@_) }
sub display_info_message     { shift->{chat}->display_info_message(@_) }
sub display_command_header   { shift->{chat}->display_command_header(@_) }
sub display_section_header   { shift->{chat}->display_section_header(@_) }
sub display_key_value        { shift->{chat}->display_key_value(@_) }
sub display_command_row      { shift->{chat}->display_command_row(@_) }
sub display_list_item        { shift->{chat}->display_list_item(@_) }
sub display_tip              { shift->{chat}->display_tip(@_) }
sub display_paginated_list   { shift->{chat}->display_paginated_list(@_) }
sub display_paginated_content { shift->{chat}->display_paginated_content(@_) }
sub render_markdown          { shift->{chat}->render_markdown(@_) }
sub refresh_terminal_size    { shift->{chat}->refresh_terminal_size(@_) }

1;

__END__

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

Same as CLIO.

=cut
