#!/usr/bin/env python3
"""Keep the default manual fixture inside the documented identity boundary."""

from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "tests" / "nginx.conf"
HARNESS_DOC = ROOT / "tests" / "README.md"
CLIENT_DOC = ROOT / "docs" / "c-client.md"
OPERATIONS_DOC = ROOT / "docs" / "operations.md"

FORBIDDEN_IDENTITY_VARIABLES = re.compile(
    r"\$(?:arg_[A-Za-z0-9_]*|cookie_[A-Za-z0-9_]*|http_[A-Za-z0-9_]*"
    r"|host|uri|request_uri)\b"
)
RATELIMITLY_DIRECTIVE = re.compile(
    r"^\s*ratelimitly(?:_[a-z_]+)?\b.*?;",
    re.MULTILINE | re.DOTALL,
)


def fixture_failures(fixture: str, harness_doc: str) -> list[str]:
    failures: list[str] = []
    directives = RATELIMITLY_DIRECTIVE.findall(fixture)

    if not directives:
        failures.append("manual fixture contains no RateLimitly directives")
    for directive in directives:
        match = FORBIDDEN_IDENTITY_VARIABLES.search(directive)
        if match:
            compact = " ".join(directive.split())
            failures.append(
                f"manual fixture sends raw {match.group(0)} through {compact!r}"
            )

    required_fixture = (
        "map $request_uri $rl_fixture_route",
        "map $request_method $rl_fixture_method",
        "bucket=v1|fixture=manual|zone=dynamic|route=$rl_fixture_route"
        "|method=$rl_fixture_method",
        "service=v1|fixture=manual|service=api",
        "rl_verdict=$ratelimitly_verdict",
    )
    for fragment in required_fixture:
        if fragment not in fixture:
            failures.append(f"manual fixture is missing {fragment!r}")

    if re.search(r"https?://[^'\"]*[?]", harness_doc):
        failures.append("manual harness examples use query-selected policy inputs")
    if "--cookie" in harness_doc:
        failures.append("manual harness examples send a cookie-selected identity")

    return failures


def documentation_failures(client_doc: str, operations_doc: str) -> list[str]:
    failures: list[str] = []

    if "otherwise use a single deterministic commit target" in client_doc:
        failures.append("C-client guide advertises an unimplemented target fallback")
    for fragment in (
        "rl-nginx neither selects one deterministic commit target",
        "external commit-safety property",
    ):
        if fragment not in client_doc:
            failures.append(f"C-client guide is missing {fragment!r}")

    for fragment in (
        "worker=$pid rl_verdict=$ratelimitly_verdict",
        "rl_verdict=-",
        "main context, before `events` and `http`",
    ):
        if fragment not in operations_doc:
            failures.append(f"operations guide is missing {fragment!r}")

    return failures


def main() -> int:
    fixture = FIXTURE.read_text(encoding="utf-8")
    harness_doc = HARNESS_DOC.read_text(encoding="utf-8")
    client_doc = CLIENT_DOC.read_text(encoding="utf-8")
    operations_doc = OPERATIONS_DOC.read_text(encoding="utf-8")

    failures = fixture_failures(fixture, harness_doc)
    failures.extend(documentation_failures(client_doc, operations_doc))

    unsafe_fixture = fixture + '\nratelimitly_label "$cookie_session";\n'
    if not fixture_failures(unsafe_fixture, harness_doc):
        failures.append("negative fixture accepted a raw cookie identity")
    false_mitigation = (
        client_doc
        + "\notherwise use a single deterministic commit target for writes\n"
    )
    if not documentation_failures(false_mitigation, operations_doc):
        failures.append("negative fixture accepted the nonexistent target fallback")

    if failures:
        for failure in failures:
            print(f"FAIL {failure}", file=sys.stderr)
        return 1

    print("PASS public examples use bounded identities and executable operations")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
