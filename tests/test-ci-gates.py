#!/usr/bin/env python3
"""Check that required CI jobs execute bounded, failure-propagating gates."""

from __future__ import annotations

import re
import shlex
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
JOB_HEADER = re.compile(r"^  ([A-Za-z][A-Za-z0-9-]*):$")

REQUIRED_COMMANDS = {
    "hygiene": ("syntax", "unit", "whitespace"),
    "supported-build": ("build", "dynamic-relocation-test"),
    "configuration": ("config-test",),
    "public-behavior": ("public-test",),
    "sanitizers": ("sanitizers",),
}

REQUIRED_MARKERS = {
    "hygiene": ("fetch-depth: 0", "WHITESPACE_BASE:"),
    "supported-build": ("module_mode:", "release-1.30.2", "release-1.31.1"),
}

RUN_LINE = re.compile(r"^(\s*)(?:-\s*)?run:\s*(.*)$")
ENV_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


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


def make_target(code: str) -> str | None:
    try:
        tokens = shlex.split(code, comments=True)
    except ValueError:
        return None

    index = 0
    while index < len(tokens):
        name, separator, _value = tokens[index].partition("=")
        if not separator or ENV_NAME.fullmatch(name) is None:
            break
        index += 1
    if index + 1 >= len(tokens) or tokens[index] != "make":
        return None
    target = tokens[index + 1]
    return target if re.fullmatch(r"[A-Za-z0-9_.-]+", target) else None


def run_commands(block: str) -> set[str]:
    lines = block.splitlines()
    commands: set[str] = set()
    index = 0
    while index < len(lines):
        match = RUN_LINE.match(lines[index])
        if match is None:
            index += 1
            continue

        indent = len(match.group(1))
        value = match.group(2).strip()
        scripts: list[str] = []
        if value in ("|", ">", "|-"):
            index += 1
            while index < len(lines):
                line = lines[index]
                if line.strip() and len(line) - len(line.lstrip()) <= indent:
                    break
                scripts.append(line.strip())
                index += 1
        else:
            scripts.append(value)
            index += 1

        for script in scripts:
            target = make_target(script)
            if target is not None:
                commands.add(target)
    return commands


def validate(text: str) -> list[str]:
    lines = text.splitlines()
    blocks = job_blocks(lines)
    failures: list[str] = []

    for name, required_commands in REQUIRED_COMMANDS.items():
        block = blocks.get(name)
        if block is None:
            failures.append(f"missing job {name!r}")
            continue
        timeout = re.search(r"^    timeout-minutes:\s*([0-9]+)\s*$", block, re.MULTILINE)
        if timeout is None or int(timeout.group(1)) <= 0:
            failures.append(f"job {name!r} lacks a positive timeout")
        if re.search(r"^\s+continue-on-error:", block, re.MULTILINE):
            failures.append(f"job {name!r} must not discard a step or job failure")
        if re.search(r"^\s+if:\s*(?:false|\$\{\{\s*false\s*\}\})\s*$", block, re.MULTILINE):
            failures.append(f"job {name!r} must not be statically disabled")

        observed_commands = run_commands(block)
        for command in required_commands:
            if command not in observed_commands:
                failures.append(f"job {name!r} does not execute 'make {command}'")
        for fragment in REQUIRED_MARKERS.get(name, ()):
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

    return failures


def remove_make_command(text: str, target: str) -> str:
    lines: list[str] = []
    for line in text.splitlines():
        run_line = RUN_LINE.match(line)
        code = run_line.group(2) if run_line is not None else line.strip()
        if make_target(code) == target:
            lines.append(f"{line[: len(line) - len(line.lstrip())]}# removed make {target}")
        else:
            lines.append(line)
    return "\n".join(lines) + "\n"


def negative_fixture_failures(text: str) -> list[str]:
    failures: list[str] = []
    targets = sorted({target for targets in REQUIRED_COMMANDS.values() for target in targets})
    for target in targets:
        if not validate(remove_make_command(text, target)):
            failures.append(f"validator stayed green after removing 'make {target}'")

    continue_on_error = text.replace(
        "  hygiene:\n", "  hygiene:\n    continue-on-error: true\n", 1
    )
    if not validate(continue_on_error):
        failures.append("validator accepted continue-on-error on a required job")

    no_timeout = text.replace("    timeout-minutes: 15", "    timeout-minutes: 0", 1)
    if not validate(no_timeout):
        failures.append("validator accepted an unbounded required job")

    shallow_hygiene = text.replace("          fetch-depth: 0\n", "", 1)
    if not validate(shallow_hygiene):
        failures.append("validator accepted a whitespace job without revision history")

    no_whitespace_base = re.sub(
        r"\n        env:\n          WHITESPACE_BASE:.*(?=\n        run: make whitespace)",
        "",
        text,
        count=1,
    )
    if not validate(no_whitespace_base):
        failures.append("validator accepted a whitespace job without an event base")
    return failures


def main() -> int:
    if not WORKFLOW.is_file():
        print(f"FAIL CI gates: missing {WORKFLOW}", file=sys.stderr)
        return 1

    text = WORKFLOW.read_text()
    failures = validate(text)
    failures.extend(negative_fixture_failures(text))

    if failures:
        for failure in failures:
            print(f"FAIL CI gates: {failure}", file=sys.stderr)
        return 1

    mutation_count = len({target for targets in REQUIRED_COMMANDS.values() for target in targets}) + 4
    print(
        "PASS named CI gates execute and propagate failures: "
        f"{', '.join(REQUIRED_COMMANDS)} ({mutation_count} red-case mutations)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
