#!/usr/bin/env python3
"""Prove Makefile gates turn red for the failures they claim to catch."""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
PUBLIC_SUITE = ROOT / "integration-tests" / "public.sh"


def run(*args: str, cwd: Path = ROOT) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        cwd=cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )


def require_red(name: str, result: subprocess.CompletedProcess[str]) -> None:
    if result.returncode == 0:
        raise SystemExit(
            f"FAIL Makefile gate oracle: {name} stayed green\n{result.stdout}"
        )


def require_green(name: str, result: subprocess.CompletedProcess[str]) -> None:
    if result.returncode != 0:
        raise SystemExit(f"FAIL Makefile gate oracle: {name} failed\n{result.stdout}")


def check_fetch_failure() -> None:
    with tempfile.TemporaryDirectory() as directory:
        missing = Path(directory) / "missing-client"
        require_red(
            "fetch accepted a missing explicit client checkout",
            run("make", "--no-print-directory", "fetch", f"RCLIENT_DIR={missing}"),
        )


def check_early_syntax_failure() -> None:
    with tempfile.TemporaryDirectory() as directory:
        fixture = Path(directory)
        invalid = fixture / "invalid-first.sh"
        valid = fixture / "valid-last.sh"
        invalid.write_text("#!/usr/bin/env bash\nif then\n", encoding="utf-8")
        valid.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
        require_red(
            "syntax discarded an early loop failure",
            run(
                "make",
                "--no-print-directory",
                "syntax",
                f"SH_SCRIPTS={invalid} {valid}",
                "PY_SCRIPTS=",
            ),
        )


def check_committed_whitespace_failure() -> None:
    with tempfile.TemporaryDirectory() as directory:
        fixture = Path(directory)
        commands = (
            ("git", "init", "-q"),
            ("git", "config", "user.name", "rl-nginx test"),
            ("git", "config", "user.email", "test@example.invalid"),
        )
        for command in commands:
            result = run(*command, cwd=fixture)
            if result.returncode != 0:
                raise SystemExit(result.stdout)

        tracked = fixture / "tracked.txt"
        tracked.write_text("clean\n", encoding="utf-8")
        for command in (("git", "add", "tracked.txt"), ("git", "commit", "-qm", "base")):
            result = run(*command, cwd=fixture)
            if result.returncode != 0:
                raise SystemExit(result.stdout)
        baseline = run("git", "rev-parse", "HEAD", cwd=fixture).stdout.strip()
        result = run(
            "git", "update-ref", "refs/remotes/origin/main", baseline, cwd=fixture
        )
        if result.returncode != 0:
            raise SystemExit(result.stdout)

        tracked.write_text("trailing whitespace \n", encoding="utf-8")
        for command in (("git", "add", "tracked.txt"), ("git", "commit", "-qm", "bad")):
            result = run(*command, cwd=fixture)
            if result.returncode != 0:
                raise SystemExit(result.stdout)

        (fixture / "later.txt").write_text("later clean commit\n", encoding="utf-8")
        for command in (("git", "add", "later.txt"), ("git", "commit", "-qm", "later")):
            result = run(*command, cwd=fixture)
            if result.returncode != 0:
                raise SystemExit(result.stdout)

        require_red(
            "whitespace ignored a committed defect before the latest commit",
            run("make", "--no-print-directory", "-f", str(ROOT / "Makefile"), "whitespace", cwd=fixture),
        )


def check_public_test_reuses_requested_build() -> None:
    public_suite = PUBLIC_SUITE.read_text()
    if 'make -C "${RCLIENT_DIR}" test-responder' not in public_suite:
        raise SystemExit(
            "FAIL Makefile gate oracle: public suite does not materialize its responder"
        )

    dry_check = run(
        "make",
        "--no-print-directory",
        "-n",
        "check",
        "BUILD_FLAGS=--clean",
    )
    require_green("could not inspect make check", dry_check)
    if "SKIP_BUILD=1 ./integration-tests/public.sh" not in dry_check.stdout:
        raise SystemExit(
            "FAIL Makefile gate oracle: make check does not reuse its requested build"
        )
    if "./tools/build-nginx.sh \"./upstream-nginx\" --clean" not in dry_check.stdout:
        raise SystemExit(
            "FAIL Makefile gate oracle: make check discarded caller BUILD_FLAGS"
        )

    standalone = run("make", "--no-print-directory", "-n", "public-test")
    require_green("could not inspect standalone public-test", standalone)
    if "SKIP_BUILD=0 ./integration-tests/public.sh" not in standalone.stdout:
        raise SystemExit(
            "FAIL Makefile gate oracle: standalone public-test no longer builds nginx"
        )

    require_red(
        "make check accepted dynamic BUILD_FLAGS without a reusable nginx binary",
        run(
            "make",
            "--no-print-directory",
            "check-build-flags",
            "BUILD_FLAGS=--dynamic --compat --clean",
        ),
    )


def main() -> None:
    check_fetch_failure()
    check_early_syntax_failure()
    check_committed_whitespace_failure()
    check_public_test_reuses_requested_build()
    print(
        "PASS Makefile failure propagation and build reuse "
        "(fetch, syntax, whitespace, static check, responder fixture)"
    )


if __name__ == "__main__":
    main()
