# Security Policy

## Report privately

Do not open a public issue or pull request for a suspected vulnerability.
Submit it through GitHub's private vulnerability reporting for this repository:

[Open a private security report](https://github.com/ratelimitly-com/rl-nginx/security/advisories/new)

The report is private to the repository's security maintainers and requires a
GitHub account. GitHub private reporting is the authoritative security contact
for rl-nginx; this project does not assign a personal maintainer email or
advertise an unverified alias.

Report vulnerabilities in the rl-nginx module, its build and release tooling,
the public test fixtures, or the supported integration with the locked
`rl-c-client` and nginx revisions. If the root cause belongs to `rl-c-client`
or nginx, report it to that upstream project as well and explain the rl-nginx
impact in the private report.

Please test only systems and tenants you own or are explicitly authorized to
test. The public responder and DNS fixture use synthetic credentials and are
the preferred environment for reproducing module behavior.

## What to include

Include enough detail for a maintainer to reproduce and assess impact:

- affected commit, tag, or release;
- supported nginx and `rl-c-client` revisions, build mode (static or dynamic),
  operating system, architecture, and relevant toolchain details;
- a minimal configuration with credentials, tenant names, and other sensitive
  values replaced by placeholders;
- exact reproduction steps, request shape, logs, and packet/protocol details
  when relevant;
- expected and observed behavior, security impact, and whether exploitation
  requires a particular failure policy or deployment setting; and
- a proposed mitigation or patch, if available.

Attach logs or traces only after removing API keys, cookies, authorization
headers, tenant identifiers, private hostnames, personal data, and unrelated
customer information. A synthetic fixture reproducer is more useful than a
production capture.

## Supported versions and scope

The `0.1.0-rc.3` source-only public preview is the current published release
line. The default `main` branch remains the security-fix target. The supported
preview is described in
[compatibility and release scope](docs/compatibility.md); its supported matrix
is Linux with glibc on `x86_64` and `aarch64`, nginx `1.30.2` and `1.31.1`, and
the locked `rl-c-client` `v0.4.0` revision that `0.1.0-rc.3` actually shipped.

`main` — and therefore the next release candidate — has moved to the locked
`rl-c-client` `v1.0.0` revision. Report against the combination you are running:
a published `0.1.0-rc.3` deployment pairs with `v0.4.0`, not `v1.0.0`.

The preview does not promise ABI or configuration stability across the `0.1.x`
line.

After the first release, this section and the release notes MUST identify which
release lines receive security fixes. Unless a release note says otherwise,
security fixes target the latest published line and the current `main` branch;
older lines may require an upgrade. Unsupported nginx versions, operating
systems, architectures, private server integrations, and unmodified upstream
components are not support commitments, but a report is still welcome when the
supported module integration is affected.

## Response and coordinated disclosure

Maintainers aim to acknowledge a private report within three business days,
provide an initial impact/viability assessment within seven business days, and
post an update at least every fourteen calendar days while the report remains
active. These are response targets, not a guarantee that a fix can be produced
within a fixed time; severity, reproducibility, dependency coordination, and
release risk determine the remediation schedule.

For a confirmed issue, maintainers will coordinate a fix, supported-version
impact, release timing, and public disclosure with the reporter. A GitHub
Security Advisory and CVE request may be used when appropriate. Do not publish
technical details, proof-of-concept code, or an exploit before the agreed
disclosure date. Reporter credit is given only with the reporter's permission.

If a report is not reproducible or is outside the supported scope, maintainers
will explain that disposition in the private report. The report remains the
place for follow-up questions and status updates.

## Credential and test-data handling

`ratelimitly_auth_key` values are credentials. Never commit real API keys to
this repository, examples, issues, pull requests, CI logs, support bundles, or
test artifacts. The public tests use synthetic credentials and do not require a
RateLimitly tenant or server.

If a real key is exposed, immediately revoke or rotate it through the
RateLimitly control plane, remove it from accessible logs and artifacts where
possible, preserve only the minimum evidence needed for the private report, and
record the affected deployment and time window. Treat `nginx -T` output, debug
logs, core dumps, packet captures, and process memory as potentially
credential-bearing.
