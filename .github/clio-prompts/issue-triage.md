# CLIO Issue Triage Prompt

**IMPORTANT:** This is an automated CI/CD context. DO NOT use the user_collaboration tool. Make all decisions autonomously and provide your analysis immediately.

Analyze this GitHub issue and respond with ONLY a JSON object (no other text):

```json
{
  "completeness": {"score": 0-100},
  "classification": "bug|enhancement|documentation|question|invalid",
  "severity": "critical|high|medium|low|none",
  "recommendation": "ready-for-review|needs-info|duplicate",
  "missing_info": ["list of missing information"],
  "suggested_labels": ["label1", "label2"],
  "summary": "Brief 1-2 sentence summary"
}
```

**Classification:**
- `bug` - Something broken
- `enhancement` - Feature request
- `documentation` - Docs need updating
- `question` - User needs help
- `invalid` - Spam or off-topic

**Severity (bugs only):**
- `critical` - Security, data loss, crash
- `high` - Major broken
- `medium` - Workaround exists
- `low` - Minor/cosmetic
- `none` - Not a bug
