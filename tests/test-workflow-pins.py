#!/usr/bin/env python3
"""Reject movable external action references in GitHub Actions workflows."""

from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
WORKFLOW_DIR = ROOT / ".github" / "workflows"
USES_LINE = re.compile(r"^\s*(?:-\s*)?uses:\s*([^\s#]+)\s*$")
GITHUB_ACTION = re.compile(
    r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*@([0-9a-f]{40})"
)
VERSION = re.compile(r"v[0-9]+(?:\.[0-9]+){0,2}")
DOCKER_DIGEST = re.compile(r"docker://[^@\s]+@sha256:[0-9a-f]{64}")


def main() -> int:
    workflows = sorted((*WORKFLOW_DIR.glob("*.yml"), *WORKFLOW_DIR.glob("*.yaml")))
    if not workflows:
        print("FAIL workflow pins: no workflow files found", file=sys.stderr)
        return 1

    checked = 0
    failures: list[str] = []

    for workflow in workflows:
        for line_number, line in enumerate(workflow.read_text().splitlines(), 1):
            code, separator, comment = line.partition("#")
            match = USES_LINE.match(code)
            if match is None:
                continue

            reference = match.group(1)
            location = f"{workflow.relative_to(ROOT)}:{line_number}"
            if reference.startswith("./"):
                continue

            checked += 1
            if reference.startswith("docker://"):
                if DOCKER_DIGEST.fullmatch(reference) is None:
                    failures.append(f"{location}: Docker action is not pinned by digest")
                continue

            if GITHUB_ACTION.fullmatch(reference) is None:
                failures.append(f"{location}: action is not pinned to a full commit SHA")
                continue
            if not separator or VERSION.fullmatch(comment.strip()) is None:
                failures.append(f"{location}: pinned action lacks an exact version comment")

    if checked == 0:
        failures.append("no external action references found")

    if failures:
        for failure in failures:
            print(f"FAIL workflow pins: {failure}", file=sys.stderr)
        return 1

    print(f"PASS {checked} external action references use immutable pins")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
