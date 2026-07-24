#!/usr/bin/env python3
"""Keep sanitizer scope complete, shared, and narrowly suppressed."""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
FLAGS = ROOT / "tools" / "sanitizer-flags.env"
BUILD = ROOT / "tests" / "build-nginx.sh"
RUNNER = ROOT / "tools" / "sanitized-lifecycle.sh"
LIFECYCLE = ROOT / "integration-tests" / "lifecycle-regressions.sh"
SCANNER = ROOT / "tools" / "check-sanitizer-reports.sh"
ALLOWLIST = ROOT / "tools" / "sanitizer-known-reports.txt"
KNOWN_UPSTREAM_REPORTS = (
    "src/core/ngx_string.c:84:5: runtime error: null pointer passed as "
    "argument 2, which is declared to never be null",
    "src/core/ngx_string.c:586:19: runtime error: null pointer passed as "
    "argument 2, which is declared to never be null",
)


def validate(documents: dict[str, str]) -> list[str]:
    flags = documents["flags"]
    build = documents["build"]
    runner = documents["runner"]
    lifecycle = documents["lifecycle"]
    scanner = documents["scanner"]
    allowlist = documents["allowlist"]
    failures: list[str] = []

    for required in (
        "RN_SANITIZER_COMPILE_FLAGS=",
        "RN_SANITIZER_LINK_FLAGS=",
        "-fsanitize=address,undefined",
        "-fno-omit-frame-pointer",
    ):
        if required not in flags:
            failures.append(f"shared sanitizer flags omit {required!r}")
    if "-fno-sanitize=" in flags or "-fno-sanitize=" in build:
        failures.append("nginx/module build disables a sanitizer category globally")
    if 'source "${RN_DIR}/tools/sanitizer-flags.env"' not in build:
        failures.append("nginx/module build does not consume shared sanitizer flags")
    if 'source "${RN_ROOT}/tools/sanitizer-flags.env"' not in runner:
        failures.append("lifecycle runner does not consume shared sanitizer flags")
    default_asan = (
        'export ASAN_OPTIONS="${ASAN_OPTIONS:-abort_on_error=1:'
        'detect_leaks=1:strict_string_checks=1}"'
    )
    if default_asan not in runner:
        failures.append("runtime LeakSanitizer is not enabled by default")
    if (
        'export UBSAN_OPTIONS="${UBSAN_OPTIONS:-halt_on_error=0:print_stacktrace=1}"'
        not in runner
    ):
        failures.append("UBSan does not defer acceptance to the exact report scanner")
    if runner.count("run_sanitized_probe env") != 3:
        failures.append("standalone sanitizer probes are not all captured")
    if (
        '"${RN_ROOT}/tools/check-sanitizer-reports.sh" "${PROBE_ARTIFACTS}"'
        not in runner
    ):
        failures.append("standalone sanitizer probe reports are not scanned")
    if (
        'RN_NGINX_ONESHOT_ASAN_OPTIONS="${ASAN_OPTIONS}:detect_leaks=0"'
        not in runner
    ):
        failures.append("one-shot nginx commands lack their process-scoped LSan exception")
    if (
        'oneshot_env+=("ASAN_OPTIONS=${RN_NGINX_ONESHOT_ASAN_OPTIONS}")'
        not in lifecycle
        or 'env "${oneshot_env[@]}" "${NGINX_BIN}" "$@"' not in lifecycle
    ):
        failures.append("lifecycle one-shot commands ignore the scoped exception")
    for command in (
        'run_nginx_oneshot -p "${PREFIX}/" -c "${NGINX_CONF}" -t',
        'run_nginx_oneshot -p "${PREFIX}/" -c "${NGINX_CONF}" -s reload',
        'run_nginx_oneshot -p "${PREFIX}/" -c "${NGINX_CONF}" -s quit',
    ):
        if command not in lifecycle:
            failures.append(f"one-shot nginx command bypasses scoped LSan handling: {command}")
    if '"${RN_ROOT}/tools/check-sanitizer-reports.sh"' not in runner:
        failures.append("sanitizer runner bypasses the reviewed report scanner")
    for marker in (
        "ERROR: AddressSanitizer",
        "ERROR: LeakSanitizer",
        "SUMMARY: AddressSanitizer",
        "runtime error:",
    ):
        if marker not in scanner:
            failures.append(f"artifact scanner does not detect {marker!r}")
    accepted = [
        line for line in allowlist.splitlines() if line and not line.startswith("#")
    ]
    if accepted != list(KNOWN_UPSTREAM_REPORTS):
        failures.append("sanitizer allowlist is not the exact reviewed nginx reports")
    return failures


def negative_fixture_failures(documents: dict[str, str]) -> list[str]:
    mutations = (
        (
            "disabled runtime leak detection",
            {
                **documents,
                "runner": documents["runner"].replace(
                    'abort_on_error=1:detect_leaks=1:strict_string_checks=1',
                    'abort_on_error=1:detect_leaks=0:strict_string_checks=1',
                    1,
                ),
            },
        ),
        (
            "global sanitizer exclusion",
            {**documents, "build": documents["build"] + "\n-fno-sanitize=nonnull-attribute\n"},
        ),
        (
            "premature UBSan halt",
            {
                **documents,
                "runner": documents["runner"].replace(
                    "halt_on_error=0:print_stacktrace=1",
                    "halt_on_error=1:print_stacktrace=1",
                    1,
                ),
            },
        ),
        (
            "uncaptured standalone probe",
            {
                **documents,
                "runner": documents["runner"].replace(
                    "run_sanitized_probe env",
                    "env",
                    1,
                ),
            },
        ),
        (
            "unscanned standalone probes",
            {
                **documents,
                "runner": documents["runner"].replace(
                    '"${RN_ROOT}/tools/check-sanitizer-reports.sh" '
                    '"${PROBE_ARTIFACTS}"',
                    "true",
                    1,
                ),
            },
        ),
        (
            "divergent nginx sanitizer flags",
            {
                **documents,
                "build": documents["build"].replace(
                    'source "${RN_DIR}/tools/sanitizer-flags.env"', "# removed", 1
                ),
            },
        ),
        (
            "missing one-shot nginx exception",
            {
                **documents,
                "runner": documents["runner"].replace(
                    'RN_NGINX_ONESHOT_ASAN_OPTIONS="${ASAN_OPTIONS}:detect_leaks=0"',
                    "# removed",
                    1,
                ),
            },
        ),
        (
            "reload bypasses one-shot exception",
            {
                **documents,
                "lifecycle": documents["lifecycle"].replace(
                    'run_nginx_oneshot -p "${PREFIX}/" -c "${NGINX_CONF}" -s reload',
                    '"${NGINX_BIN}" -p "${PREFIX}/" -c "${NGINX_CONF}" -s reload',
                    1,
                ),
            },
        ),
        (
            "quit bypasses one-shot exception",
            {
                **documents,
                "lifecycle": documents["lifecycle"].replace(
                    'run_nginx_oneshot -p "${PREFIX}/" -c "${NGINX_CONF}" -s quit',
                    '"${NGINX_BIN}" -p "${PREFIX}/" -c "${NGINX_CONF}" -s quit',
                    1,
                ),
            },
        ),
        (
            "unobservable LeakSanitizer report",
            {
                **documents,
                "scanner": documents["scanner"].replace(
                    "ERROR: LeakSanitizer", "removed LeakSanitizer marker", 1
                ),
            },
        ),
        (
            "runner bypasses report scanner",
            {
                **documents,
                "runner": documents["runner"].replace(
                    '"${RN_ROOT}/tools/check-sanitizer-reports.sh"', "# removed", 1
                ),
            },
        ),
        (
            "broadened report allowlist",
            {**documents, "allowlist": "runtime error:\n"},
        ),
    )
    failures: list[str] = []
    for name, mutated in mutations:
        if mutated == documents:
            failures.append(f"negative fixture could not create {name}")
        elif not validate(mutated):
            failures.append(f"sanitizer validator accepted {name}")
    return failures


def scanner_fixture_failures() -> list[str]:
    failures: list[str] = []
    with tempfile.TemporaryDirectory(prefix="rl-nginx-sanitizer-policy-") as tmp:
        log = Path(tmp) / "nginx-error.log"
        log.write_text(
            "".join(f"prefix: {report}\n" for report in KNOWN_UPSTREAM_REPORTS)
        )
        accepted = subprocess.run(
            [str(SCANNER), tmp], capture_output=True, text=True, check=False
        )
        if accepted.returncode != 0:
            failures.append("report scanner rejected the exact upstream-nginx report")

        log.write_text("src/module.c:42: runtime error: unexpected module fault\n")
        rejected = subprocess.run(
            [str(SCANNER), tmp], capture_output=True, text=True, check=False
        )
        if rejected.returncode == 0:
            failures.append("report scanner accepted an unexpected module report")
    return failures


def main() -> int:
    paths = (FLAGS, BUILD, RUNNER, LIFECYCLE, SCANNER, ALLOWLIST)
    if any(not path.is_file() for path in paths):
        print("FAIL sanitizer policy: a required policy file is missing", file=sys.stderr)
        return 1
    documents = {
        "flags": FLAGS.read_text(),
        "build": BUILD.read_text(),
        "runner": RUNNER.read_text(),
        "lifecycle": LIFECYCLE.read_text(),
        "scanner": SCANNER.read_text(),
        "allowlist": ALLOWLIST.read_text(),
    }
    failures = validate(documents)
    failures.extend(negative_fixture_failures(documents))
    failures.extend(scanner_fixture_failures())
    if failures:
        for failure in failures:
            print(f"FAIL sanitizer policy: {failure}", file=sys.stderr)
        return 1
    print(
        "PASS sanitizer policy is shared and narrowly scoped "
        "(12 red-case mutations, 2 scanner fixtures)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
