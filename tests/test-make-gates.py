#!/usr/bin/env python3
"""Prove Makefile gates turn red for the failures they claim to catch."""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


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


def main() -> None:
    check_fetch_failure()
    check_early_syntax_failure()
    check_committed_whitespace_failure()
    print("PASS Makefile failure propagation (fetch, syntax, committed whitespace)")


if __name__ == "__main__":
    main()
