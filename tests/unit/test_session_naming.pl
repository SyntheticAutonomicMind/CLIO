#!/usr/bin/env perl
# Test session naming via AI-generated markers
# Tests the extraction regex, prompt generation, and fallback behavior

use strict;
use warnings;
use utf8;
use Test::More;

# Test 1: PromptBuilder generates session naming section
subtest 'generate_session_naming_section' => sub {
    require CLIO::Core::PromptBuilder;
    
    my $section = CLIO::Core::PromptBuilder::generate_session_naming_section();
    ok(defined $section, "Section generated");
    ok(length($section) > 100, "Section has meaningful content");
    like($section, qr/<!--session:/, "Contains marker format example");
    like($section, qr/3-6 words/, "Contains word count instruction");
    like($section, qr/FIRST response/, "Specifies first response only");
    like($section, qr/LAST line/, "Specifies placement at end");
};

# Test 2: Marker extraction regex (used in WorkflowOrchestrator)
subtest 'marker extraction' => sub {
    my @tests = (
        {
            input => "Hello world\n<!--session:{\"title\":\"fix session naming\"}-->",
            title => "fix session naming",
            desc  => "basic marker at end",
        },
        {
            input => "Response text\n\n<!--session:{\"title\":\"debug API auth flow\"}-->\n",
            title => "debug API auth flow",
            desc  => "marker with trailing newline",
        },
        {
            input => "Short reply <!--session:{\"title\":\"test query\"}-->",
            title => "test query",
            desc  => "marker on same line as content",
        },
        {
            input => "No marker here",
            title => undef,
            desc  => "no marker present",
        },
        {
            input => "<!--session:{\"title\":\"ab\"}-->",
            title => undef,
            desc  => "title too short (< 3 chars)",
        },
        {
            input => "Multiple\nlines\nof content\n\n<!--session:{\"title\":\"refactor Chat module\"}-->",
            title => "refactor Chat module",
            desc  => "multiline content with marker",
        },
        {
            input => "<!--session:{\"title\":\"a]b\"}-->",
            title => "a]b",
            desc  => "title with special chars (valid)",
        },
    );

    for my $t (@tests) {
        my $content = $t->{input};
        my $title = undef;

        if ($content =~ s/\s*<!--session:\{[^}]*"title"\s*:\s*"([^"]{3,80})"[^}]*\}-->\s*//s) {
            $title = $1;
            $title =~ s/^\s+|\s+$//g;
            $title = undef if length($title) < 3;
        }

        if (defined $t->{title}) {
            is($title, $t->{title}, "$t->{desc}: extracted '$t->{title}'");
        } else {
            ok(!defined $title, "$t->{desc}: no title extracted");
        }
    }
};

# Test 3: Content is cleaned after marker extraction
subtest 'content cleanup after extraction' => sub {
    my $content = "Here is my response.\n\n<!--session:{\"title\":\"session naming feature\"}-->\n";
    
    $content =~ s/\s*<!--session:\{[^}]*"title"\s*:\s*"([^"]{3,80})"[^}]*\}-->\s*//s;
    my $title = $1;
    
    is($title, "session naming feature", "Title extracted correctly");
    unlike($content, qr/<!--session:/, "Marker removed from content");
    like($content, qr/Here is my response/, "Original content preserved");
};

# Test 4: Streaming line filter regex
subtest 'streaming line filter' => sub {
    my @tests = (
        ['<!--session:{"title":"fix bug"}-->', 1, "exact marker"],
        ['  <!--session:{"title":"fix bug"}-->  ', 1, "marker with whitespace"],
        ['Hello <!--session:{"title":"fix bug"}-->', 0, "text before marker"],
        ['<!-- not a session -->', 0, "non-session comment"],
        ['<!--session:{"title":""}-->', 1, "empty title (matched but extraction won't use it)"],
    );

    for my $t (@tests) {
        my ($line, $expected, $desc) = @$t;
        my $matched = ($line =~ /^\s*<!--session:\{.*\}-->\s*$/) ? 1 : 0;
        is($matched, $expected, "line filter: $desc");
    }
};

# Test 5: _generate_session_name fallback still works
subtest 'text truncation fallback' => sub {
    # Simulate the _generate_session_name function from Chat.pm
    my $generate = sub {
        my ($text) = @_;
        return unless defined $text && length($text) > 0;
        my $name = $text;
        $name =~ s/^\s+//;
        $name =~ s/\s+$//;
        $name =~ s/\s+/ /g;
        $name =~ s/^(?:hey|hi|hello|please|can you|could you|i want to|i need to|i'd like to|let's)\s+//i;
        $name = ucfirst($name);
        if (length($name) > 50) {
            $name = substr($name, 0, 50);
            $name =~ s/\s+\S*$//;
            $name .= '...' if length($name) > 0;
        }
        return undef if length($name) < 3;
        return $name;
    };

    is($generate->("fix the session naming"), "Fix the session naming", "Simple input");
    is($generate->("please fix the bug"), "Fix the bug", "Strips filler");
    is($generate->("hi"), undef, "Too short");
    like($generate->("A very long message that goes on and on and on and on about nothing in particular"), qr/\.\.\.$/, "Truncated with ellipsis");
};

# Test 6: Accumulated content stripping regex
subtest 'accumulated content stripping' => sub {
    my $acc = "Response text\n\n<!--session:{\"title\":\"test session\"}-->\n";
    $acc =~ s/\s*<!--session:\{[^}]*\}-->\s*//sg;
    unlike($acc, qr/<!--session:/, "Marker stripped from accumulated content");
    like($acc, qr/Response text/, "Content preserved");
};

done_testing();
