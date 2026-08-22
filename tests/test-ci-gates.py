#!/usr/bin/env python3
"""Check that required CI jobs execute bounded, failure-propagating gates."""

from __future__ import annotations

import re
import shlex
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
DYNAMIC_RELOCATION = ROOT / "integration-tests" / "dynamic-module-relocation.sh"
JOB_HEADER = re.compile(r"^  ([A-Za-z][A-Za-z0-9-]*):$")

REQUIRED_COMMANDS = {
    "hygiene": ("syntax", "unit", "whitespace"),
    "supported-build": ("build", "dynamic-relocation-test"),
    "configuration": ("config-test",),
    "public-behavior": ("public-test",),
    "architecture": ("check", "build", "dynamic-relocation-test"),
    "sanitizers": ("sanitizers",),
}

# The one job allowed to hold a credential. It is main-only and actor-pinned,
# so it never runs for a pull request, and it is not part of the required
# gate: every job in REQUIRED_COMMANDS must stay runnable without a secret.
CREDENTIALED_JOB = "production-smoke"
CREDENTIALED_COMMANDS = ("production-smoke",)
ALLOWED_SECRET = "RATELIMITLY_AUTH_KEY"
SECRET_REFERENCE = re.compile(r"secrets\.([A-Za-z_][A-Za-z0-9_-]*)")
CREDENTIALED_CONDITIONS = (
    "github.ref == 'refs/heads/main'",
    "github.event_name == 'push'",
    "github.event_name == 'workflow_dispatch'",
    "github.actor == 'edescourtis'",
)
# Step-level environment only, with a namespace that cannot collide between
# concurrent runs.
CREDENTIALED_STEP_ENV = (
    "        env:\n"
    "          RATELIMITLY_AUTH_KEY: ${{ secrets.RATELIMITLY_AUTH_KEY }}\n"
    "          RATELIMITLY_P0_TEST_NAMESPACE:"
    " ci-${{ github.run_id }}-${{ github.run_attempt }}\n"
)

REQUIRED_MARKERS = {
    "hygiene": ("fetch-depth: 0", "WHITESPACE_BASE:"),
    "supported-build": ("module_mode:", "release-1.30.2", "release-1.31.1"),
    "architecture": (
        "runs-on: ubuntu-24.04-arm",
        "fetch-depth: 0",
        'test "$(uname -m)" = "aarch64"',
    ),
}

RUN_LINE = re.compile(r"^(\s*)(?:-\s*)?run:\s*(.*)$")
ENV_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
NGINX_MATRIX_ENTRY = re.compile(
    r"^[ \t]*- line:[ \t]*([^\s]+)[ \t]*$"
    r"\n^[ \t]+ref:[ \t]*([^\s]+)[ \t]*$"
    r"\n^[ \t]+commit:[ \t]*([0-9a-f]{40})[ \t]*$",
    re.MULTILINE,
)


def nginx_gitlink_commit() -> str | None:
    try:
        output = subprocess.check_output(
            ["git", "ls-files", "--stage", "--", "upstream-nginx"],
            cwd=ROOT,
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        return None
    match = re.fullmatch(r"160000 ([0-9a-f]{40}) 0\tupstream-nginx", output)
    return match.group(1) if match is not None else None


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


def validate_credentialed_job(block: str | None) -> list[str]:
    """Check the live production job that is trusted with the API key."""
    if block is None:
        return [f"missing job {CREDENTIALED_JOB!r}"]

    failures: list[str] = []
    timeout = re.search(r"^    timeout-minutes:\s*([0-9]+)\s*$", block, re.MULTILINE)
    if timeout is None or int(timeout.group(1)) <= 0:
        failures.append(f"job {CREDENTIALED_JOB!r} lacks a positive timeout")
    if re.search(r"^\s+continue-on-error:", block, re.MULTILINE):
        failures.append(
            f"job {CREDENTIALED_JOB!r} must not discard a step or job failure"
        )

    observed_commands = run_commands(block)
    for command in CREDENTIALED_COMMANDS:
        if command not in observed_commands:
            failures.append(
                f"job {CREDENTIALED_JOB!r} does not execute 'make {command}'"
            )
    for condition in CREDENTIALED_CONDITIONS:
        if condition not in block:
            failures.append(f"job {CREDENTIALED_JOB!r} lacks {condition!r}")
    if f"      group: rl-nginx-{CREDENTIALED_JOB}\n" not in block:
        failures.append(f"job {CREDENTIALED_JOB!r} lacks its own concurrency group")
    if "      cancel-in-progress: false\n" not in block:
        failures.append(f"job {CREDENTIALED_JOB!r} must never cancel a live run")
    if CREDENTIALED_STEP_ENV not in block:
        failures.append(
            f"job {CREDENTIALED_JOB!r} must read the credential as step-level "
            "environment beside a unique per-run namespace"
        )
    return failures


def validate(text: str, nginx_gitlink: str) -> list[str]:
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

    matrix_jobs = (
        "supported-build",
        "configuration",
        "public-behavior",
        "architecture",
        "sanitizers",
    )
    expected_entries = NGINX_MATRIX_ENTRY.findall(blocks.get("supported-build", ""))
    if len(expected_entries) != 2 or {entry[0] for entry in expected_entries} != {
        "stable",
        "mainline",
    }:
        failures.append("supported-build must declare exactly stable and mainline nginx")
    for name in matrix_jobs:
        entries = NGINX_MATRIX_ENTRY.findall(blocks.get(name, ""))
        if entries != expected_entries:
            failures.append(f"job {name!r} nginx matrix diverges from supported-build")

    mainline = [entry for entry in expected_entries if entry[0] == "mainline"]
    if len(mainline) != 1 or mainline[0][2] != nginx_gitlink:
        failures.append("required nginx matrices do not match the nginx gitlink")

    if "permissions:\n  contents: read" not in text:
        failures.append("workflow must retain least-privilege contents: read permissions")
    if "RL_CI_TOKEN" in text:
        failures.append("CI must not depend on a repository or organization token")

    failures.extend(validate_credentialed_job(blocks.get(CREDENTIALED_JOB)))
    for name, block in blocks.items():
        if name == CREDENTIALED_JOB:
            continue
        if SECRET_REFERENCE.search(block):
            failures.append(
                f"job {name!r} must not depend on a repository or organization secret"
            )
    for secret in sorted(set(SECRET_REFERENCE.findall(text))):
        if secret != ALLOWED_SECRET:
            failures.append(f"CI must not read the {secret!r} secret")
    if len(SECRET_REFERENCE.findall(text)) != len(
        SECRET_REFERENCE.findall(blocks.get(CREDENTIALED_JOB, ""))
    ):
        failures.append(f"only job {CREDENTIALED_JOB!r} may read a secret")
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


def mutate_job(text: str, name: str, old: str, new: str) -> str:
    lines = text.splitlines(keepends=True)
    start = next(
        (index for index, line in enumerate(lines) if line == f"  {name}:\n"),
        None,
    )
    if start is None:
        return text
    end = next(
        (
            index
            for index in range(start + 1, len(lines))
            if JOB_HEADER.match(lines[index].rstrip("\n")) is not None
        ),
        len(lines),
    )
    block = "".join(lines[start:end])
    mutated = block.replace(old, new, 1)
    return "".join((*lines[:start], mutated, *lines[end:]))


def validate_dynamic_relocation(text: str) -> list[str]:
    failures: list[str] = []
    if 'NGINX_LOAD_MODULE="${RUNTIME_MODULE}"' not in text:
        failures.append("dynamic behavior does not load the relocated module")
    for case in (
        "admission-contract",
        "worker-resolver-scope",
        "enforcement-boundary",
        "udp-ingress-fairness",
        "steering-rebind",
        "guard-latency",
    ):
        command = f'"${{SCRIPT_DIR}}/lifecycle-regressions.sh" {case}'
        if command not in text:
            failures.append(f"dynamic behavior omits {case!r}")
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


def credentialed_negative_fixture_failures(
    text: str, nginx_gitlink: str
) -> list[str]:
    """Prove the live-job rules turn red for the properties they claim."""
    cases = {
        "an unpinned dispatch actor": mutate_job(
            text,
            CREDENTIALED_JOB,
            "        github.actor == 'edescourtis'))",
            "        github.actor != ''))",
        ),
        "a live run that can be cancelled midway": mutate_job(
            text,
            CREDENTIALED_JOB,
            "      cancel-in-progress: false",
            "      cancel-in-progress: true",
        ),
        "a live job sharing another concurrency group": mutate_job(
            text,
            CREDENTIALED_JOB,
            f"      group: rl-nginx-{CREDENTIALED_JOB}",
            "      group: ${{ github.workflow }}",
        ),
        "a namespace shared by concurrent runs": mutate_job(
            text,
            CREDENTIALED_JOB,
            "ci-${{ github.run_id }}-${{ github.run_attempt }}",
            "ci-fixed",
        ),
        "a job-level credential": mutate_job(
            text,
            CREDENTIALED_JOB,
            "        env:\n          RATELIMITLY_AUTH_KEY:",
            "    env:\n      RATELIMITLY_AUTH_KEY:",
        ),
        "a missing live job": mutate_job(
            text,
            CREDENTIALED_JOB,
            f"  {CREDENTIALED_JOB}:",
            f"  {CREDENTIALED_JOB}-disabled:",
        ),
        "an unrelated secret": text.replace(
            "secrets.RATELIMITLY_AUTH_KEY", "secrets.RATELIMITLY_OTHER_KEY", 1
        ),
        "a secret inside a required job": text.replace(
            "  hygiene:\n",
            "  hygiene:\n    env:\n      KEY: ${{ secrets.RATELIMITLY_AUTH_KEY }}\n",
            1,
        ),
    }

    failures: list[str] = []
    for name, mutated in cases.items():
        if mutated == text:
            failures.append(f"negative fixture could not introduce {name}")
        elif not validate(mutated, nginx_gitlink):
            failures.append(f"validator accepted {name}")
    return failures


def negative_fixture_failures(text: str, nginx_gitlink: str) -> list[str]:
    failures: list[str] = []
    targets = sorted(
        {target for targets in REQUIRED_COMMANDS.values() for target in targets}
        | set(CREDENTIALED_COMMANDS)
    )
    for target in targets:
        if not validate(remove_make_command(text, target), nginx_gitlink):
            failures.append(f"validator stayed green after removing 'make {target}'")

    continue_on_error = text.replace(
        "  hygiene:\n", "  hygiene:\n    continue-on-error: true\n", 1
    )
    if not validate(continue_on_error, nginx_gitlink):
        failures.append("validator accepted continue-on-error on a required job")

    no_timeout = text.replace("    timeout-minutes: 15", "    timeout-minutes: 0", 1)
    if not validate(no_timeout, nginx_gitlink):
        failures.append("validator accepted an unbounded required job")

    shallow_hygiene = text.replace("          fetch-depth: 0\n", "", 1)
    if not validate(shallow_hygiene, nginx_gitlink):
        failures.append("validator accepted a whitespace job without revision history")

    shallow_architecture = mutate_job(
        text, "architecture", "          fetch-depth: 0\n", ""
    )
    if shallow_architecture == text:
        failures.append("negative fixture could not make the architecture checkout shallow")
    elif not validate(shallow_architecture, nginx_gitlink):
        failures.append(
            "validator accepted an architecture check without revision history"
        )

    no_whitespace_base = re.sub(
        r"\n        env:\n          WHITESPACE_BASE:.*(?=\n        run: make whitespace)",
        "",
        text,
        count=1,
    )
    if not validate(no_whitespace_base, nginx_gitlink):
        failures.append("validator accepted a whitespace job without an event base")

    mismatched_gitlink = text.replace(nginx_gitlink, "0" * 40)
    if mismatched_gitlink == text:
        failures.append("negative fixture could not mutate the nginx matrix commit")
    elif not validate(mismatched_gitlink, nginx_gitlink):
        failures.append("validator accepted an nginx matrix that omitted the gitlink")

    x64_architecture = mutate_job(
        text, "architecture", "runs-on: ubuntu-24.04-arm", "runs-on: ubuntu-latest"
    )
    if x64_architecture == text:
        failures.append("negative fixture could not remove native aarch64 execution")
    elif not validate(x64_architecture, nginx_gitlink):
        failures.append("validator accepted an architecture job on x86_64")

    stable_entry = (
        "          - line: stable\n"
        "            ref: release-1.30.2\n"
        "            commit: a92a537860c7b87d3793d9eb41c9cf3ed833b53c\n"
    )
    one_line_sanitizers = mutate_job(text, "sanitizers", stable_entry, "")
    if one_line_sanitizers == text:
        failures.append("negative fixture could not remove stable sanitizers")
    elif not validate(one_line_sanitizers, nginx_gitlink):
        failures.append("validator accepted sanitizers for only one nginx line")
    return failures


def dynamic_negative_fixture_failures(text: str) -> list[str]:
    failures: list[str] = []
    for case in (
        "admission-contract",
        "worker-resolver-scope",
        "enforcement-boundary",
        "udp-ingress-fairness",
        "steering-rebind",
        "guard-latency",
    ):
        command = f'"${{SCRIPT_DIR}}/lifecycle-regressions.sh" {case}'
        mutated = text.replace(command, f"# removed {case}", 1)
        if mutated == text:
            failures.append(f"negative fixture could not remove dynamic {case!r}")
        elif not validate_dynamic_relocation(mutated):
            failures.append(f"validator accepted dynamic behavior without {case!r}")
    return failures


def main() -> int:
    if not WORKFLOW.is_file() or not DYNAMIC_RELOCATION.is_file():
        print("FAIL CI gates: workflow or dynamic relocation script is missing", file=sys.stderr)
        return 1

    nginx_gitlink = nginx_gitlink_commit()
    if nginx_gitlink is None:
        print("FAIL CI gates: could not read the upstream-nginx gitlink", file=sys.stderr)
        return 1

    text = WORKFLOW.read_text()
    dynamic_relocation = DYNAMIC_RELOCATION.read_text()
    failures = validate(text, nginx_gitlink)
    failures.extend(negative_fixture_failures(text, nginx_gitlink))
    failures.extend(credentialed_negative_fixture_failures(text, nginx_gitlink))
    failures.extend(validate_dynamic_relocation(dynamic_relocation))
    failures.extend(dynamic_negative_fixture_failures(dynamic_relocation))

    if failures:
        for failure in failures:
            print(f"FAIL CI gates: {failure}", file=sys.stderr)
        return 1

    mutation_count = (
        len(
            {target for targets in REQUIRED_COMMANDS.values() for target in targets}
            | set(CREDENTIALED_COMMANDS)
        )
        + 20
    )
    print(
        "PASS named CI gates execute and propagate failures: "
        f"{', '.join((*REQUIRED_COMMANDS, CREDENTIALED_JOB))} "
        f"({mutation_count} red-case mutations)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
