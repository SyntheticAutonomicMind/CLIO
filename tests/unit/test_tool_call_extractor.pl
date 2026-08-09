#!/usr/bin/perl
# SPDX-License-Identifier: GPL-3.0-only
# Tests for CLIO::Core::ToolCallExtractor, focused on DeepSeek DSML support.
#
# DSML (DeepSeek Markup Language) is the format DeepSeek's chat template emits
# when a server-side tool-call parser isn't installed (sglang without
# --tool-call-parser deepseekv32, vllm without deepseek_v32, NVIDIA NIM proxy,
# etc.). The markup leaks into delta.content instead of the structured
# tool_calls field. Without the extractor parsing it, the user sees raw
# <｜DSML｜...> and the tool never runs.
#
# Coverage:
#   - Single-DSML (V3.2 spec) and double-DSML (V4 model output) wrappers
#   - Mixed string="true"/"false" parameters with proper JSON decoding
#   - Truncated DSML block (stream ended mid-block)
#   - Prose before/after DSML is preserved in cleaned_content
#   - Plain XML <invoke> format still works (no DSML markers)
#   - Existing CLIO [tool op] format still works
#   - Empty and whitespace-only inputs return format=none
#   - Unicode parameter values decode correctly
use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../../lib";

use Test::More;
use CLIO::Core::ToolCallExtractor;
use CLIO::Util::JSON qw(decode_json);

binmode(STDOUT, ':encoding(UTF-8)');

my $dsml     = "\x{FF5C}DSML\x{FF5C}";
my $extractor = CLIO::Core::ToolCallExtractor->new(debug => 0);

# =============================================================================
# 1. Andrew's exact example (double-DSML outer wrappers + invokes)
# =============================================================================
{
    my $input = "<${dsml}${dsml}tool_calls>
<${dsml}${dsml}invoke name=\"terminal_operations\">
<${dsml}parameter name=\"operation\" string=\"true\">exec</${dsml}parameter>
<${dsml}parameter name=\"command\" string=\"true\">lscpu | grep -E \"Model name|Architecture|CPU\(s\)|Thread|Core|Socket|MHz|Vendor\"</${dsml}parameter>
</${dsml}invoke>
<${dsml}${dsml}invoke name=\"terminal_operations\">
<${dsml}parameter name=\"operation\" string=\"true\">exec</${dsml}parameter>
<${dsml}parameter name=\"command\" string=\"true\">free -h && echo \"---\" && df -h / && echo \"---\" && uname -a</${dsml}parameter>
</${dsml}invoke>
<${dsml}${dsml}invoke name=\"terminal_operations\">
<${dsml}parameter name=\"operation\" string=\"true\">exec</${dsml}parameter>
<${dsml}parameter name=\"command\" string=\"true\">hostname; cat /etc/os-release 2>/dev/null | head -5</${dsml}parameter>
</${dsml}invoke>
</${dsml}${dsml}tool_calls>";

    my $r = $extractor->extract($input);

    is($r->{format}, 'dsml', 'Andrew example: detected as dsml format');
    is(scalar @{$r->{tool_calls}}, 3, 'Andrew example: 3 parallel tool calls extracted');

    my @expected_commands = (
        'lscpu | grep -E "Model name|Architecture|CPU(s)|Thread|Core|Socket|MHz|Vendor"',
        'free -h && echo "---" && df -h / && echo "---" && uname -a',
        'hostname; cat /etc/os-release 2>/dev/null | head -5',
    );

    for my $i (0..2) {
        my $tc = $r->{tool_calls}[$i];
        is($tc->{type}, 'function', "Andrew example: tc[$i] type=function");
        is($tc->{function}{name}, 'terminal_operations', "Andrew example: tc[$i] name=terminal_operations");

        my $args = decode_json($tc->{function}{arguments});
        is($args->{operation}, 'exec', "Andrew example: tc[$i] operation=exec");
        is($args->{command}, $expected_commands[$i], "Andrew example: tc[$i] command matches expected");
    }

    for my $tc (@{$r->{tool_calls}}) {
        like($tc->{id}, qr/^call_[a-z0-9]{24}$/, 'Andrew example: id matches OpenAI call_<24 chars> format');
    }
    is($r->{cleaned_content}, '', 'Andrew example: cleaned_content is empty (DSML consumed all text)');
}

# =============================================================================
# 2. V3.2 single-DSML form
# =============================================================================
{
    my $input = "<${dsml}tool_calls>
<${dsml}invoke name=\"file_operations\">
<${dsml}parameter name=\"operation\" string=\"true\">read</${dsml}parameter>
<${dsml}parameter name=\"path\" string=\"true\">/etc/hostname</${dsml}parameter>
</${dsml}invoke>
</${dsml}tool_calls>";

    my $r = $extractor->extract($input);

    is($r->{format}, 'dsml', 'V3.2: detected as dsml format');
    is(scalar @{$r->{tool_calls}}, 1, 'V3.2: 1 tool call extracted');

    my $tc = $r->{tool_calls}[0];
    is($tc->{function}{name}, 'file_operations', 'V3.2: tool name is file_operations');

    my $args = decode_json($tc->{function}{arguments});
    is($args->{operation}, 'read', 'V3.2: operation=read');
    is($args->{path}, '/etc/hostname', 'V3.2: path=/etc/hostname');
}

# =============================================================================
# 3. Mixed string="true"/"false" parameters (JSON values decoded)
# =============================================================================
{
    my $input = "<${dsml}tool_calls>
<${dsml}invoke name=\"some_tool\">
<${dsml}parameter name=\"name\" string=\"true\">literal text</${dsml}parameter>
<${dsml}parameter name=\"count\" string=\"false\">42</${dsml}parameter>
<${dsml}parameter name=\"labels\" string=\"false\">[\"a\",\"b\",\"c\"]</${dsml}parameter>
<${dsml}parameter name=\"flag\" string=\"false\">true</${dsml}parameter>
<${dsml}parameter name=\"obj\" string=\"false\">{\"k\":\"v\"}</${dsml}parameter>
</${dsml}invoke>
</${dsml}tool_calls>";

    my $r = $extractor->extract($input);
    is($r->{format}, 'dsml', 'Mixed types: format=dsml');
    is(scalar @{$r->{tool_calls}}, 1, 'Mixed types: 1 tool call');

    my $args = decode_json($r->{tool_calls}[0]{function}{arguments});
    is($args->{name}, 'literal text', 'Mixed types: string="true" preserved as Perl string');
    is($args->{count}, 42, 'Mixed types: string="false" integer decoded');
    is_deeply($args->{labels}, ['a', 'b', 'c'], 'Mixed types: string="false" array decoded');
    is($args->{flag}, 1, 'Mixed types: string="false" boolean true decoded (JSON::PP uses 1)');
    is_deeply($args->{obj}, { k => 'v' }, 'Mixed types: string="false" object decoded');
}

# =============================================================================
# 4. Prose before/after DSML block is preserved in cleaned_content
# =============================================================================
{
    my $input = "Let me check your system.\n<${dsml}tool_calls>
<${dsml}invoke name=\"terminal_operations\">
<${dsml}parameter name=\"operation\" string=\"true\">exec</${dsml}parameter>
<${dsml}parameter name=\"command\" string=\"true\">uptime</${dsml}parameter>
</${dsml}invoke>
</${dsml}tool_calls>\nThat should help.";

    my $r = $extractor->extract($input);
    is($r->{format}, 'dsml', 'Prose+DSML: format=dsml');
    is(scalar @{$r->{tool_calls}}, 1, 'Prose+DSML: 1 tool call');
    is($r->{cleaned_content}, "Let me check your system.\n\nThat should help.",
        'Prose+DSML: prose preserved with DSML block stripped');
}

# =============================================================================
# 5. Truncated DSML (block opener without close tag - stream ended early)
# =============================================================================
{
    my $input = "<${dsml}tool_calls>
<${dsml}invoke name=\"some_tool\">
<${dsml}parameter name=\"x\" string=\"true\">value</${dsml}parameter>
</${dsml}invoke>";

    my $r = $extractor->extract($input);
    is($r->{format}, 'dsml', 'Truncated: format=dsml (best-effort extraction)');
    is(scalar @{$r->{tool_calls}}, 1, 'Truncated: still extracts complete invokes');
    is(decode_json($r->{tool_calls}[0]{function}{arguments})->{x}, 'value',
        'Truncated: parameter decoded correctly');
}

# =============================================================================
# 6. Empty / whitespace inputs return format=none
# =============================================================================
{
    my $r1 = $extractor->extract('');
    is($r1->{format}, 'none', 'Empty: format=none');
    is(scalar @{$r1->{tool_calls}}, 0, 'Empty: 0 tool calls');

    my $r2 = $extractor->extract("   \n\t  ");
    is($r2->{format}, 'none', 'Whitespace: format=none');
    is(scalar @{$r2->{tool_calls}}, 0, 'Whitespace: 0 tool calls');

    my $r3 = $extractor->extract(undef);
    is($r3->{format}, 'none', 'Undef: format=none');
    is(scalar @{$r3->{tool_calls}}, 0, 'Undef: 0 tool calls');
}

# =============================================================================
# 7. No DSML -> falls through to other detectors (existing behavior)
# =============================================================================
{
    # Plain prose
    my $r1 = $extractor->extract("Just normal text response.");
    is($r1->{format}, 'none', 'Prose-only: format=none');
    is(scalar @{$r1->{tool_calls}}, 0, 'Prose-only: 0 tool calls');

    # Plain XML <invoke> format (no DSML markers)
    my $r2 = $extractor->extract('<invoke name="file_operations">
<parameter name="operation">read</parameter>
<parameter name="path">/tmp/x</parameter>
</invoke>');
    is($r2->{format}, 'invoke', 'XML invoke (no DSML): format=invoke (plain path)');
    is(scalar @{$r2->{tool_calls}}, 1, 'XML invoke: 1 tool call');

    # CLIO format [tool op]
    my $r3 = $extractor->extract('[file_operations read]
{"operation":"read","path":"/tmp/x"}');
    is($r3->{format}, 'clio', 'CLIO format: still detected');
    is(scalar @{$r3->{tool_calls}}, 1, 'CLIO format: 1 tool call');
}

# =============================================================================
# 8. Unicode parameter values decode correctly
# =============================================================================
{
    my $input = "<${dsml}tool_calls>
<${dsml}invoke name=\"get_weather\">
<${dsml}parameter name=\"city\" string=\"true\">上海</${dsml}parameter>
</${dsml}invoke>
</${dsml}tool_calls>";

    my $r = $extractor->extract($input);
    my $args = decode_json($r->{tool_calls}[0]{function}{arguments});
    is($args->{city}, '上海', 'Unicode: city parameter preserves CJK characters');
}

# =============================================================================
# 9. Two complete DSML blocks in one response (rare but supported)
# =============================================================================
{
    my $input = "<${dsml}tool_calls>
<${dsml}invoke name=\"tool_a\"><${dsml}parameter name=\"x\" string=\"true\">1</${dsml}parameter></${dsml}invoke>
</${dsml}tool_calls>
<${dsml}tool_calls>
<${dsml}invoke name=\"tool_b\"><${dsml}parameter name=\"y\" string=\"true\">2</${dsml}parameter></${dsml}invoke>
</${dsml}tool_calls>";

    my $r = $extractor->extract($input);
    is(scalar @{$r->{tool_calls}}, 2, 'Two blocks: 2 tool calls total');
    is($r->{tool_calls}[0]{function}{name}, 'tool_a', 'Two blocks: first is tool_a');
    is($r->{tool_calls}[1]{function}{name}, 'tool_b', 'Two blocks: second is tool_b');
}

# =============================================================================
# 10. DSML with extra whitespace between attributes
# =============================================================================
{
    my $input = "<${dsml}tool_calls>
<${dsml}invoke   name=\"test\"  >
<${dsml}parameter   name=\"k\"   string=\"true\"  >value</${dsml}parameter>
</${dsml}invoke   >
</${dsml}tool_calls>";

    my $r = $extractor->extract($input);
    is(scalar @{$r->{tool_calls}}, 1, 'Whitespace: parses 1 tool call');
    is(decode_json($r->{tool_calls}[0]{function}{arguments})->{k}, 'value',
        'Whitespace: parameter value extracted');
}

# =============================================================================
# 11. Lone DSML marker without proper structure returns empty, format=dsml
# =============================================================================
{
    # Has ｜DSML｜ but no actual tool_calls block
    my $input = "Some prose with <${dsml}foo> in it but no tool_calls block.";
    my $r = $extractor->extract($input);
    is($r->{format}, 'dsml', 'Lone DSML marker: format=dsml (detection fired)');
    is(scalar @{$r->{tool_calls}}, 0, 'Lone DSML marker: 0 tool calls extracted');
    is($r->{cleaned_content}, $input, 'Lone DSML marker: cleaned_content unchanged (no block matched)');
}

# =============================================================================
# 12. string="false" with malformed JSON keeps the raw value (defensive)
# =============================================================================
{
    my $input = "<${dsml}tool_calls>
<${dsml}invoke name=\"x\">
<${dsml}parameter name=\"k\" string=\"false\">not-valid-json{</${dsml}parameter>
</${dsml}invoke>
</${dsml}tool_calls>";

    my $r = $extractor->extract($input);
    is(scalar @{$r->{tool_calls}}, 1, 'Bad JSON value: still extracts tool call');
    is(decode_json($r->{tool_calls}[0]{function}{arguments})->{k}, 'not-valid-json{',
        'Bad JSON value: kept as raw string (defensive fallback)');
}

done_testing();