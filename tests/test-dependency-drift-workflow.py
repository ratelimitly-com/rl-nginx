#!/usr/bin/env python3
"""Keep exploratory dependency probes isolated from required CI."""

from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
REQUIRED_WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
DRIFT_WORKFLOW = ROOT / ".github" / "workflows" / "dependency-drift.yml"


def fail(message: str) -> int:
    print(f"FAIL dependency drift workflow: {message}", file=sys.stderr)
    return 1


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


def main() -> int:
    if not REQUIRED_WORKFLOW.is_file() or not DRIFT_WORKFLOW.is_file():
        return fail("required or drift workflow is missing")

    required = REQUIRED_WORKFLOW.read_text()
    drift = DRIFT_WORKFLOW.read_text()

    if workflow_events(drift) != {"schedule", "workflow_dispatch"}:
        return fail("drift workflow must be schedule/manual only")
    if workflow_events(required) != {"push", "pull_request"}:
        return fail("required CI triggers changed unexpectedly")
    if "continue-on-error:" in drift:
        return fail("drift failures must remain visible")
    if "rl-c-client-main" in required or "origin master" in required:
        return fail("required CI contains a floating dependency probe")

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
            return fail(f"missing compatibility probe fragment: {fragment}")

    print("PASS dependency drift probes are isolated from required CI")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
