package CLIO::Session::Export;

use strict;
use warnings;
use utf8;
use CLIO::Util::JSON qw(decode_json);
use File::Spec;
use POSIX qw(strftime);
use Carp qw(croak);

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

=head1 NAME

CLIO::Session::Export - Export CLIO sessions to HTML

=head1 DESCRIPTION

Converts CLIO session JSON data into a styled, self-contained HTML document.
The output is a single HTML file with embedded CSS - no external dependencies.

Handles all message types: system, user, assistant, tool, and tool_calls.

=head1 SYNOPSIS

    use CLIO::Session::Export;
    
    my $exporter = CLIO::Session::Export->new();
    my $html = $exporter->export_html($session_state);
    
    # Or export directly to file
    $exporter->export_to_file($session_state, 'session.html');

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        debug => $args{debug} // 0,
        include_system => $args{include_system} // 0,  # Skip system prompts by default
        include_tool_results => $args{include_tool_results} // 1,
    };
    
    bless $self, $class;
    return $self;
}

=head2 export_html($state)

Convert a session state object to HTML string.

Arguments:
- $state: CLIO::Session::State instance or hashref with {history, session_id, created_at}

Returns: HTML string

=cut

sub export_html {
    my ($self, $state) = @_;
    
    croak "State required" unless $state;
    
    # Extract data - handle both State objects and raw hashrefs
    my $history;
    my $session_id;
    my $created_at;
    my $model;
    
    if (ref($state) && ref($state) ne 'HASH' && $state->can('session_id')) {
        # State object
        $history = $state->{history} || [];
        $session_id = $state->session_id();
        $created_at = $state->{created_at} || '';
        $model = $state->{selected_model} || $state->{billing}{model} || 'unknown';
    } else {
        # Raw hashref (loaded from JSON)
        $history = $state->{history} || [];
        $session_id = $state->{session_id} || 'unknown';
        $created_at = $state->{created_at} || '';
        $model = $state->{selected_model} || '';
        if (!$model && $state->{billing}) {
            $model = $state->{billing}{model} || 'unknown';
        }
    }
    
    # Build message HTML
    my @message_html;
    
    for my $msg (@$history) {
        next unless ref($msg) eq 'HASH';
        
        my $role = $msg->{role} || '';
        
        # Handle nested role/content (some older sessions stored this way)
        if (ref($role) eq 'HASH') {
            $role = $role->{role} || '';
            # Content may be in the nested hash too
        }
        
        # Skip system messages unless requested
        next if $role eq 'system' && !$self->{include_system};
        
        # Skip tool results unless requested
        next if $role eq 'tool' && !$self->{include_tool_results};
        
        my $content = $msg->{content};
        if (!defined $content || $content eq '') {
            # Assistant messages with only tool_calls have empty content
            if ($role eq 'assistant' && $msg->{tool_calls}) {
                $content = $self->_format_tool_calls($msg->{tool_calls});
            } else {
                next;  # Skip empty messages
            }
        }
        
        # Handle nested content
        if (ref($role) eq 'HASH' && $role->{content}) {
            $content = $role->{content};
            $role = $role->{role} || 'unknown';
        }
        
        my $timestamp = $msg->{timestamp} || '';
        my $html = $self->_render_message($role, $content, $timestamp, $msg);
        push @message_html, $html if $html;
    }
    
    my $messages_html = join("\n", @message_html);
    my $title = "CLIO Session - " . _html_escape(substr($session_id, 0, 8));
    my $export_time = strftime("%Y-%m-%d %H:%M:%S UTC", gmtime());
    
    return $self->_wrap_html($title, $messages_html, {
        session_id => $session_id,
        created_at => $created_at,
        model => $model,
        export_time => $export_time,
        message_count => scalar(@message_html),
    });
}

=head2 export_to_file($state, $filename)

Export session to an HTML file.

Arguments:
- $state: Session state
- $filename: Output file path

Returns: 1 on success, dies on error

=cut

sub export_to_file {
    my ($self, $state, $filename) = @_;
    
    croak "Filename required" unless $filename;
    
    my $html = $self->export_html($state);
    
    # Atomic write
    my $temp = $filename . '.tmp';
    open my $fh, '>:encoding(UTF-8)', $temp or croak "Cannot write to $temp: $!";
    print $fh $html;
    close $fh;
    rename $temp, $filename or croak "Cannot rename $temp to $filename: $!";
    
    return 1;
}

# Render a single message to HTML
sub _render_message {
    my ($self, $role, $content, $timestamp, $msg) = @_;
    
    my $role_class = $role;
    my $role_label;
    my $content_html;
    
    if ($role eq 'user') {
        $role_label = 'YOU';
        $content_html = $self->_markdown_to_html($content);
    }
    elsif ($role eq 'assistant') {
        $role_label = 'CLIO';
        if ($msg->{tool_calls} && (!$content || $content eq '')) {
            $content_html = $self->_format_tool_calls($msg->{tool_calls});
        } else {
            $content_html = $self->_markdown_to_html($content);
        }
    }
    elsif ($role eq 'tool') {
        $role_label = 'TOOL';
        # Truncate very long tool results
        if (length($content) > 2000) {
            $content = substr($content, 0, 2000) . "\n... [truncated]";
        }
        $content_html = '<pre class="tool-result">' . _html_escape($content) . '</pre>';
    }
    elsif ($role eq 'system') {
        $role_label = 'SYSTEM';
        # Truncate system prompts
        if (length($content) > 500) {
            $content = substr($content, 0, 500) . "\n... [system prompt truncated]";
        }
        $content_html = '<pre class="system-content">' . _html_escape($content) . '</pre>';
    }
    else {
        return '';  # Unknown role
    }
    
    my $time_html = '';
    if ($timestamp) {
        $time_html = '<span class="timestamp">' . _html_escape($timestamp) . '</span>';
    }
    
    return qq{<div class="message $role_class">
  <div class="message-header">
    <span class="role-label">$role_label</span>$time_html
  </div>
  <div class="message-content">$content_html</div>
</div>};
}

# Format tool_calls array for display
sub _format_tool_calls {
    my ($self, $tool_calls) = @_;
    
    return '' unless $tool_calls && ref($tool_calls) eq 'ARRAY';
    
    my @parts;
    for my $tc (@$tool_calls) {
        next unless ref($tc) eq 'HASH';
        my $fn = $tc->{function} || {};
        my $name = $fn->{name} || 'unknown';
        my $args = $fn->{arguments} || '{}';
        
        # Try to pretty-print arguments
        my $args_display = eval {
            my $decoded = decode_json($args);
            my $op = $decoded->{operation} || '';
            my $path = $decoded->{path} || '';
            my $cmd = $decoded->{command} || '';
            my $query = $decoded->{query} || '';
            
            my @details;
            push @details, $op if $op;
            push @details, $path if $path;
            push @details, "\"$cmd\"" if $cmd;
            push @details, "\"$query\"" if $query && !$cmd;
            
            join(' ', @details) || $args;
        } || $args;
        
        push @parts, '<div class="tool-call"><span class="tool-name">' . 
            _html_escape($name) . '</span> ' . 
            _html_escape($args_display) . '</div>';
    }
    
    return join("\n", @parts);
}

# Simple markdown to HTML conversion (inline only - no full parser needed)
sub _markdown_to_html {
    my ($self, $text) = @_;
    
    return '' unless defined $text;
    
    my @lines = split /\n/, $text;
    my @output;
    my $in_code_block = 0;
    my $code_lang = '';
    my @code_lines;
    
    for my $line (@lines) {
        # Code block handling
        if ($line =~ /^```(\w*)/) {
            if ($in_code_block) {
                # End code block
                my $code_content = _html_escape(join("\n", @code_lines));
                my $lang_attr = $code_lang ? " data-lang=\"$code_lang\"" : '';
                my $lang_label = $code_lang ? "<span class=\"code-lang\">$code_lang</span>" : '';
                push @output, "<div class=\"code-block\">$lang_label<pre><code$lang_attr>$code_content</code></pre></div>";
                @code_lines = ();
                $in_code_block = 0;
                $code_lang = '';
            } else {
                # Start code block
                $in_code_block = 1;
                $code_lang = $1 || '';
            }
            next;
        }
        
        if ($in_code_block) {
            push @code_lines, $line;
            next;
        }
        
        # Headers
        if ($line =~ /^(#{1,6})\s+(.+)/) {
            my $level = length($1);
            my $text_h = _html_escape($2);
            push @output, "<h$level>$text_h</h$level>";
            next;
        }
        
        # Horizontal rule
        if ($line =~ /^[-*_]{3}\s*$/) {
            push @output, '<hr>';
            next;
        }
        
        # Unordered list items
        if ($line =~ /^(\s*)[*\-+]\s+(.+)/) {
            my $content_li = $self->_inline_markdown(_html_escape($2));
            push @output, "<li>$content_li</li>";
            next;
        }
        
        # Ordered list items
        if ($line =~ /^(\s*)\d+\.\s+(.+)/) {
            my $content_li = $self->_inline_markdown(_html_escape($2));
            push @output, "<li>$content_li</li>";
            next;
        }
        
        # Empty line = paragraph break
        if ($line =~ /^\s*$/) {
            push @output, '<br>';
            next;
        }
        
        # Regular text with inline formatting
        my $escaped = _html_escape($line);
        push @output, '<p>' . $self->_inline_markdown($escaped) . '</p>';
    }
    
    # Close unclosed code block
    if ($in_code_block && @code_lines) {
        my $code_content = _html_escape(join("\n", @code_lines));
        push @output, "<div class=\"code-block\"><pre><code>$code_content</code></pre></div>";
    }
    
    return join("\n", @output);
}

# Apply inline markdown formatting (bold, italic, code, links)
sub _inline_markdown {
    my ($self, $text) = @_;
    
    # Inline code (must be first to prevent inner formatting)
    $text =~ s/`([^`]+)`/<code class="inline-code">$1<\/code>/g;
    
    # Bold + italic
    $text =~ s/\*\*\*(.+?)\*\*\*/<strong><em>$1<\/em><\/strong>/g;
    
    # Bold
    $text =~ s/\*\*(.+?)\*\*/<strong>$1<\/strong>/g;
    
    # Italic
    $text =~ s/\*(.+?)\*/<em>$1<\/em>/g;
    
    # Strikethrough
    $text =~ s/~~(.+?)~~/<del>$1<\/del>/g;
    
    # Links [text](url)
    $text =~ s/\[([^\]]+)\]\(([^)]+)\)/<a href="$2">$1<\/a>/g;
    
    return $text;
}

# HTML entity escaping
sub _html_escape {
    my ($text) = @_;
    return '' unless defined $text;
    $text =~ s/&/&amp;/g;
    $text =~ s/</&lt;/g;
    $text =~ s/>/&gt;/g;
    $text =~ s/"/&quot;/g;
    return $text;
}

# Wrap content in full HTML document
sub _wrap_html {
    my ($self, $title, $content, $meta) = @_;
    
    my $session_id = _html_escape($meta->{session_id} || '');
    my $created_at = _html_escape($meta->{created_at} || '');
    my $model = _html_escape($meta->{model} || '');
    my $export_time = _html_escape($meta->{export_time} || '');
    my $msg_count = $meta->{message_count} || 0;
    my $escaped_title = _html_escape($title);
    
    return <<"HTML";
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>$escaped_title</title>
<style>
:root {
  --bg: #1a1b26;
  --fg: #c0caf5;
  --surface: #24283b;
  --surface-hover: #292e42;
  --border: #3b4261;
  --accent: #7aa2f7;
  --accent-dim: #3d59a1;
  --user-bg: #1f2335;
  --user-border: #3d59a1;
  --assistant-bg: #1a1b26;
  --assistant-border: #7aa2f7;
  --tool-bg: #1f2335;
  --tool-border: #565f89;
  --system-bg: #1f2335;
  --system-border: #565f89;
  --code-bg: #16161e;
  --code-border: #3b4261;
  --dim: #565f89;
  --error: #f7768e;
  --success: #9ece6a;
  --warning: #e0af68;
}

* { margin: 0; padding: 0; box-sizing: border-box; }

body {
  font-family: 'SF Mono', 'Fira Code', 'JetBrains Mono', 'Cascadia Code', monospace;
  background: var(--bg);
  color: var(--fg);
  line-height: 1.6;
  padding: 0;
}

.container {
  max-width: 900px;
  margin: 0 auto;
  padding: 20px;
}

/* Header */
.session-header {
  border-bottom: 1px solid var(--border);
  padding-bottom: 16px;
  margin-bottom: 24px;
}

.session-header h1 {
  font-size: 1.4em;
  color: var(--accent);
  margin-bottom: 8px;
  font-weight: 600;
}

.session-meta {
  display: flex;
  flex-wrap: wrap;
  gap: 16px;
  font-size: 0.85em;
  color: var(--dim);
}

.session-meta span { white-space: nowrap; }
.session-meta .label { color: var(--dim); }
.session-meta .value { color: var(--fg); }

/* Messages */
.message {
  margin-bottom: 16px;
  border-left: 3px solid var(--border);
  padding: 12px 16px;
  border-radius: 0 4px 4px 0;
}

.message.user {
  background: var(--user-bg);
  border-left-color: var(--user-border);
}

.message.assistant {
  background: var(--assistant-bg);
  border-left-color: var(--assistant-border);
}

.message.tool {
  background: var(--tool-bg);
  border-left-color: var(--tool-border);
  font-size: 0.85em;
}

.message.system {
  background: var(--system-bg);
  border-left-color: var(--system-border);
  font-size: 0.85em;
  opacity: 0.7;
}

.message-header {
  display: flex;
  align-items: center;
  gap: 12px;
  margin-bottom: 8px;
}

.role-label {
  font-weight: 700;
  font-size: 0.8em;
  text-transform: uppercase;
  letter-spacing: 0.05em;
}

.user .role-label { color: var(--accent-dim); }
.assistant .role-label { color: var(--accent); }
.tool .role-label { color: var(--dim); }
.system .role-label { color: var(--dim); }

.timestamp {
  font-size: 0.75em;
  color: var(--dim);
}

.message-content {
  color: var(--fg);
}

.message-content p {
  margin-bottom: 4px;
}

.message-content h1, .message-content h2, .message-content h3,
.message-content h4, .message-content h5, .message-content h6 {
  color: var(--accent);
  margin: 12px 0 6px 0;
}

.message-content li {
  margin-left: 20px;
  margin-bottom: 2px;
}

.message-content hr {
  border: none;
  border-top: 1px solid var(--border);
  margin: 12px 0;
}

.message-content a {
  color: var(--accent);
  text-decoration: underline;
}

/* Code */
.code-block {
  position: relative;
  margin: 8px 0;
  border: 1px solid var(--code-border);
  border-radius: 4px;
  overflow: hidden;
}

.code-block .code-lang {
  display: block;
  background: var(--surface);
  color: var(--dim);
  font-size: 0.75em;
  padding: 4px 12px;
  border-bottom: 1px solid var(--code-border);
}

.code-block pre {
  background: var(--code-bg);
  padding: 12px;
  overflow-x: auto;
  font-size: 0.9em;
  line-height: 1.5;
}

.code-block code {
  color: var(--fg);
}

.inline-code {
  background: var(--code-bg);
  border: 1px solid var(--code-border);
  padding: 1px 5px;
  border-radius: 3px;
  font-size: 0.9em;
}

/* Tool calls */
.tool-call {
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: 4px;
  padding: 6px 12px;
  margin: 4px 0;
  font-size: 0.85em;
}

.tool-name {
  color: var(--accent);
  font-weight: 600;
}

.tool-result {
  background: var(--code-bg);
  border: 1px solid var(--code-border);
  border-radius: 4px;
  padding: 8px 12px;
  font-size: 0.9em;
  overflow-x: auto;
  white-space: pre-wrap;
  word-wrap: break-word;
}

.system-content {
  background: var(--code-bg);
  border: 1px solid var(--code-border);
  border-radius: 4px;
  padding: 8px 12px;
  font-size: 0.85em;
  overflow-x: auto;
  white-space: pre-wrap;
  word-wrap: break-word;
  opacity: 0.8;
}

/* Footer */
.export-footer {
  margin-top: 32px;
  padding-top: 16px;
  border-top: 1px solid var(--border);
  font-size: 0.8em;
  color: var(--dim);
  text-align: center;
}

/* Responsive */
\@media (max-width: 600px) {
  .container { padding: 12px; }
  .message { padding: 8px 12px; }
  .session-meta { flex-direction: column; gap: 4px; }
}
</style>
</head>
<body>
<div class="container">
  <div class="session-header">
    <h1>CLIO Session</h1>
    <div class="session-meta">
      <span><span class="label">Session:</span> <span class="value">$session_id</span></span>
      <span><span class="label">Created:</span> <span class="value">$created_at</span></span>
      <span><span class="label">Model:</span> <span class="value">$model</span></span>
      <span><span class="label">Messages:</span> <span class="value">$msg_count</span></span>
    </div>
  </div>

$content

  <div class="export-footer">
    Exported by CLIO on $export_time
  </div>
</div>
</body>
</html>
HTML
}

1;

__END__

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

Same as CLIO.

=cut
