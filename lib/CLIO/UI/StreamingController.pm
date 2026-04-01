# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::UI::StreamingController;

use strict;
use warnings;
use utf8;

use Carp qw(croak);
use CLIO::Core::Logger qw(log_debug);
use CLIO::Compat::Terminal qw(GetTerminalSize);

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
            my $agent = $ui->agent_name();
            print $ui->colorize("$agent: ", 'ASSISTANT');
            STDOUT->flush() if STDOUT->can('flush');

            if ($ui->{_prepare_for_next_iteration}) {
                $ui->{_prepare_for_next_iteration} = 0;
                $self->{first_line_printed} = 0;  # Reset for new agent prefix
                log_debug('Chat', "Printed agent prefix for continuation after tools");
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
        my $skip_first = !$self->{first_line_printed};
        $self->{first_line_printed} = 1;
        $output = $self->_indent_and_wrap($output, $skip_first);
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
        my $skip_first = !$self->{first_line_printed};
        $self->{first_line_printed} = 1;
        $output = $self->_indent_and_wrap($output, $skip_first);
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
        my $skip_first = !$self->{first_line_printed};
        $self->{first_line_printed} = 1;
        $output = $self->_indent_and_wrap($output, $skip_first);
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
        my $skip_first = !$self->{first_line_printed};
        $self->{first_line_printed} = 1;
        $output = $self->_indent_and_wrap($output, $skip_first);
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
    
    # Indent (and word-wrap) agent output under CLIO: prefix
    my $skip_first = !$self->{first_line_printed};
    $self->{first_line_printed} = 1;
    $output = $self->_indent_and_wrap($output, $skip_first);
    
    print $output;
    STDOUT->flush() if STDOUT->can('flush');

    my @rendered_lines = split /\n/, $self->{markdown_buffer};
    for my $rl (@rendered_lines) {
        $ui->{pager}->track_line($rl);
    }

    my $line_count_delta = $ui->_count_visual_lines($self->{markdown_buffer});
    my $tracked = scalar(@rendered_lines);
    if ($line_count_delta != $tracked) {
        $ui->{pager}->increment_lines($line_count_delta - $tracked);
    }

    $self->{markdown_buffer}  = '';
    $self->{md_line_count}    = 0;
    $self->{last_flush_time}  = time();
}

=head2 _indent_and_wrap($text, $skip_first)

Add 4-space indent to agent output lines, word-wrapping lines that would
exceed the terminal width. ANSI escape sequences are preserved across
wrap boundaries.

Arguments:
- text: rendered output (may contain ANSI codes)
- skip_first: if true, skip indenting the first line (follows CLIO: prefix)

Returns: indented and wrapped text

=cut

sub _indent_and_wrap {
    my ($self, $text, $skip_first) = @_;
    
    my $indent = '    ';
    my ($term_cols) = GetTerminalSize();
    $term_cols ||= 80;
    my $max_width = $term_cols - 1;
    my $avail = $max_width - length($indent);
    $avail = 20 if $avail < 20;
    
    my @lines = split /\n/, $text, -1;
    my @out;
    
    for my $i (0 .. $#lines) {
        my $line = $lines[$i];
        my $no_indent = ($skip_first && $i == 0);
        
        # Empty lines pass through
        if (length($line) == 0) {
            push @out, $line;
            next;
        }
        
        # Compute visible text (without ANSI escapes)
        my $visible = $line;
        $visible =~ s/\e\[[0-9;]*[A-Za-z]//g;
        $visible =~ s/\e\[\?\d+[lh]//g;
        $visible =~ s/\e\]8;;[^\e]*\e\\//g;
        
        # Skip word-wrapping for code block lines (2-space prefix from markdown renderer)
        # and table rows (start with |)
        my $is_preformatted = ($visible =~ /^  \S/ || $visible =~ /^\|/
                               || $visible =~ /^Code Block/);
        
        my $prefix_len = length(($ENV{CLIO_AGENT_NAME} || 'CLIO') . ": ");
        my $effective_avail = $no_indent ? ($max_width - $prefix_len) : $avail;
        
        if ($is_preformatted || length($visible) <= $effective_avail) {
            # Line fits or is preformatted - just indent
            push @out, ($no_indent ? $line : "$indent$line");
        } else {
            # Word-wrap needed
            push @out, $self->_wrap_ansi_line($line, $indent, $effective_avail, $avail, $no_indent);
        }
    }
    
    return join("\n", @out);
}

=head2 _wrap_ansi_line($line, $indent, $avail, $no_indent_first)

Word-wrap a single line that may contain ANSI codes, breaking at spaces.

=cut

sub _wrap_ansi_line {
    my ($self, $line, $indent, $first_avail, $cont_avail, $no_indent_first) = @_;
    
    # Split into segments: alternating ANSI sequences and visible text
    my @segments = split /(\e\[[0-9;]*[A-Za-z]|\e\[\?\d+[lh]|\e\]8;;[^\e]*\e\\)/, $line;
    
    # Build word list: each word carries its ANSI prefix
    my @words;
    my $ansi_prefix = '';
    
    for my $seg (@segments) {
        if ($seg =~ /^\e/) {
            $ansi_prefix .= $seg;
        } else {
            my @parts = split /( +)/, $seg;
            for my $part (@parts) {
                next if length($part) == 0;
                push @words, { text => $part, raw => $ansi_prefix . $part };
                $ansi_prefix = '';
            }
        }
    }
    if (length($ansi_prefix) && @words) {
        $words[-1]{raw} .= $ansi_prefix;
    }
    
    my @result_lines;
    my $current_raw = '';
    my $current_vis_len = 0;
    my $is_first = 1;
    
    for my $w (@words) {
        my $vis_len = length($w->{text});
        my $avail = $is_first ? $first_avail : $cont_avail;
        
        if ($current_vis_len == 0) {
            if ($w->{text} =~ /^ +$/) {
                next unless $is_first;
            }
            $current_raw = $w->{raw};
            $current_vis_len = $vis_len;
        } elsif ($current_vis_len + $vis_len > $avail) {
            $current_raw =~ s/ +$//;
            if ($is_first && $no_indent_first) {
                push @result_lines, $current_raw;
            } else {
                push @result_lines, "$indent$current_raw";
            }
            $is_first = 0;
            if ($w->{text} =~ /^ +$/) {
                $current_raw = '';
                $current_vis_len = 0;
            } else {
                $current_raw = $w->{raw};
                $current_vis_len = $vis_len;
            }
        } else {
            $current_raw .= $w->{raw};
            $current_vis_len += $vis_len;
        }
    }
    
    if (length($current_raw)) {
        $current_raw =~ s/ +$//;
        if ($is_first && $no_indent_first) {
            push @result_lines, $current_raw;
        } else {
            push @result_lines, "$indent$current_raw";
        }
    }
    
    return @result_lines;
}

1;

__END__

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

Same as CLIO.

=cut
