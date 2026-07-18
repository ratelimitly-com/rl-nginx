#!/usr/bin/env python3
"""Check that required CI coverage is exposed as named, bounded jobs."""

from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
JOB_HEADER = re.compile(r"^  ([A-Za-z][A-Za-z0-9-]*):$")

REQUIRED = {
    "hygiene": ("timeout-minutes:", "make syntax", "make unit", "make whitespace"),
    "supported-build": (
        "timeout-minutes:",
        "module_mode:",
        "release-1.30.2",
        "release-1.31.1",
        "make build",
        "make dynamic-relocation-test",
    ),
    "configuration": ("timeout-minutes:", "make config-test"),
    "public-behavior": ("timeout-minutes:", "make public-test"),
    "sanitizers": ("timeout-minutes:", "make sanitizers"),
}


def job_blocks(lines: list[str]) -> dict[str, str]:
    in_jobs = False
    starts: list[tuple[str, int]] = []
    for index, line in enumerate(lines):
        if line == "jobs:":
            in_jobs = True
            continue
        if in_jobs:
            match = JOB_HEADER.match(line)
            if match:
                starts.append((match.group(1), index))

    blocks: dict[str, str] = {}
    for position, (name, start) in enumerate(starts):
        end = starts[position + 1][1] if position + 1 < len(starts) else len(lines)
        blocks[name] = "\n".join(lines[start:end])
    return blocks


def workflow_events(lines: list[str]) -> set[str]:
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


def main() -> int:
    if not WORKFLOW.is_file():
        print(f"FAIL CI gates: missing {WORKFLOW}", file=sys.stderr)
        return 1

    text = WORKFLOW.read_text()
    lines = text.splitlines()
    blocks = job_blocks(lines)
    failures: list[str] = []

    for name, fragments in REQUIRED.items():
        block = blocks.get(name)
        if block is None:
            failures.append(f"missing job {name!r}")
            continue
        for fragment in fragments:
            if fragment not in block:
                failures.append(f"job {name!r} lacks {fragment!r}")

    if "permissions:\n  contents: read" not in text:
        failures.append("workflow must retain least-privilege contents: read permissions")
    if "RL_CI_TOKEN" in text or "secrets." in text:
        failures.append("required CI must not depend on repository or organization secrets")
    if workflow_events(lines) != {"push", "pull_request", "workflow_dispatch"}:
        failures.append("workflow must use main pushes, pull requests, and manual dispatch")
    if "  push:\n    branches:\n      - main" not in text:
        failures.append("push trigger must be restricted to main")
    if (
        "concurrency:\n"
        "  group: ${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}\n"
        "  cancel-in-progress: true" not in text
    ):
        failures.append("workflow must cancel superseded runs using a PR/ref concurrency group")

    if failures:
        for failure in failures:
            print(f"FAIL CI gates: {failure}", file=sys.stderr)
        return 1

    print(f"PASS named CI gates: {', '.join(REQUIRED)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
