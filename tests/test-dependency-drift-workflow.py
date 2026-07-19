#!/usr/bin/env python3
"""Keep exploratory dependency probes isolated from required CI."""

from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
REQUIRED_WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
DRIFT_WORKFLOW = ROOT / ".github" / "workflows" / "dependency-drift.yml"


def workflow_events(text: str) -> set[str]:
    lines = text.splitlines()
    try:
        start = lines.index("on:") + 1
    except ValueError:
        return set()

    events: set[str] = set()
    for line in lines[start:]:
        if line and not line.startswith(" "):
            break
        match = re.fullmatch(r"  ([A-Za-z_]+):", line)
        if match is not None:
            events.add(match.group(1))
    return events


def validate(required: str, drift: str) -> list[str]:
    failures: list[str] = []
    if workflow_events(drift) != {"schedule", "workflow_dispatch"}:
        failures.append("drift workflow must be schedule/manual only")
    if workflow_events(required) != {"push", "pull_request", "workflow_dispatch"}:
        failures.append("required CI triggers changed unexpectedly")
    if "continue-on-error:" in drift:
        failures.append("drift failures must remain visible")
    if "rl-c-client-main" in required or "origin master" in required:
        failures.append("required CI contains a floating dependency probe")
    if "permissions:\n  contents: read" not in drift:
        failures.append("drift workflow must retain top-level contents: read")
    if re.search(r"^[ \t]{2,}permissions:", drift, re.MULTILINE):
        failures.append("drift jobs must not override top-level permissions")
    if "write-all" in drift or "secrets." in drift or "RL_CI_TOKEN" in drift:
        failures.append("drift workflow must not gain write or secret access")

    checkout_count = drift.count("uses: actions/checkout@")
    credential_blocks = drift.count("persist-credentials: false")
    if checkout_count == 0 or credential_blocks != checkout_count:
        failures.append("every drift checkout must disable credential persistence")

    required_fragments = (
        "c-client-main:",
        "nginx-master:",
        "--branch main https://github.com/ratelimitly-com/rl-c-client.git",
        "git -C upstream-nginx fetch --depth=1 origin master",
        "make dynamic-relocation-test",
        "make public-test",
    )
    for fragment in required_fragments:
        if fragment not in drift:
            failures.append(f"missing compatibility probe fragment: {fragment}")

    return failures


def negative_fixture_failures(required: str, drift: str) -> list[str]:
    failures: list[str] = []
    mutations = (
        (
            "writable top-level permissions",
            drift.replace("permissions:\n  contents: read", "permissions:\n  contents: write", 1),
        ),
        (
            "job-level write-all override",
            drift.replace(
                "  c-client-main:\n",
                "  c-client-main:\n    permissions: write-all\n",
                1,
            ),
        ),
        (
            "persisted checkout credentials",
            drift.replace("          persist-credentials: false\n", "", 1),
        ),
    )
    for name, mutated in mutations:
        if mutated == drift:
            failures.append(f"negative fixture could not create {name}")
        elif not validate(required, mutated):
            failures.append(f"validator accepted {name}")
    return failures


def main() -> int:
    if not REQUIRED_WORKFLOW.is_file() or not DRIFT_WORKFLOW.is_file():
        print(
            "FAIL dependency drift workflow: required or drift workflow is missing",
            file=sys.stderr,
        )
        return 1

    required = REQUIRED_WORKFLOW.read_text()
    drift = DRIFT_WORKFLOW.read_text()
    failures = validate(required, drift)
    failures.extend(negative_fixture_failures(required, drift))
    if failures:
        for failure in failures:
            print(f"FAIL dependency drift workflow: {failure}", file=sys.stderr)
        return 1

    print(
        "PASS dependency drift probes are isolated and read-only "
        "(3 red-case mutations)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
