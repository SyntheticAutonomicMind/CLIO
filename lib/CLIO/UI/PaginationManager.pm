package CLIO::UI::PaginationManager;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Carp qw(croak);
use CLIO::Core::Logger qw(log_debug);
use CLIO::UI::Terminal qw(box_char);
use CLIO::Compat::Terminal qw(ReadKey ReadMode);

=head1 NAME

CLIO::UI::PaginationManager - Terminal pagination state and display

=head1 SYNOPSIS

    my $pager = CLIO::UI::PaginationManager->new(ui => $chat);
    $pager->reset();

    # Inline pagination (streaming/writeline)
    if ($pager->should_trigger()) {
        my $response = $pager->pause();
        # 'Q' = quit, 'C' = continue
    }

    # Fullscreen pagination
    $pager->display_list($title, \@items, $formatter);
    $pager->display_content($title, \@lines, $filepath);

=head1 DESCRIPTION

Owns all pagination state and display logic extracted from Chat.pm.
Handles inline line-count pagination during streaming/writeline output,
and fullscreen alternate-screen pagination for lists and file content.

Delegates colorize() and theme access back to the Chat instance via
the C<ui> reference.

=cut

sub new {
    my ($class, %args) = @_;
    croak "ui (Chat instance) required" unless $args{ui};

    my $self = bless {
        ui => $args{ui},
    }, $class;

    $self->reset();
    return $self;
}

=head2 reset

Reset pagination state for a new response cycle.

=cut

sub reset {
    my ($self) = @_;

    $self->{line_count}         = 0;
    $self->{pages}              = [];
    $self->{current_page}       = [];
    $self->{page_index}         = 0;
    $self->{pagination_enabled} = 0;
    $self->{_pagination_hint_shown} ||= 0;  # persist across resets

    return $self;
}

=head2 enable / disable

Toggle pagination on or off.

=cut

sub enable {
    my ($self) = @_;
    $self->{pagination_enabled} = 1;
    $self->{line_count} = 0;
    return $self;
}

sub disable {
    my ($self) = @_;
    $self->{pagination_enabled} = 0;
    return $self;
}

=head2 enabled

Return current pagination enabled state.

=cut

sub enabled { $_[0]->{pagination_enabled} }

=head2 line_count

Get/set current line count.

=cut

sub line_count {
    my ($self, $val) = @_;
    $self->{line_count} = $val if defined $val;
    return $self->{line_count};
}

=head2 increment_lines($n)

Add $n to the line counter (default 1).

=cut

sub increment_lines {
    my ($self, $n) = @_;
    $n //= 1;
    $self->{line_count} += $n;
}

=head2 track_line($line)

Record a line for page navigation and increment counter.

=cut

sub track_line {
    my ($self, $line) = @_;
    push @{$self->{current_page}}, $line;
    $self->{line_count}++;
}

=head2 threshold

Get the pagination threshold (lines per page).

=cut

sub threshold {
    my ($self) = @_;
    my $ui = $self->{ui};
    return ($ui->{terminal_height} // 24) - 2;
}

=head2 should_trigger(%opts)

Check if pagination should fire.

Options:

=over 4

=item streaming - if true, skip the tools_invoked check (agent text paginates always)

=item force - if true, bypass pagination_enabled check

=back

=cut

sub should_trigger {
    my ($self, %opts) = @_;

    return 0 unless -t STDIN;
    return 0 unless $self->{pagination_enabled} || $opts{force};

    # During tool execution, only streaming text gets paginated
    unless ($opts{streaming}) {
        return 0 if $self->{ui}{_tools_invoked_this_request};
    }

    return 1 if $self->{line_count} >= $self->threshold();
    return 0;
}

=head2 save_page

Save the current page buffer before pausing.

=cut

sub save_page {
    my ($self) = @_;
    push @{$self->{pages}}, [@{$self->{current_page}}];
    $self->{page_index} = scalar(@{$self->{pages}}) - 1;
}

=head2 reset_page

Clear line count and current page after pagination continues.

=cut

sub reset_page {
    my ($self) = @_;
    $self->{line_count} = 0;
    $self->{current_page} = [];
}

=head2 pause($streaming)

Pause for user input during inline pagination.

In streaming mode: simple prompt, any key continues.
In non-streaming mode: arrow key navigation between pages.

Returns: 'Q' to quit output, any other key to continue.

=cut

sub pause {
    my ($self, $streaming) = @_;
    $streaming ||= 0;
    my $ui = $self->{ui};

    # Refresh terminal size before pagination
    $ui->refresh_terminal_size();

    my $show_hint    = !$self->{_pagination_hint_shown};
    my $hint_shown   = 0;
    my $total_pages  = scalar(@{$self->{pages}}) || 1;
    my $current      = ($self->{page_index} || 0) + 1;

    if ($streaming) {
        if ($show_hint) {
            print $ui->{theme_mgr}->get_pagination_hint(1) . "\n";
            $self->{_pagination_hint_shown} = 1;
            $hint_shown = 1;
        }

        my $prompt = $ui->{theme_mgr}->get_pagination_prompt($current, 1, 0);
        print $prompt;

        my $key = ReadKey(0);

        # Clear prompt (and hint if shown)
        if ($hint_shown) {
            print "\e[2K";
            print "\e[" . $ui->{terminal_width} . "D";
            print "\e[1A";
            print "\e[2K";
        } else {
            print "\e[2K\e[" . $ui->{terminal_width} . "D";
        }

        $key = uc($key) if $key;
        return $key || 'C';
    }

    # Non-streaming: full arrow navigation
    while (1) {
        if ($show_hint) {
            print $ui->{theme_mgr}->get_pagination_hint(0) . "\n";
            $self->{_pagination_hint_shown} = 1;
            $hint_shown = 1;
            $show_hint = 0;
        }

        my $prompt = $ui->{theme_mgr}->get_pagination_prompt(
            $current, $total_pages, ($total_pages > 1)
        );
        print $prompt;

        my $key = ReadKey(0);

        # Arrow key handling
        if ($key eq "\e") {
            my $seq = ReadKey(0) . ReadKey(0);

            print "\e[2K\e[" . $ui->{terminal_width} . "D";

            if ($seq eq '[A' && $self->{page_index} > 0) {
                $self->{page_index}--;
                $current = $self->{page_index} + 1;
                $ui->redraw_page();
                next;
            }
            elsif ($seq eq '[B' && $self->{page_index} < $total_pages - 1) {
                $self->{page_index}++;
                $current = $self->{page_index} + 1;
                $ui->redraw_page();
                next;
            }
        }

        # Clear prompt
        if ($hint_shown) {
            print "\e[2K";
            print "\e[" . $ui->{terminal_width} . "D";
            print "\e[1A";
            print "\e[2K";
        } else {
            print "\e[2K\e[" . $ui->{terminal_width} . "D";
        }

        $key = uc($key) if $key;
        return $key || 'C';
    }
}

=head2 display_list($title, \@items, $formatter)

Fullscreen paginated list display using alternate screen buffer.

Arguments:
- $title: Header text
- $items: Arrayref of items
- $formatter: Optional coderef($item, $index) returning formatted string

=cut

sub display_list {
    my ($self, $title, $items, $formatter) = @_;
    my $ui = $self->{ui};

    $ui->refresh_terminal_size();
    $formatter ||= sub { return $_[0] };

    my $overhead  = 9;
    my $page_size = ($ui->{terminal_height} || 24) - $overhead;
    $page_size = 10 if $page_size < 10;

    my $total       = scalar @$items;
    my $total_pages = int(($total + $page_size - 1) / $page_size);
    $total_pages = 1 if $total_pages < 1;
    my $current_page = 0;

    if ($total == 0) {
        $ui->display_system_message("No items to display");
        return;
    }

    my $is_interactive = -t STDIN;

    # Non-paginated path
    if (!$is_interactive || $total <= $page_size) {
        print "\n";
        print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", "\n";
        print $ui->colorize($title, 'DATA'), "\n";
        print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", "\n";
        print "\n";
        for my $i (0 .. $total - 1) {
            my $formatted = $formatter->($items->[$i], $i);
            print "  $formatted\n";
        }
        print "\n";
        print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", "\n";
        print $ui->colorize("Total: $total items", 'DIM'), "\n";
        print "\n";
        return;
    }

    # Fullscreen alternate screen buffer
    print "\e[?1049h";
    my $show_hint = !$self->{_pagination_hint_shown};

    while (1) {
        my $start = $current_page * $page_size;
        my $end   = $start + $page_size - 1;
        $end = $total - 1 if $end >= $total;

        print "\e[2J\e[H";
        print "\n";
        print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", "\n";
        print $ui->colorize($title, 'DATA'), "\n";
        print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", "\n";
        print "\n";

        for my $i ($start .. $end) {
            my $formatted = $formatter->($items->[$i], $i);
            print "  $formatted\n";
        }

        print "\n";
        print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", "\n";

        my $showing = sprintf("Showing %d-%d of %d", $start + 1, $end + 1, $total);
        print $ui->colorize($showing, 'DIM'), "\n";

        if ($show_hint) {
            print $ui->{theme_mgr}->get_pagination_hint(0) . "\n";
            $self->{_pagination_hint_shown} = 1;
            $show_hint = 0;
        }

        my $current = $current_page + 1;
        my $prompt = $ui->{theme_mgr}->get_pagination_prompt(
            $current, $total_pages, ($total_pages > 1)
        );
        print $prompt;

        ReadMode('cbreak');
        my $key = ReadKey(0);

        if ($key eq "\e") {
            my $seq = ReadKey(0) . ReadKey(0);
            ReadMode('normal');
            print "\e[2K\e[" . $ui->{terminal_width} . "D";
            if ($seq eq '[A' && $current_page > 0) {
                $current_page--;
                next;
            }
            elsif ($seq eq '[B' && $current_page < $total_pages - 1) {
                $current_page++;
                next;
            }
        } else {
            ReadMode('normal');
        }

        last if $key && $key =~ /^[qQ]$/;

        if ($current_page < $total_pages - 1) {
            $current_page++;
        } else {
            last;
        }
    }

    ReadMode('restore');
    print "\e[?1049l";
}

=head2 display_content($title, \@lines, $filepath)

Fullscreen paginated content display (file viewer).

Arguments:
- $title: Header text
- $lines: Arrayref of content lines
- $filepath: Optional filepath shown in footer

=cut

sub display_content {
    my ($self, $title, $lines, $filepath) = @_;
    my $ui = $self->{ui};

    $ui->refresh_terminal_size();

    my $overhead  = 9;
    my $page_size = ($ui->{terminal_height} || 24) - $overhead;
    $page_size = 10 if $page_size < 10;

    my $total_lines = scalar @$lines;
    my $total_pages = int(($total_lines + $page_size - 1) / $page_size);
    $total_pages = 1 if $total_pages < 1;
    my $current_page = 0;

    my $is_interactive = -t STDIN;

    # Non-paginated path
    if (!$is_interactive || $total_lines <= $page_size) {
        print "\n";
        print $ui->colorize(box_char("dhorizontal") x 80, 'DIM'), "\n";
        print $ui->colorize($title, 'DATA'), "\n";
        print $ui->colorize(box_char("dhorizontal") x 80, 'DIM'), "\n";
        print "\n";
        for my $line (@$lines) {
            print $line, "\n";
        }
        print "\n";
        print $ui->colorize(box_char("horizontal") x 80, 'DIM'), "\n";
        print $ui->colorize("$total_lines lines", 'DIM');
        print $ui->colorize(" | $filepath", 'DIM') if $filepath;
        print "\n\n";
        return;
    }

    # Fullscreen alternate screen buffer
    print "\e[?1049h";
    my $show_hint = !$self->{_pagination_hint_shown};

    while (1) {
        my $start = $current_page * $page_size;
        my $end   = $start + $page_size - 1;
        $end = $total_lines - 1 if $end >= $total_lines;

        print "\e[2J\e[H";
        print "\n";
        print $ui->colorize(box_char("dhorizontal") x 80, 'DIM'), "\n";
        print $ui->colorize($title, 'DATA'), "\n";
        print $ui->colorize(box_char("dhorizontal") x 80, 'DIM'), "\n";
        print "\n";

        for my $i ($start .. $end) {
            print $lines->[$i], "\n";
        }

        print "\n";
        print $ui->colorize(box_char("horizontal") x 80, 'DIM'), "\n";

        my $status = sprintf("Lines %d-%d of %d", $start + 1, $end + 1, $total_lines);
        $status .= " | $filepath" if $filepath;
        print $ui->colorize($status, 'DIM'), "\n";

        if ($show_hint) {
            print $ui->{theme_mgr}->get_pagination_hint(0) . "\n";
            $self->{_pagination_hint_shown} = 1;
            $show_hint = 0;
        }

        my $current = $current_page + 1;
        my $prompt = $ui->{theme_mgr}->get_pagination_prompt(
            $current, $total_pages, ($total_pages > 1)
        );
        print $prompt;

        ReadMode('cbreak');
        my $key = ReadKey(0);

        if ($key eq "\e") {
            my $seq = ReadKey(0) . ReadKey(0);
            ReadMode('normal');
            print "\e[2K\e[" . $ui->{terminal_width} . "D";
            if ($seq eq '[A' && $current_page > 0) {
                $current_page--;
                next;
            }
            elsif ($seq eq '[B' && $current_page < $total_pages - 1) {
                $current_page++;
                next;
            }
            if ($seq !~ /^\[/) {
                last;  # Bare escape - quit
            }
        } else {
            ReadMode('normal');
        }

        last if $key && $key =~ /^[qQ]$/;

        if ($current_page < $total_pages - 1) {
            $current_page++;
        } else {
            last;
        }
    }

    ReadMode('restore');
    print "\e[?1049l";
}

1;

__END__

=head1 SEE ALSO

L<CLIO::UI::Chat> - parent module that delegates pagination

=cut
