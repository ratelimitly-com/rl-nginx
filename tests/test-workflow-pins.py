#!/usr/bin/env python3
"""Reject movable action and container references in GitHub automation."""

from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
GITHUB_DIR = ROOT / ".github"
WORKFLOW_DIR = ROOT / ".github" / "workflows"
USES_LINE = re.compile(r"^\s*(?:-\s*)?uses:\s*([^\s#]+)\s*$")
IMAGE_LINE = re.compile(r"^\s*image:\s*([^\s#]+)\s*$")
CONTAINER_LINE = re.compile(r"^\s*container:\s*([^\s#]+)\s*$")
GITHUB_ACTION = re.compile(
    r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*@([0-9a-f]{40})"
)
VERSION = re.compile(r"v[0-9]+(?:\.[0-9]+){0,2}")
DOCKER_DIGEST = re.compile(r"docker://[^@\s]+@sha256:[0-9a-f]{64}")
CONTAINER_DIGEST = re.compile(r"(?:docker://)?[^@\s]+@sha256:[0-9a-f]{64}")


def validate(documents: dict[Path, str]) -> tuple[int, list[str]]:
    checked = 0
    failures: list[str] = []

    for document, contents in sorted(documents.items()):
        for line_number, line in enumerate(contents.splitlines(), 1):
            code, separator, comment = line.partition("#")
            match = USES_LINE.match(code)
            if match is not None:
                reference = match.group(1)
                location = f"{document}:{line_number}"
                if reference.startswith("./"):
                    continue

                checked += 1
                if reference.startswith("docker://"):
                    if DOCKER_DIGEST.fullmatch(reference) is None:
                        failures.append(
                            f"{location}: Docker action is not pinned by digest"
                        )
                    continue

                if GITHUB_ACTION.fullmatch(reference) is None:
                    failures.append(
                        f"{location}: action is not pinned to a full commit SHA"
                    )
                    continue
                if not separator or VERSION.fullmatch(comment.strip()) is None:
                    failures.append(
                        f"{location}: pinned action lacks an exact version comment"
                    )
                continue

            image = IMAGE_LINE.match(code)
            container = CONTAINER_LINE.match(code)
            image_reference = (
                image.group(1) if image is not None
                else container.group(1) if container is not None
                else None
            )
            if image_reference is None:
                continue
            if image_reference == "Dockerfile" or image_reference.startswith("./"):
                continue
            checked += 1
            if CONTAINER_DIGEST.fullmatch(image_reference) is None:
                failures.append(
                    f"{document}:{line_number}: container image is not pinned by digest"
                )

    if checked == 0:
        failures.append("no external action or container references found")
    return checked, failures


def negative_fixture_failures() -> list[str]:
    cases = {
        "movable action tag": {
            Path(".github/workflows/red.yml"): (
                "jobs:\n  test:\n    steps:\n      - uses: actions/checkout@v7\n"
            ),
        },
        "movable container tag": {
            Path(".github/workflows/red.yml"): (
                "jobs:\n  test:\n    container: ubuntu:24.04\n"
            ),
        },
        "movable action inside a local composite": {
            Path(".github/workflows/red.yml"): (
                "jobs:\n  test:\n    steps:\n      - uses: ./.github/actions/local\n"
            ),
            Path(".github/actions/local/action.yml"): (
                "runs:\n  using: composite\n  steps:\n    - uses: actions/checkout@v7\n"
            ),
        },
    }
    failures: list[str] = []
    for name, documents in cases.items():
        _checked, detected = validate(documents)
        if not detected:
            failures.append(f"negative fixture accepted {name}")
    return failures


def main() -> int:
    workflows = sorted((*WORKFLOW_DIR.glob("*.yml"), *WORKFLOW_DIR.glob("*.yaml")))
    if not workflows:
        print("FAIL workflow pins: no workflow files found", file=sys.stderr)
        return 1

    paths = sorted((*GITHUB_DIR.rglob("*.yml"), *GITHUB_DIR.rglob("*.yaml")))
    documents = {path.relative_to(ROOT): path.read_text() for path in paths}
    checked, failures = validate(documents)
    failures.extend(negative_fixture_failures())

    if failures:
        for failure in failures:
            print(f"FAIL workflow pins: {failure}", file=sys.stderr)
        return 1

    print(
        f"PASS {checked} action/container references use immutable pins "
        "across .github (3 red-case mutations)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
