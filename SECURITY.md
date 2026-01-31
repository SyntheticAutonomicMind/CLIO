# Security Policy

## Supported Versions

CLIO is currently in active development. Security updates are applied to the latest version only.

| Version | Supported          |
| ------- | ------------------ |
| Latest  | :white_check_mark: |
| Older   | :x:                |

## Reporting a Vulnerability

If you discover a security vulnerability in CLIO, please report it responsibly:

### How to Report

1. **Email**: Send details to the repository maintainer (see GitHub profile)
2. **GitHub Security Advisory**: Use GitHub's private vulnerability reporting feature
3. **Do NOT** open a public issue for security vulnerabilities

### What to Include

- Description of the vulnerability
- Steps to reproduce
- Potential impact assessment
- Any suggested fixes (optional but appreciated)

### Response Timeline

- **Acknowledgment**: Within 48 hours
- **Initial Assessment**: Within 1 week
- **Fix Development**: Depends on severity
- **Disclosure**: Coordinated with reporter

## Security Model

### Threat Model

CLIO is designed as a personal development assistant with the following assumptions:

1. **Trusted User**: The user running CLIO is trusted
2. **Untrusted AI Outputs**: AI-generated code/commands are treated with caution
3. **Local Execution**: CLIO runs locally on the user's machine
4. **API Keys**: API keys are stored locally and transmitted securely over HTTPS

### Security Features

#### Path Authorization

CLIO implements a path authorization system:

- Operations inside the working directory are auto-approved
- Operations outside require explicit user confirmation
- This prevents AI from accidentally modifying system files

#### API Key Storage

- API keys are stored in `~/.config/clio/config.json`
- File permissions should be set to user-only (recommended: `chmod 600`)
- Keys are never logged or displayed in full

#### Session Isolation

- Each session has its own isolated workspace
- Session files stored in `.clio/sessions/` with restricted permissions
- Lock files prevent concurrent session access

#### Input Sanitization

- AI outputs are sanitized to remove potentially dangerous content
- Terminal escape sequences are filtered (safe subset allowed)
- UTF-8 encoding is enforced throughout

### Known Limitations

1. **API Key Encryption**: Keys are stored in plain JSON (not encrypted)
   - Mitigation: Ensure proper file permissions
   - Future: OS keychain integration planned

2. **Network Trust**: HTTPS is used but certificate validation details vary by provider
   - Mitigation: Use trusted API providers only

3. **AI Prompt Injection**: AI could be manipulated by malicious input
   - Mitigation: User confirmation for sensitive operations
   - Mitigation: Path authorization system

4. **Terminal Escape Sequences**: Partial sanitization implemented
   - Mitigation: TerminalGuard module for state cleanup
   - Future: More comprehensive sanitization

### Best Practices for Users

1. **Review AI Suggestions**: Always review code before execution
2. **Protect API Keys**: Don't share config.json; use proper file permissions
3. **Use Incognito Mode**: For sensitive work, use `--incognito` flag
4. **Regular Updates**: Keep CLIO updated to get security fixes
5. **Session Cleanup**: Use `/session trim` to remove old sessions

### Security Testing

We welcome security testing and responsible disclosure. Areas of interest:

- Path traversal vulnerabilities
- API key exposure
- Terminal escape sequence injection
- Prompt injection attacks
- Session file manipulation

## Changelog

Security-related changes are noted in [CHANGELOG.md](CHANGELOG.md).

## Contact

For security concerns, contact the maintainer through GitHub's security features or the email listed on the maintainer's GitHub profile.
