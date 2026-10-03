#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test for CLIO::Core::SkillManager::_substitute_variables.
#
# The substitution must be SINGLE-PASS: a variable value that contains a
# literal ${other} reference must NOT be recursively expanded. A multi-pass
# implementation silently turned data into injected variables -- e.g.
#   context: { outer => '${inner}', inner => 'REPLACED' }
#   template: 'before ${outer} after'
# used to expand to 'before REPLACED after' instead of leaving the literal
# '${inner}' in place. This both corrupted skill content and let one
# skill's value reach into another's placeholder (an injection vector if
# any value comes from user/tool output).

use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/../../lib";

use Test::More;
use CLIO::Core::SkillManager;

# Construct without a real config dir: we only exercise _substitute_variables.
my $sm = bless { skills => {}, debug => 0 }, 'CLIO::Core::SkillManager';

# --- Test 1: single-pass. A value containing ${inner} must stay literal. ---
{
    my $ctx = { outer => '${inner}', inner => 'REPLACED' };
    my $r = $sm->_substitute_variables('before ${outer} after', $ctx);
    is($r, 'before ${inner} after',
       'value containing ${inner} is not recursively expanded');
}

# --- Test 2: values are substituted verbatim (no regex interpretation). ---
{
    my $ctx = { path => '/tmp/$HOME/x' };   # $HOME is not a var here
    my $r = $sm->_substitute_variables('${path}/file', $ctx);
    is($r, '/tmp/$HOME/x/file',
       'literal $ in value is preserved verbatim');
}

# --- Test 3: normal substitution still works. ---
{
    my $ctx = { tool => 'file_operations' };
    my $r = $sm->_substitute_variables('use ${tool} now', $ctx);
    is($r, 'use file_operations now', 'normal ${var} substitution works');
}

# --- Test 4: undefined variable -> empty (not an error). ---
{
    my $r = $sm->_substitute_variables('a ${missing} b', undef);
    is($r, 'a  b', 'undefined variable becomes empty string');
}

# --- Test 5: undefined variable key -> empty. ---
{
    my $r = $sm->_substitute_variables('a ${missing} b', {});
    is($r, 'a  b', 'absent key becomes empty string');
}

# --- Test 6: multiple distinct vars in one template. ---
{
    my $r = $sm->_substitute_variables('${a}-${b}-${c}', { a => 'x', b => 'y', c => 'z' });
    is($r, 'x-y-z', 'multiple distinct substitutions all applied');
}

# --- Test 7: a value containing a DIFFERENT var name is not expanded. ---
{
    my $ctx = { a => '${b}', b => 'SHOULD-NOT-APPEAR' };
    my $r = $sm->_substitute_variables('${a}', $ctx);
    is($r, '${b}', 'cross-var injection via value is blocked');
}

# --- Test 8: same var repeated in the template all replaced. ---
{
    my $r = $sm->_substitute_variables('${x} and ${x}', { x => 'once' });
    is($r, 'once and once', 'repeated var substituted each occurrence');
}

# --- Test 9: regex metacharacters in var NAME handled (var names are
#     [a-zA-Z0-9_:]+ so this is a no-op, but confirm no crash / no partial). ---
{
    my $r = $sm->_substitute_variables('plain text', {});
    is($r, 'plain text', 'template with no vars is unchanged');
}

done_testing();
