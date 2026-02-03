# Tool Error Guidance System - Implementation Summary

## Problem

When agents make bad tool calls (missing required parameters, invalid values, etc.), they were receiving vague error messages that provided no guidance on how to fix the problem. This caused agents to:

1. Abandon the tool and try alternatives
2. Give up after repeated failures
3. Not understand what went wrong or how to fix it

**Example from bug report:**
```
[claude-haiku-4.5] CLIO: Got it - you're right to flag that. The collaboration tool failed 
when I called it without the required message parameter. Let me check the tool definition 
to understand what went wrong...

The tool requires:
• operation (required): "request_input"
• message (required): The question/update for the user
• context (optional): Additional context

The Bug: The tool's error handling didn't give a clear error message - it just said 
"Missing required parameter: message" both times.
```

The agent had to figure out the schema on its own because the error message didn't provide it.

## Solution

### 1. New Module: `CLIO::Core::ToolErrorGuidance`

Created a comprehensive error guidance system that:

#### Categorizes Errors
- `missing_required` - Missing required parameters
- `invalid_operation` - Wrong operation name
- `invalid_json` - Malformed JSON parameters
- `invalid_value` - Invalid parameter values
- `file_not_found` - File doesn't exist
- `permission_denied` - Access denied
- `generic_error` - Unknown errors

#### Provides Targeted Guidance
For each error category, the system provides:

1. **Clear Problem Statement**
   - What went wrong
   - Which parameters are missing/wrong

2. **How to Fix**
   - Specific guidance for this error type
   - Common mistakes to avoid

3. **Schema Reference**
   - All parameters with types
   - Required vs optional markers
   - Allowed values (for enums)
   - Descriptions

4. **Usage Examples**
   - Tool-specific examples of correct usage
   - Multiple scenarios where applicable

#### Example Output

```
TOOL ERROR: user_collaboration
Missing required parameter: message

WHAT WENT WRONG: You didn't include the required parameter(s): message
HOW TO FIX: Include these required parameters in your tool call.
REQUIRED: All parameters marked 'required' in the schema MUST be included.

--- SCHEMA REFERENCE ---

Parameters:

  message [REQUIRED]
    Type: string
    Description: The question/update for the user

  operation [REQUIRED]
    Type: string
    Description: Operation to perform
    Allowed values: request_input

  context [optional]
    Type: string
    Description: Optional context

--- CORRECT USAGE EXAMPLES ---
Requesting user input:
  {"operation": "request_input", "message": "Which approach should I use?", "context": "Optional context here"}

The message parameter is REQUIRED and must clearly ask the user for what you need.
```

### 2. Integration in WorkflowOrchestrator

Modified `CLIO::Core::WorkflowOrchestrator` to:

1. Initialize `ToolErrorGuidance` in constructor
2. When a tool returns an error:
   - Get the tool definition from registry
   - Get the parameters agent attempted to use
   - Call `enhance_tool_error()` to generate comprehensive guidance
   - Send enhanced error to AI instead of bare error message

**Code Changes:**
```perl
# In WorkflowOrchestrator execute_tool section (~line 1065)
if (exists $result_data->{success} && !$result_data->{success}) {
    $is_error = 1;
    
    # ENHANCEMENT: Provide schema guidance to help agent recover
    my $tool_obj = $self->{tool_registry}->get_tool($tool_name);
    my $tool_def = undef;
    if ($tool_obj && $tool_obj->can('get_tool_definition')) {
        $tool_def = $tool_obj->get_tool_definition();
    }
    
    # Use error guidance system to enhance the error message
    $enhanced_error_for_ai = $self->{error_guidance}->enhance_tool_error(
        error => $error_msg,
        tool_name => $tool_name,
        tool_definition => $tool_def,
        attempted_params => $attempted_params
    );
}

# Later, when sending to AI:
if ($is_error && $enhanced_error_for_ai) {
    $ai_content = $enhanced_error_for_ai;  # Use enhanced error
} elsif (...) {
    $ai_content = $result_data->{output};  # Use normal output
}
```

## Files Changed

### New Files
- `lib/CLIO/Core/ToolErrorGuidance.pm` - Error guidance system
- `tests/unit/test_error_guidance.pl` - Unit tests
- `tests/unit/test_error_guidance_integration.pl` - Integration test

### Modified Files
- `lib/CLIO/Core/WorkflowOrchestrator.pm`
  - Added import for `ToolErrorGuidance`
  - Initialize guidance system in constructor
  - Enhanced tool result error handling
  - Send enhanced errors to AI

## Expected Behavior Changes

### Before
```
Agent: calls user_collaboration without message
Error returned: "ERROR: Missing required parameter: message"
Agent: Doesn't understand what's missing, tries other tools or gives up
```

### After
```
Agent: calls user_collaboration without message
Error returned: [Detailed guidance with schema, examples, and "how to fix"]
Agent: Reads guidance, sees it needs 'message' parameter, fixes it immediately
Agent: Makes correct call on next attempt
```

## Testing

### Unit Tests
- `tests/unit/test_error_guidance.pl` - Tests all error categories with real tool schemas
- Verifies error categorization works correctly
- Verifies schema formatting is readable
- Verifies examples are provided for each tool

### Integration Tests
- `tests/unit/test_error_guidance_integration.pl` - Tests end-to-end with actual tools
- Simulates agent making a bad call
- Verifies error guidance is provided
- Verifies guidance helps agent understand what to fix

### All Syntax Checks Passed
- All Core modules: ✓
- All Tools modules: ✓
- Main clio script: ✓

## Benefits

1. **Agents Don't Abandon Tools** - Clear guidance on how to fix errors
2. **Reduced API Calls** - Agents fix issues faster instead of retrying blindly
3. **Better Error Recovery** - Targeted guidance for each error type
4. **Self-Service Resolution** - Agents have all info needed to fix their own mistakes
5. **Improved Schema Awareness** - Full schema reference in every error

## Backward Compatibility

- No breaking changes to tool interfaces
- Existing error messages still work (enhanced with guidance)
- Tool definitions already existed (just used more effectively)
- No new dependencies added

## Future Enhancements

1. Add more error categories as they're discovered
2. Add video examples in schema (if supported)
3. Add "Did you mean?" suggestions for typos
4. Track common errors to improve guidance over time
5. Add error severity levels (warning vs critical)

## References

- **Bug Report:** When agents get bad tool call errors, they're not getting correct guidance
- **Module:** `CLIO::Core::ToolErrorGuidance`
- **Integration Point:** `CLIO::Core::WorkflowOrchestrator` (line ~1065-1130)
- **Tool Base Class:** `CLIO::Tools::Tool` (already had good error methods)
