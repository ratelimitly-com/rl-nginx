#!/usr/bin/env python3
"""Check source-backed claims in the normative specification."""

from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / "src" / "ngx_http_ratelimitly_module.c"
SPEC_DIR = ROOT / "spec"
DSL = SPEC_DIR / "dsl.md"
BEHAVIOR = SPEC_DIR / "behavior.md"
IMPLEMENTATION = SPEC_DIR / "implementation.md"
INDEX = SPEC_DIR / "index.md"
ROADMAP = SPEC_DIR / "roadmap.md"


def fail(message: str) -> None:
    print(f"spec consistency: FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def require(text: str, fragment: str, location: str) -> None:
    if fragment not in text:
        fail(f"{location} is missing {fragment!r}")


source = MODULE.read_text(encoding="utf-8")
dsl = DSL.read_text(encoding="utf-8")
behavior = BEHAVIOR.read_text(encoding="utf-8")
implementation = IMPLEMENTATION.read_text(encoding="utf-8")
index = INDEX.read_text(encoding="utf-8")
roadmap = ROADMAP.read_text(encoding="utf-8")

source_directives = set(re.findall(r'ngx_string\("(ratelimitly(?:_[a-z_]+)?)"\)', source))
# This directive is compiled only into the sanitizer fault-injection binary and
# is deliberately absent from the public module DSL.
source_directives.discard("ratelimitly_test_fault")
documented_directives = set(re.findall(r"^### `([^`]+)`$", dsl, re.MULTILINE))
if source_directives != documented_directives:
    missing = sorted(source_directives - documented_directives)
    extra = sorted(documented_directives - source_directives)
    fail(f"directive mismatch; undocumented={missing}, nonexistent={extra}")

source_defaults = {
    "timeout": "mcf->timeout_ms = 20;",
    "failure": "mcf->fail_open = 1;",
    "debug": "mcf->debug = 0;",
    "ttl": "uint32_t ttl_ms = 30000;",
    "max_samples": "uint32_t max_samples = 128;",
    "buffer_size": "uint32_t buffer_size = 128;",
    "min_sample_threshold": "uint32_t min_sample_threshold = 8;",
}
for name, fragment in source_defaults.items():
    require(source, fragment, f"module default {name}")

dsl_defaults = (
    "| `ratelimitly_timeout` | `20ms` |",
    "| `ratelimitly_fail` | `open` |",
    "| `ratelimitly_bind` | kernel-selected local address, ephemeral port |",
    "| `ratelimitly_debug` | `off` |",
    "| `ratelimitly_guard ttl` | `30s` |",
    "| `ratelimitly_guard max_samples` | `128` |",
    "| `ratelimitly_guard buffer_size` | `128` |",
    "| `ratelimitly_guard min_sample_threshold` | `8` |",
)
for fragment in dsl_defaults:
    require(dsl, fragment, "DSL defaults table")

for fragment in (
    "r_client_default_request_policy(&worker->policy);",
    "worker->policy.attempt_timeout_ms = mcf->timeout_ms;",
    "worker->policy.retry.retry_attempts = 0;",
    "r_client_check_rate_limit_async_borrowed(",
    "r_client_report_latency(",
):
    require(source, fragment, "module C-client integration")

require(behavior, "retry attempts to zero", "behavior specification")
require(implementation, "retry.retry_attempts = 0", "implementation specification")

for filename in ("dsl.md", "behavior.md", "mapping.md", "implementation.md", "roadmap.md"):
    require(index, f"({filename})", "specification index")

for path in (DSL, BEHAVIOR, SPEC_DIR / "mapping.md", IMPLEMENTATION, INDEX):
    text = path.read_text(encoding="utf-8")
    if "(Draft)" in text or re.search(r"^# .*\bDraft\b", text, re.MULTILINE):
        fail(f"{path.relative_to(ROOT)} still presents normative material as a draft")
    if re.search(r"^\s*(?:[-*]\s*)?Expose Prometheus counters\b", text, re.IGNORECASE | re.MULTILINE):
        fail(f"{path.relative_to(ROOT)} claims unimplemented Prometheus counters")

for fragment in (
    "This file is non-normative.",
    "does **not** provide",
    "Prometheus counters",
    "fixed RateLimitly server address",
    "deterministic single-commit routing mode",
    "not a server/product option",
):
    require(roadmap, fragment, "roadmap/non-features document")

print(f"spec consistency: PASS ({len(source_directives)} directives and executable defaults)")
