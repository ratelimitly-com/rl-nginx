# Security Policy

## Reporting A Vulnerability

Do not open public issues for suspected vulnerabilities.

Until a dedicated security alias is published, report security concerns to:

```text
wojciech@ratelimitly.com
```

Include:

- affected commit or release
- nginx version
- build mode, static or dynamic
- relevant configuration snippets with secrets removed
- reproduction steps
- expected and observed behavior

## Secret Handling

`ratelimitly_auth_key` values are credentials. Do not commit real API keys to
this repository, examples, issues, or logs.

If a real key is exposed, rotate it through the RateLimitly control plane.
