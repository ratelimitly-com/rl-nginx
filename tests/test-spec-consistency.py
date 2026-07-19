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


DEFAULT_STATEMENTS = {
    "timeout": "mcf->timeout_ms = 20;",
    "failure": "mcf->fail_open = 1;",
    "debug": "mcf->debug = 0;",
    "ttl": "uint32_t ttl_ms = 30000;",
    "max_samples": "uint32_t max_samples = 128;",
    "buffer_size": "uint32_t buffer_size = 128;",
    "min_sample_threshold": "uint32_t min_sample_threshold = 8;",
}

C_CLIENT_STATEMENTS = (
    "r_client_default_request_policy(&worker->policy);",
    "worker->policy.attempt_timeout_ms = mcf->timeout_ms;",
    "worker->policy.retry.retry_attempts = 0;",
    "r_client_check_rate_limit_async_borrowed(",
    "r_client_report_latency(",
)

PHASE_STATEMENTS = (
    "cmcf->phases[NGX_HTTP_PRECONTENT_PHASE].handlers",
    "ngx_memmove(&h[1], &h[0]",
)


def strip_non_executable_c(source: str) -> str:
    """Remove comments and literal #if 0 blocks before checking C statements."""
    source = re.sub(r"/\*.*?\*/", "", source, flags=re.DOTALL)
    source = re.sub(r"//[^\n]*", "", source)
    output: list[str] = []
    disabled_depth = 0
    for line in source.splitlines():
        directive = line.strip()
        if re.match(r"#\s*if\s+0(?:\s|$)", directive):
            disabled_depth += 1
            continue
        if disabled_depth:
            if re.match(r"#\s*if(?:def|ndef)?\b", directive):
                disabled_depth += 1
            elif re.match(r"#\s*endif\b", directive):
                disabled_depth -= 1
            continue
        output.append(line)
    return "\n".join(output)


def function_body(source: str, name: str) -> str:
    match = re.search(rf"\b{re.escape(name)}\s*\([^;]*?\)\s*\{{", source, re.DOTALL)
    if match is None:
        return ""
    start = match.end() - 1
    depth = 0
    for index in range(start, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start + 1 : index]
    return ""


def require(text: str, fragment: str, location: str, failures: list[str]) -> None:
    if fragment not in text:
        failures.append(f"{location} is missing {fragment!r}")


def validate(raw_source: str) -> tuple[list[str], int]:
    failures: list[str] = []
    source = strip_non_executable_c(raw_source)
    dsl = DSL.read_text(encoding="utf-8")
    behavior = BEHAVIOR.read_text(encoding="utf-8")
    implementation = IMPLEMENTATION.read_text(encoding="utf-8")
    index = INDEX.read_text(encoding="utf-8")
    roadmap = ROADMAP.read_text(encoding="utf-8")

    source_directives = set(
        re.findall(r'ngx_string\("(ratelimitly(?:_[a-z_]+)?)"\)', source)
    )
    source_directives.discard("ratelimitly_test_fault")
    documented_directives = set(re.findall(r"^### `([^`]+)`$", dsl, re.MULTILINE))
    if source_directives != documented_directives:
        missing = sorted(source_directives - documented_directives)
        extra = sorted(documented_directives - source_directives)
        failures.append(f"directive mismatch; undocumented={missing}, nonexistent={extra}")

    main_conf = function_body(source, "ngx_http_rn_create_main_conf").split(
        "return mcf;", 1
    )[0]
    guard_parser = function_body(source, "ngx_http_rn_guard")
    for name, fragment in DEFAULT_STATEMENTS.items():
        scope = guard_parser if name in {
            "ttl", "max_samples", "buffer_size", "min_sample_threshold"
        } else main_conf
        require(scope, fragment, f"executable module default {name}", failures)

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
        require(dsl, fragment, "DSL defaults table", failures)

    worker_init = function_body(source, "rn_worker_init")
    handler = function_body(source, "ngx_http_rn_handler")
    log_handler = function_body(source, "ngx_http_rn_log_handler")
    integration_scopes = (
        worker_init,
        worker_init,
        worker_init,
        handler,
        log_handler,
    )
    for fragment, scope in zip(C_CLIENT_STATEMENTS, integration_scopes):
        require(scope, fragment, "executable module C-client integration", failures)

    require(behavior, "retry attempts to zero", "behavior specification", failures)
    require(
        implementation,
        "retry.retry_attempts = 0",
        "implementation specification",
        failures,
    )

    init = function_body(source, "ngx_http_rn_init")
    require(init, PHASE_STATEMENTS[0], "final admission phase registration", failures)
    if "cmcf->phases[NGX_HTTP_ACCESS_PHASE].handlers" in init:
        failures.append("RateLimitly registers as an access-phase authorization handler")
    require(init, PHASE_STATEMENTS[1], "last-running pre-content ordering", failures)
    require(behavior, "final HTTP pre-content handler", "admission contract", failures)
    require(
        behavior,
        "consumption of the requested resources",
        "consumption contract",
        failures,
    )

    for filename in ("dsl.md", "behavior.md", "mapping.md", "implementation.md", "roadmap.md"):
        require(index, f"({filename})", "specification index", failures)

    for path in (DSL, BEHAVIOR, SPEC_DIR / "mapping.md", IMPLEMENTATION, INDEX):
        text = path.read_text(encoding="utf-8")
        if "(Draft)" in text or re.search(r"^# .*\bDraft\b", text, re.MULTILINE):
            failures.append(f"{path.relative_to(ROOT)} presents normative material as a draft")
        if re.search(
            r"^\s*(?:[-*]\s*)?Expose Prometheus counters\b",
            text,
            re.IGNORECASE | re.MULTILINE,
        ):
            failures.append(f"{path.relative_to(ROOT)} claims unimplemented Prometheus counters")

    for fragment in (
        "This file is non-normative.",
        "does **not** provide",
        "Prometheus counters",
        "fixed RateLimitly server address",
        "deterministic single-commit routing mode",
        "not a server/product option",
    ):
        require(roadmap, fragment, "roadmap/non-features document", failures)

    return failures, len(source_directives)


def negative_fixture_failures(source: str) -> list[str]:
    failures: list[str] = []
    statements = (*DEFAULT_STATEMENTS.values(), *C_CLIENT_STATEMENTS, *PHASE_STATEMENTS)
    for statement in statements:
        mutated = source.replace(statement, f"/* disabled: {statement} */", 1)
        if mutated == source:
            failures.append(f"negative fixture could not find {statement!r}")
        elif not validate(mutated)[0]:
            failures.append(f"validator accepted disabled executable statement {statement!r}")

    dead_default = source.replace(
        DEFAULT_STATEMENTS["timeout"],
        f"#if 0\n    {DEFAULT_STATEMENTS['timeout']}\n#endif",
        1,
    )
    if not validate(dead_default)[0]:
        failures.append("validator accepted a default hidden in #if 0")
    return failures


def main() -> int:
    source = MODULE.read_text(encoding="utf-8")
    failures, directive_count = validate(source)
    failures.extend(negative_fixture_failures(source))
    if failures:
        for failure in failures:
            print(f"spec consistency: FAIL: {failure}", file=sys.stderr)
        return 1
    mutation_count = len(DEFAULT_STATEMENTS) + len(C_CLIENT_STATEMENTS) + len(PHASE_STATEMENTS) + 1
    print(
        "spec consistency: PASS "
        f"({directive_count} directives, executable defaults, {mutation_count} red cases)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
