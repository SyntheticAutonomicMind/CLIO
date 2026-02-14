# PR Review Instructions - HEADLESS CI/CD MODE

## [WARN]️ CRITICAL: HEADLESS OPERATION

**YOU ARE IN HEADLESS CI/CD MODE:**
- NO HUMAN IS PRESENT
- DO NOT use user_collaboration - it will hang forever
- DO NOT ask questions - nobody will answer
- DO NOT checkpoint - this is automated
- JUST READ FILES AND WRITE JSON TO FILE

## Your Task

1. Read `PR_INFO.md` in your workspace for PR metadata
2. Read `PR_DIFF.txt` for the actual code changes
3. Read `PR_FILES.txt` to see which files changed
4. Check relevant project files if needed:
   - `AGENTS.md` - Code style, naming conventions
   - `docs/STYLE_GUIDE.md` - Detailed style rules
5. **WRITE your review to `/workspace/review.json`**

## Key Style Requirements

- `use strict; use warnings; use utf8;` required in every .pm file
- 4 spaces indentation (never tabs)
- UTF-8 encoding
- POD documentation for public modules
- Every .pm file ends with `1;`
- Commit format: `type(scope): description`

## Security Patterns to Flag

- `eval($user_input)` - Code injection
- `system()`, `exec()` with user input
- Hardcoded credentials or API keys
- `chmod 777` or permissive modes
- Path traversal (`../`)

## Output - WRITE TO FILE

**CRITICAL: Write your review to `/workspace/review.json` using file_operations**

Use `file_operations` with operation `create_file` to write:

```json
{
  "recommendation": "approve|needs-changes|needs-review|security-concern",
  "security_concerns": ["List of security issues"],
  "style_issues": ["List of style violations"],
  "documentation_issues": ["Missing docs"],
  "test_coverage": "adequate|insufficient|none|not-applicable",
  "breaking_changes": false,
  "suggested_labels": ["needs-review"],
  "summary": "One sentence summary",
  "detailed_feedback": ["Specific suggestions"]
}
```

## REMEMBER

- NO user_collaboration (causes hang)
- NO questions (nobody will answer)
- Read the files, analyze, **WRITE JSON TO /workspace/review.json**
- Use file_operations to create the file
