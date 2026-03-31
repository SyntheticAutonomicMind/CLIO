# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::UI::StreamingController;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Carp qw(croak);
use CLIO::Core::Logger qw(log_debug);

=head1 NAME

CLIO::UI::StreamingController - Streaming response buffering and display

=head1 SYNOPSIS

    my $sc = CLIO::UI::StreamingController->new(ui => $chat);
    $sc->reset();

    my $on_chunk = $sc->make_on_chunk_callback(
        spinner => $spinner,
        host_proto => $host_proto,
    );
    # ... pass $on_chunk to process_user_request

    $sc->flush();                 # after streaming ends
    my $content = $sc->content(); # accumulated raw content

=head1 DESCRIPTION

Owns the streaming line/markdown buffering logic extracted from Chat.pm.
Handles:

=over 4

=item * Line-level accumulation (raw chunks -> complete lines)

=item * Markdown batching (code block and table detection)

=item * Periodic flushing with time/size thresholds

=item * Session naming marker stripping

=item * Pagination triggering during streaming

=back

Delegates rendering (colorize, render_markdown, pause) back to the
Chat instance via the C<ui> reference.

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

Clear all streaming state for a new response.

=cut

sub reset {
    my ($self) = @_;

    # Buffers
    $self->{line_buffer}     = '';
    $self->{markdown_buffer} = '';

    # Markdown context tracking
    $self->{md_line_count}   = 0;
    $self->{in_code_block}   = 0;
    $self->{in_table}        = 0;
    $self->{last_flush_time} = time();

    # Chunk tracking
    $self->{first_chunk_received} = 0;
    $self->{accumulated_content}  = '';
    $self->{first_line_printed}   = 0;  # Track if first line has been printed (no indent)

    return $self;
}

=head2 make_on_chunk_callback(%opts)

Build the on_chunk closure for process_user_request.

Options:

=over 4

=item spinner - Spinner object (required)

=item host_proto - HostProtocol emitter (required)

=back

Returns: coderef suitable for on_chunk parameter.

=cut

sub make_on_chunk_callback {
    my ($self, %opts) = @_;
    my $spinner    = $opts{spinner}    || croak "spinner required";
    my $host_proto = $opts{host_proto} || croak "host_proto required";
    my $ui = $self->{ui};

    return sub {
        my ($chunk, $metrics) = @_;

        return if $ui->{stop_streaming};

        log_debug('Chat', "Received chunk: " . substr($chunk, 0, 50) . "...");

        # Reset system message flag on content output
        $ui->{_last_was_system_message} = 0;

        # Print prefix on first chunk or after tool execution continuation
        if (!$self->{first_chunk_received} || $ui->{_prepare_for_next_iteration}) {
            $spinner->stop();
            print $ui->colorize("CLIO: ", 'ASSISTANT');
            STDOUT->flush() if STDOUT->can('flush');

            if ($ui->{_prepare_for_next_iteration}) {
                $ui->{_prepare_for_next_iteration} = 0;
                $self->{first_line_printed} = 0;  # Reset for new CLIO: prefix
                log_debug('Chat', "Printed CLIO: prefix for continuation after tools");
            }

            if (!$self->{first_chunk_received}) {
                $ui->{pager}->enable();
                $self->{first_line_printed} = 0;  # Reset for first CLIO: prefix
                log_debug('Chat', "Pagination ENABLED for text response");
            }

            $self->{first_chunk_received} = 1;
            $host_proto->emit_status('streaming');
        }

        # Clear prefix flag if set
        if ($ui->{_need_agent_prefix}) {
            $ui->{_need_agent_prefix} = 0;
        }

        # Feed chunk into line buffer
        $self->{line_buffer} .= $chunk;

        # Process complete lines
        while ((my $pos = index($self->{line_buffer}, "\n")) >= 0) {
            my $line = substr($self->{line_buffer}, 0, $pos);
            $self->{line_buffer} = substr($self->{line_buffer}, $pos + 1);

            # Strip session naming markers
            if ($line =~ /<!--session:\{/) {
                my $had_content = ($line =~ /\S/ && $line !~ /^\s*<!--session:\{[^}]*\}-->\s*$/);
                $line =~ s/\s*<!--session:\{[^}]*\}-->\s*//sg;
                next if !$had_content && $line !~ /\S/;
            }

            # Track markdown context
            if ($line =~ /^```/) {
                $self->{in_code_block} = !$self->{in_code_block};
            }
            my $line_is_table_row = ($line =~ /^\|.*\|$/);
            my $line_is_blank     = ($line =~ /^\s*$/);
            if ($line_is_table_row) {
                $self->{in_table} = 1;
            } elsif (!$line_is_blank && $self->{in_table}) {
                $self->{in_table} = 0;
            }

            $self->{markdown_buffer} .= $line . "\n";
            $self->{md_line_count}++;

            # Flush decision
            my $now        = time();
            my $size_limit = 10;
            my $time_limit = 0.5;
            my $max_limit  = 50;
            my $in_special = $self->{in_code_block} || $self->{in_table};
            my $should_flush = (
                ($self->{md_line_count} >= $size_limit && !$in_special) ||
                ($now - $self->{last_flush_time} >= $time_limit && !$in_special) ||
                ($self->{md_line_count} >= $max_limit)
            );

            if ($should_flush) {
                $self->_flush_markdown_buffer();

                # Check pagination
                if ($ui->_should_pagination_trigger_for_agent_streaming()) {
                    my $response = $ui->pause(1);
                    if ($response eq 'Q') {
                        $ui->{stop_streaming} = 1;
                        return;
                    }
                    $ui->{pager}->reset_page();
                }
            }
        }

        $self->{accumulated_content} .= $chunk;
    };
}

=head2 flush

Flush any remaining buffered content after streaming ends.

=cut

sub flush {
    my ($self) = @_;
    my $ui = $self->{ui};
    my $printed = 0;

    # Flush markdown buffer
    if ($self->{markdown_buffer} =~ /\S/) {
        $self->{markdown_buffer} =~ s/\s*<!--session:\{[^}]*\}-->\s*//sg;
    }
    if ($self->{markdown_buffer} =~ /\S/) {
        log_debug('Chat', "Flushing markdown_buffer (" . length($self->{markdown_buffer}) . " bytes)");
        my $output = $self->{markdown_buffer};
        if ($ui->{enable_markdown}) {
            $output = $ui->render_markdown($self->{markdown_buffer});
        }
        # Indent agent output by 4 spaces under CLIO: prefix
        if (!$self->{first_line_printed}) {
            $self->{first_line_printed} = 1;
            my @lines = split /\n/, $output, -1;
            for my $i (1 .. $#lines) {
                next unless length($lines[$i]) > 0;
                $lines[$i] = "    " . $lines[$i];
            }
            $output = join "\n", @lines;
        } else {
            my @lines = split /\n/, $output, -1;
            for my $i (0 .. $#lines) {
                next unless length($lines[$i]) > 0;
                $lines[$i] = "    " . $lines[$i];
            }
            $output = join "\n", @lines;
        }
        print $output;
        STDOUT->flush() if STDOUT->can('flush');
        $printed = 1;
    }

    # Flush line buffer (incomplete final line)
    if ($self->{line_buffer} =~ /\S/) {
        $self->{line_buffer} =~ s/\s*<!--session:\{[^}]*\}-->\s*//sg;
    }
    if ($self->{line_buffer} =~ /\S/) {
        log_debug('Chat', "Flushing line_buffer (" . length($self->{line_buffer}) . " bytes)");
        my $output = $self->{line_buffer};
        if ($ui->{enable_markdown}) {
            $output = $ui->render_markdown($self->{line_buffer});
        }
        # Indent agent output (line_buffer is always a continuation)
        if (!$self->{first_line_printed}) {
            $self->{first_line_printed} = 1;
            # No indent for the line itself (follows CLIO: prefix)
        } else {
            my @lines = split /\n/, $output, -1;
            for my $i (0 .. $#lines) {
                next unless length($lines[$i]) > 0;
                $lines[$i] = "    " . $lines[$i];
            }
            $output = join "\n", @lines;
        }
        print $output, "\n";
        STDOUT->flush() if STDOUT->can('flush');
        $printed = 1;
    }

    $self->{markdown_buffer} = '';
    $self->{line_buffer}     = '';

    return $printed;
}

=head2 flush_for_tools

Flush buffers before tool execution begins.
Called by Chat::flush_output_buffer().

=cut

sub flush_for_tools {
    my ($self) = @_;
    my $ui = $self->{ui};
    my $printed = 0;

    if ($self->{markdown_buffer} =~ /\S/) {
        my $output = $self->{markdown_buffer};
        if ($ui->{enable_markdown}) {
            $output = $ui->render_markdown($self->{markdown_buffer});
        }
        # Indent agent output by 4 spaces under CLIO: prefix
        if (!$self->{first_line_printed}) {
            $self->{first_line_printed} = 1;
            my @lines = split /\n/, $output, -1;
            for my $i (1 .. $#lines) {
                next unless length($lines[$i]) > 0;
                $lines[$i] = "    " . $lines[$i];
            }
            $output = join "\n", @lines;
        } else {
            my @lines = split /\n/, $output, -1;
            for my $i (0 .. $#lines) {
                next unless length($lines[$i]) > 0;
                $lines[$i] = "    " . $lines[$i];
            }
            $output = join "\n", @lines;
        }
        print $output;
        $self->{markdown_buffer} = '';
        $printed = 1;
    }

    if ($self->{line_buffer} =~ /\S/) {
        $self->{line_buffer} =~ s/\s*<!--session:\{[^}]*\}-->\s*//sg;
    }
    if ($self->{line_buffer} =~ /\S/) {
        my $output = $self->{line_buffer};
        if ($ui->{enable_markdown}) {
            $output = $ui->render_markdown($self->{line_buffer});
        }
        # Indent agent output (continuation)
        if (!$self->{first_line_printed}) {
            $self->{first_line_printed} = 1;
        } else {
            my @lines = split /\n/, $output, -1;
            for my $i (0 .. $#lines) {
                next unless length($lines[$i]) > 0;
                $lines[$i] = "    " . $lines[$i];
            }
            $output = join "\n", @lines;
        }
        print $output;
        print "\n" unless $output =~ /\n$/;
        $self->{line_buffer} = '';
        $printed = 1;
    }

    STDOUT->flush() if STDOUT->can('flush');
    $| = 1;

    log_debug('Chat', "Buffer flushed for tool execution handshake (printed=$printed)");
    return $printed;
}

=head2 content

Return accumulated raw content from streaming.

=cut

sub content { $_[0]->{accumulated_content} }

=head2 first_chunk_received

Return whether any content chunk was received.

=cut

sub first_chunk_received { $_[0]->{first_chunk_received} }

# ---- Private ----

sub _flush_markdown_buffer {
    my ($self) = @_;
    my $ui = $self->{ui};

    log_debug('Chat', "Periodic flush of markdown_buffer (" .
              length($self->{markdown_buffer}) . " bytes, $self->{md_line_count} lines)");

    my $output = $self->{markdown_buffer};
    if ($ui->{enable_markdown}) {
        $output = $ui->render_markdown($self->{markdown_buffer});
    }
    
    # Indent agent output by 4 spaces for visual nesting under CLIO: prefix
    if (!$self->{first_line_printed}) {
        $self->{first_line_printed} = 1;
        # First flush: indent all lines EXCEPT the first (follows CLIO: prefix)
        my @lines = split /\n/, $output, -1;
        for my $i (1 .. $#lines) {
            next unless length($lines[$i]) > 0;
            $lines[$i] = "    " . $lines[$i];
        }
        $output = join "\n", @lines;
    } else {
        # Subsequent flushes: indent all lines
        my @lines = split /\n/, $output, -1;
        for my $i (0 .. $#lines) {
            next unless length($lines[$i]) > 0;
            $lines[$i] = "    " . $lines[$i];
        }
        $output = join "\n", @lines;
    }
    
    print $output;
    STDOUT->flush() if STDOUT->can('flush');

    my @rendered_lines = split /\n/, $self->{markdown_buffer};
    for my $rl (@rendered_lines) {
        $ui->{pager}->track_line($rl);
    }

    my $line_count_delta = $ui->_count_visual_lines($self->{markdown_buffer});
    # track_line already incremented, but _count_visual_lines may differ
    # Adjust: track_line added scalar(@rendered_lines), we need line_count_delta
    my $tracked = scalar(@rendered_lines);
    if ($line_count_delta != $tracked) {
        $ui->{pager}->increment_lines($line_count_delta - $tracked);
    }

    $self->{markdown_buffer}  = '';
    $self->{md_line_count}    = 0;
    $self->{last_flush_time}  = time();
}

1;

__END__

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

Same as CLIO.

=cut
